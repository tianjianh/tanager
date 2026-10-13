// Simulation of the S1 PL logic (tg_s1_top) before it goes to the board: an AXI4-Lite
// master plays the A53 program, two AXI4 memory models (random latency, responses out of
// order across IDs) play the HP ports.
//   Vtb_s1 +seed=<n>
module tb_s1;
  localparam int AW = 49, DW = 128, IW = 6;
  logic clk = 0, rstn = 0;
  always #2.5 clk = ~clk;
  int errors = 0, seed = 1;

  // AXI-Lite
  logic [11:0] awaddr, araddr;
  logic awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata_l;
  logic [3:0] wstrb;
  logic [1:0] bresp, rresp_l;

  // Two AXI4 masters
  logic [1:0][IW-1:0] arid, rid, awid, bid;
  logic [1:0][AW-1:0] araddr_m, awaddr_m;
  logic [1:0][7:0] arlen, awlen;
  logic [1:0][2:0] arsize, awsize, arprot, awprot;
  logic [1:0][1:0] arburst, awburst, rresp, bresp_m;
  logic [1:0] arlock, awlock, arvalid_m, arready_m, rlast, rvalid_m, rready_m;
  logic [1:0] awvalid_m, awready_m, wlast, wvalid_m, wready_m, bvalid_m, bready_m;
  logic [1:0][3:0] arcache, awcache, arqos, awqos;
  logic [1:0][DW-1:0] rdata, wdata_m;
  logic [1:0][DW/8-1:0] wstrb_m;
  logic fan;

  tg_s1_top dut (
    .clk, .rstn, .fan_en_b(fan),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata_l), .s_axi_rresp(rresp_l), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .m0_axi_arid(arid[0]), .m0_axi_araddr(araddr_m[0]), .m0_axi_arlen(arlen[0]),
    .m0_axi_arsize(arsize[0]), .m0_axi_arburst(arburst[0]), .m0_axi_arlock(arlock[0]),
    .m0_axi_arcache(arcache[0]), .m0_axi_arprot(arprot[0]), .m0_axi_arqos(arqos[0]),
    .m0_axi_arvalid(arvalid_m[0]), .m0_axi_arready(arready_m[0]), .m0_axi_rid(rid[0]),
    .m0_axi_rdata(rdata[0]), .m0_axi_rresp(rresp[0]), .m0_axi_rlast(rlast[0]),
    .m0_axi_rvalid(rvalid_m[0]), .m0_axi_rready(rready_m[0]),
    .m0_axi_awid(awid[0]), .m0_axi_awaddr(awaddr_m[0]), .m0_axi_awlen(awlen[0]),
    .m0_axi_awsize(awsize[0]), .m0_axi_awburst(awburst[0]), .m0_axi_awlock(awlock[0]),
    .m0_axi_awcache(awcache[0]), .m0_axi_awprot(awprot[0]), .m0_axi_awqos(awqos[0]),
    .m0_axi_awvalid(awvalid_m[0]), .m0_axi_awready(awready_m[0]), .m0_axi_wdata(wdata_m[0]),
    .m0_axi_wstrb(wstrb_m[0]), .m0_axi_wlast(wlast[0]), .m0_axi_wvalid(wvalid_m[0]),
    .m0_axi_wready(wready_m[0]), .m0_axi_bid(bid[0]), .m0_axi_bresp(bresp_m[0]),
    .m0_axi_bvalid(bvalid_m[0]), .m0_axi_bready(bready_m[0]),
    .m1_axi_arid(arid[1]), .m1_axi_araddr(araddr_m[1]), .m1_axi_arlen(arlen[1]),
    .m1_axi_arsize(arsize[1]), .m1_axi_arburst(arburst[1]), .m1_axi_arlock(arlock[1]),
    .m1_axi_arcache(arcache[1]), .m1_axi_arprot(arprot[1]), .m1_axi_arqos(arqos[1]),
    .m1_axi_arvalid(arvalid_m[1]), .m1_axi_arready(arready_m[1]), .m1_axi_rid(rid[1]),
    .m1_axi_rdata(rdata[1]), .m1_axi_rresp(rresp[1]), .m1_axi_rlast(rlast[1]),
    .m1_axi_rvalid(rvalid_m[1]), .m1_axi_rready(rready_m[1]),
    .m1_axi_awid(awid[1]), .m1_axi_awaddr(awaddr_m[1]), .m1_axi_awlen(awlen[1]),
    .m1_axi_awsize(awsize[1]), .m1_axi_awburst(awburst[1]), .m1_axi_awlock(awlock[1]),
    .m1_axi_awcache(awcache[1]), .m1_axi_awprot(awprot[1]), .m1_axi_awqos(awqos[1]),
    .m1_axi_awvalid(awvalid_m[1]), .m1_axi_awready(awready_m[1]), .m1_axi_wdata(wdata_m[1]),
    .m1_axi_wstrb(wstrb_m[1]), .m1_axi_wlast(wlast[1]), .m1_axi_wvalid(wvalid_m[1]),
    .m1_axi_wready(wready_m[1]), .m1_axi_bid(bid[1]), .m1_axi_bresp(bresp_m[1]),
    .m1_axi_bvalid(bvalid_m[1]), .m1_axi_bready(bready_m[1]));

  // ---- AXI4 memory models: requests queue up, each gets a random latency; responses may
  // overtake each other across IDs. Memory: 64-bit words, sparse. ----
  logic [63:0] mem [logic [AW-1:0]];
  function automatic logic [63:0] mrd(input logic [AW-1:0] a);
    return mem.exists(a) ? mem[a] : {16'hc0de, a[47:0]};
  endfunction

  typedef struct { logic [IW-1:0] id; logic [AW-1:0] addr; int beats; int due; } req_t;
  for (genvar p = 0; p < 2; p++) begin : g_mem
    req_t rq [$];
    req_t wq [$];
    int cyc = 0, nbeat = 0, cur = -1, wbeats = 0;
    logic [AW-1:0] w_addr;
    int maxlat_seen = 0;
    assign arready_m[p] = rq.size() < 32;
    assign awready_m[p] = wq.size() < 32;
    assign wready_m[p]  = 1'b1;
    always @(posedge clk) begin
      cyc++;
      if (arvalid_m[p] && arready_m[p]) begin
        req_t r;
        r.id = arid[p]; r.addr = araddr_m[p]; r.beats = arlen[p] + 1;
        r.due = cyc + 20 + ($urandom % 30);
        rq.push_back(r);
      end
      if (awvalid_m[p] && awready_m[p]) begin
        req_t r;
        r.id = awid[p]; r.addr = awaddr_m[p]; r.beats = awlen[p] + 1; r.due = 0;
        wq.push_back(r);
      end
    end
    // read data: pick a due request (not always the oldest), stream its beats
    always @(posedge clk) begin
      if (rvalid_m[p] && rready_m[p]) begin
        nbeat++;
        if (rlast[p]) begin
          rq.delete(cur);
          cur = -1;
          nbeat = 0;
        end
      end
      if (cur < 0) begin
        for (int i = 0; i < rq.size(); i++)
          if (rq[i].due <= cyc && (cur < 0 || ($urandom % 2) == 0)) cur = i;
      end
      rvalid_m[p] <= 1'b0;
      if (cur >= 0) begin
        logic [AW-1:0] a;
        a = rq[cur].addr + AW'(nbeat * 16);
        rvalid_m[p] <= 1'b1;
        rid[p]   <= rq[cur].id;
        rdata[p] <= {mrd(a + 8), mrd(a)};
        rlast[p] <= nbeat == rq[cur].beats - 1;
        rresp[p] <= 2'b00;
      end
    end
    // writes: data beats go to the oldest address, the response comes a little later
    logic [IW-1:0] bq [$];
    always @(posedge clk) begin
      bvalid_m[p] <= 1'b0;
      if (wvalid_m[p] && wready_m[p]) begin
        if (wq.size() == 0) begin errors++; $display("ERROR port %0d: W before AW", p); end
        else begin
          mem[wq[0].addr + AW'(wbeats * 16)]     = wdata_m[p][63:0];
          mem[wq[0].addr + AW'(wbeats * 16 + 8)] = wdata_m[p][127:64];
          wbeats++;
          if (wlast[p] != (wbeats == wq[0].beats)) begin
            errors++; $display("ERROR port %0d: wlast at beat %0d of %0d", p, wbeats, wq[0].beats);
          end
          if (wlast[p]) begin
            bq.push_back(wq[0].id);
            wq.pop_front();
            wbeats = 0;
          end
        end
      end
      if (bq.size() > 0 && ($urandom % 3) == 0) begin
        bvalid_m[p] <= 1'b1;
        bid[p] <= bq.pop_front();
        bresp_m[p] <= 2'b00;
      end
    end
  end

  // ---- AXI-Lite master ----
  task automatic lw(input logic [11:0] a, input logic [31:0] d);
    @(negedge clk);
    awaddr = a; awvalid = 1; wdata = d; wstrb = 4'hf; wvalid = 1; bready = 1;
    do @(posedge clk); while (!awready);
    @(negedge clk);
    awvalid = 0; wvalid = 0;
    while (!bvalid) @(posedge clk);
    @(negedge clk);
  endtask
  task automatic lr(input logic [11:0] a, output logic [31:0] d);
    @(negedge clk);
    araddr = a; arvalid = 1; rready = 1;
    do @(posedge clk); while (!arready);
    @(negedge clk);
    arvalid = 0;
    while (!rvalid) @(posedge clk);
    d = rdata_l;
    @(negedge clk);
  endtask

  function automatic logic [11:0] reg_a(input int e, input int r);
    return 12'(e * 'h800 + r * 4);
  endfunction

  task automatic wait_idle(input int e);
    logic [31:0] st;
    do lr(reg_a(e, 2), st); while (st[0]);
  endtask
  task automatic run_job(input int e, input int mode, input int chase, input int beats,
                         input int outst, input int count, input logic [AW-1:0] base,
                         input int size, input int stride, input bit wait_end = 1);
    lw(reg_a(e, 1), (chase << 2) | (mode << 4));
    lw(reg_a(e, 3), beats - 1);
    lw(reg_a(e, 4), outst);
    lw(reg_a(e, 5), count);
    lw(reg_a(e, 6), base[31:0]);
    lw(reg_a(e, 7), 32'(base[AW-1:32]));
    lw(reg_a(e, 8), size);
    lw(reg_a(e, 9), stride);
    lw(reg_a(e, 11), 1);
    lw(reg_a(e, 1), (chase << 2) | (mode << 4) | 1);
    if (wait_end) wait_idle(e);
  endtask

  // Monitor the chase: every read address must be the node the previous read pointed to
  logic [AW-1:0] expect_next;
  bit chase_on = 0;
  always @(posedge clk) begin
    if (chase_on && arvalid_m[0] && arready_m[0]) begin
      if (araddr_m[0] != expect_next) begin
        errors++;
        if (errors < 10) $display("ERROR chase: read %h, expected %h", araddr_m[0], expect_next);
      end
      expect_next = mem[araddr_m[0]];
    end
  end

  initial begin
    logic [31:0] v, done, lmin, lmax, nerr, h;
    int hsum;
    void'($value$plusargs("seed=%d", seed));
    void'($urandom(seed));
    awvalid = 0; wvalid = 0; arvalid = 0; bready = 1; rready = 1;
    repeat (10) @(posedge clk);
    rstn = 1;
    repeat (10) @(posedge clk);
    for (int e = 0; e < 2; e++) begin
      lr(reg_a(e, 0), v);
      if (v != 32'h7153_0001) begin errors++; $display("ERROR engine %0d ID %h", e, v); end
    end
    // 1. pointer chase over 256 nodes of 64 B at 0x4000_0000
    begin
      int n = 256;
      int perm [256];
      logic [AW-1:0] base = 49'h4000_0000;
      for (int i = 0; i < n; i++) perm[i] = i;
      for (int i = n - 1; i > 0; i--) begin
        int k = $urandom % i;
        int t = perm[i]; perm[i] = perm[k]; perm[k] = t;
      end
      for (int i = 0; i < n; i++) mem[base + AW'(perm[i] * 64)] = 64'(base + AW'(perm[(i + 1) % n] * 64));
      expect_next = base + AW'(perm[0] * 64);
      chase_on = 1;
      run_job(0, 0, 1, 4, 1, 1000, base + AW'(perm[0] * 64), 'h4000, 64);
      chase_on = 0;
      lr(reg_a(0, 18), done); lr(reg_a(0, 14), lmin); lr(reg_a(0, 15), lmax); lr(reg_a(0, 21), nerr);
      $display("chase: done %0d min %0d max %0d errors %0d", done, lmin, lmax, nerr);
      if (done != 1000 || nerr != 0 || lmin < 20 || lmax > 60) begin
        errors++; $display("ERROR chase results");
      end
      hsum = 0;
      for (int i = 0; i < 256; i++) begin lr(reg_a(0, 256 + i), h); hsum += h; end
      if (hsum != 1000) begin errors++; $display("ERROR histogram sums to %0d", hsum); end
    end
    // 2. read bandwidth: 2000 bursts of 4 beats, 16 outstanding, on both engines at once
    begin
      logic [31:0] b0, b1, c0;
      run_job(0, 0, 0, 4, 16, 2000, 49'h1000_0000, 'h10000, 64, 0);
      run_job(1, 0, 0, 16, 32, 500, 49'h2000_0000, 'h10000, 256, 0);
      wait_idle(0);
      wait_idle(1);
      lr(reg_a(0, 19), b0); lr(reg_a(1, 19), b1); lr(reg_a(0, 12), c0);
      $display("bandwidth: engine0 %0d bytes in %0d cycles, engine1 %0d bytes", b0, c0, b1);
      if (b0 != 2000 * 64 || b1 != 500 * 256) begin errors++; $display("ERROR byte counts"); end
    end
    // 3. writes: 300 bursts of 4 beats, sequential from 0x3000_0000
    begin
      logic [31:0] d;
      run_job(0, 1, 0, 4, 8, 300, 49'h3000_0000, 'h10000, 64);
      lr(reg_a(0, 18), d); lr(reg_a(0, 21), nerr);
      if (d != 300 || nerr != 0) begin errors++; $display("ERROR writes: done %0d", d); end
      for (int i = 0; i < 300 * 8; i++)
        if (!mem.exists(49'h3000_0000 + AW'(i * 8))) begin
          errors++; $display("ERROR write missing at %0d", i); break;
        end
    end
    if (errors == 0) $display("PASS tb_s1");
    else $display("FAIL tb_s1: %0d errors", errors);
    $finish;
  end
endmodule
