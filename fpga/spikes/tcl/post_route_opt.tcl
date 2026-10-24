# Post-route physical optimization of a routed checkpoint (spikes §8.18: rc3_u110 at -0.237 ns, the coordinator, 10-23):
# phys_opt_design with each directive given in turn (AggressiveExplore, then AggressiveFanoutOpt or
# AlternateFlowWithRetiming), each followed by route_design for whatever it moved, stopping once setup and hold are met.
# The checkpoint's own constraints are the start: build.tcl takes the placement uncertainty back before it writes
# routed.dcp, so this optimizes the real slack. Writes post_route_opt.txt (each pass's WNS, TNS, failing endpoints and
# WHS), routed.dcp (the result), timing_pro.rpt and utilization_pro.rpt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/post_route_opt.tcl <routed.dcp> <directive>...   (about 22 GB)
set dcp [lindex $argv 0]
set dirs [lrange $argv 1 end]
open_checkpoint $dcp
set fs [open post_route_opt.txt w]
# The Design Timing Summary row of report_timing_summary: WNS, TNS, TNS failing endpoints, WHS
proc tsum {} {
  set lines [split [report_timing_summary -no_detailed_paths -return_string] "\n"]
  set i [lsearch -regexp $lines {^\s+WNS\(ns\)\s+TNS\(ns\)}]
  set v [regexp -all -inline {\S+} [lindex $lines [expr {$i + 2}]]]
  return [list [lindex $v 0] [lindex $v 1] [lindex $v 2] [lindex $v 4]]
}
lassign [tsum] w t n h
puts $fs "start: WNS $w TNS $t failing $n WHS $h ([file normalize $dcp])"
flush $fs
set steps {}
foreach d $dirs {
  if {$w >= 0 && $h >= 0} break
  phys_opt_design -directive $d
  lassign [tsum] w t n h
  puts $fs "phys_opt_design -directive $d: WNS $w TNS $t failing $n WHS $h"
  route_design
  lassign [tsum] w t n h
  puts $fs "route_design: WNS $w TNS $t failing $n WHS $h"
  lappend steps "phys_opt_design -directive $d, route_design"
  flush $fs
}
write_checkpoint -force routed.dcp
report_timing_summary -max_paths 10 -file timing_pro.rpt
report_utilization -file utilization_pro.rpt
puts $fs "steps: [join $steps { / }]"
puts $fs "final: WNS $w TNS $t failing $n WHS $h"
close $fs
puts "POST_ROUTE_OPT_DONE"
