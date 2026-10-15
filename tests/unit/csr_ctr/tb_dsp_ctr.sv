// Random test of tg_dsp_ctr (rtl/core/csr): a 64-bit counter with a load that takes effect a
// cycle late (d held in that cycle), and reset, against a reference:
//   q(t+1) = rst(t) ? 0 : ld(t-1) ? d(t) + inc(t) : q(t) + inc(t)
// Loads are biased towards values just below a carry out of bit 47 or a wrap at 2^64, so
// increments cross both; reset comes now and then.
//   +seed=<n> +cycles=<n> ; parameter IW
module tb_dsp_ctr #(
  parameter int IW = 2
);
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic          rst, ld;
  logic [63:0]   d, q;
  logic [IW-1:0] inc;
  tg_dsp_ctr #(.IW(IW)) dut (.clk, .rst, .ld, .d, .inc, .q);
`ifdef TG_SIM_PRIMS
  glbl glbl ();     // the vendor DSP48E2 model's global set/reset
`endif

  // Module-level state (Icarus takes no automatic variables in an initial block)
  int seed = 1, cycles = 20000, errors = 0, nld = 0, nc48 = 0, nwrap = 0, c = 0;
  logic [63:0] ref_q = '0, r, nxt;
  logic        ld_prev = 1'b0;
  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
    rst = 1'b1; ld = 1'b0; d = '0; inc = '0;
`ifdef TG_SIM_PRIMS
    wait (glbl.GSR === 1'b0);
`endif
    @(negedge clk);
    @(negedge clk);
    for (c = 0; c < cycles; c++) begin
      // drive this cycle's inputs
      rst = ($urandom % 2000) == 0;
      ld  = !ld_prev && ($urandom % 40) == 0;      // loads never back to back (tg_csr: a flush follows)
      if (!ld_prev) begin                           // d is held in the cycle after a load
        r = {$urandom, $urandom};
        case ($urandom % 6)
          0:       d = {r[63:48], 48'hFFFF_FFFF_FFFF - 48'(r[2:0])};   // just below a carry out of bit 47
          1:       d = 64'hFFFF_FFFF_FFFF_FFFF - 64'(r[2:0]);          // just below the wrap
          2:       d = '0;
          default: d = r;
        endcase
      end
      inc = IW'($urandom);
      // reference
      if (rst)          nxt = '0;
      else if (ld_prev) nxt = d + 64'(inc);
      else              nxt = ref_q + 64'(inc);
      if (!rst && nxt[63:48] != (ld_prev ? d[63:48] : ref_q[63:48])) nc48++;
      if (!rst && nxt < (ld_prev ? d : ref_q)) nwrap++;
      if (ld) nld++;
      ld_prev = ld;
      @(posedge clk);
      #1;
      ref_q = nxt;
      if (q !== ref_q) begin
        errors++;
        if (errors <= 10) $display("cycle %0d: q %h, expected %h", c, q, ref_q);
      end
      @(negedge clk);
    end
    $display("tb_dsp_ctr IW=%0d: %0d cycles, %0d loads, %0d carries out of bit 47, %0d wraps: %s",
             IW, cycles, nld, nc48, nwrap, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
