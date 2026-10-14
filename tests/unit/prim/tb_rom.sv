// Test of tg_rom: every address reads its INIT entry RD_LAT cycles later, and the output
// holds while the read enable is low.
//   Vtb_rom +seed=<n> +cycles=<n> ; parameters DEPTH, WIDTH, PRIM, RD_LAT
module tb_rom #(
  parameter int DEPTH  = 2048,
  parameter int WIDTH  = 9,
  parameter     PRIM   = "block",
  parameter int RD_LAT = 2
);
  localparam int AW = $clog2(DEPTH);
  typedef logic [WIDTH-1:0] word_t;

  function automatic word_t entry(input int i);
    logic [63:0] x = 64'(i) * 64'h9E37_79B9_7F4A_7C15;
    return word_t'(x ^ (x >> 29));
  endfunction
  typedef word_t rom_t [DEPTH];
  function automatic rom_t contents();
    rom_t r;
    for (int i = 0; i < DEPTH; i++) r[i] = entry(i);
    return r;
  endfunction
  localparam rom_t INIT = contents();

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic re;
  logic [AW-1:0] raddr;
  word_t rdata;
  tg_rom #(.DEPTH(DEPTH), .WIDTH(WIDTH), .PRIM(PRIM), .RD_LAT(RD_LAT), .INIT(INIT)) dut (.*);

  initial begin
    int seed = 1, cycles = 20000, errors = 0, nread = 0;
    word_t pipe [$];   // expected outputs, oldest first
    word_t held = 'x;
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
    re = 1'b0; raddr = '0;
    for (int c = 0; c < cycles; c++) begin
      @(negedge clk);
      // the value expected now: the read issued RD_LAT cycles ago
      if (pipe.size() == RD_LAT) begin
        automatic word_t want = pipe.pop_front();
        if (want !== 'x && rdata !== want) begin
          errors++;
          if (errors < 10) $display("ERROR cycle %0d: rdata %h, expected %h", c, rdata, want);
        end
      end
      re = ($urandom % 4) != 0;
      raddr = AW'($urandom % DEPTH);
      if (re) begin held = INIT[raddr]; nread++; end
      pipe.push_back(held);
    end
    if (errors == 0) $display("PASS tb_rom %s DEPTH %0d WIDTH %0d RD_LAT %0d (%0d reads)",
                              PRIM, DEPTH, WIDTH, RD_LAT, nread);
    else $display("FAIL tb_rom: %0d errors", errors);
    $finish;
  end
endmodule
