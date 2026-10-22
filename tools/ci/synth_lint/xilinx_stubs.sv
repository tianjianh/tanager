// Port-only stand-ins for the Xilinx primitives and XPM macros that the RTL instantiates under SYNTHESIS,
// for the synthesis-view lint only (make lint SYNTH=1, tools/ci/lint_all.sh; docs/spec/verification.md
// §4.3). Never simulated, never synthesized. Each declares the ports and parameters our instantiations
// use, with the widths of the Xilinx documentation (UG573, UG579, UG974), and drives its outputs with
// zeros, so a signal our RTL takes from a primitive counts as driven. The LUT and SRL primitives come
// from the behavioural models in tests/unit/prim/models instead.

// CARRY8 (UG974): tg_iq_cand's chains (rtl/core/issue/tg_iq.sv, the FPU track's lever 2; for verif-2's review)
module CARRY8 #(
  parameter CARRY_TYPE = "SINGLE_CY8"
) (
  output [7:0] CO,
  output [7:0] O,
  input        CI,
  input        CI_TOP,
  input  [7:0] DI,
  input  [7:0] S
);
  assign CO = '0;
  assign O  = '0;
  wire unused = ^{CI, CI_TOP, DI, S};
endmodule

module DSP48E2 #(
  parameter ACASCREG = 1, parameter ADREG = 1, parameter ALUMODEREG = 1, parameter AMULTSEL = "A",
  parameter AREG = 1, parameter AUTORESET_PATDET = "NO_RESET", parameter AUTORESET_PRIORITY = "RESET",
  parameter A_INPUT = "DIRECT", parameter BCASCREG = 1, parameter BMULTSEL = "B", parameter BREG = 1,
  parameter B_INPUT = "DIRECT", parameter CARRYINREG = 1, parameter CARRYINSELREG = 1, parameter CREG = 1,
  parameter DREG = 1, parameter INMODEREG = 1, parameter MASK = 48'h3fffffffffff, parameter MREG = 1,
  parameter OPMODEREG = 1, parameter PATTERN = 48'h0, parameter PREADDINSEL = "A", parameter PREG = 1,
  parameter RND = 48'h0, parameter SEL_MASK = "MASK", parameter SEL_PATTERN = "PATTERN",
  parameter USE_MULT = "MULTIPLY", parameter USE_PATTERN_DETECT = "NO_PATDET", parameter USE_SIMD = "ONE48",
  parameter USE_WIDEXOR = "FALSE", parameter XORSIMD = "XOR24_48_96"
) (
  input  logic [29:0] A, ACIN,
  input  logic [3:0]  ALUMODE,
  input  logic [17:0] B, BCIN,
  input  logic [47:0] C, PCIN,
  input  logic [26:0] D,
  input  logic        CARRYCASCIN, CARRYIN, MULTSIGNIN, CLK,
  input  logic [2:0]  CARRYINSEL,
  input  logic [4:0]  INMODE,
  input  logic [8:0]  OPMODE,
  input  logic        CEA1, CEA2, CEAD, CEALUMODE, CEB1, CEB2, CEC, CECARRYIN, CECTRL, CED, CEINMODE, CEM, CEP,
  input  logic        RSTA, RSTALLCARRYIN, RSTALUMODE, RSTB, RSTC, RSTCTRL, RSTD, RSTINMODE, RSTM, RSTP,
  output logic [29:0] ACOUT,
  output logic [17:0] BCOUT,
  output logic [47:0] P, PCOUT,
  output logic [3:0]  CARRYOUT,
  output logic [7:0]  XOROUT,
  output logic        CARRYCASCOUT, MULTSIGNOUT, OVERFLOW, PATTERNBDETECT, PATTERNDETECT, UNDERFLOW
);
  assign {ACOUT, BCOUT, P, PCOUT, CARRYOUT, XOROUT} = '0;
  assign {CARRYCASCOUT, MULTSIGNOUT, OVERFLOW, PATTERNBDETECT, PATTERNDETECT, UNDERFLOW} = '0;
endmodule

// UltraRAM (UG573): tg_urf's copies (URF, DR-174)
module URAM288_BASE #(
  parameter BWE_MODE_A = "PARITY_INTERLEAVED", parameter BWE_MODE_B = "PARITY_INTERLEAVED",
  parameter EN_AUTO_SLEEP_MODE = "FALSE", parameter EN_ECC_RD_A = "FALSE", parameter EN_ECC_RD_B = "FALSE",
  parameter EN_ECC_WR_A = "FALSE", parameter EN_ECC_WR_B = "FALSE", parameter IREG_PRE_A = "FALSE",
  parameter IREG_PRE_B = "FALSE", parameter OREG_A = "FALSE", parameter OREG_B = "FALSE",
  parameter OREG_ECC_A = "FALSE", parameter OREG_ECC_B = "FALSE", parameter RST_MODE_A = "SYNC",
  parameter RST_MODE_B = "SYNC", parameter USE_EXT_CE_A = "FALSE", parameter USE_EXT_CE_B = "FALSE"
) (
  input  logic [22:0] ADDR_A, ADDR_B,
  input  logic [8:0]  BWE_A, BWE_B,
  input  logic        CLK,
  input  logic [71:0] DIN_A, DIN_B,
  input  logic        EN_A, EN_B, INJECT_DBITERR_A, INJECT_DBITERR_B, INJECT_SBITERR_A, INJECT_SBITERR_B,
  input  logic        OREG_CE_A, OREG_CE_B, OREG_ECC_CE_A, OREG_ECC_CE_B, RDB_WR_A, RDB_WR_B, RST_A, RST_B, SLEEP,
  output logic [71:0] DOUT_A, DOUT_B,
  output logic        DBITERR_A, DBITERR_B, SBITERR_A, SBITERR_B
);
  assign {DOUT_A, DOUT_B} = '0;
  assign {DBITERR_A, DBITERR_B, SBITERR_A, SBITERR_B} = '0;
endmodule

module xpm_memory_sdpram #(
  parameter ADDR_WIDTH_A = 6, parameter ADDR_WIDTH_B = 6, parameter BYTE_WRITE_WIDTH_A = 32,
  parameter CLOCKING_MODE = "common_clock", parameter MEMORY_INIT_FILE = "none",
  parameter MEMORY_PRIMITIVE = "auto", parameter MEMORY_SIZE = 2048, parameter READ_DATA_WIDTH_B = 32,
  parameter READ_LATENCY_B = 2, parameter USE_MEM_INIT = 1, parameter WRITE_DATA_WIDTH_A = 32,
  parameter WRITE_MODE_B = "no_change"
) (
  input  logic sleep, clka, ena, injectsbiterra, injectdbiterra, clkb, rstb, enb, regceb,
  input  logic [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea,
  input  logic [ADDR_WIDTH_A-1:0]       addra,
  input  logic [WRITE_DATA_WIDTH_A-1:0] dina,
  input  logic [ADDR_WIDTH_B-1:0]       addrb,
  output logic [READ_DATA_WIDTH_B-1:0]  doutb,
  output logic sbiterrb, dbiterrb
);
  assign {doutb, sbiterrb, dbiterrb} = '0;
endmodule

module xpm_memory_tdpram #(
  parameter ADDR_WIDTH_A = 6, parameter ADDR_WIDTH_B = 6, parameter BYTE_WRITE_WIDTH_A = 32,
  parameter BYTE_WRITE_WIDTH_B = 32, parameter CASCADE_HEIGHT = 0, parameter CLOCKING_MODE = "common_clock",
  parameter MEMORY_INIT_FILE = "none", parameter MEMORY_PRIMITIVE = "auto", parameter MEMORY_SIZE = 2048,
  parameter READ_DATA_WIDTH_A = 32, parameter READ_DATA_WIDTH_B = 32, parameter READ_LATENCY_A = 2,
  parameter READ_LATENCY_B = 2, parameter USE_MEM_INIT = 1, parameter WRITE_DATA_WIDTH_A = 32,
  parameter WRITE_DATA_WIDTH_B = 32, parameter WRITE_MODE_A = "no_change", parameter WRITE_MODE_B = "no_change"
) (
  input  logic sleep, clka, rsta, ena, regcea, clkb, rstb, enb, regceb,
  input  logic injectsbiterra, injectdbiterra, injectsbiterrb, injectdbiterrb,
  input  logic [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea,
  input  logic [WRITE_DATA_WIDTH_B/BYTE_WRITE_WIDTH_B-1:0] web,
  input  logic [ADDR_WIDTH_A-1:0]       addra,
  input  logic [ADDR_WIDTH_B-1:0]       addrb,
  input  logic [WRITE_DATA_WIDTH_A-1:0] dina,
  input  logic [WRITE_DATA_WIDTH_B-1:0] dinb,
  output logic [READ_DATA_WIDTH_A-1:0]  douta,
  output logic [READ_DATA_WIDTH_B-1:0]  doutb,
  output logic sbiterra, dbiterra, sbiterrb, dbiterrb
);
  assign {douta, doutb, sbiterra, dbiterra, sbiterrb, dbiterrb} = '0;
endmodule

module xpm_fifo_async #(
  parameter CDC_SYNC_STAGES = 2, parameter DOUT_RESET_VALUE = "0", parameter ECC_MODE = "no_ecc",
  parameter FIFO_MEMORY_TYPE = "auto", parameter FIFO_READ_LATENCY = 1, parameter FIFO_WRITE_DEPTH = 2048,
  parameter FULL_RESET_VALUE = 0, parameter PROG_EMPTY_THRESH = 10, parameter PROG_FULL_THRESH = 10,
  parameter RD_DATA_COUNT_WIDTH = 1, parameter READ_DATA_WIDTH = 32, parameter READ_MODE = "std",
  parameter RELATED_CLOCKS = 0, parameter SIM_ASSERT_CHK = 0, parameter USE_ADV_FEATURES = "0707",
  parameter WAKEUP_TIME = 0, parameter WRITE_DATA_WIDTH = 32, parameter WR_DATA_COUNT_WIDTH = 1
) (
  input  logic sleep, rst, wr_clk, wr_en, rd_clk, rd_en, injectsbiterr, injectdbiterr,
  input  logic [WRITE_DATA_WIDTH-1:0]    din,
  output logic [READ_DATA_WIDTH-1:0]     dout,
  output logic [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
  output logic [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
  output logic full, empty, wr_rst_busy, rd_rst_busy, prog_full, overflow, wr_ack, almost_full,
  output logic prog_empty, underflow, data_valid, almost_empty, sbiterr, dbiterr
);
  assign {dout, rd_data_count, wr_data_count} = '0;
  assign {full, empty, wr_rst_busy, rd_rst_busy, prog_full, overflow, wr_ack, almost_full} = '0;
  assign {prog_empty, underflow, data_valid, almost_empty, sbiterr, dbiterr} = '0;
endmodule

module xpm_cdc_single #(
  parameter DEST_SYNC_FF = 4, parameter INIT_SYNC_FF = 0, parameter SIM_ASSERT_CHK = 0,
  parameter SRC_INPUT_REG = 1
) (
  input  logic src_clk, src_in, dest_clk,
  output logic dest_out
);
  assign dest_out = 1'b0;
endmodule

module xpm_cdc_pulse #(
  parameter DEST_SYNC_FF = 4, parameter INIT_SYNC_FF = 0, parameter REG_OUTPUT = 0, parameter RST_USED = 1,
  parameter SIM_ASSERT_CHK = 0
) (
  input  logic src_clk, src_rst, src_pulse, dest_clk, dest_rst,
  output logic dest_pulse
);
  assign dest_pulse = 1'b0;
endmodule

module xpm_cdc_handshake #(
  parameter DEST_EXT_HSK = 1, parameter DEST_SYNC_FF = 4, parameter INIT_SYNC_FF = 0,
  parameter SIM_ASSERT_CHK = 0, parameter SRC_SYNC_FF = 4, parameter WIDTH = 1
) (
  input  logic             src_clk, src_send, dest_clk, dest_ack,
  input  logic [WIDTH-1:0] src_in,
  output logic             src_rcv, dest_req,
  output logic [WIDTH-1:0] dest_out
);
  assign {src_rcv, dest_req, dest_out} = '0;
endmodule
