// Simulation model of the UltraScale+ RAM64X8SW primitive for unit tests of the tg_cam_lut
// "sw" mapping (TG_SIM_PRIMS), written from the documented behaviour (UG974): a 64 x 8
// single-port RAM; O is the 8-bit word at A (asynchronous read); on the rising WCLK edge
// with WE high, bit WSEL of the word at A takes D. INIT_A..INIT_H are bits 0..7.
/* verilator lint_off DECLFILENAME */
module RAM64X8SW #(
  parameter logic [63:0] INIT_A = '0, INIT_B = '0, INIT_C = '0, INIT_D = '0,
  parameter logic [63:0] INIT_E = '0, INIT_F = '0, INIT_G = '0, INIT_H = '0,
  parameter bit IS_WCLK_INVERTED = 1'b0
) (
  output logic [7:0] O,
  input  logic [5:0] A,
  input  logic       D, WCLK, WE,
  input  logic [2:0] WSEL
);
  logic [63:0] m [8];   // m[b]: bit b of every word (unpacked, so Icarus takes it too)
  initial begin
    m[0] = INIT_A; m[1] = INIT_B; m[2] = INIT_C; m[3] = INIT_D;
    m[4] = INIT_E; m[5] = INIT_F; m[6] = INIT_G; m[7] = INIT_H;
  end
  always @(posedge WCLK) begin
    if (WE) m[WSEL][A] <= D;
  end
  for (genvar b = 0; b < 8; b++) begin : g_o
    assign O[b] = m[b][A];
  end
  wire unused = IS_WCLK_INVERTED;
endmodule
/* verilator lint_on DECLFILENAME */
