// The PS window alone (rtl/uncore/ps/tg_ps_window.sv; docs/spec/soc.md §8.2, docs/spec/soc-d4-modes.md), with
// TIMEOUT_LOG2 = 6, against a PS model whose answers the test sets: the cycle-exact cases tb_soc can't place.
//   1. BOARD_CTRL[1] clear (rst_en_i 0): RESET_CTRL denied, a reset request ignored, other accesses as before.
//   2. Set: RESET_CTRL passes, that word alone (a doubleword and its neighbours denied).
//   3. A reset request: one write of SOFT_RESET (RESET_CTRL, 4 bytes, the upper half's strobes), fired, no error, and
//      no second write while the request stays up.
//   4. rst_en_i cleared: fired and the error clear.
//   5. The request and an access in the same idle cycle: the reset write goes out, the access is denied at once;
//      an error answer sets the error flag.
//   6. An access while the reset write waits for its answer: denied at once, no transaction.
//   7. No answer: the error flag after the timeout (one timeout pulse), accesses denied while the late answer is
//      outstanding, then taken, and the window works again.
//   8. rst_en_i cleared while the write is open: the flags stay until it ends, then clear.
module tb_ps_window;
  import tg_pkg::*, tg_uncore_pkg::*;

  localparam logic [31:0] RESET_CTRL = 32'hFF5E_0218, UART1 = 32'hFF01_0000;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;

  dev_req_t req = '0;
  logic     req_v = 1'b0;
  dev_rsp_t rsp;
  logic     wt;
  axi_ax_t  aw, ar;
  axi_w_t   w;
  axi_b_t   b = '0;
  axi_r_t   r = '0;
  logic     awv, awr = 1'b0, wv, wr = 1'b0, bv = 1'b0, br, arv, arr = 1'b0, rv = 1'b0, rr;
  logic     tmo, en = 1'b0, rq = 1'b0, fired, err;

  tg_ps_window #(.TIMEOUT_LOG2 (6)) dut (
    .clk, .rst, .req_i (req), .req_valid_i (req_v), .rsp_o (rsp), .wait_o (wt),
    .m_aw_o (aw), .m_aw_valid_o (awv), .m_aw_ready_i (awr), .m_w_o (w), .m_w_valid_o (wv), .m_w_ready_i (wr),
    .m_b_i (b), .m_b_valid_i (bv), .m_b_ready_o (br), .m_ar_o (ar), .m_ar_valid_o (arv), .m_ar_ready_i (arr),
    .m_r_i (r), .m_r_valid_i (rv), .m_r_ready_o (rr), .timeout_o (tmo),
    .rst_en_i (en), .rst_req_i (rq), .rst_fired_o (fired), .rst_err_o (err)
  );

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("[%0t] ERROR: %s", $time, m);
  endtask

  // ---- the PS: one transaction at a time; a write's answer after lat_b cycles, held while b_hold ----
  int          lat_b = 3;
  bit          b_hold = 1'b0;
  logic [1:0]  b_resp = AXI_OKAY;
  axi_ax_t     log_aw [$];
  axi_w_t      log_w [$];
  axi_ax_t     log_ar [$];
  int          tmo_pulses = 0;
  always @(posedge clk) if (tmo) tmo_pulses++;
  initial forever begin
    @(posedge clk);
    if (awv && wv) begin
      repeat (1) @(posedge clk);
      awr <= 1'b1; wr <= 1'b1;
      @(posedge clk);
      awr <= 1'b0; wr <= 1'b0;
      log_aw.push_back(aw);
      log_w.push_back(w);
      repeat (lat_b) @(posedge clk);
      while (b_hold) @(posedge clk);
      b <= '{id: aw.id, resp: b_resp};
      bv <= 1'b1;
      do @(posedge clk); while (!br);
      bv <= 1'b0;
    end else if (arv) begin
      @(posedge clk);
      arr <= 1'b1;
      @(posedge clk);
      arr <= 1'b0;
      log_ar.push_back(ar);
      repeat (2) @(posedge clk);
      r <= '{id: ar.id, data: {64'h1111_2222_3333_4444, 64'h5555_6666_7777_8888}, resp: AXI_OKAY, last: 1'b1};
      rv <= 1'b1;
      do @(posedge clk); while (!rr);
      rv <= 1'b0;
    end
  end

  // ---- the device bus: one access, its answer at the first cycle without wait ----
  task automatic acc(input logic [31:0] a, input bit we, input logic [1:0] size, output bit e);
    @(negedge clk);
    req = '0;
    req.addr = PA_W'(a);
    req.we = we;
    req.size = size;
    req.wdata = 64'h0000_0010_0000_0010;
    req.be = (size == 2'd3) ? 8'hFF : (size == 2'd2) ? 8'h0F : (size == 2'd1) ? 8'h03 : 8'h01;
    req_v = 1'b1;
    @(negedge clk);
    req_v = 1'b0;
    while (wt) @(negedge clk);
    e = rsp.err;
  endtask
  task automatic expect_acc(input logic [31:0] a, input bit we, input logic [1:0] size, input bit want_err,
                            input string what);
    bit e;
    int naw, nar;
    naw = log_aw.size(); nar = log_ar.size();
    acc(a, we, size, e);
    repeat (2) @(posedge clk);
    if (e != want_err) fail($sformatf("%s: err %0d, want %0d", what, e, want_err));
    if (want_err && (log_aw.size() != naw || log_ar.size() != nar)) fail($sformatf("%s: denied, but a transaction went out", what));
    if (!want_err && log_aw.size() + log_ar.size() != naw + nar + 1) fail($sformatf("%s: no transaction", what));
  endtask
  // the last write is the reset write: RESET_CTRL, 4 bytes, the beat's upper half, SOFT_RESET
  task automatic check_reset_write(input string what);
    axi_ax_t a;
    axi_w_t  d;
    a = log_aw[$];
    d = log_w[$];
    if (a.addr != AXI_ADDR_W'(RESET_CTRL) || a.size != 3'd2 || a.len != 8'd0 || a.burst != AXI_INCR ||
        d.strb != 16'h0F00 || d.data[95:64] != 32'h10 || !d.last)
      fail($sformatf("%s: write %h size %0d len %0d strb %h data %h", what, a.addr, a.size, a.len, d.strb, d.data));
  endtask
  task automatic settle(input int n);
    repeat (n) @(posedge clk);
  endtask

  initial begin
    bit e;
    int n;
    repeat (5) @(posedge clk);
    rst = 1'b0;
    settle(3);

    // 1. rst_en_i clear
    expect_acc(RESET_CTRL, 1'b1, 2'd2, 1'b1, "1: RESET_CTRL with the reset path off");
    expect_acc(RESET_CTRL, 1'b0, 2'd2, 1'b1, "1: RESET_CTRL read with the reset path off");
    n = log_aw.size();
    @(negedge clk) rq = 1'b1;
    settle(100);
    if (log_aw.size() != n || fired || err) fail("1: a reset request with the reset path off did something");
    @(negedge clk) rq = 1'b0;
    expect_acc(UART1, 1'b1, 2'd2, 1'b0, "1: UART1 write");
    expect_acc(UART1, 1'b0, 2'd2, 1'b0, "1: UART1 read");

    // 2. rst_en_i set: RESET_CTRL alone
    @(negedge clk) en = 1'b1;
    expect_acc(RESET_CTRL, 1'b1, 2'd2, 1'b0, "2: RESET_CTRL write");
    if (log_aw[$].addr != AXI_ADDR_W'(RESET_CTRL) || log_w[$].strb != 16'h0F00) fail("2: the access's write");
    expect_acc(RESET_CTRL, 1'b0, 2'd2, 1'b0, "2: RESET_CTRL read");
    expect_acc(RESET_CTRL, 1'b1, 2'd3, 1'b1, "2: a doubleword at RESET_CTRL");
    expect_acc(RESET_CTRL + 4, 1'b0, 2'd2, 1'b1, "2: CRL_APB + 0x21c");
    expect_acc(RESET_CTRL - 4, 1'b0, 2'd2, 1'b1, "2: CRL_APB + 0x214");
    if (fired || err) fail("2: accesses set the reset write's flags");

    // 3. a reset request
    n = log_aw.size();
    @(negedge clk) rq = 1'b1;
    settle(30);
    if (log_aw.size() != n + 1) fail($sformatf("3: %0d reset writes, want 1", log_aw.size() - n));
    else check_reset_write("3");
    if (!fired || err) fail($sformatf("3: fired %0d err %0d, want 1 0", fired, err));
    settle(200);
    if (log_aw.size() != n + 1) fail("3: a second reset write while the request stays up");

    // 4. rst_en_i cleared: the flags clear
    @(negedge clk) begin en = 1'b0; rq = 1'b0; end
    settle(2);
    if (fired || err) fail("4: the flags stay with the reset path off");

    // 5. the request and an access in the same idle cycle
    @(negedge clk) en = 1'b1;
    settle(2);
    b_resp = AXI_SLVERR;
    n = log_aw.size();
    @(negedge clk);
    req = '0;
    req.addr = PA_W'(UART1);
    req.we = 1'b1;
    req.size = 2'd2;
    req.be = 8'h0F;
    req_v = 1'b1;
    rq = 1'b1;
    @(negedge clk);
    req_v = 1'b0;
    if (wt) fail("5: the access waits instead of being denied");
    if (!rsp.err) fail("5: the access isn't denied");
    if (!awv || aw.addr != AXI_ADDR_W'(RESET_CTRL)) fail("5: the reset write isn't the transaction that went out");
    settle(30);
    if (log_aw.size() != n + 1) fail($sformatf("5: %0d writes, want 1 (the reset write)", log_aw.size() - n));
    else check_reset_write("5");
    if (!fired || !err) fail($sformatf("5: fired %0d err %0d after an error answer, want 1 1", fired, err));
    @(negedge clk) begin en = 1'b0; rq = 1'b0; end
    settle(2);
    b_resp = AXI_OKAY;

    // 6. an access while the reset write waits for its answer
    b_hold = 1'b1;
    @(negedge clk) begin en = 1'b1; rq = 1'b1; end
    settle(10);
    n = log_aw.size();
    expect_acc(UART1, 1'b0, 2'd2, 1'b1, "6: an access during the reset write");
    expect_acc(UART1, 1'b1, 2'd2, 1'b1, "6: another");
    if (log_aw.size() != n) fail("6: a new write during the reset write");
    b_hold = 1'b0;
    settle(20);
    if (!fired || err) fail("6: the flags after the answer");
    @(negedge clk) begin en = 1'b0; rq = 1'b0; end
    settle(2);

    // 7. no answer: the timeout, accesses denied while it is late, then taken
    b_hold = 1'b1;
    n = tmo_pulses;
    @(negedge clk) begin en = 1'b1; rq = 1'b1; end
    settle(60);
    if (err) fail("7: the error before the timeout");
    settle(20);
    if (!err || !fired) fail("7: no error after the timeout");
    if (tmo_pulses != n + 1) fail($sformatf("7: %0d timeout pulses, want 1", tmo_pulses - n));
    expect_acc(UART1, 1'b0, 2'd2, 1'b1, "7: an access while the late answer is outstanding");
    b_hold = 1'b0;
    settle(20);
    @(negedge clk) begin en = 1'b0; rq = 1'b0; end
    settle(2);
    expect_acc(UART1, 1'b0, 2'd2, 1'b0, "7: an access after the late answer");

    // 8. rst_en_i cleared while the write is open
    b_hold = 1'b1;
    @(negedge clk) begin en = 1'b1; rq = 1'b1; end
    settle(10);
    @(negedge clk) begin en = 1'b0; rq = 1'b0; end
    settle(5);
    if (!fired) fail("8: fired cleared while the write is open");
    b_hold = 1'b0;
    settle(20);
    if (fired || err) fail("8: the flags stay after the write ended with the reset path off");

    if (errors == 0) $display("TEST PASSED (ps_window: %0d writes, %0d reads)", log_aw.size(), log_ar.size());
    else $display("TEST FAILED (ps_window): %0d errors", errors);
    $finish;
  end

  initial begin
    #1ms;
    $display("TEST FAILED: timeout");
    $finish;
  end
endmodule
