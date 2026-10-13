// Spike S6: dual-core floorplan dry run and fill test on the XCK26 (plan §8.2, §8.5).
// Two synthetic cores (tg_s6_core: the real S2-S5 structures plus filler sized to the
// configuration's per-core budget) and the uncore (tg_s6_l2: the 1 MiB UltraRAM L2, its
// tag/directory BRAMs, injector buffers and filler for the rest of the uncore budget).
// The core <-> L2 buses cross the chip with one pipeline register in each direction.
// fpga/spikes/scripts/s6_size.py turns a configuration and a LUT target into the sizes.
module tg_s6_top #(
  parameter int CORE_TILES = 400,
  parameter int CORE_NRAM  = 0,
  parameter int CORE_NBRAM = 0,
  parameter int CORE_NDSP  = 0,
  parameter int UNC_TILES  = 300,
  parameter int UNC_NRAM   = 0,
  localparam int BUS_W = 256
) (
  input  logic        clk,
  output logic [15:0] obs
);
  logic [1:0][BUS_W-1:0] to_l2, to_l2_q, from_l2, from_l2_q;
  for (genvar c = 0; c < 2; c++) begin : g_core
    tg_s6_core #(.TILES(CORE_TILES), .NRAM(CORE_NRAM), .NBRAM(CORE_NBRAM), .NDSP(CORE_NDSP),
                 .SEED(c + 1), .BUS_W(BUS_W)) u_core (
      .clk, .l2_in(from_l2_q[c]), .l2_out(to_l2[c]));
  end
  always_ff @(posedge clk) begin
    to_l2_q   <= to_l2;
    from_l2_q <= from_l2;
  end
  tg_s6_l2 #(.TILES(UNC_TILES), .NRAM(UNC_NRAM), .BUS_W(BUS_W)) u_l2 (
    .clk, .c_in(to_l2_q), .c_out(from_l2), .obs);
endmodule
