# Takes back over_unc.tcl's setup uncertainty on the core clock after routing, so the reports give the
# slack at the real period (g4_fit.tcl -pre_report).
set_clock_uncertainty -setup 0 [get_clocks c0]
