// FMA unit: (+-a x b) +- c with one rounding, for FADD, FSUB, FMUL, FMADD, FMSUB, FNMSUB, FNMADD
// in S and D (docs/spec/fpu.md, "FMA unit"), and, by lever R5, the FP->FP and integer->FP
// conversions, which reuse its normaliser and rounder:
//   FCVT.F.F  a x 1.0 with no addend, a in src_fmt, rounded to fmt
//   FCVT.F.I  x placed in the adder at V[164:101] (V[164] weighs 2^63), the product off; a
//             negative x goes through the subtraction path, which yields -x
// Single-path datapath with the addend aligned in a window to the left of the product; five
// stages E0..E4, response FMA_LAT = 5 cycles after the request.
//
// Window coordinates ("V"): V[164:1] is the window (product in V[109:4], addend from
// V[164:112] downwards), V[0] collects the sticky of whatever falls below it, and bit 165 is the
// sign of the two's-complement difference. The three bits below the product's LSB keep the
// round bit inside the window when a multiplicand is a subnormal with one or two significant
// bits (the product then sits up to 53 places below its nominal position).
module tg_fpu_fma
  import tg_pkg::*;
  import tg_fpu_pkg::*;
  import tg_fpu_util_pkg::*;
#(
  // 5: E0..E4 as specified. 4: the E3/E4 boundary is removed (the plan's 4-cycle option,
  // kept for timing experiments; the core's FMA_LAT must match).
  parameter int STAGES = FMA_LAT
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       valid_i,
  input  fpu_req_t   req_i,
  output logic       valid_o,
  output fpu_resp_t  resp_o
);
  localparam int VW = 165;               // V[164:0]
  localparam int SH_MAX = 165;           // addend shifted entirely into the sticky

  // ------------------------------------------------------------------------------------------
  // E0: unpack, specials, exponents, DSP operand registers
  // ------------------------------------------------------------------------------------------
  fpu_req_t q;
  assign q = req_i;

  logic dbl, sdbl, cvt_f, cvt_i, is_add, one_b, has_c, neg_prod, neg_add;
  assign dbl      = (q.fmt == FMT_D);                    // result format
  assign cvt_f    = (q.op == FOP_FCVT_F_F);
  assign cvt_i    = (q.op == FOP_FCVT_F_I);
  assign sdbl     = cvt_f ? (q.src_fmt == FMT_D) : dbl;  // format of the FP operands
  assign is_add   = (q.op == FOP_FADD) || (q.op == FOP_FSUB);
  assign one_b    = is_add || cvt_f;                     // b reads as 1.0
  assign has_c    = !(q.op == FOP_FMUL || cvt_f || cvt_i);
  assign neg_prod = (q.op == FOP_FNMSUB) || (q.op == FOP_FNMADD);
  assign neg_add  = (q.op == FOP_FSUB) || (q.op == FOP_FMSUB) || (q.op == FOP_FNMADD);

  fp_unp_t ua, ub, uc, ub_raw, uc_raw;
  assign ua     = unpack(q.a, sdbl);
  assign ub_raw = unpack(q.b, sdbl);
  assign uc_raw = unpack(q.c, sdbl);
  always_comb begin
    // FADD/FSUB: a x 1.0 + c (P4 reads rs2 into c); FCVT.F.F: a x 1.0
    if (one_b) begin
      ub = '0;
      ub.exp = EXP_W'(D_BIAS);
      ub.sig = {1'b1, 52'b0};
    end else begin
      ub = ub_raw;
    end
    uc = uc_raw;
  end

  // FCVT.F.I: the integer source in a, sign-extended or zero-extended per ifmt
  logic        x_neg;
  logic [63:0] x_val;
  always_comb begin
    unique case (q.ifmt)
      IFMT_W:  begin x_val = {{32{q.a[31]}}, q.a[31:0]}; x_neg = q.a[31]; end
      IFMT_WU: begin x_val = {32'b0, q.a[31:0]};         x_neg = 1'b0;    end
      IFMT_L:  begin x_val = q.a;                        x_neg = q.a[63]; end
      default: begin x_val = q.a;                        x_neg = 1'b0;    end
    endcase
  end

  logic sp, sc, eff_sub;
  assign sp      = cvt_i ? x_neg : (ua.sign ^ ub.sign ^ neg_prod);
  assign sc      = uc.sign ^ neg_add;
  // FCVT.F.I: a negative x enters the adder as itself (two's complement) and leaves as -x, through
  // the effective-subtraction path, so it needs no negation of its own
  assign eff_sub = cvt_i ? x_neg : (has_c && (sp != sc));

  // Special results, decided here and substituted in E4 (a kind and a sign).
  logic  prod_zero, c_zero, inf_x_zero, prod_inf, c_inf, nan_in, snan_in, inf_m_inf;
  spec_e spec;
  logic  spec_nv, spec_sign;
  always_comb begin
    prod_zero  = ua.zero || ub.zero;
    c_zero     = !has_c || uc.zero;
    inf_x_zero = (ua.inf && ub.zero) || (ua.zero && ub.inf);
    nan_in     = ua.nan || ub.nan || (has_c && uc.nan);
    snan_in    = ua.snan || ub.snan || (has_c && uc.snan);
    prod_inf   = (ua.inf || ub.inf) && !inf_x_zero && !ua.nan && !ub.nan;
    c_inf      = has_c && uc.inf;
    inf_m_inf  = prod_inf && c_inf && (sp != sc);
    spec_nv    = snan_in || inf_x_zero || inf_m_inf;
    spec_sign  = 1'b0;
    if (cvt_i) begin                       // integer source: only zero is special (+0)
      spec     = (x_val == '0) ? SPEC_ZERO : SPEC_NONE;
      spec_nv  = 1'b0;
    end
    else if (nan_in || inf_x_zero || inf_m_inf) spec = SPEC_NAN;
    else if (prod_inf) begin spec = SPEC_INF; spec_sign = sp; end
    else if (c_inf)    begin spec = SPEC_INF; spec_sign = sc; end
    else if (prod_zero && c_zero) begin    // exact zero: x + x keeps the sign; +0 - +0 is +0 (RDN: -0)
      spec      = SPEC_ZERO;
      spec_sign = !has_c ? sp : (sp == sc) ? sp : (q.rm == RM_RDN);
    end
    else spec = SPEC_NONE;
  end

  // Exponents. E0 only forms the sums, straight from the encoding fields (a subnormal field reads
  // 1) with the operand format's bias folded into constants; E1 clamps and selects (double bias):
  //   ep  = ea + eb - bias        product exponent      (S: + 896 to reach double bias)
  //   shr = ep - ec + 56          right shift of the addend, from V[164:112]
  logic [10:0] fa_e, fb_e, fc_e;
  // (an improperly boxed S operand is a NaN, whose result ignores these exponents)
  always_comb begin
    logic [10:0] ra, rb, rc;
    ra = sdbl ? q.a[62:52] : {3'b0, q.a[30:23]};
    rb = one_b ? (sdbl ? 11'd1023 : 11'd127) : (sdbl ? q.b[62:52] : {3'b0, q.b[30:23]});
    rc = sdbl ? q.c[62:52] : {3'b0, q.c[30:23]};
    fa_e = (ra == '0) ? 11'd1 : ra;
    fb_e = (rb == '0) ? 11'd1 : rb;
    fc_e = (rc == '0) ? 11'd1 : rc;
  end
  logic signed [13:0] ep0, shr0, ec0;
  assign ep0  = $signed({3'b0, fa_e}) + $signed({3'b0, fb_e}) + (sdbl ? -14'sd1023 : 14'sd769);
  assign shr0 = $signed({3'b0, fa_e}) + $signed({3'b0, fb_e}) - $signed({3'b0, fc_e})
              + (sdbl ? -14'sd967 : -14'sd71);
  assign ec0  = $signed({3'b0, fc_e}) + (sdbl ? 14'sd0 : 14'sd896);

  // ---- E0 -> E1 registers ----
  typedef struct packed {
    logic        dbl;
    rm_e         rm;
    logic [FPU_TAG_W-1:0] tag;
    spec_e       spec;
    logic        spec_nv, spec_sign;
    logic        sp, sc, eff_sub, prod_sticky;
    logic        prod_zero, c_zero;
    logic        cvt_i;         // FCVT.F.I: the adder takes x instead of the product and addend
    logic [13:0] ep, shr, ec;   // signed (E0 -> E1)
    logic [13:0] e_top, lim;    // signed (from E1)
  } ctl_t;

  // Flip-flops, not shift-register LUTs (shreg_extract): LUTs are the scarce resource, and an SRL
  // input's setup time would lengthen E0.
  ctl_t c0;
  (* shreg_extract = "no" *) ctl_t c1_q, c2_q, c3_q;
  logic v1_q, v2_q, v3_q, v4_q;
  always_comb begin
    c0.dbl = dbl; c0.rm = q.rm; c0.tag = q.tag;
    c0.spec = spec; c0.spec_nv = spec_nv; c0.spec_sign = spec_sign;
    c0.sp = sp; c0.sc = sc; c0.eff_sub = eff_sub; c0.prod_sticky = 1'b0;
    c0.prod_zero = prod_zero; c0.c_zero = c_zero;
    c0.cvt_i = cvt_i;
    c0.ep = ep0; c0.shr = shr0; c0.ec = ec0;
    c0.e_top = '0; c0.lim = '0;
  end

  // Multiplier operands: fa = ma[51:0] in two 26-bit chunks (27-bit DSP port), fb[50:0] in
  // three 17-bit chunks (18-bit port); fb[51] and the hidden bits form the "rows" added through
  // the C ports of two tiles.
  logic [25:0] a0_q, a1_q;
  logic [16:0] b0_q, b1_q, b2_q;
  logic [51:0] fa_q, fb_q;
  logic        ha_q, hb_q;
  logic [52:0] mc_q;
  logic [63:0] x_q;
  // Zeros come from the registers' synchronous resets, not LUTs (fpga_friendly.md T7): an S
  // significand has nothing in bits 28:0; b reads as 1.0 (fraction 0) for FADD, FSUB and FCVT.F.F;
  // with no addend (FMUL, the conversions) mc is 0, and a zero addend's significand is 0 anyway
  (* direct_reset = "yes" *) logic zs, zsb, zc, zsc;
  assign zs  = !sdbl;
  assign zsb = !sdbl || one_b;
  assign zc  = !has_c;
  assign zsc = zs || zc;
  always_ff @(posedge clk) begin
    a0_q <= zs ? '0 : q.a[25:0];
    a1_q <= ua.sig[51:26];
    b0_q <= zsb ? '0 : q.b[16:0];
    b1_q <= ub.sig[33:17];
    b2_q <= ub.sig[50:34];
    fa_q[28:0]  <= zs ? '0 : q.a[28:0];
    fa_q[51:29] <= ua.sig[51:29];
    fb_q[28:0]  <= zsb ? '0 : q.b[28:0];
    fb_q[51:29] <= ub.sig[51:29];
    ha_q <= ua.sig[52];
    hb_q <= ub.sig[52];
    mc_q[28:0]  <= zsc ? '0 : q.c[28:0];
    mc_q[52:29] <= zc ? '0 : uc.sig[52:29];
    x_q  <= cvt_i ? x_val : '0;       // zero unless FCVT.F.I, so E1 can OR it into the addend
    c1_q <= c0;
  end

  // ------------------------------------------------------------------------------------------
  // E1: DSP tiles (A x B + C in one cycle) and addend alignment
  // ------------------------------------------------------------------------------------------
  // rows = fb[51]*fa + 2*(ha*fb + hb*fa) + 2^53*ha*hb, in units of 2^51 of the product: three
  // operands (the 2^53 bit sits above 2*ha*fb in the same operand), so one ternary adder
  logic [54:0] rows;
  assign rows = ({3'b0, fb_q[51] ? fa_q : 52'b0})
              + ({1'b0, ha_q && hb_q, ha_q ? fb_q : 52'b0, 1'b0})
              + ({2'b0, hb_q ? fa_q : 52'b0, 1'b0});

  // The tiles' output registers are reset (the DSP48E2 P-register reset) when the product does
  // not take part: FCVT.F.I, or an addend that dominates (the product is only a sticky).
  logic [42:0] t00_q, t01_q, t02_q, t10_q;
  logic [43:0] t11_q;
  logic [46:0] t12_q;
  logic        p_off;
  always_ff @(posedge clk) begin
    if (p_off) begin
      t00_q <= '0; t01_q <= '0; t02_q <= '0; t10_q <= '0; t11_q <= '0; t12_q <= '0;
    end else begin
      t00_q <= 43'(a0_q) * 43'(b0_q);
      t01_q <= 43'(a0_q) * 43'(b1_q);
      t02_q <= 43'(a0_q) * 43'(b2_q);
      t10_q <= 43'(a1_q) * 43'(b0_q);
      t11_q <= 44'(a1_q) * 44'(b1_q) + {27'b0, rows[8:0], 8'b0};   // frame 43: rows bits 59:51
      t12_q <= 47'(a1_q) * 47'(b2_q) + {1'b0, rows[54:9]};         // frame 60: rows bits 105:60
    end
  end

  // Window placement: the window's bit 160 has weight 2^(ep + 56) unless the addend dominates
  // (shr < 0), when it has the addend's weight and the product only contributes a sticky.
  logic [7:0] sh;
  ctl_t       c1x;
  always_comb begin
    c1x = c1_q;
    if (c1_q.cvt_i) begin                 // integer source: V[164] weighs 2^63
      sh = 8'(SH_MAX);
      c1x.e_top = 14'sd1086;
    end else if (c1_q.prod_zero) begin    // a zero product: the addend anchors the window
      sh = 8'd0;
      c1x.e_top = c1_q.ec;
    end else if (c1_q.c_zero) begin       // no addend: the product anchors
      sh = 8'(SH_MAX);
      c1x.e_top = 14'($signed(c1_q.ep) + 14'sd56);
    end else if ($signed(c1_q.shr) < 0) begin
      sh = 8'd0;
      c1x.e_top = c1_q.ec;
      c1x.prod_sticky = 1'b1;
    end else begin
      sh = ($signed(c1_q.shr) > 14'(SH_MAX)) ? 8'(SH_MAX) : c1_q.shr[7:0];
      c1x.e_top = 14'($signed(c1_q.ep) + 14'sd56);
    end
    // normalising may not take the exponent below emin (double bias: 1 for D, 897 for S)
    c1x.lim = 14'($signed(c1x.e_top) - (c1_q.dbl ? 14'sd1 : 14'sd897));
  end
  assign p_off = c1_q.cvt_i || c1x.prod_sticky;

  // Addend: mc at V[164:112], shifted right by sh; V[0] collects every bit at or below it.
  logic [VW-1:0] cal;
  tg_fpu_fma_align #(.W(VW)) u_align (.mc(mc_q), .sh, .cal);

  // FCVT.F.I: x itself at V[164:101], sign-extended into bit 165; E2 complements it for a negative
  // x (eff_sub), so |S| = -x. x_q is zero for every other operation, and the aligned addend is zero
  // for FCVT.F.I (it has none), so the two are ORed.
  logic [VW:0] cop_d, cop_q;    // addend operand of the adder: C or x (166 bits)
  assign cop_d = {c1_q.cvt_i && c1_q.sp, cal | {x_q, {(VW-64){1'b0}}}};
  always_ff @(posedge clk) begin
    cop_q <= cop_d;
    c2_q  <= c1x;
  end

  // The adder's upper part plus one (tg_fpu_fma_add: above LO only the addend contributes):
  // (cop ^ eff_sub)[VW:LO] + 1, in DSPs that keep their own copy of that register (T6). The XOR
  // shares its LUT with cop_d's OR.
  localparam int LO = 112;
  logic [VW-LO:0] hi1;
  tg_fpu_dsp_add #(.W(VW-LO+1)) u_hi1 (
    .clk, .ce(1'b1), .a(cop_d[VW:LO] ^ {(VW-LO+1){c1x.eff_sub}}), .b('0), .ci(1'b1), .s(hi1));

  // ------------------------------------------------------------------------------------------
  // E2: add. Six tiles and the addend reduce to three rows (one counter level), then two
  // ternary adders: X = P - C (= P + ~C + 1) and Y = X - 1. |P - C| is X, or ~Y when X < 0.
  // ------------------------------------------------------------------------------------------
  logic [VW-1:0] mag;
  logic          rsign;
  tg_fpu_fma_add #(.W(VW), .LO(LO)) u_add (
    .t00(t00_q), .t01(t01_q), .t02(t02_q), .t10(t10_q), .t11(t11_q), .t12(t12_q),
    .cop(cop_q), .hi1, .prod_sticky(c2_q.prod_sticky), .eff_sub(c2_q.eff_sub),
    .sp(c2_q.sp), .sc(c2_q.sc),
    .mag, .rsign
  );

  // The marker bit that limits normalisation at emin: V[164 - lim], decoded here from lim (known
  // since E1) as the AND of a one-hot of lim[7:4] (zero unless 0 <= lim < 165) and one of lim[3:0].
  logic [VW-1:0] marker_d;
  logic          below_d;        // window entirely below the subnormal range
  always_comb begin
    logic [10:0] mk_hi;
    logic [15:0] mk_lo;
    below_d = $signed(c2_q.lim) < 0;
    mk_hi   = (!below_d && $signed(c2_q.lim) < 14'(VW)) ? 11'(1) << c2_q.lim[7:4] : '0;
    mk_lo   = 16'(1) << c2_q.lim[3:0];
    for (int k = 0; k < VW; k++) marker_d[k] = mk_hi[(VW-1-k) >> 4] && mk_lo[(VW-1-k) & 15];
  end

  logic [VW-1:0] mag_q, marker_q;
  logic          rsign_q, below_q;
  always_ff @(posedge clk) begin
    mag_q    <= mag;
    rsign_q  <= rsign;
    marker_q <= marker_d;
    below_q  <= below_d;
    c3_q     <= c2_q;
  end

  // ------------------------------------------------------------------------------------------
  // E3: leading-zero count (limited at emin by a marker bit) and normalising left shift that
  // keeps 55 bits (significand, guard, round) plus a sticky.
  // ------------------------------------------------------------------------------------------
  logic [7:0]  lz;
  logic [54:0] nrm;
  logic        nst;
  tg_fpu_fma_norm #(.W(VW), .K(55)) u_norm (.x(mag_q), .marker(marker_q), .lz, .n(nrm), .st(nst));

  // Below the subnormal range the window holds a non-zero product (a window anchored at an
  // addend or a zero product never lies below emin), so its sticky is 1. An exact zero
  // (cancellation) is recognised in E4 as n = 0 with no sticky.
  logic [54:0] n_d, n_q;
  logic        st_d, st_q;
  logic [13:0] eres_d, eres_q;   // signed, double bias
  (* shreg_extract = "no" *) ctl_t c4_q;
  logic        rsign4_q;
  always_comb begin
    n_d    = below_q ? '0 : nrm;
    st_d   = below_q || nst;
    eres_d = below_q ? (c3_q.dbl ? 14'sd1 : 14'sd897) : 14'($signed(c3_q.e_top) - $signed({6'b0, lz}));
  end
  if (STAGES == 5) begin : g_e3_reg
    always_ff @(posedge clk) begin
      n_q <= n_d; st_q <= st_d; eres_q <= eres_d;
      c4_q <= c3_q; rsign4_q <= rsign_q;
    end
  end else begin : g_e3_comb
    assign n_q = n_d; assign st_q = st_d; assign eres_q = eres_d;
    assign c4_q = c3_q; assign rsign4_q = rsign_q;
  end

  // ------------------------------------------------------------------------------------------
  // E4: round, pack, overflow, specials
  // ------------------------------------------------------------------------------------------
  fpu_resp_t r;
  always_comb begin
    logic s, g, st, lsb, inc, inexact, tiny, ovf, tn_ones, gn, sn, zero;
    logic signed [13:0] ef;      // exponent in the result format's bias
    logic [62:0] pk_b, pk;
    logic [63:0] res;
    s = rsign4_q;
    zero = (n_q == '0) && !st_q;
    if (c4_q.dbl) begin
      lsb = n_q[2]; g = n_q[1]; st = n_q[0] || st_q;
      tn_ones = &n_q[53:1]; gn = n_q[0]; sn = st_q;
      ef = $signed(eres_q);
    end else begin
      lsb = n_q[31]; g = n_q[30]; st = (|n_q[29:0]) || st_q;
      tn_ones = &n_q[53:30]; gn = n_q[29]; sn = (|n_q[28:0]) || st_q;
      ef = $signed(eres_q) - 14'sd896;
    end
    inc     = round_up(c4_q.rm, s, lsb, g, st);
    inexact = g || st;
    // tiny after rounding: below 2^emin unless the normal-precision rounding reaches it
    tiny    = !n_q[54] && !(n_q[53] && tn_ones && round_up(c4_q.rm, s, 1'b1, gn, sn));
    // pack {exponent - 1 + hidden, fraction} + increment; a subnormal has exponent emin and no
    // hidden bit, so its field becomes 0 (or 1 if it rounds up to 2^emin). One adder serves both
    // formats: an S result is bits 59:29 of the D layout, and below bit 29 its operand is all
    // ones when rounding up, so the increment enters at bit 0 and carries into bit 29.
    pk_b = {10'b0, n_q[54:31], c4_q.dbl ? n_q[30:2] : {29{inc}}};
    pk   = ({49'b0, 14'(ef - 14'sd1)} << 52) + pk_b + 63'(inc);
    if (c4_q.dbl) ovf = (ef >= 14'sd2047) || (&pk[62:52]);
    else          ovf = (ef >= 14'sd255) || (&pk[59:52]);
    res = c4_q.dbl ? {s, pk} : box_s({s, pk[59:29]});
    r.fflags = '0;
    r.int_dest = 1'b0;
    r.tag = c4_q.tag;
    if (c4_q.spec != SPEC_NONE) begin
      r.result = spec_value(c4_q.spec, c4_q.dbl, c4_q.spec_sign);
      r.fflags[FL_NV] = c4_q.spec_nv;
    end else if (zero) begin
      // exact cancellation (sticky bits make any inexact difference non-zero)
      r.result = zero_value(c4_q.dbl, c4_q.rm == RM_RDN);
    end else if (ovf) begin
      r.result = ovf_value(c4_q.dbl, s, ovf_to_inf(c4_q.rm, s));
      r.fflags[FL_OF] = 1'b1;
      r.fflags[FL_NX] = 1'b1;
    end else begin
      r.result = res;
      r.fflags[FL_NX] = inexact;
      r.fflags[FL_UF] = tiny && inexact;
    end
  end

  fpu_resp_t resp_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      v1_q <= 1'b0; v2_q <= 1'b0; v3_q <= 1'b0; v4_q <= 1'b0; valid_o <= 1'b0;
    end else begin
      v1_q <= valid_i; v2_q <= v1_q; v3_q <= v2_q; v4_q <= v3_q;
      valid_o <= (STAGES == 5) ? v4_q : v3_q;
    end
    resp_q <= r;
  end
  assign resp_o = resp_q;

  logic unused;
  assign unused = ^{ua.sub, ub.sub, uc.sub, ua.snan, ub.inf, ua.exp, ub.exp, c3_q.lim,
                    ub_raw.sign, uc_raw, c4_q.e_top, c4_q.lim, c4_q.cvt_i, c3_q.cvt_i, c2_q.cvt_i,
                    c4_q.sp, c4_q.sc, c4_q.eff_sub, c4_q.prod_sticky, c4_q.prod_zero, c4_q.c_zero,
                    c4_q.ep, c4_q.shr, c4_q.ec, c3_q.prod_zero, c3_q.c_zero, c3_q.ep, c3_q.shr,
                    c3_q.ec, c2_q.prod_zero, c2_q.c_zero, c2_q.ep, c2_q.shr, c2_q.ec, c2_q.lim,
                    c2_q.e_top, c3_q.sp, c3_q.sc, c3_q.eff_sub, c3_q.prod_sticky, uc.exp};

  if (STAGES != 4 && STAGES != 5) begin : g_bad_stages
    $error("tg_fpu_fma: STAGES must be 4 or 5");
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && valid_i) begin
      assert (q.fmt != FMT_H) else $error("tg_fpu_fma: FMT_H is not implemented");
      assert (fpu_unit_of(q.op) == FU_FMA)
        else $error("tg_fpu_fma: operation %0d belongs to another unit", q.op);
    end
  end
`endif

endmodule
