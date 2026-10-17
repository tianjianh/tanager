// The uncore (docs/spec/soc.md §1, docs/spec/uncore.md): everything in tanager_soc except the cores.
// Its ports toward the cores are the cores' ports (interfaces.md), so it can also be synthesised
// on its own, as the per-unit LUT budget run does (fpga/budget, unit "uncore").
//   cores -> tg_xbar -> L2 banks -> latency injector -> DRAM window -> AXI slice -> m_axi_*
//                    -> boot ROM, device bus (ACLINT, PLIC, UART, host control, the virtio window)
//   host bridge: AXI4-Lite from the host (clk_host), resets, configuration, console, mailbox;
//   commit-trace streaming into DDR (its own AXI master);
//   the coherent host DMA port (HOST_DMA): an AXI4 slave from the host -> tg_hdma -> the crossbar's hdma.
module tg_uncore
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
#(
  parameter int          N_CORES         = NUM_CORES,
  parameter int unsigned CLK_HZ          = 100_000_000,
  parameter int          L2_SETS         = 1024,
  parameter int          L2_MSHR         = 24,
  parameter              L2_PRIM         = "ultra",
  parameter int          L2_DATA_LAT     = L2_DATA_LAT_DEF,  // 2; 4 for the URAM cascade at 200 MHz
  parameter bit          CORE_RST_INIT   = 1'b1,
  parameter bit          UNCORE_RST_INIT = 1'b1,
  parameter logic [39:0] DRAM_BASE_INIT  = '0,
  parameter logic [39:0] DRAM_SIZE_INIT  = '0,
  parameter bit          UART_SERIAL     = 1'b0,       // console on uart_txd_o/uart_rxd_i (8N1), else host only
  // Register slices whose main data register sits in DSP48E2s (tg_skid DSP; DR-136), one bit per
  // site, so a placement check can return a site to fabric without new RTL:
  //   [31:0]  tg_xbar DSP_SKID (D per initiator, A per target, C per bank, B per core);
  //   [41:32] memory port p's tg_axi_slice: bit 32 + 5p + {0 AR, 1 AW, 2 W, 3 R, 4 B};
  //   [43:42] L2 bank b's R slice; [63:44] reserved.
  // The default keeps in DSPs only the sites whose DSP form met 200 MHz in two out-of-context
  // placements of the whole uncore (docs/perf/budgets.md §4): the device bus's A slice (bit 19 with
  // two banks), the banks' C slices and the memory ports' W slices. A DSP input passes through its
  // ALU, so the slices behind arbiters (D, B, the banks' A, memory AR) stay in fabric; memory AW, the
  // memory R slices (their slower clock-to-out) and the L2 R slices failed in one placement and stay
  // there too; the AXI B slices (a few bits) always do.
  parameter logic [63:0] UNCORE_DSP      = UNCORE_DSP_DEF,
  // A register slice on each bank's AXI AR, before the latency injector: it cuts the L2's AR
  // handshake (pick, MSHR LUTRAM, the window's range check, ready back into the pick), the
  // uncore's longest path at 200 MHz, for a cycle on every fill (DR-135; on by default, the user's
  // decision of 10-15: +0.056% cycles at st, +0.134% at smt2 over the first 20M of the Linux boot)
  parameter bit          AR_SLICE        = AR_SLICE_DEF,
  // A register slice on each bank's TileLink B (probes), before the crossbar: it would cut the probe
  // handshake (the L2's probe pick, the destination, the crossbar's per-core B arbiter, ready back
  // into the probe flags), for a cycle on every probe. Off: a DR-135 reserve item, measured in docs/spec/soc.md
  parameter bit          B_SLICE         = B_SLICE_DEF,
  // A register slice on each bank's TileLink D (responses), before the crossbar: it would cut the D
  // channel's handshake (a bank's D queue and output arbiter, the crossbar's per-initiator D arbiter,
  // which weighs both banks, then the ready back into the bank's queue and credit), for a cycle on
  // every L2 response. Off: a DR-135 reserve item, measured in docs/spec/soc.md
  parameter bit          D_SLICE         = D_SLICE_DEF,
  // Register slices on each bank's AXI AW and W, before the latency injector, as the AR slice is on
  // AR: they would cut the write-back path from the L2 to the memory path by the PS ports (G4-FP:
  // the memory W slices at -2.3 / -2.4 ns with the banks at the URAM column), for a cycle on every
  // write-back. Off: a DR-135 reserve item, measured in docs/spec/soc.md
  parameter bit          W_SLICE         = W_SLICE_DEF,
  // Register slices on the cores' request channels, between the core ports and the crossbar: the
  // interface register stage on the uncore's side (G4-FP: core -> A slices -2.87 ns, core -> C
  // -3.05 ns, mostly wire). Bit 0 the caches' A (l1d, l1i), bit 1 the MMIO A, bit 2 the l1d C,
  // bit 3 the l1d E; each costs a cycle on every message of its channel. Off: DR-135 reserve items,
  // measured in docs/spec/soc.md
  parameter logic [3:0]  XBAR_IN_SLICE   = XBAR_IN_SLICE_DEF,
  // The crossbar's own register slices (every target-side A, C and E output, every initiator-side D
  // and B output) and the memory ports' AXI slices toward the PS. On, as built for 200 MHz; off
  // they cost no cycle and no area: a timing study at the lower clock of DR-145
  parameter bit          XBAR_SLICE      = XBAR_SLICE_DEF,
  parameter bit          MEM_SLICE       = MEM_SLICE_DEF,
  // The L2 MSHRs' way flip-flops one-hot (else binary): the reservations and the ProbeAck search take
  // them without a decode, on the S2 path (DR-142; cycle-identical either way)
  parameter bit          L2_MWAY_OH      = 1'b1,
  // The L2 directory RAM written a cycle after S2, from the bypass's newest history entry (with a
  // third entry), so S2's paths end at flip-flops, not the RAM's pins (DR-142; cycle-identical)
  parameter bit          L2_DIR_S3       = 1'b1,
  // The commit-trace stream to the PS (tg_trace_stream and the host bridge's trace registers), built
  // when the trace is (tg_trace_pkg COMMIT_TRACE, +define+TG_COMMIT_TRACE; DR-146). Off, the trace inputs are
  // ignored, trace_stall_o is 0, the trace master stays idle (AWVALID = WVALID = 0, BREADY = 1) and
  // the host bridge's capability bit 3 (trace streaming) reads 0
  parameter bit          TRACE           = COMMIT_TRACE,
  // Board debug (DR-147): message counters per L2 bank and per core's data cache, and a snapshot of
  // every coherence channel's valid and ready, which the host reads one at a time (host bridge DBG_SEL,
  // DBG_VAL; tanager-host dbg). Off by default: no logic
  parameter bit          DEBUG_CNT       = 1'b0,
  // The forwarded virtio window (docs/spec/soc.md §8.1, DR-147 stage C): the virtio slots at
  // VIRTIO_BASE become a device whose accesses the A53 serves through the host bridge's VQ_*
  // registers, with InterruptStatus and InterruptACK in RTL and PLIC sources 1-4. Off by default:
  // the slots answer denied, as before
  parameter bit          VIRTIO_WINDOW   = 1'b0,
  // The coherent host DMA port (docs/spec/soc.md §8.1, DR-147 stage C): s_axi_dma_* (the PS's
  // M_AXI_HPM1_FPD) reaches the RISC-V's RAM through tg_hdma and the crossbar's hdma initiator, so the
  // L2 serves the host's reads and writes coherently; each write line's AccessAck cycle can be recorded
  // for lockstep (host bridge HDMA_*). Off by default: no logic, s_axi_dma_* ignored and its outputs 0
  parameter bit          HOST_DMA        = 1'b0,
  localparam int         NH              = N_CORES * NUM_THREADS   // harts
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

  // toward the cores: the cores' reset, their TileLink ports, interrupts and time
  output logic                  core_rst_o,
  input  tl_a_t [N_CORES-1:0]   l1i_a_i,
  input  logic  [N_CORES-1:0]   l1i_a_valid_i,
  output logic  [N_CORES-1:0]   l1i_a_ready_o,
  output tl_d_t [N_CORES-1:0]   l1i_d_o,
  output logic  [N_CORES-1:0]   l1i_d_valid_o,
  input  logic  [N_CORES-1:0]   l1i_d_ready_i,
  input  tl_a_t [N_CORES-1:0]   l1d_a_i,
  input  logic  [N_CORES-1:0]   l1d_a_valid_i,
  output logic  [N_CORES-1:0]   l1d_a_ready_o,
  output tl_b_t [N_CORES-1:0]   l1d_b_o,
  output logic  [N_CORES-1:0]   l1d_b_valid_o,
  input  logic  [N_CORES-1:0]   l1d_b_ready_i,
  input  tl_c_t [N_CORES-1:0]   l1d_c_i,
  input  logic  [N_CORES-1:0]   l1d_c_valid_i,
  output logic  [N_CORES-1:0]   l1d_c_ready_o,
  output tl_d_t [N_CORES-1:0]   l1d_d_o,
  output logic  [N_CORES-1:0]   l1d_d_valid_o,
  input  logic  [N_CORES-1:0]   l1d_d_ready_i,
  input  tl_e_t [N_CORES-1:0]   l1d_e_i,
  input  logic  [N_CORES-1:0]   l1d_e_valid_i,
  output logic  [N_CORES-1:0]   l1d_e_ready_o,
  input  tl_a_t [N_CORES-1:0]   mmio_a_i,
  input  logic  [N_CORES-1:0]   mmio_a_valid_i,
  output logic  [N_CORES-1:0]   mmio_a_ready_o,
  output tl_d_t [N_CORES-1:0]   mmio_d_o,
  output logic  [N_CORES-1:0]   mmio_d_valid_o,
  input  logic  [N_CORES-1:0]   mmio_d_ready_i,
  output logic [2*NH-1:0]       plic_irq_o,      // hart h: [2h] machine, [2h+1] supervisor external
  output logic [NH-1:0]         msi_o,
  output logic [NH-1:0]         mti_o,
  output logic [63:0]           mtime_o,
  input  logic [NH-1:0]         merr_i,

  // commit trace of every core, streamed into DDR; back-pressure to each core (interfaces.md §5)
  input  tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_i,
  input  logic    [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_valid_i,
  input  tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_i,
  input  logic    [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_valid_i,
  output logic    [N_CORES-1:0]                     trace_stall_o,
  // the trace stream's AXI4 write master (clk): PS physical addresses (S_AXI_HP3_FPD on the KV260)
  output axi_ax_t                                   m_axi_trace_aw,
  output logic                                      m_axi_trace_aw_valid,
  input  logic                                      m_axi_trace_aw_ready,
  output axi_w_t                                    m_axi_trace_w,
  output logic                                      m_axi_trace_w_valid,
  input  logic                                      m_axi_trace_w_ready,
  input  axi_b_t                                    m_axi_trace_b,
  input  logic                                      m_axi_trace_b_valid,
  output logic                                      m_axi_trace_b_ready,

  // the coherent host DMA port's AXI4 slave (clk; HOST_DMA): window offsets in address bits [31:0]
  input  hdma_ax_t                                  s_axi_dma_aw,
  input  logic                                      s_axi_dma_aw_valid,
  output logic                                      s_axi_dma_aw_ready,
  input  axi_w_t                                    s_axi_dma_w,
  input  logic                                      s_axi_dma_w_valid,
  output logic                                      s_axi_dma_w_ready,
  output hdma_b_t                                   s_axi_dma_b,
  output logic                                      s_axi_dma_b_valid,
  input  logic                                      s_axi_dma_b_ready,
  input  hdma_ax_t                                  s_axi_dma_ar,
  input  logic                                      s_axi_dma_ar_valid,
  output logic                                      s_axi_dma_ar_ready,
  output hdma_r_t                                   s_axi_dma_r,
  output logic                                      s_axi_dma_r_valid,
  input  logic                                      s_axi_dma_r_ready,

  // traffic-generator controls and results (host registers; tied off with real cores)
  output logic                    tg_en_o,
  output logic [27:0]             tg_base_o,
  output logic [23:0]             tg_lines_o,
  input  logic [N_CORES-1:0][31:0] tg_ops_i,
  input  logic [N_CORES-1:0][15:0] tg_errs_i,
  input  logic [N_CORES-1:0][27:0] tg_err_line_i,
  input  logic [N_CORES-1:0][15:0] tg_pass_i,

  // console serial line (UART_SERIAL = 1): 8N1 at the 16550's divisor; idle high otherwise
  output logic        uart_txd_o,
  input  logic        uart_rxd_i,

  output logic [7:0]  status_o
);
  if (N_CORES < 1 || N_CORES > NUM_CORES) begin : g_bad_cores
    $error("tg_uncore: N_CORES must be 1..NUM_CORES");
  end

  logic uncore_rst;     // from the host bridge (rst, or the host's CTRL register)

  // ---------------------------------------------------------------------------------------------
  // Interconnect
  // ---------------------------------------------------------------------------------------------
  tl_a_t [N_BANKS-1:0] l2_a; logic [N_BANKS-1:0] l2_av, l2_ar;
  tl_b_t [N_BANKS-1:0] l2_b; logic [N_BANKS-1:0] l2_bv, l2_br;
  tl_b_t [N_BANKS-1:0] xb_b; logic [N_BANKS-1:0] xb_bv, xb_br;   // B into the crossbar (B_SLICE)
  for (genvar b = 0; b < N_BANKS; b++) begin : g_bsl
    if (B_SLICE) begin : g_s
      tg_skid #(.T (tl_b_t)) u_bs (
        .clk, .rst (uncore_rst), .in_valid (l2_bv[b]), .in_ready (l2_br[b]), .in_data (l2_b[b]),
        .out_valid (xb_bv[b]), .out_ready (xb_br[b]), .out_data (xb_b[b])
      );
    end else begin : g_w
      assign xb_b[b]  = l2_b[b];
      assign xb_bv[b] = l2_bv[b];
      assign l2_br[b] = xb_br[b];
    end
  end
  tl_c_t [N_BANKS-1:0] l2_c; logic [N_BANKS-1:0] l2_cv, l2_cr;
  tl_d_t [N_BANKS-1:0] l2_d; logic [N_BANKS-1:0] l2_dv, l2_dr;
  tl_d_t [N_BANKS-1:0] xb_d; logic [N_BANKS-1:0] xb_dv, xb_dr;   // D into the crossbar (D_SLICE)
  for (genvar b = 0; b < N_BANKS; b++) begin : g_dsl
    if (D_SLICE) begin : g_s
      tg_skid #(.T (tl_d_t)) u_ds (
        .clk, .rst (uncore_rst), .in_valid (l2_dv[b]), .in_ready (l2_dr[b]), .in_data (l2_d[b]),
        .out_valid (xb_dv[b]), .out_ready (xb_dr[b]), .out_data (xb_d[b])
      );
    end else begin : g_w
      assign xb_d[b]  = l2_d[b];
      assign xb_dv[b] = l2_dv[b];
      assign l2_dr[b] = xb_dr[b];
    end
  end
  tl_e_t [N_BANKS-1:0] l2_e; logic [N_BANKS-1:0] l2_ev, l2_er;
  tl_a_t rom_a, dev_a; logic rom_av, rom_ar, dev_av, dev_ar;
  tl_d_t rom_d, dev_d; logic rom_dv, rom_dr, dev_dv, dev_dr;
  tl_a_t hdma_a; logic hdma_av, hdma_ar;
  tl_d_t hdma_d; logic hdma_dv, hdma_dr;

  // The cores' requests into the crossbar, through a slice where XBAR_IN_SLICE says so. The caches'
  // A data, mask and corrupt are constants inside the crossbar, so their slice bits have no loads.
  tl_a_t [N_CORES-1:0] x_l1i_a, x_l1d_a, x_mmio_a;
  logic  [N_CORES-1:0] x_l1i_av, x_l1i_ar, x_l1d_av, x_l1d_ar, x_mmio_av, x_mmio_ar;
  tl_c_t [N_CORES-1:0] x_l1d_c;
  logic  [N_CORES-1:0] x_l1d_cv, x_l1d_cr;
  tl_e_t [N_CORES-1:0] x_l1d_e;
  logic  [N_CORES-1:0] x_l1d_ev, x_l1d_er;
  for (genvar c = 0; c < N_CORES; c++) begin : g_isl
    if (XBAR_IN_SLICE[0]) begin : g_ca
      tg_skid #(.T (tl_a_t)) u_l1i (
        .clk, .rst (uncore_rst), .in_valid (l1i_a_valid_i[c]), .in_ready (l1i_a_ready_o[c]), .in_data (l1i_a_i[c]),
        .out_valid (x_l1i_av[c]), .out_ready (x_l1i_ar[c]), .out_data (x_l1i_a[c])
      );
      tg_skid #(.T (tl_a_t)) u_l1d (
        .clk, .rst (uncore_rst), .in_valid (l1d_a_valid_i[c]), .in_ready (l1d_a_ready_o[c]), .in_data (l1d_a_i[c]),
        .out_valid (x_l1d_av[c]), .out_ready (x_l1d_ar[c]), .out_data (x_l1d_a[c])
      );
    end else begin : g_caw
      assign x_l1i_a[c] = l1i_a_i[c];  assign x_l1i_av[c] = l1i_a_valid_i[c];  assign l1i_a_ready_o[c] = x_l1i_ar[c];
      assign x_l1d_a[c] = l1d_a_i[c];  assign x_l1d_av[c] = l1d_a_valid_i[c];  assign l1d_a_ready_o[c] = x_l1d_ar[c];
    end
    if (XBAR_IN_SLICE[1]) begin : g_ma
      tg_skid #(.T (tl_a_t)) u_mmio (
        .clk, .rst (uncore_rst), .in_valid (mmio_a_valid_i[c]), .in_ready (mmio_a_ready_o[c]), .in_data (mmio_a_i[c]),
        .out_valid (x_mmio_av[c]), .out_ready (x_mmio_ar[c]), .out_data (x_mmio_a[c])
      );
    end else begin : g_maw
      assign x_mmio_a[c] = mmio_a_i[c];  assign x_mmio_av[c] = mmio_a_valid_i[c];  assign mmio_a_ready_o[c] = x_mmio_ar[c];
    end
    if (XBAR_IN_SLICE[2]) begin : g_c
      tg_skid #(.T (tl_c_t)) u_c (
        .clk, .rst (uncore_rst), .in_valid (l1d_c_valid_i[c]), .in_ready (l1d_c_ready_o[c]), .in_data (l1d_c_i[c]),
        .out_valid (x_l1d_cv[c]), .out_ready (x_l1d_cr[c]), .out_data (x_l1d_c[c])
      );
    end else begin : g_cw
      assign x_l1d_c[c] = l1d_c_i[c];  assign x_l1d_cv[c] = l1d_c_valid_i[c];  assign l1d_c_ready_o[c] = x_l1d_cr[c];
    end
    if (XBAR_IN_SLICE[3]) begin : g_e
      tg_skid #(.T (tl_e_t)) u_e (
        .clk, .rst (uncore_rst), .in_valid (l1d_e_valid_i[c]), .in_ready (l1d_e_ready_o[c]), .in_data (l1d_e_i[c]),
        .out_valid (x_l1d_ev[c]), .out_ready (x_l1d_er[c]), .out_data (x_l1d_e[c])
      );
    end else begin : g_ew
      assign x_l1d_e[c] = l1d_e_i[c];  assign x_l1d_ev[c] = l1d_e_valid_i[c];  assign l1d_e_ready_o[c] = x_l1d_er[c];
    end
  end

  tg_xbar #(.N_CORES (N_CORES), .HOST_DMA (HOST_DMA), .SLICE (XBAR_SLICE), .DSP_SKID (UNCORE_DSP[31:0])) u_xbar (
    .clk, .rst (uncore_rst),
    .l1i_a_i (x_l1i_a), .l1i_a_valid_i (x_l1i_av), .l1i_a_ready_o (x_l1i_ar), .l1i_d_o, .l1i_d_valid_o, .l1i_d_ready_i,
    .l1d_a_i (x_l1d_a), .l1d_a_valid_i (x_l1d_av), .l1d_a_ready_o (x_l1d_ar), .l1d_b_o, .l1d_b_valid_o, .l1d_b_ready_i,
    .l1d_c_i (x_l1d_c), .l1d_c_valid_i (x_l1d_cv), .l1d_c_ready_o (x_l1d_cr), .l1d_d_o, .l1d_d_valid_o, .l1d_d_ready_i,
    .l1d_e_i (x_l1d_e), .l1d_e_valid_i (x_l1d_ev), .l1d_e_ready_o (x_l1d_er),
    .mmio_a_i (x_mmio_a), .mmio_a_valid_i (x_mmio_av), .mmio_a_ready_o (x_mmio_ar), .mmio_d_o, .mmio_d_valid_o, .mmio_d_ready_i,
    .hdma_a_i (hdma_a), .hdma_a_valid_i (hdma_av), .hdma_a_ready_o (hdma_ar),
    .hdma_d_o (hdma_d), .hdma_d_valid_o (hdma_dv), .hdma_d_ready_i (hdma_dr),
    .l2_a_o (l2_a), .l2_a_valid_o (l2_av), .l2_a_ready_i (l2_ar),
    .l2_b_i (xb_b), .l2_b_valid_i (xb_bv), .l2_b_ready_o (xb_br),
    .l2_c_o (l2_c), .l2_c_valid_o (l2_cv), .l2_c_ready_i (l2_cr),
    .l2_d_i (xb_d), .l2_d_valid_i (xb_dv), .l2_d_ready_o (xb_dr),
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
  axi_r_t  [N_BANKS-1:0] l2_r_ch, ij_r, wn_r;
  logic    [N_BANKS-1:0] l2_rv, l2_rr, ij_rv, ij_rr, wn_rv, wn_rr;
  axi_ax_t [N_BANKS-1:0] wn_ar, wn_aw;
  logic    [N_BANKS-1:0] wn_arv, wn_arr, wn_awv, wn_awr;
  axi_w_t  [N_BANKS-1:0] wn_w;
  logic    [N_BANKS-1:0] wn_wv, wn_wr;
  axi_b_t  [N_BANKS-1:0] wn_b;
  logic    [N_BANKS-1:0] wn_bv, wn_br;
  axi_w_t  [N_BANKS-1:0] l2_w_ch, ij_w;
  logic    [N_BANKS-1:0] l2_wv, l2_wr, ij_wv, ij_wr;
  axi_b_t  [N_BANKS-1:0] l2_b_ch, ij_b;
  logic    [N_BANKS-1:0] l2_bvv, l2_brr, ij_bv, ij_br;
  logic                  l2_init_done;
  logic    [N_BANKS-1:0] ev_hit, ev_miss, ev_wb, ev_probe, ev_err;

  tg_l2 #(.N_AGENTS (N_CORES), .SETS (L2_SETS), .N_MSHR (L2_MSHR), .DATA_PRIM (L2_PRIM),
          .DATA_LAT (L2_DATA_LAT), .RSLICE_DSP ({2'b00, UNCORE_DSP[43:42]}), .MWAY_OH (L2_MWAY_OH),
          .DIR_S3 (L2_DIR_S3)) u_l2 (
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
    axi_ax_t ar_s;
    logic    ar_sv, ar_sr;
    if (AR_SLICE) begin : g_ars
      tg_skid #(.T (axi_ax_t)) u_ars (
        .clk, .rst (uncore_rst), .in_valid (l2_arv[b]), .in_ready (l2_arr[b]), .in_data (l2_ar_ch[b]),
        .out_valid (ar_sv), .out_ready (ar_sr), .out_data (ar_s)
      );
    end else begin : g_arw
      assign ar_s      = l2_ar_ch[b];
      assign ar_sv     = l2_arv[b];
      assign l2_arr[b] = ar_sr;
    end
    axi_ax_t aw_s;
    logic    aw_sv, aw_sr;
    axi_w_t  w_s;
    logic    w_sv, w_sr;
    if (W_SLICE) begin : g_wsl
      tg_skid #(.T (axi_ax_t)) u_aws (
        .clk, .rst (uncore_rst), .in_valid (l2_awv[b]), .in_ready (l2_awr[b]), .in_data (l2_aw_ch[b]),
        .out_valid (aw_sv), .out_ready (aw_sr), .out_data (aw_s)
      );
      tg_skid #(.T (axi_w_t)) u_ws (
        .clk, .rst (uncore_rst), .in_valid (l2_wv[b]), .in_ready (l2_wr[b]), .in_data (l2_w_ch[b]),
        .out_valid (w_sv), .out_ready (w_sr), .out_data (w_s)
      );
    end else begin : g_wsw
      assign aw_s      = l2_aw_ch[b];
      assign aw_sv     = l2_awv[b];
      assign l2_awr[b] = aw_sr;
      assign w_s       = l2_w_ch[b];
      assign w_sv      = l2_wv[b];
      assign l2_wr[b]  = w_sr;
    end
    tg_axi_lat_inj u_inj (
      .clk, .rst (uncore_rst),
      .rd_delay_i (inj_rd), .wr_delay_i (inj_wr), .mode_i (inj_mode), .bw_rate_i (inj_bw),
      .st_rd_count_o (inj_cnt[b]), .st_lat_sum_o (inj_sum[b]), .st_lat_max_o (inj_max[b]),
      .s_ar_i (ar_s), .s_ar_valid_i (ar_sv), .s_ar_ready_o (ar_sr),
      .s_r_o (l2_r_ch[b]), .s_r_valid_o (l2_rv[b]), .s_r_ready_i (l2_rr[b]),
      .s_aw_i (aw_s), .s_aw_valid_i (aw_sv), .s_aw_ready_o (aw_sr),
      .s_w_i (w_s), .s_w_valid_i (w_sv), .s_w_ready_o (w_sr),
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
      .m_ar_o (wn_ar[b]), .m_ar_valid_o (wn_arv[b]), .m_ar_ready_i (wn_arr[b]),
      .m_r_i (wn_r[b]), .m_r_valid_i (wn_rv[b]), .m_r_ready_o (wn_rr[b]),
      .m_aw_o (wn_aw[b]), .m_aw_valid_o (wn_awv[b]), .m_aw_ready_i (wn_awr[b]),
      .m_w_o (wn_w[b]), .m_w_valid_o (wn_wv[b]), .m_w_ready_i (wn_wr[b]),
      .m_b_i (wn_b[b]), .m_b_valid_i (wn_bv[b]), .m_b_ready_o (wn_br[b])
    );
    // register slice toward the PS port: the window's adder and the long route end at flip-flops
    tg_axi_slice #(.DSP (UNCORE_DSP[32 + 5 * b +: 5]), .ON (MEM_SLICE)) u_slice (
      .clk, .rst (uncore_rst),
      .s_ar_i (wn_ar[b]), .s_ar_valid_i (wn_arv[b]), .s_ar_ready_o (wn_arr[b]),
      .s_r_o (wn_r[b]), .s_r_valid_o (wn_rv[b]), .s_r_ready_i (wn_rr[b]),
      .s_aw_i (wn_aw[b]), .s_aw_valid_i (wn_awv[b]), .s_aw_ready_o (wn_awr[b]),
      .s_w_i (wn_w[b]), .s_w_valid_i (wn_wv[b]), .s_w_ready_o (wn_wr[b]),
      .s_b_o (wn_b[b]), .s_b_valid_o (wn_bv[b]), .s_b_ready_i (wn_br[b]),
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
  // The coherent host DMA port (HOST_DMA): the host's AXI4 reads and writes as Gets and Puts on the
  // crossbar's hdma initiator; completions and line counts go to the host bridge
  // ---------------------------------------------------------------------------------------------
  logic        cpl_en, cpl_v, cpl_r;
  logic [25:0] cpl_line;
  logic [31:0] cpl_cycle, hdma_rd_lines, hdma_wr_lines, hdma_wr_drops;
  if (HOST_DMA) begin : g_hdma
    tg_hdma #(.ID_W (HDMA_ID_W)) u_hdma (
      .clk, .rst (uncore_rst),
      .s_awid (s_axi_dma_aw.id), .s_awaddr (s_axi_dma_aw.addr), .s_awlen (s_axi_dma_aw.len),
      .s_awsize (s_axi_dma_aw.size), .s_awburst (s_axi_dma_aw.burst), .s_awvalid (s_axi_dma_aw_valid),
      .s_awready (s_axi_dma_aw_ready),
      .s_wdata (s_axi_dma_w.data), .s_wstrb (s_axi_dma_w.strb), .s_wlast (s_axi_dma_w.last),
      .s_wvalid (s_axi_dma_w_valid), .s_wready (s_axi_dma_w_ready),
      .s_bid (s_axi_dma_b.id), .s_bresp (s_axi_dma_b.resp), .s_bvalid (s_axi_dma_b_valid), .s_bready (s_axi_dma_b_ready),
      .s_arid (s_axi_dma_ar.id), .s_araddr (s_axi_dma_ar.addr), .s_arlen (s_axi_dma_ar.len),
      .s_arsize (s_axi_dma_ar.size), .s_arburst (s_axi_dma_ar.burst), .s_arvalid (s_axi_dma_ar_valid),
      .s_arready (s_axi_dma_ar_ready),
      .s_rid (s_axi_dma_r.id), .s_rdata (s_axi_dma_r.data), .s_rresp (s_axi_dma_r.resp), .s_rlast (s_axi_dma_r.last),
      .s_rvalid (s_axi_dma_r_valid), .s_rready (s_axi_dma_r_ready),
      .ram_size_i (win_size),
      .a_o (hdma_a), .a_valid_o (hdma_av), .a_ready_i (hdma_ar),
      .d_i (hdma_d), .d_valid_i (hdma_dv), .d_ready_o (hdma_dr),
      .cpl_en_i (cpl_en), .cpl_valid_o (cpl_v), .cpl_line_o (cpl_line), .cpl_cycle_o (cpl_cycle), .cpl_ready_i (cpl_r),
      .rd_lines_o (hdma_rd_lines), .wr_lines_o (hdma_wr_lines), .wr_drops_o (hdma_wr_drops)
    );
  end else begin : g_no_hdma
    assign hdma_a             = '0;
    assign hdma_av            = 1'b0;
    assign hdma_dr            = 1'b1;
    assign s_axi_dma_aw_ready = 1'b0;
    assign s_axi_dma_w_ready  = 1'b0;
    assign s_axi_dma_b        = '0;
    assign s_axi_dma_b_valid  = 1'b0;
    assign s_axi_dma_ar_ready = 1'b0;
    assign s_axi_dma_r        = '0;
    assign s_axi_dma_r_valid  = 1'b0;
    assign cpl_v              = 1'b0;
    assign cpl_line           = '0;
    assign cpl_cycle          = '0;
    assign hdma_rd_lines      = '0;
    assign hdma_wr_lines      = '0;
    assign hdma_wr_drops      = '0;
    wire unused_hdma = ^{s_axi_dma_aw, s_axi_dma_aw_valid, s_axi_dma_w, s_axi_dma_w_valid, s_axi_dma_b_ready,
                         s_axi_dma_ar, s_axi_dma_ar_valid, s_axi_dma_r_ready, hdma_ar, hdma_d, hdma_dv, cpl_en, cpl_r};
  end
`ifndef SYNTHESIS
  // the completions' cycle is the trace stream's capture count (both count clk from the uncore reset)
  if (HOST_DMA && TRACE) begin : g_cyc_check
    always_ff @(posedge clk) if (!uncore_rst)
      assert (g_hdma.u_hdma.cycle_q == g_trace.u_trace.cycle_q) else $error("tg_uncore: tg_hdma's cycle count differs from the trace stream's");
  end
`endif

  // ---------------------------------------------------------------------------------------------
  // Boot ROM and the device bus
  // ---------------------------------------------------------------------------------------------
  tg_bootrom u_rom (
    .clk, .rst (uncore_rst),
    .a_i (rom_a), .a_valid_i (rom_av), .a_ready_o (rom_ar), .d_o (rom_d), .d_valid_o (rom_dv), .d_ready_i (rom_dr)
  );

  dev_req_t           dreq;
  logic [DEV_N-1:0]   dreq_v, dwait;
  dev_rsp_t [DEV_N-1:0] drsp;
  logic               vio_wait;
  logic [VIO_SLOTS-1:0] vio_irq;
  always_comb begin
    dwait             = '0;                      // only the virtio window waits
    dwait[DEV_VIRTIO] = vio_wait;
  end
  tg_tl_dev #(.VIRTIO (VIRTIO_WINDOW)) u_dev (
    .clk, .rst (uncore_rst),
    .a_i (dev_a), .a_valid_i (dev_av), .a_ready_o (dev_ar), .d_o (dev_d), .d_valid_o (dev_dv), .d_ready_i (dev_dr),
    .req_o (dreq), .req_valid_o (dreq_v), .rsp_i (drsp), .wait_i (dwait)
  );

  tg_aclint #(.N_HARTS (NH), .CLK_HZ (CLK_HZ)) u_aclint (
    .clk, .rst (uncore_rst), .req_i (dreq), .req_valid_i (dreq_v[DEV_ACLINT]), .rsp_o (drsp[DEV_ACLINT]),
    .irq_msi_o (msi_o), .irq_mti_o (mti_o), .mtime_o
  );

  logic uart_irq, mbox_irq;
  logic [PLIC_NSRC-1:0] plic_src;
  localparam logic [PLIC_NSRC-1:0] EDGE_SRC = PLIC_NSRC'(((1 << NH) - 1) << IRQ_MERR0);
  always_comb begin
    plic_src = '0;
    plic_src[IRQ_UART]    = uart_irq;
    plic_src[IRQ_HOSTCTL] = mbox_irq;
    for (int s = 0; s < VIO_SLOTS; s++) plic_src[IRQ_VIRTIO0 + s] = vio_irq[s];
    for (int h = 0; h < NH; h++) plic_src[IRQ_MERR0 + h] = merr_i[h];
  end
  tg_plic #(.N_SRC (PLIC_NSRC), .N_CTX (2 * NH), .EDGE_SRC (EDGE_SRC)) u_plic (
    .clk, .rst (uncore_rst), .req_i (dreq), .req_valid_i (dreq_v[DEV_PLIC]), .rsp_o (drsp[DEV_PLIC]),
    .src_i (plic_src), .irq_o (plic_irq_o)
  );

  logic        con_tx_v, con_tx_r, con_rx_v, con_rx_r;      // host bridge console streams
  logic [7:0]  con_tx_b, con_rx_b;
  logic        u_tx_v, u_tx_r, u_rx_v, u_rx_r, line_busy;   // the UART's streams
  logic [7:0]  u_tx_b, u_rx_b;
  logic [15:0] uart_div;
  tg_uart #(.CLK_HZ (CLK_HZ)) u_uart (
    .clk, .rst (uncore_rst), .req_i (dreq), .req_valid_i (dreq_v[DEV_UART]), .rsp_o (drsp[DEV_UART]),
    .irq_o (uart_irq),
    .tx_valid_o (u_tx_v), .tx_ready_i (u_tx_r), .tx_byte_o (u_tx_b),
    .rx_valid_i (u_rx_v), .rx_ready_o (u_rx_r), .rx_byte_i (u_rx_b),
    .div_o (uart_div), .line_busy_i (line_busy)
  );
  if (UART_SERIAL) begin : g_serial
    // The line paces TX, and the host gets a copy of each character (dropped while its FIFO is
    // full). RX takes the line's byte first, else the host's, so both consoles work.
    logic       ph_tx_r, ph_rx_v;
    logic [7:0] ph_rx_b;
    tg_uart_phy #(.CLK_HZ (CLK_HZ)) u_phy (
      .clk, .rst (uncore_rst), .div_i (uart_div),
      .tx_valid_i (u_tx_v), .tx_ready_o (ph_tx_r), .tx_byte_i (u_tx_b), .tx_busy_o (line_busy), .txd_o (uart_txd_o),
      .rxd_i (uart_rxd_i), .rx_valid_o (ph_rx_v), .rx_ready_i (u_rx_r), .rx_byte_o (ph_rx_b)
    );
    assign u_tx_r   = ph_tx_r;
    assign con_tx_v = u_tx_v && ph_tx_r;
    assign con_tx_b = u_tx_b;
    assign u_rx_v   = ph_rx_v || con_rx_v;
    assign u_rx_b   = ph_rx_v ? ph_rx_b : con_rx_b;
    assign con_rx_r = u_rx_r && !ph_rx_v;
    wire unused_ser = con_tx_r;                 // the copy never waits
  end else begin : g_virtual
    assign u_tx_r     = con_tx_r;
    assign con_tx_v   = u_tx_v;
    assign con_tx_b   = u_tx_b;
    assign u_rx_v     = con_rx_v;
    assign u_rx_b     = con_rx_b;
    assign con_rx_r   = u_rx_r;
    assign line_busy  = 1'b0;
    assign uart_txd_o = 1'b1;
    wire unused_ser = ^{uart_rxd_i, uart_div};
  end

  // ---------------------------------------------------------------------------------------------
  // Host bridge (host control is the device bus's fourth device, the virtio window its fifth)
  // ---------------------------------------------------------------------------------------------
  // The debug counters' select and value (DEBUG_CNT, below), declared before the bridge connects them:
  // a name used before its declaration becomes an implicit one-bit net in synthesis (Vivado Synth
  // 8-11241), though Verilator finds the later declaration
  logic [5:0]  dbg_sel;
  logic [31:0] dbg_val;

  logic [31:0] tg_ops_all;
  logic [15:0] tg_errs_all;
  logic [27:0] tg_err_line_any;
  always_comb begin
    tg_ops_all      = '0;
    tg_errs_all     = '0;
    tg_err_line_any = '0;
    for (int c = 0; c < N_CORES; c++) begin
      tg_ops_all  = tg_ops_all + tg_ops_i[c];
      tg_errs_all = tg_errs_all + tg_errs_i[c];
      if (tg_errs_i[c] != '0) tg_err_line_any = tg_err_line_i[c];
    end
  end

  // Commit-trace streaming into a DDR ring (docs/spec/uncore-trace.md)
  logic         trs_en, trs_wrap, trs_stop_arm, trs_start_arm;
  logic [63:0]  trs_stop_pc, trs_start_pc, trs_rp, trs_wp;
  logic [15:0]  trs_post, trs_buffered;
  logic [39:0]  trs_base;
  logic [4:0]   trs_size, trs_flags;
  logic [31:0]  trs_stalls;
  if (TRACE) begin : g_trace
    tg_trace_stream #(.N_CORES (N_CORES)) u_trace (
      .clk, .rst (uncore_rst),
      .trace_i, .trace_valid_i, .trace_wb_i, .trace_wb_valid_i, .trace_stall_o,
      .enable_i (trs_en), .wrap_i (trs_wrap), .stop_arm_i (trs_stop_arm), .stop_pc_i (trs_stop_pc),
      .post_i (trs_post), .start_arm_i (trs_start_arm), .start_pc_i (trs_start_pc), .base_i (trs_base),
      .size_log2_i (trs_size), .rp_i (trs_rp),
      .wp_o (trs_wp), .capturing_o (trs_flags[0]), .started_o (trs_flags[1]), .stopped_o (trs_flags[2]),
      .full_o (trs_flags[3]), .axi_err_o (trs_flags[4]), .buffered_o (trs_buffered), .stall_cycles_o (trs_stalls),
      .aw_o (m_axi_trace_aw), .aw_valid_o (m_axi_trace_aw_valid), .aw_ready_i (m_axi_trace_aw_ready),
      .w_o (m_axi_trace_w), .w_valid_o (m_axi_trace_w_valid), .w_ready_i (m_axi_trace_w_ready),
      .b_i (m_axi_trace_b), .b_valid_i (m_axi_trace_b_valid), .b_ready_o (m_axi_trace_b_ready)
    );
  end else begin : g_no_trace
    // no trace stream: the cores' records are dropped (they send none in such a build), and the
    // trace master toward the PS never starts a write
    assign trace_stall_o        = '0;
    assign m_axi_trace_aw       = '0;
    assign m_axi_trace_aw_valid = 1'b0;
    assign m_axi_trace_w        = '0;
    assign m_axi_trace_w_valid  = 1'b0;
    assign m_axi_trace_b_ready  = 1'b1;
    assign trs_wp       = '0;
    assign trs_flags    = '0;
    assign trs_buffered = '0;
    assign trs_stalls   = '0;
    wire unused_trace = ^{trace_i, trace_valid_i, trace_wb_i, trace_wb_valid_i, m_axi_trace_aw_ready,
                          m_axi_trace_w_ready, m_axi_trace_b, m_axi_trace_b_valid, trs_en, trs_wrap,
                          trs_stop_arm, trs_stop_pc, trs_post, trs_start_arm, trs_start_pc, trs_base,
                          trs_size, trs_rp};
  end

  localparam logic [7:0] CFG_CODE = (CFG_NAME == "smt2") ? 8'd1 : (CFG_NAME == "st_w3") ? 8'd2 :
                                    (CFG_NAME == "smt2_w3") ? 8'd3 : 8'd0;
  tg_host_bridge #(
    .CLK_HZ (CLK_HZ), .CFG_CODE (CFG_CODE), .N_CORES_SOC (N_CORES),
    .CORE_RST_INIT (CORE_RST_INIT), .UNCORE_RST_INIT (UNCORE_RST_INIT),
    .DRAM_BASE_INIT (DRAM_BASE_INIT), .DRAM_SIZE_INIT (DRAM_SIZE_INIT), .TRACE (TRACE), .DEBUG (DEBUG_CNT),
    .VIRTIO (VIRTIO_WINDOW), .HDMA (HOST_DMA)
  ) u_host (
    .clk_host, .rst_host,
    .s_awaddr (s_axil_awaddr), .s_awvalid (s_axil_awvalid), .s_awready (s_axil_awready),
    .s_wdata (s_axil_wdata), .s_wstrb (s_axil_wstrb), .s_wvalid (s_axil_wvalid), .s_wready (s_axil_wready),
    .s_bresp (s_axil_bresp), .s_bvalid (s_axil_bvalid), .s_bready (s_axil_bready),
    .s_araddr (s_axil_araddr), .s_arvalid (s_axil_arvalid), .s_arready (s_axil_arready),
    .s_rdata (s_axil_rdata), .s_rresp (s_axil_rresp), .s_rvalid (s_axil_rvalid), .s_rready (s_axil_rready),
    .host_irq_o,
    .clk, .rst, .core_rst_o, .uncore_rst_o (uncore_rst),
    .req_i (dreq), .req_valid_i (dreq_v[DEV_HOSTCTL]), .rsp_o (drsp[DEV_HOSTCTL]),
    .vio_req_valid_i (dreq_v[DEV_VIRTIO]), .vio_rsp_o (drsp[DEV_VIRTIO]), .vio_wait_o (vio_wait),
    .vio_irq_o (vio_irq),
    .mbox_irq_o (mbox_irq),
    .dram_base_o (win_base), .dram_size_o (win_size),
    .inj_rd_delay_o (inj_rd), .inj_wr_delay_o (inj_wr), .inj_mode_o (inj_mode), .inj_bw_o (inj_bw),
    .l2_init_done_i (l2_init_done),
    .inj_rd_count_i (inj_cnt_all), .inj_lat_sum_i (inj_sum_all), .inj_lat_max_i (inj_max_all),
    .tg_en_o, .tg_base_o, .tg_lines_o,
    .tg_ops_i (tg_ops_all), .tg_errs_i (tg_errs_all), .tg_err_line_i (tg_err_line_any), .tg_pass_i (tg_pass_i[0]),
    .trs_enable_o (trs_en), .trs_wrap_o (trs_wrap), .trs_stop_arm_o (trs_stop_arm), .trs_stop_pc_o (trs_stop_pc),
    .trs_post_o (trs_post), .trs_start_arm_o (trs_start_arm), .trs_start_pc_o (trs_start_pc),
    .trs_base_o (trs_base), .trs_size_log2_o (trs_size), .trs_rp_o (trs_rp),
    .trs_wp_i (trs_wp), .trs_flags_i (trs_flags), .trs_buffered_i (trs_buffered), .trs_stalls_i (trs_stalls),
    .dbg_sel_o (dbg_sel), .dbg_val_i (dbg_val),
    .hdma_cpl_en_o (cpl_en), .hdma_cpl_valid_i (cpl_v), .hdma_cpl_i ({cpl_line, cpl_cycle}), .hdma_cpl_ready_o (cpl_r),
    .hdma_rd_lines_i (hdma_rd_lines), .hdma_wr_lines_i (hdma_wr_lines), .hdma_wr_drops_i (hdma_wr_drops),
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
  assign status_o = {2'b00, |tg_errs_all, l2_err_q, con_tx_v, l2_init_done, uncore_rst, core_rst_o};

  // ---------------------------------------------------------------------------------------------
  // Debug counters (DEBUG_CNT): index 8b+k for bank b counts its A, B, C, D, E messages, misses, AXI
  // reads and fills (R last beats); 8*N_BANKS + 5c + k for core c's data cache its A, B, C, D, E;
  // then the L2 error events; the index after holds the channels' valid/ready levels now
  // ---------------------------------------------------------------------------------------------
  if (DEBUG_CNT) begin : g_dbg
    localparam int NCNT = 8 * N_BANKS + 5 * N_CORES + 1;
    logic [31:0]     cnt_q [NCNT];
    logic [NCNT-1:0] inc;
    logic [31:0]     lv;
    always_comb begin
      inc = '0;
      lv  = '0;
      for (int b = 0; b < N_BANKS; b++) begin
        inc[8*b+0] = l2_av[b] && l2_ar[b];
        inc[8*b+1] = l2_bv[b] && l2_br[b];
        inc[8*b+2] = l2_cv[b] && l2_cr[b];
        inc[8*b+3] = l2_dv[b] && l2_dr[b];
        inc[8*b+4] = l2_ev[b] && l2_er[b];
        inc[8*b+5] = ev_miss[b];
        inc[8*b+6] = l2_arv[b] && l2_arr[b];
        inc[8*b+7] = m_axi_r_valid[b] && m_axi_r_ready[b] && m_axi_r[b].last;
        lv[10*b +: 10] = {l2_av[b], l2_ar[b], l2_bv[b], l2_br[b], l2_cv[b], l2_cr[b], l2_dv[b], l2_dr[b],
                          l2_ev[b], l2_er[b]};
      end
      for (int c = 0; c < N_CORES; c++) begin
        inc[8*N_BANKS+5*c+0] = l1d_a_valid_i[c] && l1d_a_ready_o[c];
        inc[8*N_BANKS+5*c+1] = l1d_b_valid_o[c] && l1d_b_ready_i[c];
        inc[8*N_BANKS+5*c+2] = l1d_c_valid_i[c] && l1d_c_ready_o[c];
        inc[8*N_BANKS+5*c+3] = l1d_d_valid_o[c] && l1d_d_ready_i[c];
        inc[8*N_BANKS+5*c+4] = l1d_e_valid_i[c] && l1d_e_ready_o[c];
        if (c < 2) lv[20+5*c +: 5] = {l1d_a_valid_i[c] && !l1d_a_ready_o[c], l1d_b_valid_o[c] && !l1d_b_ready_i[c],
                                       l1d_c_valid_i[c] && !l1d_c_ready_o[c], l1d_d_valid_o[c] && !l1d_d_ready_i[c],
                                       l1d_e_valid_i[c] && !l1d_e_ready_o[c]};
      end
      inc[NCNT-1] = |ev_err;
      lv[30] = l2_err_q;
    end
    always_ff @(posedge clk)
      for (int i = 0; i < NCNT; i++)
        if (uncore_rst) cnt_q[i] <= '0;
        else if (inc[i]) cnt_q[i] <= cnt_q[i] + 32'd1;
    localparam int IW = $clog2(NCNT);
    assign dbg_val = (int'(dbg_sel) < NCNT) ? cnt_q[IW'(dbg_sel)] : (int'(dbg_sel) == NCNT) ? lv : 32'hDEB0_0000;
  end else begin : g_no_dbg
    assign dbg_val = '0;
    wire unused_dbg = ^dbg_sel;
  end

  wire unused = ^{ev_hit, ev_miss, ev_wb, ev_probe, tg_pass_i};
endmodule
