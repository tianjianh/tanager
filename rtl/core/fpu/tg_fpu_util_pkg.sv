// Helpers shared by the FPU units (docs/spec/fpu.md, "Behaviour common to all units"):
// operand unpacking with the RISC-V NaN-boxing rule, rounding decisions, leading/trailing-zero
// counts and result constants. Owned by the FPU track.
package tg_fpu_util_pkg;
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

  function automatic fp_unp_t unpack(input logic [63:0] x, input logic dbl);
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

endpackage
