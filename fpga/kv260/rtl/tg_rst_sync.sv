// Reset synchronizer for the board top: asserts asynchronously, releases synchronously to clk
// (xpm_cdc_async_rst). The result is used as the synchronous reset of its clock domain.
module tg_rst_sync (
  input  logic clk,
  input  logic rst_async,     // active high
  output logic rst_sync       // active high, released on a clk edge
);
  xpm_cdc_async_rst #(
    .DEST_SYNC_FF    (4),
    .INIT_SYNC_FF    (0),
    .RST_ACTIVE_HIGH (1)
  ) u_sync (
    .src_arst  (rst_async),
    .dest_clk  (clk),
    .dest_arst (rst_sync)
  );
endmodule
