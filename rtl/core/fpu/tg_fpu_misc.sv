// FMISC unit: sign injection, min/max, compares, classify, moves and FP -> integer conversion
// (docs/spec/fpu.md, "FMISC unit"). Two stages, M0 (request cycle) and M1; the response is
// registered and appears exactly FMISC_LAT = 2 cycles after the request. The FP -> FP and
// integer -> FP conversions run on the FMA (lever R5; tg_fpu_pkg::fpu_unit_of).
//
// M0 classifies the operands, compares magnitudes and prepares FCVT.I.F; M1 computes every
// result from the raw operands. NaN boxing only matters where an S operand's bits reach the result
// (sign injection), so M0 passes one flag rather than unboxed copies. FCVT.I.F shifts
// {significand, 12'b0} right by 63 - E in three radix-4 stages to {integer part, guard}; each
// stage ORs the bits it drops into the sticky.
module tg_fpu_misc
  import tg_pkg::*;
  import tg_fpu_pkg::*;
  import tg_fpu_util_pkg::*;
#(parameter bit SHARED = 1'b0)       // 1: a and b come unpacked (ua_i, ub_i, from tg_fpu)
(
  input  logic       clk,
  input  logic       rst,
  input  logic       valid_i,
  input  fpu_req_t   req_i,
  input  fp_unp_t    ua_i = '0,
  input  fp_unp_t    ub_i = '0,
  output logic       valid_o,
  output fpu_resp_t  resp_o
);

  // ------------------------------------------------------------------------------------------
  // M0
  // ------------------------------------------------------------------------------------------
  fpu_req_t q;
  assign q = req_i;

  logic dbl;         // operand format (and result format of the FP results)
  assign dbl = (q.fmt == FMT_D);

  fp_unp_t ua, ub;
  assign ua = SHARED ? ua_i : unpack(q.a, dbl);
  assign ub = SHARED ? ub_i : unpack(q.b, dbl);

  // Magnitudes for the compares, from the raw encodings: a NaN operand (an improperly boxed S
  // operand included) decides every result through its class, so its bits do not matter.
  logic [62:0] mag_a, mag_b;
  assign mag_a = dbl ? q.a[62:0] : {32'b0, q.a[30:0]};
  assign mag_b = dbl ? q.b[62:0] : {32'b0, q.b[30:0]};

  // ---- FCVT.I.F preparation: shift = 1086 - exponent field (the MSB has weight 2^E) ----
  logic [6:0] fi_amt;
  logic       fi_big;                               // |a| >= 2^64 or infinity
  always_comb begin
    logic signed [12:0] sh;
    sh     = 13'sd1086 - $signed({2'b00, ua.exp});
    fi_big = ua.inf || (sh < 0);
    fi_amt = (sh > 13'sd65) ? 7'd65 : sh[6:0];
  end

  // ---- M0 -> M1 register ----
  typedef struct packed {
    fop_e        op;
    logic        dbl;
    ifmt_e       ifmt;
    rm_e         rm;
    logic [FPU_TAG_W-1:0] tag;
    logic [63:0] a_raw, b_raw;
    logic        a_box;          // a reads as itself: D, or S properly NaN-boxed
    logic        a_sign, a_zero, a_sub, a_inf, a_nan, a_snan;
    logic        b_sign, b_zero, b_nan, b_snan;
    logic        mag_lt, mag_eq;
    // FCVT.I.F
    logic [52:0] a_sig;
    logic        a_fnz;          // fraction bits a_sig[51:0] not all zero
    logic [6:0]  fi_amt;
    logic        fi_big;
  } m1_t;

  m1_t m0, m1_q;
  logic v1_q;
  always_comb begin
    m0 = '0;
    m0.op = q.op; m0.dbl = dbl; m0.ifmt = q.ifmt; m0.rm = q.rm; m0.tag = q.tag;
    m0.a_raw = q.a; m0.b_raw = q.b;
    m0.a_box = dbl || (&q.a[63:32]);
    m0.a_sign = ua.sign; m0.a_zero = ua.zero; m0.a_sub = ua.sub; m0.a_inf = ua.inf;
    m0.a_nan = ua.nan; m0.a_snan = ua.snan;
    m0.b_sign = ub.sign; m0.b_zero = ub.zero; m0.b_nan = ub.nan; m0.b_snan = ub.snan;
    m0.mag_lt = mag_a < mag_b;
    m0.mag_eq = mag_a == mag_b;
    m0.a_sig  = ua.sig;
    m0.a_fnz  = |ua.sig[51:0];
    m0.fi_amt = fi_amt;
    m0.fi_big = fi_big;
  end

  always_ff @(posedge clk) begin
    if (rst) v1_q <= 1'b0;
    else     v1_q <= valid_i;
    m1_q <= m0;
  end

  // ------------------------------------------------------------------------------------------
  // M1
  // ------------------------------------------------------------------------------------------
  m1_t m;
  assign m = m1_q;

  // ---- Simple operations ----
  logic both_zero, a_eq_b, a_lt_b, any_nan, any_snan;
  always_comb begin
    both_zero = m.a_zero && m.b_zero;
    a_eq_b    = both_zero || (m.a_sign == m.b_sign && m.mag_eq);
    unique case ({m.a_sign, m.b_sign})
      2'b00:   a_lt_b = m.mag_lt;
      2'b11:   a_lt_b = !m.mag_lt && !m.mag_eq;
      2'b10:   a_lt_b = !both_zero;
      default: a_lt_b = 1'b0;
    endcase
    any_nan  = m.a_nan || m.b_nan;
    any_snan = m.a_snan || m.b_snan;
  end

  // FSGNJ*'s sign, the FMIN/FMAX choice, the class and the flags of the simple operations
  logic        sj, pick_b, mm_nan;
  logic [9:0]  cls;
  logic [4:0]  simple_fl;
  always_comb begin
    logic pick_a;
    unique case (m.op)
      FOP_FSGNJN: sj = !m.b_sign;
      FOP_FSGNJX: sj = m.a_sign ^ m.b_sign;
      default:    sj = m.b_sign;
    endcase
    // FMIN/FMAX per F 2.2 (IEEE 754-2019 minimumNumber/maximumNumber): -0 < +0; a NaN loses.
    // The result is an operand that is not a NaN, so (S) properly boxed: the raw value.
    pick_a = (a_lt_b || (a_eq_b && m.a_sign)) ^ (m.op == FOP_FMAX);
    mm_nan = m.a_nan && m.b_nan;                     // both NaN: the canonical NaN
    pick_b = m.a_nan || (!m.b_nan && !pick_a);
    cls = '0;
    cls[0] = m.a_inf && m.a_sign;
    cls[1] = !m.a_inf && !m.a_nan && !m.a_zero && !m.a_sub && m.a_sign;
    cls[2] = m.a_sub && m.a_sign;
    cls[3] = m.a_zero && m.a_sign;
    cls[4] = m.a_zero && !m.a_sign;
    cls[5] = m.a_sub && !m.a_sign;
    cls[6] = !m.a_inf && !m.a_nan && !m.a_zero && !m.a_sub && !m.a_sign;
    cls[7] = m.a_inf && !m.a_sign;
    cls[8] = m.a_snan;
    cls[9] = m.a_nan && !m.a_snan;
    simple_fl = '0;
    unique case (m.op)
      FOP_FMIN, FOP_FMAX, FOP_FEQ: simple_fl[FL_NV] = any_snan;
      FOP_FLT, FOP_FLE:            simple_fl[FL_NV] = any_nan;
      default: ;
    endcase
  end

  // ---- FCVT.I.F: shift to {integer part, guard}, round, negate, range check, saturate ----
  logic [63:0] so;
  logic        so_g, so_s;
  always_comb begin
    logic [64:0] x0, x1, x2, x3;
    logic        st1, st2, st3, st4;
    x0  = {m.a_sig, 12'b0};
    x1  = x0 >> {m.fi_amt[5:4], 4'b0};
    st1 = |(x0 & ~({65{1'b1}} << {m.fi_amt[5:4], 4'b0}));
    x2  = x1 >> {m.fi_amt[3:2], 2'b0};
    st2 = |(x1 & ~({65{1'b1}} << {m.fi_amt[3:2], 2'b0}));
    x3  = x2 >> m.fi_amt[1:0];
    st3 = |(x2 & ~({65{1'b1}} << m.fi_amt[1:0]));
    // fi_amt = 64 or 65 (|a| < 1; the stages shifted by 0 or 1): nothing reaches the integer
    // part; the guard is x3[64] and the sticky is every significand bit below it
    st4 = m.fi_amt[6] && (m.a_fnz || (m.fi_amt[0] && m.a_sig[52]));
    so   = m.fi_amt[6] ? 64'b0 : x3[64:1];
    so_g = m.fi_amt[6] ? x3[64] : x3[0];
    so_s = st1 || st2 || st3 || st4;
  end

  logic [63:0] sum, maxv, minv;
  logic        ovf;
  logic [4:0]  fi_fl;
  always_comb begin
    logic inc, nv, o_h, o_l, a_h, a_l;
    inc = round_up(m.rm, m.a_sign, so[0], so_g, so_s);
    sum = (m.a_sign ? ~so : so) + 64'(m.a_sign ? !inc : inc);
    // the rounded magnitude so + inc against the format's range, without another adder, from six
    // shared reductions of so (bits 63, 62:32, 31 and 30:0)
    o_h = |so[62:32];  a_h = &so[62:32];
    o_l = |so[30:0];   a_l = &so[30:0];
    unique case (m.ifmt)
      IFMT_W: begin
        ovf  = m.a_sign ? (so[63] || o_h || (so[31] && (o_l || inc)))
                        : (so[63] || o_h || so[31] || (a_l && inc));
        maxv = 64'h0000_0000_7FFF_FFFF; minv = 64'hFFFF_FFFF_8000_0000;
      end
      IFMT_WU: begin
        ovf  = m.a_sign ? (so[63] || o_h || so[31] || o_l || inc)
                        : (so[63] || o_h || (so[31] && a_l && inc));
        maxv = 64'hFFFF_FFFF_FFFF_FFFF; minv = 64'h0;
      end
      IFMT_L: begin
        ovf  = m.a_sign ? (so[63] && (o_h || so[31] || o_l || inc))
                        : (so[63] || (a_h && so[31] && a_l && inc));
        maxv = 64'h7FFF_FFFF_FFFF_FFFF; minv = 64'h8000_0000_0000_0000;
      end
      default: begin
        ovf  = m.a_sign ? (so[63] || o_h || so[31] || o_l || inc)
                        : (so[63] && a_h && so[31] && a_l && inc);
        maxv = 64'hFFFF_FFFF_FFFF_FFFF; minv = 64'h0;
      end
    endcase
    ovf = ovf || m.fi_big;
    nv  = m.a_nan || ovf;
    fi_fl = '0;
    fi_fl[FL_NV] = nv;
    fi_fl[FL_NX] = !nv && (so_g || so_s);
  end

  // ---- Result: one encoded select per bit (fpga_friendly.md T7) ----
  // The sources are a, b, the FCVT.I.F sum, sum[31] (the W forms' sign extension), a[31]
  // (FMV.X.W's) and a constant word kw: the canonical NaNs, the saturation values, the NaN box,
  // FSGNJ*'s sign, the compare and class results. Each op chooses a source per bit range
  // (30:0, 31, 62:32, 63), so a bit is one 4:1 select below bit 32 and a 6:1 above it, in place
  // of the simple results' multiplexer, FCVT.I.F's and the final choice between them.
  typedef enum logic [2:0] { RS_A, RS_B, RS_SUM, RS_SUMW, RS_AW, RS_K } rs_e;
  rs_e         rs_lo, rs_31, rs_hi, rs_63;
  logic [63:0] kw;
  always_comb begin
    rs_lo = RS_K; rs_31 = RS_K; rs_hi = RS_K; rs_63 = RS_K;
    kw = '0;
    unique case (m.op)
      FOP_FSGNJ, FOP_FSGNJN, FOP_FSGNJX: begin
        if (m.dbl) begin
          rs_lo = RS_A; rs_31 = RS_A; rs_hi = RS_A;
          kw[63] = sj;
        end else begin
          // NaN-boxed: the sign at bit 31, and an operand that is not boxed reads as the
          // canonical NaN's magnitude
          rs_lo = m.a_box ? RS_A : RS_K;
          kw    = {32'hFFFF_FFFF, sj, CNAN_S32[30:0]};
        end
      end
      FOP_FMIN, FOP_FMAX: begin
        rs_lo = mm_nan ? RS_K : pick_b ? RS_B : RS_A;
        rs_31 = rs_lo; rs_hi = rs_lo; rs_63 = rs_lo;
        kw    = cnan(m.dbl);
      end
      FOP_FEQ:    kw = {63'b0, !any_nan && a_eq_b};
      FOP_FLT:    kw = {63'b0, !any_nan && a_lt_b};
      FOP_FLE:    kw = {63'b0, !any_nan && (a_lt_b || a_eq_b)};
      FOP_FCLASS: kw = {54'b0, cls};
      FOP_FMV_X_F: begin
        rs_lo = RS_A; rs_31 = RS_A;
        rs_hi = m.dbl ? RS_A : RS_AW; rs_63 = rs_hi;
      end
      FOP_FMV_F_X: begin
        rs_lo = RS_A; rs_31 = RS_A;
        rs_hi = m.dbl ? RS_A : RS_K; rs_63 = rs_hi;
        kw    = {32'hFFFF_FFFF, 32'b0};
      end
      FOP_FCVT_I_F: begin
        if (m.a_nan || ovf) begin
          kw = (ovf && !m.a_nan && m.a_sign) ? minv : maxv;   // a NaN saturates to the maximum
        end else begin
          rs_lo = RS_SUM; rs_31 = RS_SUM;
          rs_hi = (m.ifmt == IFMT_W || m.ifmt == IFMT_WU) ? RS_SUMW : RS_SUM; rs_63 = rs_hi;
        end
      end
      default: ;
    endcase
  end
  logic [63:0] res;
  always_comb begin
    for (int i = 0; i < 64; i++) begin
      rs_e rs;
      rs = (i == 63) ? rs_63 : (i >= 32) ? rs_hi : (i == 31) ? rs_31 : rs_lo;
      unique case (rs)
        RS_A:    res[i] = m.a_raw[i];
        RS_B:    res[i] = m.b_raw[i];
        RS_SUM:  res[i] = sum[i];
        RS_SUMW: res[i] = sum[31];
        RS_AW:   res[i] = m.a_raw[31];
        default: res[i] = kw[i];
      endcase
    end
  end

  // ---- Output register ----
  fpu_resp_t r;
  always_comb begin
    r.tag      = m.tag;
    r.int_dest = (m.op inside {FOP_FEQ, FOP_FLT, FOP_FLE, FOP_FCLASS, FOP_FCVT_I_F, FOP_FMV_X_F});
    r.result   = res;
    r.fflags   = (m.op == FOP_FCVT_I_F) ? fi_fl : simple_fl;
  end

  fpu_resp_t resp_q;
  logic v2_q;
  always_ff @(posedge clk) begin
    if (rst) v2_q <= 1'b0;
    else     v2_q <= v1_q;
    resp_q <= r;
  end
  assign valid_o = v2_q;
  assign resp_o  = resp_q;

  logic unused;
  assign unused = ^{q.c, q.src_fmt, ub.exp, ub.sig, ub.inf, ub.sub, ua.exp[10]};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && valid_i) begin
      assert (q.fmt != FMT_H) else $error("tg_fpu_misc: FMT_H is not implemented");
      assert (fpu_unit_of(q.op) == FU_MISC)
        else $error("tg_fpu_misc: operation %0d belongs to another unit", q.op);
    end
  end
`endif

endmodule
