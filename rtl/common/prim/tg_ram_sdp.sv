// Simple dual-port block memory: one write port, one synchronous read port, one clock.
// Read-during-write to the same address returns the old data (read-first).
// Synthesis maps it with xpm_memory_sdpram; simulation uses the behavioural model.
//   BYTE_W:  write-enable granularity in bits (WIDTH = no byte enables).
//   OUT_REG: 1 adds the output register (read latency 2 instead of 1).
//   RD_LAT:  read latency in cycles, default 1 (2 with OUT_REG). Above 2 the extra stages
//            are output pipeline registers; XPM puts them in the UltraRAM cascade, which a
//            deep cascade needs at 200 MHz (S6: the L2's 4-deep banks use 4).
//   PRIM:    "block", "ultra", "distributed" or "auto".
//   WR_PORT_ON: 1 keeps the write port always enabled, so it writes exactly the bytes whose `we` bit
//            is set and no path ends at its enable (in an UltraRAM cascade the enable crosses every
//            stage); 0, the default, enables it with the OR of `we`. The same writes either way: a
//            set `we` bit implies the OR. The L2's data array uses 1.
(* keep_hierarchy = "yes" *)  // keeps the instance and its ports for the primitive check
module tg_ram_sdp #(
  parameter int    DEPTH   = 512,
  parameter int    WIDTH   = 64,
  parameter int    BYTE_W  = WIDTH,
  parameter bit    OUT_REG = 1'b0,
  parameter        PRIM    = "block",   // untyped: XPM compares it with integers too
  parameter int    RD_LAT  = OUT_REG ? 2 : 1,
  parameter bit    WR_PORT_ON = 1'b0,
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
  wire ena = WR_PORT_ON ? 1'b1 : |we;   // the write port's enable

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
    .READ_LATENCY_B      (RD_LAT),
    .USE_MEM_INIT        (0),
    .WRITE_DATA_WIDTH_A  (WIDTH),
    .WRITE_MODE_B        ("read_first")
  ) u_mem (
    .clka (clk), .ena (ena), .wea (we), .addra (waddr), .dina (wdata),
    .clkb (clk), .enb (re), .addrb (raddr), .doutb (rdata),
    .regceb (1'b1), .rstb (1'b0), .sleep (1'b0),
    .injectsbiterra (1'b0), .injectdbiterra (1'b0), .sbiterrb (), .dbiterrb ()
  );
`else
  logic [WIDTH-1:0] mem [DEPTH];
  logic [WIDTH-1:0] rd_q;

  // as the synthesized memory writes: a byte when the port is enabled and its `we` bit is set
  always_ff @(posedge clk) begin
    for (int b = 0; b < NWE; b++)
      if (ena && we[b]) mem[waddr][b*BYTE_W +: BYTE_W] <= wdata[b*BYTE_W +: BYTE_W];
    if (re) rd_q <= mem[raddr];
  end
  // the enable covers every write, in either form, so it never drops one
  always_ff @(posedge clk) assert (!(|we) || ena) else $error("tg_ram_sdp: a write with its port disabled");

  if (RD_LAT > 1) begin : g_oreg
    logic [RD_LAT-2:0][WIDTH-1:0] out_q;
    always_ff @(posedge clk) begin
      out_q[0] <= rd_q;
      for (int i = 1; i < RD_LAT - 1; i++) out_q[i] <= out_q[i-1];
    end
    assign rdata = out_q[RD_LAT-2];
  end else begin : g_noreg
    assign rdata = rd_q;
  end
`endif
endmodule
