// Software boot on tanager_soc with the real core (docs/spec/soc.md §Verification): the host loads
// images into the carve-out the way tanager-host does, releases the cores, and echoes the console.
// The run passes when the console shows the +expect string.
//   +fw=<file>      at 0x8000_0000 (OpenSBI fw_jump)          +dtb=<file>    at DTB_ADDR (0x8220_0000)
//   +kernel=<file>  at 0x8020_0000 (optional)                 +initrd=<file> at 0x8400_0000 (optional)
//   +expect=<text>  pass when the console contains it         +max_mcycles=N  give up after N million cycles
//   +dump_pc=<hex>  print the hart's last records when a record has this pc (once)
//   +dump_cause=N   ... when an instruction traps with this cause (once)      +dump_stop  end the run there
//   +trace_out=<file>  the commit trace into <file>, 64 bytes a record, as tanager-host --trace writes it
//                      (for tanager-lockstep); unwritten memory then reads as zero, as on the board
// At the end the run prints a signature over every commit record and its cycle: two builds that give
// the same signature retired the same instructions in the same cycles (the cycle-identity check of
// docs/perf/fpga_friendly.md for uncore rewrites). Each progress line carries the running signature,
// so two runs compare at every million cycles, however far each got.
module tb_boot;
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;

  parameter int N_CORES = 1;
  parameter bit UART_SERIAL_TB = 1'b0;   // console on the serial line; the host keeps a copy
  // The DDR models' timing: random by default; MEM_LAT_MIN = MEM_LAT_MAX with every *_PCT at 100 and
  // MEM_OOO 0 gives the board's fixed latency, where the cores run in step from reset
  parameter int MEM_LAT_MIN   = 4;
  parameter int MEM_LAT_MAX   = 12;
  parameter int MEM_READY_PCT = 95;
  parameter bit MEM_OOO       = 1'b1;
  parameter int MEM_R_PCT     = 85;
  parameter int L2_SETS_TB    = 64;      // the board has 1024 (tanager_soc's default)
  parameter bit DEBUG_CNT_TB  = 1'b0;    // the board debug counters; +dbg_dump prints them at the end
  parameter bit HOST_DMA_TB   = 1'b0;    // the host DMA port, for +hdma_lines (external-write lockstep, below)

  localparam logic [39:0] CO_BASE = 40'h8_4000_0000;    // carve-out in "PS" address space
  localparam logic [39:0] CO_SIZE = 40'h1000_0000;      // 256 MiB (the device tree says 128 MiB)
  localparam longint unsigned RV_DRAM = 64'h8000_0000;
  localparam logic [39:0] TR_BASE = 40'h8_4800_0000;    // the trace ring, in the trace memory
  localparam int          TR_LOG2 = 12;                 // 4,096 records: it wraps, and the reader holds the cores

  logic clk = 1'b0, clk_host = 1'b0, rst = 1'b1, rst_host = 1'b1;
  logic uart_txd;
  always #5    clk      = ~clk;        // 100 MHz
  always #6.85 clk_host = ~clk_host;   // ~73 MHz, unrelated

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

  // the host DMA port, driven by the external-write model (+hdma_lines, below)
  hdma_ax_t dma_aw  = '0;
  axi_w_t   dma_w   = '0;
  hdma_b_t  dma_b;
  logic     dma_awv = 1'b0, dma_wv = 1'b0, dma_awr, dma_wr, dma_bv;

  tg_trace_pkg::tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace;
  logic [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_v;
  tg_trace_pkg::tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb;
  logic [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_v;

  tanager_soc #(
    .N_CORES (N_CORES), .CLK_HZ (100_000_000), .L2_SETS (L2_SETS_TB), .L2_MSHR (24), .DEBUG_CNT (DEBUG_CNT_TB),
    .HOST_DMA (HOST_DMA_TB),
    .CORE_RST_INIT (1'b1), .UNCORE_RST_INIT (1'b1), .CORE_KIND ("core"), .UART_SERIAL (UART_SERIAL_TB)
  ) dut (
    .uart_txd_o (uart_txd), .uart_rxd_i (1'b1),
    .clk, .rst, .clk_host, .rst_host,
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
    .s_axi_dma_aw (dma_aw), .s_axi_dma_aw_valid (dma_awv), .s_axi_dma_aw_ready (dma_awr), .s_axi_dma_w (dma_w),
    .s_axi_dma_w_valid (dma_wv), .s_axi_dma_w_ready (dma_wr), .s_axi_dma_b (dma_b), .s_axi_dma_b_valid (dma_bv),
    .s_axi_dma_b_ready (1'b1), .s_axi_dma_ar ('0),
    .s_axi_dma_ar_valid (1'b0), .s_axi_dma_ar_ready (), .s_axi_dma_r (), .s_axi_dma_r_valid (), .s_axi_dma_r_ready (1'b1),
    // the PS window (stage D, tg_map_pkg PS_WINDOW) has nothing behind it here: never addressed
    .m_axi_ps_aw (), .m_axi_ps_aw_valid (), .m_axi_ps_aw_ready (1'b1), .m_axi_ps_w (), .m_axi_ps_w_valid (),
    .m_axi_ps_w_ready (1'b1), .m_axi_ps_b ('0), .m_axi_ps_b_valid (1'b0), .m_axi_ps_b_ready (), .m_axi_ps_ar (),
    .m_axi_ps_ar_valid (), .m_axi_ps_ar_ready (1'b1), .m_axi_ps_r ('0), .m_axi_ps_r_valid (1'b0), .m_axi_ps_r_ready (),
    .ps_irq_i ('0), .board_status_i ('0), .board_ctrl_o (),
    .trace_o (trace), .trace_valid_o (trace_v), .trace_wb_o (trace_wb), .trace_wb_valid_o (trace_wb_v),
    .status_o (status)
  );

  for (genvar k = 0; k < N_BANKS; k++) begin : g_mem
    tb_axi_mem #(.LAT_MIN(MEM_LAT_MIN), .LAT_MAX(MEM_LAT_MAX), .READY_PCT(MEM_READY_PCT), .OOO(MEM_OOO),
                 .R_PCT(MEM_R_PCT), .NAME($sformatf("ddr%0d", k))) u_mem (
      .clk, .rst,
      .ar_i (ar[k]), .ar_valid_i (arv[k]), .ar_ready_o (arr[k]),
      .r_o (r[k]), .r_valid_o (rv[k]), .r_ready_i (rr[k]),
      .aw_i (aw[k]), .aw_valid_i (awv[k]), .aw_ready_o (awr[k]),
      .w_i (w[k]), .w_valid_i (wv[k]), .w_ready_o (wr[k]),
      .b_o (b[k]), .b_valid_o (bv[k]), .b_ready_i (br[k])
    );
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

  // ---- External writes for lockstep (verification.md §3.10; the verification track's gen_coh mode) ----
  // +hdma_base=PA +hdma_lines=N +hdma_rounds=R (HOST_DMA_TB): R rounds, each writing every line i < N once, whole
  // (one 64-byte burst on the host DMA port, a PutFull), in random order with 0-2000-cycle gaps; word w of line i
  // in round k is k << 32 | i << 8 | w. Off without +hdma_lines. Each write's completion (HDMA_CPL0/1, its
  // AccessAck cycle in the trace's count) becomes two 0xE1 records in +trace_out, ahead of every trace record of
  // that cycle or later: trace_poll holds the records from a write's issue until its completion is read, as
  // tanager-host does on the board. The records go ahead of every trace record captured from the write's
  // issue on, not only from its AccessAck: the L2 may give the new line to a core before the AccessAck, and a
  // load's record can then carry a cycle up to 256 below it (the verification track's rule, §3.10).
  typedef struct { int line; int round; } hdma_wr_t;
  typedef struct { int line; logic [31:0] cycle; logic [31:0] issue; } hdma_cpl_t;
  longint unsigned hdma_base = 0;
  int        hdma_lines = 0, hdma_rounds = 0;
  logic      hdma_go = 1'b0;            // completions enabled: the model may start
  logic [31:0] hdma_issue [$];          // the trace-count cycle of each write issued and not yet completed
  hdma_wr_t  hdma_wrote [$];            // what each such write wrote, oldest first
  hdma_cpl_t hdma_cpl [$];              // completions read, their records not yet written
  int        hdma_n_cpl = 0;
  if (HOST_DMA_TB) begin : g_hdma_model
    initial begin
      int order [$];
      wait (hdma_go);
      for (int k = 1; k <= hdma_rounds; k++) begin
        order.delete();
        for (int i = 0; i < hdma_lines; i++) order.push_back(i);
        order.shuffle();
        foreach (order[j]) begin
          int i;
          i = order[j];
          repeat ($urandom_range(2000)) @(posedge clk);
          @(negedge clk);
          dma_aw  = '{id: HDMA_ID_W'(j), addr: AXI_ADDR_W'(hdma_base - RV_DRAM + 64 * i), len: 8'd3, size: 3'd4,
                      burst: AXI_INCR};
          dma_awv = 1'b1;
          hdma_issue.push_back(dut.u_uncore.g_hdma.u_hdma.cycle_q);
          hdma_wrote.push_back('{line: i, round: k});
          do @(posedge clk); while (!dma_awr);
          @(negedge clk) dma_awv = 1'b0;
          for (int b = 0; b < 4; b++) begin
            logic [63:0] w0, w1;
            w0 = 64'(k) << 32 | 64'(i) << 8 | 64'(2 * b);
            w1 = 64'(k) << 32 | 64'(i) << 8 | 64'(2 * b + 1);
            dma_w  = '{data: {w1, w0}, strb: '1, last: b == 3};
            dma_wv = 1'b1;
            do @(posedge clk); while (!dma_wr);
            @(negedge clk);
          end
          dma_wv = 1'b0;
          do @(posedge clk); while (!dma_bv);
          if (dma_b.resp != AXI_OKAY) $error("tb_boot: host DMA write of line %0d answered %0d", i, dma_b.resp);
        end
      end
      $display("\n[tb_boot] host DMA: %0d rounds of %0d lines written", hdma_rounds, hdma_lines);
    end
  end


  // ---- Serial console (UART_SERIAL_TB): TXD decoded at 115200 baud (divisor 2 at 3.6864 MHz) ----
  string sconsole = "";
  if (UART_SERIAL_TB) begin : g_sdec
    localparam real BIT = 100.0e6 / 115200.0;   // cycles per bit at the 100 MHz clock
    initial begin
      forever begin
        logic [7:0] b;
        @(negedge uart_txd);
        repeat ($rtoi(BIT * 1.5)) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
          b[i] = uart_txd;
          repeat ($rtoi(BIT)) @(posedge clk);
        end
        if (uart_txd) sconsole = {sconsole, string'(b)};
        else          $display("tb_boot: serial framing error after %0d characters", sconsole.len());
      end
    end
  end
  // ---- retirement count (all harts) and the last records of each hart, for progress and post-mortem ----
  localparam int NH_TB = N_CORES * NUM_THREADS;
  localparam int LAST  = 64;
  typedef struct {
    logic [63:0] pc;
    logic [31:0] insn;
    logic [1:0]  kind;
    logic [1:0]  priv;
    logic [63:0] val;        // rd value; the cause of a trap or interrupt
    logic [63:0] tval;
  } last_t;
  longint unsigned instret = 0;
  last_t           last_rec [NH_TB][LAST];
  longint unsigned last_n   [NH_TB];
  longint unsigned cycles = 0;
  logic [63:0]     tsig = 64'hcbf2_9ce4_8422_2325;   // FNV-1a offset basis
  function automatic logic [63:0] fnv(input logic [63:0] h, input logic [63:0] x);
    for (int b = 0; b < 8; b++) h = (h ^ 64'(x[8*b +: 8])) * 64'h0000_0100_0000_01b3;
    return h;
  endfunction
  logic [63:0]     dump_pc;
  int              dump_cause;
  bit              dump_pc_on, dump_cause_on, dump_stop, dumped = 1'b0;
  initial begin
    dump_pc_on    = $value$plusargs("dump_pc=%h", dump_pc);
    dump_cause_on = $value$plusargs("dump_cause=%d", dump_cause);
    dump_stop     = $test$plusargs("dump_stop");
  end
  always @(posedge clk) if (!rst) cycles <= cycles + 1;
  always @(posedge clk) if (!rst)
    for (int c = 0; c < N_CORES; c++)
      for (int k = 0; k < COMMIT_WIDTH; k++)
        if (trace_v[c][k]) begin
          int h;
          h = int'(trace[c][k].hart);
          if (trace[c][k].kind == tg_trace_pkg::TR_RETIRE) instret++;
          if (h < NH_TB) begin
            last_rec[h][last_n[h] % LAST] = '{pc: trace[c][k].pc, insn: trace[c][k].insn, kind: trace[c][k].kind,
                                             priv: trace[c][k].priv,
                                             val: (trace[c][k].kind == tg_trace_pkg::TR_RETIRE) ? trace[c][k].rd_value : trace[c][k].cause,
                                             tval: trace[c][k].tval};
            last_n[h]++;
            tsig = fnv(tsig, cycles);
            tsig = fnv(tsig, {32'(h), trace[c][k].insn});
            tsig = fnv(tsig, trace[c][k].pc);
            tsig = fnv(tsig, (trace[c][k].kind == tg_trace_pkg::TR_RETIRE) ? trace[c][k].rd_value : trace[c][k].cause);
            if (!dumped && ((dump_pc_on && trace[c][k].pc == dump_pc) ||
                            (dump_cause_on && trace[c][k].kind == tg_trace_pkg::TR_TRAP &&
                             trace[c][k].cause == 64'(dump_cause)))) begin
              dumped = 1'b1;
              $display("\n[tb_boot] trigger: hart %0d, cycle %0d, pc %h", h, cycles, trace[c][k].pc);
              dump_hart(h);
              if (dump_stop) $finish;
            end
          end
        end
  function automatic string last_pc_str();
    string r;
    r = "";
    for (int h = 0; h < NH_TB; h++)
      r = {r, $sformatf(" hart%0d pc %h", h, (last_n[h] == 0) ? 64'd0 : last_rec[h][(last_n[h] - 1) % LAST].pc)};
    return r;
  endfunction
  task automatic dump_hart(input int h);
    $display("[tb_boot] hart %0d: the last %0d of %0d records", h, (last_n[h] < LAST) ? last_n[h] : LAST, last_n[h]);
    for (longint unsigned i = (last_n[h] > LAST) ? last_n[h] - LAST : 0; i < last_n[h]; i++) begin
      last_t r;
      r = last_rec[h][i % LAST];
      $display("  %s pc %h insn %h priv %0d %s %h%s", (r.kind == 0) ? "retire" : (r.kind == 1) ? "TRAP  " : "IRQ   ",
               r.pc, r.insn, r.priv, (r.kind == 0) ? "rd" : "cause", r.val,
               (r.kind == 1) ? $sformatf(" tval %h", r.tval) : "");
    end
  endtask
  task automatic dump_last();
    for (int h = 0; h < NH_TB; h++) dump_hart(h);
  endtask

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
  task automatic wait_status(input int bit_i, input logic val);
    logic [31:0] v;
    do hr(16'h014, v); while (v[bit_i] != val);
  endtask

  // ---- loading: backdoor writes into the two banks' memory models ----
  task automatic load(input string path, input longint unsigned rv_addr);
    int fd, c;
    longint unsigned a, pa;
    fd = $fopen(path, "rb");
    if (fd == 0) begin
      $display("TEST FAILED: cannot open %s", path);
      $finish;
    end
    a = 0;
    while (1) begin
      c = $fgetc(fd);
      if (c < 0) break;
      pa = longint'(CO_BASE) + rv_addr - RV_DRAM + a;
      if ((pa >> 6) & 1) g_mem[1].u_mem.preload_byte(pa, 8'(c));
      else               g_mem[0].u_mem.preload_byte(pa, 8'(c));
      a++;
    end
    $fclose(fd);
    $display("tb_boot: loaded %s at %h (%0d bytes)", path, rv_addr, a);
  endtask

  string console = "", expect_s = "";
  task automatic drain_console();
    logic [31:0] v;
    do begin
      hr(16'h100, v);
      if (v[8]) begin
        console = {console, $sformatf("%c", v[7:0])};
        $write("%c", v[7:0]);
      end
    end while (v[8]);
    $fflush();
  endtask
  function automatic bit console_has(input string s);
    if (s.len() == 0) return 1'b0;
    for (int i = 0; i + s.len() <= console.len(); i++)
      if (console.substr(i, i + s.len() - 1) == s) return 1'b1;
    return 1'b0;
  endfunction

  // =============================================================================================
  // tanager-host's `run --trace FILE` (host.md): +trace_out=FILE streams every commit record into the ring,
  // copies the records the stream has completed to FILE, 64 bytes each as the board's ring holds them, and
  // frees them (TRS_RP), so that tanager-lockstep can check the run (verification.md §3.9).
  int              trace_fd = 0;
  longint unsigned trace_rp = 0;
  // the completions waiting in HDMA_CPL0/1, in order; each retires its write's issue entry
  task automatic hdma_cpl_read();
    logic [31:0] c0, c1;
    forever begin
      hr(16'h1310, c0);
      if (!c0[31]) break;
      hr(16'h1314, c1);                         // pops the completion
      if (hdma_issue.size() == 0) $fatal(1, "tb_boot: a host DMA completion with no write in flight");
      hdma_cpl.push_back('{line: int'(c0[25:0]), cycle: c1, issue: hdma_issue.pop_front()});
    end
  endtask
  // a completion's two 0xE1 records: bytes 0-7 the address, 8-39 the data, 40-43 the AccessAck cycle, 44-47
  // the byte mask, 63 the kind (verification.md §3.10)
  task automatic hdma_emit(input hdma_cpl_t c);
    hdma_wr_t wr;
    longint unsigned pa;
    logic [511:0] line;
    if (hdma_wrote.size() == 0) $fatal(1, "tb_boot: a host DMA completion with no write");
    wr = hdma_wrote.pop_front();
    pa = RV_DRAM + longint'(c.line) * 64;
    if (pa != hdma_base + 64 * longint'(wr.line)) $error("tb_boot: completion for line %0d, wrote line %0d", c.line, wr.line);
    for (int w = 0; w < 8; w++) line[64*w +: 64] = 64'(wr.round) << 32 | 64'(wr.line) << 8 | 64'(w);
    for (int h = 0; h < 2; h++) begin
      logic [511:0] r;
      r = '0;
      r[63:0]    = 64'(pa + 32 * h);
      r[319:64]  = line[256*h +: 256];
      r[351:320] = c.cycle;
      r[383:352] = 32'hFFFF_FFFF;
      r[511:504] = 8'hE1;
      for (int i = 0; i < 64; i++) $fwrite(trace_fd, "%c", r[8*i +: 8]);
    end
    hdma_n_cpl++;
  endtask

  // With external writes, a completion's records go ahead of the first record captured at or after its
  // write's issue, and records wait while a write issued at or before their cycle is still in flight; the
  // last call flushes what is left.
  task automatic trace_poll(input bit last = 1'b0);
    logic [31:0] lo, hi;
    longint unsigned wp, a, n;
    logic [127:0] b;
    logic [511:0] rec;
    if (trace_fd == 0) return;
    if (hdma_lines > 0) hdma_cpl_read();
    hr(16'h1038, lo);
    hr(16'h103C, hi);
    wp = {hi, lo};
    for (n = trace_rp; n < wp; n++) begin
      a = longint'(TR_BASE) + (n % (64'd1 << TR_LOG2)) * 64;
      for (int k = 0; k < 4; k++) rec[128*k +: 128] = u_tmem.peek_beat(a + longint'(k) * 16);
      while (hdma_cpl.size() > 0 && hdma_cpl[0].issue <= rec[351:320]) hdma_emit(hdma_cpl.pop_front());
      if (hdma_issue.size() > 0 && rec[351:320] >= hdma_issue[0]) break;   // a write in flight may precede it
      for (int i = 0; i < 64; i++) $fwrite(trace_fd, "%c", rec[8*i +: 8]);
    end
    if (last) while (hdma_cpl.size() > 0) hdma_emit(hdma_cpl.pop_front());
    if (n != trace_rp) begin
      trace_rp = n;
      hw64(16'h1030, trace_rp);
    end
  endtask

  initial begin
    string path;
    longint unsigned max_cycles, cyc;
    int max_m;
    logic [31:0] v;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    if (!$value$plusargs("expect=%s", expect_s)) expect_s = "";
    if (!$value$plusargs("max_mcycles=%d", max_m)) max_m = 20;
    max_cycles = longint'(max_m) * 1_000_000;
    if ($value$plusargs("max_kcycles=%d", max_m)) max_cycles = longint'(max_m) * 1_000;   // a short run
    $display("tb_boot: %0d core(s) x %0d thread(s), expect \"%s\", up to %0d M cycles", N_CORES, NUM_THREADS, expect_s, max_m);
    for (int h = 0; h < NH_TB; h++) last_n[h] = 0;

    // A traced run is checked against Spike, whose memory starts at zero: unwritten memory reads as zero
    // here too, as on the board, where tanager-host zeroes the window for --trace. Set before the images
    // load, so the bytes they leave unwritten in a beat are zero as well.
    if ($test$plusargs("trace_out=")) begin
      g_mem[0].u_mem.zero_unwritten(1'b1);
      g_mem[1].u_mem.zero_unwritten(1'b1);
    end

    repeat (10) @(posedge clk);
    rst = 0; rst_host = 0;
    repeat (10) @(posedge clk);

    // tanager-host's load sequence: window, uncore out of reset, images, entry points, cores
    hw64(16'h020, 64'(CO_BASE));
    hw64(16'h028, 64'(CO_SIZE));
    hw(16'h010, 32'h1);
    wait_status(1, 1'b0);
    wait_status(2, 1'b1);
    if ($value$plusargs("fw=%s", path))     load(path, 64'h8000_0000);
    if ($value$plusargs("dtb=%s", path))    load(path, 64'h8220_0000);
    if ($value$plusargs("kernel=%s", path)) load(path, 64'h8020_0000);
    if ($value$plusargs("initrd=%s", path)) load(path, 64'h8400_0000);
    hw64(16'h030, 64'h8000_0000);               // BOOT_ENTRY
    hw64(16'h038, 64'h8220_0000);               // DTB_ADDR
    if ($value$plusargs("trace_out=%s", path)) begin
      trace_fd = $fopen(path, "wb");
      if (trace_fd == 0) $fatal(1, "tb_boot: cannot open %s", path);
      hw64(16'h1020, 64'(TR_BASE));
      hw(16'h1028, 32'(TR_LOG2));
      hw64(16'h1030, 64'h0);
      hw(16'h1000, 32'h1);                      // enable, no wrap: the cores wait for the reader
      do hr(16'h1040, v); while (!v[0]);
    end
    if ($value$plusargs("hdma_lines=%d", hdma_lines) && hdma_lines > 0) begin
      if (!HOST_DMA_TB) $fatal(1, "tb_boot: +hdma_lines needs a build with HOST_DMA_TB=1");
      if (!$value$plusargs("hdma_base=%h", hdma_base)) hdma_base = 64'h8010_0000;
      if (!$value$plusargs("hdma_rounds=%d", hdma_rounds)) hdma_rounds = 4;
      // the DMA port drops a write past the window (no AccessAck, so no completion), which would hold the trace
      if (hdma_base < RV_DRAM || hdma_base + 64 * hdma_lines - RV_DRAM > longint'(CO_SIZE) || hdma_base % 64 != 0)
        $fatal(1, "tb_boot: +hdma_base %h: the lines must be line-aligned inside the RISC-V window (%h + %h)",
               hdma_base, RV_DRAM, CO_SIZE);
      hw(16'h1300, 32'h1);                      // HDMA_CTRL: record completions
      hdma_go = 1'b1;
      // the plusargs spelled out here also give run_coh's guard its string ("hdma_lines=") in the binary
      $display("tb_boot: host DMA writes, +hdma_lines=%0d +hdma_base=%h +hdma_rounds=%0d", hdma_lines, hdma_base,
               hdma_rounds);
    end
    hw(16'h010, 32'h0);                         // release the cores
    wait_status(0, 1'b0);

    cyc = 0;
    while (!console_has(expect_s) && cyc < max_cycles) begin
      repeat (2000) @(posedge clk);
      cyc += 2000;
      drain_console();
      trace_poll();
      if (cyc % 1_000_000 == 0) $display("\n[tb_boot] %0d M cycles, %0d instructions retired, sig %016h,%s", cyc / 1_000_000, instret, tsig, last_pc_str());
      hr(16'h018, v);
      if (v[31]) begin
        $display("\ntb_boot: power request %h", v[15:0]);
        break;
      end
    end
    drain_console();
    if (trace_fd != 0) begin                    // stop taking records; the lanes drain into the ring
      hw(16'h1000, 32'h0);
      repeat (4000) @(posedge clk);
      for (int t = 0; t < 1000 && hdma_issue.size() > 0; t++) begin   // writes still in flight complete
        repeat (100) @(posedge clk);
        hdma_cpl_read();
      end
      trace_poll(1'b1);
      $fclose(trace_fd);
      $display("\n[tb_boot] trace: %0d records%s", trace_rp,
               hdma_lines > 0 ? $sformatf(", %0d external-write completions", hdma_n_cpl) : "");
    end
    if (DEBUG_CNT_TB && $test$plusargs("dbg_dump")) begin
      // the cores held first (CTRL[0]), so the counters stop and the dump is one moment (the verification
      // track's note); a transaction left open in the L2 does not matter once the test is over
      logic [31:0] dv;
      hw(16'h010, 32'h1);
      repeat (100) @(posedge clk);
      // the counters, the levels word, then the DRAM windows' refusals and the first L2 error and refusal
      for (int i = 0; i <= 8 * N_BANKS + 5 * N_CORES + 6; i++) begin
        hw(16'h1200, 32'(i));
        repeat (200) @(posedge clk);
        hr(16'h1204, dv);
        $display("[tb_boot] debug counter %0d: %0d (0x%08h)", i, dv, dv);
      end
      // the cores' board-debug words: 128 + 32c + w
      for (int c = 0; c < N_CORES; c++)
        for (int k = 0; k < 32; k++) begin
          hw(16'h1200, 32'(128 + 32 * c + k));
          repeat (200) @(posedge clk);
          hr(16'h1204, dv);
          if (k == 0 || dv != 0) $display("[tb_boot] core %0d debug word %0d: 0x%08h", c, k, dv);
        end
    end
    $display("\n[tb_boot] %0d cycles, %0d instructions retired", cyc, instret);
    $display("[tb_boot] trace signature %016h", tsig);
    if (UART_SERIAL_TB) begin
      if (sconsole.len() == 0) $display("tb_boot: ERROR: nothing on the serial line");
      else if (console.substr(0, sconsole.len() - 1) != sconsole) $display("tb_boot: ERROR: the serial line and the host copy differ");
      else $display("tb_boot: serial line: %0d characters, the same as the host copy", sconsole.len());
    end
    if (console_has(expect_s)) $display("TEST PASSED (boot, %0d core(s))", N_CORES);
    else begin
      dump_last();
      $display("TEST FAILED (boot, %0d core(s)): \"%s\" not seen", N_CORES, expect_s);
    end
    $finish;
  end
endmodule
