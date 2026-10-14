// Rounding stages of the divide/sqrt units (docs/spec/fpu.md, "Final rounding"): takes the
// quotient or root at normal precision as (T, G, S) and returns the packed response.
//   F1 (registered input): denormalise a division result below 2^emin by ks (three radix-4
//      stages, each ORing the bits it drops into the sticky), the rounding decision, tininess
//      after rounding, overflow
//   F2 (registered input, combinational output): pack {exponent - 1 + hidden, fraction} plus
//      the increment, special results, NaN boxing
// valid_o and resp_o appear two cycles after valid_i.
module tg_fpu_div_round
  import tg_pkg::*;
  import tg_fpu_pkg::*;
  import tg_fpu_util_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        valid_i,
  input  div_info_t   info_i,
  input  logic [52:0] t_i,          // with the hidden bit (S: bits 23:0)
  input  logic        g_i,
  input  logic        s_i,
  output logic        valid_o,
  output fpu_resp_t   resp_o
);
  // ---- F1 ----
  logic        f1_v;
  div_info_t   f1_info;
  logic [52:0] f1_t;
  logic        f1_g, f1_s;
  always_ff @(posedge clk) begin
    if (rst) f1_v <= 1'b0;
    else     f1_v <= valid_i;
    f1_info <= info_i;
    f1_t    <= t_i;
    f1_g    <= g_i;
    f1_s    <= s_i;
  end

  logic        f2_v;
  div_info_t   f2_info;
  logic [52:0] f2_t;
  logic        f2_inc, f2_inexact, f2_tiny, f2_ovf;
  always_ff @(posedge clk) begin
    logic        s, gg, ss, tmax, st1, st2, st3;
    logic [53:0] x0, x1, x2, x3;
    logic [52:0] tt;
    logic [5:0]  ks;
    s    = f1_info.sign;
    ks   = f1_info.ks;
    x0   = {f1_t, f1_g};
    x1   = x0 >> {ks[5:4], 4'b0};
    st1  = |(x0 & ~({54{1'b1}} << {ks[5:4], 4'b0}));
    x2   = x1 >> {ks[3:2], 2'b0};
    st2  = |(x1 & ~({54{1'b1}} << {ks[3:2], 2'b0}));
    x3   = x2 >> ks[1:0];
    st3  = |(x2 & ~({54{1'b1}} << ks[1:0]));
    tt   = x3[53:1];
    gg   = x3[0];
    ss   = f1_s || st1 || st2 || st3;
    tmax = f1_info.dbl ? (&f1_t[52:0]) : (&f1_t[23:0]);
    if (rst) f2_v <= 1'b0;
    else     f2_v <= f1_v;
    f2_info    <= f1_info;
    f2_t       <= tt;
    f2_inc     <= round_up(f1_info.rm, s, tt[0], gg, ss);
    f2_inexact <= gg || ss;
    // tiny after rounding: below 2^emin unless rounding to full precision reaches it
    f2_tiny    <= f1_info.sub && !(f1_info.emin_m1 && tmax && round_up(f1_info.rm, s, 1'b1, f1_g, f1_s));
    // overflow: exponent above emax, or rounding carries out of the largest binade
    f2_ovf     <= f1_info.big || (f1_info.at_emax && tmax && round_up(f1_info.rm, s, f1_t[0], f1_g, f1_s));
  end

  // ---- F2 ----
  always_comb begin
    logic dbl, s;
    logic [62:0] pk_d;
    logic [30:0] pk_s;
    dbl  = f2_info.dbl;
    s    = f2_info.sign;
    pk_d = ({52'b0, f2_info.fbase} << 52) + {10'b0, f2_t} + 63'(f2_inc);
    pk_s = ({20'b0, f2_info.fbase} << 23) + {7'b0, f2_t[23:0]} + 31'(f2_inc);
    resp_o.tag = f2_info.tag;
    resp_o.int_dest = 1'b0;
    resp_o.fflags = '0;
    unique case (f2_info.spec)
      SPEC_NAN:  begin resp_o.result = cnan(dbl); resp_o.fflags[FL_NV] = f2_info.nv; end
      SPEC_INF:  begin resp_o.result = inf_value(dbl, s); resp_o.fflags[FL_DZ] = f2_info.dz; end
      SPEC_ZERO: resp_o.result = zero_value(dbl, s);
      default: begin
        if (f2_ovf) begin
          resp_o.result = ovf_value(dbl, s, ovf_to_inf(f2_info.rm, s));
          resp_o.fflags[FL_OF] = 1'b1;
          resp_o.fflags[FL_NX] = 1'b1;
        end else begin
          resp_o.result = dbl ? {s, pk_d} : box_s({s, pk_s});
          resp_o.fflags[FL_NX] = f2_inexact;
          resp_o.fflags[FL_UF] = f2_tiny && f2_inexact;
        end
      end
    endcase
  end
  assign valid_o = f2_v;

  logic unused;
  assign unused = ^{f2_info.sqrt, f2_info.eq, f2_info.sub, f2_info.ks, f2_info.emin_m1, f2_info.big,
                    f2_info.at_emax, f1_info.eq, f1_info.fbase, f1_info.nv, f1_info.dz,
                    f1_info.spec, f1_info.tag, f1_info.sqrt};
endmodule
