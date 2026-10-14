// FMA addend alignment (docs/spec/fpu.md, "FMA unit", E1): the 53-bit addend significand placed
// at the top of the W-bit window and shifted right by sh; the bit at the bottom (V[0]) collects
// every bit shifted to or below it (from the trailing-zero count, not an OR tree).
module tg_fpu_fma_align #(
  parameter int W = 165
) (
  input  logic [52:0]   mc,
  input  logic [7:0]    sh,
  output logic [W-1:0]  cal
);
  localparam int LSB = W - 53;  // window position of mc[0] when sh = 0

  logic [5:0] tz;
  always_comb begin
    tz = 6'd53;
    for (int i = 52; i >= 0; i--)
      if (mc[i]) tz = 6'(i);
  end
  always_comb begin
    logic [W-1:0] x;
    x   = {mc, {LSB{1'b0}}} >> sh;
    cal = {x[W-1:1], x[0] || ((mc != '0) && (sh >= 8'(LSB)) && ({2'b0, tz} <= sh - 8'(LSB)))};
  end
endmodule
