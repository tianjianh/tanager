// Latency injector test (docs/spec/uncore-mem.md §Verification). A stub master issues random
// 4-beat reads and writes with unique IDs; tb_axi_mem answers with random latency, out of order.
// Phases: pass-through; mode 0 (target latency); mode 1 (added latency); write delay; bandwidth cap;
// sparse reads after the dense phases (the issue-order queue then holds stale slots from them, and
// a burst often finishes as the next arrives: the head after a pop with one entry).
// Checks data, issue order of R bursts, delivered latency per burst, B delay, beat rate, statistics.
module tb_lat_inj;
  import tg_pkg::*, tg_uncore_pkg::*, tb_axi_mem_pkg::*;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;

  logic [9:0] rd_delay, wr_delay;
  logic       mode;
  logic [8:0] bw_rate;
  logic [31:0] st_cnt, st_sum;
  logic [15:0] st_max;

  axi_ax_t s_ar, s_aw, m_ar, m_aw;
  axi_r_t  s_r, m_r;
  axi_w_t  s_w, m_w;
  axi_b_t  s_b, m_b;
  logic s_ar_v, s_ar_r, s_r_v, s_r_r, s_aw_v, s_aw_r, s_w_v, s_w_r, s_b_v, s_b_r;
  logic m_ar_v, m_ar_r, m_r_v, m_r_r, m_aw_v, m_aw_r, m_w_v, m_w_r, m_b_v, m_b_r;

  tg_axi_lat_inj dut (
    .clk, .rst, .rd_delay_i (rd_delay), .wr_delay_i (wr_delay), .mode_i (mode), .bw_rate_i (bw_rate),
    .st_rd_count_o (st_cnt), .st_lat_sum_o (st_sum), .st_lat_max_o (st_max),
    .s_ar_i (s_ar), .s_ar_valid_i (s_ar_v), .s_ar_ready_o (s_ar_r),
    .s_r_o (s_r), .s_r_valid_o (s_r_v), .s_r_ready_i (s_r_r),
    .s_aw_i (s_aw), .s_aw_valid_i (s_aw_v), .s_aw_ready_o (s_aw_r),
    .s_w_i (s_w), .s_w_valid_i (s_w_v), .s_w_ready_o (s_w_r),
    .s_b_o (s_b), .s_b_valid_o (s_b_v), .s_b_ready_i (s_b_r),
    .m_ar_o (m_ar), .m_ar_valid_o (m_ar_v), .m_ar_ready_i (m_ar_r),
    .m_r_i (m_r), .m_r_valid_i (m_r_v), .m_r_ready_o (m_r_r),
    .m_aw_o (m_aw), .m_aw_valid_o (m_aw_v), .m_aw_ready_i (m_aw_r),
    .m_w_o (m_w), .m_w_valid_o (m_w_v), .m_w_ready_i (m_w_r),
    .m_b_i (m_b), .m_b_valid_i (m_b_v), .m_b_ready_o (m_b_r)
  );

  tb_axi_mem #(.LAT_MIN(6), .LAT_MAX(50), .READY_PCT(80), .OOO(1'b1), .NAME("injmem")) mem (
    .clk, .rst,
    .ar_i (m_ar), .ar_valid_i (m_ar_v), .ar_ready_o (m_ar_r),
    .r_o (m_r), .r_valid_o (m_r_v), .r_ready_i (m_r_r),
    .aw_i (m_aw), .aw_valid_i (m_aw_v), .aw_ready_o (m_aw_r),
    .w_i (m_w), .w_valid_i (m_w_v), .w_ready_o (m_w_r),
    .b_o (m_b), .b_valid_o (m_b_v), .b_ready_i (m_b_r)
  );

  // ---- Master model ----
  typedef struct { int id; longint unsigned addr; longint unsigned t; } rd_t;
  rd_t   rd_q[$];          // outstanding reads in issue order
  bit    id_busy_r [16];
  bit    id_busy_w [16];
  longint unsigned aw_t [16];
  longint unsigned wr_lines [$];
  logic [511:0] model [longint unsigned];
  longint unsigned cyc;
  int    beat, errors, n_rd, n_wr, phase, n_beats_window;
  longint unsigned win_start, lat_min_seen, lat_max_seen, lat_sum_seen;
  logic [511:0] rbuf;
  axi_ax_t pend_aw[$];
  logic [511:0] pend_wdata[$];
  int    wbeat;
  int unsigned seed;
  bit    stop_issue;
  int    ar_pct = 30;                    // chance per cycle of a new read

  function automatic logic [511:0] model_line(input longint unsigned l);
    return model.exists(l) ? model[l] : init_line(l);
  endfunction

  task automatic fail(input string m);
    errors++;
    $display("[%0d] ERROR: %s", cyc, m);
    if (errors > 10) begin $display("TEST FAILED"); $finish; end
  endtask

  // Expected delivered latency bounds for a read issued at t0, with native latency nat (to the
  // injector's last-beat arrival). Pipeline overhead: a few cycles (output buffer, beats).
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (rst) begin
      s_ar_v <= 0; s_aw_v <= 0; s_w_v <= 0; s_r_r <= 0; s_b_r <= 0;
      beat = 0; wbeat = 0;
    end else begin
      // ---- handshakes ----
      if (s_ar_v && s_ar_r) begin
        rd_t x;
        x.id = int'(s_ar.id); x.addr = s_ar.addr; x.t = cyc;
        rd_q.push_back(x);
        n_rd++;
      end
      if (s_r_v && s_r_r) begin
        rd_t h;
        h = rd_q[0];
        if (int'(s_r.id) != h.id) fail($sformatf("R burst out of issue order: id %0d, expected %0d", s_r.id, h.id));
        if (s_r.resp != AXI_OKAY) fail("R error");
        rbuf[128*beat +: 128] = s_r.data;
        n_beats_window++;
        if (s_r.last) begin
          longint unsigned lat;
          if (beat != 3) fail("burst length");
          if (rbuf !== model_line(h.addr >> 6)) fail($sformatf("read data mismatch at line %h", h.addr >> 6));
          lat = cyc - h.t;
          if (lat < lat_min_seen) lat_min_seen = lat;
          if (lat > lat_max_seen) lat_max_seen = lat;
          lat_sum_seen += lat;
          // delivered latency must honour the configured delay
          if (mode == 1'b0 && lat < longint'(rd_delay)) fail($sformatf("mode 0: latency %0d below delay %0d", lat, rd_delay));
          if (mode == 1'b0 && rd_delay >= 120 && lat > longint'(rd_delay) + 40)
            fail($sformatf("mode 0: latency %0d well above delay %0d (native at most 50+overhead)", lat, rd_delay));
          if (mode == 1'b1 && lat < longint'(rd_delay) + 6) fail($sformatf("mode 1: latency %0d below native+delay", lat));
          id_busy_r[h.id] = 1'b0;
          void'(rd_q.pop_front());
          beat = 0;
        end else beat++;
      end
      if (s_aw_v && s_aw_r) begin
        aw_t[int'(s_aw.id)] = cyc;
        void'(pend_aw.pop_front());
      end
      if (s_w_v && s_w_r) begin
        if (s_w.last) begin
          wbeat = 0;
          void'(pend_wdata.pop_front());
        end else wbeat++;
      end
      if (s_b_v && s_b_r) begin
        longint unsigned d;
        d = cyc - aw_t[int'(s_b.id)];
        if (mode == 1'b0 && d < longint'(wr_delay)) fail($sformatf("B after %0d cycles, delay %0d", d, wr_delay));
        id_busy_w[int'(s_b.id)] = 1'b0;
        void'(wr_lines.pop_front());
        n_wr++;
      end

      // ---- issue ----
      if (!(s_ar_v && !s_ar_r)) begin           // no AR waiting: maybe present a new one
        s_ar_v <= 1'b0;
        if (!stop_issue && $urandom_range(99) < ar_pct) begin
          int id;
          longint unsigned l;
          bit clash;
          id = int'($urandom_range(15));
          l  = (64'h8000_0000 >> 6) + longint'($urandom_range(255));
          clash = id_busy_r[id];
          foreach (wr_lines[k]) if (wr_lines[k] == l) clash = 1;
          if (!clash) begin
            id_busy_r[id] = 1'b1;
            s_ar   <= '{id: AXI_ID_W'(id), addr: AXI_ADDR_W'(l << 6), len: 8'd3, size: 3'd4, burst: AXI_INCR};
            s_ar_v <= 1'b1;
          end
        end
      end
      if (!stop_issue && phase != 4 && pend_aw.size() == 0 && pend_wdata.size() == 0 && $urandom_range(99) < 8) begin
        int id;
        longint unsigned l;
        bit clash;
        id = int'($urandom_range(15));
        l  = (64'h8000_0000 >> 6) + longint'($urandom_range(255));
        clash = id_busy_w[id] || (s_ar_v && (s_ar.addr >> 6) == l);
        foreach (rd_q[k]) if ((rd_q[k].addr >> 6) == l) clash = 1;
        foreach (wr_lines[k]) if (wr_lines[k] == l) clash = 1;
        if (!clash) begin
          id_busy_w[id] = 1'b1;
          pend_aw.push_back('{id: AXI_ID_W'(id), addr: AXI_ADDR_W'(l << 6), len: 8'd3, size: 3'd4, burst: AXI_INCR});
          pend_wdata.push_back({16{$urandom()}});
          wr_lines.push_back(l);
          model[l] = pend_wdata[$];
        end
      end
      if (pend_aw.size() > 0) begin s_aw <= pend_aw[0]; s_aw_v <= 1'b1; end else s_aw_v <= 1'b0;
      if (pend_wdata.size() > 0 && pend_aw.size() == 0) begin
        s_w <= '{data: pend_wdata[0][128*wbeat +: 128], strb: '1, last: wbeat == 3};
        s_w_v <= 1'b1;
      end else s_w_v <= 1'b0;
      s_r_r <= (phase == 4) ? 1'b1 : ($urandom_range(99) < 85);
      s_b_r <= ($urandom_range(99) < 85);
    end
  end

  task automatic run_phase(input int p, input int cycles, input logic [9:0] rd, input logic [9:0] wr,
                           input logic md, input logic [8:0] bw);
    phase = p; rd_delay = rd; wr_delay = wr; mode = md; bw_rate = bw;
    lat_min_seen = '1; lat_max_seen = 0; lat_sum_seen = 0; n_rd = 0;
    stop_issue = 0;
    repeat (cycles) @(posedge clk);
    stop_issue = 1;
    wait (rd_q.size() == 0 && pend_aw.size() == 0 && pend_wdata.size() == 0 && wr_lines.size() == 0);
    repeat (10) @(posedge clk);
    $display("phase %0d (rd_delay %0d mode %0d bw %0d): %0d reads, latency min %0d avg %0d max %0d", p, rd, md, bw,
             n_rd, lat_min_seen, (n_rd > 0) ? lat_sum_seen / longint'(n_rd) : 0, lat_max_seen);
  endtask

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    cyc = 0; errors = 0; n_wr = 0; phase = 0;
    rd_delay = 0; wr_delay = 0; mode = 0; bw_rate = 0; stop_issue = 1;
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);
    run_phase(0, 4000, 10'd0,   10'd0,   1'b0, 9'd0);    // pass-through
    if (st_cnt == 0) fail("statistics: no reads counted");
    run_phase(1, 6000, 10'd250, 10'd0,   1'b0, 9'd0);    // 250-cycle target latency
    if (lat_min_seen < 250) fail("mode 0 minimum below target");
    run_phase(2, 6000, 10'd120, 10'd0,   1'b1, 9'd0);    // native + 120
    run_phase(3, 6000, 10'd0,   10'd300, 1'b0, 9'd0);    // write responses delayed 300
    // bandwidth cap: 64/256 = 0.25 beats per cycle, reads only, continuously ready
    n_beats_window = 0;
    win_start = cyc;
    run_phase(4, 8000, 10'd0, 10'd0, 1'b0, 9'd64);
    begin
      real rate;
      rate = real'(n_beats_window) / real'(cyc - win_start);
      $display("bandwidth cap: %0d beats in %0d cycles = %f beats/cycle (cap 0.25)", n_beats_window, cyc - win_start, rate);
      if (rate > 0.26) fail("bandwidth cap exceeded");
    end
    // Sparse reads: often one burst in the queue, finishing as the next arrives
    ar_pct = 4;
    run_phase(6, 6000, 10'd0, 10'd0, 1'b0, 9'd0);
    ar_pct = 30;
    // Past a wrap of the injector's 16-bit time stamps (the board found the sum broken there)
    if (cyc < 70000) run_phase(5, 70000 - int'(cyc), 10'd0, 10'd0, 1'b0, 9'd0);
    $display("statistics: %0d reads, latency sum %0d, max %0d (writes %0d)", st_cnt, st_sum, st_max, n_wr);
    if (st_max < 6) fail("statistics: max latency implausible");
    if (st_cnt == 0 || st_sum / st_cnt > 32'(st_max) || st_sum / st_cnt < 6)
      fail($sformatf("statistics: average latency %0d against max %0d", (st_cnt != 0) ? st_sum / st_cnt : 0, st_max));
    if (errors == 0) $display("TEST PASSED (seed %0d)", seed); else $display("TEST FAILED (seed %0d)", seed);
    $finish;
  end
endmodule
