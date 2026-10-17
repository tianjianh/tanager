// An AXI4 slave for a port with nothing behind it (docs/spec/soc.md §8.1): M_AXI_HPM1_FPD in a
// bitstream without the host DMA port, so an A53 access there ends instead of hanging the ARM, as a PL
// access nothing answers would. A read answers DECERR on every beat (a synchronous abort on the A53:
// SIGBUS to the reader); a write is taken and dropped with OKAY, because an error on a posted write
// is an asynchronous SError there, which panics the A53's Linux. One burst at a time each way: a
// write's beats are taken, then B; a read gets its len + 1 beats, the last with RLAST.
module tg_axi_absent #(
  parameter int ID_W = 16,
  parameter int DATA_W = 128
) (
  input  logic              clk,
  input  logic              rst,
  input  logic [ID_W-1:0]   s_awid,
  input  logic              s_awvalid,
  output logic              s_awready,
  input  logic              s_wlast,
  input  logic              s_wvalid,
  output logic              s_wready,
  output logic [ID_W-1:0]   s_bid,
  output logic [1:0]        s_bresp,
  output logic              s_bvalid,
  input  logic              s_bready,
  input  logic [ID_W-1:0]   s_arid,
  input  logic [7:0]        s_arlen,
  input  logic              s_arvalid,
  output logic              s_arready,
  output logic [ID_W-1:0]   s_rid,
  output logic [DATA_W-1:0] s_rdata,
  output logic [1:0]        s_rresp,
  output logic              s_rlast,
  output logic              s_rvalid,
  input  logic              s_rready
);
  typedef enum logic [1:0] { W_IDLE, W_DATA, W_B } wst_e;
  wst_e       ws_q;
  logic [8:0] rleft_q;                          // read beats still to answer; 0 is idle

  always_ff @(posedge clk) begin
    if (rst) begin
      ws_q    <= W_IDLE;
      rleft_q <= '0;
    end else begin
      unique case (ws_q)
        W_IDLE: if (s_awvalid) begin s_bid <= s_awid; ws_q <= W_DATA; end
        W_DATA: if (s_wvalid && s_wlast) ws_q <= W_B;
        W_B:    if (s_bready) ws_q <= W_IDLE;
        default: ws_q <= W_IDLE;
      endcase
      if (rleft_q == 9'd0) begin
        if (s_arvalid) begin
          s_rid   <= s_arid;
          rleft_q <= {1'b0, s_arlen} + 9'd1;
        end
      end else if (s_rready) begin
        rleft_q <= rleft_q - 9'd1;
      end
    end
  end

  assign s_awready = ws_q == W_IDLE;
  assign s_wready  = ws_q == W_DATA;
  assign s_bvalid  = ws_q == W_B;
  assign s_bresp   = 2'b00;
  assign s_arready = rleft_q == 9'd0;
  assign s_rvalid  = rleft_q != 9'd0;
  assign s_rdata   = '0;
  assign s_rresp   = 2'b11;
  assign s_rlast   = rleft_q == 9'd1;
endmodule
