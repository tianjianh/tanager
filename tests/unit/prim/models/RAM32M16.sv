// Simulation model of the UltraScale+ RAM32M16 primitive for unit tests of the tg_ram_lut
// mapping (TG_SIM_PRIMS), written from the documented behaviour (UG974): eight 32 x 2
// memories with independent asynchronous read addresses; all are written at ADDRH with
// their own DI on the rising WCLK edge when WE is high.
/* verilator lint_off DECLFILENAME */
module RAM32M16 #(
  parameter logic [63:0] INIT_A = '0, INIT_B = '0, INIT_C = '0, INIT_D = '0,
  parameter logic [63:0] INIT_E = '0, INIT_F = '0, INIT_G = '0, INIT_H = '0,
  parameter bit IS_WCLK_INVERTED = 1'b0
) (
  output logic [1:0] DOA, DOB, DOC, DOD, DOE, DOF, DOG, DOH,
  input  logic [4:0] ADDRA, ADDRB, ADDRC, ADDRD, ADDRE, ADDRF, ADDRG, ADDRH,
  input  logic [1:0] DIA, DIB, DIC, DID, DIE, DIF, DIG, DIH,
  input  logic WCLK, WE
);
  logic [7:0][31:0][1:0] m = {INIT_H, INIT_G, INIT_F, INIT_E, INIT_D, INIT_C, INIT_B, INIT_A};
  always_ff @(posedge WCLK) begin
    if (WE) begin
      m[0][ADDRH] <= DIA; m[1][ADDRH] <= DIB; m[2][ADDRH] <= DIC; m[3][ADDRH] <= DID;
      m[4][ADDRH] <= DIE; m[5][ADDRH] <= DIF; m[6][ADDRH] <= DIG; m[7][ADDRH] <= DIH;
    end
  end
  assign DOA = m[0][ADDRA]; assign DOB = m[1][ADDRB]; assign DOC = m[2][ADDRC];
  assign DOD = m[3][ADDRD]; assign DOE = m[4][ADDRE]; assign DOF = m[5][ADDRF];
  assign DOG = m[6][ADDRG]; assign DOH = m[7][ADDRH];
  wire unused = IS_WCLK_INVERTED;
endmodule
/* verilator lint_on DECLFILENAME */
