# One placement form for a netlist that doesn't pack (spikes §8.18, M9's area package, the coordinator, 10-24): from
# build.tcl's post_opt.dcp (TG_CHECKPOINT=1: opt_design done), the placement uncertainty on clk_core and clk2x as
# build.tcl sets it (TG_PR_UNC, TG_URF=1), DR-181's soft pblocks (the L2 banks, the crossbar) kept or removed, then
# place_design with the given directive and build.tcl's own steps after it: phys_opt_design, route_design, the
# uncertainty taken back, routed.dcp and the reports. A placement that fails is recorded with its error (Place
# 30-487's CLB count is in vivado.log). Writes trial.txt: the form, each step's WNS, TNS, failing endpoints and WHS,
# and the CLBs and LUTs in use.
# [reopt] is a second opt_design pass before placement, its options comma-separated without the dash (e.g.
# remap,aggressive_remap,resynth_seq_area,control_set_merge; - for none), for a netlist a little too big to pack.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/place_trial.tcl <post_opt.dcp> <place directive> <keep|none> [unc=1.05] [phys=Default] [route=AlternateCLBRouting] [reopt=-]   (about 22 GB)
lassign $argv dcp pdir fp unc phys route reopt
if {$unc eq ""} { set unc 1.05 }
if {$phys eq ""} { set phys Default }
if {$route eq ""} { set route AlternateCLBRouting }
if {$reopt eq ""} { set reopt - }
if {$fp ni {keep none}} { puts "ERROR: the floorplan argument is keep or none"; exit 1 }
open_checkpoint $dcp
set fh [open trial.txt w]
puts $fh "dcp=[file normalize $dcp] place=$pdir floorplan=$fp unc=$unc phys=$phys route=$route reopt=$reopt"
# The Design Timing Summary row of report_timing_summary: WNS, TNS, TNS failing endpoints, WHS (post_route_opt.tcl's)
proc tsum {} {
  set lines [split [report_timing_summary -no_detailed_paths -return_string] "\n"]
  set i [lsearch -regexp $lines {^\s+WNS\(ns\)\s+TNS\(ns\)}]
  set v [regexp -all -inline {\S+} [lindex $lines [expr {$i + 2}]]]
  return [list [lindex $v 0] [lindex $v 1] [lindex $v 2] [lindex $v 4]]
}
# report_utilization's row for a resource: used, available, percent
proc urow {name} {
  foreach l [split [report_utilization -return_string] "\n"] {
    if {[regexp "^\\|\\s*${name}\\s*\\|\\s*(\\d+)\\s*\\|\[^|\]*\\|\[^|\]*\\|\\s*(\\d+)\\s*\\|\\s*(\[\\d.\]+)" $l -> u a p]} { return "$u of $a ($p%)" }
  }
  return "?"
}
set clks [get_clocks -quiet {c0 c2x}]
puts $fh "the uncertainty's clocks: $clks"
if {[llength $clks] != 2} { puts $fh "ERROR: c0 and c2x not both found"; close $fh; exit 1 }
set_clock_uncertainty -setup $unc $clks
if {$fp eq "none"} {
  set pbs [get_pblocks -quiet]
  puts $fh "pblocks removed: [llength $pbs] ($pbs)"
  if {[llength $pbs]} { delete_pblocks $pbs }
} else {
  puts $fh "pblocks kept: [get_pblocks -quiet]"
}
puts $fh "after opt_design: CLB LUTs [urow {CLB LUTs\*?}], LUTs as memory [urow {  LUT as Memory}], control sets [urow {Unique Control Sets}]"
if {$reopt ne "-"} {
  set oargs [lmap o [split $reopt ,] {string cat - $o}]
  flush $fh
  opt_design {*}$oargs
  puts $fh "opt_design $oargs: CLB LUTs [urow {CLB LUTs\*?}], LUTs as memory [urow {  LUT as Memory}], control sets [urow {Unique Control Sets}]"
}
flush $fh
if {[catch {place_design -directive $pdir} err]} {
  puts $fh "place_design -directive $pdir: FAILED ($err)"
  close $fh
  puts "PLACE_TRIAL_DONE"
  exit 0
}
lassign [tsum] w t n h
puts $fh "place_design -directive $pdir: placed; CLBs [urow CLB], CLB LUTs [urow {CLB LUTs\*?}]; estimated WNS $w TNS $t failing $n (uncertainty on)"
flush $fh
phys_opt_design -directive $phys
lassign [tsum] w t n h
puts $fh "phys_opt_design -directive $phys: WNS $w TNS $t failing $n (uncertainty on)"
flush $fh
if {[catch {route_design -directive $route} err]} {
  puts $fh "route_design -directive $route: FAILED ($err)"
  close $fh
  puts "PLACE_TRIAL_DONE"
  exit 0
}
set_clock_uncertainty -setup 0 $clks
write_checkpoint -force routed.dcp
report_timing_summary -max_paths 20 -report_unconstrained -file timing_summary.rpt
report_utilization -file utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file utilization_hier.rpt
lassign [tsum] w t n h
puts $fh "route_design -directive $route: routed; CLBs [urow CLB], CLB LUTs [urow {CLB LUTs\*?}]"
puts $fh "final (the real period): WNS $w TNS $t failing $n WHS $h"
close $fh
puts "PLACE_TRIAL_DONE"
