# Takes back over_unc.tcl's setup uncertainty on the core clock after routing, so the reports give the
# slack at the real period (g4_fit.tcl -pre_report).
set_clock_uncertainty -setup 0 [get_clocks c0]
# and clk2x's in a URF build (DR-174)
set c2x [get_clocks -quiet -of_objects [get_pins -quiet u_clkgen/u_mmcm/CLKOUT2]]
if {[llength $c2x]} { set_clock_uncertainty -setup 0 $c2x }
