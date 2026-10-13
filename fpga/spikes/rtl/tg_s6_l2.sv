// Synthetic uncore for the S6 floorplan dry run: the shared L2's real memories plus
// synthetic logic for the rest of the uncore budget (plan §5.1, §8.2).
//   Data: 1 MiB in 32 UltraRAMs, 2 banks interleaved on address bit 6, each 16K x 256 bits
//         (4 URAM288 wide, cascaded 4 deep), output registers.
//   Tags and directory: 1K sets x 8 ways x 28 bits per bank in block RAM.
//   Latency injector buffers: one 512 x 128 block RAM per memory port.
//   Control (MSHRs, directory logic, interconnect, AXI, peripherals, debug, host bridge):
//         tg_s6_fill sized by TILES/NRAM.
// The two core buses arrive registered; each carries an address, write data and controls.
module tg_s6_l2 #(
  parameter int TILES = 300,
  parameter int NRAM  = 0,
  parameter int BUS_W = 256,
  parameter int SEED  = 99
) (
  input  logic                  clk,
  input  logic [1:0][BUS_W-1:0] c_in,     // from the cores
  output logic [1:0][BUS_W-1:0] c_out,    // to the cores
  output logic [15:0]           obs       // keeps the design observable
);
  localparam int FIN_W  = 2 * BUS_W + 2 * 256 + 2 * 224 + 2 * 128;
  // Filler outputs: per-bank controls [0, 128), injector write data [128, 384), responses
  localparam int F_INJ  = 128;
  localparam int F_RSP  = 384;
  localparam int FOUT_W = F_RSP + 2 * BUS_W;

  logic [1:0][BUS_W-1:0] cin_q;
  always_ff @(posedge clk) cin_q <= c_in;

  logic [FOUT_W-1:0] fout;
  logic [FIN_W-1:0]  fin;

  // ---- Data banks (URAM), tags/directory (BRAM), injector buffers (BRAM) ----
  logic [1:0][255:0] dq;
  logic [1:0][223:0] tq;
  logic [1:0][127:0] iq;
  for (genvar b = 0; b < 2; b++) begin : g_bank
    logic [13:0] ra, wa;
    logic [9:0]  tra, twa;
    assign ra  = cin_q[b][13:0];
    assign wa  = fout[b * 64 +: 14];
    assign tra = cin_q[b][23:14];
    assign twa = fout[b * 64 + 14 +: 10];
    tg_ram_sdp #(.DEPTH(16384), .WIDTH(256), .OUT_REG(1'b1), .PRIM("ultra")) u_data (
      .clk, .we(fout[b * 64 + 24]), .waddr(wa), .wdata({cin_q[b][BUS_W-1:24], fout[b * 64 +: 24]}),
      .re(1'b1), .raddr(ra), .rdata(dq[b]));
    tg_ram_sdp #(.DEPTH(1024), .WIDTH(224), .OUT_REG(1'b0), .PRIM("block")) u_tag (
      .clk, .we(fout[b * 64 + 25]), .waddr(twa), .wdata({fout[b * 64 +: 32], cin_q[b][BUS_W-1 -: 192]}),
      .re(1'b1), .raddr(tra), .rdata(tq[b]));
    tg_ram_sdp #(.DEPTH(512), .WIDTH(128), .OUT_REG(1'b1), .PRIM("block")) u_inj (
      .clk, .we(fout[b * 64 + 26]), .waddr(fout[b * 64 + 27 +: 9]),
      .wdata(fout[F_INJ + b * 128 +: 128]), .re(1'b1), .raddr(cin_q[b][32 +: 9]), .rdata(iq[b]));
    logic unused;
    assign unused = ^fout[b * 64 + 36 +: 28];
  end

  assign fin = {iq, tq, dq, cin_q};

  tg_s6_fill #(.TILES(TILES), .NRAM(NRAM), .NBRAM(0), .NDSP(0), .SEED(SEED),
               .IN_W(FIN_W), .OUT_W(FOUT_W)) u_fill (.clk, .in(fin), .out(fout));

  // Responses: data from the bank the core addressed, through the control logic
  always_ff @(posedge clk) begin
    for (int c = 0; c < 2; c++)
      c_out[c] <= fout[F_RSP + c * BUS_W +: BUS_W] ^ dq[cin_q[c][6]][BUS_W-1:0];
    obs <= fout[15:0];
  end
endmodule
