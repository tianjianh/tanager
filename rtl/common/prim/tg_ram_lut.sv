// Multi-read-port LUTRAM: NR asynchronous read ports, one synchronous write port.
// The only way RTL instantiates LUTRAM (plan §8.3). This version is behavioural for both
// simulation and synthesis; explicit RAM64M8/RAM32M16 mapping replaces it under SYNTHESIS
// once spike S3 settles the structure. The port contract below does not change.
module tg_ram_lut #(
  parameter int DEPTH = 64,
  parameter int WIDTH = 8,
  parameter int NR    = 1,
  localparam int AW   = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
  input  logic                       clk,
  input  logic                       we,
  input  logic [AW-1:0]              waddr,
  input  logic [WIDTH-1:0]           wdata,
  input  logic [NR-1:0][AW-1:0]      raddr,
  output logic [NR-1:0][WIDTH-1:0]   rdata
);
  (* ram_style = "distributed" *) logic [WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
  end

  for (genvar r = 0; r < NR; r++) begin : g_rd
    assign rdata[r] = mem[raddr[r]];
  end
endmodule
