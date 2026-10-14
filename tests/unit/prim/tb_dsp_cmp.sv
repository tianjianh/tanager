// Random test of tg_dsp_cmp: eq and lt LAT cycles after the operands, against a reference.
// Operands are biased towards equal values, neighbours and the ends of the range, and with
// LAT = 2 random stalls (ce low) hold the DSP's operand registers.
//   Vtb_dsp_cmp +seed=<n> +cycles=<n> ; parameters W, SIGNED, LAT
module tb_dsp_cmp #(
  parameter int W      = 32,
  parameter bit SIGNED = 1'b0,
  parameter int LAT    = 1
);
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic         ce;
  logic [W-1:0] a, b;
  logic         eq, lt;
  tg_dsp_cmp #(.W(W), .SIGNED(SIGNED), .LAT(LAT)) dut (.*);
`ifdef TG_SIM_PRIMS
  // The vendor's DSP48E2 simulation model (built with TG_SIM_PRIMS) reads its global
  // set/reset from a top-level glbl instance, found by upward name resolution.
  glbl glbl ();
`endif

  function automatic logic [W-1:0] pick(input logic [W-1:0] other);
    logic [63:0] r;
    r = {$urandom, $urandom};
    case ($urandom % 8)
      0, 1:    return other;                        // equal
      2:       return other + 1'b1;                 // neighbours
      3:       return other - 1'b1;
      4:       return ($urandom % 2) ? '0 : '1;     // ends of the range
      5:       return {1'b1, {(W - 1){1'b0}}};      // most negative when signed
      default: return W'(r);
    endcase
  endfunction

  function automatic logic ref_lt(input logic [W-1:0] x, input logic [W-1:0] y);
    if (SIGNED) return $signed(x) < $signed(y);
    return x < y;
  endfunction

  // Module-level state (the test also runs on Icarus, for the vendor DSP48E2 model, and
  // Icarus does not take automatic variables in an initial block).
  int seed = 1, cycles = 20000, errors = 0, neq = 0, nlt = 0, nstall = 0;
  logic [1:0] want [$];       // {eq, lt} of each issued compare, oldest first
  logic [1:0] w;
  logic [W-1:0] ha = '0, hb = '0, t;   // ha, hb: the DSP's operand registers (LAT = 2)

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
    ce = 1'b1; a = '0; b = '0;
`ifdef TG_SIM_PRIMS
    wait (glbl.GSR === 1'b0);   // the model's power-on global reset
`endif
    for (int c = 0; c < cycles; c++) begin
      @(negedge clk);
      // result due now: the compare issued LAT cycles ago
      if (want.size() == LAT) begin
        w = want.pop_front();
        // lt is undefined for 48-bit signed operands (tg_dsp_cmp's header)
        if (W == 48 && SIGNED) w[0] = lt;
        if (c > LAT + 1 && {eq, lt} !== w) begin
          errors++;
          if (errors < 10) $display("ERROR cycle %0d: eq %b lt %b, expected eq %b lt %b",
                                    c, eq, lt, w[1], w[0]);
        end
      end
      a = W'({$urandom, $urandom});
      b = pick(a);
      if ($urandom % 2) begin t = a; a = b; b = t; end
      ce = (LAT == 1) || ($urandom % 5) != 0;
      if (LAT == 2) begin
        // the DSP compares what its operand registers hold after this edge
        if (ce) begin ha = a; hb = b; end else nstall++;
        want.push_back({ha == hb, ref_lt(ha, hb)});
      end else begin
        want.push_back({a == b, ref_lt(a, b)});
      end
      if (a == b) neq++;
      if (ref_lt(a, b)) nlt++;
    end
    if (neq < cycles / 10 || nlt < cycles / 10) begin
      errors++;
      $display("ERROR poor coverage: %0d equal, %0d less-than", neq, nlt);
    end
    if (errors == 0) $display("PASS tb_dsp_cmp W %0d SIGNED %0d LAT %0d (%0d equal, %0d less, %0d stalls)",
                              W, SIGNED, LAT, neq, nlt, nstall);
    else $display("FAIL tb_dsp_cmp: %0d errors", errors);
    $finish;
  end
endmodule
