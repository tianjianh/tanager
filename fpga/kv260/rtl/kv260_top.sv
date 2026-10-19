// KV260 board top (docs/spec/soc.md §2.1): the PS block design, the clock generator, reset
// synchronizers, the AXI4 -> AXI4-Lite converter for the host window, and tanager_soc.
//   M_AXI_HPM0_FPD (clk_host, 32-bit) -> tg_axi4_to_axil -> host bridge
//   M_AXI_HPM1_FPD (clk_core, 128-bit) -> the host DMA port (HOST_DMA), else tg_axi_absent
//   L2 banks 0/1 (clk_core, 128-bit)  -> S_AXI_HP1_FPD / S_AXI_HP2_FPD
//   commit-trace stream (clk_core)     -> S_AXI_HP3_FPD (writes only)
//   the PS window (clk_core, 128-bit)  -> S_AXI_LPD, the PS's peripheral registers (stage D, tg_map_pkg
//   PS_WINDOW; idle without it), and the PS-to-PL interrupts of UART1, SD1, GEM3, USB0 and TTC1 back
//   host_irq -> pl_ps_irq0[0];  fan_en_b: the fan's PL regulator (tg_fan, FAN_PL; stage D's D2, DR-147), whose
//   duty is the larger of the PL SYSMON's curve and the PS TTC waveform Linux's pwm-fan drives (DR-129:
//   fan_wave[FAN_WAVE] from the block design, inverted if FAN_INVERT); without FAN_PL, that waveform alone
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
  parameter bit    FAN_INVERT = 1'b0,
  parameter bit    FAN_PL     = 1'b1,     // the fan's PL regulator (build.tcl TG_FAN_PL; 0: the TTC waveform alone)
  parameter logic [63:0] UNCORE_DSP = UNCORE_DSP_DEF,     // slices in DSPs (tg_uncore; build.tcl TG_UNCORE_DSP)
  // The L2's data latency and tg_uncore's register slices, each settable on its own (DR-146; build.tcl
  // TG_L2_DATA_LAT, TG_AR_SLICE ... TG_MEM_SLICE). L2_DATA_LAT 0 picks it by the clock: 4 above
  // 150 MHz (the URAM cascade pipelined), else 2. The slices' defaults are tg_uncore_pkg's.
  parameter int          L2_DATA_LAT   = 0,
  parameter bit          AR_SLICE      = AR_SLICE_DEF,
  parameter bit          B_SLICE       = B_SLICE_DEF,
  parameter bit          D_SLICE       = D_SLICE_DEF,
  parameter bit          W_SLICE       = W_SLICE_DEF,
  parameter logic [3:0]  XBAR_IN_SLICE = XBAR_IN_SLICE_DEF,
  parameter bit          XBAR_SLICE    = XBAR_SLICE_DEF,
  parameter bit          MEM_SLICE     = MEM_SLICE_DEF,
  parameter bit          DEBUG_CNT     = 1'b0,            // board debug counters (build.tcl TG_DEBUG_CNT)
  parameter bit          VIRTIO_WINDOW = 1'b0,            // the forwarded virtio window (build.tcl TG_VIRTIO_WINDOW)
  parameter bit          HOST_DMA      = 1'b0             // the coherent host DMA port on HPM1 (build.tcl TG_HOST_DMA)
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

  // M_AXI_HPM1_FPD: the host DMA port
  hdma_ax_t dma_aw, dma_ar;
  axi_w_t   dma_w;
  hdma_b_t  dma_b;
  hdma_r_t  dma_r;
  logic     dma_awv, dma_awr, dma_wv, dma_wr, dma_bv, dma_br, dma_arv, dma_arr, dma_rv, dma_rr;
  hdma_b_t  soc_b;                      // tanager_soc's side of the port
  hdma_r_t  soc_r;
  logic     soc_awr, soc_wr, soc_bv, soc_arr, soc_rv;

  axi_ax_t [N_BANKS-1:0] ar, aw;
  axi_r_t  [N_BANKS-1:0] r;
  axi_w_t  [N_BANKS-1:0] w;
  axi_b_t  [N_BANKS-1:0] b;
  axi_ax_t taw;                       // commit-trace stream
  axi_w_t  tw;
  axi_b_t  tb;
  logic    tawv, tawr, twv, twr, tbv, tbr;
  logic    [N_BANKS-1:0] arv, arr, rv, rr, awv, awr, wv, wr, bv, br;
  axi_ax_t ps_aw, ps_ar;              // the PS window (tg_uncore idles it when not built)
  axi_w_t  ps_w;
  axi_b_t  ps_b;
  axi_r_t  ps_r;
  logic    ps_awv, ps_awr, ps_wv, ps_wr, ps_bv, ps_br, ps_arv, ps_arr, ps_rv, ps_rr;
  logic [PS_IRQS-1:0] ps_irq;
  logic [3:0]         usb0_ep_irq;    // USB0's endpoint interrupts: [0] is the host controller's line
  logic        ttc_fan, fan_pl_en_b;  // the fan (below): the A53's PWM, the regulator's output
  logic [31:0] fan_status;            // the regulator's status word, to the host bridge (FAN)
  logic [1:0]  board_ctrl;            // the host's BOARD_CTRL: [0] the regulator ignores the A53's PWM ([1] is
                                      // tanager_soc's own: the board's reset path)

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
    // host DMA port
    .M_AXI_HPM1_araddr (dma_ar.addr), .M_AXI_HPM1_arburst (dma_ar.burst), .M_AXI_HPM1_arcache (), .M_AXI_HPM1_arid (dma_ar.id),
    .M_AXI_HPM1_arlen (dma_ar.len), .M_AXI_HPM1_arlock (), .M_AXI_HPM1_arprot (), .M_AXI_HPM1_arqos (),
    .M_AXI_HPM1_arready (dma_arr), .M_AXI_HPM1_arsize (dma_ar.size), .M_AXI_HPM1_aruser (), .M_AXI_HPM1_arvalid (dma_arv),
    .M_AXI_HPM1_awaddr (dma_aw.addr), .M_AXI_HPM1_awburst (dma_aw.burst), .M_AXI_HPM1_awcache (), .M_AXI_HPM1_awid (dma_aw.id),
    .M_AXI_HPM1_awlen (dma_aw.len), .M_AXI_HPM1_awlock (), .M_AXI_HPM1_awprot (), .M_AXI_HPM1_awqos (),
    .M_AXI_HPM1_awready (dma_awr), .M_AXI_HPM1_awsize (dma_aw.size), .M_AXI_HPM1_awuser (), .M_AXI_HPM1_awvalid (dma_awv),
    .M_AXI_HPM1_bid (dma_b.id), .M_AXI_HPM1_bready (dma_br), .M_AXI_HPM1_bresp (dma_b.resp), .M_AXI_HPM1_bvalid (dma_bv),
    .M_AXI_HPM1_rdata (dma_r.data), .M_AXI_HPM1_rid (dma_r.id), .M_AXI_HPM1_rlast (dma_r.last), .M_AXI_HPM1_rready (dma_rr),
    .M_AXI_HPM1_rresp (dma_r.resp), .M_AXI_HPM1_rvalid (dma_rv),
    .M_AXI_HPM1_wdata (dma_w.data), .M_AXI_HPM1_wlast (dma_w.last), .M_AXI_HPM1_wready (dma_wr),
    .M_AXI_HPM1_wstrb (dma_w.strb), .M_AXI_HPM1_wvalid (dma_wv),
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
    .S_AXI_HP3_wvalid (twv),
    // the PS window: device non-bufferable, unprivileged non-secure data accesses
    .S_AXI_LPD_araddr (49'(ps_ar.addr)), .S_AXI_LPD_arburst (ps_ar.burst), .S_AXI_LPD_arcache (4'b0000),
    .S_AXI_LPD_arid (ps_ar.id), .S_AXI_LPD_arlen (ps_ar.len), .S_AXI_LPD_arlock (1'b0), .S_AXI_LPD_arprot (3'b010),
    .S_AXI_LPD_arqos (4'd0), .S_AXI_LPD_arready (ps_arr), .S_AXI_LPD_arsize (ps_ar.size), .S_AXI_LPD_aruser (1'b0),
    .S_AXI_LPD_arvalid (ps_arv),
    .S_AXI_LPD_awaddr (49'(ps_aw.addr)), .S_AXI_LPD_awburst (ps_aw.burst), .S_AXI_LPD_awcache (4'b0000),
    .S_AXI_LPD_awid (ps_aw.id), .S_AXI_LPD_awlen (ps_aw.len), .S_AXI_LPD_awlock (1'b0), .S_AXI_LPD_awprot (3'b010),
    .S_AXI_LPD_awqos (4'd0), .S_AXI_LPD_awready (ps_awr), .S_AXI_LPD_awsize (ps_aw.size), .S_AXI_LPD_awuser (1'b0),
    .S_AXI_LPD_awvalid (ps_awv),
    .S_AXI_LPD_bid (ps_b.id), .S_AXI_LPD_bready (ps_br), .S_AXI_LPD_bresp (ps_b.resp), .S_AXI_LPD_bvalid (ps_bv),
    .S_AXI_LPD_rdata (ps_r.data), .S_AXI_LPD_rid (ps_r.id), .S_AXI_LPD_rlast (ps_r.last), .S_AXI_LPD_rready (ps_rr),
    .S_AXI_LPD_rresp (ps_r.resp), .S_AXI_LPD_rvalid (ps_rv),
    .S_AXI_LPD_wdata (ps_w.data), .S_AXI_LPD_wlast (ps_w.last), .S_AXI_LPD_wready (ps_wr), .S_AXI_LPD_wstrb (ps_w.strb),
    .S_AXI_LPD_wvalid (ps_wv),
    .ps_pl_irq_uart1 (ps_irq[PS_IRQ_UART1]), .ps_pl_irq_sdio1 (ps_irq[PS_IRQ_SD1]),
    .ps_pl_irq_enet3 (ps_irq[PS_IRQ_GEM3]), .ps_pl_irq_usb3_0_endpoint (usb0_ep_irq),
    .ps_pl_irq_ttc1_0 (ps_irq[PS_IRQ_TTC1])
  );
  assign ps_irq[PS_IRQ_USB0] = usb0_ep_irq[0];

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
    .L2_DATA_LAT (L2_DATA_LAT != 0 ? L2_DATA_LAT : CORE_MHZ > 150 ? 4 : 2),
    .CORE_RST_INIT (1'b1), .UNCORE_RST_INIT (1'b1), .UNCORE_DSP (UNCORE_DSP),
    .AR_SLICE (AR_SLICE), .B_SLICE (B_SLICE), .D_SLICE (D_SLICE), .W_SLICE (W_SLICE),
    .XBAR_IN_SLICE (XBAR_IN_SLICE), .XBAR_SLICE (XBAR_SLICE), .MEM_SLICE (MEM_SLICE), .DEBUG_CNT (DEBUG_CNT),
    .VIRTIO_WINDOW (VIRTIO_WINDOW), .HOST_DMA (HOST_DMA)
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
    .s_axi_dma_aw (HOST_DMA ? dma_aw : '0), .s_axi_dma_aw_valid (HOST_DMA && dma_awv), .s_axi_dma_aw_ready (soc_awr),
    .s_axi_dma_w (HOST_DMA ? dma_w : '0), .s_axi_dma_w_valid (HOST_DMA && dma_wv), .s_axi_dma_w_ready (soc_wr),
    .s_axi_dma_b (soc_b), .s_axi_dma_b_valid (soc_bv), .s_axi_dma_b_ready (HOST_DMA && dma_br),
    .s_axi_dma_ar (HOST_DMA ? dma_ar : '0), .s_axi_dma_ar_valid (HOST_DMA && dma_arv), .s_axi_dma_ar_ready (soc_arr),
    .s_axi_dma_r (soc_r), .s_axi_dma_r_valid (soc_rv), .s_axi_dma_r_ready (HOST_DMA && dma_rr),
    .m_axi_ps_aw (ps_aw), .m_axi_ps_aw_valid (ps_awv), .m_axi_ps_aw_ready (ps_awr),
    .m_axi_ps_w (ps_w), .m_axi_ps_w_valid (ps_wv), .m_axi_ps_w_ready (ps_wr),
    .m_axi_ps_b (ps_b), .m_axi_ps_b_valid (ps_bv), .m_axi_ps_b_ready (ps_br),
    .m_axi_ps_ar (ps_ar), .m_axi_ps_ar_valid (ps_arv), .m_axi_ps_ar_ready (ps_arr),
    .m_axi_ps_r (ps_r), .m_axi_ps_r_valid (ps_rv), .m_axi_ps_r_ready (ps_rr), .ps_irq_i (ps_irq),
    .board_status_i (fan_status), .board_ctrl_o (board_ctrl),
    .trace_o (trace), .trace_valid_o (trace_v), .trace_wb_o (trace_wb), .trace_wb_valid_o (trace_wb_v),
    .uart_txd_o (uart_txd), .uart_rxd_i (pmod_uart_rxd),
    .status_o (status)
  );

  // ---- HPM1: the host DMA port, or nothing (reads DECERR, writes dropped) ----
  if (HOST_DMA) begin : g_hdma
    assign dma_awr = soc_awr;
    assign dma_wr  = soc_wr;
    assign dma_b   = soc_b;
    assign dma_bv  = soc_bv;
    assign dma_arr = soc_arr;
    assign dma_r   = soc_r;
    assign dma_rv  = soc_rv;
  end else begin : g_absent
    tg_axi_absent #(.ID_W (HDMA_ID_W), .DATA_W (AXI_DATA_W)) u_absent (
      .clk (clk_core), .rst (rst_core),
      .s_awid (dma_aw.id), .s_awvalid (dma_awv), .s_awready (dma_awr),
      .s_wlast (dma_w.last), .s_wvalid (dma_wv), .s_wready (dma_wr),
      .s_bid (dma_b.id), .s_bresp (dma_b.resp), .s_bvalid (dma_bv), .s_bready (dma_br),
      .s_arid (dma_ar.id), .s_arlen (dma_ar.len), .s_arvalid (dma_arv), .s_arready (dma_arr),
      .s_rid (dma_r.id), .s_rdata (dma_r.data), .s_rresp (dma_r.resp), .s_rlast (dma_r.last), .s_rvalid (dma_rv),
      .s_rready (dma_rr)
    );
    wire unused_dma = ^{soc_awr, soc_wr, soc_b, soc_bv, soc_arr, soc_r, soc_rv};
  end

  wire unused_usb0_ep = ^usb0_ep_irq[3:1];

  // ---- the fan: the PL regulator on the PL's reset alone, so it runs whatever the RISC-V's state ----
  assign ttc_fan = fan_wave[FAN_WAVE] ^ FAN_INVERT;          // the A53's PWM, low = on
  if (FAN_PL) begin : g_fan
    tg_fan #(.CLK_HZ (CORE_MHZ * 1_000_000)) u_fan (
      .clk (clk_core), .rst (rst_core), .ttc_wave_i (ttc_fan), .ignore_ttc_i (board_ctrl[0]),
      .fan_en_b_o (fan_pl_en_b), .status_o (fan_status)
    );
    assign fan_en_b = fan_pl_en_b;
  end else begin : g_fan_ttc
    assign fan_pl_en_b = 1'b1;
    assign fan_status  = '0;
    assign fan_en_b    = ttc_fan;
    wire unused_fan = board_ctrl[0];
  end
  assign pmod_uart_txd = PMOD_UART ? uart_txd : 1'bz;
  wire unused_board_ctrl = board_ctrl[1];
endmodule
