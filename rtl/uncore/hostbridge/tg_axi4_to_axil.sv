// AXI4 slave to AXI4-Lite master (docs/spec/host.md): lets the PS's M_AXI_HPM0_FPD (AXI4) reach the
// host bridge's AXI4-Lite window. Bursts are split into single 32-bit accesses at consecutive
// addresses; one read and one write transaction at a time; IDs are echoed; responses are OKAY
// unless the AXI4-Lite side reports an error (the last error of a burst is returned).
module tg_axi4_to_axil #(
  parameter int ID_W   = 16,
  parameter int ADDR_W = 40,
  parameter int LA_W   = 16          // AXI4-Lite address bits passed on
) (
  input  logic              clk,
  input  logic              rst,
  // AXI4 slave
  input  logic [ID_W-1:0]   s_awid,
  input  logic [ADDR_W-1:0] s_awaddr,
  input  logic [7:0]        s_awlen,
  input  logic              s_awvalid,
  output logic              s_awready,
  input  logic [31:0]       s_wdata,
  input  logic [3:0]        s_wstrb,
  input  logic              s_wlast,
  input  logic              s_wvalid,
  output logic              s_wready,
  output logic [ID_W-1:0]   s_bid,
  output logic [1:0]        s_bresp,
  output logic              s_bvalid,
  input  logic              s_bready,
  input  logic [ID_W-1:0]   s_arid,
  input  logic [ADDR_W-1:0] s_araddr,
  input  logic [7:0]        s_arlen,
  input  logic              s_arvalid,
  output logic              s_arready,
  output logic [ID_W-1:0]   s_rid,
  output logic [31:0]       s_rdata,
  output logic [1:0]        s_rresp,
  output logic              s_rlast,
  output logic              s_rvalid,
  input  logic              s_rready,
  // AXI4-Lite master
  output logic [LA_W-1:0]   m_awaddr,
  output logic              m_awvalid,
  input  logic              m_awready,
  output logic [31:0]       m_wdata,
  output logic [3:0]        m_wstrb,
  output logic              m_wvalid,
  input  logic              m_wready,
  input  logic [1:0]        m_bresp,
  input  logic              m_bvalid,
  output logic              m_bready,
  output logic [LA_W-1:0]   m_araddr,
  output logic              m_arvalid,
  input  logic              m_arready,
  input  logic [31:0]       m_rdata,
  input  logic [1:0]        m_rresp,
  input  logic              m_rvalid,
  output logic              m_rready
);
  // ---- reads ----
  typedef enum logic [1:0] { R_IDLE, R_AR, R_R, R_OUT } rst_e;
  rst_e            r_st_q;
  logic [ID_W-1:0] r_id_q;
  logic [LA_W-1:0] r_addr_q;
  logic [7:0]      r_left_q;
  logic [31:0]     r_data_q;
  logic [1:0]      r_resp_q;

  assign s_arready = r_st_q == R_IDLE;
  assign m_araddr  = r_addr_q;
  assign m_arvalid = r_st_q == R_AR;
  assign m_rready  = r_st_q == R_R;
  assign s_rid     = r_id_q;
  assign s_rdata   = r_data_q;
  assign s_rresp   = r_resp_q;
  assign s_rlast   = r_left_q == 8'd0;
  assign s_rvalid  = r_st_q == R_OUT;

  always_ff @(posedge clk) begin
    if (rst) begin
      r_st_q <= R_IDLE;
    end else begin
      unique case (r_st_q)
        R_IDLE: if (s_arvalid) begin
          r_id_q   <= s_arid;
          r_addr_q <= {s_araddr[LA_W-1:2], 2'b00};
          r_left_q <= s_arlen;
          r_st_q   <= R_AR;
        end
        R_AR:  if (m_arready) r_st_q <= R_R;
        R_R:   if (m_rvalid) begin
          r_data_q <= m_rdata;
          r_resp_q <= m_rresp;
          r_st_q   <= R_OUT;
        end
        R_OUT: if (s_rready) begin
          if (r_left_q == 8'd0) r_st_q <= R_IDLE;
          else begin
            r_left_q <= r_left_q - 1'b1;
            r_addr_q <= r_addr_q + LA_W'(4);
            r_st_q   <= R_AR;
          end
        end
        default: r_st_q <= R_IDLE;
      endcase
    end
  end

  // ---- writes ----
  typedef enum logic [2:0] { W_IDLE, W_DATA, W_LITE, W_RESP, W_B } wst_e;
  wst_e            w_st_q;
  logic [ID_W-1:0] w_id_q;
  logic [LA_W-1:0] w_addr_q;
  logic [31:0]     w_data_q;
  logic [3:0]      w_strb_q;
  logic            w_last_q, aw_done_q, wl_done_q;
  logic [1:0]      w_resp_q;

  assign s_awready = w_st_q == W_IDLE;
  assign s_wready  = w_st_q == W_DATA;
  assign m_awaddr  = w_addr_q;
  assign m_awvalid = w_st_q == W_LITE && !aw_done_q;
  assign m_wdata   = w_data_q;
  assign m_wstrb   = w_strb_q;
  assign m_wvalid  = w_st_q == W_LITE && !wl_done_q;
  assign m_bready  = w_st_q == W_RESP;
  assign s_bid     = w_id_q;
  assign s_bresp   = w_resp_q;
  assign s_bvalid  = w_st_q == W_B;

  always_ff @(posedge clk) begin
    if (rst) begin
      w_st_q <= W_IDLE;
    end else begin
      unique case (w_st_q)
        W_IDLE: if (s_awvalid) begin
          w_id_q   <= s_awid;
          w_addr_q <= {s_awaddr[LA_W-1:2], 2'b00};
          w_resp_q <= 2'b00;
          w_st_q   <= W_DATA;
        end
        W_DATA: if (s_wvalid) begin
          w_data_q  <= s_wdata;
          w_strb_q  <= s_wstrb;
          w_last_q  <= s_wlast;
          aw_done_q <= 1'b0;
          wl_done_q <= 1'b0;
          w_st_q    <= W_LITE;
        end
        W_LITE: begin
          if (m_awvalid && m_awready) aw_done_q <= 1'b1;
          if (m_wvalid && m_wready)   wl_done_q <= 1'b1;
          if ((aw_done_q || m_awready) && (wl_done_q || m_wready)) w_st_q <= W_RESP;
        end
        W_RESP: if (m_bvalid) begin
          if (m_bresp != 2'b00) w_resp_q <= m_bresp;
          if (w_last_q) w_st_q <= W_B;
          else begin
            w_addr_q <= w_addr_q + LA_W'(4);
            w_st_q   <= W_DATA;
          end
        end
        W_B: if (s_bready) w_st_q <= W_IDLE;
        default: w_st_q <= W_IDLE;
      endcase
    end
  end

  wire unused = ^{s_awaddr[ADDR_W-1:LA_W], s_awaddr[1:0], s_araddr[ADDR_W-1:LA_W], s_araddr[1:0], s_awlen};
endmodule
