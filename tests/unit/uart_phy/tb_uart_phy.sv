// tg_uart_phy test (docs/spec/uncore-periph.md §UART): 8N1 framing and bit timing on txd against
// the divisor, loopback of random bytes with back-pressure, and a reference serializer driving rxd
// at the nominal baud and 2.5% off it, with a framing error, a glitch and an overrun.
module tb_uart_phy;
  localparam int unsigned CLK_HZ = 100_000_000;
  localparam int unsigned REF_HZ = 3_686_400;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;
  longint unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  logic [15:0] div;
  logic        txv, txr, txbusy, txd, rxv, rxr, rxd, loop, rxd_tb;
  logic [7:0]  txb, rxb;
  assign rxd = loop ? txd : rxd_tb;

  tg_uart_phy #(.CLK_HZ (CLK_HZ), .REF_HZ (REF_HZ)) dut (
    .clk, .rst, .div_i (div),
    .tx_valid_i (txv), .tx_ready_o (txr), .tx_byte_i (txb), .tx_busy_o (txbusy), .txd_o (txd),
    .rxd_i (rxd), .rx_valid_o (rxv), .rx_ready_i (rxr), .rx_byte_o (rxb)
  );

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    if (errors < 20) $display("[%0t] ERROR: %s", $time, m);
  endtask

  // ---- Bit timing on txd: every edge of a character falls a whole number of bit times after its
  // start edge, within one REF_HZ period (the shared REF tick's phase) and rounding ----
  real    bit_cyc;                         // nominal cycles per bit
  longint char_start = 0;
  logic   txd_q = 1'b1;
  int     n_edges = 0;
  always @(posedge clk) if (!rst) begin
    txd_q <= txd;
    if (txv && txr) char_start = cyc + 1;  // the start bit goes out on the next edge
    if (txd != txd_q && txbusy && cyc > char_start) begin
      real d, err;
      d   = real'(cyc - char_start);
      err = d - real'($rtoi(d / bit_cyc + 0.5)) * bit_cyc;
      if (err > real'(CLK_HZ) / real'(REF_HZ) + 2.0 || err < -(real'(CLK_HZ) / real'(REF_HZ) + 2.0))
        fail($sformatf("txd edge %0d cycles into a character: %.2f bits at div %0d", cyc - char_start, d / bit_cyc, div));
      n_edges++;
    end
  end

  // RX back-pressure: brief random stalls, or held low
  logic bp_en = 1'b0, rx_hold = 1'b0;
  always @(posedge clk) rxr <= !rx_hold && (!bp_en || $urandom_range(3) != 0);

  // ---- TX driver: bytes queued by the test go out one per handshake ----
  logic [7:0] txq [$];
  always @(posedge clk) begin
    if (rst) begin
      txv <= 1'b0;
    end else begin
      if (txv && txr) void'(txq.pop_front());
      txv <= txq.size() > 0;
      if (txq.size() > 0) txb <= txq[0];
    end
  end
  task automatic tx_drain();
    while (txq.size() > 0 || txv || txbusy) @(posedge clk);
  endtask

  // ---- Received bytes ----
  logic [7:0] rx_got [$];
  always @(posedge clk) if (!rst && rxv && rxr) rx_got.push_back(rxb);

  // A reference serializer on rxd: one 8N1 character at baud x (1 + skew)
  task automatic ref_send(input logic [7:0] b, input real skew, input logic stop = 1'b1);
    int bc;
    bc = $rtoi(bit_cyc / (1.0 + skew) + 0.5);
    rxd_tb = 1'b0;
    repeat (bc) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_tb = b[i];
      repeat (bc) @(posedge clk);
    end
    rxd_tb = stop;
    repeat (bc) @(posedge clk);
    rxd_tb = 1'b1;
    repeat (bc) @(posedge clk);
  endtask

  task automatic set_div(input int d);
    div     = 16'(d);
    bit_cyc = real'(CLK_HZ) * 16.0 * real'((d == 0) ? 1 : d) / real'(REF_HZ);
    repeat (4) @(posedge clk);
  endtask

  int seed;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    txb = '0; loop = 1'b1; rxd_tb = 1'b1;
    set_div(2);
    repeat (5) @(posedge clk);
    rst = 1'b0;

    // ---- 1. Loopback, random bytes, RX back-pressure, at 115200 (div 2) and 38400 (div 6) ----
    bp_en = 1'b1;
    for (int k = 0; k < 2; k++) begin
      int d;
      logic [7:0] sent [$];
      d = (k == 0) ? 2 : 6;
      set_div(d);
      rx_got.delete();
      sent.delete();
      for (int n = 0; n < 40; n++) begin
        logic [7:0] b;
        b = 8'($urandom);
        sent.push_back(b);
        txq.push_back(b);
      end
      tx_drain();
      repeat ($rtoi(bit_cyc) * 2) @(posedge clk);
      if (rx_got.size() != sent.size()) fail($sformatf("div %0d: %0d bytes sent, %0d received", d, sent.size(), rx_got.size()));
      for (int i = 0; i < sent.size() && i < rx_got.size(); i++)
        if (rx_got[i] != sent[i]) fail($sformatf("div %0d byte %0d: sent %h, received %h", d, i, sent[i], rx_got[i]));
    end
    bp_en = 1'b0;
    if (n_edges < 100) fail($sformatf("only %0d txd edges checked", n_edges));

    // ---- 2. A reference serializer on rxd: nominal baud, 2.5% fast and slow, at div 2 ----
    loop = 1'b0;
    set_div(2);
    rx_got.delete();
    ref_send(8'h55, 0.0);
    ref_send(8'ha3, 0.025);
    ref_send(8'h0f, -0.025);
    ref_send(8'hc6, 0.0, 1'b0);            // framing error: dropped
    ref_send(8'h7e, 0.0);
    rxd_tb = 1'b0; repeat ($rtoi(bit_cyc / 4.0)) @(posedge clk); rxd_tb = 1'b1;   // glitch
    repeat ($rtoi(bit_cyc) * 12) @(posedge clk);
    // overrun: two characters while the UART does not take them, then the first is still there
    rx_hold = 1'b1;
    ref_send(8'h11, 0.0);
    ref_send(8'h22, 0.0);
    repeat (10) @(posedge clk);
    rx_hold = 1'b0;
    repeat (10) @(posedge clk);
    begin
      logic [7:0] want [$];
      want = '{8'h55, 8'ha3, 8'h0f, 8'h7e, 8'h11};
      if (rx_got.size() != want.size()) fail($sformatf("reference RX: %0d bytes, want %0d", rx_got.size(), want.size()));
      for (int i = 0; i < want.size() && i < rx_got.size(); i++)
        if (rx_got[i] != want[i]) fail($sformatf("reference RX byte %0d: %h, want %h", i, rx_got[i], want[i]));
    end

    // ---- 3. Divisor 0 counts as 1 (230400 baud) ----
    loop = 1'b1;
    set_div(0);
    rx_got.delete();
    txq.push_back(8'h9a);
    tx_drain();
    repeat ($rtoi(bit_cyc) * 2) @(posedge clk);
    if (rx_got.size() != 1 || rx_got[0] != 8'h9a) fail("divisor 0: byte not looped back");

    $display("uart_phy: %0d txd edges checked", n_edges);
    if (errors == 0) $display("TEST PASSED (seed %0d)", seed);
    else             $display("TEST FAILED (seed %0d): %0d errors", seed, errors);
    $finish;
  end

  initial begin
    #200ms;
    $display("TEST FAILED: timeout");
    $finish;
  end
endmodule
