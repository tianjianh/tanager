// Double-pumped UltraRAM integer register file (spikes.md §8.14, measurement only: the coordinator
// and the user, 2026-10-19; not for the core). NB banks of DEPTH x W bits, one write port per bank and
// NE + NL read ports that each read any bank, as tg_irf. Each bank is NC copies of URAM288_BASE
// clocked by clk2x, twice the core clock and phase-aligned (every clk edge is a clk2x edge), so one
// copy's two ports make four accesses per core cycle:
//   core edge (slot 0): port A reads, port B reads   (early ports: the address is presented in the
//                                                     cycle before, as the D side of today's
//                                                     issue -> RF register, and the UltraRAM's
//                                                     address register replaces that register)
//   mid-cycle (slot 1): port A reads a late port,    (late ports: the address is presented in the
//                       port B writes                 cycle itself, by mid-cycle)
// UltraRAM performs port A's operation before port B's within a clock cycle (UG573), so a late read
// sees the memory before this cycle's write, as every early read does: every read in a cycle returns
// the writes of earlier cycles, as tg_ram_lut's asynchronous read does (its write lands at the end of
// the cycle). The write mode is NO_CHANGE, so port B's output keeps the early read's data through
// the write, until the next core edge's read. Port A's output keeps its early read the same way
// when the copy has no late port (EN_A low at mid-cycle); a copy with a late port captures port A's
// early data at mid-cycle (cap_q), before the late read replaces it.
// Every copy of a bank takes every write of its bank's port. Early port e is copy e / 2, port A for
// an even e and B for an odd one; late port l is copy l's port A at mid-cycle.
// WMODE "edge" moves the write to the core edge, on port A, so the write port has the full cycle that
// tg_ram_lut gives it (in a routed chip, bank 1's write data is ready only 4.5 ns into the cycle):
//   core edge (slot 0): port A writes, port B reads early port c   (after A's write: it sees it)
//   mid-cycle (slot 1): port A reads late port c, port B idles     (B's output holds the early read)
// One early and one late port per copy, NC = max(NE, NL); a late port's address comes from a register
// (today's issue -> RF register), an early port's from the select at the end of the issue cycle. Every
// read still returns the writes of earlier cycles: the late read precedes the cycle's write, and the
// early read follows the last cycle's write at the same edge (port A's operation goes first).
// rdata: the early ports, then the late ports; all valid at the next core edge.
// Sources: UG573 (UltraScale Architecture Memory Resources) for URAM288; C. E. LaForest and
// J. G. Steffan, "Efficient multi-ported memories for FPGAs", FPGA 2010 (replication for read
// ports); A. Canis, J. H. Anderson and S. D. Brown, "Multi-pumping for resource reduction in
// FPGA high-level synthesis", DATE 2013 (a memory clocked at twice the system clock).
module tg_urf #(
  parameter int NB    = 3,
  parameter int DEPTH = 64,
  parameter int W     = 64,
  parameter int NE    = 6,
  parameter int NL    = 1,
  parameter string WMODE = "mid",    // "mid" or "edge" (above)
  localparam int NR   = NE + NL,
  localparam int NC   = (WMODE == "edge") ? ((NE > NL) ? NE : NL) : (NE + 1) / 2,
  localparam int IW   = $clog2(DEPTH),
  localparam int BW   = (NB > 1) ? $clog2(NB) : 1
) (
  input  logic                     clk,       // the core clock
  input  logic                     clk2x,     // twice the core clock, phase-aligned
  // write ports, one per bank, held for the cycle (written at its mid-cycle edge)
  input  logic [NB-1:0]            we,
  input  logic [NB-1:0][IW-1:0]    waddr,
  input  logic [NB-1:0][W-1:0]     wdata,
  // early ports: next cycle's bank and index
  input  logic [NE-1:0][BW-1:0]    e_bank_n,
  input  logic [NE-1:0][IW-1:0]    e_idx_n,
  // late ports: this cycle's bank and index, by mid-cycle
  input  logic [NL-1:0]            l_en,
  input  logic [NL-1:0][BW-1:0]    l_bank,
  input  logic [NL-1:0][IW-1:0]    l_idx,
  output logic [NR-1:0][W-1:0]     rdata
);
  if (NL > NC || DEPTH > 4096 || W > 72 || (WMODE != "mid" && WMODE != "edge")) begin : g_bad
    $error("tg_urf: needs WMODE \"mid\" or \"edge\", NL <= NC copies, DEPTH <= 4096 and W <= 72");
  end

  // The half of the core cycle, in clk2x's domain: t1 toggles at each core edge and t2 follows it at
  // each clk2x edge, so fh (they differ) is high from a core edge to the next mid-cycle edge. The
  // UltraRAMs sample the slot 1 inputs where fh is high and the slot 0 inputs where it is low.
  logic t1_q = 1'b0, t2_q = 1'b0;
  always_ff @(posedge clk)   t1_q <= ~t1_q;
  always_ff @(posedge clk2x) t2_q <= t1_q;
  logic fh;
  assign fh = t1_q ^ t2_q;

  // The early ports' banks, for the bank select in the cycle they read
  logic [NE-1:0][BW-1:0] e_bank_q;
  always_ff @(posedge clk) e_bank_q <= e_bank_n;

  logic [NB-1:0][NR-1:0][W-1:0] bank_rd;
  for (genvar b = 0; b < NB; b++) begin : g_bank
    for (genvar c = 0; c < NC; c++) begin : g_copy
     if (WMODE == "edge") begin : g_edge
      localparam bit E = c < NE;
      localparam bit L = c < NL;
      logic [IW-1:0] a_addr;
      logic          a_en;
      logic [71:0]   doa, dob;
      assign a_addr = fh ? (L ? l_idx[L ? c : 0] : '0) : waddr[b];
      assign a_en   = fh ? (L && l_en[L ? c : 0]) : we[b];
      (* dont_touch = "true" *)
      URAM288_BASE #(
        .IREG_PRE_A ("FALSE"), .IREG_PRE_B ("FALSE"),
        .OREG_A     ("FALSE"), .OREG_B     ("FALSE"),
        .OREG_ECC_A ("FALSE"), .OREG_ECC_B ("FALSE"),
        .EN_ECC_RD_A("FALSE"), .EN_ECC_RD_B("FALSE"),
        .EN_ECC_WR_A("FALSE"), .EN_ECC_WR_B("FALSE"),
        .BWE_MODE_A ("PARITY_INTERLEAVED"), .BWE_MODE_B ("PARITY_INTERLEAVED"),
        .RST_MODE_A ("SYNC"), .RST_MODE_B ("SYNC"),
        .USE_EXT_CE_A("FALSE"), .USE_EXT_CE_B("FALSE"),
        .EN_AUTO_SLEEP_MODE ("FALSE")
      ) u_uram (
        .CLK      (clk2x),
        .ADDR_A   (23'(a_addr)), .EN_A (a_en), .RDB_WR_A (!fh), .BWE_A (9'h1ff), .DIN_A (72'(wdata[b])),
        .ADDR_B   (23'(E ? e_idx_n[E ? c : 0] : '0)), .EN_B (!fh && E), .RDB_WR_B (1'b0), .BWE_B (9'h000),
        .DIN_B    (72'h0),
        .DOUT_A   (doa), .DOUT_B (dob),
        .OREG_CE_A (1'b1), .OREG_CE_B (1'b1), .OREG_ECC_CE_A (1'b0), .OREG_ECC_CE_B (1'b0),
        .RST_A (1'b0), .RST_B (1'b0), .SLEEP (1'b0),
        .INJECT_SBITERR_A (1'b0), .INJECT_DBITERR_A (1'b0),
        .INJECT_SBITERR_B (1'b0), .INJECT_DBITERR_B (1'b0),
        .SBITERR_A (), .DBITERR_A (), .SBITERR_B (), .DBITERR_B ()
      );
      if (E) begin : g_e
        assign bank_rd[b][c] = dob[W-1:0];
      end
      if (L) begin : g_l
        assign bank_rd[b][NE + c] = doa[W-1:0];
      end
     end else begin : g_mid
      localparam int  EA   = 2 * c;            // early port on port A
      localparam int  EB   = 2 * c + 1;        // early port on port B (none if EB == NE)
      localparam bit  LATE = c < NL;           // port A also serves late port c
      logic [IW-1:0] a_addr, b_addr;
      logic          a_en, b_en;
      logic [71:0]   doa, dob;
      assign a_addr = (fh && LATE) ? l_idx[LATE ? c : 0] : e_idx_n[EA];
      assign a_en   = fh ? (LATE && l_en[LATE ? c : 0]) : 1'b1;
      assign b_addr = fh ? waddr[b] : ((EB < NE) ? e_idx_n[(EB < NE) ? EB : 0] : '0);
      assign b_en   = fh ? we[b] : (EB < NE);
      (* dont_touch = "true" *)
      URAM288_BASE #(
        .IREG_PRE_A ("FALSE"), .IREG_PRE_B ("FALSE"),
        .OREG_A     ("FALSE"), .OREG_B     ("FALSE"),
        .OREG_ECC_A ("FALSE"), .OREG_ECC_B ("FALSE"),
        .EN_ECC_RD_A("FALSE"), .EN_ECC_RD_B("FALSE"),
        .EN_ECC_WR_A("FALSE"), .EN_ECC_WR_B("FALSE"),
        .BWE_MODE_A ("PARITY_INTERLEAVED"), .BWE_MODE_B ("PARITY_INTERLEAVED"),
        .RST_MODE_A ("SYNC"), .RST_MODE_B ("SYNC"),
        .USE_EXT_CE_A("FALSE"), .USE_EXT_CE_B("FALSE"),
        .EN_AUTO_SLEEP_MODE ("FALSE")
      ) u_uram (
        .CLK      (clk2x),
        .ADDR_A   (23'(a_addr)), .EN_A (a_en), .RDB_WR_A (1'b0), .BWE_A (9'h000), .DIN_A (72'h0),
        .ADDR_B   (23'(b_addr)), .EN_B (b_en), .RDB_WR_B (fh),   .BWE_B (9'h1ff),
        .DIN_B    (72'(wdata[b])),
        .DOUT_A   (doa), .DOUT_B (dob),
        .OREG_CE_A (1'b1), .OREG_CE_B (1'b1), .OREG_ECC_CE_A (1'b0), .OREG_ECC_CE_B (1'b0),
        .RST_A (1'b0), .RST_B (1'b0), .SLEEP (1'b0),
        .INJECT_SBITERR_A (1'b0), .INJECT_DBITERR_A (1'b0),
        .INJECT_SBITERR_B (1'b0), .INJECT_DBITERR_B (1'b0),
        .SBITERR_A (), .DBITERR_A (), .SBITERR_B (), .DBITERR_B ()
      );
      // Port A's early data: captured at mid-cycle when the late read follows it, else held
      if (LATE) begin : g_cap
        logic [W-1:0] cap_q;
        always_ff @(posedge clk2x) if (fh) cap_q <= doa[W-1:0];
        assign bank_rd[b][EA] = cap_q;
        assign bank_rd[b][NE + c] = doa[W-1:0];
      end else begin : g_hold
        assign bank_rd[b][EA] = doa[W-1:0];
      end
      if (EB < NE) begin : g_b
        assign bank_rd[b][EB] = dob[W-1:0];
      end
     end
    end
  end

  // Bank select: the early ports' registered banks, the late ports' banks of the cycle
  for (genvar p = 0; p < NR; p++) begin : g_rd
    always_comb begin
      logic [BW-1:0] bk;
      bk = (p < NE) ? e_bank_q[(p < NE) ? p : 0] : l_bank[(p < NE) ? 0 : p - NE];
      rdata[p] = bank_rd[0][p];
      for (int b = 1; b < NB; b++) if (bk == BW'(b)) rdata[p] = bank_rd[b][p];
    end
  end
endmodule
