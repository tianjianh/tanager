// Tanager SoC (docs/spec/soc.md §1): the cores and the uncore (tg_uncore), board-independent.
// Simulation top with AXI memory models on m_axi_*, and the SoC core of kv260_top on the FPGA.
//   cores (tg_core, or tg_trafgen stand-ins) -> tg_uncore: interconnect, L2, memory path, devices,
//                                               host bridge and trace ring
module tanager_soc
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
#(
  parameter int          N_CORES         = NUM_CORES,
  parameter paddr_t      BOOT_ADDR       = BOOTROM_BASE,
  parameter int unsigned CLK_HZ          = 100_000_000,
  parameter int          L2_SETS         = 1024,
  parameter int          L2_MSHR         = 24,
  parameter              L2_PRIM         = "ultra",
  parameter int          L2_DATA_LAT     = L2_DATA_LAT_DEF,  // 2; 4 for the URAM cascade at 200 MHz
  parameter bit          CORE_RST_INIT   = 1'b1,
  parameter bit          UNCORE_RST_INIT = 1'b1,
  parameter logic [39:0] DRAM_BASE_INIT  = '0,
  parameter logic [39:0] DRAM_SIZE_INIT  = '0,
  parameter bit          UART_SERIAL     = 1'b0,       // console on uart_txd_o/uart_rxd_i (tg_uncore)
  parameter logic [63:0] UNCORE_DSP      = UNCORE_DSP_DEF,    // slices in DSPs (tg_uncore)
  // tg_uncore's register slices (DR-135, DR-146): each switch's meaning is at tg_uncore's parameter,
  // and the defaults are tg_uncore_pkg's
  parameter bit          AR_SLICE        = AR_SLICE_DEF,
  parameter bit          B_SLICE         = B_SLICE_DEF,
  parameter bit          D_SLICE         = D_SLICE_DEF,
  parameter bit          W_SLICE         = W_SLICE_DEF,
  parameter logic [3:0]  XBAR_IN_SLICE   = XBAR_IN_SLICE_DEF,
  parameter bit          XBAR_SLICE      = XBAR_SLICE_DEF,
  parameter bit          MEM_SLICE       = MEM_SLICE_DEF,
  parameter bit          L2_WB_PACE      = L2_WB_PACE_DEF,    // the L2's write-back batching (tg_uncore)
  parameter logic [15:0] L2_PACE_INIT    = L2_PACE_INIT_DEF,  // its settings at reset (tg_uncore)
  parameter bit          DEBUG_CNT       = 1'b0,              // board debug counters (tg_uncore)
  parameter bit          VIRTIO_WINDOW   = 1'b0,              // the forwarded virtio window (tg_uncore)
  parameter bit          HOST_DMA        = 1'b0,              // the coherent host DMA port (tg_uncore)
  parameter bit          LAT_INJ         = 1'b1,              // the two latency injectors: 0 in release builds (tg_uncore; DR-177)
  parameter bit          RELEASE         = 1'b0,              // a release build (tg_uncore; DR-180)
  parameter int          BREAK_LOG2      = 28,                // the PMOD reset hook's shortest break (tg_uncore)
  parameter string       CORE_KIND       = "core"     // "core" or "trafgen"
) (
  input  logic        clk,
  input  logic        clk2x,          // twice clk, rising with it: the cores' URF (DR-174); else 0
  input  logic        rst,
  input  logic        clk_host,
  input  logic        rst_host,

  // host AXI4-Lite slave (clk_host)
  input  logic [15:0] s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [15:0] s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  output logic        host_irq_o,

  // memory: one AXI4 master per L2 bank (clk), addresses already on the carve-out
  output axi_ax_t [N_BANKS-1:0] m_axi_ar,
  output logic    [N_BANKS-1:0] m_axi_ar_valid,
  input  logic    [N_BANKS-1:0] m_axi_ar_ready,
  input  axi_r_t  [N_BANKS-1:0] m_axi_r,
  input  logic    [N_BANKS-1:0] m_axi_r_valid,
  output logic    [N_BANKS-1:0] m_axi_r_ready,
  output axi_ax_t [N_BANKS-1:0] m_axi_aw,
  output logic    [N_BANKS-1:0] m_axi_aw_valid,
  input  logic    [N_BANKS-1:0] m_axi_aw_ready,
  output axi_w_t  [N_BANKS-1:0] m_axi_w,
  output logic    [N_BANKS-1:0] m_axi_w_valid,
  input  logic    [N_BANKS-1:0] m_axi_w_ready,
  input  axi_b_t  [N_BANKS-1:0] m_axi_b,
  input  logic    [N_BANKS-1:0] m_axi_b_valid,
  output logic    [N_BANKS-1:0] m_axi_b_ready,

  // commit-trace stream (docs/spec/uncore-trace.md): AXI4 write master (clk), PS physical addresses
  output axi_ax_t               m_axi_trace_aw,
  output logic                  m_axi_trace_aw_valid,
  input  logic                  m_axi_trace_aw_ready,
  output axi_w_t                m_axi_trace_w,
  output logic                  m_axi_trace_w_valid,
  input  logic                  m_axi_trace_w_ready,
  input  axi_b_t                m_axi_trace_b,
  input  logic                  m_axi_trace_b_valid,
  output logic                  m_axi_trace_b_ready,

  // the coherent host DMA port's AXI4 slave (clk; HOST_DMA, else ignored with its outputs 0)
  input  hdma_ax_t              s_axi_dma_aw,
  input  logic                  s_axi_dma_aw_valid,
  output logic                  s_axi_dma_aw_ready,
  input  axi_w_t                s_axi_dma_w,
  input  logic                  s_axi_dma_w_valid,
  output logic                  s_axi_dma_w_ready,
  output hdma_b_t               s_axi_dma_b,
  output logic                  s_axi_dma_b_valid,
  input  logic                  s_axi_dma_b_ready,
  input  hdma_ax_t              s_axi_dma_ar,
  input  logic                  s_axi_dma_ar_valid,
  output logic                  s_axi_dma_ar_ready,
  output hdma_r_t               s_axi_dma_r,
  output logic                  s_axi_dma_r_valid,
  input  logic                  s_axi_dma_r_ready,

  // the PS window's AXI4 master and the PS's interrupt levels (clk; tg_map_pkg PS_WINDOW, else idle)
  output axi_ax_t               m_axi_ps_aw,
  output logic                  m_axi_ps_aw_valid,
  input  logic                  m_axi_ps_aw_ready,
  output axi_w_t                m_axi_ps_w,
  output logic                  m_axi_ps_w_valid,
  input  logic                  m_axi_ps_w_ready,
  input  axi_b_t                m_axi_ps_b,
  input  logic                  m_axi_ps_b_valid,
  output logic                  m_axi_ps_b_ready,
  output axi_ax_t               m_axi_ps_ar,
  output logic                  m_axi_ps_ar_valid,
  input  logic                  m_axi_ps_ar_ready,
  input  axi_r_t                m_axi_ps_r,
  input  logic                  m_axi_ps_r_valid,
  output logic                  m_axi_ps_r_ready,
  input  logic [PS_IRQS-1:0]    ps_irq_i,
  // the board's status word (clk), read by the host at FAN (0x1400): the KV260's fan regulator; 0 elsewhere
  input  logic [31:0]           board_status_i,
  // BOARD_CTRL (clk, the host's 0x1404): [0] the KV260's fan regulator ignores the A53's PWM, [1] the board's
  // reset path is enabled (tg_uncore)
  output logic [1:0]            board_ctrl_o,

  // commit trace of every core, also to the simulation harness
  output tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_o,
  output logic    [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_valid_o,
  output tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_o,
  output logic    [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_valid_o,

  // console serial line (UART_SERIAL = 1), idle high otherwise
  output logic        uart_txd_o,
  input  logic        uart_rxd_i,

  output logic [7:0]  status_o
);
  localparam int NH = N_CORES * NUM_THREADS;      // harts in this build
  localparam int NT = NUM_THREADS;

  if (N_CORES < 1 || N_CORES > NUM_CORES) begin : g_bad_cores
    $error("tanager_soc: N_CORES must be 1..NUM_CORES");
  end

  // The cores' reset comes from the uncore's host bridge (rst, or the host's CTRL register); the
  // trace stream holds a core's commit while its buffers are near full (interfaces.md §5).
  logic               core_rst;
  logic [N_CORES-1:0] trace_stall;

  // ---------------------------------------------------------------------------------------------
  // Cores
  // ---------------------------------------------------------------------------------------------
  tl_a_t [N_CORES-1:0] l1i_a, l1d_a, mmio_a;
  logic  [N_CORES-1:0] l1i_av, l1i_ar, l1d_av, l1d_ar, mmio_av, mmio_ar;
  tl_d_t [N_CORES-1:0] l1i_d, l1d_d, mmio_d;
  logic  [N_CORES-1:0] l1i_dv, l1i_dr, l1d_dv, l1d_dr, mmio_dv, mmio_dr;
  tl_b_t [N_CORES-1:0] l1d_b;  logic [N_CORES-1:0] l1d_bv, l1d_br;
  tl_c_t [N_CORES-1:0] l1d_c;  logic [N_CORES-1:0] l1d_cv, l1d_cr;
  tl_e_t [N_CORES-1:0] l1d_e;  logic [N_CORES-1:0] l1d_ev, l1d_er;

  logic [2*NH-1:0] plic_irq;
  logic [NH-1:0]   msi, mti, merr;
  logic [63:0]     mtime;

  logic        tg_en;
  logic [27:0] tg_base;
  logic [23:0] tg_lines;
  logic [N_CORES-1:0][31:0] tg_ops;
  logic [N_CORES-1:0][15:0] tg_errs, tg_pass;
  logic [N_CORES-1:0][27:0] tg_err_line;
  // The cores' board-debug words (tg_core dbg_o: the word dbg_sel_i picks, built with DBG_WORD = DEBUG_CNT;
  // DR-150), which the uncore's debug counters read (index 128 + 32c + w). Declared ahead of the cores that
  // drive them: a name used before its declaration is an implicit net in synthesis.
  logic [4:0]               core_dbg_sel;
  logic [N_CORES-1:0][31:0] core_dbg;

  for (genvar c = 0; c < N_CORES; c++) begin : g_core
    logic [NT-1:0] mei, sei, mt, ms, me;
    for (genvar t = 0; t < NT; t++) begin : g_hart
      assign mei[t] = plic_irq[2 * (c * NT + t)];
      assign sei[t] = plic_irq[2 * (c * NT + t) + 1];
      assign mt[t]  = mti[c * NT + t];
      assign ms[t]  = msi[c * NT + t];
      assign merr[c * NT + t] = me[t];
    end
    if (CORE_KIND == "trafgen") begin : g_tg
      tg_trafgen #(.CORE_ID (c)) u_core (
        .clk, .rst (core_rst), .boot_addr_i (BOOT_ADDR),
        .irq_mei_i (mei), .irq_sei_i (sei), .irq_mti_i (mt), .irq_msi_i (ms), .irq_ssi_i ('0),
        .mtime_i (mtime), .debug_req_i ('0), .merr_o (me),
        .l1i_a_o (l1i_a[c]), .l1i_a_valid_o (l1i_av[c]), .l1i_a_ready_i (l1i_ar[c]),
        .l1i_d_i (l1i_d[c]), .l1i_d_valid_i (l1i_dv[c]), .l1i_d_ready_o (l1i_dr[c]),
        .l1d_a_o (l1d_a[c]), .l1d_a_valid_o (l1d_av[c]), .l1d_a_ready_i (l1d_ar[c]),
        .l1d_b_i (l1d_b[c]), .l1d_b_valid_i (l1d_bv[c]), .l1d_b_ready_o (l1d_br[c]),
        .l1d_c_o (l1d_c[c]), .l1d_c_valid_o (l1d_cv[c]), .l1d_c_ready_i (l1d_cr[c]),
        .l1d_d_i (l1d_d[c]), .l1d_d_valid_i (l1d_dv[c]), .l1d_d_ready_o (l1d_dr[c]),
        .l1d_e_o (l1d_e[c]), .l1d_e_valid_o (l1d_ev[c]), .l1d_e_ready_i (l1d_er[c]),
        .mmio_a_o (mmio_a[c]), .mmio_a_valid_o (mmio_av[c]), .mmio_a_ready_i (mmio_ar[c]),
        .mmio_d_i (mmio_d[c]), .mmio_d_valid_i (mmio_dv[c]), .mmio_d_ready_o (mmio_dr[c]),
        .trace_o (trace_o[c]), .trace_valid_o (trace_valid_o[c]),
        .trace_wb_o (trace_wb_o[c]), .trace_wb_valid_o (trace_wb_valid_o[c]),
        .tg_en_i (tg_en), .tg_base_i (tg_base + 28'(c) * 28'(tg_lines)), .tg_lines_i (tg_lines),
        .tg_ops_o (tg_ops[c]), .tg_errs_o (tg_errs[c]), .tg_err_line_o (tg_err_line[c]), .tg_pass_o (tg_pass[c])
      );
      assign core_dbg[c] = '0;
    end else begin : g_tgc
      tg_core #(.CORE_ID (c), .DBG_WORD (DEBUG_CNT)) u_core (
        .clk, .clk2x, .rst (core_rst), .boot_addr_i (BOOT_ADDR),
        .irq_mei_i (mei), .irq_sei_i (sei), .irq_mti_i (mt), .irq_msi_i (ms), .irq_ssi_i ('0),
        .mtime_i (mtime), .debug_req_i ('0), .merr_o (me),
        .l1i_a_o (l1i_a[c]), .l1i_a_valid_o (l1i_av[c]), .l1i_a_ready_i (l1i_ar[c]),
        .l1i_d_i (l1i_d[c]), .l1i_d_valid_i (l1i_dv[c]), .l1i_d_ready_o (l1i_dr[c]),
        .l1d_a_o (l1d_a[c]), .l1d_a_valid_o (l1d_av[c]), .l1d_a_ready_i (l1d_ar[c]),
        .l1d_b_i (l1d_b[c]), .l1d_b_valid_i (l1d_bv[c]), .l1d_b_ready_o (l1d_br[c]),
        .l1d_c_o (l1d_c[c]), .l1d_c_valid_o (l1d_cv[c]), .l1d_c_ready_i (l1d_cr[c]),
        .l1d_d_i (l1d_d[c]), .l1d_d_valid_i (l1d_dv[c]), .l1d_d_ready_o (l1d_dr[c]),
        .l1d_e_o (l1d_e[c]), .l1d_e_valid_o (l1d_ev[c]), .l1d_e_ready_i (l1d_er[c]),
        .mmio_a_o (mmio_a[c]), .mmio_a_valid_o (mmio_av[c]), .mmio_a_ready_i (mmio_ar[c]),
        .mmio_d_i (mmio_d[c]), .mmio_d_valid_i (mmio_dv[c]), .mmio_d_ready_o (mmio_dr[c]),
        .trace_o (trace_o[c]), .trace_valid_o (trace_valid_o[c]),
        .trace_wb_o (trace_wb_o[c]), .trace_wb_valid_o (trace_wb_valid_o[c]),
        .trace_stall_i (trace_stall[c]),
        .dbg_sel_i (core_dbg_sel), .dbg_o (core_dbg[c])
      );
      assign tg_ops[c]      = '0;
      assign tg_errs[c]     = '0;
      assign tg_err_line[c] = '0;
      assign tg_pass[c]     = '0;
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Uncore
  // ---------------------------------------------------------------------------------------------
  tg_uncore #(
    .N_CORES (N_CORES), .CLK_HZ (CLK_HZ), .L2_SETS (L2_SETS), .L2_MSHR (L2_MSHR), .L2_PRIM (L2_PRIM),
    .L2_DATA_LAT (L2_DATA_LAT), .CORE_RST_INIT (CORE_RST_INIT), .UNCORE_RST_INIT (UNCORE_RST_INIT),
    .DRAM_BASE_INIT (DRAM_BASE_INIT), .DRAM_SIZE_INIT (DRAM_SIZE_INIT), .UART_SERIAL (UART_SERIAL),
    .UNCORE_DSP (UNCORE_DSP), .AR_SLICE (AR_SLICE), .B_SLICE (B_SLICE), .D_SLICE (D_SLICE), .W_SLICE (W_SLICE),
    .XBAR_IN_SLICE (XBAR_IN_SLICE), .XBAR_SLICE (XBAR_SLICE), .MEM_SLICE (MEM_SLICE), .DEBUG_CNT (DEBUG_CNT),
    .VIRTIO_WINDOW (VIRTIO_WINDOW), .HOST_DMA (HOST_DMA), .LAT_INJ (LAT_INJ), .RELEASE (RELEASE),
    .TRAFGEN (CORE_KIND == "trafgen"), .BREAK_LOG2 (BREAK_LOG2), .L2_WB_PACE (L2_WB_PACE),
    .L2_PACE_INIT (L2_PACE_INIT)
  ) u_uncore (
    .clk, .rst, .clk_host, .rst_host,
    .core_dbg_sel_o (core_dbg_sel), .core_dbg_i (core_dbg),
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid,
    .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid,
    .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready, .host_irq_o,
    .m_axi_ar, .m_axi_ar_valid, .m_axi_ar_ready, .m_axi_r, .m_axi_r_valid, .m_axi_r_ready,
    .m_axi_aw, .m_axi_aw_valid, .m_axi_aw_ready, .m_axi_w, .m_axi_w_valid, .m_axi_w_ready,
    .m_axi_b, .m_axi_b_valid, .m_axi_b_ready,
    .core_rst_o (core_rst),
    .l1i_a_i (l1i_a), .l1i_a_valid_i (l1i_av), .l1i_a_ready_o (l1i_ar),
    .l1i_d_o (l1i_d), .l1i_d_valid_o (l1i_dv), .l1i_d_ready_i (l1i_dr),
    .l1d_a_i (l1d_a), .l1d_a_valid_i (l1d_av), .l1d_a_ready_o (l1d_ar),
    .l1d_b_o (l1d_b), .l1d_b_valid_o (l1d_bv), .l1d_b_ready_i (l1d_br),
    .l1d_c_i (l1d_c), .l1d_c_valid_i (l1d_cv), .l1d_c_ready_o (l1d_cr),
    .l1d_d_o (l1d_d), .l1d_d_valid_o (l1d_dv), .l1d_d_ready_i (l1d_dr),
    .l1d_e_i (l1d_e), .l1d_e_valid_i (l1d_ev), .l1d_e_ready_o (l1d_er),
    .mmio_a_i (mmio_a), .mmio_a_valid_i (mmio_av), .mmio_a_ready_o (mmio_ar),
    .mmio_d_o (mmio_d), .mmio_d_valid_o (mmio_dv), .mmio_d_ready_i (mmio_dr),
    .plic_irq_o (plic_irq), .msi_o (msi), .mti_o (mti), .mtime_o (mtime), .merr_i (merr),
    .trace_i (trace_o), .trace_valid_i (trace_valid_o), .trace_wb_i (trace_wb_o), .trace_wb_valid_i (trace_wb_valid_o),
    .trace_stall_o (trace_stall),
    .m_axi_trace_aw, .m_axi_trace_aw_valid, .m_axi_trace_aw_ready, .m_axi_trace_w, .m_axi_trace_w_valid,
    .m_axi_trace_w_ready, .m_axi_trace_b, .m_axi_trace_b_valid, .m_axi_trace_b_ready,
    .s_axi_dma_aw, .s_axi_dma_aw_valid, .s_axi_dma_aw_ready, .s_axi_dma_w, .s_axi_dma_w_valid, .s_axi_dma_w_ready,
    .s_axi_dma_b, .s_axi_dma_b_valid, .s_axi_dma_b_ready, .s_axi_dma_ar, .s_axi_dma_ar_valid, .s_axi_dma_ar_ready,
    .s_axi_dma_r, .s_axi_dma_r_valid, .s_axi_dma_r_ready,
    .m_axi_ps_aw, .m_axi_ps_aw_valid, .m_axi_ps_aw_ready, .m_axi_ps_w, .m_axi_ps_w_valid, .m_axi_ps_w_ready,
    .m_axi_ps_b, .m_axi_ps_b_valid, .m_axi_ps_b_ready, .m_axi_ps_ar, .m_axi_ps_ar_valid, .m_axi_ps_ar_ready,
    .m_axi_ps_r, .m_axi_ps_r_valid, .m_axi_ps_r_ready, .ps_irq_i, .board_status_i, .board_ctrl_o,
    .tg_en_o (tg_en), .tg_base_o (tg_base), .tg_lines_o (tg_lines),
    .tg_ops_i (tg_ops), .tg_errs_i (tg_errs), .tg_err_line_i (tg_err_line), .tg_pass_i (tg_pass),
    .uart_txd_o, .uart_rxd_i,
    .status_o
  );

  // The traffic-generator controls are read only by tg_trafgen builds.
  wire unused = ^{tg_en, tg_base, tg_lines};
endmodule
