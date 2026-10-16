// Unit test of tg_ram_sdp's behavioural model: read-first, byte enables, read latency 1, 2
// and 4 (RD_LAT), with the write port enabled by its byte enables or always (WR_PORT_ON), against a
// reference array.
//   Vtb_ram_sdp +seed=<n> +cycles=<n>
module tb_ram_sdp;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  int seed = 1, cycles = 20000, errors = 0;

  `define TG_SDP(NAME, D, W, BW, LAT, WPO)                                                    \
    localparam int NAME``_AW = $clog2(D);                                                 \
    logic [W/BW-1:0]      NAME``_we;                                                      \
    logic [NAME``_AW-1:0] NAME``_wa, NAME``_ra;                                           \
    logic [W-1:0]         NAME``_wd, NAME``_rd;                                           \
    logic                 NAME``_re;                                                      \
    logic [W-1:0]         NAME``_mem [D];                                                 \
    logic [LAT-1:0][W-1:0] NAME``_exp;                                                    \
    logic [LAT-1:0]        NAME``_v;                                                      \
    tg_ram_sdp #(.DEPTH(D), .WIDTH(W), .BYTE_W(BW), .RD_LAT(LAT), .WR_PORT_ON(WPO)) u_``NAME (\
      .clk, .we(NAME``_we), .waddr(NAME``_wa), .wdata(NAME``_wd), .re(NAME``_re),          \
      .raddr(NAME``_ra), .rdata(NAME``_rd));                                              \
    initial begin                                                                         \
      NAME``_v = '0;                                                                      \
      for (int i = 0; i < D; i++) NAME``_mem[i] = '0;                                     \
    end                                                                                   \
    always @(negedge clk) begin                                                           \
      if (NAME``_v[LAT-1] && NAME``_rd !== NAME``_exp[LAT-1]) begin                       \
        errors++;                                                                         \
        if (errors < 10) $display("ERROR %s: got %h want %h", `"NAME`", NAME``_rd,        \
                                  NAME``_exp[LAT-1]);                                     \
      end                                                                                 \
      NAME``_we = (W/BW)'($urandom);                                                      \
      NAME``_wa = NAME``_AW'($urandom);                                                   \
      NAME``_wd = W'({$urandom, $urandom, $urandom, $urandom});                           \
      NAME``_re = 1'b1;                                                                   \
      NAME``_ra = ($urandom % 4 == 0) ? NAME``_wa : NAME``_AW'($urandom);                 \
    end                                                                                   \
    always @(posedge clk) begin                                                           \
      /* read-first: the read sees the memory before this edge's write */                 \
      NAME``_exp <= {NAME``_exp[LAT-2:0], NAME``_mem[NAME``_ra]};                          \
      NAME``_v   <= {NAME``_v[LAT-2:0], 1'b1};                                            \
      for (int b = 0; b < W/BW; b++)                                                      \
        if (NAME``_we[b]) NAME``_mem[NAME``_wa][b*BW +: BW] <= NAME``_wd[b*BW +: BW];     \
    end

  `TG_SDP(l2, 64, 72, 8, 2, 0)
  `TG_SDP(l4, 128, 64, 64, 4, 0)
  // the write port always enabled, as the L2's data array (byte enables, latency 2 and 4)
  `TG_SDP(l2p, 64, 72, 8, 2, 1)
  `TG_SDP(l4p, 128, 256, 8, 4, 1)

  // Latency 1 uses no shift register
  localparam int A1 = 5;
  logic [7:0] we1;
  logic [A1-1:0] wa1, ra1;
  logic [63:0] wd1, rd1, exp1;
  logic [63:0] mem1 [32];
  logic v1 = 0;
  tg_ram_sdp #(.DEPTH(32), .WIDTH(64), .BYTE_W(8)) u_l1 (
    .clk, .we(we1), .waddr(wa1), .wdata(wd1), .re(1'b1), .raddr(ra1), .rdata(rd1));
  initial for (int i = 0; i < 32; i++) mem1[i] = '0;
  always @(negedge clk) begin
    if (v1 && rd1 !== exp1) begin
      errors++;
      if (errors < 10) $display("ERROR l1: got %h want %h", rd1, exp1);
    end
    we1 = 8'($urandom); wa1 = A1'($urandom); wd1 = {$urandom, $urandom};
    ra1 = ($urandom % 4 == 0) ? wa1 : A1'($urandom);
  end
  always @(posedge clk) begin
    exp1 <= mem1[ra1];
    v1 <= 1'b1;
    for (int b = 0; b < 8; b++) if (we1[b]) mem1[wa1][b*8 +: 8] <= wd1[b*8 +: 8];
  end

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
    repeat (cycles) @(posedge clk);
    if (errors == 0) $display("PASS tb_ram_sdp");
    else $display("FAIL tb_ram_sdp: %0d errors", errors);
    $finish;
  end
endmodule
