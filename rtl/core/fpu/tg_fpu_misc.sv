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
(
  input  logic       clk,
  input  logic       rst,
  input  logic       valid_i,
  input  fpu_req_t   req_i,
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
  assign ua = unpack(q.a, dbl);
  assign ub = unpack(q.b, dbl);

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

  logic [63:0] simple_res;
  logic [4:0]  simple_fl;
  always_comb begin
    logic sj, pick_a;
    logic [9:0] cls;
    logic [30:0] a_mag_s;       // S: magnitude of a as read (the canonical NaN's if not boxed)
    simple_res = '0;
    simple_fl  = '0;
    unique case (m.op)
      FOP_FSGNJN: sj = !m.b_sign;
      FOP_FSGNJX: sj = m.a_sign ^ m.b_sign;
      default:    sj = m.b_sign;
    endcase
    // FMIN/FMAX per F 2.2 (IEEE 754-2019 minimumNumber/maximumNumber): -0 < +0; a NaN loses
    pick_a = (a_lt_b || (a_eq_b && m.a_sign)) ^ (m.op == FOP_FMAX);
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
    a_mag_s = m.a_box ? m.a_raw[30:0] : CNAN_S32[30:0];
    unique case (m.op)
      FOP_FSGNJ, FOP_FSGNJN, FOP_FSGNJX:
        simple_res = m.dbl ? {sj, m.a_raw[62:0]} : box_s({sj, a_mag_s});
      FOP_FMIN, FOP_FMAX: begin
        // the result is an operand that is not a NaN, so (S) properly boxed: the raw value
        if (m.a_nan && m.b_nan) simple_res = cnan(m.dbl);
        else if (m.a_nan || (!m.b_nan && !pick_a)) simple_res = m.b_raw;
        else simple_res = m.a_raw;
        simple_fl[FL_NV] = any_snan;
      end
      FOP_FEQ: begin simple_res = {63'b0, !any_nan && a_eq_b};             simple_fl[FL_NV] = any_snan; end
      FOP_FLT: begin simple_res = {63'b0, !any_nan && a_lt_b};             simple_fl[FL_NV] = any_nan;  end
      FOP_FLE: begin simple_res = {63'b0, !any_nan && (a_lt_b || a_eq_b)}; simple_fl[FL_NV] = any_nan;  end
      FOP_FCLASS: simple_res = {54'b0, cls};
      FOP_FMV_X_F: simple_res = m.dbl ? m.a_raw : {{32{m.a_raw[31]}}, m.a_raw[31:0]};
      FOP_FMV_F_X: simple_res = m.dbl ? m.a_raw : box_s(m.a_raw[31:0]);
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

  logic [63:0] fi_res;
  logic [4:0]  fi_fl;
  always_comb begin
    logic inc, ovf, nv;
    logic [63:0] sum, maxv, minv;
    inc = round_up(m.rm, m.a_sign, so[0], so_g, so_s);
    sum = (m.a_sign ? ~so : so) + 64'(m.a_sign ? !inc : inc);
    // the rounded magnitude so + inc against the format's range, without another adder
    unique case (m.ifmt)
      IFMT_W: begin
        ovf  = m.a_sign ? ((|so[63:32]) || (so[31] && ((|so[30:0]) || inc)))
                        : ((|so[63:31]) || ((&so[30:0]) && inc));
        maxv = 64'h0000_0000_7FFF_FFFF; minv = 64'hFFFF_FFFF_8000_0000;
      end
      IFMT_WU: begin
        ovf  = m.a_sign ? ((|so) || inc) : ((|so[63:32]) || ((&so[31:0]) && inc));
        maxv = 64'hFFFF_FFFF_FFFF_FFFF; minv = 64'h0;
      end
      IFMT_L: begin
        ovf  = m.a_sign ? (so[63] && ((|so[62:0]) || inc)) : (so[63] || ((&so[62:0]) && inc));
        maxv = 64'h7FFF_FFFF_FFFF_FFFF; minv = 64'h8000_0000_0000_0000;
      end
      default: begin
        ovf  = m.a_sign ? ((|so) || inc) : ((&so) && inc);
        maxv = 64'hFFFF_FFFF_FFFF_FFFF; minv = 64'h0;
      end
    endcase
    ovf = ovf || m.fi_big;
    nv  = m.a_nan || ovf;
    if (m.a_nan)       fi_res = maxv;
    else if (ovf)      fi_res = m.a_sign ? minv : maxv;
    else if (m.ifmt == IFMT_W || m.ifmt == IFMT_WU) fi_res = {{32{sum[31]}}, sum[31:0]};
    else               fi_res = sum;
    fi_fl = '0;
    fi_fl[FL_NV] = nv;
    fi_fl[FL_NX] = !nv && (so_g || so_s);
  end

  // ---- Result select and output register ----
  fpu_resp_t r;
  always_comb begin
    r.tag = m.tag;
    r.int_dest = (m.op inside {FOP_FEQ, FOP_FLT, FOP_FLE, FOP_FCLASS, FOP_FCVT_I_F, FOP_FMV_X_F});
    if (m.op == FOP_FCVT_I_F) begin r.result = fi_res;     r.fflags = fi_fl;     end
    else                      begin r.result = simple_res; r.fflags = simple_fl; end
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
