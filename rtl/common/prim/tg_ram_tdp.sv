// True dual-port block memory: two read/write ports, one clock (e.g. an L1D way:
// port A for loads, port B for refills and stores; plan §4.11).
// Each port is read-first. Writes from both ports to the same address in the same
// cycle are undefined; the user prevents them.
// Synthesis maps it with xpm_memory_tdpram; simulation uses the behavioural model.
module tg_ram_tdp #(
  parameter int    DEPTH   = 512,
  parameter int    WIDTH   = 64,
  parameter int    BYTE_W  = WIDTH,
  parameter bit    OUT_REG = 1'b0,
  parameter        PRIM    = "block",   // untyped: XPM compares it with integers too
  parameter int    RD_LAT  = OUT_REG ? 2 : 1,   // read latency; see tg_ram_sdp
  localparam int   AW      = (DEPTH > 1) ? $clog2(DEPTH) : 1,
  localparam int   NWE     = WIDTH / BYTE_W
) (
  input  logic               clk,
  input  logic               en_a,
  input  logic [NWE-1:0]     we_a,
  input  logic [AW-1:0]      addr_a,
  input  logic [WIDTH-1:0]   wdata_a,
  output logic [WIDTH-1:0]   rdata_a,
  input  logic               en_b,
  input  logic [NWE-1:0]     we_b,
  input  logic [AW-1:0]      addr_b,
  input  logic [WIDTH-1:0]   wdata_b,
  output logic [WIDTH-1:0]   rdata_b
);
`ifdef SYNTHESIS
  xpm_memory_tdpram #(
    .ADDR_WIDTH_A        (AW),
    .ADDR_WIDTH_B        (AW),
    .BYTE_WRITE_WIDTH_A  (BYTE_W),
    .BYTE_WRITE_WIDTH_B  (BYTE_W),
    .CLOCKING_MODE       ("common_clock"),
    .MEMORY_INIT_FILE    ("none"),
    .MEMORY_PRIMITIVE    (PRIM),
    .MEMORY_SIZE         (DEPTH * WIDTH),
    .READ_DATA_WIDTH_A   (WIDTH),
    .READ_DATA_WIDTH_B   (WIDTH),
    .READ_LATENCY_A      (RD_LAT),
    .READ_LATENCY_B      (RD_LAT),
    .USE_MEM_INIT        (0),
    .WRITE_DATA_WIDTH_A  (WIDTH),
    .WRITE_DATA_WIDTH_B  (WIDTH),
    .WRITE_MODE_A        ("read_first"),
    .WRITE_MODE_B        ("read_first")
  ) u_mem (
    .clka (clk), .rsta (1'b0), .ena (en_a), .regcea (1'b1), .wea (we_a), .addra (addr_a),
    .dina (wdata_a), .douta (rdata_a),
    .clkb (clk), .rstb (1'b0), .enb (en_b), .regceb (1'b1), .web (we_b), .addrb (addr_b),
    .dinb (wdata_b), .doutb (rdata_b),
    .sleep (1'b0),
    .injectsbiterra (1'b0), .injectdbiterra (1'b0), .injectsbiterrb (1'b0), .injectdbiterrb (1'b0),
    .sbiterra (), .dbiterra (), .sbiterrb (), .dbiterrb ()
  );
`else
  logic [WIDTH-1:0] mem [DEPTH];
  logic [WIDTH-1:0] rd_a_q, rd_b_q;

  always_ff @(posedge clk) begin
    if (en_a) begin
      rd_a_q <= mem[addr_a];
      for (int b = 0; b < NWE; b++)
        if (we_a[b]) mem[addr_a][b*BYTE_W +: BYTE_W] <= wdata_a[b*BYTE_W +: BYTE_W];
    end
    if (en_b) begin
      rd_b_q <= mem[addr_b];
      for (int b = 0; b < NWE; b++)
        if (we_b[b]) mem[addr_b][b*BYTE_W +: BYTE_W] <= wdata_b[b*BYTE_W +: BYTE_W];
    end
  end

  if (RD_LAT > 1) begin : g_oreg
    logic [RD_LAT-2:0][WIDTH-1:0] out_a_q, out_b_q;
    always_ff @(posedge clk) begin
      out_a_q[0] <= rd_a_q;
      out_b_q[0] <= rd_b_q;
      for (int i = 1; i < RD_LAT - 1; i++) begin
        out_a_q[i] <= out_a_q[i-1];
        out_b_q[i] <= out_b_q[i-1];
      end
    end
    assign rdata_a = out_a_q[RD_LAT-2];
    assign rdata_b = out_b_q[RD_LAT-2];
  end else begin : g_noreg
    assign rdata_a = rd_a_q;
    assign rdata_b = rd_b_q;
  end
`endif
endmodule
