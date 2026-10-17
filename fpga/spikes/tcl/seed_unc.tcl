# A second placement sample of one netlist (spike G8, 2026-10-17). Vivado's placer has no seed, and
# -place_directive Explore gave a placement identical to Default's on G8, so this perturbs the
# timing-driven placement with 0.05 ns of setup uncertainty on the core clock (c0). The timing.xdc
# constraints set no uncertainty of their own. Pair it with -pre_report fpga/spikes/tcl/seed_unc_off.tcl,
# which takes the 0.05 ns back after routing so the reports compare with an unperturbed run.
#   g4_fit.tcl ... -constraints fpga/spikes/tcl/seed_unc.tcl -pre_report fpga/spikes/tcl/seed_unc_off.tcl
source [file join $root fpga spikes tcl g3_false_paths.tcl]
set_clock_uncertainty -setup 0.05 [get_clocks c0]
set cfh [open constraints.txt a]
puts $cfh "placement seed: set_clock_uncertainty -setup 0.05 on c0 for placement and routing, taken back before the reports"
close $cfh
