// Host bridge test (docs/spec/host.md §Verification). The host drives AXI4 (bursts) through
// tg_axi4_to_axil into tg_host_bridge on clk_host, unrelated to the core clock. Checks register
// reset values and access, 64-bit commits, the configuration and status crossings, reset levels,
// POWER/TOHOST/DOORBELL/MBOX events both ways, console streams both ways (drop and lossless),
// and host interrupt masking. TRACE = 0 (make ... COMMIT_TRACE=0) checks the bridge built without the trace
// stream (DR-146): the capability bit clear, the trace registers ignoring writes. VIRTIO = 1 (make ...
// VIRTIO=1) adds the forwarded virtio window (docs/spec/soc.md §8.1): accesses answered locally while the
// host doesn't serve it, random accesses served by a host model with random delays (posted writes in
// order, reads waiting for the host's value), a full queue holding the device bus, the status bits,
// InterruptStatus and InterruptACK, 64-bit accesses denied, and the uncore reset emptying the queue.
// HDMA = 1 (make ... HDMA=1) adds the host DMA port's registers: completions recorded only while
// HDMA_CTRL says so, read in order through HDMA_CPL0/1 while a producer pushes them with gaps, a full
// queue holding the producer, the line counters, the uncore reset emptying the queue.
module tb_host_bridge #(parameter bit TRACE = 1'b1, parameter bit VIRTIO = 1'b0, parameter bit HDMA = 1'b0);
  import tg_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;

  logic clk = 1'b0, clk_host = 1'b0, rst = 1'b1, rst_host = 1'b1;
  always #5    clk      = ~clk;
  always #6.85 clk_host = ~clk_host;

  // AXI4 host side
  logic [15:0] awid, arid, bid, rid;
  logic [39:0] awaddr, araddr;
  logic [7:0]  awlen, arlen;
  logic        awvalid, awready, wvalid, wready, wlast, bvalid, bready, arvalid, arready, rvalid, rready, rlast;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  // AXI4-Lite between converter and bridge
  logic [15:0] l_awaddr, l_araddr;
  logic        l_awvalid, l_awready, l_wvalid, l_wready, l_bvalid, l_bready, l_arvalid, l_arready, l_rvalid, l_rready;
  logic [31:0] l_wdata, l_rdata;
  logic [3:0]  l_wstrb;
  logic [1:0]  l_bresp, l_rresp;

  tg_axi4_to_axil #(.ID_W (16), .ADDR_W (40), .LA_W (16)) u_conv (
    .clk (clk_host), .rst (rst_host),
    .s_awid (awid), .s_awaddr (awaddr), .s_awlen (awlen), .s_awvalid (awvalid), .s_awready (awready),
    .s_wdata (wdata), .s_wstrb (wstrb), .s_wlast (wlast), .s_wvalid (wvalid), .s_wready (wready),
    .s_bid (bid), .s_bresp (bresp), .s_bvalid (bvalid), .s_bready (bready),
    .s_arid (arid), .s_araddr (araddr), .s_arlen (arlen), .s_arvalid (arvalid), .s_arready (arready),
    .s_rid (rid), .s_rdata (rdata), .s_rresp (rresp), .s_rlast (rlast), .s_rvalid (rvalid), .s_rready (rready),
    .m_awaddr (l_awaddr), .m_awvalid (l_awvalid), .m_awready (l_awready),
    .m_wdata (l_wdata), .m_wstrb (l_wstrb), .m_wvalid (l_wvalid), .m_wready (l_wready),
    .m_bresp (l_bresp), .m_bvalid (l_bvalid), .m_bready (l_bready),
    .m_araddr (l_araddr), .m_arvalid (l_arvalid), .m_arready (l_arready),
    .m_rdata (l_rdata), .m_rresp (l_rresp), .m_rvalid (l_rvalid), .m_rready (l_rready)
  );

  // core side
  logic core_rst, uncore_rst, mbox_irq, host_irq;
  dev_req_t req; logic req_v; dev_rsp_t rsp;
  logic vreq_v, vwait; dev_rsp_t vrsp; logic [VIO_SLOTS-1:0] virq;     // the virtio window
  logic cpl_en, cpl_v = 1'b0, cpl_r; logic [57:0] cpl = '0;              // the host DMA port's completions
  logic [39:0] dbase, dsize;
  // trace-stream configuration and status
  logic        trs_en, trs_wrap, trs_stop_arm, trs_start_arm;
  logic [63:0] trs_stop_pc, trs_start_pc, trs_rp;
  logic [15:0] trs_post;
  logic [39:0] trs_base;
  logic [4:0]  trs_size;
  logic [9:0]  ird, iwr;
  logic        imode;
  logic [8:0]  ibw;
  logic        tg_en;
  logic [27:0] tg_base;
  logic [23:0] tg_lines;
  logic        ctx_v, ctx_r, crx_v, crx_r;
  logic [7:0]  ctx_b, crx_b;

  tg_host_bridge #(.CLK_HZ (100_000_000), .CFG_CODE (8'd1), .N_CORES_SOC (2), .CORE_RST_INIT (1'b1),
                   .UNCORE_RST_INIT (1'b1), .TRACE (TRACE), .VIRTIO (VIRTIO), .HDMA (HDMA)) dut (
    .clk_host, .rst_host,
    .s_awaddr (l_awaddr), .s_awvalid (l_awvalid), .s_awready (l_awready),
    .s_wdata (l_wdata), .s_wstrb (l_wstrb), .s_wvalid (l_wvalid), .s_wready (l_wready),
    .s_bresp (l_bresp), .s_bvalid (l_bvalid), .s_bready (l_bready),
    .s_araddr (l_araddr), .s_arvalid (l_arvalid), .s_arready (l_arready),
    .s_rdata (l_rdata), .s_rresp (l_rresp), .s_rvalid (l_rvalid), .s_rready (l_rready),
    .host_irq_o (host_irq),
    .clk, .rst, .core_rst_o (core_rst), .uncore_rst_o (uncore_rst),
    .req_i (req), .req_valid_i (req_v), .rsp_o (rsp),
    .vio_req_valid_i (vreq_v), .vio_rsp_o (vrsp), .vio_wait_o (vwait), .vio_irq_o (virq),
    .mbox_irq_o (mbox_irq),
    .dram_base_o (dbase), .dram_size_o (dsize),
    .inj_rd_delay_o (ird), .inj_wr_delay_o (iwr), .inj_mode_o (imode), .inj_bw_o (ibw),
    .l2_init_done_i (1'b1), .inj_rd_count_i (32'd1234), .inj_lat_sum_i (32'd56789), .inj_lat_max_i (16'd77),
    .tg_en_o (tg_en), .tg_base_o (tg_base), .tg_lines_o (tg_lines),
    .tg_ops_i (32'd42), .tg_errs_i (16'd0), .tg_err_line_i (28'd0), .tg_pass_i (16'd3),
    .trs_enable_o (trs_en), .trs_wrap_o (trs_wrap), .trs_stop_arm_o (trs_stop_arm), .trs_stop_pc_o (trs_stop_pc),
    .trs_post_o (trs_post), .trs_start_arm_o (trs_start_arm), .trs_start_pc_o (trs_start_pc),
    .trs_base_o (trs_base), .trs_size_log2_o (trs_size), .trs_rp_o (trs_rp),
    .trs_wp_i (64'h0000_0001_2345_6789), .trs_flags_i (5'b01011), .trs_buffered_i (16'd17), .trs_stalls_i (32'd999),
    .dbg_sel_o (), .dbg_val_i (32'h0),
    .hdma_cpl_en_o (cpl_en), .hdma_cpl_valid_i (cpl_v), .hdma_cpl_i (cpl), .hdma_cpl_ready_o (cpl_r),
    .hdma_rd_lines_i (32'd4321), .hdma_wr_lines_i (32'd8765), .hdma_wr_drops_i (32'd31),
    .con_tx_valid_i (ctx_v), .con_tx_ready_o (ctx_r), .con_tx_byte_i (ctx_b),
    .con_rx_valid_o (crx_v), .con_rx_ready_i (crx_r), .con_rx_byte_o (crx_b)
  );

  // Port signatures, one per clock domain: every DUT output every cycle (read data only while
  // valid). The same signatures mean the same behaviour at the ports, cycle by cycle (the cycle-
  // identity check for rewrites, docs/perf/fpga_friendly.md).
  logic [63:0] hsig = 64'hcbf2_9ce4_8422_2325, csig = 64'hcbf2_9ce4_8422_2325;
  function automatic logic [63:0] fnv(input logic [63:0] h, input logic [255:0] x);
    for (int b = 0; b < 32; b++) h = (h ^ 64'(x[8*b +: 8])) * 64'h0000_0100_0000_01b3;
    return h;
  endfunction
  always @(posedge clk_host) if (!rst_host)
    hsig <= fnv(hsig, 256'({l_awready, l_wready, l_bvalid, l_bresp, l_arready, l_rvalid, l_rresp, host_irq,
                            l_rvalid ? l_rdata : 32'd0}));
  always @(posedge clk) if (!rst) begin
    logic [63:0] h;
    h = fnv(csig, 256'({core_rst, uncore_rst, mbox_irq, ctx_r, crx_v, crx_v ? crx_b : 8'd0, dbase, dsize, ird, iwr, imode, ibw}));
    h = fnv(h, 256'({tg_en, tg_base, tg_lines, trs_en, trs_wrap, trs_stop_arm, trs_start_arm, trs_post, trs_size, trs_base}));
    h = fnv(h, 256'({trs_stop_pc, trs_start_pc, trs_rp}));
    h = fnv(h, 256'(rsp));
    if (VIRTIO) h = fnv(h, 256'({vwait, virq, vrsp}));
    if (HDMA) h = fnv(h, 256'({cpl_en, cpl_r}));
    csig <= h;
  end

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("[%0t] ERROR: %s", $time, m);
  endtask

  // ---- AXI4 host transactions (bursts of `n` words at consecutive addresses) ----
  task automatic aw4(input logic [15:0] a, input logic [31:0] d [], input int n);
    @(negedge clk_host);
    awid = 16'h00A5; awaddr = 40'h00A0000000 | 40'(a); awlen = 8'(n - 1); awvalid = 1;
    do @(posedge clk_host); while (!awready);
    @(negedge clk_host) awvalid = 0;
    for (int i = 0; i < n; i++) begin
      wdata = d[i]; wstrb = 4'hF; wlast = (i == n - 1); wvalid = 1;
      do @(posedge clk_host); while (!wready);
      @(negedge clk_host);
    end
    wvalid = 0; bready = 1;
    do @(posedge clk_host); while (!bvalid);
    if (bid != 16'h00A5 || bresp != 2'b00) fail("B id/resp");
    @(negedge clk_host) bready = 0;
  endtask
  task automatic ar4(input logic [15:0] a, output logic [31:0] d [], input int n);
    d = new[n];
    @(negedge clk_host);
    arid = 16'h005A; araddr = 40'h00A0000000 | 40'(a); arlen = 8'(n - 1); arvalid = 1;
    do @(posedge clk_host); while (!arready);
    @(negedge clk_host) arvalid = 0;
    rready = 1;
    for (int i = 0; i < n; i++) begin
      do @(posedge clk_host); while (!rvalid);
      d[i] = rdata;
      if (rid != 16'h005A) fail("R id");
      if (rlast != (i == n - 1)) fail("RLAST");
    end
    @(negedge clk_host) rready = 0;
  endtask
  task automatic hw(input logic [15:0] a, input logic [31:0] v);
    logic [31:0] d [];
    d = new[1];
    d[0] = v;
    aw4(a, d, 1);
  endtask
  task automatic hr(input logic [15:0] a, output logic [31:0] v);
    logic [31:0] d [];
    ar4(a, d, 1);
    v = d[0];
  endtask
  task automatic expect_h(input logic [15:0] a, input logic [31:0] want, input string what);
    logic [31:0] v;
    hr(a, v);
    if (v != want) fail($sformatf("%s: %h, want %h", what, v, want));
  endtask

  // ---- core-side device bus ----
  task automatic cacc(input logic [11:0] off, input bit we, input logic [63:0] wd, input logic [7:0] be,
                      output logic [63:0] rd);
    @(negedge clk);
    req = '0;
    req.addr = HOSTCTL_BASE + PA_W'(off);
    req.we = we; req.wdata = wd; req.be = be; req.size = 2'd3;
    req_v = 1;
    @(negedge clk);
    req_v = 0;
    @(posedge clk);
    rd = rsp.rdata;
  endtask

  // ---- core-side access to the virtio window: the device bus's protocol, the response taken in the
  // first cycle without wait (tg_tl_dev); `cycles` counts from the cycle after the request ----
  task automatic vacc(input logic [1:0] slot, input logic [11:0] off, input logic [1:0] size, input bit we,
                      input logic [31:0] val, output logic [63:0] rd, output bit err, output int cycles);
    @(negedge clk);
    req = '0;
    req.addr  = VIRTIO_BASE + PA_W'({slot, off});
    req.we    = we;
    req.size  = size;
    req.wdata = 64'(val) << (8 * off[2:0]);
    req.be    = 8'(((1 << (1 << size)) - 1) << off[2:0]);
    vreq_v = 1;
    @(negedge clk);
    vreq_v = 0;
    cycles = 1;
    forever begin
      @(posedge clk);
      if (!vwait) break;
      cycles++;
    end
    rd  = vrsp.rdata;
    err = vrsp.err;
  endtask

  function automatic logic [31:0] szmask(input logic [1:0] size);
    return (size == 2'd2) ? 32'hFFFF_FFFF : (size == 2'd1) ? 32'h0000_FFFF : 32'h0000_00FF;
  endfunction

  typedef struct { logic [1:0] slot; logic [11:0] off; logic [1:0] size; bit we; logic [31:0] val; } vacc_t;

  task automatic test_virtio();
    vacc_t       acc [];
    logic [63:0] rd;
    logic [31:0] v;
    bit          err;
    int          cyc;
    int unsigned seed;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));                                   // after the signatures: SEED= varies only this part
    expect_h(16'h1100, 32'h0, "VQ_CTRL at reset");
    // not served (EN = 0): answered here at once, nothing queued
    vacc(2'd0, 12'h000, 2'd2, 0, 32'd0, rd, err, cyc);
    if (rd != 0 || err || cyc != 1) fail($sformatf("window off: MagicValue %h err %0d in %0d cycles", rd, err, cyc));
    vacc(2'd1, 12'h070, 2'd2, 1, 32'h1, rd, err, cyc);
    if (err || cyc != 1) fail("window off: a write");
    repeat (40) @(posedge clk);
    hr(16'h1104, v);
    if (v[4:0] != 0) fail("window off: an access was queued");
    hw(16'h1100, 32'h1);
    expect_h(16'h1100, 32'h1, "VQ_CTRL");
    repeat (60) @(posedge clk);

    // a full queue holds the device bus: 24 posted writes while the host waits, then drains in order
    fork
      begin
        for (int i = 0; i < 24; i++) begin
          vacc(2'd3, 12'h050, 2'd2, 1, 32'(i), rd, err, cyc);
          if (err) fail("QueueNotify denied");
          if (i < 16 && cyc > 4) fail($sformatf("write %0d waited %0d cycles with room in the queue", i, cyc));
          if (i == 16 && cyc < 1000) fail($sformatf("write %0d waited only %0d cycles for a full queue", i, cyc));
        end
      end
      begin
        repeat (4000) @(posedge clk_host);
        hr(16'h1104, v);
        if (v[4:0] != 5'd16) fail($sformatf("VQ_STATUS %h with a full queue", v));
        for (int i = 0; i < 24; i++) begin
          do hr(16'h1108, v); while (!v[31]);
          if (v != {1'b1, 12'd0, 1'b1, 2'd2, 2'd0, 2'd3, 12'h050}) fail($sformatf("VQ_REQ0 %h", v));
          hr(16'h110C, v);
          if (v != 32'(i)) fail($sformatf("posted write %0d arrived as %0d", i, v));
        end
      end
    join

    // random accesses, the host serving them with random delays; reads wait for its value
    acc = new[400];
    foreach (acc[i]) begin
      acc[i].size = 2'($urandom_range(2));
      do acc[i].off = 12'($urandom_range(4095)) & ~12'((1 << acc[i].size) - 1);
      while (acc[i].off[11:3] == 9'h00C);                  // InterruptStatus and InterruptACK are local
      acc[i].slot = 2'($urandom_range(3));
      acc[i].we   = 1'($urandom_range(1));
      acc[i].val  = $urandom & szmask(acc[i].size);
    end
    acc[200].we = 1'b0;                                      // a read the host leaves waiting for 100K cycles
    hw(16'h084, 32'h10);                                     // the host interrupt for queued requests only
    fork
      begin
        foreach (acc[i]) begin
          vacc(acc[i].slot, acc[i].off, acc[i].size, acc[i].we, acc[i].we ? acc[i].val : 32'd0, rd, err, cyc);
          if (err) fail($sformatf("virtio access %0d denied", i));
          if (!acc[i].we && ((32'(rd >> (8 * acc[i].off[2:0]))) & szmask(acc[i].size)) != acc[i].val)
            fail($sformatf("virtio read %0d (slot %0d off %h size %0d): %h, want %h", i, acc[i].slot, acc[i].off,
                           acc[i].size, rd, acc[i].val));
          repeat ($urandom_range(3)) @(posedge clk);
        end
      end
      begin
        foreach (acc[i]) begin
          do hr(16'h1108, v); while (!v[31]);
          if (!host_irq) fail("no host interrupt with a request queued");
          if (v[11:0] != acc[i].off || v[13:12] != acc[i].slot || v[17:16] != acc[i].size || v[18] != acc[i].we ||
              v[30:19] != 0 || v[15:14] != 0)
            fail($sformatf("VQ_REQ0 %h for access %0d (slot %0d off %h size %0d we %0d)", v, i, acc[i].slot,
                           acc[i].off, acc[i].size, acc[i].we));
          hr(16'h110C, v);
          if (v != (acc[i].we ? acc[i].val : 32'd0)) fail($sformatf("VQ_REQ1 %h for access %0d", v, i));
          if (!acc[i].we) begin
            repeat (i == 200 ? 100_000 : $urandom_range(300)) @(posedge clk_host);
            hw(16'h1110, acc[i].val);
          end
        end
      end
    join
    hr(16'h1108, v);
    if (v[31]) fail("an access left in the queue");
    if (host_irq) fail("host interrupt with the queue empty");
    $display("virtio window: %0d accesses served in order", acc.size());

    // status bits: the host sets and clears them, the driver reads InterruptStatus and acknowledges
    hw(16'h1114, 32'h0000_0010);                             // slot 2, used buffer
    repeat (40) @(posedge clk);
    if (virq != 4'b0100) fail($sformatf("VQ_IRQ set: %b", virq));
    vacc(2'd2, 12'h060, 2'd2, 0, 32'd0, rd, err, cyc);
    if (rd[31:0] != 32'h1 || err || cyc != 1) fail($sformatf("InterruptStatus %h in %0d cycles", rd, cyc));
    vacc(2'd2, 12'h064, 2'd2, 1, 32'h1, rd, err, cyc);
    if (virq != 4'b0000 || cyc != 1) fail("InterruptACK");
    hw(16'h1114, 32'h0000_0082);                             // slot 0 and slot 3, configuration change
    repeat (40) @(posedge clk);
    if (virq != 4'b1001) fail($sformatf("VQ_IRQ set two: %b", virq));
    hr(16'h1104, v);
    if (v[31:24] != 8'h82 || v[16]) fail($sformatf("VQ_STATUS %h", v));
    vacc(2'd3, 12'h060, 2'd0, 0, 32'd0, rd, err, cyc);       // a byte read
    if (rd[7:0] != 8'h2) fail($sformatf("InterruptStatus byte %h", rd));
    vacc(2'd3, 12'h061, 2'd0, 0, 32'd0, rd, err, cyc);       // the register's second byte
    if (rd[15:8] != 8'h0) fail($sformatf("InterruptStatus second byte %h", rd));
    hw(16'h1114, 32'h0000_8000);                             // the host clears slot 3's
    repeat (40) @(posedge clk);
    if (virq != 4'b0001) fail($sformatf("VQ_IRQ clear: %b", virq));
    vacc(2'd0, 12'h064, 2'd2, 1, 32'h2, rd, err, cyc);
    if (virq != 4'b0000) fail("InterruptACK of slot 0");
    vacc(2'd1, 12'h100, 2'd3, 0, 32'd0, rd, err, cyc);       // 64-bit: denied
    if (!err) fail("a 64-bit access not denied");
    repeat (40) @(posedge clk);
    hr(16'h1104, v);
    if (v[4:0] != 0) fail("a local or denied access was queued");

    // the uncore reset empties the queue
    for (int i = 0; i < 3; i++) vacc(2'd1, 12'h050, 2'd2, 1, 32'(i), rd, err, cyc);
    repeat (60) @(posedge clk);
    hr(16'h1104, v);
    if (v[4:0] != 3) fail($sformatf("VQ_STATUS %h with 3 queued", v));
    hw(16'h010, 32'h2);
    repeat (40) @(posedge clk);
    hw(16'h010, 32'h0);
    repeat (80) @(posedge clk);
    hr(16'h1104, v);
    if (v[4:0] != 0 || v[12:8] != 0) fail($sformatf("VQ_STATUS %h after the uncore reset", v));
    expect_h(16'h1100, 32'h1, "VQ_CTRL after the uncore reset");
    $display("virtio window: ok");
  endtask

  // ---- the host DMA port's completions (HDMA) ----
  task automatic test_hdma();
    logic [31:0] v, v1;
    int unsigned seed;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    expect_h(16'h1300, 32'h0, "HDMA_CTRL at reset");
    expect_h(16'h1308, 32'd4321, "HDMA_RD_LINES");
    expect_h(16'h130C, 32'd8765, "HDMA_WR_LINES");
    expect_h(16'h1318, 32'd31, "HDMA_WR_DROPS");
    if (cpl_en) fail("completions recorded at reset");
    hw(16'h1300, 32'h1);
    expect_h(16'h1300, 32'h1, "HDMA_CTRL");
    repeat (60) @(posedge clk);
    if (!cpl_en) fail("HDMA_CTRL did not reach the core side");
    // 200 completions pushed with gaps and a full queue while the host pauses, read back in order
    fork
      for (int i = 0; i < 200; i++) begin
        @(negedge clk);
        cpl = {26'(i * 7 + 1), 32'(i * 1000 + 5)};
        cpl_v = 1;
        do @(posedge clk); while (!cpl_r);
        @(negedge clk) cpl_v = 0;
        repeat ($urandom_range(5)) @(negedge clk);
      end
      begin
        repeat (3000) @(posedge clk_host);                   // the queue fills; the producer waits
        hr(16'h1304, v);
        if (v != 32'd16) fail($sformatf("HDMA_STATUS %0d with a full queue", v));
        for (int i = 0; i < 200; i++) begin
          do hr(16'h1310, v); while (!v[31]);
          hr(16'h1314, v1);
          if (v != {1'b1, 5'd0, 26'(i * 7 + 1)} || v1 != 32'(i * 1000 + 5))
            fail($sformatf("completion %0d: %h %h", i, v, v1));
        end
      end
    join
    hr(16'h1310, v);
    if (v[31]) fail("a completion left over");
    // the uncore reset empties the queue
    for (int i = 0; i < 3; i++) begin
      @(negedge clk); cpl = 58'(i); cpl_v = 1;
      do @(posedge clk); while (!cpl_r);
      @(negedge clk) cpl_v = 0;
    end
    repeat (60) @(posedge clk);
    expect_h(16'h1304, 32'd3, "HDMA_STATUS with 3 queued");
    hw(16'h010, 32'h2);
    repeat (40) @(posedge clk);
    hw(16'h010, 32'h0);
    repeat (80) @(posedge clk);
    expect_h(16'h1304, 32'd0, "HDMA_STATUS after the uncore reset");
    hw(16'h1300, 32'h0);
    repeat (60) @(posedge clk);
    if (cpl_en) fail("HDMA_CTRL clear did not reach the core side");
    $display("host DMA completions: ok");
  endtask

  // ---- console endpoints ----
  logic [7:0] tx_sent[$], rx_got[$];
  bit         tx_push;
  always @(posedge clk) begin
    if (ctx_v && ctx_r) begin
      tx_sent.push_back(ctx_b);
    end
    if (crx_v && crx_r) rx_got.push_back(crx_b);
    crx_r <= ($urandom_range(99) < 80);
  end

  initial begin
    logic [31:0] v;
    logic [63:0] q;
    logic [31:0] d [];
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0; req_v = 0; vreq_v = 0; ctx_v = 0; ctx_b = 0;
    repeat (8) @(posedge clk);
    rst = 0; rst_host = 0;
    repeat (8) @(posedge clk);

    // ---- reset values ----
    expect_h(16'h000, 32'h5447_4E52, "ID");
    hr(16'h004, v);
    if (v[7:0] != 8'd1 || v[15:12] != 4'd2) fail($sformatf("VERSION %h", v));
    expect_h(16'h008, 32'd100_000_000, "CLK_HZ");
    expect_h(16'h00C, {23'd0, HDMA, 4'(N_BANKS), TRACE, VIRTIO, 2'b11}, "CAPS");
    expect_h(16'h010, 32'h3, "CTRL");
    expect_h(16'h030, 32'h8000_0000, "BOOT_ENTRY lo");
    expect_h(16'h038, 32'h8220_0000, "DTB_ADDR lo");
    if (!core_rst || !uncore_rst) fail("resets not held at power-up");

    // ---- bursts through the converter: 4 words at 0x020 ----
    d = new[4];
    d[0] = 32'h4000_0000; d[1] = 32'h0000_0008; d[2] = 32'h1000_0000; d[3] = 32'h0000_0000;
    aw4(16'h020, d, 4);                               // DRAM_BASE lo/hi, DRAM_SIZE lo/hi
    ar4(16'h020, d, 4);
    if (d[0] != 32'h4000_0000 || d[1] != 32'h8 || d[2] != 32'h1000_0000 || d[3] != 0) fail("burst readback");
    repeat (60) @(posedge clk);
    if (dbase != 40'h8_4000_0000 || dsize != 40'h1000_0000) fail($sformatf("window crossing: %h %h", dbase, dsize));

    // ---- 64-bit commit: a low half alone does not reach the core side ----
    hw(16'h030, 32'h8100_0000);                       // BOOT_ENTRY lo only
    repeat (60) @(posedge clk);
    cacc(12'h008, 0, '0, '0, q);
    if (q != 64'h8000_0000) fail($sformatf("BOOT_ENTRY changed before its high half: %h", q));
    hw(16'h034, 32'h0);
    repeat (60) @(posedge clk);
    cacc(12'h008, 0, '0, '0, q);
    if (q != 64'h8100_0000) fail($sformatf("BOOT_ENTRY after commit: %h", q));
    cacc(12'h000, 0, '0, '0, q);
    if (q != 64'h4C54_4348_5254_4E47) fail("HOSTCTL ID");

    // ---- injector and traffic-generator configuration ----
    hw(16'h040, 32'd250); hw(16'h044, 32'd120); hw(16'h048, 32'h0040_0001);
    hw(16'h0C0, 32'h1); hw(16'h0C4, 32'h0200_0040); hw(16'h0C8, 32'd2048);
    repeat (60) @(posedge clk);
    if (ird != 250 || iwr != 120 || !imode || ibw != 9'h40) fail("injector configuration crossing");
    if (!tg_en || tg_base != 28'h200_0040 || tg_lines != 24'd2048) fail("traffic-generator configuration crossing");
    expect_h(16'h050, 32'd1234, "INJ_RD_COUNT");
    expect_h(16'h054, 32'd56789, "INJ_RD_LATSUM");
    expect_h(16'h058, 32'd77, "INJ_RD_LATMAX");
    expect_h(16'h0D0, 32'd42, "TG_OPS");
    expect_h(16'h0DC, 32'd3, "TG_PASS");

    // ---- trace-stream registers (docs/spec/uncore-trace.md): 64-bit commits, both crossings ----
    hw(16'h1020, 32'h4100_0000); hw(16'h1024, 32'h8);       // TRS_BASE
    hw(16'h1028, 32'd22);                                    // TRS_SIZE_LOG2
    hw(16'h1008, 32'h8000_1234); hw(16'h100C, 32'h0);        // TRS_TRIG_PC
    hw(16'h1010, 32'd100);                                   // TRS_POST
    hw(16'h1018, 32'h8000_0100); hw(16'h101C, 32'h0);        // TRS_START_PC
    hw(16'h1030, 32'h0000_0400); hw(16'h1034, 32'h1);        // TRS_RP
    hw(16'h1000, 32'h303);                                   // enable, wrap, both triggers
    repeat (60) @(posedge clk);
    if (TRACE) begin
      if (!trs_en || !trs_wrap || !trs_stop_arm || !trs_start_arm) fail("TRS_CTRL crossing");
      if (trs_base != 40'h8_4100_0000 || trs_size != 5'd22) fail("TRS_BASE / TRS_SIZE_LOG2 crossing");
      if (trs_stop_pc != 64'h8000_1234 || trs_post != 16'd100 || trs_start_pc != 64'h8000_0100) fail("trigger crossing");
      if (trs_rp != 64'h1_0000_0400) fail("TRS_RP crossing");
      expect_h(16'h1000, 32'h303, "TRS_CTRL");
      expect_h(16'h1034, 32'h1, "TRS_RP high");
    end else begin
      // no trace stream: the registers keep 0 and nothing crosses
      if (trs_en || trs_wrap || trs_stop_arm || trs_start_arm || trs_base != '0 || trs_size != '0 ||
          trs_stop_pc != '0 || trs_post != '0 || trs_start_pc != '0 || trs_rp != '0)
        fail("trace registers written in a bridge without the trace");
      expect_h(16'h1000, 32'h0, "TRS_CTRL without the trace");
      expect_h(16'h1034, 32'h0, "TRS_RP high without the trace");
    end
    expect_h(16'h1038, 32'h2345_6789, "TRS_WP low");
    expect_h(16'h103C, 32'h1, "TRS_WP high");
    expect_h(16'h1040, {16'd17, 11'd0, 5'b01011}, "TRS_STATUS");
    expect_h(16'h1044, 32'd999, "TRS_STALLS");
    expect_h(16'h1048, 32'h0000_0240, "TRS_INFO");
    hw(16'h1000, 32'h0);

    // ---- resets ----
    hw(16'h010, 32'h1);
    repeat (20) @(posedge clk);
    if (uncore_rst || !core_rst) fail("uncore release");
    for (int k = 0; k < 50; k++) begin              // the status mirror lags a few dozen cycles
      hr(16'h014, v);
      if (!v[1]) break;
    end
    if (v[1] || !v[0] || !v[2]) fail($sformatf("STATUS after uncore release %h", v));
    hw(16'h010, 32'h0);
    repeat (20) @(posedge clk);
    if (core_rst) fail("core release");

    // ---- RISC-V -> host events ----
    hw(16'h084, 32'hF);                               // enable every host interrupt
    cacc(12'h028, 1, 64'hDEAD_BEEF_0000_0001, 8'hFF, q);   // TOHOST
    repeat (40) @(posedge clk);
    hr(16'h060, v); if (v != 32'h0000_0001) fail("TOHOST lo");
    hr(16'h064, v); if (v != 32'hDEAD_BEEF) fail("TOHOST hi");
    expect_h(16'h088, 32'd1, "TOHOST_SEQ");
    hr(16'h080, v); if (!v[3]) fail("IRQ_STATUS tohost");
    if (!host_irq) fail("host_irq for tohost");
    hw(16'h080, 32'h8);                               // clear
    cacc(12'h020, 1, 64'h5555, 8'h0F, q);             // POWER off request
    repeat (40) @(posedge clk);
    hr(16'h018, v); if (v != 32'h8000_5555) fail($sformatf("POWER %h", v));
    hw(16'h018, 32'h8000_0000);
    hr(16'h018, v); if (v[31]) fail("POWER W1C");
    cacc(12'h038, 1, 64'h1, 8'hFF, q);                // DOORBELL
    repeat (40) @(posedge clk);
    expect_h(16'h070, 32'h1, "MBOX_IN");
    hw(16'h070, 32'h1);
    expect_h(16'h070, 32'h0, "MBOX_IN W1C");

    // ---- host -> RISC-V mailbox ----
    hw(16'h074, 32'h1);
    repeat (40) @(posedge clk);
    if (!mbox_irq) fail("mbox irq");
    cacc(12'h040, 0, '0, '0, q); if (q != 64'h1) fail("MBOX_PENDING read");
    cacc(12'h040, 1, 64'h1, 8'h01, q);
    if (mbox_irq) fail("MBOX_PENDING W1C");
    hw(16'h068, 32'h1111_2222); hw(16'h06C, 32'h3333_4444);
    repeat (60) @(posedge clk);
    cacc(12'h030, 0, '0, '0, q); if (q != 64'h3333_4444_1111_2222) fail("FROMHOST");

    // ---- console RISC-V -> host, lossless: a producer and the host drain run together ----
    hw(16'h080, 32'h0); hw(16'h084, 32'h1);           // only the console interrupt
    hw(16'h010, 32'h4);                               // lossless
    repeat (40) @(posedge clk);
    begin
      logic [7:0] got[$];
      fork
        begin
          for (int i = 0; i < 3000; i++) begin
            @(negedge clk);
            ctx_b = 8'(i * 7 + 3);
            ctx_v = 1;
            do @(posedge clk); while (!ctx_r);
          end
          @(negedge clk) ctx_v = 0;
        end
        begin
          repeat (3000) @(posedge clk);               // let the FIFO fill past 2048 first
          if (!host_irq) fail("console interrupt with bytes waiting");
          hr(16'h104, v);
          if (v < 2040) fail($sformatf("UART_TX_LEVEL %0d with the producer stalled", v));
          while (got.size() < 3000) begin
            hr(16'h100, v);
            if (v[8]) got.push_back(v[7:0]);
          end
        end
      join
      foreach (got[i]) if (got[i] != 8'(i * 7 + 3)) begin fail($sformatf("console byte %0d", i)); break; end
      $display("console lossless: %0d bytes in order", got.size());
    end

    // ---- console RISC-V -> host, drop mode: the producer never stalls ----
    hw(16'h010, 32'h0);
    repeat (40) @(posedge clk);
    for (int i = 0; i < 2500; i++) begin
      @(negedge clk);
      ctx_b = 8'(i);
      ctx_v = 1;
      @(posedge clk);
      if (!ctx_r) fail("drop mode stalled the UART");
    end
    @(negedge clk) ctx_v = 0;
    begin
      int n;
      n = 0;
      do begin
        hr(16'h100, v);
        if (v[8]) begin
          if (v[7:0] != 8'(n)) begin fail("drop mode kept the wrong bytes"); break; end
          n++;
        end
      end while (v[8]);
      if (n != 2048) fail($sformatf("drop mode kept %0d bytes, want 2048", n));
      $display("console drop mode: kept %0d of 2500", n);
    end

    // ---- console host -> RISC-V ----
    expect_h(16'h10C, 32'd512, "UART_RX_SPACE empty");
    for (int i = 0; i < 700; i++) begin
      do hr(16'h10C, v); while (v == 0);
      hw(16'h108, 32'(8'(i * 5)));
    end
    repeat (200) @(posedge clk);
    if (rx_got.size() != 700) fail($sformatf("console input: %0d of 700 bytes", rx_got.size()));
    foreach (rx_got[i]) if (rx_got[i] != 8'(i * 5)) begin fail($sformatf("console input byte %0d", i)); break; end
    $display("host_bridge: port signatures %016h (host) %016h (core)", hsig, csig);
    // after the signatures, which stay comparable with builds before the window
    if (HDMA) begin
      test_hdma();
    end else begin
      hw(16'h1300, 32'h1);                                   // no port: HDMA_CTRL ignores writes
      expect_h(16'h1300, 32'h0, "HDMA_CTRL without the port");
      expect_h(16'h1308, 32'h0, "HDMA_RD_LINES without the port");
    end
    if (VIRTIO) test_virtio();
    else begin
      hw(16'h1100, 32'h1);                                   // no window: VQ_CTRL ignores writes
      expect_h(16'h1100, 32'h0, "VQ_CTRL without the window");
      hw(16'h084, 32'h1F);
      expect_h(16'h084, 32'hF, "IRQ_EN bit 4 without the window");
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
endmodule
