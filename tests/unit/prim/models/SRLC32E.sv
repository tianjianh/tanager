// Simulation model of the UltraScale+ SRLC32E primitive for unit tests of the tg_fifo "srl"
// mapping (TG_SIM_PRIMS), written from the documented behaviour (UG974): a 32-bit shift
// register that shifts D in at bit 0 on the rising CLK edge when CE is high; Q is the bit
// at address A (asynchronous read) and Q31 the last bit (for cascading).
/* verilator lint_off DECLFILENAME */
module SRLC32E #(
  parameter logic [31:0] INIT = '0,
  parameter bit IS_CLK_INVERTED = 1'b0
) (
  output logic Q, Q31,
  input  logic [4:0] A,
  input  logic CE, CLK, D
);
  /* verilator lint_off PROCASSINIT */  // the power-up value is the INIT parameter
  logic [31:0] sr = INIT;
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge CLK) begin
    if (CE) sr <= {sr[30:0], D};
  end
  assign Q   = sr[A];
  assign Q31 = sr[31];
  wire unused = IS_CLK_INVERTED;
endmodule
/* verilator lint_on DECLFILENAME */
