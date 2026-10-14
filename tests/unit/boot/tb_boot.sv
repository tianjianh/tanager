// Software boot on tanager_soc with the real core (docs/spec/soc.md §Verification): the host loads
// images into the carve-out the way tanager-host does, releases the cores, and echoes the console.
// The run passes when the console shows the +expect string.
//   +fw=<file>      at 0x8000_0000 (OpenSBI fw_jump)          +dtb=<file>    at DTB_ADDR (0x8220_0000)
//   +kernel=<file>  at 0x8020_0000 (optional)                 +initrd=<file> at 0x8400_0000 (optional)
//   +expect=<text>  pass when the console contains it         +max_mcycles=N  give up after N million cycles
module tb_boot;
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;

  parameter int N_CORES = 1;

  localparam logic [39:0] CO_BASE = 40'h8_4000_0000;    // carve-out in "PS" address space
  localparam logic [39:0] CO_SIZE = 40'h1000_0000;      // 256 MiB (the device tree says 128 MiB)
  localparam longint unsigned RV_DRAM = 64'h8000_0000;

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

  tg_trace_pkg::tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace;
  logic [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_v;
  tg_trace_pkg::tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb;
  logic [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_v;

  tanager_soc #(
    .N_CORES (N_CORES), .CLK_HZ (100_000_000), .L2_SETS (64), .L2_MSHR (24),
    .CORE_RST_INIT (1'b1), .UNCORE_RST_INIT (1'b1), .CORE_KIND ("core")
  ) dut (
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
    .trace_o (trace), .trace_valid_o (trace_v), .trace_wb_o (trace_wb), .trace_wb_valid_o (trace_wb_v),
    .status_o (status)
  );

  for (genvar k = 0; k < N_BANKS; k++) begin : g_mem
    tb_axi_mem #(.LAT_MIN(4), .LAT_MAX(12), .READY_PCT(95), .OOO(1'b1), .NAME($sformatf("ddr%0d", k))) u_mem (
      .clk, .rst,
      .ar_i (ar[k]), .ar_valid_i (arv[k]), .ar_ready_o (arr[k]),
      .r_o (r[k]), .r_valid_o (rv[k]), .r_ready_i (rr[k]),
      .aw_i (aw[k]), .aw_valid_i (awv[k]), .aw_ready_o (awr[k]),
      .w_i (w[k]), .w_valid_i (wv[k]), .w_ready_o (wr[k]),
      .b_o (b[k]), .b_valid_o (bv[k]), .b_ready_i (br[k])
    );
  end

  // ---- retirement count (all harts), for progress lines ----
  longint unsigned instret = 0;
  always @(posedge clk) if (!rst)
    for (int c = 0; c < N_CORES; c++)
      for (int k = 0; k < COMMIT_WIDTH; k++)
        if (trace_v[c][k] && trace[c][k].kind == tg_trace_pkg::TR_RETIRE) instret++;

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
  initial begin
    string path;
    longint unsigned max_cycles, cyc;
    int max_m;
    logic [31:0] v;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    if (!$value$plusargs("expect=%s", expect_s)) expect_s = "";
    if (!$value$plusargs("max_mcycles=%d", max_m)) max_m = 20;
    max_cycles = longint'(max_m) * 1_000_000;
    $display("tb_boot: %0d core(s) x %0d thread(s), expect \"%s\", up to %0d M cycles", N_CORES, NUM_THREADS, expect_s, max_m);

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
    hw(16'h010, 32'h0);                         // release the cores
    wait_status(0, 1'b0);

    cyc = 0;
    while (!console_has(expect_s) && cyc < max_cycles) begin
      repeat (2000) @(posedge clk);
      cyc += 2000;
      drain_console();
      if (cyc % 1_000_000 == 0) $display("\n[tb_boot] %0d M cycles, %0d instructions retired", cyc / 1_000_000, instret);
      hr(16'h018, v);
      if (v[31]) begin
        $display("\ntb_boot: power request %h", v[15:0]);
        break;
      end
    end
    drain_console();
    $display("\n[tb_boot] %0d cycles, %0d instructions retired", cyc, instret);
    if (console_has(expect_s)) $display("TEST PASSED (boot, %0d core(s))", N_CORES);
    else                       $display("TEST FAILED (boot, %0d core(s)): \"%s\" not seen", N_CORES, expect_s);
    $finish;
  end
endmodule
