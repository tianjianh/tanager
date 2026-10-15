// Random test of tg_dsp_reg2 against a reference register: each cycle random en, sel_c, a and c;
// q must equal the reference once both have loaded. Runs on the behavioural model (Verilator) and,
// built with TG_SIM_PRIMS, on the vendor's DSP48E2 simulation model (Icarus).
//   +seed=<n> +cycles=<n> ; parameter W
module tb_dsp_reg #(
  parameter int W = 154
);
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic         en = 1'b0, sel_c = 1'b0;
  logic [W-1:0] a = '0, c = '0, q, ref_q;
  logic         loaded = 1'b0;
  tg_dsp_reg2 #(.W(W)) dut (.clk, .en, .sel_c, .a, .c, .q);
`ifdef TG_SIM_PRIMS
  glbl glbl ();
`endif

  function automatic logic [W-1:0] rnd();
    logic [W+31:0] r;
    r = '0;
    for (int i = 0; i < W; i += 32) r = {r[W-1:0], 32'($urandom)};
    return r[W-1:0];
  endfunction

  int seed, cycles, errors = 0, loads = 0;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 20000;
    void'($urandom(seed));
    #200;                                  // past the model's global set/reset (100 ns)
    for (int n = 0; n < cycles; n++) begin
      @(negedge clk);
      if (loaded && q !== ref_q) begin
        errors++;
        if (errors < 10) $display("ERROR cycle %0d: q %h, expected %h", n, q, ref_q);
      end
      en    = ($urandom % 10) < 7;
      sel_c = $urandom % 2;
      a     = rnd();
      c     = rnd();
      @(posedge clk);
      if (en) begin
        ref_q  = sel_c ? c : a;
        loaded = 1'b1;
        loads++;
      end
    end
    if (errors == 0 && loads > cycles / 2) $display("PASS (W %0d, %0d loads)", W, loads);
    else $display("FAIL (W %0d): %0d errors, %0d loads", W, errors, loads);
    $finish;
  end
endmodule
