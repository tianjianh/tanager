// Pulse transfer from src_clk to dst_clk (docs/spec/host.md): each single-cycle src_pulse produces
// one single-cycle dst_pulse. Source pulses must be spaced by at least ~8 cycles of the slower clock
// (doorbells and power requests are far rarer). xpm_cdc_pulse under SYNTHESIS; a toggle
// synchronizer in simulation.
module tg_cdc_pulse (
  input  logic src_clk,
  input  logic src_rst,
  input  logic src_pulse,
  input  logic dst_clk,
  input  logic dst_rst,
  output logic dst_pulse
);
`ifdef SYNTHESIS
  xpm_cdc_pulse #(
    .DEST_SYNC_FF   (3),
    .INIT_SYNC_FF   (1),
    .REG_OUTPUT     (1),
    .RST_USED       (1),
    .SIM_ASSERT_CHK (0)
  ) u_pulse (
    .src_clk    (src_clk),
    .src_rst    (src_rst),
    .src_pulse  (src_pulse),
    .dest_clk   (dst_clk),
    .dest_rst   (dst_rst),
    .dest_pulse (dst_pulse)
  );
`else
  logic       tog_q;
  logic [2:0] sync_q;
  logic       dst_q;
  always_ff @(posedge src_clk) begin
    if (src_rst)        tog_q <= 1'b0;
    else if (src_pulse) tog_q <= ~tog_q;
  end
  always_ff @(posedge dst_clk) begin
    if (dst_rst) begin
      sync_q <= '0;
      dst_q  <= 1'b0;
    end else begin
      sync_q <= {sync_q[1:0], tog_q};
      dst_q  <= sync_q[2] ^ sync_q[1];
    end
  end
  assign dst_pulse = dst_q;
`endif
endmodule
