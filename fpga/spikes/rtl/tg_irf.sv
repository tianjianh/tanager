// Writer-sharded integer register file (plan §4.7, Seznec's write specialisation): NB banks
// of DEPTH x 64 bits, one write port per bank (rename allocates a destination in the bank
// of the port that will write it), and NR read ports that each read any bank.
// Each bank is one tg_ram_lut with NR read ports: explicit RAM64M8, ceil(NR * 64 / 7) per
// bank (64 at 7 ports, 83 at 9), so read ports beyond 7 cost primitives, not whole copies.
// A read selects its bank with a NB:1 mux after the LUTRAM. Spike S3.
// Read-during-write follows tg_ram_lut: the new value is visible after the write edge.
module tg_irf
  import tg_pkg::*;
#(
  parameter int NB    = INT_BANKS,
  parameter int DEPTH = INT_PREGS_PER_BANK,
  parameter int NR    = 7,
  localparam int IW   = idx_w(DEPTH),
  localparam int BW   = idx_w(NB)
) (
  input  logic                    clk,
  input  logic [NB-1:0]           we,
  input  logic [NB-1:0][IW-1:0]   waddr,
  input  logic [NB-1:0][XLEN-1:0] wdata,
  input  logic [NR-1:0][BW-1:0]   rbank,
  input  logic [NR-1:0][IW-1:0]   ridx,
  output logic [NR-1:0][XLEN-1:0] rdata
);
  logic [NB-1:0][NR-1:0][XLEN-1:0] bank_rd;
  for (genvar b = 0; b < NB; b++) begin : g_bank
    tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(XLEN), .NR(NR)) u_ram (
      .clk, .we(we[b]), .waddr(waddr[b]), .wdata(wdata[b]), .raddr(ridx),
      .rdata(bank_rd[b]));
  end
  for (genvar p = 0; p < NR; p++) begin : g_rd
    always_comb begin
      rdata[p] = bank_rd[0][p];
      for (int b = 1; b < NB; b++) if (rbank[p] == BW'(b)) rdata[p] = bank_rd[b][p];
    end
  end
endmodule
