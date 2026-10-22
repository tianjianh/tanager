# Tests fp_lib.tcl's two floorplan checks (spikes §8.18, DR-181): tg_fp_check on a post-synthesis checkpoint with a
# floorplan sourced as g4_fit.tcl does, and tg_fp_check_placed on a routed checkpoint, whose pblocks it carries
# (skipped for "-"). Writes fp_checks.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_fp_checks.tcl <root> <post_synth.dcp> <floorplan.tcl> <routed.dcp|->
lassign $argv root sdcp fp rdcp
source [file join $root fpga spikes tcl fp_lib.tcl]
set fs [open fp_checks.txt w]
open_checkpoint $sdcp
close [open floorplan.txt w]
source [file join $root $fp]
puts $fs "== tg_fp_check on $sdcp: highest [format %.0f [tg_fp_check]]%"
close_design
if {$rdcp ne "-"} {
  open_checkpoint $rdcp
  puts $fs "== tg_fp_check_placed on $rdcp: highest [format %.0f [tg_fp_check_placed]]%"
  close_design
}
close $fs
puts "Q_FP_CHECKS_DONE"
