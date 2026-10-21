// Host DMA bridge test (docs/spec/soc.md §8.1): tg_hdma between an AXI4 master and a TileLink-UH
// memory model, both with random back-pressure and latency, the model answering a Get and a Put in
// either order. Random INCR bursts (lengths, narrow and unaligned beats, partial strobes) against a
// reference memory; lines the model denies (a read beat SLVERR; a denied Put leaves memory as it was);
// beats beyond the window (a read DECERR, a write dropped; nothing forwarded), bursts straddling its
// end; FIXED and WRAP bursts (SLVERR on every read beat, nothing written); writes always answer OKAY,
// and each write burst not done in full counts once; a read and a write burst at once on disjoint
// halves; the TileLink side's
// rules (size-6 aligned messages, a Put's beats together, PutFullData exactly when every byte is
// written); one completion per written line, with its line and AccessAck cycle, while enabled; the
// line counters. REL = 1 (make ... REL=1) builds the port as release builds without the trace do (DR-180: CPL = 0,
// STATS = 0): no completion ever, an AccessAck never waits for the queue, the line counters read 0, and the
// dropped write bursts still count.
module tb_hdma #(parameter bit REL = 1'b0);
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;

  localparam int          ID_W      = 16;
  localparam int          MEM_BYTES = 64 * 1024;                 // the model: DRAM_BASE .. + 64 KiB
  localparam logic [39:0] RAM_SIZE  = 40'(48 * 1024);            // the window; beyond answers DECERR
  localparam int          NLINES    = MEM_BYTES / 64;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;
  logic [31:0] tcyc;                                             // the bridge's count: cycles since reset
  always @(posedge clk) tcyc <= rst ? 32'd0 : tcyc + 32'd1;

  // ---- AXI master side ----
  logic [ID_W-1:0] awid, arid, bid, rid;
  logic [39:0]     awaddr, araddr;
  logic [7:0]      awlen, arlen;
  logic [2:0]      awsize, arsize;
  logic [1:0]      awburst, arburst, bresp, rresp;
  logic            awvalid, awready, wvalid, wready, wlast, bvalid, bready;
  logic            arvalid, arready, rvalid, rready, rlast;
  logic [127:0]    wdata, rdata;
  logic [15:0]     wstrb;
  // ---- TileLink side ----
  tl_a_t a;  logic a_v, a_r;
  tl_d_t d;  logic d_v, d_r;
  // ---- completions and statistics ----
  logic        cpl_en, cpl_v, cpl_r;
  logic [25:0] cpl_line;
  logic [31:0] cpl_cycle, rd_lines, wr_lines, wr_drops;

  tg_hdma #(.ID_W (ID_W), .CPL (!REL), .STATS (!REL)) dut (
    .clk, .rst,
    .s_awid (awid), .s_awaddr (awaddr), .s_awlen (awlen), .s_awsize (awsize), .s_awburst (awburst),
    .s_awvalid (awvalid), .s_awready (awready),
    .s_wdata (wdata), .s_wstrb (wstrb), .s_wlast (wlast), .s_wvalid (wvalid), .s_wready (wready),
    .s_bid (bid), .s_bresp (bresp), .s_bvalid (bvalid), .s_bready (bready),
    .s_arid (arid), .s_araddr (araddr), .s_arlen (arlen), .s_arsize (arsize), .s_arburst (arburst),
    .s_arvalid (arvalid), .s_arready (arready),
    .s_rid (rid), .s_rdata (rdata), .s_rresp (rresp), .s_rlast (rlast), .s_rvalid (rvalid), .s_rready (rready),
    .ram_size_i (RAM_SIZE),
    .a_o (a), .a_valid_o (a_v), .a_ready_i (a_r), .d_i (d), .d_valid_i (d_v), .d_ready_o (d_r),
    .cpl_en_i (cpl_en), .cpl_valid_o (cpl_v), .cpl_line_o (cpl_line), .cpl_cycle_o (cpl_cycle), .cpl_ready_i (cpl_r),
    .rd_lines_o (rd_lines), .wr_lines_o (wr_lines), .wr_drops_o (wr_drops)
  );

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    if (errors < 30) $display("[%0d] ERROR: %s", tcyc, m);
  endtask

  // =============================================================================================
  // TileLink-UH memory model
  // =============================================================================================
  logic [7:0] mem [MEM_BYTES];
  bit         denied [NLINES];
  int         n_get = 0, n_put = 0;
  typedef struct { bit put; logic [25:0] line; bit den; logic [127:0] data [4]; int delay; } rsp_t;
  rsp_t        rq [$];
  rsp_t        cur;
  bit          cur_v = 1'b0;
  int          cur_beat;
  // a Put being collected
  logic [127:0] pdata [4];
  logic [15:0]  pmask [4];
  int           pbeat = 0;
  logic [25:0]  pline;
  tl_a_op_e     pop;
  int           n_cpl = 0;                     // completions seen

  function automatic logic [25:0] line_of(input tl_a_t x);
    return 26'((x.address - TL_ADDR_W'(DRAM_BASE)) >> 6);
  endfunction

  always @(posedge clk) begin
    if (rst) begin
      a_r <= 1'b0;
    end else begin
      if (a_v && a_r) begin
        if (a.size != 3'd6 || a.address[5:0] != 6'd0 || a.param != 3'd0 || a.corrupt)
          fail($sformatf("A message: size %0d address %h", a.size, a.address));
        if (a.address < TL_ADDR_W'(DRAM_BASE) || a.address >= TL_ADDR_W'(DRAM_BASE) + TL_ADDR_W'(RAM_SIZE))
          fail($sformatf("A message outside the window: %h", a.address));
        if (a.opcode == A_GET) begin
          rsp_t r;
          if (pbeat != 0) fail("a Get between a Put's beats");
          if (a.source != TL_SRC_W'(0) || a.mask != '1) fail("Get source or mask");
          r.put = 1'b0;
          r.line = line_of(a);
          r.den = denied[r.line];
          for (int k = 0; k < 4; k++)
            for (int b = 0; b < 16; b++) r.data[k][8*b +: 8] = r.den ? 8'hEE : mem[64 * r.line + 16 * k + b];
          r.delay = $urandom_range(30);
          rq.push_back(r);
          n_get++;
        end else if (a.opcode == A_PUT_FULL || a.opcode == A_PUT_PARTIAL) begin
          if (a.source != TL_SRC_W'(1)) fail("Put source");
          if (pbeat == 0) begin
            pline = line_of(a);
            pop   = a.opcode;
          end else if (line_of(a) != pline || a.opcode != pop) begin
            fail("a Put's beats changed address or opcode");
          end
          pdata[pbeat] = a.data;
          pmask[pbeat] = a.mask;
          pbeat++;
          if (pbeat == 4) begin
            rsp_t r;
            bit   full;
            full = &{pmask[0], pmask[1], pmask[2], pmask[3]};
            if (full != (pop == A_PUT_FULL)) fail($sformatf("Put opcode %0d with masks full=%0d", pop, full));
            if (!denied[pline])
              for (int k = 0; k < 4; k++)
                for (int b = 0; b < 16; b++)
                  if (pmask[k][b]) mem[64 * pline + 16 * k + b] = pdata[k][8*b +: 8];
            r.put = 1'b1;
            r.line = pline;
            r.den = denied[pline];
            r.delay = $urandom_range(30);
            rq.push_back(r);
            pbeat = 0;
            n_put++;
          end
        end else begin
          fail($sformatf("A opcode %0d", a.opcode));
        end
      end
      a_r <= ($urandom_range(99) < 70);
    end
  end

  // D side: a response whose delay has passed, picked at random among them (a Get's and a Put's
  // may come back in either order), its beats together with random gaps between them
  always @(posedge clk) begin
    if (rst) begin
      d_v <= 1'b0;
      d   <= '0;
    end else begin
      if (d_v && d_r) begin
        // while recording, a Put's AccessAck is taken together with its completion: the line and this cycle
        if (cur.put && cpl_en && !REL) begin
          if (!(cpl_v && cpl_r)) fail("a Put's AccessAck taken without its completion");
          else if (cpl_line != cur.line || cpl_cycle != tcyc)
            fail($sformatf("completion line %h cycle %0d, want line %h cycle %0d", cpl_line, cpl_cycle, cur.line, tcyc));
          else n_cpl++;
        end
        cur_beat++;
        if (cur.put || cur_beat == 4) cur_v = 1'b0;
      end
      foreach (rq[i]) if (rq[i].delay > 0) rq[i].delay--;
      if (!cur_v) begin
        int ready [$];                         // static in this block: emptied each time
        ready.delete();
        foreach (rq[i]) if (rq[i].delay == 0) ready.push_back(i);
        if (ready.size() > 0) begin
          int k;
          k = ready[$urandom_range(ready.size() - 1)];
          cur = rq[k];
          rq.delete(k);
          cur_v = 1'b1;
          cur_beat = 0;
        end
      end
      if (d_v && !d_r) begin
        // a beat on offer stays
      end else if (cur_v && $urandom_range(99) < 80) begin
        d_v <= 1'b1;
        d.opcode <= cur.put ? D_ACCESS_ACK : D_ACCESS_ACK_DATA;
        d.size   <= 3'd6;
        d.source <= TL_SRC_W'(cur.put);
        d.denied <= cur.den;
        d.corrupt <= cur.den && !cur.put;
        d.data   <= cur.put ? 128'd0 : cur.data[cur_beat];
      end else begin
        d_v <= 1'b0;
      end
    end
  end

  // the completion queue's room, at random; a completion comes only with a Put's AccessAck
  always @(posedge clk) begin
    if (rst) begin
      cpl_r <= 1'b0;
    end else begin
      if (cpl_v && !cpl_en) fail("a completion while recording is off");
      if (cpl_v && REL) fail("a completion in a release build");
      if (cpl_v && cpl_r && !(d_v && d_r && d.source[0])) fail("a completion without an AccessAck");
      cpl_r <= ($urandom_range(99) < 60);
    end
  end

  // =============================================================================================
  // AXI master
  // =============================================================================================
  logic [7:0] refm [MEM_BYTES];                                  // what the memory should hold
  int         n_drops = 0;                                       // write bursts not done in full

  function automatic bit in_win(input int off);
    return off < int'(RAM_SIZE);
  endfunction
  // the byte lanes of beat k of a burst: [lo, hi] of the 16
  function automatic void lanes(input int start, input int size, input int k, output int addr, output int lo, output int hi);
    int al;
    al   = start & ~((1 << size) - 1);
    addr = (k == 0) ? start : al + k * (1 << size);
    lo   = addr & 15;
    hi   = ((k == 0 ? al : addr) & 15) + (1 << size) - 1;
  endfunction

  // A write burst; returns its B response. Partial strobes leave random bytes unwritten.
  task automatic axi_write(input int start, input int len, input int size, input logic [1:0] burst, input bit partial,
                           output logic [1:0] resp);
    logic [ID_W-1:0] id;
    bit den_seen, out_seen;
    id = ID_W'($urandom);
    den_seen = 0;
    out_seen = 0;
    @(negedge clk);
    awid = id; awaddr = 40'h5_0000_0000 | 40'(start); awlen = 8'(len); awsize = 3'(size); awburst = burst;
    awvalid = 1;
    do @(posedge clk); while (!awready);
    @(negedge clk) awvalid = 0;
    for (int k = 0; k <= len; k++) begin
      int addr, lo, hi;
      lanes(start, size, k, addr, lo, hi);
      while ($urandom_range(99) < 15) @(negedge clk);           // gaps between beats
      wdata = {$urandom, $urandom, $urandom, $urandom};
      wstrb = '0;
      for (int b = lo; b <= hi; b++) wstrb[b] = !partial || $urandom_range(3) != 0;
      wlast = (k == len);
      wvalid = 1;
      do @(posedge clk); while (!wready);
      @(negedge clk) wvalid = 0;
      if (burst == AXI_INCR)
        for (int b = lo; b <= hi; b++) begin
          int o;
          o = (addr & ~15) + b;
          if (!in_win(o)) out_seen = 1;
          else if (denied[o / 64]) den_seen |= wstrb[b];         // a line with no byte written sends no Put
          else if (wstrb[b]) refm[o] = wdata[8*b +: 8];
        end
    end
    bready = 1;
    do @(posedge clk); while (!bvalid);
    resp = bresp;
    if (bid != id) fail("B id");
    @(negedge clk) bready = 0;
    if (resp != 2'b00) fail($sformatf("write at %h len %0d size %0d burst %0d: B %0d, want OKAY", start, len, size,
                                      burst, resp));
    if (burst != AXI_INCR || den_seen || out_seen) n_drops++;
  endtask

  // A read burst, every beat checked against the reference
  task automatic axi_read(input int start, input int len, input int size, input logic [1:0] burst);
    logic [ID_W-1:0] id;
    id = ID_W'($urandom);
    @(negedge clk);
    arid = id; araddr = 40'h5_0000_0000 | 40'(start); arlen = 8'(len); arsize = 3'(size); arburst = burst;
    arvalid = 1;
    do @(posedge clk); while (!arready);
    @(negedge clk) arvalid = 0;
    for (int k = 0; k <= len; k++) begin
      int addr, lo, hi;
      logic [1:0] want;
      lanes(start, size, k, addr, lo, hi);
      rready = ($urandom_range(99) < 75);
      while (1) begin
        @(posedge clk);
        if (rvalid && rready) break;
        @(negedge clk) rready = ($urandom_range(99) < 75);
      end
      want = (burst != AXI_INCR) ? 2'b10 : !in_win(addr & ~63) ? 2'b11 : denied[(addr & ~63) / 64] ? 2'b10 : 2'b00;
      if (rid != id) fail("R id");
      if (rlast != (k == len)) fail($sformatf("RLAST at beat %0d of %0d", k, len + 1));
      if (rresp != want) fail($sformatf("read at %h beat %0d: RRESP %0d, want %0d", start, k, rresp, want));
      else if (want == 2'b00)
        for (int b = lo; b <= hi; b++)
          if (rdata[8*b +: 8] !== refm[(addr & ~15) + b]) begin
            fail($sformatf("read at %h len %0d size %0d beat %0d byte %0d: %h, want %h", start, len, size, k, b,
                           rdata[8*b +: 8], refm[(addr & ~15) + b]));
            break;
          end
      @(negedge clk) rready = 0;
    end
  endtask

  // a random burst inside [lo_off, hi_off) that stays within a 4 KiB page
  task automatic pick(input int lo_off, input int hi_off, output int start, output int len, output int size);
    int bytes;
    size = $urandom_range(4);
    len  = ($urandom_range(9) == 0) ? $urandom_range(63) : $urandom_range(7);
    bytes = (len + 1) << size;
    if (bytes > 4096) begin len = (4096 >> size) - 1; bytes = 4096; end
    do start = lo_off + $urandom_range(hi_off - lo_off - 1);
    while ((start & 4095) + bytes > 4096 || start + bytes > hi_off);
    if ($urandom_range(1)) start = start & ~((1 << size) - 1);   // aligned half the time
  endtask

  // a hang shows where each side waits, and the last handshakes before it
  string       ev [$];
  logic [31:0] last_prog;
  always @(posedge clk) begin
    if (rst) last_prog <= 0;
    else begin
      string e;
      e = "";
      if (a_v && a_r) e = {e, $sformatf(" A op%0d src%0d line %h", a.opcode, a.source[0], line_of(a))};
      if (d_v && d_r) e = {e, $sformatf(" D src%0d op%0d", d.source[0], d.opcode)};
      if (arvalid && arready) e = {e, $sformatf(" AR %h len %0d size %0d", araddr[31:0], arlen, arsize)};
      if (rvalid && rready) e = {e, $sformatf(" R last%0d", rlast)};
      if (awvalid && awready) e = {e, $sformatf(" AW %h len %0d size %0d", awaddr[31:0], awlen, awsize)};
      if (bvalid && bready) e = {e, " B"};
      if (e != "") begin
        ev.push_back($sformatf("%0d rs%0d ws%0d rbeat%0d rleft%0d:%s", tcyc, dut.rs_q, dut.ws_q, dut.rbeat_q, dut.rleft_q, e));
        if (ev.size() > 60) void'(ev.pop_front());
        last_prog <= tcyc;
      end
      if (tcyc - last_prog > 20000) begin
        foreach (ev[i]) $display("  %s", ev[i]);
        $display("WATCHDOG: rs %0d ws %0d a_busy %0d pbeat %0d | a_v %0d a_r %0d d_v %0d d_r %0d d.src %0d | rq %0d cur_v %0d cur.put %0d",
                 dut.rs_q, dut.ws_q, dut.a_busy_q, dut.pbeat_q, a_v, a_r, d_v, d_r, d.source[0], rq.size(), cur_v, cur.put);
        $display("TEST FAILED (watchdog)");
        $finish;
      end
    end
  end

  int unsigned seed;
  initial begin
    logic [1:0] resp;
    int start, len, size;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0; cpl_en = 0;
    awburst = AXI_INCR; arburst = AXI_INCR;
    for (int i = 0; i < MEM_BYTES; i++) begin mem[i] = 8'($urandom); refm[i] = mem[i]; end
    for (int l = 0; l < NLINES; l++) denied[l] = ($urandom_range(99) < 3);
    repeat (5) @(posedge clk);
    rst = 0;
    repeat (5) @(posedge clk);

    // ---- sequential: random writes and reads over the window and past its end ----
    for (int n = 0; n < 1500; n++) begin
      if (n == 500) cpl_en = 1;                                  // completions on for a while
      if (n == 1000) cpl_en = 0;
      pick(0, ($urandom_range(9) == 0) ? MEM_BYTES : int'(RAM_SIZE), start, len, size);
      if ($urandom_range(1)) axi_write(start, len, size, AXI_INCR, $urandom_range(2) == 0, resp);
      else                   axi_read(start, len, size, AXI_INCR);
    end
    // ---- FIXED and WRAP: SLVERR, nothing forwarded ----
    begin
      int g, p;
      g = n_get; p = n_put;
      axi_read(256, 3, 4, 2'b00);
      axi_read(256, 3, 4, 2'b10);
      axi_write(512, 3, 4, 2'b00, 0, resp);
      axi_write(512, 3, 4, 2'b10, 0, resp);
      if (n_get != g || n_put != p) fail("a FIXED or WRAP burst reached TileLink");
    end
    // ---- a read and a write burst at once, on disjoint halves ----
    fork
      for (int n = 0; n < 300; n++) begin
        int s, l, z;
        pick(0, 16384, s, l, z);
        axi_read(s, l, z, AXI_INCR);
      end
      for (int n = 0; n < 300; n++) begin
        int s, l, z;
        logic [1:0] r;
        pick(16384, 32768, s, l, z);
        axi_write(s, l, z, AXI_INCR, $urandom_range(1), r);
      end
    join
    // ---- the memory holds what the writes left ----
    repeat (100) @(posedge clk);
    for (int i = 0; i < MEM_BYTES; i++)
      if (mem[i] !== refm[i]) begin fail($sformatf("memory byte %h: %h, want %h", i, mem[i], refm[i])); break; end
    if (rd_lines != (REL ? 0 : 32'(n_get)) || wr_lines != (REL ? 0 : 32'(n_put)))
      fail($sformatf("line counters %0d / %0d, want %0d / %0d", rd_lines, wr_lines, REL ? 0 : n_get, REL ? 0 : n_put));
    if (wr_drops != 32'(n_drops)) fail($sformatf("%0d write bursts counted as dropped, want %0d", wr_drops, n_drops));
    if (n_cpl == 0 && !REL) fail("no completions");
    $display("hdma: %0d Gets, %0d Puts, %0d completions, %0d write bursts dropped in part", n_get, n_put, n_cpl, n_drops);
    if (errors == 0) $display("TEST PASSED (seed %0d)", seed);
    else             $display("TEST FAILED (seed %0d): %0d errors", seed, errors);
    $finish;
  end
endmodule
