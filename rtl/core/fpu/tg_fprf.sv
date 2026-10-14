// FP register file (docs/spec/fpu.md, "Core integration"; plan §4.7): writer-sharded banks F0
// (written only by P4's F0 stream) and F1 (written only by the load path), FP_PREGS_PER_BANK x 64
// bits each. NR asynchronous read ports read either bank: each bank is one tg_ram_lut with NR
// read ports (explicit RAM64M8, ceil(NR * 64 / 7) per bank) and a read selects its bank after
// the LUTRAM. Read-during-write follows tg_ram_lut: the new value is visible after the write
// edge. The init port writes zero (the reset sequence's initial FP map) and has priority.
module tg_fprf
  import tg_pkg::*, tg_fpcore_pkg::*;
#(
  parameter int NR = 4
) (
  input  logic                        clk,
  input  logic                        init_we,
  input  logic                        init_bank,
  input  logic [FPIDX_W-1:0]          init_idx,
  input  logic                        f0_we,
  input  logic [FPIDX_W-1:0]          f0_waddr,
  input  logic [63:0]                 f0_wdata,
  input  logic                        f1_we,
  input  logic [FPIDX_W-1:0]          f1_waddr,
  input  logic [63:0]                 f1_wdata,
  input  logic [NR-1:0][FPTAG_W-1:0]  rtag,        // {bank, index}
  output logic [NR-1:0][63:0]         rdata
);
  logic [1:0]               we;
  logic [1:0][FPIDX_W-1:0]  wa;
  logic [1:0][63:0]         wd;
  always_comb begin
    we = {f1_we, f0_we};
    wa = {f1_waddr, f0_waddr};
    wd = {f1_wdata, f0_wdata};
    if (init_we) begin
      we[init_bank] = 1'b1;
      wa[init_bank] = init_idx;
      wd[init_bank] = '0;
    end
  end

  logic [NR-1:0][FPIDX_W-1:0] ridx;
  for (genvar p = 0; p < NR; p++) begin : g_ridx
    assign ridx[p] = rtag[p][FPIDX_W-1:0];
  end

  logic [1:0][NR-1:0][63:0] bank_rd;
  for (genvar b = 0; b < 2; b++) begin : g_bank
    tg_ram_lut #(.DEPTH(FP_PREGS_PER_BANK), .WIDTH(64), .NR(NR)) u_ram (
      .clk, .we(we[b]), .waddr(wa[b]), .wdata(wd[b]), .raddr(ridx), .rdata(bank_rd[b]));
  end
  for (genvar p = 0; p < NR; p++) begin : g_rd
    assign rdata[p] = rtag[p][FPIDX_W] ? bank_rd[1][p] : bank_rd[0][p];
  end
endmodule
