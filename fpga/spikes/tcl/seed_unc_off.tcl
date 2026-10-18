# Takes back seed_unc.tcl's 0.05 ns of setup uncertainty on the core clock after routing, so the reports
# of a perturbed placement compare with an unperturbed run's (g4_fit.tcl -pre_report).
set_clock_uncertainty -setup 0 [get_clocks c0]
