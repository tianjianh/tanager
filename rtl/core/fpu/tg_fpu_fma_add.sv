// FMA adder (docs/spec/fpu.md, "FMA unit", E2): the six DSP tiles of the product and the aligned
// addend (or its complement for an effective subtraction) reduce column by column to three rows,
// then two ternary adders give X = P - C (= P + ~C + 1) and Y = X - 1. |P - C| is X, or ~Y when
// X < 0; for an effective addition Y is P + C.
module tg_fpu_fma_add #(
  parameter int W = 165
) (
  input  logic [42:0]   t00, t01, t02, t10,
  input  logic [43:0]   t11,
  input  logic [46:0]   t12,
  input  logic [W:0]    cop,           // C or ~C, with the sign bit W
  input  logic          prod_sticky,   // the product only contributes a sticky at V[0]
  input  logic          eff_sub,
  input  logic          sp, sc,        // product and addend signs
  output logic [W-1:0]  mag,
  output logic          rsign
);
  logic [W:0] s0, s1, s2;
  always_comb begin
    logic [W:0] o [8];
    logic gate;
    gate = !prod_sticky;
    o[0] = (W+1)'(gate ? t00 : '0) << 4;
    o[1] = (W+1)'(gate ? t01 : '0) << 21;
    o[2] = (W+1)'(gate ? t02 : '0) << 38;
    o[3] = (W+1)'(gate ? t10 : '0) << 30;
    o[4] = (W+1)'(gate ? t11 : '0) << 47;
    o[5] = (W+1)'(gate ? t12 : '0) << 64;
    o[6] = cop;
    o[7] = (W+1)'(prod_sticky);
    s0 = '0; s1 = '0; s2 = '0;
    for (int k = 0; k <= W; k++) begin
      logic [2:0] cnt;
      cnt = 3'(o[0][k]) + 3'(o[1][k]) + 3'(o[2][k]) + 3'(o[3][k]) + 3'(o[4][k]) + 3'(o[5][k])
          + 3'(o[6][k]) + 3'(o[7][k]);
      s0[k] = cnt[0];
      if (k + 1 <= W) s1[k+1] = cnt[1];
      if (k + 2 <= W) s2[k+2] = cnt[2];
    end
  end
  logic [W:0] sum_x, sum_y;
  assign sum_x = s0 + s1 + s2 + (W+1)'(1);
  assign sum_y = s0 + s1 + s2;

  always_comb begin
    if (!eff_sub)       begin mag = sum_y[W-1:0];  rsign = sp; end
    else if (sum_x[W])  begin mag = ~sum_y[W-1:0]; rsign = sc; end
    else                begin mag = sum_x[W-1:0];  rsign = sp; end
  end

  logic unused;
  assign unused = sum_y[W];
endmodule
