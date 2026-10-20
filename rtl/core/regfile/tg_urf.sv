// Double-pumped UltraRAM integer register file (DR-174, the area reserve behind URF; spikes.md §8.14,
// WMODE "edge" of spikes-2's tg_urf). NB banks of DEPTH x W bits, one write port per bank, NE early
// and NL late read ports that each read any bank. Each bank is NC = max(NE, NL) copies of
// URAM288_BASE clocked by clk2x, twice the core clock and phase-aligned (every clk rise is a clk2x
// rise), and every copy of a bank takes every write of its bank. Copy c serves early port c and late
// port c, two accesses on each of its two ports per core cycle:
//   core edge (slot 0): port A writes the bank's write port (held through the cycle that ends here);
//                       port B reads early port c, after A's write, so it sees it
//   mid-cycle (slot 1): port A reads late port c; port B idles, so its output holds the early read
//                       to the next core edge
// - Early port: e_bank_n/e_idx_n are the next cycle's bank and index, the D side of the issue -> RF
//   register. The UltraRAM's address register replaces that register for the read; the data is valid
//   from the core edge plus port B's clock-to-out through the whole cycle.
// - Late port: l_bank/l_idx are this cycle's, from a register; the data is valid from mid-cycle plus
//   port A's clock-to-out to the end of the cycle.
// - Every read returns the writes of earlier cycles, as tg_irf's (tg_ram_lut's asynchronous read,
//   written at the end of the cycle): the late read comes before this cycle's write, the early read
//   after the last cycle's. That depends on UltraRAM doing port A's operation before port B's in a
//   clock cycle (UG573); its NO_CHANGE write keeps port A's output through the write.
// - Half-cycle flag: t1 toggles at each core edge and t2 follows it at each clk2x edge, so fh (they
//   differ) is high from a core edge to the next mid-cycle edge. The UltraRAMs sample the slot 1
//   inputs where fh is high and the slot 0 inputs where it is low.
// Bodies (as tg_ram_lut's):
//   SYNTHESIS, or TG_SIM_PRIMS (unit tests, with a URAM288_BASE model): the UltraRAMs on clk2x.
//   Otherwise (core simulation): the same reads on clk alone, a memory per bank written at the core
//   edge with the early ports' addresses registered, so no testbench needs clk2x (it is unused).
// rdata: the early ports, then the late ports; all valid at the next core edge.
// Sources: UG573 (UltraScale Architecture Memory Resources) for URAM288; C. E. LaForest and
// J. G. Steffan, "Efficient multi-ported memories for FPGAs", FPGA 2010 (copies for read ports);
// A. Canis, J. H. Anderson and S. D. Brown, "Multi-pumping for resource reduction in FPGA high-level
// synthesis", DATE 2013 (a memory clocked at twice the system clock).
module tg_urf #(
  parameter int NB    = 3,
  parameter int DEPTH = 64,
  parameter int W     = 64,
  parameter int NE    = 3,
  parameter int NL    = 3,
  localparam int NR   = NE + NL,
  localparam int IW   = (DEPTH > 1) ? $clog2(DEPTH) : 1,
  localparam int BW   = (NB > 1) ? $clog2(NB) : 1
) (
  input  logic                     clk,       // the core clock
  input  logic                     clk2x,     // twice the core clock, phase-aligned
  // write ports, one per bank, held through the cycle (written at the core edge that ends it)
  input  logic [NB-1:0]            we,
  input  logic [NB-1:0][IW-1:0]    waddr,
  input  logic [NB-1:0][W-1:0]     wdata,
  // early ports: the next cycle's bank and index
  input  logic [NE-1:0][BW-1:0]    e_bank_n,
  input  logic [NE-1:0][IW-1:0]    e_idx_n,
  // late ports: this cycle's bank and index, from a register
  input  logic [NL-1:0][BW-1:0]    l_bank,
  input  logic [NL-1:0][IW-1:0]    l_idx,
  output logic [NR-1:0][W-1:0]     rdata
);
  if (NE < 1 || NL < 1 || DEPTH > 4096 || W > 72) begin : g_bad
    $error("tg_urf: needs NE >= 1, NL >= 1, DEPTH <= 4096 and W <= 72");
  end

  // The early ports' banks, for the bank select in the cycle they read
  logic [NE-1:0][BW-1:0] e_bank_q;
  always_ff @(posedge clk) e_bank_q <= e_bank_n;

  logic [NB-1:0][NR-1:0][W-1:0] bank_rd;

`ifdef SYNTHESIS
  `define TG_URF_PRIMS
`elsif TG_SIM_PRIMS
  `define TG_URF_PRIMS
`endif

`ifdef TG_URF_PRIMS
  `undef TG_URF_PRIMS
  localparam int NC = (NE > NL) ? NE : NL;   // copies per bank
  // Power-up values (the flip-flops' INIT), so a four-state simulation starts from known values; fh
  // is right from the first core edge either way (t2 takes t1 at the first clk2x edge)
  /* verilator lint_off PROCASSINIT */
  logic t1_q = 1'b0, t2_q = 1'b0;
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge clk)   t1_q <= ~t1_q;
  always_ff @(posedge clk2x) t2_q <= t1_q;
  logic fh;
  assign fh = t1_q ^ t2_q;

  for (genvar b = 0; b < NB; b++) begin : g_bank
    for (genvar c = 0; c < NC; c++) begin : g_copy
      localparam bit E = c < NE;
      localparam bit L = c < NL;
      logic [IW-1:0] a_addr;
      logic          a_en;
      /* verilator lint_off UNUSEDSIGNAL */  // bits 71:W, port A's output in a copy with no late port,
      logic [71:0]   doa, dob;               // and the ECC flags (no ECC)
      logic [3:0]    ecc;
      /* verilator lint_on UNUSEDSIGNAL */
      assign a_addr = fh ? (L ? l_idx[L ? c : 0] : '0) : waddr[b];
      assign a_en   = fh ? L : we[b];
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
        .SBITERR_A (ecc[0]), .DBITERR_A (ecc[1]), .SBITERR_B (ecc[2]), .DBITERR_B (ecc[3])
      );
      if (E) begin : g_e
        assign bank_rd[b][c] = dob[W-1:0];
      end
      if (L) begin : g_l
        assign bank_rd[b][NE + c] = doa[W-1:0];
      end
    end
  end

`ifndef SYNTHESIS
  // clk2x must rise twice in every core cycle (simulation only: a testbench that leaves it still
  // would read nothing)
  int unsigned n2x;
  initial n2x = 0;
  always @(posedge clk2x) n2x <= n2x + 1;
  int unsigned n2x_last, ncyc;
  initial begin
    n2x_last = 0;
    ncyc     = 0;
  end
  always @(posedge clk) begin
    ncyc <= ncyc + 1;
    n2x_last <= n2x;
    if (ncyc > 2 && n2x - n2x_last != 2)
      $fatal(1, "tg_urf: clk2x rose %0d times in a core cycle, not twice", n2x - n2x_last);
  end
`endif
`else
  // Core simulation: what the UltraRAMs return, on clk alone
  logic unused_clk2x;
  assign unused_clk2x = clk2x;
  logic [NE-1:0][IW-1:0] e_idx_q;
  always_ff @(posedge clk) e_idx_q <= e_idx_n;
  for (genvar b = 0; b < NB; b++) begin : g_bank
    logic [W-1:0] mem [DEPTH];
    always_ff @(posedge clk) begin
      if (we[b]) mem[waddr[b]] <= wdata[b];
    end
    for (genvar e = 0; e < NE; e++) begin : g_e
      assign bank_rd[b][e] = mem[e_idx_q[e]];
    end
    for (genvar l = 0; l < NL; l++) begin : g_l
      assign bank_rd[b][NE + l] = mem[l_idx[l]];
    end
  end
`endif

  // Bank select: the early ports' registered banks, the late ports' banks of the cycle; a bank
  // number past NB - 1 reads bank 0, as tg_irf's
  for (genvar p = 0; p < NR; p++) begin : g_rd
    always_comb begin
      logic [BW-1:0] bk;
      bk = (p < NE) ? e_bank_q[(p < NE) ? p : 0] : l_bank[(p < NE) ? 0 : p - NE];
      rdata[p] = bank_rd[0][p];
      for (int b = 1; b < NB; b++) if (bk == BW'(b)) rdata[p] = bank_rd[b][p];
    end
  end
endmodule
