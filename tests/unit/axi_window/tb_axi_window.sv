// DRAM window test (docs/spec/uncore-mem.md §Verification): random in- and out-of-range 64-byte
// reads and writes through tg_axi_window into a memory model. Checks that in-range bursts reach
// base + offset with intact data, that out-of-range bursts never appear downstream, and that they
// are answered with SLVERR (reads: all beats; writes: one B after the W beats) and reported once each
// on oob_rd_o/oob_wr_o with their address.
module tb_axi_window;
  import tg_pkg::*, tg_uncore_pkg::*, tb_axi_mem_pkg::*;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;

  localparam logic [39:0] BASE = 40'h8_4000_0000;   // e.g. the top GiB of the KV260's high DDR
  localparam logic [39:0] SIZE = 40'h0010_0000;     // 1 MiB window for the test

  axi_ax_t s_ar, s_aw, m_ar, m_aw;
  axi_r_t  s_r, m_r;
  axi_w_t  s_w, m_w;
  axi_b_t  s_b, m_b;
  logic s_ar_v, s_ar_r, s_r_v, s_r_r, s_aw_v, s_aw_r, s_w_v, s_w_r, s_b_v, s_b_r;
  logic m_ar_v, m_ar_r, m_r_v, m_r_r, m_aw_v, m_aw_r, m_w_v, m_w_r, m_b_v, m_b_r;
  logic oob_rd, oob_wr;
  logic [39:0] oob_addr;

  tg_axi_window dut (
    .clk, .rst, .base_i (BASE), .size_i (SIZE),
    .s_ar_i (s_ar), .s_ar_valid_i (s_ar_v), .s_ar_ready_o (s_ar_r),
    .s_r_o (s_r), .s_r_valid_o (s_r_v), .s_r_ready_i (s_r_r),
    .s_aw_i (s_aw), .s_aw_valid_i (s_aw_v), .s_aw_ready_o (s_aw_r),
    .s_w_i (s_w), .s_w_valid_i (s_w_v), .s_w_ready_o (s_w_r),
    .s_b_o (s_b), .s_b_valid_o (s_b_v), .s_b_ready_i (s_b_r),
    .m_ar_o (m_ar), .m_ar_valid_o (m_ar_v), .m_ar_ready_i (m_ar_r),
    .m_r_i (m_r), .m_r_valid_i (m_r_v), .m_r_ready_o (m_r_r),
    .m_aw_o (m_aw), .m_aw_valid_o (m_aw_v), .m_aw_ready_i (m_aw_r),
    .m_w_o (m_w), .m_w_valid_o (m_w_v), .m_w_ready_i (m_w_r),
    .m_b_i (m_b), .m_b_valid_i (m_b_v), .m_b_ready_o (m_b_r),
    .oob_rd_o (oob_rd), .oob_wr_o (oob_wr), .oob_addr_o (oob_addr)
  );
  tb_axi_mem #(.LAT_MIN(3), .LAT_MAX(30), .OOO(1'b1), .NAME("winmem")) mem (
    .clk, .rst,
    .ar_i (m_ar), .ar_valid_i (m_ar_v), .ar_ready_o (m_ar_r),
    .r_o (m_r), .r_valid_o (m_r_v), .r_ready_i (m_r_r),
    .aw_i (m_aw), .aw_valid_i (m_aw_v), .aw_ready_o (m_aw_r),
    .w_i (m_w), .w_valid_i (m_w_v), .w_ready_o (m_w_r),
    .b_o (m_b), .b_valid_o (m_b_v), .b_ready_i (m_b_r)
  );

  // Downstream monitor: everything must be inside [BASE, BASE + SIZE)
  always @(posedge clk) if (!rst) begin
    if (m_ar_v && m_ar_r) assert (m_ar.addr >= BASE && m_ar.addr + 64 <= BASE + SIZE) else $error("AR leaked: %h", m_ar.addr);
    if (m_aw_v && m_aw_r) assert (m_aw.addr >= BASE && m_aw.addr + 64 <= BASE + SIZE) else $error("AW leaked: %h", m_aw.addr);
  end

  int errors, n_ok_rd, n_err_rd, n_ok_wr, n_err_wr, beat, n_oob_rd, n_oob_wr;
  // the refusal reports: one per out-of-range burst, with its address
  always @(posedge clk) if (!rst) begin
    if (oob_rd) begin
      n_oob_rd++;
      assert (oob_addr == s_ar.addr && !(s_ar.addr >= 40'h8000_0000 && s_ar.addr - 40'h8000_0000 < SIZE))
        else $error("oob_rd for %h (AR %h)", oob_addr, s_ar.addr);
    end
    if (oob_wr) begin
      n_oob_wr++;
      assert (oob_rd || (oob_addr == s_aw.addr && !(s_aw.addr >= 40'h8000_0000 && s_aw.addr - 40'h8000_0000 < SIZE)))
        else $error("oob_wr for %h (AW %h)", oob_addr, s_aw.addr);
    end
  end
  logic [511:0] model [longint unsigned];    // keyed by downstream line
  logic [511:0] rbuf;
  bit   rerr;
  int unsigned seed;

  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s", m);
  endtask

  task automatic do_read(input logic [39:0] a);
    bit inr;
    longint unsigned dl;
    inr = a >= 40'h8000_0000 && a - 40'h8000_0000 < SIZE;
    dl  = (BASE + (a - 40'h8000_0000)) >> 6;
    @(negedge clk);
    s_ar = '{id: 6'd5, addr: a, len: 8'd3, size: 3'd4, burst: AXI_INCR};
    s_ar_v = 1'b1;
    do @(posedge clk); while (!s_ar_r);
    @(negedge clk) s_ar_v = 1'b0;
    beat = 0; rerr = 0;
    s_r_r = 1'b1;
    while (1) begin
      @(posedge clk);
      if (s_r_v) begin
        rbuf[128*beat +: 128] = s_r.data;
        if (s_r.resp != AXI_OKAY) rerr = 1;
        if (s_r.last) break;
        beat++;
      end
    end
    @(negedge clk) s_r_r = 1'b0;
    if (inr) begin
      logic [511:0] want;
      want = model.exists(dl) ? model[dl] : init_line(dl);
      if (rerr) fail($sformatf("in-range read %h answered SLVERR", a));
      else if (rbuf !== want) fail($sformatf("read %h data mismatch", a));
      n_ok_rd++;
    end else begin
      if (!rerr || beat != 3) fail($sformatf("out-of-range read %h: resp ok or wrong beats", a));
      n_err_rd++;
    end
  endtask

  task automatic do_write(input logic [39:0] a, input logic [511:0] d);
    bit inr;
    inr = a >= 40'h8000_0000 && a - 40'h8000_0000 < SIZE;
    @(negedge clk);
    s_aw = '{id: 6'd9, addr: a, len: 8'd3, size: 3'd4, burst: AXI_INCR};
    s_aw_v = 1'b1;
    do @(posedge clk); while (!s_aw_r);
    @(negedge clk) s_aw_v = 1'b0;
    for (int k = 0; k < 4; k++) begin
      s_w = '{data: d[128*k +: 128], strb: '1, last: k == 3};
      s_w_v = 1'b1;
      do @(posedge clk); while (!s_w_r);
      @(negedge clk);
    end
    s_w_v = 1'b0;
    s_b_r = 1'b1;
    do @(posedge clk); while (!s_b_v);
    if (inr) begin
      if (s_b.resp != AXI_OKAY) fail($sformatf("in-range write %h answered SLVERR", a));
      model[(BASE + (a - 40'h8000_0000)) >> 6] = d;
      n_ok_wr++;
    end else begin
      if (s_b.resp != AXI_SLVERR) fail($sformatf("out-of-range write %h not answered SLVERR", a));
      n_err_wr++;
    end
    @(negedge clk) s_b_r = 1'b0;
  endtask

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    errors = 0; n_ok_rd = 0; n_err_rd = 0; n_ok_wr = 0; n_err_wr = 0; n_oob_rd = 0; n_oob_wr = 0;
    s_ar_v = 0; s_aw_v = 0; s_w_v = 0; s_r_r = 0; s_b_r = 0;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    for (int i = 0; i < 2000; i++) begin
      logic [39:0] a;
      int k;
      k = int'($urandom_range(99));
      if (k < 70)       a = 40'h8000_0000 + 40'(($urandom_range(16383)) << 6);           // in range
      else if (k < 85)  a = 40'h8000_0000 + SIZE + 40'(($urandom_range(16383)) << 6);    // above
      else              a = 40'h7FFF_0000 + 40'(($urandom_range(1023)) << 6);            // below DRAM_BASE
      if ($urandom_range(1)) do_read(a);
      else                   do_write(a, {16{$urandom()}});
    end
    if (n_oob_rd != n_err_rd || n_oob_wr != n_err_wr)
      fail($sformatf("refusals reported: %0d reads, %0d writes (want %0d, %0d)", n_oob_rd, n_oob_wr, n_err_rd, n_err_wr));
    $display("window: %0d/%0d reads ok/denied, %0d/%0d writes ok/denied, %0d errors", n_ok_rd, n_err_rd, n_ok_wr, n_err_wr, errors);
    if (errors == 0 && n_err_rd > 0 && n_err_wr > 0) $display("TEST PASSED (seed %0d)", seed);
    else $display("TEST FAILED (seed %0d)", seed);
    $finish;
  end
endmodule
