// FP register file (docs/spec/fpu.md, "Core integration"; plan §4.7): banks F0 and F1, FP_PREGS_PER_BANK x 64 bits
// each, one write port each. Two writers, each into the bank its destination names (DR-179: renaming across both
// banks): P4's stream (FP results; F0 unless rename crossed it into F1) and the load path (FP loads; F1 unless crossed
// into F0). P4 wins a bank both want: the load path never presents one in that cycle (the LSU holds the load a cycle,
// from P4's announcement the cycle before), asserted below. Each bank's address and data are selected by P4's
// registered slot (p4_sel, its live owner) and its bank, so a late flush reaches only the write enables. The two
// banks' writes after the select leave the module (the core's FP ready tables and store-data snoop). NR asynchronous
// read ports read either bank: each bank is one tg_ram_lut with NR read ports (explicit RAM64M8, ceil(NR * 64 / 7) per
// bank). Both banks leave the module: each user selects the bank in a multiplexer of its own (tg_fp_exec's RF stage
// for the operands, the core's store-data and trace multiplexers; fpga_friendly.md T7). Read-during-write follows
// tg_ram_lut: the new value is visible after the write edge.
module tg_fprf
  import tg_pkg::*, tg_core_pkg::*, tg_fpcore_pkg::*;
#(
  parameter int NR = 4
) (
  input  logic                        clk,
  input  logic                        rst,
  // P4's stream: p4_sel its registered live slot (the selects), p4_we the write (with the late flush)
  input  logic                        p4_sel,
  input  logic                        p4_we,
  input  logic                        p4_bank,
  input  logic [FPIDX_W-1:0]          p4_waddr,
  input  logic [63:0]                 p4_wdata,
  // The load path
  input  logic                        ld_we,
  input  logic                        ld_bank,
  input  logic [FPIDX_W-1:0]          ld_waddr,
  input  logic [63:0]                 ld_wdata,
  // Each bank's write, after the select
  output logic [1:0]                  bank_we,
  output logic [1:0][FPIDX_W-1:0]     bank_waddr,
  input  logic [NR-1:0][FPTAG_W-1:0]  rtag,        // {bank, index}; the bank bit is the user's
  output logic [1:0][NR-1:0][63:0]    bank_rd      // both banks: each user folds the bank select
                                                   // into a multiplexer of its own
);
  logic [1:0][63:0] wd;
  for (genvar b = 0; b < 2; b++) begin : g_sel
    logic p4b;                                     // bank b takes P4's address and data
    assign p4b           = p4_sel && p4_bank == 1'(b);
    assign bank_we[b]    = (p4_we && p4_bank == 1'(b)) || (ld_we && ld_bank == 1'(b));
    assign bank_waddr[b] = p4b ? p4_waddr : ld_waddr;
    assign wd[b]         = p4b ? p4_wdata : ld_wdata;
  end

  logic [NR-1:0][FPIDX_W-1:0] ridx;
  for (genvar p = 0; p < NR; p++) begin : g_ridx
    assign ridx[p] = rtag[p][FPIDX_W-1:0];
  end

  for (genvar b = 0; b < 2; b++) begin : g_bank
    tg_ram_lut #(.DEPTH(FP_PREGS_PER_BANK), .WIDTH(64), .NR(NR)) u_ram (
      .clk, .we(bank_we[b]), .waddr(bank_waddr[b]), .wdata(wd[b]), .raddr(ridx), .rdata(bank_rd[b]));
  end

`ifndef SYNTHESIS
  // The load path never meets P4 on a bank, and P4 writes only from its slot
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert (!(ld_we && p4_sel && ld_bank == p4_bank)) else $error("tg_fprf: a load write in P4's bank and cycle");
      assert (!p4_we || p4_sel) else $error("tg_fprf: a P4 write outside its slot");
    end
  end
`endif
endmodule
