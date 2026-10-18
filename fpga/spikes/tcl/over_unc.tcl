# Over-constrains placement and routing for a closure check at a loose clock (the area-headroom series at
# 100 MHz, 2026-10-17): at a 100 MHz constraint the placer under-works the cores (spikes.md §8.6:
# g5r_100_fill reached -2.683 ns at 10 ns while the same tree routed at 125 MHz had a 10.2 ns worst path),
# so this adds TG_OVER_UNC ns (default 1.0) of setup uncertainty on the core clock c0 for placement and
# routing. Pair it with -pre_report fpga/spikes/tcl/over_unc_off.tcl, which takes it back after routing,
# so the reports give the slack at the real period. timing.xdc sets no uncertainty of its own.
#   g4_fit.tcl ... -constraints fpga/spikes/tcl/over_unc.tcl -pre_report fpga/spikes/tcl/over_unc_off.tcl
set u [expr {[info exists ::env(TG_OVER_UNC)] ? $::env(TG_OVER_UNC) : 1.0}]
set_clock_uncertainty -setup $u [get_clocks c0]
set cfh [open constraints.txt a]
puts $cfh "over-constraint: set_clock_uncertainty -setup $u on c0 for placement and routing, taken back before the reports"
close $cfh
