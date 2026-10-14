# Timing constraints for the KV260 build (docs/spec/soc.md §2.4).
# pl_clk0 comes from the PS (constrained by the PS IP); the MMCM's outputs are derived from it.
# clk_core and clk_host meet only in the host bridge, through XPM CDC macros (which carry their own
# scoped constraints); the two domains are asynchronous by design.
set clk_core [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT0]]
set clk_host [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT1]]
set_clock_groups -asynchronous -group $clk_core -group $clk_host
