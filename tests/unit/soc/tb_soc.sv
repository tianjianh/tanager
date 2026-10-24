// SoC simulation test (docs/spec/soc.md §Verification): tanager_soc with AXI memory models and a
// host on an unrelated clock that drives the AXI4-Lite window the way tanager-host does.
//   KIND = "core":    stub cores. Host register map, reset sequencing, L2 initialisation, DRAM
//                     window registers, mailbox to the RISC-V side, console input path.
//   KIND = "trafgen": traffic generators in the cores' place. Memory passes through the L2, the
//                     latency injector and the window (L2 shrunk so the region spills to memory),
//                     at injected latencies 0 and 250; console output ('.' per pass) read back by
//                     the host; every memory access must land inside the carve-out.
//   VIRTIO = 1 (make ... VIRTIO=1, KIND = "tcore"): the forwarded virtio window (soc.md §8.1); the host
//                     serves its queue and the program checks reads, a QueueNotify and the interrupt.
//   HOST_DMA = 1 (make ... HOST_DMA=1, KIND = "tcore"): the coherent host DMA port (soc.md §8.1); the
//                     host reads a buffer the program left dirty in its cache and writes one the
//                     program holds copies of, records the writes' completions, and both sides check.
//   PS window (make ... PS_WINDOW=1, +define+TG_PS_WINDOW=1, KIND = "tcore"): stage D's D1 (soc.md §8.2);
//                     a model of the PS behind S_AXI_LPD answers the window with random delays, an error
//                     and a response later than the window's timeout, and drives PLIC source 24; the
//                     program checks every access size and the faults, and this side counts the
//                     transactions and that no denied address ever reached the PS. The board's reset (D4's
//                     modes, docs/spec/soc-d4-modes.md): the program finds CRL_APB RESET_CTRL denied, asks
//                     the host for BOARD_CTRL[1], then finds that word alone passing; then, while it keeps
//                     accessing the window, the PMOD reset hook (BREAK_LOG2 = 6: breaks of 64 to 255
//                     cycles on uart_rxd_i) writes RESET_CTRL once per arming, after a break of the right
//                     length only, and BOARD_CTRL reads back how the write went (answered, an error, none).
//   SDIRQ = 1 (make ... SDIRQ=1: KIND = "tcore", the PS window, sw/sd_irq.c): SD1's lost interrupt (the board's
//                     s19b boot 1, 10-20). The PS model gets an SD-like device at SD1 (status, write 1 to clear;
//                     signal enable; a command that sets command complete and then transfer complete after random
//                     delays), its line on ps_irq[PS_IRQ_SD1]; hart 0 handles it as Linux's sdhci and PLIC drivers
//                     do while hart 1 contends on the device bus. Every request must complete; on a failure this
//                     side prints the PLIC's own state for source 21. The PS window's own checks don't run.
//   RELEASE = 1 (make ... RELEASE=1: also LAT_INJ = 0 and no trace; DR-180): a release build. The console comes from
//                     the UART's own output (no host console: its input path must not reach the UART); the
//                     program (FROMHOST bit 3) finds the PLIC's M contexts empty and 1-bit priorities, claims the
//                     UART's interrupt on hart 0's S context, and with the PS window finds TTC1's line no source
//                     and UART1's claimed there instead; the DMA port's completions and line counters read 0.
//   Every KIND: BOARD_CTRL[0] reaches board_ctrl_o (the KV260's fan regulator); CAPS's DR-177 and DR-180 bits.
module tb_soc;
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;

  parameter string KIND = "core";       // "core" (stub cores), "trafgen", or "tcore" (tg_core is the
                                        // test core: tests/unit/soc/tcore_as_core.sv)
  parameter bit    VIRTIO = 1'b0;       // the forwarded virtio window (tg_uncore VIRTIO_WINDOW)
  parameter bit    HOST_DMA = 1'b0;     // the coherent host DMA port (tg_uncore HOST_DMA)
  parameter bit    SDIRQ = 1'b0;        // the SD-like interrupt stress (with the PS window; sw/sd_irq.c)
  parameter bit    LAT_INJ = 1'b1;      // the two latency injectors (tg_uncore LAT_INJ); 0: a release build (DR-177)
  // A release build (tg_uncore RELEASE, DR-180; the Makefile's RELEASE=1 also sets LAT_INJ = 0 and builds without the
  // trace): no host console, so the console is read where the UART's characters leave it; the PLIC's M contexts
  // hold nothing (the program claims on hart 0's S context) and TTC1 is no source; the DMA port has no line
  // counters or completions; CAPS[9], [10] and [11] read 0
  parameter bit    RELEASE = 1'b0;
  // The uncore's register slices (tanager_soc XBAR_SLICE and MEM_SLICE, off by default since DR-186): a bigger chip may
  // want them back for timing (docs/spec/area_switches.md)
  parameter bit    XBAR_SLICE = XBAR_SLICE_DEF;
  parameter bit    MEM_SLICE  = MEM_SLICE_DEF;
  // The L2's write-back batching (tanager_soc L2_WB_PACE, docs/spec/l2.md): with it, batches of 4 write-backs, or
  // 256 cycles, from reset (L2_PACE_INIT), so the memory tests' evictions go out in runs
  parameter bit          L2_WB_PACE   = L2_WB_PACE_DEF;
  parameter logic [15:0] L2_PACE_INIT = 16'h1004;
  // A program runs on the test cores, or with SDIRQ on the real ones too (KIND = "core")
  localparam bit   PROG = KIND == "tcore" || SDIRQ;

  localparam logic [39:0] CO_BASE = 40'h8_4000_0000;    // carve-out in "PS" address space
  localparam logic [39:0] CO_SIZE = 40'h0400_0000;      // 64 MiB
  localparam logic [39:0] TR_BASE = 40'h8_4800_0000;    // the trace stream's ring
  // Built without the trace (make ... COMMIT_TRACE=0, +define+TG_COMMIT_TRACE=0; DR-146): the program still runs,
  // the capability bit reads 0 and the trace master never starts a write.
  localparam bit TRACE = tg_trace_pkg::COMMIT_TRACE;

  logic clk = 1'b0, clk_host = 1'b0, rst = 1'b1, rst_host = 1'b1;
  always #5    clk      = ~clk;        // 100 MHz
  always #6.85 clk_host = ~clk_host;   // ~73 MHz, unrelated
  // clk2x at 200 MHz, rising with clk (from 1, so both rise at 5, 15 ...), for the cores' URF (DR-174); unused
  // by a core built without it, by tg_trafgen and by tcore_as_core
  logic clk2x = 1'b1;
  always #2.5  clk2x    = ~clk2x;

  logic [15:0] awaddr, araddr;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  logic        host_irq;
  logic [7:0]  status;

  axi_ax_t [N_BANKS-1:0] ar, aw;
  axi_r_t  [N_BANKS-1:0] r;
  axi_w_t  [N_BANKS-1:0] w;
  axi_b_t  [N_BANKS-1:0] b;
  logic [N_BANKS-1:0] arv, arr, rv, rr, awv, awr, wv, wr, bv, br;
  axi_ax_t taw;                       // commit-trace stream (writes only)
  axi_w_t  tw;
  axi_b_t  tb;
  logic    tawv, tawr, twv, twr, tbv, tbr;
  bit      taw_seen = 1'b0;                 // the trace master started a write
  always @(posedge clk) if (tawv || twv) taw_seen <= 1'b1;

  // the host DMA port (HOST_DMA): the host's AXI4 master
  hdma_ax_t dma_aw = '0, dma_ar = '0;
  axi_w_t   dma_w = '0;
  hdma_b_t  dma_b;
  hdma_r_t  dma_r;
  logic     dma_awv = 1'b0, dma_awr, dma_wv = 1'b0, dma_wr, dma_bv, dma_br = 1'b0, dma_arv = 1'b0, dma_arr, dma_rv, dma_rr = 1'b0;

  // the PS window (tg_map_pkg PS_WINDOW): its AXI4 master into the PS model below, and the PS's interrupts
  axi_ax_t ps_aw, ps_ar;
  axi_w_t  ps_w;
  axi_b_t  ps_b = '0;
  axi_r_t  ps_r = '0;
  logic    ps_awv, ps_awr = 1'b0, ps_wv, ps_wr = 1'b0, ps_bv = 1'b0, ps_br, ps_arv, ps_arr = 1'b0, ps_rv = 1'b0, ps_rr;
  logic [PS_IRQS-1:0] ps_irq = '0;
  logic    sd_irq = 1'b0;             // SDIRQ: the SD-like device's line (PS_IRQ_SD1)
  logic    ps_rxd = 1'b1;             // the serial line's RX, idle high: the PMOD reset hook's breaks
  logic [1:0] board_ctrl;             // BOARD_CTRL, core side

  tg_trace_pkg::tr_rec_t [NUM_CORES-1:0][COMMIT_WIDTH-1:0]   trace;
  logic [NUM_CORES-1:0][COMMIT_WIDTH-1:0]   trace_v;
  tg_trace_pkg::tr_wb_t  [NUM_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb;
  logic [NUM_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_v;

  tanager_soc #(
    .N_CORES (NUM_CORES), .CLK_HZ (100_000_000), .L2_SETS (16), .L2_MSHR (24),
    .CORE_RST_INIT (1'b1), .UNCORE_RST_INIT (1'b1), .CORE_KIND ((KIND == "trafgen") ? "trafgen" : "core"),
    .VIRTIO_WINDOW (VIRTIO), .HOST_DMA (HOST_DMA), .LAT_INJ (LAT_INJ), .RELEASE (RELEASE), .BREAK_LOG2 (6),
    .XBAR_SLICE (XBAR_SLICE), .MEM_SLICE (MEM_SLICE), .L2_WB_PACE (L2_WB_PACE), .L2_PACE_INIT (L2_PACE_INIT)
  ) dut (
    .uart_txd_o (), .uart_rxd_i (ps_rxd),
    .clk, .clk2x, .rst, .clk_host, .rst_host,
    .s_axil_awaddr (awaddr), .s_axil_awvalid (awvalid), .s_axil_awready (awready),
    .s_axil_wdata (wdata), .s_axil_wstrb (wstrb), .s_axil_wvalid (wvalid), .s_axil_wready (wready),
    .s_axil_bresp (bresp), .s_axil_bvalid (bvalid), .s_axil_bready (bready),
    .s_axil_araddr (araddr), .s_axil_arvalid (arvalid), .s_axil_arready (arready),
    .s_axil_rdata (rdata), .s_axil_rresp (rresp), .s_axil_rvalid (rvalid), .s_axil_rready (rready),
    .host_irq_o (host_irq),
    .m_axi_ar (ar), .m_axi_ar_valid (arv), .m_axi_ar_ready (arr),
    .m_axi_r (r), .m_axi_r_valid (rv), .m_axi_r_ready (rr),
    .m_axi_aw (aw), .m_axi_aw_valid (awv), .m_axi_aw_ready (awr),
    .m_axi_w (w), .m_axi_w_valid (wv), .m_axi_w_ready (wr),
    .m_axi_b (b), .m_axi_b_valid (bv), .m_axi_b_ready (br),
    .m_axi_trace_aw (taw), .m_axi_trace_aw_valid (tawv), .m_axi_trace_aw_ready (tawr),
    .m_axi_trace_w (tw), .m_axi_trace_w_valid (twv), .m_axi_trace_w_ready (twr),
    .m_axi_trace_b (tb), .m_axi_trace_b_valid (tbv), .m_axi_trace_b_ready (tbr),
    .s_axi_dma_aw (dma_aw), .s_axi_dma_aw_valid (dma_awv), .s_axi_dma_aw_ready (dma_awr),
    .s_axi_dma_w (dma_w), .s_axi_dma_w_valid (dma_wv), .s_axi_dma_w_ready (dma_wr),
    .s_axi_dma_b (dma_b), .s_axi_dma_b_valid (dma_bv), .s_axi_dma_b_ready (dma_br),
    .s_axi_dma_ar (dma_ar), .s_axi_dma_ar_valid (dma_arv), .s_axi_dma_ar_ready (dma_arr),
    .s_axi_dma_r (dma_r), .s_axi_dma_r_valid (dma_rv), .s_axi_dma_r_ready (dma_rr),
    .m_axi_ps_aw (ps_aw), .m_axi_ps_aw_valid (ps_awv), .m_axi_ps_aw_ready (ps_awr),
    .m_axi_ps_w (ps_w), .m_axi_ps_w_valid (ps_wv), .m_axi_ps_w_ready (ps_wr),
    .m_axi_ps_b (ps_b), .m_axi_ps_b_valid (ps_bv), .m_axi_ps_b_ready (ps_br),
    .m_axi_ps_ar (ps_ar), .m_axi_ps_ar_valid (ps_arv), .m_axi_ps_ar_ready (ps_arr),
    .m_axi_ps_r (ps_r), .m_axi_ps_r_valid (ps_rv), .m_axi_ps_r_ready (ps_rr), .ps_irq_i (ps_irq | (PS_IRQS'(sd_irq) << PS_IRQ_SD1)),
    .board_status_i (32'h0F0A_1234), .board_ctrl_o (board_ctrl),
    .trace_o (trace), .trace_valid_o (trace_v), .trace_wb_o (trace_wb), .trace_wb_valid_o (trace_wb_v),
    .status_o (status)
  );

  for (genvar k = 0; k < N_BANKS; k++) begin : g_mem
    tb_axi_mem #(.LAT_MIN(8), .LAT_MAX(40), .READY_PCT(85), .OOO(1'b1), .NAME($sformatf("ddr%0d", k))) u_mem (
      .clk, .rst,
      .ar_i (ar[k]), .ar_valid_i (arv[k]), .ar_ready_o (arr[k]),
      .r_o (r[k]), .r_valid_o (rv[k]), .r_ready_i (rr[k]),
      .aw_i (aw[k]), .aw_valid_i (awv[k]), .aw_ready_o (awr[k]),
      .w_i (w[k]), .w_valid_i (wv[k]), .w_ready_o (wr[k]),
      .b_o (b[k]), .b_valid_o (bv[k]), .b_ready_i (br[k])
    );
    // the carve-out is the only memory the SoC may touch
    always @(posedge clk) if (!rst) begin
      if (arv[k] && arr[k]) assert (ar[k].addr >= CO_BASE && ar[k].addr < CO_BASE + CO_SIZE) else $error("AR outside the carve-out: %h", ar[k].addr);
      if (awv[k] && awr[k]) assert (aw[k].addr >= CO_BASE && aw[k].addr < CO_BASE + CO_SIZE) else $error("AW outside the carve-out: %h", aw[k].addr);
    end
  end

  // the commit-trace stream's memory (records land here when the host enables streaming)
  axi_r_t trace_r_unused;
  tb_axi_mem #(.LAT_MIN(4), .LAT_MAX(20), .READY_PCT(90), .OOO(1'b0), .STRICT_ID(1'b0), .NAME("trace")) u_tmem (
    .clk, .rst,
    .ar_i ('0), .ar_valid_i (1'b0), .ar_ready_o (), .r_o (trace_r_unused), .r_valid_o (), .r_ready_i (1'b1),
    .aw_i (taw), .aw_valid_i (tawv), .aw_ready_o (tawr),
    .w_i (tw), .w_valid_i (twv), .w_ready_o (twr),
    .b_o (tb), .b_valid_o (tbv), .b_ready_i (tbr)
  );

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("[%0t] ERROR: %s", $time, m);
  endtask

  // ---- the PS behind the PS window (PS_WINDOW): one transaction at a time, as the window issues them ----
  // Byte registers, 0 until written; IOU_SLCR reads byte a as a ^ 0x5A; TTC1's first register drives
  // ps_irq[PS_IRQ_TTC1], UART1's at 0x40 ps_irq[PS_IRQ_UART1]; SD1 + 0x100 answers SLVERR; GEM3 + 0x200 answers
  // 70,000 cycles late, past the window's timeout. CRL_APB RESET_CTRL (the board's reset) records its writes and answers as ps_rst_mode
  // says. An address the window should have denied is an error here.
  localparam logic [31:0] PS_TTC1 = 32'hFF12_0000, PS_ERR = 32'hFF17_0100, PS_LATE = 32'hFF0E_0200;
  localparam logic [31:0] PS_RST = 32'hFF5E_0218, PS_U1IRQ = 32'hFF01_0040;
  byte unsigned ps_mem [logic [31:0]];
  int ps_txn = 0, ps_late = 0, ps_done = 0;   // transactions accepted, GEM3's late ones, answered
  int ps_rst = 0;                             // writes to RESET_CTRL, the last one's beat below
  int ps_rst_mode = 0;                        // their answer: 0 OKAY, 1 SLVERR, 2 70,000 cycles late
  axi_ax_t ps_rst_aw;
  axi_w_t  ps_rst_w;
  function automatic bit ps_allowed(input logic [31:0] a, input bit we, input logic [2:0] size);
    if (a[31:2] == PS_RST[31:2]) return size <= 3'd2;             // that word alone, while BOARD_CTRL[1]
    if (a[31:16] == 16'hFF01 || a[31:16] == 16'hFF0E || a[31:16] == 16'hFF12 || a[31:16] == 16'hFF17 ||
        a[31:16] == 16'hFF9D || a[31:20] == 12'hFE2) return 1'b1;
    return !we && a[31:19] == 13'h1FE3;
  endfunction
  // SDIRQ's SD-like device at SD1: status at 0x30 (write 1 to clear), signal enable at 0x38, the command at 0x40
  // (the model's own: a write starts a request); the line is status & signal enable, from a register. A request
  // sets bit 0 after a random delay and bit 1 after another: under 40 cycles four times in ten (inside the
  // handler's reads and writes), else up to 400 or 4,000.
  localparam logic [31:0] PS_SD_ST = 32'hFF17_0030, PS_SD_SIG = 32'hFF17_0038, PS_SD_CMD = 32'hFF17_0040;
  logic [31:0] sd_st = '0, sd_sig = '0;
  int sd_go = 0, sd_started = 0, sd_cmds = 0, sd_xfers = 0;
  int sd_claimed = 0, sd_both = 0;          // transfer completes raised while source 21 was claimed; with bit 0 set
  // With HOST_DMA, each request's data before its transfer complete: one to four 128-byte bursts through the host
  // DMA port into buffer (request % 8) at RISC-V 0x8020_0000 + 4 KiB * (request % 8); the program checks the first
  // A command with bit 31 set is a write: the model reads the buffer instead (the program filled it, dirty in its
  // cache), as SD1's ADMA reads a write's data, and checks it
  int sd_bursts = 0, sd_wbursts = 0;
  bit sd_wrq [$];
  localparam logic [31:0] SD_BUF = 32'h0020_0000;
  function automatic logic [63:0] sd_word(input int req, input int k);
    return (64'(req) * 64'h9E37_79B9_7F4A_7C15) ^ 64'(k);
  endfunction
  function automatic logic [63:0] sd_wword(input int req, input int k);
    return (64'(req) * 64'hC2B2_AE3D_27D4_EB4F) ^ 64'(k) ^ 64'h5A5A_5A5A_5A5A_5A5A;
  endfunction
  function automatic int sd_delay();
    int r;
    r = $urandom_range(0, 9);
    return (r < 4) ? $urandom_range(0, 40) : (r < 7) ? $urandom_range(40, 400) : $urandom_range(400, 4000);
  endfunction
  function automatic byte unsigned ps_byte(input logic [31:0] a);
    if (SDIRQ && a[31:2] == PS_SD_ST[31:2]) return sd_st[8 * a[1:0] +: 8];
    if (ps_mem.exists(a)) return ps_mem[a];
    return (a[31:19] == 13'h1FE3) ? 8'(a[7:0] ^ 8'h5A) : 8'h00;
  endfunction
  initial if (SDIRQ) forever begin
    @(posedge clk);
    if (sd_go != sd_started) begin
      bit wr;
      wr = sd_wrq.pop_front();
      sd_started++;
      repeat (sd_delay()) @(posedge clk);
      sd_st |= 32'h1; sd_cmds++;
      repeat (sd_delay()) @(posedge clk);
      if (HOST_DMA) begin                        // the data first, as SD1's ADMA writes it before transfer complete
        logic [127:0] beats [8];
        logic [1:0]   r;
        int           nb;
        nb = $urandom_range(1, 4);
        for (int b = 0; b < nb; b++) begin
          if (wr) begin
            dma_read(SD_BUF + 32'(4096 * ((sd_started - 1) % 8)) + 32'(128 * b), beats, r);
            if (r != 2'b00) fail($sformatf("SD device: DMA read response %0d", r));
            for (int k = 0; k < 8; k++)
              for (int h = 0; h < 2; h++)
                if (beats[k][64*h +: 64] != sd_wword(sd_started - 1, 16 * b + 2 * k + h))
                  fail($sformatf("SD device: request %0d's write data, word %0d: %h", sd_started - 1,
                                 16 * b + 2 * k + h, beats[k][64*h +: 64]));
            sd_wbursts++;
          end else begin
            for (int k = 0; k < 8; k++)
              beats[k] = {sd_word(sd_started - 1, 16 * b + 2 * k + 1), sd_word(sd_started - 1, 16 * b + 2 * k)};
            dma_write(SD_BUF + 32'(4096 * ((sd_started - 1) % 8)) + 32'(128 * b), beats, r);
            if (r != 2'b00) fail($sformatf("SD device: DMA write response %0d", r));
            sd_bursts++;
          end
        end
      end
      if (dut.u_uncore.u_plic.busy_q[IRQ_PS0 + PS_IRQ_SD1]) sd_claimed++;
      if (sd_st[0]) sd_both++;
      sd_st |= 32'h2; sd_xfers++;
    end
  end
  always @(posedge clk) sd_irq <= SDIRQ && |(sd_st & sd_sig);
  // SDIRQ on the real cores with +ipi_race=N: an IPI to hart 0 (its MSIP in the ACLINT, OpenSBI's IPI) made
  // pending in the very cycle hart 0's LSU issues its Nth PLIC claim of context 1 (S-mode, sd_irq_smt2s/v), as
  // an IPI can land while Linux's plic_handle_irq claims. The ACLINT's output register (msi_q) to the hart's
  // interrupt selection is combinational, so set mid-cycle with msip_q behind it, it is taken that cycle;
  // hart 0's M-mode handler clears it.
  // Under TB_SOC_CORE only (the Makefile's, with KIND=core): Verilator resolves these names even in a generate
  // branch that is off, and the test cores and the traffic generators have no LSU
  int ipi_race_at = 0, claims_seen = 0, ipi_injected = 0;
`ifdef TB_SOC_CORE
  if (KIND == "core" && SDIRQ) begin : g_ipi_race
    initial if ($value$plusargs("ipi_race=%d", ipi_race_at)) forever begin
      @(negedge clk);
      if (dut.g_core[0].g_tgc.u_core.u_lsu.mm_go &&
          dut.g_core[0].g_tgc.u_core.u_lsu.lqa_rd[1].pa == PA_W'(PLIC_BASE + 64'h20_1004)) begin
        claims_seen++;
        if (claims_seen == ipi_race_at) begin
          dut.u_uncore.u_aclint.msip_q[0] = 1'b1;
          dut.u_uncore.u_aclint.msi_q[0]  = 1'b1;
          ipi_injected++;
          $display("[%0t] ipi_race: an IPI to hart 0 in the cycle its claim number %0d issues", $time, claims_seen);
        end
      end
    end
    // What follows the injection, from the hardware's side: the PLIC's claims of context 1 (the ID each
    // returns), hart 0's MMIO responses dropped as killed, and its traps, for 3,000 cycles
    initial if ($value$plusargs("ipi_race=%d", ipi_race_at)) begin
      wait (ipi_injected != 0);
      repeat (3000) begin
        @(posedge clk);
        if (dut.u_uncore.u_plic.claim && dut.u_uncore.u_plic.cx == 14'd1)
          $display("[%0t] ipi_race: PLIC claim on context 1 returns %0d", $time, dut.u_uncore.u_plic.claim_id);
        if (dut.g_core[0].g_tgc.u_core.u_lsu.xs_q == 2'd2 && dut.g_core[0].g_tgc.u_core.u_lsu.mmio_d_valid_i &&
            !dut.g_core[0].g_tgc.u_core.u_lsu.x_st_q && dut.g_core[0].g_tgc.u_core.u_lsu.x_kill_q)
          $display("[%0t] ipi_race: hart 0 drops the response of a killed MMIO load (pa %h)", $time,
                   dut.g_core[0].g_tgc.u_core.u_lsu.x_pa_q);
        if (dut.g_core[0].g_tgc.u_core.u_rob.do_irq)
          $display("[%0t] ipi_race: hart 0 takes an interrupt (head pc %h)", $time, dut.g_core[0].g_tgc.u_core.u_rob.hp[0].pc);
      end
    end
  end
`endif
  initial if (PS_WINDOW) forever begin
    @(posedge clk);
    if (ps_awv && ps_wv) begin
      axi_ax_t a;
      axi_w_t  d;
      int      lat;
      bit      rst_w;
      a = ps_aw;
      d = ps_w;
      rst_w = a.addr[31:2] == PS_RST[31:2];
      if (!ps_allowed(a.addr[31:0], 1'b1, a.size)) fail($sformatf("PS window: a write to %h reached the PS", a.addr));
      if (a.len != 0 || a.burst != AXI_INCR) fail($sformatf("PS window: write burst len %0d burst %0d", a.len, a.burst));
      repeat ($urandom_range(0, 6)) @(posedge clk);
      ps_awr <= 1'b1; ps_wr <= 1'b1;
      @(posedge clk);
      ps_awr <= 1'b0; ps_wr <= 1'b0;
      if (SDIRQ && a.addr[31:0] == PS_SD_ST) sd_st &= ~d.data[8 * a.addr[3:0] +: 32];   // write 1 to clear
      else for (int k = 0; k < 16; k++) if (d.strb[k]) ps_mem[{a.addr[31:4], 4'(k)}] = d.data[8*k +: 8];
      if (SDIRQ && a.addr[31:0] == PS_SD_SIG) sd_sig = d.data[8 * a.addr[3:0] +: 32];
      if (SDIRQ && a.addr[31:0] == PS_SD_CMD) begin sd_wrq.push_back(d.data[8 * a.addr[3:0] + 31]); sd_go++; end
      if (a.addr[31:0] == PS_TTC1) ps_irq[PS_IRQ_TTC1] <= d.data[0];
      if (a.addr[31:0] == PS_U1IRQ) ps_irq[PS_IRQ_UART1] <= d.data[8 * PS_U1IRQ[3:0]];
      if (rst_w) begin ps_rst++; ps_rst_aw = a; ps_rst_w = d; end
      ps_txn++;
      lat = (a.addr[31:0] == PS_LATE || (rst_w && ps_rst_mode == 2)) ? 70000 : $urandom_range(1, 20);
      repeat (lat) @(posedge clk);
      ps_b <= '{id: a.id, resp: (a.addr[31:0] == PS_ERR || (rst_w && ps_rst_mode == 1)) ? AXI_SLVERR : AXI_OKAY};
      ps_bv <= 1'b1;
      do @(posedge clk); while (!ps_br);
      ps_bv <= 1'b0;
      ps_done++;
    end else if (ps_arv) begin
      axi_ax_t a;
      logic [127:0] beat;
      int      lat;
      a = ps_ar;
      if (!ps_allowed(a.addr[31:0], 1'b0, a.size)) fail($sformatf("PS window: a read of %h reached the PS", a.addr));
      if (a.len != 0 || a.burst != AXI_INCR) fail($sformatf("PS window: read burst len %0d burst %0d", a.len, a.burst));
      repeat ($urandom_range(0, 6)) @(posedge clk);
      ps_arr <= 1'b1;
      @(posedge clk);
      ps_arr <= 1'b0;
      for (int k = 0; k < 16; k++) beat[8*k +: 8] = ps_byte({a.addr[31:4], 4'(k)});
      ps_txn++;
      lat = (a.addr[31:0] == PS_LATE) ? 70000 : $urandom_range(1, 20);
      if (a.addr[31:0] == PS_LATE) ps_late++;
      repeat (lat) @(posedge clk);
      ps_r <= '{id: a.id, data: beat, resp: (a.addr[31:0] == PS_ERR) ? AXI_SLVERR : AXI_OKAY, last: 1'b1};
      ps_rv <= 1'b1;
      do @(posedge clk); while (!ps_rr);
      ps_rv <= 1'b0;
      ps_done++;
    end
  end

  // ---- AXI4-Lite host master (clk_host) ----
  task automatic hw(input logic [15:0] a, input logic [31:0] d);
    @(negedge clk_host);
    awaddr = a; awvalid = 1; wdata = d; wstrb = 4'hF; wvalid = 1;
    do @(posedge clk_host); while (!(awready && wready));
    @(negedge clk_host);
    awvalid = 0; wvalid = 0; bready = 1;
    do @(posedge clk_host); while (!bvalid);
    @(negedge clk_host) bready = 0;
  endtask
  task automatic hr(input logic [15:0] a, output logic [31:0] d);
    @(negedge clk_host);
    araddr = a; arvalid = 1;
    do @(posedge clk_host); while (!arready);
    @(negedge clk_host);
    arvalid = 0; rready = 1;
    do @(posedge clk_host); while (!rvalid);
    d = rdata;
    @(negedge clk_host) rready = 0;
  endtask
  task automatic hw64(input logic [15:0] a, input logic [63:0] d);
    hw(a, d[31:0]);
    hw(a + 16'h4, d[63:32]);
  endtask
  task automatic expect_reg(input logic [15:0] a, input logic [31:0] want, input string what);
    logic [31:0] v;
    hr(a, v);
    if (v != want) fail($sformatf("%s: %h, want %h", what, v, want));
  endtask
  task automatic wait_status(input int bit_i, input logic val, input int max_us);
    logic [31:0] v;
    int t;
    t = 0;
    do begin hr(16'h014, v); t++; end while (v[bit_i] != val && t < max_us * 10);
    if (v[bit_i] != val) fail($sformatf("STATUS[%0d] never became %0d", bit_i, val));
  endtask

  // BOARD_CTRL's core side (board_ctrl_o), once the configuration crossing has carried the host's value
  task automatic wait_board(input logic [1:0] want, input string what);
    int t;
    t = 0;
    while (board_ctrl !== want && t < 400) begin @(posedge clk); t++; end
    if (board_ctrl !== want) fail($sformatf("%s: BOARD_CTRL's core side %b, want %b", what, board_ctrl, want));
  endtask
  // BOARD_CTRL as the host reads it, once the PS window's status has crossed back
  task automatic expect_board(input logic [31:0] want, input string what);
    logic [31:0] v;
    int t;
    t = 0;
    do begin hr(16'h1404, v); t++; end while (v != want && t < 100);
    if (v != want) fail($sformatf("%s: BOARD_CTRL %h, want %h", what, v, want));
  endtask

  // Drain the console: everything the RISC-V side has written so far. A release build has no console through
  // the host: there the UART's characters are taken where they leave it (its serial side)
  string console, uconsole = "";
  always @(posedge clk) if (dut.u_uncore.u_tx_v && dut.u_uncore.u_tx_r) uconsole = {uconsole, $sformatf("%c", dut.u_uncore.u_tx_b)};
  task automatic drain_console();
    logic [31:0] v;
    if (RELEASE) begin
      console = uconsole;
      return;
    end
    do begin
      hr(16'h100, v);
      if (v[8]) console = {console, $sformatf("%c", v[7:0])};
    end while (v[8]);
  endtask

  // Serve the virtio window's queue the way tanager-host's back-ends will: a read gets "virt" at
  // offset 0, else (slot << 16) | offset; a QueueNotify of slot 3 sets its used-buffer bit
  int vio_reads = 0, vio_notify = 0;
  task automatic serve_virtio();
    logic [31:0] h, d, val;
    forever begin
      hr(16'h1108, h);                          // VQ_REQ0
      if (!h[31]) break;
      hr(16'h110C, d);                          // VQ_REQ1 pops
      if (h[18]) begin
        if (h[13:12] == 2'd3 && h[11:0] == 12'h050) begin
          vio_notify++;
          hw(16'h1114, 32'h40);                 // VQ_IRQ: set slot 3's bit 0
        end
      end else begin
        val = (h[11:0] == 12'h000) ? 32'h7472_6976 : {14'd0, h[13:12], 4'd0, h[11:0]};
        val &= (h[17:16] == 2'd2) ? 32'hFFFF_FFFF : (h[17:16] == 2'd1) ? 32'h0000_FFFF : 32'h0000_00FF;
        hw(16'h1110, val);                      // VQ_RSP
        vio_reads++;
      end
    end
  endtask

  // The host DMA port: the host's AXI4 master (clk), 8-beat bursts at window offsets
  function automatic logic [63:0] mix(input logic [63:0] x);
    x ^= x >> 33;
    x *= 64'hff51afd7ed558ccd;
    x ^= x >> 29;
    return x;
  endfunction
  localparam logic [31:0] DMA_A = 32'h0010_0000, DMA_B = 32'h0010_1000;   // RISC-V 0x8010_0000, 0x8010_1000
  task automatic dma_read(input logic [31:0] off, output logic [127:0] beats [8], output logic [1:0] worst);
    @(negedge clk);
    dma_ar = '{id: 16'h0A1, addr: 40'h5_0000_0000 | 40'(off), len: 8'd7, size: 3'd4, burst: AXI_INCR};
    dma_arv = 1;
    do @(posedge clk); while (!dma_arr);
    @(negedge clk) dma_arv = 0;
    worst = 2'b00;
    for (int k = 0; k < 8; k++) begin
      dma_rr = 1;
      do @(posedge clk); while (!dma_rv);
      beats[k] = dma_r.data;
      if (dma_r.resp != 2'b00) worst = dma_r.resp;
      if (dma_r.last != (k == 7) || dma_r.id != 16'h0A1) fail("DMA read: RLAST or RID");
      @(negedge clk) dma_rr = 0;
    end
  endtask
  task automatic dma_write(input logic [31:0] off, input logic [127:0] beats [8], output logic [1:0] resp);
    @(negedge clk);
    dma_aw = '{id: 16'h0B2, addr: 40'h5_0000_0000 | 40'(off), len: 8'd7, size: 3'd4, burst: AXI_INCR};
    dma_awv = 1;
    do @(posedge clk); while (!dma_awr);
    @(negedge clk) dma_awv = 0;
    for (int k = 0; k < 8; k++) begin
      dma_w = '{data: beats[k], strb: '1, last: (k == 7)};
      dma_wv = 1;
      do @(posedge clk); while (!dma_wr);
      @(negedge clk) dma_wv = 0;
    end
    dma_br = 1;
    do @(posedge clk); while (!dma_bv);
    resp = dma_b.resp;
    if (dma_b.id != 16'h0B2) fail("DMA write: BID");
    @(negedge clk) dma_br = 0;
  endtask

  // When the program rings the doorbell: read DMA_A (dirty in its cache), write DMA_B (cached there),
  // check the completions, then answer through MBOX_OUT
  bit dma_done = 0;
  task automatic serve_dma();
    logic [31:0] v, v1;
    logic [127:0] beats [8];
    logic [1:0] r;
    hr(16'h070, v);                             // MBOX_IN: the program's doorbell
    if (!v[0]) return;
    hw(16'h070, 32'h1);
    for (int b = 0; b < 4; b++) begin           // DMA_A: 512 bytes in four 128-byte bursts
      dma_read(DMA_A + 32'(128 * b), beats, r);
      if (r != 2'b00) fail($sformatf("DMA read response %0d", r));
      for (int k = 0; k < 8; k++)
        for (int h = 0; h < 2; h++)
          if (beats[k][64*h +: 64] != mix(64'(16 * b + 2 * k + h) ^ 64'hA5))
            fail($sformatf("DMA read of the dirty buffer, word %0d: %h", 16 * b + 2 * k + h, beats[k][64*h +: 64]));
    end
    for (int b = 0; b < 4; b++) begin           // DMA_B: overwritten while the program holds copies
      for (int k = 0; k < 8; k++)
        for (int h = 0; h < 2; h++) beats[k][64*h +: 64] = mix(64'(16 * b + 2 * k + h) ^ 64'hB6);
      dma_write(DMA_B + 32'(128 * b), beats, r);
      if (r != 2'b00) fail($sformatf("DMA write response %0d", r));
    end
    if (RELEASE) begin
      // a release build without the trace: no completion queue and no line counters (DR-180); they read 0
      repeat (100) @(posedge clk);
      expect_reg(16'h1300, 32'd0, "HDMA_CTRL in a release build");
      expect_reg(16'h1304, 32'd0, "HDMA_STATUS in a release build");
      expect_reg(16'h1310, 32'd0, "HDMA_CPL0 in a release build");
      expect_reg(16'h1308, 32'd0, "HDMA_RD_LINES in a release build");
      expect_reg(16'h130C, 32'd0, "HDMA_WR_LINES in a release build");
    end else begin
      // one completion per line written, in order, with rising cycles. The count is the queue's level as the
      // host side sees it, a few clk_host cycles behind the last AccessAck (the asynchronous FIFO's pointer
      // synchronizer), while the last write's B comes in clk: poll it
      begin
        int t;
        t = 0;
        do begin hr(16'h1304, v); t++; end while (v != 32'd8 && t < 20);
      end
      if (v != 32'd8) fail($sformatf("HDMA_STATUS %0d completions, want 8", v));
      begin
        logic [31:0] last;
        last = 0;
        for (int i = 0; i < 8; i++) begin
          hr(16'h1310, v);
          hr(16'h1314, v1);
          if (!v[31] || v[25:0] != 26'((DMA_B >> 6) + 32'(i)) || (i > 0 && v1 <= last))
            fail($sformatf("completion %0d: %h cycle %0d", i, v, v1));
          last = v1;
        end
      end
      hr(16'h1308, v);
      if (v != 32'd8) fail($sformatf("HDMA_RD_LINES %0d, want 8", v));
      hr(16'h130C, v);
      if (v != 32'd8) fail($sformatf("HDMA_WR_LINES %0d, want 8", v));
    end
    hr(16'h1318, v);
    if (v != 32'd0) fail($sformatf("HDMA_WR_DROPS %0d, want 0", v));
    hw(16'h074, 32'h1);                         // MBOX_OUT: the program reads DMA_B
    dma_done = 1;
  endtask

  // The board's reset (PS_WINDOW): when the program rings the doorbell, set BOARD_CTRL[1] and answer through
  // MBOX_OUT once the core side has it
  bit board_done = 0;
  task automatic serve_board();
    logic [31:0] v;
    hr(16'h070, v);                             // MBOX_IN: the program's doorbell
    if (!v[0]) return;
    hw(16'h070, 32'h1);
    hw(16'h1404, 32'h2);
    wait_board(2'b10, "the reset path enabled");
    hw(16'h074, 32'h1);                         // MBOX_OUT
    board_done = 1;
  endtask

  // The PMOD reset hook (PS_WINDOW; BREAK_LOG2 = 6 here: a break of 64 to 255 cycles, the write at its end),
  // while the program reads the window nonstop, as a hart stuck polling a PS register would
  task automatic brk(input int cycles);
    @(negedge clk) ps_rxd = 1'b0;
    repeat (cycles) @(negedge clk);
    ps_rxd = 1'b1;
  endtask
  task automatic no_rst_write(input int n0, input string what);
    repeat (400) @(posedge clk);
    if (ps_rst != n0) fail($sformatf("%s: %0d writes to RESET_CTRL, want none", what, ps_rst - n0));
  endtask
  task automatic test_hook();
    int n0;
    hw(16'h074, 32'h1);                         // MBOX_OUT: the program starts reading the window nonstop
    n0 = ps_rst;
    hw(16'h1404, 32'h0);                        // disarmed: a break does nothing
    wait_board(2'b00, "disarmed");
    brk(128);
    no_rst_write(n0, "a break while disarmed");
    hw(16'h1404, 32'h2);
    wait_board(2'b10, "armed");
    expect_board(32'h2, "armed, nothing sent");
    brk(32);
    no_rst_write(n0, "a break of 32 cycles");
    brk(300);
    no_rst_write(n0, "a break of 300 cycles");
    brk(128);
    expect_board(32'h6, "after a break of 128 cycles");
    if (ps_rst != n0 + 1) fail($sformatf("the hook: %0d writes to RESET_CTRL, want 1", ps_rst - n0));
    else if (ps_rst_aw.addr != 40'(PS_RST) || ps_rst_aw.size != 3'd2 || ps_rst_w.strb != 16'h0F00 ||
             ps_rst_w.data[95:64] != 32'h10)
      fail($sformatf("the hook's write: %h size %0d strb %h data %h", ps_rst_aw.addr, ps_rst_aw.size,
                     ps_rst_w.strb, ps_rst_w.data));
    brk(128);
    no_rst_write(n0 + 1, "a second break (one write per arming)");
    expect_board(32'h6, "after a second break");
    hw(16'h1404, 32'h0);                        // disarmed: the status clears
    expect_board(32'h0, "disarmed after the write");
    wait_board(2'b00, "disarmed after the write");
    ps_rst_mode = 1;                            // armed again: the write answered with an error
    hw(16'h1404, 32'h2);
    wait_board(2'b10, "armed again");
    brk(128);
    expect_board(32'hE, "the write answered with an error");
    hw(16'h1404, 32'h0);
    expect_board(32'h0, "disarmed after the error");
    wait_board(2'b00, "disarmed after the error");
    ps_rst_mode = 2;                            // and not answered: the window's timeout, 2^16 cycles
    hw(16'h1404, 32'h2);
    wait_board(2'b10, "armed a third time");
    brk(128);
    repeat (66000) @(posedge clk);
    expect_board(32'hE, "the write unanswered");
    wait (ps_done == ps_txn);                   // the late answer, taken and dropped
    ps_rst_mode = 0;
    if (ps_rst != n0 + 3) fail($sformatf("the hook: %0d writes to RESET_CTRL, want 3", ps_rst - n0));
    hw(16'h1404, 32'h0);
    expect_board(32'h0, "disarmed at the end");
    $display("PMOD reset hook: %0d writes to RESET_CTRL from 7 breaks; %0d window transactions", ps_rst - n0, ps_txn);
  endtask

  // =============================================================================================
  initial begin
    logic [31:0] v;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    console = "";
    repeat (10) @(posedge clk);
    rst = 0; rst_host = 0;
    repeat (10) @(posedge clk);

    // ---- identity and reset state ----
    expect_reg(16'h000, 32'h5447_4E52, "ID");
    hr(16'h004, v);
    if (v[15:12] != 4'(NUM_CORES) || v[11:8] != 4'(NUM_THREADS)) fail($sformatf("VERSION %h", v));
    expect_reg(16'h008, 32'd100_000_000, "CLK_HZ");
    expect_reg(16'h010, 32'h3, "CTRL reset value (cores and uncore held)");
    wait_status(0, 1'b1, 2);
    wait_status(1, 1'b1, 2);
    expect_reg(16'h030, 32'h8000_0000, "BOOT_ENTRY reset value");
    expect_reg(16'h038, 32'h8220_0000, "DTB_ADDR reset value");

    // ---- load sequence (tanager-host step 2-3): window, then release the uncore ----
    hw64(16'h020, 64'(CO_BASE));
    hw64(16'h028, 64'(CO_SIZE));
    hr(16'h024, v);
    if (v != 32'(CO_BASE >> 32)) fail("DRAM_BASE high half");
    hw(16'h010, 32'h1);                         // release the uncore
    wait_status(1, 1'b0, 5);
    wait_status(2, 1'b1, 50);                   // L2 initialised
    if (PROG) begin
      // load the test program at the start of the carve-out (RISC-V 0x8000_0000), backdoor
      int fd, c;
      longint unsigned a;
      string path;
      if (!$value$plusargs("prog=%s", path)) path = "soc_test.bin";
      fd = $fopen(path, "rb");
      if (fd == 0) begin fail($sformatf("cannot open %s", path)); $finish; end
      a = 0;
      while (1) begin
        c = $fgetc(fd);
        if (c < 0) break;
        if (((CO_BASE + a) >> 6) & 1) g_mem[1].u_mem.preload_byte(CO_BASE + a, 8'(c));
        else                          g_mem[0].u_mem.preload_byte(CO_BASE + a, 8'(c));
        a++;
      end
      $fclose(fd);
      $display("loaded %0d bytes of %s", a, path);
    end
    if (PROG && TRACE) begin
      // commit-trace streaming into its memory: everything the cores retire (uncore-trace.md)
      hw64(16'h1020, 64'(TR_BASE));
      hw(16'h1028, 32'd16);                     // a ring of 64K records: no wrap in this test
      hw(16'h1000, 32'h1);                      // enable
      do hr(16'h1040, v); while (!v[0]);        // capturing in the core domain before the cores start
    end
    if (KIND == "tcore" && VIRTIO) hw(16'h1100, 32'h1);     // VQ_CTRL: the host serves the window
    if (KIND == "tcore" && HOST_DMA && !SDIRQ) hw(16'h1300, 32'h1);   // HDMA_CTRL: record the completions
    if (PROG && (VIRTIO || HOST_DMA || PS_WINDOW || RELEASE)) // FROMHOST: which parts the program runs
      hw64(16'h068, 64'h7467_0000 | 64'(VIRTIO) | (64'(HOST_DMA) << 1) | (64'(PS_WINDOW) << 2) | (64'(RELEASE) << 3));
    hw(16'h010, 32'h0);                         // release the cores
    wait_status(0, 1'b0, 5);

    // ---- the board's status word (the KV260's fan regulator) reaches the host at FAN ----
    begin
      logic [31:0] fv;
      hr(16'h1400, fv);
      if (fv != 32'h0F0A_1234) fail($sformatf("FAN %h, want the board's status word 0f0a1234", fv));
    end
    // ---- BOARD_CTRL[0] reaches the board (the KV260's fan regulator); 0 again for the rest ----
    expect_reg(16'h1404, 32'h0, "BOARD_CTRL reset value");
    hw(16'h1404, 32'h1);
    expect_reg(16'h1404, 32'h1, "BOARD_CTRL [0]");
    wait_board(2'b01, "[0]");
    hw(16'h1404, 32'h0);
    wait_board(2'b00, "cleared");

    // ---- mailbox host -> RISC-V ----
    hw(16'h074, 32'h1);
    repeat (40) @(posedge clk);
    if (!dut.u_uncore.u_host.mbox_pend_q) fail("MBOX_OUT did not reach the RISC-V side");
    if (!dut.u_uncore.plic_src[IRQ_HOSTCTL]) fail("mailbox not on PLIC source 11");

    // ---- console input reaches the UART (a release build: there is no such path) ----
    hr(16'h10C, v);
    if (v != (RELEASE ? 0 : 512)) fail($sformatf("UART_RX_SPACE %0d, want %0d", v, RELEASE ? 0 : 512));
    hw(16'h108, 32'h41);
    repeat (40) @(posedge clk);
    if (dut.u_uncore.u_uart.rx_cnt != (RELEASE ? 0 : 1))
      fail(RELEASE ? "a console byte from the host reached the UART in a release build" : "console byte did not reach the UART RX FIFO");

    if (PROG) begin
      // run until the program reports through TOHOST, echoing the console; +run_limit=N: N x 500 cycles at most
      int t, run_limit;
      bit first_ok;
      logic [31:0] seq, lo;
      if (!$value$plusargs("run_limit=%d", run_limit)) run_limit = SDIRQ ? 90000 : 20000;
      t = 0;
      first_ok = 0;
      do begin
        repeat (500) @(posedge clk);
        drain_console();
        if (VIRTIO) serve_virtio();
        if (HOST_DMA && !SDIRQ && !dma_done) serve_dma();
        if (PS_WINDOW && !SDIRQ && (dma_done || !HOST_DMA) && !board_done) serve_board();
        hr(16'h088, seq);
        // the trace consumer: check the first record once, then release everything written
        if (TRACE) hr(16'h1038, lo);
        else lo = '0;
        if (lo != 0 && !first_ok) begin
          logic [127:0] b0;
          b0 = u_tmem.peek_beat(longint'(TR_BASE));
          if (b0[1:0] != 2'd0 || b0[127:64] != 64'(BOOTROM_BASE))
            fail($sformatf("first trace record: kind %0d pc %h, want the boot ROM's first instruction", b0[1:0], b0[127:64]));
          first_ok = 1;
        end
        if (TRACE) begin hw(16'h1030, lo); hw(16'h1034, 32'h0); end   // TRS_RP = WP (records consumed)
        t++;
      end while (seq == 0 && t < run_limit);   // streaming slows the cores to the trace rate
      drain_console();
      $display("console:\n%s", console);
      hr(16'h060, lo);
      if (seq == 0) fail("the program never wrote TOHOST");
      else if (lo != 32'h1) fail($sformatf("program reported failure: TOHOST %h", lo));
      begin
        bit found;
        found = 0;
        for (int i = 0; i + 4 <= console.len(); i++) if (console.substr(i, i + 3) == "PASS") found = 1;
        if (!found) fail("no PASS on the console");
      end
      if (HOST_DMA && !SDIRQ && !dma_done) fail("the host DMA test never ran");
      if (VIRTIO && (vio_reads != 4 || vio_notify != 1))
        fail($sformatf("virtio window: %0d reads and %0d QueueNotify served, want 4 and 1", vio_reads, vio_notify));
      if (SDIRQ) begin
        $display("SD device: %0d requests, %0d command and %0d transfer completes raised (%0d while source %0d was claimed, %0d with bit 0 still set), %0d DMA bursts written and %0d read",
                 sd_go, sd_cmds, sd_xfers, sd_claimed, IRQ_PS0 + PS_IRQ_SD1, sd_both, sd_bursts, sd_wbursts);
        if (ipi_race_at != 0) $display("ipi_race: %0d claims of context 1 seen, %0d IPI injected", claims_seen, ipi_injected);
        $display("PLIC source %0d: pending %0d busy %0d enabled(ctx 0, 1) %0d %0d line %0d", IRQ_PS0 + PS_IRQ_SD1,
                 dut.u_uncore.u_plic.pend_q[IRQ_PS0 + PS_IRQ_SD1], dut.u_uncore.u_plic.busy_q[IRQ_PS0 + PS_IRQ_SD1],
                 dut.u_uncore.u_plic.en_q[0][IRQ_PS0 + PS_IRQ_SD1], dut.u_uncore.u_plic.en_q[1][IRQ_PS0 + PS_IRQ_SD1],
                 dut.u_uncore.u_plic.src_i[IRQ_PS0 + PS_IRQ_SD1]);
        if (sd_go == 0 || sd_xfers != sd_go) fail($sformatf("SD device: %0d requests, %0d completed", sd_go, sd_xfers));
      end else if (PS_WINDOW) begin
        // a release build's program also raises and lowers UART1's line: two transactions more
        if (ps_txn != (RELEASE ? 19 : 17) || ps_late != 1 || ps_rst != 1)
          fail($sformatf("PS window: %0d transactions (%0d late, %0d to RESET_CTRL), want %0d (1, 1)", ps_txn, ps_late,
                         ps_rst, RELEASE ? 19 : 17));
        else $display("PS window: %0d transactions, 1 answered after the timeout, 1 to RESET_CTRL", ps_txn);
        if (!board_done) fail("the board's reset part never asked for BOARD_CTRL[1]");
        test_hook();
      end
      // the stream: everything retired went to the trace memory, starting at the boot ROM
      if (!TRACE) begin
        hr(16'h00C, lo);
        if (lo[3]) fail("capability bit 3 (trace streaming) set in a build without the trace");
        if (taw_seen) fail("the trace master started a write in a build without the trace");
        $display("trace stream: not built (TG_COMMIT_TRACE=0)");
      end else begin
        logic [31:0] wpl, st, stl;
        hw(16'h1000, 32'h0);                    // stop capturing; the lanes drain
        repeat (2000) @(posedge clk);
        hr(16'h1038, wpl);
        hr(16'h1040, st);
        hr(16'h1044, stl);
        $display("trace stream: %0d records, %0d stall cycles, status %h", wpl, stl, st);
        if (!first_ok) fail("no trace record was checked");
        if (wpl < 1000) fail($sformatf("trace stream wrote %0d records", wpl));
        if (st[4]) fail("trace stream AXI error");
      end
    end

    if (KIND == "trafgen") begin
      int passes;
      // ---- memory passes: 2 x 1024 lines (64 KiB each) vs a 16 KiB L2: spills to memory ----
      hw(16'h0C4, 32'(DRAM_BASE >> 6) + 32'h40);
      hw(16'h0C8, 32'd1024);
      hw(16'h0C0, 32'h1);
      do begin
        repeat (2000) @(posedge clk);
        hr(16'h0DC, v);
        passes = int'(v);
      end while (passes < 6);
      expect_reg(16'h0D4, 32'd0, "traffic generator errors at injected latency 0");
      if (LAT_INJ) begin
        // ---- the same at a 250-cycle target latency ----
        hw(16'h040, 32'd250);
        hr(16'h0DC, v);
        passes = int'(v) + 4;
        do begin
          repeat (5000) @(posedge clk);
          hr(16'h0DC, v);
        end while (int'(v) < passes);
        expect_reg(16'h0D4, 32'd0, "traffic generator errors at injected latency 250");
        hr(16'h050, v);
        begin
          logic [31:0] lsum, lmax;
          hr(16'h054, lsum);
          hr(16'h058, lmax);
          $display("injector: %0d reads, native latency avg %0.1f max %0d (host registers)", v,
                   (v != 0) ? real'(lsum) / real'(v) : 0.0, lmax);
          if (v != 0 && real'(lsum) / real'(v) < 2.0) fail("injector: native latency average below 2 cycles");
        end
        if (v == 0) fail("injector saw no reads");
      end else begin
        // ---- a release build (DR-177): the L2's banks straight to the DDR models, which answer out of order;
        // no injector, so a delay written is dropped and the statistics read 0 ----
        hw(16'h040, 32'd250);
        expect_reg(16'h040, 32'd0, "INJ_RD_DELAY in a build without the injectors");
        expect_reg(16'h050, 32'd0, "INJ_RD_COUNT in a build without the injectors");
        expect_reg(16'h054, 32'd0, "INJ_RD_LATSUM in a build without the injectors");
        expect_reg(16'h058, 32'd0, "INJ_RD_LATMAX in a build without the injectors");
        $display("injector: not built (LAT_INJ=0)");
      end
      hw(16'h0C0, 32'h0);
      hw(16'h040, 32'd0);
      hr(16'h0D0, v);
      $display("traffic generators: %0d lines checked, %0d passes of generator 0", v, passes);
      // ---- console output: one character per pass from each generator ----
      repeat (200) @(posedge clk);
      drain_console();
      $display("console: \"%s\"", console);
      if (console.len() < 6) fail("too little console output");
      for (int i = 0; i < console.len(); i++) if (console[i] != ".") fail("console shows an error pass");
    end

    // ---- the injectors' capability bit (DR-177: none in a release build), and DR-180's ----
    begin
      logic [31:0] caps;
      hr(16'h00C, caps);
      if (caps[1] != LAT_INJ) fail($sformatf("capability bit 1 (the latency injector) %0d with LAT_INJ=%0d", caps[1], LAT_INJ));
      if (caps[9] != !RELEASE) fail($sformatf("capability bit 9 (the host console) %0d with RELEASE=%0d", caps[9], RELEASE));
      if (caps[10] != (HOST_DMA && !RELEASE))
        fail($sformatf("capability bit 10 (the DMA line counters) %0d with HOST_DMA=%0d RELEASE=%0d", caps[10], HOST_DMA, RELEASE));
      if (caps[11] != (HOST_DMA && (!RELEASE || TRACE)))
        fail($sformatf("capability bit 11 (the DMA completion queue) %0d with HOST_DMA=%0d RELEASE=%0d", caps[11], HOST_DMA, RELEASE));
      if (caps[31:12] != 0) fail($sformatf("CAPS %h: bits above 11 set", caps));
    end

    // ---- hold everything in reset again (tanager-host reset) ----
    hw(16'h010, 32'h3);
    wait_status(0, 1'b1, 5);
    wait_status(1, 1'b1, 5);

    if (errors == 0) $display("TEST PASSED (%s)", KIND);
    else             $display("TEST FAILED (%s): %0d errors", KIND, errors);
    $finish;
  end

  initial begin
    #500ms;
    $display("TEST FAILED: timeout");
    $finish;
  end
endmodule
