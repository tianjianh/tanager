// Clock generation for the KV260 build (docs/spec/soc.md §2.1, plan §7.1): one MMCM from the PS's
// pl_clk0 (100 MHz). VCO = 1200 MHz; clk_core = 1200 / (1200 / CORE_MHZ), clk_host = 100 MHz.
// CORE_MHZ must divide 1200 (100, 120, 150, 200 ...).
module tg_clkgen #(
  parameter int CORE_MHZ = 100
) (
  input  logic clk_in,      // pl_clk0, 100 MHz
  input  logic rst_in,      // active high (from !pl_resetn0)
  output logic clk_core,
  output logic clk_host,
  output logic locked
);
  localparam real CORE_DIV = 1200.0 / CORE_MHZ;

  if ((1200 % CORE_MHZ) != 0) begin : g_bad_mhz
    $error("tg_clkgen: CORE_MHZ must divide 1200");
  end

  logic fb, c0, c1;
  MMCME4_BASE #(
    .BANDWIDTH        ("OPTIMIZED"),
    .CLKIN1_PERIOD    (10.0),
    .DIVCLK_DIVIDE    (1),
    .CLKFBOUT_MULT_F  (12.0),
    .CLKOUT0_DIVIDE_F (CORE_DIV),
    .CLKOUT1_DIVIDE   (12),
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
