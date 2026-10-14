// Simulation model of the UltraScale+ SRL16E primitive for unit tests of the tg_fifo "srl"
// mapping (TG_SIM_PRIMS), written from the documented behaviour (UG974): a 16-bit shift
// register that shifts D in at bit 0 on the rising CLK edge when CE is high; Q is the bit
// at address {A3, A2, A1, A0}, read asynchronously.
/* verilator lint_off DECLFILENAME */
module SRL16E #(
  parameter logic [15:0] INIT = '0,
  parameter bit IS_CLK_INVERTED = 1'b0
) (
  output logic Q,
  input  logic A0, A1, A2, A3, CE, CLK, D
);
  /* verilator lint_off PROCASSINIT */  // the power-up value is the INIT parameter
  logic [15:0] sr = INIT;
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge CLK) begin
    if (CE) sr <= {sr[14:0], D};
  end
  assign Q = sr[{A3, A2, A1, A0}];
  wire unused = IS_CLK_INVERTED;
endmodule
/* verilator lint_on DECLFILENAME */
