// Writer-sharded integer register file (plan §4.7, Seznec's write specialisation): NB banks
// of DEPTH x 64 bits, one write port per bank (rename allocates a destination in the bank
// of the port that will write it), and NR read ports that each read any bank.
// Each bank is one tg_ram_lut with NR read ports: explicit RAM64M8, ceil(NR * 64 / 7) per
// bank (64 at 7 ports, 83 at 9), so read ports beyond 7 cost primitives, not whole copies.
// A read selects its bank with a NB:1 mux after the LUTRAM. Spike S3.
// Read-during-write follows tg_ram_lut: the new value is visible after the write edge.
// URF (DR-174, the area reserve): the first NI ports, read at issue, come from tg_urf, the
// double-pumped UltraRAM copies on clk2x, with the same values in the same cycles. Its early
// ports take the next cycle's address (rbank_n/ridx_n, the D side of rbank/ridx's register)
// and hold their data through the cycle. They are the last (NI + 1) / 2 of the NI, so the
// caller puts the ports with the most logic after the read last. The others are its late
// ports, read at mid-cycle. Their index is registered here from ridx_n: the same value as
// ridx's register, but placed by the UltraRAMs, since port A takes it in half a cycle (from
// the issue queue's register it was the whole core's worst path: +0.228 ns, smt2 at 10 ns).
// The ports after NI (store data, trace: their addresses are not ready by mid-cycle) stay on
// the tg_ram_lut banks, which take every write.
module tg_irf
  import tg_pkg::*;
#(
  parameter int NB    = INT_BANKS,
  parameter int DEPTH = INT_PREGS_PER_BANK,
  parameter int NR    = 7,
  parameter bit URF   = 1'b0,
  parameter int NI    = 1,              // URF: the issue-time ports, 2 <= NI < NR
  localparam int IW   = idx_w(DEPTH),
  localparam int BW   = idx_w(NB),
  localparam int LP0  = URF ? NI : 0    // the first port on LUTRAM
) (
  input  logic                    clk,
  input  logic                    clk2x,    // URF: twice clk, phase-aligned; else unused
  input  logic [NB-1:0]           we,
  input  logic [NB-1:0][IW-1:0]   waddr,
  input  logic [NB-1:0][XLEN-1:0] wdata,
  input  logic [NR-1:0][BW-1:0]   rbank,
  input  logic [NR-1:0][IW-1:0]   ridx,
  input  logic [NI-1:0][BW-1:0]   rbank_n,  // URF: the issue-time ports' next bank and index
  input  logic [NI-1:0][IW-1:0]   ridx_n,
  output logic [NR-1:0][XLEN-1:0] rdata
);
  logic [NB-1:0][NR-LP0-1:0][XLEN-1:0] bank_rd;
  for (genvar b = 0; b < NB; b++) begin : g_bank
    tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(XLEN), .NR(NR - LP0)) u_ram (
      .clk, .we(we[b]), .waddr(waddr[b]), .wdata(wdata[b]), .raddr(ridx[NR-1:LP0]),
      .rdata(bank_rd[b]));
  end
  for (genvar p = LP0; p < NR; p++) begin : g_rd
    always_comb begin
      rdata[p] = bank_rd[0][p - LP0];
      for (int b = 1; b < NB; b++) if (rbank[p] == BW'(b)) rdata[p] = bank_rd[b][p - LP0];
    end
  end

  if (URF) begin : g_urf
    localparam int NE = (NI + 1) / 2;
    localparam int NL = NI - NE;
    if (NI < 2 || NI >= NR) begin : g_bad
      $error("tg_irf: URF needs 2 <= NI < NR");
    end
    logic [NI-1:0][XLEN-1:0] urd;     // tg_urf's: the early ports, then the late ones
    // the late ports' index, beside the UltraRAMs; kept, so that synthesis does not merge it into
    // the issue queue's register of the same value
    (* keep = "true" *) logic [NL-1:0][IW-1:0] l_idx_q;
    always_ff @(posedge clk) l_idx_q <= ridx_n[NL-1:0];
    tg_urf #(.NB(NB), .DEPTH(DEPTH), .W(XLEN), .NE(NE), .NL(NL)) u_urf (
      .clk, .clk2x, .we, .waddr, .wdata,
      .e_bank_n(rbank_n[NI-1:NL]), .e_idx_n(ridx_n[NI-1:NL]),
      .l_bank(rbank[NL-1:0]), .l_idx(l_idx_q), .rdata(urd));
    assign rdata[NL-1:0]  = urd[NI-1:NE];
    assign rdata[NI-1:NL] = urd[NE-1:0];
    // the issue-time ports' registered indices, the early ports' registered banks and the late
    // ports' next banks are not read
    logic unused;
    assign unused = ^{rbank[NI-1:NL], ridx[NI-1:0], rbank_n[NL-1:0]};
  end else begin : g_lut
    logic unused;
    assign unused = ^{clk2x, rbank_n, ridx_n};
  end
endmodule
