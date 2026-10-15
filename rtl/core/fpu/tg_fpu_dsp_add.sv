// Adder in DSP48E2 slices (docs/perf/fpga_friendly.md T6), for operands that a pipeline
// register holds anyway: that register is this module's, so synthesis places it in the DSPs'
// A:B, C and carry-in registers, and the sum costs no LUTs or carry chain.
//   s = a_q + b_q + ci_q, where a_q, b_q and ci_q are a, b and ci registered when ce is set;
//   s is combinational from them (no output register).
// 48 bits per DSP, cascaded above that. Under the kept hierarchy (DR-113) the register must be
// in here: synthesis does not move a parent's register into the DSP. Used by the execute
// unit's branch path (pc + 2 or 4) as well as the FPU.
(* use_dsp = "yes" *)
module tg_fpu_dsp_add #(
  parameter int W = 48
) (
  input  logic         clk,
  input  logic         ce,
  input  logic [W-1:0] a,
  input  logic [W-1:0] b,
  input  logic         ci,
  output logic [W-1:0] s
);
  logic [W-1:0] a_q, b_q;
  logic         ci_q;
  always_ff @(posedge clk) begin
    if (ce) begin
      a_q  <= a;
      b_q  <= b;
      ci_q <= ci;
    end
  end
  assign s = a_q + b_q + W'(ci_q);
endmodule
