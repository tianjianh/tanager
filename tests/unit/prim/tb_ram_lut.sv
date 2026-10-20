// Unit test of tg_ram_lut: random writes and reads on several shapes, against a reference
// array. Built twice by the Makefile: with the behavioural model and with the primitive
// mapping (TG_SIM_PRIMS plus the primitive models in models/).
//   obj/Vtb_ram_lut +seed=<n> +cycles=<n>
module tb_ram_lut;
  logic clk = 1'b0;
  int   seed = 1, cycles = 20000, errors = 0;
  always #5 clk = ~clk;

  // One shape under test: DEPTH x WIDTH with NR read ports, random traffic, compare.
  // Read data is checked combinationally just before each rising edge (asynchronous read).
  `define TG_SHAPE(NAME, D, W, R)                                                         \
    localparam int NAME``_AW = (D > 1) ? $clog2(D) : 1;                                   \
    logic                      NAME``_we;                                                 \
    logic [NAME``_AW-1:0]      NAME``_wa;                                                 \
    logic [W-1:0]              NAME``_wd;                                                 \
    logic [R-1:0][NAME``_AW-1:0] NAME``_ra;                                               \
    logic [R-1:0][W-1:0]       NAME``_rd;                                                 \
    logic [W-1:0]              NAME``_ref [D];                                            \
    logic [D-1:0]              NAME``_ok = '0;                                            \
    tg_ram_lut #(.DEPTH(D), .WIDTH(W), .NR(R)) u_``NAME (                                \
      .clk, .we(NAME``_we), .waddr(NAME``_wa), .wdata(NAME``_wd),                         \
      .raddr(NAME``_ra), .rdata(NAME``_rd));                                              \
    always @(negedge clk) begin                                                           \
      for (int r = 0; r < R; r++) begin                                                   \
        if (NAME``_ok[NAME``_ra[r]] && NAME``_rd[r] !== NAME``_ref[NAME``_ra[r]]) begin   \
          errors++;                                                                       \
          if (errors < 10) $display("ERROR %s port %0d addr %0d: got %h want %h",        \
            `"NAME`", r, NAME``_ra[r], NAME``_rd[r], NAME``_ref[NAME``_ra[r]]);           \
        end                                                                               \
      end                                                                                 \
      NAME``_we = ($urandom % 3) != 0;                                                    \
      NAME``_wa = NAME``_AW'($urandom % D);                                               \
      NAME``_wd = W'({$urandom, $urandom, $urandom, $urandom});                          \
      for (int r = 0; r < R; r++) NAME``_ra[r] = NAME``_AW'($urandom % D);               \
    end                                                                                   \
    always @(posedge clk) begin                                                           \
      if (NAME``_we) begin                                                                \
        NAME``_ref[NAME``_wa] <= NAME``_wd;                                               \
        NAME``_ok[NAME``_wa] <= 1'b1;                                                     \
      end                                                                                 \
    end

  `TG_SHAPE(rf7,  64, 64, 7)    // integer register-file bank, 2-ALU build
  `TG_SHAPE(rf9,  64, 64, 9)    // 3-ALU bank, read ports beyond 7
  `TG_SHAPE(m32,  32, 64, 3)
  `TG_SHAPE(odd,  24, 13, 5)    // odd width on RAM32M16
  `TG_SHAPE(deep, 200, 33, 2)   // banks of 64
  `TG_SHAPE(fp96, 96, 64, 4)    // 96 entries, DR-175's smt2 FP bank: RAM64M8 and RAM32M16
  `TG_SHAPE(o96,  96, 13, 7)    // the same with an odd width and a full primitive of slots
  `TG_SHAPE(d65,  65, 9, 3)     // the 96 form's smallest depth
  `TG_SHAPE(d97,  97, 8, 2)     // just above it: banks of 64
  `TG_SHAPE(tiny, 10, 7, 1)

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    $display("tb_ram_lut: seed %0d cycles %0d", seed, cycles);
    void'($urandom(seed));
    repeat (cycles) @(posedge clk);
    if (errors == 0) $display("PASS tb_ram_lut");
    else $display("FAIL tb_ram_lut: %0d errors", errors);
    $finish;
  end
endmodule
