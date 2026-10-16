// SoC simulation test (docs/spec/soc.md §Verification): tanager_soc with AXI memory models and a
// host on an unrelated clock that drives the AXI4-Lite window the way tanager-host does.
//   KIND = "core":    stub cores. Host register map, reset sequencing, L2 initialisation, DRAM
//                     window registers, mailbox to the RISC-V side, console input path.
//   KIND = "trafgen": traffic generators in the cores' place. Memory passes through the L2, the
//                     latency injector and the window (L2 shrunk so the region spills to memory),
//                     at injected latencies 0 and 250; console output ('.' per pass) read back by
//                     the host; every memory access must land inside the carve-out.
module tb_soc;
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;

  parameter string KIND = "core";       // "core" (stub cores), "trafgen", or "tcore" (tg_core is the
                                        // test core: tests/unit/soc/tcore_as_core.sv)

  localparam logic [39:0] CO_BASE = 40'h8_4000_0000;    // carve-out in "PS" address space
  localparam logic [39:0] CO_SIZE = 40'h0400_0000;      // 64 MiB
  localparam logic [39:0] TR_BASE = 40'h8_4800_0000;    // the trace stream's ring
  // Built without the trace (make ... COMMIT_TRACE=0, +define+TG_COMMIT_TRACE=0; DR-146): the program still runs,
  // the capability bit reads 0 and the trace master never starts a write.
  localparam bit TRACE = tg_trace_pkg::COMMIT_TRACE;

  logic clk = 1'b0, clk_host = 1'b0, rst = 1'b1, rst_host = 1'b1;
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
  bit      taw_seen = 1'b0;                 // the trace master started a write
  always @(posedge clk) if (tawv || twv) taw_seen <= 1'b1;

  tg_trace_pkg::tr_rec_t [NUM_CORES-1:0][COMMIT_WIDTH-1:0]   trace;
  logic [NUM_CORES-1:0][COMMIT_WIDTH-1:0]   trace_v;
  tg_trace_pkg::tr_wb_t  [NUM_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb;
  logic [NUM_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_v;

  tanager_soc #(
    .N_CORES (NUM_CORES), .CLK_HZ (100_000_000), .L2_SETS (16), .L2_MSHR (24),
    .CORE_RST_INIT (1'b1), .UNCORE_RST_INIT (1'b1), .CORE_KIND ((KIND == "trafgen") ? "trafgen" : "core")
  ) dut (
    .uart_txd_o (), .uart_rxd_i (1'b1),
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

  // Drain the console: everything the RISC-V side has written so far
  string console;
  task automatic drain_console();
    logic [31:0] v;
    do begin
      hr(16'h100, v);
      if (v[8]) console = {console, $sformatf("%c", v[7:0])};
    end while (v[8]);
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
    if (KIND == "tcore") begin
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
    if (KIND == "tcore" && TRACE) begin
      // commit-trace streaming into its memory: everything the cores retire (uncore-trace.md)
      hw64(16'h1020, 64'(TR_BASE));
      hw(16'h1028, 32'd16);                     // a ring of 64K records: no wrap in this test
      hw(16'h1000, 32'h1);                      // enable
      do hr(16'h1040, v); while (!v[0]);        // capturing in the core domain before the cores start
    end
    hw(16'h010, 32'h0);                         // release the cores
    wait_status(0, 1'b0, 5);

    // ---- mailbox host -> RISC-V ----
    hw(16'h074, 32'h1);
    repeat (40) @(posedge clk);
    if (!dut.u_uncore.u_host.mbox_pend_q) fail("MBOX_OUT did not reach the RISC-V side");
    if (!dut.u_uncore.plic_src[IRQ_HOSTCTL]) fail("mailbox not on PLIC source 11");

    // ---- console input reaches the UART ----
    hr(16'h10C, v);
    if (v != 512) fail($sformatf("UART_RX_SPACE %0d, want 512", v));
    hw(16'h108, 32'h41);
    repeat (40) @(posedge clk);
    if (dut.u_uncore.u_uart.rx_cnt != 1) fail("console byte did not reach the UART RX FIFO");

    if (KIND == "tcore") begin
      // run until the program reports through TOHOST, echoing the console
      int t;
      bit first_ok;
      logic [31:0] seq, lo;
      t = 0;
      first_ok = 0;
      do begin
        repeat (500) @(posedge clk);
        drain_console();
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
      end while (seq == 0 && t < 20000);         // streaming slows the cores to the trace rate
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
