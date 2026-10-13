// FMISC unit: sign injection, min/max, compares, classify, moves and conversions
// (docs/spec/fpu.md, "FMISC unit"). Two stages, M0 (request cycle) and M1; the response is
// registered and appears exactly FMISC_LAT = 2 cycles after the request.
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

  // Raw values as the format reads them (S unboxed; an improperly boxed S is the canonical NaN).
  logic [63:0] ra, rb;
  assign ra = dbl ? q.a : {32'b0, unbox_s(q.a)};
  assign rb = dbl ? q.b : {32'b0, unbox_s(q.b)};

  // ---- Sign injection ----
  logic sj_sign;
  logic [63:0] sgnj_res;
  always_comb begin
    unique case (q.op)
      FOP_FSGNJN: sj_sign = !ub.sign;
      FOP_FSGNJX: sj_sign = ua.sign ^ ub.sign;
      default:    sj_sign = ub.sign;
    endcase
    sgnj_res = dbl ? {sj_sign, ra[62:0]} : box_s({sj_sign, ra[30:0]});
  end

  // ---- Compares, min/max ----
  logic [62:0] mag_a, mag_b;
  assign mag_a = dbl ? ra[62:0] : {32'b0, ra[30:0]};
  assign mag_b = dbl ? rb[62:0] : {32'b0, rb[30:0]};
  logic mag_lt, mag_eq, both_zero, a_lt_b, a_eq_b, any_nan, any_snan;
  assign mag_lt    = mag_a < mag_b;
  assign mag_eq    = mag_a == mag_b;
  assign both_zero = ua.zero && ub.zero;
  assign a_eq_b    = both_zero || (ua.sign == ub.sign && mag_eq);
  always_comb begin
    unique case ({ua.sign, ub.sign})
      2'b00:   a_lt_b = mag_lt;
      2'b11:   a_lt_b = !mag_lt && !mag_eq;
      2'b10:   a_lt_b = !both_zero;
      default: a_lt_b = 1'b0;
    endcase
  end
  assign any_nan  = ua.nan || ub.nan;
  assign any_snan = ua.snan || ub.snan;

  logic cmp_res, cmp_nv;
  always_comb begin
    unique case (q.op)
      FOP_FEQ: begin cmp_res = !any_nan && a_eq_b;             cmp_nv = any_snan; end
      FOP_FLT: begin cmp_res = !any_nan && a_lt_b;             cmp_nv = any_nan;  end
      default: begin cmp_res = !any_nan && (a_lt_b || a_eq_b); cmp_nv = any_nan;  end
    endcase
  end

  // FMIN/FMAX per F 2.2 (IEEE 754-2019 minimumNumber/maximumNumber): -0 < +0; a NaN loses.
  logic pick_a;
  logic [63:0] minmax_res;
  always_comb begin
    pick_a = (a_lt_b || (a_eq_b && ua.sign)) ^ (q.op == FOP_FMAX);
    if (ua.nan && ub.nan) minmax_res = cnan(dbl);
    else if (ua.nan)      minmax_res = dbl ? rb : box_s(rb[31:0]);
    else if (ub.nan)      minmax_res = dbl ? ra : box_s(ra[31:0]);
    else                  minmax_res = pick_a ? (dbl ? ra : box_s(ra[31:0])) : (dbl ? rb : box_s(rb[31:0]));
  end

  // ---- Classify ----
  logic [9:0] class_res;
  always_comb begin
    class_res = '0;
    class_res[0] = ua.inf && ua.sign;
    class_res[1] = !ua.inf && !ua.nan && !ua.zero && !ua.sub && ua.sign;
    class_res[2] = ua.sub && ua.sign;
    class_res[3] = ua.zero && ua.sign;
    class_res[4] = ua.zero && !ua.sign;
    class_res[5] = ua.sub && !ua.sign;
    class_res[6] = !ua.inf && !ua.nan && !ua.zero && !ua.sub && !ua.sign;
    class_res[7] = ua.inf && !ua.sign;
    class_res[8] = ua.snan;
    class_res[9] = ua.nan && !ua.snan;
  end

  // ---- Moves ----
  logic [63:0] fmv_res;
  always_comb begin
    if (q.op == FOP_FMV_X_F) fmv_res = dbl ? q.a : {{32{q.a[31]}}, q.a[31:0]};
    else                     fmv_res = dbl ? q.a : box_s(q.a[31:0]);
  end

  // ---- FCVT.I.F, first half: integer part of |a| with guard and sticky ----
  // The significand sits at the top of a 64-bit window V (MSB weight 2^E); the integer part is
  // V >> (63 - E). sh < 0 means |a| >= 2^64.
  logic signed [12:0] fi_sh;
  logic        fi_big;           // |a| >= 2^64 (or infinity)
  logic [63:0] fi_int;
  logic        fi_g, fi_s;
  always_comb begin
    logic [63:0] v;
    logic [6:0]  sh;
    logic [127:0] w;
    fi_sh  = 13'sd1086 - $signed({2'b00, ua.exp});
    fi_big = ua.inf || (fi_sh < 0);
    v      = {ua.sig, 11'b0};
    sh     = (fi_sh > 13'sd65) ? 7'd65 : fi_sh[6:0];
    w      = {v, 64'b0} >> sh;
    fi_int = w[127:64];
    fi_g   = w[63];
    fi_s   = |w[62:0];
  end

  // ---- FCVT.F.I, first half: |x|, leading zeros of x ^ sign, trailing zeros ----
  logic        if_neg;
  logic [63:0] if_x, if_abs;
  logic [6:0]  if_lz, if_tz;
  always_comb begin
    unique case (q.ifmt)
      IFMT_W:  begin if_x = {{32{q.a[31]}}, q.a[31:0]}; if_neg = q.a[31]; end
      IFMT_WU: begin if_x = {32'b0, q.a[31:0]};         if_neg = 1'b0;    end
      IFMT_L:  begin if_x = q.a;                        if_neg = q.a[63]; end
      default: begin if_x = q.a;                        if_neg = 1'b0;    end
    endcase
    if_abs = if_neg ? -if_x : if_x;
  end
  logic [63:0] if_x_rev;
  always_comb for (int i = 0; i < 64; i++) if_x_rev[i] = if_x[63-i];
  // lzc(x ^ sign) is lzc(|x|) except for x = -2^k, where |x| has one leading zero fewer;
  // M1 corrects that case. The trailing-zero count is the same for x and -x.
  tg_fpu_lzc #(.W(64)) u_if_lz (.x(if_x ^ {64{if_neg}}), .cnt(if_lz));
  tg_fpu_lzc #(.W(64)) u_if_tz (.x(if_x_rev), .cnt(if_tz));

  // ---- FCVT.F.F, first half ----
  // S -> D: leading zeros of a subnormal S fraction. D -> S: S exponent, right shift by k for
  // S-subnormal results, (T, G, S) at the result grid, plus the normal-precision bits for the
  // tininess test.
  logic [4:0] fs_lz;
  always_comb begin
    fs_lz = 5'd23;
    for (int i = 0; i < 23; i++)
      if (ua.sig[29 + i]) fs_lz = 5'(22 - i);
  end
  logic signed [12:0] fd_e;      // unbiased exponent of a (D source)
  logic        fd_sub;           // result below the S normal range
  logic [23:0] fd_t;             // kept significand bits (24 normal, fewer when subnormal)
  logic        fd_g, fd_st;
  logic        fd_tn_ones, fd_gn, fd_sn;   // normal-precision bits for tininess after rounding
  always_comb begin
    logic signed [12:0] k;
    logic [5:0] ks;
    logic [79:0] w;
    fd_e   = $signed({2'b00, ua.exp}) - 13'sd1023;
    fd_sub = fd_e < -13'sd126;
    k      = -13'sd126 - fd_e;
    ks     = (!fd_sub) ? 6'd0 : (k > 13'sd27) ? 6'd27 : k[5:0];
    w      = {ua.sig, 27'b0} >> ks;           // 53 + 27 bits; T = w[79:56]
    fd_t   = w[79:56];
    fd_g   = w[55];
    fd_st  = |w[54:0];
    fd_tn_ones = &ua.sig[52:29];
    fd_gn  = ua.sig[28];
    fd_sn  = |ua.sig[27:0];
  end

  // ---- M0 -> M1 register ----
  typedef struct packed {
    fop_e        op;
    logic        dbl;
    logic        src_dbl;
    ifmt_e       ifmt;
    rm_e         rm;
    logic [FPU_TAG_W-1:0] tag;
    logic [63:0] res0;           // finished result of the simple operations
    logic [4:0]  fl0;
    logic        a_sign, a_nan, a_snan, a_inf, a_zero, a_sub;
    logic [EXP_W-1:0] a_exp;
    logic [SIG_W-1:0] a_sig;
    // FCVT.I.F
    logic        fi_big;
    logic [63:0] fi_int;
    logic        fi_g, fi_s;
    // FCVT.F.I
    logic        if_neg;
    logic [63:0] if_abs;
    logic [6:0]  if_lz, if_tz;
    // FCVT.F.F
    logic [4:0]  fs_lz;
    logic [12:0] fd_e;           // signed
    logic        fd_sub;
    logic [23:0] fd_t;
    logic        fd_g, fd_st, fd_tn_ones, fd_gn, fd_sn;
  } m1_t;

  m1_t m0, m1_q;
  logic v1_q;

  always_comb begin
    m0 = '0;
    m0.op = q.op; m0.dbl = dbl; m0.src_dbl = src_dbl; m0.ifmt = q.ifmt; m0.rm = q.rm; m0.tag = q.tag;
    m0.a_sign = ua.sign; m0.a_nan = ua.nan; m0.a_snan = ua.snan; m0.a_inf = ua.inf;
    m0.a_zero = ua.zero; m0.a_sub = ua.sub; m0.a_exp = ua.exp; m0.a_sig = ua.sig;
    m0.fi_big = fi_big; m0.fi_int = fi_int; m0.fi_g = fi_g; m0.fi_s = fi_s;
    m0.if_neg = if_neg; m0.if_abs = if_abs; m0.if_lz = if_lz; m0.if_tz = if_tz;
    m0.fs_lz = fs_lz; m0.fd_e = fd_e; m0.fd_sub = fd_sub; m0.fd_t = fd_t; m0.fd_g = fd_g; m0.fd_st = fd_st;
    m0.fd_tn_ones = fd_tn_ones; m0.fd_gn = fd_gn; m0.fd_sn = fd_sn;
    unique case (q.op)
      FOP_FSGNJ, FOP_FSGNJN, FOP_FSGNJX: m0.res0 = sgnj_res;
      FOP_FMIN, FOP_FMAX: begin m0.res0 = minmax_res; m0.fl0[FL_NV] = any_snan; end
      FOP_FEQ, FOP_FLT, FOP_FLE: begin m0.res0 = {63'b0, cmp_res}; m0.fl0[FL_NV] = cmp_nv; end
      FOP_FCLASS: m0.res0 = {54'b0, class_res};
      FOP_FMV_X_F, FOP_FMV_F_X: m0.res0 = fmv_res;
      default: m0.res0 = '0;
    endcase
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

  // ---- FCVT.I.F: round, negate, range check, saturate ----
  logic [63:0] fi_res;
  logic [4:0]  fi_fl;
  always_comb begin
    logic inc, ovf, nv;
    logic [64:0] mag;
    logic [63:0] sum, maxv, minv;
    inc = round_up(m.rm, m.a_sign, m.fi_int[0], m.fi_g, m.fi_s);
    mag = {1'b0, m.fi_int} + 65'(inc);
    sum = (m.a_sign ? ~m.fi_int : m.fi_int) + 64'(m.a_sign ? !inc : inc);
    unique case (m.ifmt)
      IFMT_W: begin
        ovf  = m.a_sign ? (mag > 65'h0_8000_0000) : (mag >= 65'h0_8000_0000);
        maxv = 64'h0000_0000_7FFF_FFFF; minv = 64'hFFFF_FFFF_8000_0000;
      end
      IFMT_WU: begin
        ovf  = m.a_sign ? (mag != '0) : (mag >= 65'h1_0000_0000);
        maxv = 64'hFFFF_FFFF_FFFF_FFFF; minv = 64'h0;
      end
      IFMT_L: begin
        ovf  = m.a_sign ? (mag > 65'h0_8000_0000_0000_0000) : (mag >= 65'h0_8000_0000_0000_0000);
        maxv = 64'h7FFF_FFFF_FFFF_FFFF; minv = 64'h8000_0000_0000_0000;
      end
      default: begin
        ovf  = m.a_sign ? (mag != '0) : mag[64];
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
    fi_fl[FL_NX] = !nv && (m.fi_g || m.fi_s);
  end

  // ---- FCVT.F.I: normalise, round, pack ----
  logic [64:0] if_n65;
  logic [63:0] if_n;             // |x| shifted so its MSB is bit 63
  logic [6:0]  if_l;             // true leading-zero count of |x|
  always_comb begin
    if_n65 = {1'b0, m.if_abs} << m.if_lz;
    if (if_n65[64]) begin if_n = if_n65[64:1]; if_l = m.if_lz - 7'd1; end
    else            begin if_n = if_n65[63:0]; if_l = m.if_lz;         end
  end
  logic [63:0] if_res;
  logic [4:0]  if_fl;
  logic [62:0] if_pk_d;
  logic [30:0] if_pk_s;
  always_comb begin
    logic g, s, inc;
    // Sticky: the bits below the guard of the normalised value are the original bits 0 up to
    // 63 - l - p - 1; one of them is set when tz + l < 63 - p.
    if (m.dbl) begin
      g = if_n[10];
      s = ({1'b0, m.if_tz} + {1'b0, if_l}) < 8'd10;
      inc = round_up(m.rm, m.if_neg, if_n[11], g, s);
    end else begin
      g = if_n[39];
      s = ({1'b0, m.if_tz} + {1'b0, if_l}) < 8'd39;
      inc = round_up(m.rm, m.if_neg, if_n[40], g, s);
    end
    // pack as {exponent - 1, significand with hidden bit} + increment; the exponent is
    // bias + 63 - l and cannot overflow
    if_pk_d = ({52'b0, 11'(D_BIAS + 62) - 11'(if_l)} << 52) + {10'b0, if_n[63:11]} + 63'(inc);
    if_pk_s = ({23'b0, 8'(S_BIAS + 62) - 8'(if_l)} << 23) + {7'b0, if_n[63:40]} + 31'(inc);
    if (m.dbl) if_res = (m.if_abs == '0) ? 64'b0 : {m.if_neg, if_pk_d};
    else       if_res = (m.if_abs == '0) ? box_s(32'b0) : box_s({m.if_neg, if_pk_s});
    if_fl = '0;
    if_fl[FL_NX] = g || s;
  end

  // ---- FCVT.F.F ----
  logic [63:0] ff_res;
  logic [4:0]  ff_fl;
  logic [31:0] ds_packed;
  always_comb begin
    logic [51:0] sd_fr;          // S -> D fraction and exponent field
    logic [10:0] sd_e;
    logic        ds_inc, ds_tiny, ds_inexact, ds_ovf;
    logic [8:0]  ds_ebase;       // D -> S: exponent field - 1 (normal) or 0 (subnormal)
    // S -> D: exact; a subnormal S operand is normalised
    if (m.a_sub) begin
      sd_fr = {m.a_sig[51:29] << (m.fs_lz + 5'd1), 29'b0};
      sd_e  = 11'(S2D) - 11'(m.fs_lz);
    end else begin
      sd_fr = m.a_sig[51:0];
      sd_e  = m.a_exp;
    end
    // D -> S: round to 24 bits
    ds_inc     = round_up(m.rm, m.a_sign, m.fd_t[0], m.fd_g, m.fd_st);
    ds_ebase   = m.fd_sub ? 9'd0 : 9'($signed(m.fd_e) + 13'sd126);
    ds_packed  = ({23'b0, ds_ebase} << 23) + {8'b0, m.fd_t} + 32'(ds_inc);
    ds_inexact = m.fd_g || m.fd_st;
    ds_tiny    = m.fd_sub && !($signed(m.fd_e) == -13'sd127 && m.fd_tn_ones &&
                               round_up(m.rm, m.a_sign, 1'b1, m.fd_gn, m.fd_sn));
    ds_ovf     = ($signed(m.fd_e) > 13'sd127) || (ds_packed[30:23] == 8'hFF);
    ff_fl = '0;
    if (m.dbl) begin
      if (m.a_nan)       ff_res = CNAN_D;
      else if (m.a_inf)  ff_res = inf_value(1'b1, m.a_sign);
      else if (m.a_zero) ff_res = zero_value(1'b1, m.a_sign);
      else               ff_res = {m.a_sign, sd_e, sd_fr};
      ff_fl[FL_NV] = m.a_snan;
    end else begin
      if (m.a_nan)       ff_res = CNAN_S;
      else if (m.a_inf)  ff_res = inf_value(1'b0, m.a_sign);
      else if (m.a_zero) ff_res = zero_value(1'b0, m.a_sign);
      else if (ds_ovf)   ff_res = ovf_value(1'b0, m.a_sign, ovf_to_inf(m.rm, m.a_sign));
      else               ff_res = box_s({m.a_sign, ds_packed[30:0]});
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
      default:      begin r.result = m.res0; r.fflags = m.fl0; end
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
  assign unused = ^{q.c, ub.exp, ub.sig, ub.inf, ub.sub, m.src_dbl, if_n[9:0], ds_packed[31]};

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
