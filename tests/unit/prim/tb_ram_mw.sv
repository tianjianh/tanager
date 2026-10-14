// Random test of tg_ram_lut_mw against a reference array: NW writers (with same-address
// collisions, where the highest-numbered writer must win) and NR readers, biased towards
// recently written addresses. Read data is checked just before each rising edge
// (asynchronous read), for addresses written at least once.
//   Vtb_ram_mw +seed=<n> +cycles=<n> ; parameters DEPTH, WIDTH, NW, NR, IMPL, LVT
module tb_ram_mw #(
  parameter int DEPTH = 64,
  parameter int WIDTH = 8,
  parameter int NW    = 2,
  parameter int NR    = 4,
  parameter     IMPL  = "lvt",
  parameter     LVT   = "lutram"
);
  localparam int AW = $clog2(DEPTH);

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic [NW-1:0]            we;
  logic [NW-1:0][AW-1:0]    waddr;
  logic [NW-1:0][WIDTH-1:0] wdata;
  logic [NR-1:0][AW-1:0]    raddr;
  logic [NR-1:0][WIDTH-1:0] rdata;
  tg_ram_lut_mw #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NW(NW), .NR(NR), .IMPL(IMPL), .LVT(LVT)) dut (
    .clk, .wen(we), .waddr, .wdata, .raddr, .rdata);

  logic [WIDTH-1:0] ref_mem [DEPTH];
  logic [DEPTH-1:0] ok = '0;
  always @(posedge clk) begin
    for (int w = 0; w < NW; w++) begin   // ascending: the highest writer's value lands last
      if (we[w]) begin
        ref_mem[waddr[w]] <= wdata[w];
        ok[waddr[w]] <= 1'b1;
      end
    end
  end

  int seed = 1, cycles = 20000, errors = 0, nchk = 0, ncoll = 0, nfresh = 0;
  logic [AW-1:0] recent [8];   // recently written addresses

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
    for (int i = 0; i < 8; i++) recent[i] = AW'($urandom % DEPTH);
    we = '0; waddr = '0; wdata = '0; raddr = '0;
    for (int c = 0; c < cycles; c++) begin
      @(negedge clk);
      for (int r = 0; r < NR; r++) begin
        if (ok[raddr[r]]) begin
          nchk++;
          if (rdata[r] !== ref_mem[raddr[r]]) begin
            errors++;
            if (errors < 10) $display("ERROR cycle %0d port %0d addr %0d: got %h want %h",
                                      c, r, raddr[r], rdata[r], ref_mem[raddr[r]]);
          end
        end
      end
      for (int w = 0; w < NW; w++) begin
        we[w]    = ($urandom % 10) < 6;
        waddr[w] = ($urandom % 4 == 0) ? recent[$urandom % 8] : AW'($urandom % DEPTH);
        wdata[w] = WIDTH'({$urandom, $urandom, $urandom});
      end
      if ($urandom % 5 == 0) begin   // force a collision between two writers
        automatic int x = $urandom % NW, y = $urandom % NW;
        waddr[y] = waddr[x];
        we[x] = 1'b1; we[y] = 1'b1;
        if (x != y) ncoll++;
      end
      for (int w = 0; w < NW; w++) if (we[w]) recent[$urandom % 8] = waddr[w];
      for (int r = 0; r < NR; r++) begin
        raddr[r] = ($urandom % 2) ? recent[$urandom % 8] : AW'($urandom % DEPTH);
        if (raddr[r] == waddr[0] && we[0]) nfresh++;
      end
    end
    if (ncoll < cycles / 20) begin errors++; $display("ERROR few collisions: %0d", ncoll); end
    if (errors == 0) $display("PASS tb_ram_mw %s/%s DEPTH %0d WIDTH %0d NW %0d NR %0d (%0d reads checked, %0d collisions)",
                              IMPL, LVT, DEPTH, WIDTH, NW, NR, nchk, ncoll);
    else $display("FAIL tb_ram_mw: %0d errors", errors);
    $finish;
  end
endmodule
