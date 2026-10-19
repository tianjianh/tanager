// The fan's PL regulator (fpga/kv260/rtl/tg_fan.sv; docs/spec/soc.md §8.2, D2) against a SYSMONE4 stand-in and
// an A53 PWM generator: full speed until the first reading; the curve below, inside and above 35-45 C; the
// 1 C hysteresis on the way down; a DRP read that never answers; the larger of the curve's and the A53's
// duty, with the A53's PWM at 50%, held low and held high; the A53's PWM held low but ignored (ignore_ttc_i,
// BOARD_CTRL[0]: D4's RISC-V mode). Each duty is checked from the status word and from fan_en_b's low time over
// whole PWM periods.
module tb_fan;
  logic clk = 1'b0, rst = 1'b1, ttc = 1'b1, ignore = 1'b0;
  always #5 clk = ~clk;                       // 100 MHz
  logic        fan_en_b;
  logic [31:0] status;
  tg_fan #(.CLK_HZ (100_000_000)) dut (.clk, .rst, .ttc_wave_i (ttc), .ignore_ttc_i (ignore), .fan_en_b_o (fan_en_b),
                                       .status_o (status));

  int errors = 0;
  task automatic fail(input string m); errors++; $display("[%0t] ERROR: %s", $time, m); endtask

  // the A53's PWM: 25 kHz (4000 cycles), low for lo of them; lo < 0 holds it high, lo > 4000 low
  int ttc_lo = -1;
  initial forever begin
    if (ttc_lo < 0)          begin ttc = 1'b1; repeat (4000) @(posedge clk); end
    else if (ttc_lo >= 4000) begin ttc = 1'b0; repeat (4000) @(posedge clk); end
    else begin
      ttc = 1'b0; repeat (ttc_lo) @(posedge clk);
      ttc = 1'b1; repeat (4000 - ttc_lo) @(posedge clk);
    end
  end

  function automatic logic [15:0] code_of(input real t);
    return 16'($rtoi((t + 280.2308787) * 65536.0 / 509.3140064));
  endfunction
  // the curve as the spec states it, on a held code
  function automatic int curve(input logic [15:0] c);
    if (c >= 16'd41849) return 255;
    if (c <= 16'd40562) return 15;
    return 15 + ((int'(c) - 40562) * 191) / 1024;
  endfunction

  // fan_en_b's low time over 16 PWM periods (16 x 4096 cycles), in 1/256ths
  task automatic measure(output int duty);
    int lo;
    lo = 0;
    for (int i = 0; i < 16 * 4096; i++) begin @(posedge clk); lo += !fan_en_b; end
    duty = lo / 256;
  endtask
  task automatic reads(input int n);                     // wait for n more DRP reads to complete
    int r0;
    r0 = dut.u_sysmon.reads;
    wait (dut.u_sysmon.reads >= r0 + n);
    repeat (100) @(posedge clk);
  endtask
  // want: the duty, exactly from the curve (tol 0) or within tol of the A53's (the window's edges move its
  // measured duty by about 2/256)
  task automatic expect_duty(input int want, input int tol, input int ttc_want, input string what);
    int got, d;
    repeat (2 * 262144) @(posedge clk);                   // the A53's duty settles over two windows
    d = int'(status[25:18]);
    if (d < want - tol || d > want + tol)
      fail($sformatf("%s: status duty %0d, want %0d +-%0d (TTC %0d, code %h)", what, d, want, tol, status[17:10], dut.code_q));
    if (ttc_want >= 0 && (int'(status[17:10]) < ttc_want - 3 || int'(status[17:10]) > ttc_want + 3))
      fail($sformatf("%s: TTC duty %0d, want %0d +-3", what, status[17:10], ttc_want));
    measure(got);
    if (got < want - tol - 1 || got > want + tol + 1) fail($sformatf("%s: fan_en_b low %0d/256, want %0d", what, got, want));
    else $display("%s: duty %0d (TTC %0d), fan_en_b low %0d/256", what, status[25:18], status[17:10], got);
  endtask

  initial begin
    repeat (20) @(posedge clk);
    rst = 1'b0;
    // until the first reading the fan runs full
    repeat (1000) @(posedge clk);
    if (fan_en_b !== 1'b0 || status[27]) fail("the fan does not run full before the first reading");
    dut.u_sysmon.code = code_of(30.0);
    reads(1);
    if (!status[27]) fail("no reading after the first DRP read");
    expect_duty(15, 0, 0, "30 C, the A53's PWM high");
    dut.u_sysmon.code = code_of(40.0);
    reads(1);
    expect_duty(curve(code_of(40.0)), 0, 0, "40 C");
    // falling by less than 1 C keeps the duty; by more, the curve follows 1 C above the temperature
    dut.u_sysmon.code = code_of(39.4);
    reads(1);
    expect_duty(curve(code_of(40.0)), 0, 0, "39.4 C (within the hysteresis)");
    dut.u_sysmon.code = code_of(38.0);
    reads(1);
    expect_duty(curve(code_of(38.0) + 16'd129), 0, 0, "38 C (below it)");
    dut.u_sysmon.code = code_of(46.0);
    reads(1);
    expect_duty(255, 0, 0, "46 C");
    // the A53's PWM: its duty rules when it asks for more than the curve
    dut.u_sysmon.code = code_of(30.0);
    reads(1);
    ttc_lo = 2000;
    expect_duty(128, 3, 128, "30 C, the A53's PWM at 50%");
    ttc_lo = 400;
    expect_duty(26, 3, 26, "30 C, the A53's PWM at 10%");
    ttc_lo = 4000;
    expect_duty(255, 0, 255, "the A53's PWM held low");
    ignore = 1'b1;                                        // the A53 parked: its dead TTC reads low
    expect_duty(15, 0, 255, "the A53's PWM held low, ignored");
    ignore = 1'b0;
    expect_duty(255, 0, 255, "the A53's PWM held low, heeded again");
    ttc_lo = -1;
    expect_duty(15, 0, 0, "the A53's PWM held high again");
    // a DRP read that never answers: full speed until a reading comes back
    dut.u_sysmon.silent = 1'b1;
    reads(1);
    repeat (70000) @(posedge clk);
    if (!status[26]) fail("no DRP timeout flagged");
    expect_duty(255, 0, 0, "the DRP silent");
    dut.u_sysmon.silent = 1'b0;
    reads(1);
    if (status[26]) fail("the DRP timeout stays flagged after a reading");
    expect_duty(15, 0, 0, "the DRP back");
    if (dut.u_sysmon.bad != 0) fail($sformatf("%0d DRP accesses were not reads of register 00h", dut.u_sysmon.bad));
    if (errors == 0) $display("TEST PASSED (fan, %0d DRP reads)", dut.u_sysmon.reads);
    else $display("TEST FAILED (fan): %0d errors", errors);
    $finish;
  end
endmodule
