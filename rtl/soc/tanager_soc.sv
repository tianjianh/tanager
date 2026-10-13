// Tanager SoC (docs/spec/soc.md §1): the cores and the uncore, board-independent.
// Simulation top with AXI memory models on m_axi_*, and the SoC core of kv260_top on the FPGA.
//   cores (tg_core, or tg_trafgen stand-ins) -> tg_xbar -> L2 banks -> latency injector -> DRAM window
//                                                       -> boot ROM, device bus (ACLINT, PLIC, UART, host control)
//   host bridge: AXI4-Lite from the host (clk_host), resets, configuration, console, mailbox.
module tanager_soc
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
#(
  parameter int          N_CORES         = NUM_CORES,
  parameter paddr_t      BOOT_ADDR       = BOOTROM_BASE,
  parameter int unsigned CLK_HZ          = 100_000_000,
  parameter int          L2_SETS         = 1024,
  parameter int          L2_MSHR         = 24,
  parameter              L2_PRIM         = "ultra",
  parameter bit          CORE_RST_INIT   = 1'b1,
  parameter bit          UNCORE_RST_INIT = 1'b1,
  parameter logic [39:0] DRAM_BASE_INIT  = '0,
  parameter logic [39:0] DRAM_SIZE_INIT  = '0,
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

  // commit trace of every core, for the simulation harness (the trace ring comes with M4)
  output tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_o,
  output logic    [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_valid_o,
  output tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_o,
  output logic    [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_valid_o,

  output logic [7:0]  status_o
);
  localparam int NH = N_CORES * NUM_THREADS;      // harts in this build
  localparam int NT = NUM_THREADS;

  if (N_CORES < 1 || N_CORES > NUM_CORES) begin : g_bad_cores
    $error("tanager_soc: N_CORES must be 1..NUM_CORES");
  end

  // ---------------------------------------------------------------------------------------------
  // Resets: the host bridge generates the uncore and core resets from rst and its CTRL register
  // ---------------------------------------------------------------------------------------------
  logic uncore_rst, core_rst;

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
        .trace_wb_o (trace_wb_o[c]), .trace_wb_valid_o (trace_wb_valid_o[c])
      );
      assign tg_ops[c]      = '0;
      assign tg_errs[c]     = '0;
      assign tg_err_line[c] = '0;
      assign tg_pass[c]     = '0;
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Interconnect
  // ---------------------------------------------------------------------------------------------
  tl_a_t [N_BANKS-1:0] l2_a; logic [N_BANKS-1:0] l2_av, l2_ar;
  tl_b_t [N_BANKS-1:0] l2_b; logic [N_BANKS-1:0] l2_bv, l2_br;
  tl_c_t [N_BANKS-1:0] l2_c; logic [N_BANKS-1:0] l2_cv, l2_cr;
  tl_d_t [N_BANKS-1:0] l2_d; logic [N_BANKS-1:0] l2_dv, l2_dr;
  tl_e_t [N_BANKS-1:0] l2_e; logic [N_BANKS-1:0] l2_ev, l2_er;
  tl_a_t rom_a, dev_a; logic rom_av, rom_ar, dev_av, dev_ar;
  tl_d_t rom_d, dev_d; logic rom_dv, rom_dr, dev_dv, dev_dr;
  tl_d_t hdma_d; logic hdma_ar, hdma_dv;

  tg_xbar #(.N_CORES (N_CORES), .HOST_DMA (1'b0), .SLICE (1'b1)) u_xbar (
    .clk, .rst (uncore_rst),
    .l1i_a_i (l1i_a), .l1i_a_valid_i (l1i_av), .l1i_a_ready_o (l1i_ar),
    .l1i_d_o (l1i_d), .l1i_d_valid_o (l1i_dv), .l1i_d_ready_i (l1i_dr),
    .l1d_a_i (l1d_a), .l1d_a_valid_i (l1d_av), .l1d_a_ready_o (l1d_ar),
    .l1d_b_o (l1d_b), .l1d_b_valid_o (l1d_bv), .l1d_b_ready_i (l1d_br),
    .l1d_c_i (l1d_c), .l1d_c_valid_i (l1d_cv), .l1d_c_ready_o (l1d_cr),
    .l1d_d_o (l1d_d), .l1d_d_valid_o (l1d_dv), .l1d_d_ready_i (l1d_dr),
    .l1d_e_i (l1d_e), .l1d_e_valid_i (l1d_ev), .l1d_e_ready_o (l1d_er),
    .mmio_a_i (mmio_a), .mmio_a_valid_i (mmio_av), .mmio_a_ready_o (mmio_ar),
    .mmio_d_o (mmio_d), .mmio_d_valid_o (mmio_dv), .mmio_d_ready_i (mmio_dr),
    .hdma_a_i ('0), .hdma_a_valid_i (1'b0), .hdma_a_ready_o (hdma_ar),
    .hdma_d_o (hdma_d), .hdma_d_valid_o (hdma_dv), .hdma_d_ready_i (1'b1),
    .l2_a_o (l2_a), .l2_a_valid_o (l2_av), .l2_a_ready_i (l2_ar),
    .l2_b_i (l2_b), .l2_b_valid_i (l2_bv), .l2_b_ready_o (l2_br),
    .l2_c_o (l2_c), .l2_c_valid_o (l2_cv), .l2_c_ready_i (l2_cr),
    .l2_d_i (l2_d), .l2_d_valid_i (l2_dv), .l2_d_ready_o (l2_dr),
    .l2_e_o (l2_e), .l2_e_valid_o (l2_ev), .l2_e_ready_i (l2_er),
    .rom_a_o (rom_a), .rom_a_valid_o (rom_av), .rom_a_ready_i (rom_ar),
    .rom_d_i (rom_d), .rom_d_valid_i (rom_dv), .rom_d_ready_o (rom_dr),
    .dev_a_o (dev_a), .dev_a_valid_o (dev_av), .dev_a_ready_i (dev_ar),
    .dev_d_i (dev_d), .dev_d_valid_i (dev_dv), .dev_d_ready_o (dev_dr)
  );

  // ---------------------------------------------------------------------------------------------
  // L2 and the memory path of each bank
  // ---------------------------------------------------------------------------------------------
  axi_ax_t [N_BANKS-1:0] l2_ar_ch, l2_aw_ch, ij_ar, ij_aw;
  logic    [N_BANKS-1:0] l2_arv, l2_arr, l2_awv, l2_awr, ij_arv, ij_arr, ij_awv, ij_awr;
  axi_r_t  [N_BANKS-1:0] l2_r_ch, ij_r;
  logic    [N_BANKS-1:0] l2_rv, l2_rr, ij_rv, ij_rr;
  axi_w_t  [N_BANKS-1:0] l2_w_ch, ij_w;
  logic    [N_BANKS-1:0] l2_wv, l2_wr, ij_wv, ij_wr;
  axi_b_t  [N_BANKS-1:0] l2_b_ch, ij_b;
  logic    [N_BANKS-1:0] l2_bvv, l2_brr, ij_bv, ij_br;
  logic                  l2_init_done;
  logic    [N_BANKS-1:0] ev_hit, ev_miss, ev_wb, ev_probe, ev_err;

  tg_l2 #(.N_AGENTS (N_CORES), .SETS (L2_SETS), .N_MSHR (L2_MSHR), .DATA_PRIM (L2_PRIM)) u_l2 (
    .clk, .rst (uncore_rst),
    .a_i (l2_a), .a_valid_i (l2_av), .a_ready_o (l2_ar),
    .b_o (l2_b), .b_valid_o (l2_bv), .b_ready_i (l2_br),
    .c_i (l2_c), .c_valid_i (l2_cv), .c_ready_o (l2_cr),
    .d_o (l2_d), .d_valid_o (l2_dv), .d_ready_i (l2_dr),
    .e_i (l2_e), .e_valid_i (l2_ev), .e_ready_o (l2_er),
    .ar_o (l2_ar_ch), .ar_valid_o (l2_arv), .ar_ready_i (l2_arr),
    .r_i (l2_r_ch), .r_valid_i (l2_rv), .r_ready_o (l2_rr),
    .aw_o (l2_aw_ch), .aw_valid_o (l2_awv), .aw_ready_i (l2_awr),
    .w_o (l2_w_ch), .w_valid_o (l2_wv), .w_ready_i (l2_wr),
    .bresp_i (l2_b_ch), .bresp_valid_i (l2_bvv), .bresp_ready_o (l2_brr),
    .init_done_o (l2_init_done),
    .ev_hit_o (ev_hit), .ev_miss_o (ev_miss), .ev_wb_o (ev_wb), .ev_probe_o (ev_probe), .ev_err_o (ev_err)
  );

  logic [9:0]  inj_rd, inj_wr;
  logic        inj_mode;
  logic [8:0]  inj_bw;
  logic [39:0] win_base, win_size;
  logic [N_BANKS-1:0][31:0] inj_cnt, inj_sum;
  logic [N_BANKS-1:0][15:0] inj_max;

  for (genvar b = 0; b < N_BANKS; b++) begin : g_mem
    tg_axi_lat_inj u_inj (
      .clk, .rst (uncore_rst),
      .rd_delay_i (inj_rd), .wr_delay_i (inj_wr), .mode_i (inj_mode), .bw_rate_i (inj_bw),
      .st_rd_count_o (inj_cnt[b]), .st_lat_sum_o (inj_sum[b]), .st_lat_max_o (inj_max[b]),
      .s_ar_i (l2_ar_ch[b]), .s_ar_valid_i (l2_arv[b]), .s_ar_ready_o (l2_arr[b]),
      .s_r_o (l2_r_ch[b]), .s_r_valid_o (l2_rv[b]), .s_r_ready_i (l2_rr[b]),
      .s_aw_i (l2_aw_ch[b]), .s_aw_valid_i (l2_awv[b]), .s_aw_ready_o (l2_awr[b]),
      .s_w_i (l2_w_ch[b]), .s_w_valid_i (l2_wv[b]), .s_w_ready_o (l2_wr[b]),
      .s_b_o (l2_b_ch[b]), .s_b_valid_o (l2_bvv[b]), .s_b_ready_i (l2_brr[b]),
      .m_ar_o (ij_ar[b]), .m_ar_valid_o (ij_arv[b]), .m_ar_ready_i (ij_arr[b]),
      .m_r_i (ij_r[b]), .m_r_valid_i (ij_rv[b]), .m_r_ready_o (ij_rr[b]),
      .m_aw_o (ij_aw[b]), .m_aw_valid_o (ij_awv[b]), .m_aw_ready_i (ij_awr[b]),
      .m_w_o (ij_w[b]), .m_w_valid_o (ij_wv[b]), .m_w_ready_i (ij_wr[b]),
      .m_b_i (ij_b[b]), .m_b_valid_i (ij_bv[b]), .m_b_ready_o (ij_br[b])
    );
    tg_axi_window u_win (
      .clk, .rst (uncore_rst), .base_i (win_base), .size_i (win_size),
      .s_ar_i (ij_ar[b]), .s_ar_valid_i (ij_arv[b]), .s_ar_ready_o (ij_arr[b]),
      .s_r_o (ij_r[b]), .s_r_valid_o (ij_rv[b]), .s_r_ready_i (ij_rr[b]),
      .s_aw_i (ij_aw[b]), .s_aw_valid_i (ij_awv[b]), .s_aw_ready_o (ij_awr[b]),
      .s_w_i (ij_w[b]), .s_w_valid_i (ij_wv[b]), .s_w_ready_o (ij_wr[b]),
      .s_b_o (ij_b[b]), .s_b_valid_o (ij_bv[b]), .s_b_ready_i (ij_br[b]),
      .m_ar_o (m_axi_ar[b]), .m_ar_valid_o (m_axi_ar_valid[b]), .m_ar_ready_i (m_axi_ar_ready[b]),
      .m_r_i (m_axi_r[b]), .m_r_valid_i (m_axi_r_valid[b]), .m_r_ready_o (m_axi_r_ready[b]),
      .m_aw_o (m_axi_aw[b]), .m_aw_valid_o (m_axi_aw_valid[b]), .m_aw_ready_i (m_axi_aw_ready[b]),
      .m_w_o (m_axi_w[b]), .m_w_valid_o (m_axi_w_valid[b]), .m_w_ready_i (m_axi_w_ready[b]),
      .m_b_i (m_axi_b[b]), .m_b_valid_i (m_axi_b_valid[b]), .m_b_ready_o (m_axi_b_ready[b])
    );
  end

  // Injector statistics, both ports
  logic [31:0] inj_cnt_all, inj_sum_all;
  logic [15:0] inj_max_all;
  always_comb begin
    inj_cnt_all = '0;
    inj_sum_all = '0;
    inj_max_all = '0;
    for (int b = 0; b < N_BANKS; b++) begin
      inj_cnt_all = inj_cnt_all + inj_cnt[b];
      inj_sum_all = inj_sum_all + inj_sum[b];
      if (inj_max[b] > inj_max_all) inj_max_all = inj_max[b];
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Boot ROM and the device bus
  // ---------------------------------------------------------------------------------------------
  tg_bootrom u_rom (
    .clk, .rst (uncore_rst),
    .a_i (rom_a), .a_valid_i (rom_av), .a_ready_o (rom_ar), .d_o (rom_d), .d_valid_o (rom_dv), .d_ready_i (rom_dr)
  );

  dev_req_t           dreq;
  logic [DEV_N-1:0]   dreq_v;
  dev_rsp_t [DEV_N-1:0] drsp;
  tg_tl_dev u_dev (
    .clk, .rst (uncore_rst),
    .a_i (dev_a), .a_valid_i (dev_av), .a_ready_o (dev_ar), .d_o (dev_d), .d_valid_o (dev_dv), .d_ready_i (dev_dr),
    .req_o (dreq), .req_valid_o (dreq_v), .rsp_i (drsp)
  );

  logic [NH-1:0] msi_all, mti_all;
  tg_aclint #(.N_HARTS (NH), .CLK_HZ (CLK_HZ)) u_aclint (
    .clk, .rst (uncore_rst), .req_i (dreq), .req_valid_i (dreq_v[DEV_ACLINT]), .rsp_o (drsp[DEV_ACLINT]),
    .irq_msi_o (msi_all), .irq_mti_o (mti_all), .mtime_o (mtime)
  );
  assign msi = msi_all;
  assign mti = mti_all;

  logic uart_irq, mbox_irq;
  logic [PLIC_NSRC-1:0] plic_src;
  localparam logic [PLIC_NSRC-1:0] EDGE_SRC = PLIC_NSRC'(((1 << NH) - 1) << IRQ_MERR0);
  always_comb begin
    plic_src = '0;
    plic_src[IRQ_UART]    = uart_irq;
    plic_src[IRQ_HOSTCTL] = mbox_irq;
    for (int h = 0; h < NH; h++) plic_src[IRQ_MERR0 + h] = merr[h];
  end
  tg_plic #(.N_SRC (PLIC_NSRC), .N_CTX (2 * NH), .EDGE_SRC (EDGE_SRC)) u_plic (
    .clk, .rst (uncore_rst), .req_i (dreq), .req_valid_i (dreq_v[DEV_PLIC]), .rsp_o (drsp[DEV_PLIC]),
    .src_i (plic_src), .irq_o (plic_irq)
  );

  logic       con_tx_v, con_tx_r, con_rx_v, con_rx_r;
  logic [7:0] con_tx_b, con_rx_b;
  tg_uart #(.CLK_HZ (CLK_HZ)) u_uart (
    .clk, .rst (uncore_rst), .req_i (dreq), .req_valid_i (dreq_v[DEV_UART]), .rsp_o (drsp[DEV_UART]),
    .irq_o (uart_irq),
    .tx_valid_o (con_tx_v), .tx_ready_i (con_tx_r), .tx_byte_o (con_tx_b),
    .rx_valid_i (con_rx_v), .rx_ready_o (con_rx_r), .rx_byte_i (con_rx_b)
  );

  // ---------------------------------------------------------------------------------------------
  // Host bridge (host control is the device bus's fourth device)
  // ---------------------------------------------------------------------------------------------
  logic [31:0] tg_ops_all;
  logic [15:0] tg_errs_all;
  logic [27:0] tg_err_line_any;
  always_comb begin
    tg_ops_all      = '0;
    tg_errs_all     = '0;
    tg_err_line_any = '0;
    for (int c = 0; c < N_CORES; c++) begin
      tg_ops_all  = tg_ops_all + tg_ops[c];
      tg_errs_all = tg_errs_all + tg_errs[c];
      if (tg_errs[c] != '0) tg_err_line_any = tg_err_line[c];
    end
  end

  localparam logic [7:0] CFG_CODE = (CFG_NAME == "smt2") ? 8'd1 : (CFG_NAME == "st_w3") ? 8'd2 :
                                    (CFG_NAME == "smt2_w3") ? 8'd3 : 8'd0;
  tg_host_bridge #(
    .CLK_HZ (CLK_HZ), .CFG_CODE (CFG_CODE), .N_CORES_SOC (N_CORES),
    .CORE_RST_INIT (CORE_RST_INIT), .UNCORE_RST_INIT (UNCORE_RST_INIT),
    .DRAM_BASE_INIT (DRAM_BASE_INIT), .DRAM_SIZE_INIT (DRAM_SIZE_INIT)
  ) u_host (
    .clk_host, .rst_host,
    .s_awaddr (s_axil_awaddr), .s_awvalid (s_axil_awvalid), .s_awready (s_axil_awready),
    .s_wdata (s_axil_wdata), .s_wstrb (s_axil_wstrb), .s_wvalid (s_axil_wvalid), .s_wready (s_axil_wready),
    .s_bresp (s_axil_bresp), .s_bvalid (s_axil_bvalid), .s_bready (s_axil_bready),
    .s_araddr (s_axil_araddr), .s_arvalid (s_axil_arvalid), .s_arready (s_axil_arready),
    .s_rdata (s_axil_rdata), .s_rresp (s_axil_rresp), .s_rvalid (s_axil_rvalid), .s_rready (s_axil_rready),
    .host_irq_o,
    .clk, .rst, .core_rst_o (core_rst), .uncore_rst_o (uncore_rst),
    .req_i (dreq), .req_valid_i (dreq_v[DEV_HOSTCTL]), .rsp_o (drsp[DEV_HOSTCTL]),
    .mbox_irq_o (mbox_irq),
    .dram_base_o (win_base), .dram_size_o (win_size),
    .inj_rd_delay_o (inj_rd), .inj_wr_delay_o (inj_wr), .inj_mode_o (inj_mode), .inj_bw_o (inj_bw),
    .l2_init_done_i (l2_init_done),
    .inj_rd_count_i (inj_cnt_all), .inj_lat_sum_i (inj_sum_all), .inj_lat_max_i (inj_max_all),
    .tg_en_o (tg_en), .tg_base_o (tg_base), .tg_lines_o (tg_lines),
    .tg_ops_i (tg_ops_all), .tg_errs_i (tg_errs_all), .tg_err_line_i (tg_err_line_any), .tg_pass_i (tg_pass[0]),
    .con_tx_valid_i (con_tx_v), .con_tx_ready_o (con_tx_r), .con_tx_byte_i (con_tx_b),
    .con_rx_valid_o (con_rx_v), .con_rx_ready_i (con_rx_r), .con_rx_byte_o (con_rx_b)
  );

  // ---------------------------------------------------------------------------------------------
  // Status (debug / ILA): sticky L2 error, init, resets, console activity
  // ---------------------------------------------------------------------------------------------
  logic l2_err_q;
  always_ff @(posedge clk) begin
    if (uncore_rst) l2_err_q <= 1'b0;
    else if (|ev_err) l2_err_q <= 1'b1;
  end
  assign status_o = {2'b00, |tg_errs_all, l2_err_q, con_tx_v, l2_init_done, uncore_rst, core_rst};

  // The traffic-generator controls are unused in builds with real cores.
  wire unused = ^{hdma_ar, hdma_d, hdma_dv, ev_hit, ev_miss, ev_wb, ev_probe, tg_en, tg_base, tg_lines, tg_pass};
endmodule
