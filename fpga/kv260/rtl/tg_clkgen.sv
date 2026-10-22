// Clock generation for the KV260 build (docs/spec/soc.md §2.1, plan §7.1): one MMCM from the PS's
// pl_clk0 (100 MHz). clk_core = VCO / (VCO / CORE_MHZ), clk_host = VCO / (VCO / 100) = 100 MHz.
// The VCO is 1200 MHz when CORE_MHZ divides it (100, 120, 150, 200 ..., every earlier build);
// otherwise the first multiple of 100 MHz in the MMCM's 800-1600 MHz range that CORE_MHZ divides
// in eighths (CLKOUT0's fractional divide), for example 1000 MHz and a divide of 8 at 125 MHz
// (DR-145). A multiple of 100 MHz keeps clk_host's divide an integer.
// CLK2X (DR-174's URF, the core's double-pumped UltraRAM register file): clk2x = VCO / (VCO / (2 * CORE_MHZ))
// on CLKOUT2, twice clk_core and rising with it (one VCO, both at phase 0), on a BUFG of its own: 200 MHz at
// 100 (1200 / 6). CLKOUT2's divide is an integer, so the VCO must be a multiple of 2 * CORE_MHZ, and the choice
// above takes the first VCO that is (800 MHz at 80, DR-187: 1200 / 160 is no integer). Without
// CLK2X, CLKOUT2 keeps its default divide and drives nothing, and clk2x is 0: the MMCM of every earlier build.
module tg_clkgen #(
  parameter int CORE_MHZ = 100,
  parameter bit CLK2X    = 1'b0
) (
  input  logic clk_in,      // pl_clk0, 100 MHz
  input  logic rst_in,      // active high (from !pl_resetn0)
  output logic clk_core,
  output logic clk2x,       // CLK2X: twice clk_core, rising with it; else 0
  output logic clk_host,
  output logic locked
);
  function automatic int pick_vco(input int mhz, input bit c2x);
    if (mhz <= 0) return 0;
    if (1200 % mhz == 0 && (!c2x || 1200 % (2 * mhz) == 0)) return 1200;
    for (int v = 800; v <= 1600; v += 100) if ((8 * v) % mhz == 0 && (!c2x || v % (2 * mhz) == 0)) return v;
    return 0;
  endfunction
  localparam int  VCO      = pick_vco(CORE_MHZ, CLK2X);
  localparam real CORE_DIV = real'(VCO) / real'(CORE_MHZ);
  localparam int  C2X_DIV  = CLK2X && VCO > 0 ? VCO / (2 * CORE_MHZ) : 1;

  if (VCO == 0) begin : g_bad_mhz
    $error("tg_clkgen: no VCO of 800-1600 MHz in steps of 100 that CORE_MHZ divides in eighths (and with CLK2X, that 2 * CORE_MHZ divides)");
  end
  if (CLK2X && VCO % (2 * CORE_MHZ) != 0) begin : g_bad_2x
    $error("tg_clkgen: CLK2X needs a VCO that 2 * CORE_MHZ divides (CLKOUT2's divide is an integer)");
  end

  logic fb, c0, c1, c2x;
  MMCME4_BASE #(
    .BANDWIDTH        ("OPTIMIZED"),
    .CLKIN1_PERIOD    (10.0),
    .DIVCLK_DIVIDE    (1),
    .CLKFBOUT_MULT_F  (real'(VCO / 100)),
    .CLKOUT0_DIVIDE_F (CORE_DIV),
    .CLKOUT1_DIVIDE   (VCO / 100),
    .CLKOUT2_DIVIDE   (C2X_DIV),
    .STARTUP_WAIT     ("FALSE")
  ) u_mmcm (
    .CLKIN1   (clk_in),
    .CLKFBIN  (fb),
    .CLKFBOUT (fb),
    .CLKFBOUTB(),
    .CLKOUT0  (c0),
    .CLKOUT0B (),
    .CLKOUT1  (c1),
    .CLKOUT1B (),
    .CLKOUT2  (c2x),
    .CLKOUT2B (), .CLKOUT3 (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
    .LOCKED   (locked),
    .PWRDWN   (1'b0),
    .RST      (rst_in)
  );
  BUFG u_bufg_core (.I (c0), .O (clk_core));
  BUFG u_bufg_host (.I (c1), .O (clk_host));
  if (CLK2X) begin : g_2x
    BUFG u_bufg_2x (.I (c2x), .O (clk2x));
  end else begin : g_no_2x
    assign clk2x = 1'b0;
    wire unused_c2x = c2x;
  end
endmodule
