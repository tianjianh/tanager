// Helpers shared by the FPU units (docs/spec/fpu.md, "Behaviour common to all units"):
// operand unpacking with the RISC-V NaN-boxing rule, rounding decisions, leading/trailing-zero
// counts and result constants. Owned by the FPU track.
package tg_fpu_util_pkg;
  import tg_pkg::*;
  import tg_fpu_pkg::*;

  localparam int SIG_W  = 53;     // significand field {hidden, fraction}; S uses bits 52:29
  localparam int EXP_W  = 11;     // exponent field width in double bias
  localparam int D_BIAS = 1023;
  localparam int S_BIAS = 127;
  localparam int S2D    = D_BIAS - S_BIAS;  // 896: rebias of S exponent fields

  localparam logic [63:0] CNAN_D = 64'h7FF8_0000_0000_0000;
  localparam logic [63:0] CNAN_S = 64'hFFFF_FFFF_7FC0_0000;  // boxed
  localparam logic [31:0] CNAN_S32 = 32'h7FC0_0000;

  // fflags bits
  localparam int FL_NX = 0;
  localparam int FL_UF = 1;
  localparam int FL_OF = 2;
  localparam int FL_DZ = 3;
  localparam int FL_NV = 4;

  typedef struct packed {
    logic              sign;
    logic [EXP_W-1:0]  exp;    // effective exponent field in double bias: subnormals read 1
    logic [SIG_W-1:0]  sig;    // {hidden, fraction}, not normalised
    logic              zero;
    logic              sub;    // subnormal (non-zero, exponent field 0)
    logic              inf;
    logic              nan;
    logic              snan;
  } fp_unp_t;

  // The value of a 64-bit FP register as format fmt reads it: an S operand whose bits 63:32 are
  // not all ones reads as the canonical NaN (RISC-V F, "NaN boxing").
  function automatic logic [31:0] unbox_s(input logic [63:0] x);
    return (&x[63:32]) ? x[31:0] : CNAN_S32;
  endfunction

  // A register's value as format dbl reads it, unpacked, for the units' first stages (operands
  // through P4's bypass). The classes come from the raw fields, with an S operand's box check ANDed
  // in last (an unboxed S operand reads as the canonical NaN: exponent all ones, quiet, fraction
  // not zero), so they do not wait for the unboxed value: four LUT levels, where forming them from
  // it took eight. The S fraction's zero check is a part of the D one's.
  function automatic fp_unp_t unpack(input logic [63:0] x, input logic dbl);
    fp_unp_t u;
    logic [31:0] s;
    logic [EXP_W-1:0] e;
    logic [SIG_W-2:0] f;
    logic box, lo0, emax, ez, fz, qb;
    s   = unbox_s(x);
    box = &x[63:32];
    lo0 = x[22:0] == '0;
    if (dbl) begin
      u.sign = x[63];
      e      = x[62:52];
      f      = x[51:0];
      emax   = &x[62:52];
      ez     = x[62:52] == '0;
      fz     = (x[51:23] == '0) && lo0;
      qb     = x[51];
    end else begin
      u.sign = s[31];
      e      = {3'b000, s[30:23]};
      f      = {s[22:0], 29'b0};
      emax   = !box || &x[30:23];
      ez     = box && x[30:23] == '0;
      fz     = box && lo0;
      qb     = !box || x[22];
    end
    u.zero = ez && fz;
    u.sub  = ez && !fz;
    u.inf  = emax && fz;
    u.nan  = emax && !fz;
    u.snan = u.nan && !qb;
    u.sig  = {e != '0, f};
    if (dbl) u.exp = (e == '0) ? EXP_W'(1) : e;
    else     u.exp = ((e == '0) ? EXP_W'(1) : e) + EXP_W'(S2D);
    return u;
  endfunction

  // unpack's value, with the classes formed from the unboxed value: more levels, but fewer LUTs
  // where they share logic with the significand and exponent (the dividers: the form above cost
  // them 58). For operands straight from registers.
  function automatic fp_unp_t unpack_lean(input logic [63:0] x, input logic dbl);
    fp_unp_t u;
    logic [31:0] s;
    logic [EXP_W-1:0] e;
    logic [SIG_W-2:0] f;
    logic emax;
    s = unbox_s(x);
    if (dbl) begin
      u.sign = x[63];
      e      = x[62:52];
      f      = x[51:0];
      emax   = &x[62:52];
    end else begin
      u.sign = s[31];
      e      = {3'b000, s[30:23]};
      f      = {s[22:0], 29'b0};
      emax   = &s[30:23];
    end
    u.zero = (e == '0) && (f == '0);
    u.sub  = (e == '0) && (f != '0);
    u.inf  = emax && (f == '0);
    u.nan  = emax && (f != '0);
    u.snan = u.nan && !f[SIG_W-2];
    u.sig  = {e != '0, f};
    if (dbl) u.exp = (e == '0) ? EXP_W'(1) : e;
    else     u.exp = ((e == '0) ? EXP_W'(1) : e) + EXP_W'(S2D);
    return u;
  endfunction

  // IEEE 754 rounding decision from the last kept bit, guard and sticky.
  function automatic logic round_up(input rm_e rm, input logic sign, input logic lsb, input logic g,
                                    input logic s);
    unique case (rm)
      RM_RNE:  return g && (s || lsb);
      RM_RTZ:  return 1'b0;
      RM_RDN:  return (g || s) && sign;
      RM_RUP:  return (g || s) && !sign;
      RM_RMM:  return g;
      default: return 1'b0;
    endcase
  endfunction

  // Overflow goes to infinity (else to the largest finite value) for this mode and sign.
  function automatic logic ovf_to_inf(input rm_e rm, input logic sign);
    return (rm == RM_RNE) || (rm == RM_RMM) || (rm == RM_RUP && !sign) || (rm == RM_RDN && sign);
  endfunction

  function automatic logic [63:0] box_s(input logic [31:0] v);
    return {32'hFFFF_FFFF, v};
  endfunction

  // Infinity or the largest finite value, boxed for S.
  function automatic logic [63:0] ovf_value(input logic dbl, input logic sign, input logic to_inf);
    if (dbl) return {sign, to_inf ? 63'h7FF0_0000_0000_0000 : 63'h7FEF_FFFF_FFFF_FFFF};
    else     return box_s({sign, to_inf ? 31'h7F80_0000 : 31'h7F7F_FFFF});
  endfunction

  function automatic logic [63:0] inf_value(input logic dbl, input logic sign);
    return dbl ? {sign, 63'h7FF0_0000_0000_0000} : box_s({sign, 31'h7F80_0000});
  endfunction

  function automatic logic [63:0] zero_value(input logic dbl, input logic sign);
    return dbl ? {sign, 63'b0} : box_s({sign, 31'b0});
  endfunction

  function automatic logic [63:0] cnan(input logic dbl);
    return dbl ? CNAN_D : CNAN_S;
  endfunction

  // A special result, decided from the operands' classes and carried to the result stage as a
  // kind and a sign rather than as 64 bits.
  typedef enum logic [1:0] { SPEC_NONE, SPEC_NAN, SPEC_INF, SPEC_ZERO } spec_e;

  function automatic logic [63:0] spec_value(input spec_e k, input logic dbl, input logic sign);
    unique case (k)
      SPEC_NAN: return cnan(dbl);
      SPEC_INF: return inf_value(dbl, sign);
      default:  return zero_value(dbl, sign);
    endcase
  endfunction

  // ---- Divide/sqrt: what travels with an operation to the rounding stages (tg_fpu_div_round) ----

  typedef struct packed {
    logic        sqrt;
    logic        dbl;
    rm_e         rm;
    logic [FPU_TAG_W-1:0] tag;
    spec_e       spec;
    logic        nv, dz;       // flags of a special result
    logic        sign;
    logic [12:0] eq;           // signed: the result is q * 2^eq with q in [1, 2)
    // derived from eq by div_info_derive, for the rounding stages
    logic        sub;          // eq < emin: denormalise by ks
    logic [5:0]  ks;
    logic [10:0] fbase;        // exponent field - 1 (normal) or 0 (subnormal)
    logic        emin_m1;      // eq = emin - 1: tininess depends on rounding at full precision
    logic        big;          // eq > emax: overflow
    logic        at_emax;      // eq = emax: overflow if rounding carries out
  } div_info_t;

  // Special operands of FDIV (a / b) and FSQRT (a), and the result sign. Only the class and sign
  // fields of the unpacked operands matter here (hence the waiver).
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic div_info_t div_info_init(input logic sqrt, input logic dbl, input rm_e rm,
                                              input logic [FPU_TAG_W-1:0] tag, input fp_unp_t ua,
                                              input fp_unp_t ub);
    div_info_t i;
    i      = '0;
    i.sqrt = sqrt;
    i.dbl  = dbl;
    i.rm   = rm;
    i.tag  = tag;
    i.sign = sqrt ? 1'b0 : (ua.sign ^ ub.sign);
    i.spec = SPEC_NONE;
    if (sqrt) begin
      if (ua.nan)                  begin i.spec = SPEC_NAN;  i.nv = ua.snan; end
      else if (ua.zero)            begin i.spec = SPEC_ZERO; i.sign = ua.sign; end
      else if (ua.sign)            begin i.spec = SPEC_NAN;  i.nv = 1'b1; end
      else if (ua.inf)             begin i.spec = SPEC_INF; end
    end else begin
      if (ua.nan || ub.nan)        begin i.spec = SPEC_NAN;  i.nv = ua.snan || ub.snan; end
      else if ((ua.inf && ub.inf) || (ua.zero && ub.zero))
                                   begin i.spec = SPEC_NAN;  i.nv = 1'b1; end
      else if (ua.inf)             begin i.spec = SPEC_INF; end
      else if (ub.zero)            begin i.spec = SPEC_INF;  i.dz = 1'b1; end
      else if (ua.zero || ub.inf)  begin i.spec = SPEC_ZERO; end
    end
    return i;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // The exponent conditions the rounding stages need, from eq.
  function automatic div_info_t div_info_derive(input div_info_t i);
    div_info_t o;
    logic signed [12:0] eq, emin, emax, k;
    o    = i;
    eq   = $signed(i.eq);
    emin = i.dbl ? -13'sd1022 : -13'sd126;
    emax = i.dbl ? 13'sd1023 : 13'sd127;
    k    = emin - eq;
    o.sub     = eq < emin;
    o.ks      = (eq >= emin) ? 6'd0 : (k > 13'sd55) ? 6'd55 : 6'(k);
    o.fbase   = (eq < emin) ? 11'd0 : 11'(eq + emax - 13'sd1);
    o.emin_m1 = eq == emin - 13'sd1;
    o.big     = eq > emax;
    o.at_emax = eq == emax;
    return o;
  endfunction

endpackage
