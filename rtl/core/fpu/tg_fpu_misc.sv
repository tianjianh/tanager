// FMISC unit: sign injection, min/max, compares, classify, moves and FP -> integer conversion
// (docs/spec/fpu.md, "FMISC unit"). Two stages, M0 (request cycle) and M1; the response is
// registered and appears exactly FMISC_LAT = 2 cycles after the request. The FP -> FP and
// integer -> FP conversions run on the FMA (lever R5; tg_fpu_pkg::fpu_unit_of).
//
// M0 unpacks, compares magnitudes and prepares FCVT.I.F; M1 computes every result. FCVT.I.F
// shifts {significand, 11'b0} right by 63 - E to the integer part, with the guard from the
// shifter and the sticky from the significand's trailing-zero count.
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

  // Values as the format reads them (S unboxed; an improperly boxed S is the canonical NaN).
  logic [63:0] ra, rb;
  assign ra = dbl ? q.a : {32'b0, unbox_s(q.a)};
  assign rb = dbl ? q.b : {32'b0, unbox_s(q.b)};

  logic [62:0] mag_a, mag_b;
  assign mag_a = dbl ? ra[62:0] : {32'b0, ra[30:0]};
  assign mag_b = dbl ? rb[62:0] : {32'b0, rb[30:0]};

  // ---- FCVT.I.F preparation: shift = 1086 - exponent field (the MSB has weight 2^E) ----
  logic [6:0] fi_amt;
  logic       fi_big;                               // |a| >= 2^64 or infinity
  always_comb begin
    logic signed [12:0] sh;
    sh     = 13'sd1086 - $signed({2'b00, ua.exp});
    fi_big = ua.inf || (sh < 0);
    fi_amt = (sh > 13'sd65) ? 7'd65 : sh[6:0];
  end
  // Trailing zeros of the significand, for the sticky.
  logic [52:0] sig_rev;
  always_comb for (int i = 0; i < 53; i++) sig_rev[i] = ua.sig[52-i];
  logic [5:0] sig_tz;
  tg_fpu_lzc #(.W(53)) u_sig_tz (.x(sig_rev), .cnt(sig_tz));

  // ---- M0 -> M1 register ----
  typedef struct packed {
    fop_e        op;
    logic        dbl;
    ifmt_e       ifmt;
    rm_e         rm;
    logic [FPU_TAG_W-1:0] tag;
    logic [63:0] ra, rb, a_raw;
    logic        a_sign, a_zero, a_sub, a_inf, a_nan, a_snan;
    logic        b_sign, b_zero, b_nan, b_snan;
    logic        mag_lt, mag_eq;
    // FCVT.I.F
    logic [52:0] a_sig;
    logic [6:0]  fi_amt;
    logic [6:0]  sig_tz;         // trailing zeros of {significand, 11'b0}
    logic        fi_big;
  } m1_t;

  m1_t m0, m1_q;
  logic v1_q;
  always_comb begin
    m0 = '0;
    m0.op = q.op; m0.dbl = dbl; m0.ifmt = q.ifmt; m0.rm = q.rm; m0.tag = q.tag;
    m0.ra = ra; m0.rb = rb; m0.a_raw = q.a;
    m0.a_sign = ua.sign; m0.a_zero = ua.zero; m0.a_sub = ua.sub; m0.a_inf = ua.inf;
    m0.a_nan = ua.nan; m0.a_snan = ua.snan;
    m0.b_sign = ub.sign; m0.b_zero = ub.zero; m0.b_nan = ub.nan; m0.b_snan = ub.snan;
    m0.mag_lt = mag_a < mag_b;
    m0.mag_eq = mag_a == mag_b;
    m0.a_sig  = ua.sig;
    m0.fi_amt = fi_amt;
    m0.sig_tz = (ua.sig == '0) ? 7'd64 : 7'(sig_tz) + 7'd11;
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
    unique case (m.op)
      FOP_FSGNJ, FOP_FSGNJN, FOP_FSGNJX:
        simple_res = m.dbl ? {sj, m.ra[62:0]} : box_s({sj, m.ra[30:0]});
      FOP_FMIN, FOP_FMAX: begin
        if (m.a_nan && m.b_nan) simple_res = cnan(m.dbl);
        else if (m.a_nan || (!m.b_nan && !pick_a)) simple_res = m.dbl ? m.rb : box_s(m.rb[31:0]);
        else simple_res = m.dbl ? m.ra : box_s(m.ra[31:0]);
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

  // ---- FCVT.I.F: shift to the integer part, round, negate, range check, saturate ----
  logic [63:0] sh_in, so;
  logic        so_g, so_s;
  always_comb begin
    sh_in = {m.a_sig, 11'b0};
    so    = (m.fi_amt >= 7'd64) ? 64'b0 : (sh_in >> m.fi_amt[5:0]);
    so_g  = (m.fi_amt == '0 || m.fi_amt > 7'd64) ? 1'b0 : sh_in[6'(m.fi_amt - 7'd1)];
    so_s  = (m.fi_amt >= 7'd2) && ({1'b0, m.sig_tz} < {1'b0, m.fi_amt} - 8'd1);
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
