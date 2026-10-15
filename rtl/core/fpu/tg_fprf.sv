// FP register file (docs/spec/fpu.md, "Core integration"; plan §4.7): writer-sharded banks F0
// (written only by P4's F0 stream) and F1 (written only by the load path), FP_PREGS_PER_BANK x 64
// bits each. NR asynchronous read ports read either bank: each bank is one tg_ram_lut with NR
// read ports (explicit RAM64M8, ceil(NR * 64 / 7) per bank). Both banks leave the module: each user
// selects the bank in a multiplexer of its own (tg_fp_exec's RF stage for the operands, the core's
// store-data and trace multiplexers; fpga_friendly.md T7). Read-during-write follows tg_ram_lut:
// the new value is visible after the write edge. The reset sequence's zero writes come through
// the F0 port (tg_fp_exec).
module tg_fprf
  import tg_pkg::*, tg_core_pkg::*, tg_fpcore_pkg::*;
#(
  parameter int NR = 4
) (
  input  logic                        clk,
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

  for (genvar b = 0; b < 2; b++) begin : g_bank
    tg_ram_lut #(.DEPTH(FP_PREGS_PER_BANK), .WIDTH(64), .NR(NR)) u_ram (
      .clk, .we(we[b]), .waddr(wa[b]), .wdata(wd[b]), .raddr(ridx), .rdata(bank_rd[b]));
  end
endmodule
