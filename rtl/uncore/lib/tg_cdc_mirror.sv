// Continuously mirrors a multi-bit vector from src_clk into dst_clk (docs/spec/host.md):
// a 4-phase handshake loop copies consistent snapshots, so a multi-bit value never arrives torn.
// The value seen in dst_clk lags the source by a few cycles of both clocks.
// xpm_cdc_handshake under SYNTHESIS; an equivalent req/ack synchronizer pair in simulation.
module tg_cdc_mirror #(
  parameter int              W    = 32,
  parameter logic [W-1:0]    INIT = '0
) (
  input  logic         src_clk,
  input  logic         src_rst,
  input  logic [W-1:0] src_in,
  input  logic         dst_clk,
  input  logic         dst_rst,
  output logic [W-1:0] dst_out
);
  logic [W-1:0] hold_q;
  logic         send_q;
  logic         rcv;
  logic [W-1:0] dst_bus;
  logic         dst_req;

  // Source side: capture, send, wait for rcv, drop send, wait for rcv to drop, repeat.
  always_ff @(posedge src_clk) begin
    if (src_rst) begin
      send_q <= 1'b0;
      hold_q <= INIT;
    end else if (!send_q && !rcv) begin
      hold_q <= src_in;
      send_q <= 1'b1;
    end else if (send_q && rcv) begin
      send_q <= 1'b0;
    end
  end

`ifdef SYNTHESIS
  xpm_cdc_handshake #(
    .DEST_EXT_HSK   (0),
    .DEST_SYNC_FF   (3),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_SYNC_FF    (3),
    .WIDTH          (W)
  ) u_hs (
    .src_clk  (src_clk),
    .src_in   (hold_q),
    .src_send (send_q),
    .src_rcv  (rcv),
    .dest_clk (dst_clk),
    .dest_req (dst_req),
    .dest_ack (1'b0),
    .dest_out (dst_bus)
  );
`else
  logic [2:0] req_sync_q, ack_sync_q;
  logic       req_seen_q;
  logic [W-1:0] bus_q;
  always_ff @(posedge dst_clk) begin
    if (dst_rst) begin
      req_sync_q <= '0;
      req_seen_q <= 1'b0;
    end else begin
      req_sync_q <= {req_sync_q[1:0], send_q};
      req_seen_q <= req_sync_q[2];
    end
    if (req_sync_q[2] && !req_seen_q) bus_q <= hold_q;
  end
  always_ff @(posedge src_clk) begin
    if (src_rst) ack_sync_q <= '0;
    else         ack_sync_q <= {ack_sync_q[1:0], req_seen_q};
  end
  assign rcv     = ack_sync_q[2];
  assign dst_req = req_sync_q[2] && !req_seen_q;
  assign dst_bus = bus_q;
`endif

  // Destination register: updated once per completed transfer.
  always_ff @(posedge dst_clk) begin
    if (dst_rst)      dst_out <= INIT;
    else if (dst_req) dst_out <= dst_bus;
  end
endmodule
