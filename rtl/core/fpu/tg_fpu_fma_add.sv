// FMA adder (docs/spec/fpu.md, "FMA unit", E2): the six DSP tiles of the product and the aligned
// addend (complemented here for an effective subtraction, inside the column counters) reduce
// column by column to three rows, then two ternary adders give X = P - C (= P + ~C + 1) and
// Y = X - 1. |P - C| is X, or ~Y when X < 0; for an effective addition Y is P + C. When the
// product does not take part, the tiles arrive as zero (their output registers are reset).
module tg_fpu_fma_add #(
  parameter int W = 165
) (
  input  logic [42:0]   t00, t01, t02, t10,
  input  logic [43:0]   t11,
  input  logic [46:0]   t12,
  input  logic [W:0]    cop,           // C (bit W is zero), or |x| for FCVT.F.I
  input  logic          prod_sticky,   // the product only contributes a sticky at V[0]
  input  logic          eff_sub,
  input  logic          sp, sc,        // product and addend signs
  output logic [W-1:0]  mag,
  output logic          rsign
);
  logic [W:0] s0, s1, s2;
  always_comb begin
    logic [W:0] o [8];
    o[0] = (W+1)'(t00) << 4;
    o[1] = (W+1)'(t01) << 21;
    o[2] = (W+1)'(t02) << 38;
    o[3] = (W+1)'(t10) << 30;
    o[4] = (W+1)'(t11) << 47;
    o[5] = (W+1)'(t12) << 64;
    o[6] = cop ^ {(W+1){eff_sub}};
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
  // From bit LO up only the addend contributes: the tiles end at V[110] and the counters' carries
  // at V[111]. The low part sums to less than 2^(LO+1) (product < 2^110, addend part < 2^LO), so
  // its carry out is 0 or 1, and both sums above LO are the addend's bits plus that carry: one
  // incrementer serves X and Y there.
  localparam int LO = 112;
  logic [LO:0]   lx, ly;        // low parts with their carry out (bit LO)
  logic [W-LO:0] hi, hi1;       // the addend's bits W..LO, and hi + 1
  logic [W:0]    sum_x, sum_y;
  assign lx  = {1'b0, s0[LO-1:0]} + {1'b0, s1[LO-1:0]} + {1'b0, s2[LO-1:0]} + (LO+1)'(1);
  assign ly  = {1'b0, s0[LO-1:0]} + {1'b0, s1[LO-1:0]} + {1'b0, s2[LO-1:0]};
  assign hi  = s0[W:LO];
  assign hi1 = hi + (W-LO+1)'(1);
  assign sum_x = {lx[LO] ? hi1 : hi, lx[LO-1:0]};
  assign sum_y = {ly[LO] ? hi1 : hi, ly[LO-1:0]};

  always_comb begin
    if (!eff_sub)       begin mag = sum_y[W-1:0];  rsign = sp; end
    else if (sum_x[W])  begin mag = ~sum_y[W-1:0]; rsign = sc; end
    else                begin mag = sum_x[W-1:0];  rsign = sp; end
  end

  logic unused;
  assign unused = ^{sum_y[W], s1[W:LO], s2[W:LO]};
endmodule
