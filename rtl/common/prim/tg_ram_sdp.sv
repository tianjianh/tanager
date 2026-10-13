// Simple dual-port block memory: one write port, one synchronous read port, one clock.
// Read-during-write to the same address returns the old data (read-first).
// Synthesis maps it with xpm_memory_sdpram; simulation uses the behavioural model.
//   BYTE_W:  write-enable granularity in bits (WIDTH = no byte enables).
//   OUT_REG: 1 adds the output register (read latency 2 instead of 1).
//   PRIM:    "block", "ultra", "distributed" or "auto".
module tg_ram_sdp #(
  parameter int    DEPTH   = 512,
  parameter int    WIDTH   = 64,
  parameter int    BYTE_W  = WIDTH,
  parameter bit    OUT_REG = 1'b0,
  parameter        PRIM    = "block",   // untyped: XPM compares it with integers too
  localparam int   AW      = (DEPTH > 1) ? $clog2(DEPTH) : 1,
  localparam int   NWE     = WIDTH / BYTE_W
) (
  input  logic               clk,
  input  logic [NWE-1:0]     we,
  input  logic [AW-1:0]      waddr,
  input  logic [WIDTH-1:0]   wdata,
  input  logic               re,
  input  logic [AW-1:0]      raddr,
  output logic [WIDTH-1:0]   rdata
);
`ifdef SYNTHESIS
  xpm_memory_sdpram #(
    .ADDR_WIDTH_A        (AW),
    .ADDR_WIDTH_B        (AW),
    .BYTE_WRITE_WIDTH_A  (BYTE_W),
    .CLOCKING_MODE       ("common_clock"),
    .MEMORY_INIT_FILE    ("none"),
    .MEMORY_PRIMITIVE    (PRIM),
    .MEMORY_SIZE         (DEPTH * WIDTH),
    .READ_DATA_WIDTH_B   (WIDTH),
    .READ_LATENCY_B      (OUT_REG ? 2 : 1),
    .USE_MEM_INIT        (0),
    .WRITE_DATA_WIDTH_A  (WIDTH),
    .WRITE_MODE_B        ("read_first")
  ) u_mem (
    .clka (clk), .ena (|we), .wea (we), .addra (waddr), .dina (wdata),
    .clkb (clk), .enb (re), .addrb (raddr), .doutb (rdata),
    .regceb (1'b1), .rstb (1'b0), .sleep (1'b0),
    .injectsbiterra (1'b0), .injectdbiterra (1'b0), .sbiterrb (), .dbiterrb ()
  );
`else
  logic [WIDTH-1:0] mem [DEPTH];
  logic [WIDTH-1:0] rd_q;

  always_ff @(posedge clk) begin
    for (int b = 0; b < NWE; b++)
      if (we[b]) mem[waddr][b*BYTE_W +: BYTE_W] <= wdata[b*BYTE_W +: BYTE_W];
    if (re) rd_q <= mem[raddr];
  end

  if (OUT_REG) begin : g_oreg
    logic [WIDTH-1:0] out_q;
    always_ff @(posedge clk) out_q <= rd_q;
    assign rdata = out_q;
  end else begin : g_noreg
    assign rdata = rd_q;
  end
`endif
endmodule
