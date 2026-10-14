// tg_trace_stream test (docs/spec/uncore-trace.md §Verification).
// Core models follow interfaces.md §5 exactly: trace_stall_i is registered (a core may retire in
// the cycle after it rises), deferred writebacks are never stalled, at most LLT_ENTRIES are
// outstanding per core. An AXI slave with random back-pressure and latency stores the records; a
// consumer reads them behind WP at a random pace and advances RP.
// Phases: 1. lossless ring, small, consumer-paced; 2. wrap with a stop trigger; 3. start trigger.
module tb_trace_stream;
  import tg_pkg::*, tg_trace_pkg::*, tg_uncore_pkg::*;

  localparam int NC = 2;
  localparam int CW = COMMIT_WIDTH;
  localparam int NW = TRACE_WB_PORTS;
  localparam logic [39:0] BASE = 40'h8_4100_0000;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;

  tr_rec_t [NC-1:0][CW-1:0] tr;
  logic    [NC-1:0][CW-1:0] tr_v;
  tr_wb_t  [NC-1:0][NW-1:0] twb;
  logic    [NC-1:0][NW-1:0] twb_v;
  logic    [NC-1:0]         stall;

  logic        en, wrap, stop_arm, start_arm;
  logic [63:0] stop_pc, start_pc, rp;
  logic [15:0] post;
  logic [4:0]  size_log2;
  logic [63:0] wp;
  logic        capturing, started, stopped, full, axi_err;
  logic [15:0] buffered;
  logic [31:0] stall_cyc;

  axi_ax_t aw; logic aw_v, aw_r;
  axi_w_t  w;  logic w_v, w_r;
  axi_b_t  b;  logic b_v, b_r;

  tg_trace_stream #(.N_CORES (NC)) dut (
    .clk, .rst,
    .trace_i (tr), .trace_valid_i (tr_v), .trace_wb_i (twb), .trace_wb_valid_i (twb_v), .trace_stall_o (stall),
    .enable_i (en), .wrap_i (wrap), .stop_arm_i (stop_arm), .stop_pc_i (stop_pc), .post_i (post),
    .start_arm_i (start_arm), .start_pc_i (start_pc), .base_i (BASE), .size_log2_i (size_log2), .rp_i (rp),
    .wp_o (wp), .capturing_o (capturing), .started_o (started), .stopped_o (stopped), .full_o (full),
    .axi_err_o (axi_err), .buffered_o (buffered), .stall_cycles_o (stall_cyc),
    .aw_o (aw), .aw_valid_o (aw_v), .aw_ready_i (aw_r),
    .w_o (w), .w_valid_o (w_v), .w_ready_i (w_r),
    .b_i (b), .b_valid_i (b_v), .b_ready_o (b_r)
  );

  // Port signature: every cycle, every output of the DUT (payloads only while valid). Two builds with
  // the same seed and signature behave identically at the ports, cycle by cycle (the cycle-identity
  // check for rewrites, docs/perf/fpga_friendly.md).
  logic [63:0] psig = 64'hcbf2_9ce4_8422_2325;
  function automatic logic [63:0] fnv(input logic [63:0] h, input logic [255:0] x);
    for (int b = 0; b < 32; b++) h = (h ^ 64'(x[8*b +: 8])) * 64'h0000_0100_0000_01b3;
    return h;
  endfunction
  always @(posedge clk) if (!rst) begin
    logic [63:0] h;
    h = fnv(psig, 256'({stall, aw_v, w_v, b_r, capturing, started, stopped, full, axi_err, buffered, stall_cyc}));
    h = fnv(h, 256'(wp));
    h = fnv(h, aw_v ? 256'(aw) : '0);
    h = fnv(h, w_v ? 256'(w) : '0);
    psig <= h;
  end

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    if (errors < 20) $display("[%0t] ERROR: %s", $time, m);
  endtask

  // ---------------------------------------------------------------------------------------------
  // Reference packing (docs/spec/host.md §Trace ring), independent of the DUT's functions
  // ---------------------------------------------------------------------------------------------
  function automatic logic [319:0] ref_rec(input tr_rec_t r);
    logic [319:0] x;
    x = '0;
    x[1:0] = r.kind; x[3:2] = 2'(r.hart); x[5:4] = r.priv; x[6] = r.rvc; x[7] = r.rd_we; x[8] = r.rd_fp;
    x[13:9] = r.rd; x[14] = r.rd_deferred; x[19:15] = 5'(r.wb_tag); x[20] = r.mem_st; x[22:21] = r.mem_size;
    x[23] = r.mmio_ld; x[24] = r.nondet; x[63:32] = r.insn; x[127:64] = r.pc;
    x[191:128] = (r.kind == TR_RETIRE) ? r.rd_value : r.cause;
    x[255:192] = (r.kind == TR_TRAP) ? r.tval : r.mem_vaddr;
    x[319:256] = r.mem_wdata;
    return x;
  endfunction
  function automatic logic [319:0] ref_wb(input tr_wb_t v);
    logic [319:0] x;
    x = '0;
    x[1:0] = 2'd3; x[3:2] = 2'(v.hart); x[8] = v.rd_fp; x[13:9] = v.rd; x[19:15] = 5'(v.wb_tag);
    x[191:128] = v.value;
    return x;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Core models (each core's pcs in its own range, so a trigger pc names one core)
  // ---------------------------------------------------------------------------------------------
  function automatic logic [63:0] pc_of(input int c, input longint unsigned n);
    return 64'h8000_0000 + (64'(c) << 32) + 64'(n) * 4;
  endfunction
  logic [319:0] expq [NC][$];        // expected records per core, in stream order
  longint unsigned seq [NC];         // per-core instruction sequence (pc = seq * 4)
  bit           gen_on;              // the cores run
  bit           capture_ref;         // the reference expects records (mirrors the DUT's capture state)
  logic [NC-1:0] stall_q;
  int           pend_tag [NC][$];    // outstanding deferred tags
  int           pend_age [NC][$];
  logic [LLT_ENTRIES-1:0] tag_busy [NC];
  int retire_pct = 80, defer_pct = 25, wb_pct = 30;

  // The core registers trace_stall_i and may still retire in the cycle after it rises
  // (interfaces.md §5): the longest latency the interface allows, two stages here.
  logic [NC-1:0] stall_r1;
  always @(posedge clk) begin
    stall_r1 <= rst ? '0 : stall;
    stall_q  <= rst ? '0 : stall_r1;
  end

  always @(negedge clk) begin
    tr_v = '0; twb_v = '0; tr = '0; twb = '0;
    if (!rst && gen_on) begin
      for (int c = 0; c < NC; c++) begin
        int n;
        n = 0;
        if (!stall_q[c]) while (n < CW && $urandom_range(99) < retire_pct) n++;
        for (int k = 0; k < n; k++) begin
          tr_rec_t r;
          r = '0;
          r.hart  = hart_t'(c * NUM_THREADS);
          r.priv  = PRIV_M;
          r.pc    = pc_of(c, seq[c]);
          r.insn  = $urandom();
          r.kind  = ($urandom_range(99) < 3) ? TR_TRAP : ($urandom_range(99) < 2 ? TR_IRQ : TR_RETIRE);
          r.cause = {$urandom(), $urandom()};
          r.tval  = {$urandom(), $urandom()};
          if (r.kind == TR_RETIRE) begin
            r.rd_we = 1'b1;
            r.rd    = 5'($urandom_range(31));
            r.mem_st = $urandom_range(9) == 0;
            r.mem_vaddr = {$urandom(), $urandom()};
            r.mem_wdata = {$urandom(), $urandom()};
            r.rd_value  = {$urandom(), $urandom()};
            if ($urandom_range(99) < defer_pct && pend_tag[c].size() < LLT_ENTRIES) begin
              int t;
              do t = $urandom_range(LLT_ENTRIES - 1); while (tag_busy[c][t]);
              tag_busy[c][t] = 1'b1;
              pend_tag[c].push_back(t);
              pend_age[c].push_back(0);
              r.rd_deferred = 1'b1;
              r.wb_tag      = WB_TAG_W'(t);
              r.rd_value    = '0;
            end
          end
          tr[c][k]   = r;
          tr_v[c][k] = 1'b1;
          seq[c]++;
          if (capture_ref) expq[c].push_back(ref_rec(r));
        end
        // writebacks: never stalled; any outstanding tag, on any port
        for (int p = 0; p < NW; p++) begin
          if (pend_tag[c].size() > 0 && pend_age[c][0] > 0 && $urandom_range(99) < wb_pct) begin
            tr_wb_t v;
            int i;
            i = $urandom_range(pend_tag[c].size() - 1);
            if (pend_age[c][i] == 0) i = 0;
            v = '0;
            v.hart   = hart_t'(c * NUM_THREADS);
            v.wb_tag = WB_TAG_W'(pend_tag[c][i]);
            v.rd     = 5'($urandom_range(31));
            v.value  = {$urandom(), $urandom()};
            tag_busy[c][pend_tag[c][i]] = 1'b0;
            pend_tag[c].delete(i);
            pend_age[c].delete(i);
            twb[c][p]   = v;
            twb_v[c][p] = 1'b1;
          end
        end
        for (int p = 0; p < NW; p++) if (twb_v[c][p] && capture_ref) expq[c].push_back(ref_wb(twb[c][p]));
        for (int i = 0; i < pend_age[c].size(); i++) pend_age[c][i]++;
      end
    end
  end

  // ---------------------------------------------------------------------------------------------
  // AXI slave: random ready, B after a random delay, records stored by address
  // ---------------------------------------------------------------------------------------------
  // AXI allows a burst's data before its address: addresses and completed data pair up in order
  logic [511:0] mem [longint unsigned];
  longint unsigned awq [$];
  logic [511:0] wq [$];
  int beat;
  logic [511:0] cur_rec;
  int bq [$];
  int ready_pct = 70;

  always @(negedge clk) begin
    aw_r = !rst && $urandom_range(99) < ready_pct;
    w_r  = !rst && $urandom_range(99) < ready_pct;
    b_v  = 1'b0;
    b    = '0;
    if (bq.size() > 0 && bq[0] <= 0 && $urandom_range(99) < 60) b_v = 1'b1;
  end
  always @(posedge clk) if (!rst) begin
    for (int i = 0; i < bq.size(); i++) bq[i]--;
    if (b_v && b_r) void'(bq.pop_front());
    if (aw_v && aw_r) begin
      if (aw.len != 8'd3 || aw.size != 3'd4 || aw.burst != AXI_INCR) fail("AW not a 4-beat INCR burst of 16 bytes");
      if (aw.addr[5:0] != 6'd0) fail("AW not 64-byte aligned");
      awq.push_back(longint'(aw.addr));
    end
    if (w_v && w_r) begin
      cur_rec[128 * beat +: 128] = w.data;
      if (w.last != (beat == 3)) fail("WLAST");
      if (w.strb != '1) fail("WSTRB");
      beat++;
      if (beat == 4) begin
        beat = 0;
        wq.push_back(cur_rec);
      end
    end
    while (awq.size() > 0 && wq.size() > 0) begin
      mem[awq.pop_front()] = wq.pop_front();
      bq.push_back($urandom_range(2, 30));
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Consumer: reads records below WP in order, checks them against the per-core expectations
  // ---------------------------------------------------------------------------------------------
  longint unsigned consumed;
  int consume_pct = 40;
  bit consume_on;
  int checked;

  task automatic check_record(input logic [511:0] x, input longint unsigned n);
    int c;
    logic [319:0] want;
    c = int'(x[3:2]) / NUM_THREADS;
    if (x[511:352] != '0) fail($sformatf("record %0d: reserved bytes not zero", n));
    if (expq[c].size() == 0) begin
      fail($sformatf("record %0d for core %0d, none expected", n, c));
      return;
    end
    want = expq[c].pop_front();
    if (x[319:0] != want) fail($sformatf("record %0d core %0d: got %h, want %h", n, c, x[319:0], want));
    checked++;
  endtask

  always @(posedge clk) if (!rst && consume_on && consumed < wp && $urandom_range(99) < consume_pct) begin
    longint unsigned a;
    a = longint'(BASE) + ((consumed & ((64'(1) << size_log2) - 1)) << 6);
    if (!mem.exists(a)) fail($sformatf("record %0d missing at %h", consumed, a));
    else check_record(mem[a], consumed);
    consumed++;
    rp <= consumed;
  end

  // ---------------------------------------------------------------------------------------------
  int unsigned seed;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    en = 0; wrap = 0; stop_arm = 0; start_arm = 0; stop_pc = '0; start_pc = '0; post = '0; rp = '0;
    size_log2 = 5'd6;
    gen_on = 0; capture_ref = 0; consume_on = 0; consumed = 0; checked = 0; beat = 0;
    for (int c = 0; c < NC; c++) begin seq[c] = 0; tag_busy[c] = '0; end
    repeat (5) @(posedge clk);
    rst = 0;
    repeat (5) @(posedge clk);

    // ---- phase 1: lossless, 64-record ring, consumer-paced (the ring fills and stalls the cores)
    @(negedge clk);
    en = 1; consume_on = 1;
    repeat (3) @(posedge clk);                  // the DUT registers enable
    @(negedge clk);
    capture_ref = 1; gen_on = 1;
    repeat (20000) @(posedge clk);
    @(negedge clk);
    gen_on = 0;
    repeat (50) @(posedge clk);
    @(negedge clk) capture_ref = 0;                // deferred tags still pending: drain them below
    gen_on = 0;
    begin
      int t;
      t = 0;
      while ((buffered != 0 || consumed < wp || wp != dut.issued_q) && t < 200000) begin
        @(posedge clk);
        t++;
      end
    end
    for (int c = 0; c < NC; c++)
      if (expq[c].size() != 0) fail($sformatf("phase 1: %0d records of core %0d never arrived", expq[c].size(), c));
    if (stall_cyc == 0) fail("phase 1: the cores were never stalled (ring too large for the test?)");
    if (axi_err) fail("AXI error");
    $display("phase 1: %0d records checked, %0d stall cycles", checked, stall_cyc);

    // ---- phase 2: wrap with a stop trigger: the ring holds the tail up to POST after the pc
    @(negedge clk);
    en = 0;
    for (int c = 0; c < NC; c++) begin
      pend_tag[c].delete(); pend_age[c].delete(); tag_busy[c] = '0;
    end
    repeat (5) @(posedge clk);
    @(negedge clk);
    consume_on = 0;
    wrap = 1; size_log2 = 5'd8; rp = '0; consumed = 0;
    stop_arm = 1; post = 16'd40;
    stop_pc = pc_of(0, seq[0] + 3000);                   // core 0, about 3000 instructions in
    en = 1; defer_pct = 0;                               // no writebacks: the tail is exact
    gen_on = 1;
    begin
      int t;
      t = 0;
      while (!stopped && t < 100000) begin @(posedge clk); t++; end
      if (!stopped) fail("phase 2: the stop trigger never fired");
    end
    @(negedge clk) gen_on = 0;
    repeat (2000) @(posedge clk);
    // the newest record of core 0 lies within POST plus one cycle of the trigger
    begin
      longint unsigned n, last_pc, last_rec;
      bit found;
      n = wp;
      found = 0;
      last_pc = 0;
      for (longint unsigned i = n; i > 0 && i + 256 > n; i--) begin
        logic [511:0] x;
        x = mem[longint'(BASE) + (((i - 1) & 255) << 6)];
        if (int'(x[3:2]) == 0 && !found) begin found = 1; last_pc = x[127:64]; last_rec = i - 1; end
      end
      if (!found) fail("phase 2: no record of core 0 in the ring");
      else if (last_pc < stop_pc || last_pc > stop_pc + 4 * (40 + 2 * CW)) fail($sformatf("phase 2: last pc %h, trigger %h", last_pc, stop_pc));
      $display("phase 2: stopped; last core-0 pc %h (trigger %h), %0d records written", last_pc, stop_pc, n);
    end

    // ---- phase 3: start trigger: nothing before the pc
    @(negedge clk);
    en = 0; stop_arm = 0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    wrap = 0; size_log2 = 5'd10; rp = '0; consumed = 0; consume_on = 0;   // contents not checked here
    start_arm = 1; start_pc = pc_of(1, seq[1] + 500);   // core 1
    en = 1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    gen_on = 1;
    repeat (3000) @(posedge clk);
    @(negedge clk) gen_on = 0;
    repeat (3000) @(posedge clk);
    if (!started) fail("phase 3: the start trigger never fired");
    begin
      logic [511:0] x;
      x = mem[longint'(BASE)];
      if (x[127:64] != start_pc) fail($sformatf("phase 3: first record pc %h, want the trigger pc %h", x[127:64], start_pc));
    end
    $display("phase 3: started at the trigger pc, %0d records", wp);

    $display("trace_stream: port signature %016h", psig);
    if (errors == 0) $display("TEST PASSED (seed %0d)", seed);
    else             $display("TEST FAILED (seed %0d): %0d errors", seed, errors);
    $finish;
  end

  initial begin
    #50ms;
    $display("TEST FAILED: timeout");
    $finish;
  end
endmodule
