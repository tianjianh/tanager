// A behavioural URAM288_BASE for Verilator runs of tb_urf (tests/unit/urf; URF, DR-174), written from UG573's
// description by spikes-2 (fpga/spikes/uram/sim on claude/spikes-2-uram-rf), not from the vendor's model (the
// Makefile runs that too, when Vivado is installed): one clock for both ports; in a clock cycle port A's
// operation happens before port B's, so B reads what A wrote in the same cycle and A does not see B's write;
// a write leaves the port's output unchanged (NO_CHANGE); a disabled port does nothing and holds its output;
// with OREG the output register takes the read data at the next edge where OREG_CE is high. 4K x 72, byte
// writes by BWE (8 data bits each, the ninth bits as the top byte, PARITY_INTERLEAVED order is not
// modelled); no ECC, reset, sleep or cascade.
// TB_URAM_B_FIRST does port B's operation first, against UG573: tb_urf must then fail (a negative test).
module URAM288_BASE #(
  parameter AUTO_SLEEP_LATENCY = 8, parameter AVG_CONS_INACTIVE_CYCLES = 10,
  parameter BWE_MODE_A = "PARITY_INTERLEAVED", parameter BWE_MODE_B = "PARITY_INTERLEAVED",
  parameter EN_AUTO_SLEEP_MODE = "FALSE",
  parameter EN_ECC_RD_A = "FALSE", parameter EN_ECC_RD_B = "FALSE",
  parameter EN_ECC_WR_A = "FALSE", parameter EN_ECC_WR_B = "FALSE",
  parameter IREG_PRE_A = "FALSE", parameter IREG_PRE_B = "FALSE",
  parameter OREG_A = "FALSE", parameter OREG_B = "FALSE",
  parameter OREG_ECC_A = "FALSE", parameter OREG_ECC_B = "FALSE",
  parameter RST_MODE_A = "SYNC", parameter RST_MODE_B = "SYNC",
  parameter USE_EXT_CE_A = "FALSE", parameter USE_EXT_CE_B = "FALSE"
) (
  output logic        DBITERR_A, DBITERR_B, SBITERR_A, SBITERR_B,
  output logic [71:0] DOUT_A, DOUT_B,
  input  logic [22:0] ADDR_A, ADDR_B,
  input  logic [8:0]  BWE_A, BWE_B,
  input  logic        CLK,
  input  logic [71:0] DIN_A, DIN_B,
  input  logic        EN_A, EN_B,
  input  logic        INJECT_DBITERR_A, INJECT_DBITERR_B, INJECT_SBITERR_A, INJECT_SBITERR_B,
  input  logic        OREG_CE_A, OREG_CE_B, OREG_ECC_CE_A, OREG_ECC_CE_B,
  input  logic        RDB_WR_A, RDB_WR_B,
  input  logic        RST_A, RST_B,
  input  logic        SLEEP
);
  logic [71:0] mem [4096];
  logic [71:0] la, lb, ra, rb;    // the ports' read latches and output registers
  function automatic logic [71:0] merge(input logic [71:0] old, input logic [71:0] d, input logic [8:0] bwe);
    logic [71:0] m;
    m = old;
    for (int i = 0; i < 8; i++) if (bwe[i]) m[8*i +: 8] = d[8*i +: 8];
    if (bwe[8]) m[71:64] = d[71:64];
    return m;
  endfunction
  always_ff @(posedge CLK) begin
    logic [11:0] aa, ab;
    aa = ADDR_A[11:0]; ab = ADDR_B[11:0];
`ifndef TB_URAM_B_FIRST
    // port A, then port B
    if (EN_A) begin
      if (RDB_WR_A) mem[aa] = merge(mem[aa], DIN_A, BWE_A);
      else          la <= mem[aa];
    end
`endif
    if (EN_B) begin
      if (RDB_WR_B) mem[ab] = merge(mem[ab], DIN_B, BWE_B);
      else          lb <= mem[ab];
    end
`ifdef TB_URAM_B_FIRST
    if (EN_A) begin
      if (RDB_WR_A) mem[aa] = merge(mem[aa], DIN_A, BWE_A);
      else          la <= mem[aa];
    end
`endif
    if (OREG_CE_A) ra <= la;
    if (OREG_CE_B) rb <= lb;
  end
  assign DOUT_A = (OREG_A == "TRUE") ? ra : la;
  assign DOUT_B = (OREG_B == "TRUE") ? rb : lb;
  assign {DBITERR_A, DBITERR_B, SBITERR_A, SBITERR_B} = '0;
endmodule
