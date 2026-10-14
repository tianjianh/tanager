// KV260 board top (docs/spec/soc.md §2.1): the PS block design, the clock generator, reset
// synchronizers, the AXI4 -> AXI4-Lite converter for the host window, and tanager_soc.
//   M_AXI_HPM0_FPD (clk_host, 32-bit) -> tg_axi4_to_axil -> host bridge
//   L2 banks 0/1 (clk_core, 128-bit)  -> S_AXI_HP1_FPD / S_AXI_HP2_FPD
//   commit-trace stream (clk_core)     -> S_AXI_HP3_FPD (writes only)
//   host_irq -> pl_ps_irq0[0];  fan_en_b = the PS TTC waveform Linux's pwm-fan drives (DR-129):
//   fan_wave[FAN_WAVE] from the block design, inverted if FAN_INVERT
//   PMOD_UART = 1: the RISC-V console on the PMOD connector (pmod_uart_txd/rxd, 8N1 at the 16550's
//   divisor, 115200 after OpenSBI); the host still gets a copy. Off: txd is high-impedance.
module kv260_top
  import tg_pkg::*, tg_uncore_pkg::*;
#(
  parameter int    CORE_MHZ  = 100,
  parameter int    N_CORES   = NUM_CORES,
  parameter string CORE_KIND = "core",
  parameter bit    PMOD_UART = 1'b0,
  parameter int    FAN_WAVE   = 2,        // TTC0 channel 2 on fan_en_b, uninverted (the board; build.tcl TG_FAN_*)
  parameter bit    FAN_INVERT = 1'b0
) (
  output logic fan_en_b,
  output logic pmod_uart_txd,
  input  logic pmod_uart_rxd
);
  // ---- PS ----
  logic        pl_clk0, pl_resetn0;
  logic        clk_core, clk_host, locked;
  logic        host_irq;
  logic [2:0]  fan_wave;                // TTC waveform outputs (EMIO)

  logic [39:0] hpm_araddr, hpm_awaddr;
  logic [15:0] hpm_arid, hpm_awid, hpm_bid, hpm_rid;
  logic [7:0]  hpm_arlen, hpm_awlen;
  logic        hpm_arvalid, hpm_arready, hpm_awvalid, hpm_awready;
  logic [31:0] hpm_wdata, hpm_rdata;
  logic [3:0]  hpm_wstrb;
  logic        hpm_wlast, hpm_wvalid, hpm_wready, hpm_bvalid, hpm_bready, hpm_rlast, hpm_rvalid, hpm_rready;
  logic [1:0]  hpm_bresp, hpm_rresp;

  axi_ax_t [N_BANKS-1:0] ar, aw;
  axi_r_t  [N_BANKS-1:0] r;
  axi_w_t  [N_BANKS-1:0] w;
  axi_b_t  [N_BANKS-1:0] b;
  axi_ax_t taw;                       // commit-trace stream
  axi_w_t  tw;
  axi_b_t  tb;
  logic    tawv, tawr, twv, twr, tbv, tbr;
  logic    [N_BANKS-1:0] arv, arr, rv, rr, awv, awr, wv, wr, bv, br;

  tg_ps_wrapper u_ps (
    .clk_core (clk_core),
    .clk_host (clk_host),
    .pl_clk0 (pl_clk0),
    .pl_resetn0 (pl_resetn0),
    .pl_ps_irq0 (host_irq),
    .fan_wave (fan_wave),
    // host window
    .M_AXI_HPM0_araddr (hpm_araddr), .M_AXI_HPM0_arburst (), .M_AXI_HPM0_arcache (), .M_AXI_HPM0_arid (hpm_arid),
    .M_AXI_HPM0_arlen (hpm_arlen), .M_AXI_HPM0_arlock (), .M_AXI_HPM0_arprot (), .M_AXI_HPM0_arqos (),
    .M_AXI_HPM0_arready (hpm_arready), .M_AXI_HPM0_arsize (), .M_AXI_HPM0_aruser (), .M_AXI_HPM0_arvalid (hpm_arvalid),
    .M_AXI_HPM0_awaddr (hpm_awaddr), .M_AXI_HPM0_awburst (), .M_AXI_HPM0_awcache (), .M_AXI_HPM0_awid (hpm_awid),
    .M_AXI_HPM0_awlen (hpm_awlen), .M_AXI_HPM0_awlock (), .M_AXI_HPM0_awprot (), .M_AXI_HPM0_awqos (),
    .M_AXI_HPM0_awready (hpm_awready), .M_AXI_HPM0_awsize (), .M_AXI_HPM0_awuser (), .M_AXI_HPM0_awvalid (hpm_awvalid),
    .M_AXI_HPM0_bid (hpm_bid), .M_AXI_HPM0_bready (hpm_bready), .M_AXI_HPM0_bresp (hpm_bresp), .M_AXI_HPM0_bvalid (hpm_bvalid),
    .M_AXI_HPM0_rdata (hpm_rdata), .M_AXI_HPM0_rid (hpm_rid), .M_AXI_HPM0_rlast (hpm_rlast), .M_AXI_HPM0_rready (hpm_rready),
    .M_AXI_HPM0_rresp (hpm_rresp), .M_AXI_HPM0_rvalid (hpm_rvalid),
    .M_AXI_HPM0_wdata (hpm_wdata), .M_AXI_HPM0_wlast (hpm_wlast), .M_AXI_HPM0_wready (hpm_wready),
    .M_AXI_HPM0_wstrb (hpm_wstrb), .M_AXI_HPM0_wvalid (hpm_wvalid),
    // memory port of L2 bank 0
    .S_AXI_HP1_araddr (49'(ar[0].addr)), .S_AXI_HP1_arburst (ar[0].burst), .S_AXI_HP1_arcache (4'b0011),
    .S_AXI_HP1_arid (ar[0].id), .S_AXI_HP1_arlen (ar[0].len), .S_AXI_HP1_arlock (1'b0), .S_AXI_HP1_arprot (3'b000),
    .S_AXI_HP1_arqos (4'd0), .S_AXI_HP1_arready (arr[0]), .S_AXI_HP1_arsize (ar[0].size), .S_AXI_HP1_aruser (1'b0),
    .S_AXI_HP1_arvalid (arv[0]),
    .S_AXI_HP1_awaddr (49'(aw[0].addr)), .S_AXI_HP1_awburst (aw[0].burst), .S_AXI_HP1_awcache (4'b0011),
    .S_AXI_HP1_awid (aw[0].id), .S_AXI_HP1_awlen (aw[0].len), .S_AXI_HP1_awlock (1'b0), .S_AXI_HP1_awprot (3'b000),
    .S_AXI_HP1_awqos (4'd0), .S_AXI_HP1_awready (awr[0]), .S_AXI_HP1_awsize (aw[0].size), .S_AXI_HP1_awuser (1'b0),
    .S_AXI_HP1_awvalid (awv[0]),
    .S_AXI_HP1_bid (b[0].id), .S_AXI_HP1_bready (br[0]), .S_AXI_HP1_bresp (b[0].resp), .S_AXI_HP1_bvalid (bv[0]),
    .S_AXI_HP1_rdata (r[0].data), .S_AXI_HP1_rid (r[0].id), .S_AXI_HP1_rlast (r[0].last), .S_AXI_HP1_rready (rr[0]),
    .S_AXI_HP1_rresp (r[0].resp), .S_AXI_HP1_rvalid (rv[0]),
    .S_AXI_HP1_wdata (w[0].data), .S_AXI_HP1_wlast (w[0].last), .S_AXI_HP1_wready (wr[0]), .S_AXI_HP1_wstrb (w[0].strb),
    .S_AXI_HP1_wvalid (wv[0]),
    // memory port of L2 bank 1
    .S_AXI_HP2_araddr (49'(ar[1].addr)), .S_AXI_HP2_arburst (ar[1].burst), .S_AXI_HP2_arcache (4'b0011),
    .S_AXI_HP2_arid (ar[1].id), .S_AXI_HP2_arlen (ar[1].len), .S_AXI_HP2_arlock (1'b0), .S_AXI_HP2_arprot (3'b000),
    .S_AXI_HP2_arqos (4'd0), .S_AXI_HP2_arready (arr[1]), .S_AXI_HP2_arsize (ar[1].size), .S_AXI_HP2_aruser (1'b0),
    .S_AXI_HP2_arvalid (arv[1]),
    .S_AXI_HP2_awaddr (49'(aw[1].addr)), .S_AXI_HP2_awburst (aw[1].burst), .S_AXI_HP2_awcache (4'b0011),
    .S_AXI_HP2_awid (aw[1].id), .S_AXI_HP2_awlen (aw[1].len), .S_AXI_HP2_awlock (1'b0), .S_AXI_HP2_awprot (3'b000),
    .S_AXI_HP2_awqos (4'd0), .S_AXI_HP2_awready (awr[1]), .S_AXI_HP2_awsize (aw[1].size), .S_AXI_HP2_awuser (1'b0),
    .S_AXI_HP2_awvalid (awv[1]),
    .S_AXI_HP2_bid (b[1].id), .S_AXI_HP2_bready (br[1]), .S_AXI_HP2_bresp (b[1].resp), .S_AXI_HP2_bvalid (bv[1]),
    .S_AXI_HP2_rdata (r[1].data), .S_AXI_HP2_rid (r[1].id), .S_AXI_HP2_rlast (r[1].last), .S_AXI_HP2_rready (rr[1]),
    .S_AXI_HP2_rresp (r[1].resp), .S_AXI_HP2_rvalid (rv[1]),
    .S_AXI_HP2_wdata (w[1].data), .S_AXI_HP2_wlast (w[1].last), .S_AXI_HP2_wready (wr[1]), .S_AXI_HP2_wstrb (w[1].strb),
    .S_AXI_HP2_wvalid (wv[1]),
    // commit-trace stream: writes only
    .S_AXI_HP3_araddr ('0), .S_AXI_HP3_arburst (2'b01), .S_AXI_HP3_arcache (4'b0011), .S_AXI_HP3_arid ('0),
    .S_AXI_HP3_arlen ('0), .S_AXI_HP3_arlock (1'b0), .S_AXI_HP3_arprot (3'b000), .S_AXI_HP3_arqos (4'd0),
    .S_AXI_HP3_arready (), .S_AXI_HP3_arsize (3'd4), .S_AXI_HP3_aruser (1'b0), .S_AXI_HP3_arvalid (1'b0),
    .S_AXI_HP3_awaddr (49'(taw.addr)), .S_AXI_HP3_awburst (taw.burst), .S_AXI_HP3_awcache (4'b0011),
    .S_AXI_HP3_awid (taw.id), .S_AXI_HP3_awlen (taw.len), .S_AXI_HP3_awlock (1'b0), .S_AXI_HP3_awprot (3'b000),
    .S_AXI_HP3_awqos (4'd0), .S_AXI_HP3_awready (tawr), .S_AXI_HP3_awsize (taw.size), .S_AXI_HP3_awuser (1'b0),
    .S_AXI_HP3_awvalid (tawv),
    .S_AXI_HP3_bid (tb.id), .S_AXI_HP3_bready (tbr), .S_AXI_HP3_bresp (tb.resp), .S_AXI_HP3_bvalid (tbv),
    .S_AXI_HP3_rdata (), .S_AXI_HP3_rid (), .S_AXI_HP3_rlast (), .S_AXI_HP3_rready (1'b1),
    .S_AXI_HP3_rresp (), .S_AXI_HP3_rvalid (),
    .S_AXI_HP3_wdata (tw.data), .S_AXI_HP3_wlast (tw.last), .S_AXI_HP3_wready (twr), .S_AXI_HP3_wstrb (tw.strb),
    .S_AXI_HP3_wvalid (twv)
  );

  // ---- Clocks and resets ----
  tg_clkgen #(.CORE_MHZ (CORE_MHZ)) u_clkgen (
    .clk_in (pl_clk0), .rst_in (!pl_resetn0), .clk_core, .clk_host, .locked
  );
  logic rst_core, rst_host;
  tg_rst_sync u_rst_core (.clk (clk_core), .rst_async (!pl_resetn0 || !locked), .rst_sync (rst_core));
  tg_rst_sync u_rst_host (.clk (clk_host), .rst_async (!pl_resetn0 || !locked), .rst_sync (rst_host));

  // ---- Host window: AXI4 -> AXI4-Lite ----
  logic [15:0] l_awaddr, l_araddr;
  logic        l_awvalid, l_awready, l_wvalid, l_wready, l_bvalid, l_bready, l_arvalid, l_arready, l_rvalid, l_rready;
  logic [31:0] l_wdata, l_rdata;
  logic [3:0]  l_wstrb;
  logic [1:0]  l_bresp, l_rresp;

  tg_axi4_to_axil #(.ID_W (16), .ADDR_W (40), .LA_W (16)) u_axil (
    .clk (clk_host), .rst (rst_host),
    .s_awid (hpm_awid), .s_awaddr (hpm_awaddr), .s_awlen (hpm_awlen), .s_awvalid (hpm_awvalid), .s_awready (hpm_awready),
    .s_wdata (hpm_wdata), .s_wstrb (hpm_wstrb), .s_wlast (hpm_wlast), .s_wvalid (hpm_wvalid), .s_wready (hpm_wready),
    .s_bid (hpm_bid), .s_bresp (hpm_bresp), .s_bvalid (hpm_bvalid), .s_bready (hpm_bready),
    .s_arid (hpm_arid), .s_araddr (hpm_araddr), .s_arlen (hpm_arlen), .s_arvalid (hpm_arvalid), .s_arready (hpm_arready),
    .s_rid (hpm_rid), .s_rdata (hpm_rdata), .s_rresp (hpm_rresp), .s_rlast (hpm_rlast), .s_rvalid (hpm_rvalid),
    .s_rready (hpm_rready),
    .m_awaddr (l_awaddr), .m_awvalid (l_awvalid), .m_awready (l_awready),
    .m_wdata (l_wdata), .m_wstrb (l_wstrb), .m_wvalid (l_wvalid), .m_wready (l_wready),
    .m_bresp (l_bresp), .m_bvalid (l_bvalid), .m_bready (l_bready),
    .m_araddr (l_araddr), .m_arvalid (l_arvalid), .m_arready (l_arready),
    .m_rdata (l_rdata), .m_rresp (l_rresp), .m_rvalid (l_rvalid), .m_rready (l_rready)
  );

  // ---- SoC ----
  tg_trace_pkg::tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace;
  logic [N_CORES-1:0][COMMIT_WIDTH-1:0]                    trace_v;
  tg_trace_pkg::tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb;
  logic [N_CORES-1:0][TRACE_WB_PORTS-1:0]                  trace_wb_v;
  logic [7:0] status;

  logic uart_txd;
  tanager_soc #(
    .N_CORES (N_CORES), .CLK_HZ (CORE_MHZ * 1_000_000), .CORE_KIND (CORE_KIND), .UART_SERIAL (PMOD_UART),
    .L2_DATA_LAT (CORE_MHZ > 150 ? 4 : 2),   // pipeline the URAM cascade above 150 MHz
    .CORE_RST_INIT (1'b1), .UNCORE_RST_INIT (1'b1)
  ) u_soc (
    .clk (clk_core), .rst (rst_core), .clk_host, .rst_host,
    .s_axil_awaddr (l_awaddr), .s_axil_awvalid (l_awvalid), .s_axil_awready (l_awready),
    .s_axil_wdata (l_wdata), .s_axil_wstrb (l_wstrb), .s_axil_wvalid (l_wvalid), .s_axil_wready (l_wready),
    .s_axil_bresp (l_bresp), .s_axil_bvalid (l_bvalid), .s_axil_bready (l_bready),
    .s_axil_araddr (l_araddr), .s_axil_arvalid (l_arvalid), .s_axil_arready (l_arready),
    .s_axil_rdata (l_rdata), .s_axil_rresp (l_rresp), .s_axil_rvalid (l_rvalid), .s_axil_rready (l_rready),
    .host_irq_o (host_irq),
    .m_axi_ar (ar), .m_axi_ar_valid (arv), .m_axi_ar_ready (arr),
    .m_axi_r (r), .m_axi_r_valid (rv), .m_axi_r_ready (rr),
    .m_axi_aw (aw), .m_axi_aw_valid (awv), .m_axi_aw_ready (awr),
    .m_axi_w (w), .m_axi_w_valid (wv), .m_axi_w_ready (wr),
    .m_axi_b (b), .m_axi_b_valid (bv), .m_axi_b_ready (br),
    .m_axi_trace_aw (taw), .m_axi_trace_aw_valid (tawv), .m_axi_trace_aw_ready (tawr),
    .m_axi_trace_w (tw), .m_axi_trace_w_valid (twv), .m_axi_trace_w_ready (twr),
    .m_axi_trace_b (tb), .m_axi_trace_b_valid (tbv), .m_axi_trace_b_ready (tbr),
    .trace_o (trace), .trace_valid_o (trace_v), .trace_wb_o (trace_wb), .trace_wb_valid_o (trace_wb_v),
    .uart_txd_o (uart_txd), .uart_rxd_i (pmod_uart_rxd),
    .status_o (status)
  );

  assign fan_en_b      = fan_wave[FAN_WAVE] ^ FAN_INVERT;
  assign pmod_uart_txd = PMOD_UART ? uart_txd : 1'bz;
endmodule
