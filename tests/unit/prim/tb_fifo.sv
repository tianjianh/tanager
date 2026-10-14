// Random test of tg_fifo against a queue model: data order, count, in_ready and out_valid,
// with pushes and pops at random rates (full and empty both happen), for one STORAGE.
//   Vtb_fifo +seed=<n> +cycles=<n> ; parameters STORAGE, DEPTH
module tb_fifo #(
  parameter      STORAGE = "lutram",
  parameter int  DEPTH   = 4
);
  typedef logic [36:0] data_t;   // an odd width: RAM32M16 slots are 2 bits wide
  localparam int AW = $clog2(DEPTH);

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;

  logic in_valid, in_ready, out_valid, out_ready;
  data_t in_data, out_data;
  logic [AW:0] count;
  tg_fifo #(.T(data_t), .DEPTH(DEPTH), .STORAGE(STORAGE)) dut (.*);

  data_t q [$];
  int errors = 0, npush = 0, npop = 0, nfull = 0;

  initial begin
    int seed = 1, cycles = 20000;
    int pin, pout;
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
    in_valid = 1'b0; out_ready = 1'b0; in_data = '0;
    repeat (3) @(posedge clk);
    @(negedge clk) rst = 1'b0;
    for (int c = 0; c < cycles; c++) begin
      // phases with different push and pop rates, so the FIFO fills and drains
      if (c % 500 == 0) begin
        pin  = 1 + $urandom % 9;
        pout = 1 + $urandom % 9;
      end
      @(negedge clk);
      in_valid  = ($urandom % 10) < pin;
      in_data   = data_t'({$urandom, $urandom});
      out_ready = ($urandom % 10) < pout;
      #1;
      if (int'(count) != q.size()) begin
        errors++;
        if (errors < 10) $display("ERROR cycle %0d: count %0d, model %0d", c, count, q.size());
      end
      if (in_ready != (q.size() < DEPTH) || out_valid != (q.size() > 0)) begin
        errors++;
        if (errors < 10) $display("ERROR cycle %0d: in_ready %b out_valid %b, model size %0d",
                                  c, in_ready, out_valid, q.size());
      end
      if (out_valid && out_data !== q[0]) begin
        errors++;
        if (errors < 10) $display("ERROR cycle %0d: out %h, model %h", c, out_data, q[0]);
      end
      @(posedge clk);
      if (out_valid && out_ready) begin void'(q.pop_front()); npop++; end
      if (in_valid && in_ready) begin q.push_back(in_data); npush++; end
      if (!in_ready) nfull++;
    end
    if (nfull == 0) begin errors++; $display("ERROR the FIFO never filled"); end
    if (errors == 0) $display("PASS tb_fifo %s DEPTH %0d (%0d pushes, %0d pops, %0d full cycles)",
                              STORAGE, DEPTH, npush, npop, nfull);
    else $display("FAIL tb_fifo %s DEPTH %0d: %0d errors", STORAGE, DEPTH, errors);
    $finish;
  end
endmodule
