// A stand-in for Xilinx's SYSMONE4 in the fan regulator's test (tests/unit/fan): only the DRP, which answers a
// read with the testbench's temperature code (code) DLAT cycles after DEN, or never while silent is set.
module SYSMONE4 #(
  parameter SIM_DEVICE = "ULTRASCALE_PLUS"
) (
  output logic [15:0] ADC_DATA, output logic [15:0] ALM, output logic BUSY, output logic [5:0] CHANNEL,
  output logic [15:0] DO, output logic DRDY, output logic EOC, output logic EOS, output logic I2C_SCLK_TS,
  output logic I2C_SDA_TS, output logic JTAGBUSY, output logic JTAGLOCKED, output logic JTAGMODIFIED,
  output logic [4:0] MUXADDR, output logic OT, output logic SMBALERT_TS,
  input logic CONVST, input logic CONVSTCLK, input logic [7:0] DADDR, input logic DCLK, input logic DEN,
  input logic [15:0] DI, input logic DWE, input logic I2C_SCLK, input logic I2C_SDA, input logic RESET,
  input logic [15:0] VAUXN, input logic [15:0] VAUXP, input logic VN, input logic VP
);
  localparam int DLAT = 6;
  logic [15:0] code = 16'd0;
  bit          silent = 1'b0;
  int          reads = 0, bad = 0;
  int          cnt = 0;
  always_ff @(posedge DCLK) begin
    DRDY <= 1'b0;
    if (DEN) begin
      reads <= reads + 1;
      if (DADDR != 8'h00 || DWE) bad <= bad + 1;
      cnt <= silent ? 0 : DLAT;
    end else if (cnt > 0) begin
      cnt <= cnt - 1;
      if (cnt == 1) begin DRDY <= 1'b1; DO <= code; end
    end
  end
  assign {ADC_DATA, ALM, BUSY, CHANNEL, EOC, EOS, I2C_SCLK_TS, I2C_SDA_TS, JTAGBUSY, JTAGLOCKED, JTAGMODIFIED,
          MUXADDR, OT, SMBALERT_TS} = '0;
  wire unused = ^{SIM_DEVICE, CONVST, CONVSTCLK, DI, I2C_SCLK, I2C_SDA, RESET, VAUXN, VAUXP, VN, VP};
endmodule
