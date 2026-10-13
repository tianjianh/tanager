// FMISC unit: sign injection, min/max, compares, classify, moves and conversions
// (docs/spec/fpu.md, "FMISC unit"). Two stages, M0 (request cycle) and M1; the response is
// registered and appears exactly FMISC_LAT = 2 cycles after the request.
//
// M0 unpacks, compares magnitudes and prepares the conversions; M1 computes every result. The
// three conversions that shift share one 64-bit right shifter:
//   FCVT.I.F  {significand, 11'b0} >> (63 - E): integer part, guard, sticky
//   FCVT.S.D  {significand, 11'b0} >> (40 + k): 24-bit (or S-subnormal) significand, G, S
//   FCVT.F.I  reverse(reverse(|x|) >> (L - 1)) = |x| << (L - 1), L = lz(x ^ sign)
// Stickies come from trailing-zero counts compared with the shift, not from OR trees.
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

  logic dbl;         // result format D (or operand format for compares, class, FMV.X, FCVT.I.F)
  logic src_dbl;     // format of operand a
  assign dbl     = (q.fmt == FMT_D);
  assign src_dbl = (q.op == FOP_FCVT_F_F) ? (q.src_fmt == FMT_D) : dbl;

  fp_unp_t ua, ub;
  assign ua = unpack(q.a, src_dbl);
  assign ub = unpack(q.b, dbl);

  // Values as the format reads them (S unboxed; an improperly boxed S is the canonical NaN).
  logic [63:0] ra, rb;
  assign ra = dbl ? q.a : {32'b0, unbox_s(q.a)};
  assign rb = dbl ? q.b : {32'b0, unbox_s(q.b)};

  logic [62:0] mag_a, mag_b;
  assign mag_a = dbl ? ra[62:0] : {32'b0, ra[30:0]};
  assign mag_b = dbl ? rb[62:0] : {32'b0, rb[30:0]};

  // ---- Conversion preparation ----
  // FP -> integer: shift = 1086 - exponent field (the significand's MSB has weight 2^E).
  logic [6:0] fi_amt;
  logic       fi_big;                               // |a| >= 2^64 or infinity
  always_comb begin
    logic signed [12:0] sh;
    sh     = 13'sd1086 - $signed({2'b00, ua.exp});
    fi_big = ua.inf || (sh < 0);
    fi_amt = (sh > 13'sd65) ? 7'd65 : sh[6:0];
  end
  // D -> S: k places more for an S-subnormal result (exponent field below 897 in double bias)
  logic [6:0] ds_amt;
  logic       ds_sub;
  always_comb begin
    logic signed [12:0] k;
    k      = 13'sd897 - $signed({2'b00, ua.exp});
    ds_sub = k > 0;
    ds_amt = 7'd40 + ((k > 13'sd27) ? 7'd27 : (ds_sub ? k[6:0] : 7'd0));
  end
  // Integer -> FP: |x|, leading zeros of x ^ sign (one more than |x| has when x = -2^k), and
  // trailing zeros (the same for x and -x).
  logic        if_neg;
  logic [63:0] if_x, if_abs, if_x_rev, if_abs_rev;
  always_comb begin
    unique case (q.ifmt)
      IFMT_W:  begin if_x = {{32{q.a[31]}}, q.a[31:0]}; if_neg = q.a[31]; end
      IFMT_WU: begin if_x = {32'b0, q.a[31:0]};         if_neg = 1'b0;    end
      IFMT_L:  begin if_x = q.a;                        if_neg = q.a[63]; end
      default: begin if_x = q.a;                        if_neg = 1'b0;    end
    endcase
    if_abs = if_neg ? -if_x : if_x;
    for (int i = 0; i < 64; i++) begin
      if_x_rev[i]   = if_x[63-i];
      if_abs_rev[i] = if_abs[63-i];
    end
  end
  logic [6:0] if_lz, if_tz;
  tg_fpu_lzc #(.W(64)) u_if_lz (.x(if_x ^ {64{if_neg}}), .cnt(if_lz));
  tg_fpu_lzc #(.W(64)) u_if_tz (.x(if_x_rev), .cnt(if_tz));
  // Trailing zeros of the significand, for the FCVT.I.F and FCVT.S.D stickies.
  logic [52:0] sig_rev;
  always_comb for (int i = 0; i < 53; i++) sig_rev[i] = ua.sig[52-i];
  logic [5:0] sig_tz;
  tg_fpu_lzc #(.W(53)) u_sig_tz (.x(sig_rev), .cnt(sig_tz));
  // S -> D: leading zeros of a subnormal S fraction.
  logic [4:0] fs_lz;
  tg_fpu_lzc #(.W(23)) u_fs_lz (.x(ua.sig[51:29]), .cnt(fs_lz));

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
    logic [EXP_W-1:0] a_exp;
    logic [52:0] a_sig;
    // shared shifter
    logic [63:0] sh_in;
    logic [6:0]  sh_amt;
    logic [6:0]  sh_tz;          // trailing zeros of sh_in (shifter sticky)
    logic        fi_big;
    logic        ds_sub;
    logic        if_neg, if_zero;
    logic [6:0]  if_lz, if_tz;
    logic [4:0]  fs_lz;
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
    m0.a_exp = ua.exp; m0.a_sig = ua.sig;
    m0.fi_big = fi_big; m0.ds_sub = ds_sub;
    m0.if_neg = if_neg; m0.if_zero = (if_x == '0); m0.if_lz = if_lz; m0.if_tz = if_tz;
    m0.fs_lz = fs_lz;
    if (q.op == FOP_FCVT_F_I) begin
      // |x| << (L - 1) never overflows; M1 adds the last place when |x| is not -(-2^k)
      m0.sh_in  = if_abs_rev;
      m0.sh_amt = (if_lz == '0) ? 7'd0 : if_lz - 7'd1;
      m0.sh_tz  = '0;
    end else begin
      m0.sh_in  = {ua.sig, 11'b0};
      m0.sh_amt = (q.op == FOP_FCVT_I_F) ? fi_amt : ds_amt;
      m0.sh_tz  = (ua.sig == '0) ? 7'd64 : 7'(sig_tz) + 7'd11;
    end
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

  // ---- Shared shifter ----
  logic [63:0] so;
  logic        so_g, so_s;
  always_comb begin
    so   = (m.sh_amt >= 7'd64) ? 64'b0 : (m.sh_in >> m.sh_amt[5:0]);
    so_g = (m.sh_amt == '0 || m.sh_amt > 7'd64) ? 1'b0 : m.sh_in[6'(m.sh_amt - 7'd1)];
    so_s = (m.sh_amt >= 7'd2) && ({1'b0, m.sh_tz} < {1'b0, m.sh_amt} - 8'd1);
  end

  // ---- FCVT.I.F: round, negate, range check, saturate ----
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

  // ---- FCVT.F.I: finish normalising ----
  logic [63:0] if_n;             // |x| with its MSB at bit 63
  logic [6:0]  if_l;             // leading zeros of |x|
  always_comb begin
    logic [63:0] n0;
    for (int i = 0; i < 64; i++) n0[i] = so[63-i];
    if (n0[63] || m.if_lz == '0) begin if_n = n0;      if_l = m.sh_amt; end
    else                         begin if_n = n0 << 1; if_l = m.sh_amt + 7'd1; end
  end

  // ---- Rounding and packing: D for FCVT.F.I, S shared by FCVT.F.I and FCVT.S.D ----
  logic [31:0] pk_s;
  logic [62:0] pk_d;
  logic [63:0] if_res, ff_res;
  logic [4:0]  if_fl, ff_fl;
  always_comb begin
    logic if_g, if_st, inc_d, inc_s, ds_tiny, ds_ovf, ds_inexact;
    logic [7:0]  es;             // S exponent field - 1, or 0 for an S subnormal
    logic [23:0] ts;
    logic [51:0] sd_fr;
    logic [10:0] sd_e;
    // integer -> FP sticky: bits below the guard are |x|'s bits 0 .. 63 - l - p - 1
    if_g  = m.dbl ? if_n[10] : if_n[39];
    if_st = m.dbl ? ({1'b0, m.if_tz} + {1'b0, if_l} < 8'd10) : ({1'b0, m.if_tz} + {1'b0, if_l} < 8'd39);
    inc_d = round_up(m.rm, m.if_neg, if_n[11], if_g, if_st);
    pk_d  = ({52'b0, 11'(D_BIAS + 62) - 11'(if_l)} << 52) + {10'b0, if_n[63:11]} + 63'(inc_d);
    if (m.op == FOP_FCVT_F_I) begin
      es    = 8'(S_BIAS + 62) - 8'(if_l);
      ts    = if_n[63:40];
      inc_s = round_up(m.rm, m.if_neg, if_n[40], if_g, if_st);
    end else begin
      es    = m.ds_sub ? 8'd0 : 8'(m.a_exp - 11'(S2D + 1));
      ts    = so[23:0];
      inc_s = round_up(m.rm, m.a_sign, so[0], so_g, so_s);
    end
    pk_s = ({24'b0, es} << 23) + {8'b0, ts} + 32'(inc_s);

    // integer -> FP
    if (m.dbl) if_res = m.if_zero ? 64'b0 : {m.if_neg, pk_d};
    else       if_res = m.if_zero ? box_s(32'b0) : box_s({m.if_neg, pk_s[30:0]});
    if_fl = '0;
    if_fl[FL_NX] = !m.if_zero && (if_g || if_st);

    // FP -> FP
    ds_inexact = so_g || so_s;
    // tiny after rounding: an S result below 2^-126 unless rounding to 24 bits reaches it
    ds_tiny = m.ds_sub && !(m.a_exp == 11'(S2D) && (&m.a_sig[52:29]) &&
                            round_up(m.rm, m.a_sign, 1'b1, m.a_sig[28], |m.a_sig[27:0]));
    ds_ovf  = (m.a_exp > 11'(S2D + 254)) || (pk_s[30:23] == 8'hFF);
    sd_fr   = m.a_sub ? {m.a_sig[50:29] << m.fs_lz, 30'b0} : m.a_sig[51:0];
    sd_e    = m.a_sub ? 11'(S2D) - 11'(m.fs_lz) : m.a_exp;
    ff_fl   = '0;
    if (m.dbl) begin                                // S -> D, exact
      if (m.a_nan)       ff_res = CNAN_D;
      else if (m.a_inf)  ff_res = inf_value(1'b1, m.a_sign);
      else if (m.a_zero) ff_res = zero_value(1'b1, m.a_sign);
      else               ff_res = {m.a_sign, sd_e, sd_fr};
      ff_fl[FL_NV] = m.a_snan;
    end else begin                                  // D -> S
      if (m.a_nan)       ff_res = CNAN_S;
      else if (m.a_inf)  ff_res = inf_value(1'b0, m.a_sign);
      else if (m.a_zero) ff_res = zero_value(1'b0, m.a_sign);
      else if (ds_ovf)   ff_res = ovf_value(1'b0, m.a_sign, ovf_to_inf(m.rm, m.a_sign));
      else               ff_res = box_s({m.a_sign, pk_s[30:0]});
      if (m.a_nan) ff_fl[FL_NV] = m.a_snan;
      else if (!m.a_inf && !m.a_zero) begin
        ff_fl[FL_OF] = ds_ovf;
        ff_fl[FL_NX] = ds_inexact || ds_ovf;
        ff_fl[FL_UF] = ds_tiny && ds_inexact && !ds_ovf;
      end
    end
  end

  // ---- Result select and output register ----
  fpu_resp_t r;
  always_comb begin
    r.tag = m.tag;
    r.int_dest = (m.op inside {FOP_FEQ, FOP_FLT, FOP_FLE, FOP_FCLASS, FOP_FCVT_I_F, FOP_FMV_X_F});
    unique case (m.op)
      FOP_FCVT_I_F: begin r.result = fi_res; r.fflags = fi_fl; end
      FOP_FCVT_F_I: begin r.result = if_res; r.fflags = if_fl; end
      FOP_FCVT_F_F: begin r.result = ff_res; r.fflags = ff_fl; end
      default:      begin r.result = simple_res; r.fflags = simple_fl; end
    endcase
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
  assign unused = ^{q.c, ub.exp, ub.sig, ub.inf, ub.sub, pk_s[31], if_n[9:0]};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && valid_i) begin
      assert (q.fmt != FMT_H) else $error("tg_fpu_misc: FMT_H is not implemented");
      assert (q.op inside {FOP_FSGNJ, FOP_FSGNJN, FOP_FSGNJX, FOP_FMIN, FOP_FMAX, FOP_FEQ, FOP_FLT,
                           FOP_FLE, FOP_FCLASS, FOP_FCVT_F_F, FOP_FCVT_I_F, FOP_FCVT_F_I,
                           FOP_FMV_X_F, FOP_FMV_F_X})
        else $error("tg_fpu_misc: operation %0d belongs to another unit", q.op);
    end
  end
`endif

endmodule
