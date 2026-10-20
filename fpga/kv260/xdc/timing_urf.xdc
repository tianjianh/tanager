# Timing constraints for TG_URF=1 builds only (DR-174; build.tcl reads this after timing.xdc): clk2x, the
# core's double-pumped UltraRAM register file's clock, CLKOUT2 of the core clock's MMCM at twice clk_core and
# rising with it (tg_clkgen CLK2X). Without TG_URF nothing reads this file.
# - clk_core and clk2x are synchronous: no exception between them here, so Vivado times every path between the
#   two at the real spacing of their edges (5 ns at 100 / 200 MHz) with the real skew of their trees. The
#   register file's own exceptions (the paths its slot plan gives a full core cycle) are the core's.
# - clk2x and clk_host are asynchronous, as clk_core and clk_host are (timing.xdc): the core's side meets the
#   host's only through the host bridge's XPM crossings, and nothing of clk2x's crosses at all.
# - The two clock trees are balanced against each other: CLOCK_DELAY_GROUP on the nets of the two BUFGs that
#   the MMCM's CLKOUT0 and CLKOUT2 drive, as UG949 advises for synchronous paths between the clocks of one MMCM.
set clk_2x   [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT2]]
set clk_host [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT1]]
set_clock_groups -asynchronous -group $clk_2x -group $clk_host
set tg_2x_mmcm [get_nets -of_objects [get_pins {u_clkgen/u_mmcm/CLKOUT0 u_clkgen/u_mmcm/CLKOUT2}]]
set tg_2x_bufg [get_cells -of_objects [get_pins -leaf -filter {DIRECTION == IN} -of_objects $tg_2x_mmcm]]
set tg_2x_nets [get_nets -of_objects [get_pins -filter {REF_PIN_NAME == O} -of_objects $tg_2x_bufg]]
set_property CLOCK_DELAY_GROUP tg_core_clk2x $tg_2x_nets
