// Single-bit level synchronizer into dst_clk (docs/spec/host.md). xpm_cdc_single under SYNTHESIS;
// an equivalent flip-flop chain in simulation. The input must be a register in its own domain.
module tg_cdc_bit #(
  parameter int STAGES = 3,
  parameter bit INIT   = 1'b0
) (
  input  logic src_in,
  input  logic dst_clk,
  output logic dst_out
);
`ifdef SYNTHESIS
  xpm_cdc_single #(
    .DEST_SYNC_FF   (STAGES),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_INPUT_REG  (0)
  ) u_sync (
    .src_clk  (1'b0),
    .src_in   (src_in),
    .dest_clk (dst_clk),
    .dest_out (dst_out)
  );
  wire unused_init = INIT;
`else
  // Simulation model only: the power-up value stands in for INIT_SYNC_FF.
  /* verilator lint_off PROCASSINIT */
  logic [STAGES-1:0] sync_q = {STAGES{INIT}};
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge dst_clk) sync_q <= {sync_q[STAGES-2:0], src_in};
  assign dst_out = sync_q[STAGES-1];
`endif
endmodule
