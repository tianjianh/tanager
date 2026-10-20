// FP register file (docs/spec/fpu.md, "Core integration"; plan §4.7): writer-sharded banks F0
// (written only by P4's F0 stream) and F1 (written only by the load path), FP_PREGS_PER_BANK x 64
// bits each. NR asynchronous read ports read either bank: each bank is one tg_ram_lut with NR
// read ports (explicit RAM64M8, ceil(NR * 64 / 7) per bank). Both banks leave the module: each user
// selects the bank in a multiplexer of its own (tg_fp_exec's RF stage for the operands, the core's
// store-data and trace multiplexers; fpga_friendly.md T7). Read-during-write follows tg_ram_lut:
// the new value is visible after the write edge. The reset sequence's zero writes come through
// the F0 port (tg_fp_exec).
// RD2X (scratch study, the coordinator 10-19; not for merge): the LUTRAM read ports double-pumped at
// clk2x. Ports 2k and 2k+1 (k < NPAIR) share one read port of each bank: its address is port 2k's
// from the core edge to mid-cycle, where port 2k's data is captured (cap_q), and port 2k+1's from
// mid-cycle to the next core edge, read straight through. Every read still returns the writes of
// earlier cycles (the banks are written at the core edge only), so the cycles are the same. The
// half-cycle flag fh is high from a core edge to the next mid-cycle edge: from clk and clk2x in
// synthesis (or with TG_SIM_PRIMS), and in other simulations from clk's two edges, the falling
// edge standing for mid-cycle (clk2x unused), so the pairs' multiplexers and captures are simulated.
module tg_fprf
  import tg_pkg::*, tg_core_pkg::*, tg_fpcore_pkg::*;
#(
  parameter int NR    = 4,
  parameter bit RD2X  = 1'b0,
  parameter int NPAIR = 0,
  localparam int NPH  = RD2X ? NR - NPAIR : NR   // read ports of each bank
) (
  input  logic                        clk,
  input  logic                        clk2x,       // RD2X: twice clk, rising with it; else unused
  input  logic                        f0_we,
  input  logic [FPIDX_W-1:0]          f0_waddr,
  input  logic [63:0]                 f0_wdata,
  input  logic                        f1_we,
  input  logic [FPIDX_W-1:0]          f1_waddr,
  input  logic [63:0]                 f1_wdata,
  input  logic [NR-1:0][FPTAG_W-1:0]  rtag,        // {bank, index}; the bank bit is the user's
  output logic [1:0][NR-1:0][63:0]    bank_rd      // both banks: each user folds the bank select
                                                   // into a multiplexer of its own
);
  logic [1:0]               we;
  logic [1:0][FPIDX_W-1:0]  wa;
  logic [1:0][63:0]         wd;
  assign we = {f1_we, f0_we};
  assign wa = {f1_waddr, f0_waddr};
  assign wd = {f1_wdata, f0_wdata};

  logic [NR-1:0][FPIDX_W-1:0] ridx;
  for (genvar p = 0; p < NR; p++) begin : g_ridx
    assign ridx[p] = rtag[p][FPIDX_W-1:0];
  end

  logic [NPH-1:0][FPIDX_W-1:0] paddr;
  logic [1:0][NPH-1:0][63:0]   prd;
  for (genvar b = 0; b < 2; b++) begin : g_bank
    tg_ram_lut #(.DEPTH(FP_PREGS_PER_BANK), .WIDTH(64), .NR(NPH)) u_ram (
      .clk, .we(we[b]), .waddr(wa[b]), .wdata(wd[b]), .raddr(paddr), .rdata(prd[b]));
  end

  if (!RD2X) begin : g_plain
    assign paddr   = ridx;
    assign bank_rd = prd;
    logic unused;
    assign unused = clk2x;
  end else begin : g_2x
    if (NPAIR < 1 || 2 * NPAIR > NR) begin : g_bad
      $error("tg_fprf: RD2X needs 1 <= NPAIR <= NR / 2");
    end
    logic fh;
    logic [1:0][NPAIR-1:0][63:0] cap_q;   // the first-half reads, from mid-cycle
`ifdef SYNTHESIS
  `define TG_FPRF_2X
`elsif TG_SIM_PRIMS
  `define TG_FPRF_2X
`endif
`ifdef TG_FPRF_2X
  `undef TG_FPRF_2X
    /* verilator lint_off PROCASSINIT */
    logic t1_q = 1'b0, t2_q = 1'b0;
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge clk)   t1_q <= ~t1_q;
    always_ff @(posedge clk2x) t2_q <= t1_q;
    assign fh = t1_q ^ t2_q;
    always_ff @(posedge clk2x) if (fh) for (int b = 0; b < 2; b++) cap_q[b] <= prd[b][NPAIR-1:0];
`else
    logic p_q, n_q, unused_clk2x;
    always_ff @(posedge clk) p_q <= ~p_q;
    always_ff @(negedge clk) n_q <= p_q;
    assign fh = p_q ^ n_q;
    always_ff @(negedge clk) if (fh) for (int b = 0; b < 2; b++) cap_q[b] <= prd[b][NPAIR-1:0];
    assign unused_clk2x = clk2x;
`endif
    for (genvar k = 0; k < NPAIR; k++) begin : g_pair
      assign paddr[k] = fh ? ridx[2*k] : ridx[2*k+1];
      for (genvar b = 0; b < 2; b++) begin : g_b
        assign bank_rd[b][2*k]   = cap_q[b][k];
        assign bank_rd[b][2*k+1] = prd[b][k];
      end
    end
    for (genvar k = NPAIR; k < NPH; k++) begin : g_one
      assign paddr[k] = ridx[k + NPAIR];
      for (genvar b = 0; b < 2; b++) begin : g_b
        assign bank_rd[b][k + NPAIR] = prd[b][k];
      end
    end
  end
endmodule
