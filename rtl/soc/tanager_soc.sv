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
  parameter int          L2_DATA_LAT     = 2,          // 4 for the URAM cascade at 200 MHz
  parameter bit          CORE_RST_INIT   = 1'b1,
  parameter bit          UNCORE_RST_INIT = 1'b1,
  parameter logic [39:0] DRAM_BASE_INIT  = '0,
  parameter logic [39:0] DRAM_SIZE_INIT  = '0,
  parameter bit          UART_SERIAL     = 1'b0,       // console on uart_txd_o/uart_rxd_i (tg_uncore)
  parameter logic [31:0] XBAR_DSP        = '1,         // crossbar slices in DSPs (tg_uncore, tg_xbar DSP_SKID)
  parameter string       CORE_KIND       = "core"     // "core" or "trafgen"
) (
  input  logic        clk,
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
    end else begin : g_tgc
      tg_core #(.CORE_ID (c)) u_core (
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
        .trace_stall_i (trace_stall[c])
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
    .XBAR_DSP (XBAR_DSP)
  ) u_uncore (
    .clk, .rst, .clk_host, .rst_host,
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
    .tg_en_o (tg_en), .tg_base_o (tg_base), .tg_lines_o (tg_lines),
    .tg_ops_i (tg_ops), .tg_errs_i (tg_errs), .tg_err_line_i (tg_err_line), .tg_pass_i (tg_pass),
    .uart_txd_o, .uart_rxd_i,
    .status_o
  );

  // The traffic-generator controls are read only by tg_trafgen builds.
  wire unused = ^{tg_en, tg_base, tg_lines};
endmodule
