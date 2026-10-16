// Clock generation for the KV260 build (docs/spec/soc.md §2.1, plan §7.1): one MMCM from the PS's
// pl_clk0 (100 MHz). clk_core = VCO / (VCO / CORE_MHZ), clk_host = VCO / (VCO / 100) = 100 MHz.
// The VCO is 1200 MHz when CORE_MHZ divides it (100, 120, 150, 200 ..., every earlier build);
// otherwise the first multiple of 100 MHz in the MMCM's 800-1600 MHz range that CORE_MHZ divides
// in eighths (CLKOUT0's fractional divide), for example 1000 MHz and a divide of 8 at 125 MHz
// (DR-145). A multiple of 100 MHz keeps clk_host's divide an integer.
module tg_clkgen #(
  parameter int CORE_MHZ = 100
) (
  input  logic clk_in,      // pl_clk0, 100 MHz
  input  logic rst_in,      // active high (from !pl_resetn0)
  output logic clk_core,
  output logic clk_host,
  output logic locked
);
  function automatic int pick_vco(input int mhz);
    if (mhz <= 0) return 0;
    if (1200 % mhz == 0) return 1200;
    for (int v = 800; v <= 1600; v += 100) if ((8 * v) % mhz == 0) return v;
    return 0;
  endfunction
  localparam int  VCO      = pick_vco(CORE_MHZ);
  localparam real CORE_DIV = real'(VCO) / real'(CORE_MHZ);

  if (VCO == 0) begin : g_bad_mhz
    $error("tg_clkgen: no VCO of 800-1600 MHz in steps of 100 that CORE_MHZ divides in eighths");
  end

  logic fb, c0, c1;
  MMCME4_BASE #(
    .BANDWIDTH        ("OPTIMIZED"),
    .CLKIN1_PERIOD    (10.0),
    .DIVCLK_DIVIDE    (1),
    .CLKFBOUT_MULT_F  (real'(VCO / 100)),
    .CLKOUT0_DIVIDE_F (CORE_DIV),
    .CLKOUT1_DIVIDE   (VCO / 100),
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
    .CLKOUT2  (), .CLKOUT2B (), .CLKOUT3 (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
    .LOCKED   (locked),
    .PWRDWN   (1'b0),
    .RST      (rst_in)
  );
  BUFG u_bufg_core (.I (c0), .O (clk_core));
  BUFG u_bufg_host (.I (c1), .O (clk_host));
endmodule
