// FMA addend alignment (docs/spec/fpu.md, "FMA unit", E1): the 53-bit addend significand placed
// at the top of the W-bit window and shifted right by sh; the bit at the bottom (V[0]) collects
// every bit shifted to or below it (from the trailing-zero count, not an OR tree). The fine part
// of the shift (sh[3:0]) runs in two DSP tiles, as mc * 2^(15 - sh[3:0]) (fine, registered by the
// caller); the coarse part (sh[7:4], whole 16-bit steps) is the fabric's multiplexer.
module tg_fpu_fma_align #(
  parameter int W = 165
) (
  input  logic [52:0]   mc,
  input  logic [7:0]    sh,
  input  logic [15:0]   fine,       // 2^(15 - sh[3:0])
  output logic [W-1:0]  cal
);
  localparam int LSB = W - 53;  // window position of mc[0] when sh = 0

  logic [5:0] tz;
  always_comb begin
    tz = 6'd53;
    for (int i = 52; i >= 0; i--)
      if (mc[i]) tz = 6'(i);
  end
  // y = {mc, 15'b0} >> sh[3:0]: each 26-bit chunk's product with the one-hot is the chunk shifted, and the
  // chunks' products cover disjoint bits, so they combine without carries; the top bit takes the one-hot
  (* use_dsp = "yes" *) logic [41:0] f0, f1;
  assign f0 = 42'(mc[25:0]) * 42'(fine);
  assign f1 = 42'(mc[51:26]) * 42'(fine);
  logic [67:0] y;
  assign y = 68'(f0) | (68'(f1) << 26) | (68'(mc[52] ? fine : 16'b0) << 52);
  always_comb begin
    logic [W-1:0] x;
    x   = {y, {(W-68){1'b0}}} >> {sh[7:4], 4'b0};
    cal = {x[W-1:1], x[0] || ((mc != '0) && (sh >= 8'(LSB)) && ({2'b0, tz} <= sh - 8'(LSB)))};
  end
endmodule
