// Mapping check for tg_ram_lut (plan §8.3): a few shapes with registered I/O, so the
// primitive check and the LUT count can be compared with the formula in tg_ram_lut.sv.
module tg_s0_lutram_top #(
  parameter bit DROP = 1'b0   // 1: leave read port 6 of u_a unused (the check must flag it)
) (
  input  logic              clk,
  input  logic              we,
  input  logic [6:0]        waddr,
  input  logic [63:0]       wdata,
  input  logic [8:0][6:0]   raddr,
  output logic [8:0][63:0]  rdata_a,   // 64 x 64, 7 read ports (a register-file bank)
  output logic [8:0][63:0]  rdata_b,   // 64 x 64, 9 read ports (a 3-ALU bank)
  output logic [2:0][63:0]  rdata_c,   // 32 x 64, 3 read ports
  output logic [1:0][63:0]  rdata_d,   // 128 x 64, 2 read ports
  output logic [12:0]       rdata_e    // 10 x 13, 1 read port (payload-like)
);
  logic              we_q;
  logic [6:0]        waddr_q;
  logic [63:0]       wdata_q;
  logic [8:0][6:0]   raddr_q;
  always_ff @(posedge clk) begin
    we_q <= we; waddr_q <= waddr; wdata_q <= wdata; raddr_q <= raddr;
  end

  logic [6:0][63:0] a;
  logic [8:0][63:0] b;
  logic [2:0][63:0] c;
  logic [1:0][63:0] d;
  logic [0:0][12:0] e;
  logic [6:0][5:0] ra_a;
  logic [8:0][5:0] ra_b;
  logic [2:0][4:0] ra_c;
  logic [1:0][6:0] ra_d;
  logic [0:0][3:0] ra_e;
  for (genvar i = 0; i < 7; i++) begin : g_ra_a
    assign ra_a[i] = raddr_q[i][5:0];
  end
  for (genvar i = 0; i < 9; i++) begin : g_ra_b
    assign ra_b[i] = raddr_q[i][5:0];
  end
  for (genvar i = 0; i < 3; i++) begin : g_ra_c
    assign ra_c[i] = raddr_q[i][4:0];
  end
  for (genvar i = 0; i < 2; i++) begin : g_ra_d
    assign ra_d[i] = raddr_q[i];
  end
  assign ra_e[0] = raddr_q[0][3:0];

  tg_ram_lut #(.DEPTH(64),  .WIDTH(64), .NR(7)) u_a (
    .clk, .we(we_q), .waddr(waddr_q[5:0]), .wdata(wdata_q), .raddr(ra_a), .rdata(a));
  tg_ram_lut #(.DEPTH(64),  .WIDTH(64), .NR(9)) u_b (
    .clk, .we(we_q), .waddr(waddr_q[5:0]), .wdata(wdata_q), .raddr(ra_b), .rdata(b));
  tg_ram_lut #(.DEPTH(32),  .WIDTH(64), .NR(3)) u_c (
    .clk, .we(we_q), .waddr(waddr_q[4:0]), .wdata(wdata_q), .raddr(ra_c), .rdata(c));
  tg_ram_lut #(.DEPTH(128), .WIDTH(64), .NR(2)) u_d (
    .clk, .we(we_q), .waddr(waddr_q), .wdata(wdata_q), .raddr(ra_d), .rdata(d));
  tg_ram_lut #(.DEPTH(10),  .WIDTH(13), .NR(1)) u_e (
    .clk, .we(we_q), .waddr(waddr_q[3:0]), .wdata(wdata_q[12:0]), .raddr(ra_e), .rdata(e));

  always_ff @(posedge clk) begin
    rdata_a <= {128'(0), DROP ? {64'(0), a[5:0]} : a};
    rdata_b <= b;
    rdata_c <= c;
    rdata_d <= d;
    rdata_e <= e[0];
  end
endmodule
