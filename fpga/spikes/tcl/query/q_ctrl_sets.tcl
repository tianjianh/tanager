# Control sets and flip-flops by unit in post-synthesis checkpoints (spikes §8.18, the product baseline): for each
# <label>=<dcp>, the design's unique control sets, then each core's units and the uncore's, as report_control_sets
# -cells counts them on the unit's hierarchical cell (its own and its submodules' registers). Writes ctrl_sets.txt,
# and each label's whole report_control_sets in ctrl_sets_<label>_top.rpt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_ctrl_sets.tcl <label=dcp>...        (about 5 GB)
proc cs {r} {
  set n -; set ff -
  regexp {Total control sets\s*\|\s*(\d+)} $r -> n
  if {[regexp {\|\s*Total Registers\s*\|\s*(\d+)} $r -> f]} { set ff $f }
  return [list $n $ff]
}
proc kids {parent} {
  return [lsort [get_cells -quiet -filter "PARENT == \"$parent\" && !IS_PRIMITIVE"]]
}
set fs [open ctrl_sets.txt w]
foreach arg $argv {
  lassign [split $arg =] label dcp
  open_checkpoint $dcp
  set top [report_control_sets -return_string]
  set rf [open ctrl_sets_${label}_top.rpt w]; puts $rf $top; close $rf
  lassign [cs $top] n ff
  puts $fs [format "== %s: %s control sets (%s)" $label $n $dcp]
  set units {}
  foreach core {u_soc/g_core[0].g_tgc.u_core u_soc/g_core[1].g_tgc.u_core u_soc/u_uncore} {
    if {[llength [get_cells -quiet -filter "NAME == \"$core\""]]} { lappend units $core }
    foreach k [kids $core] { lappend units [get_property NAME $k] }
  }
  foreach u $units {
    set c [get_cells -quiet -filter "NAME == \"$u\""]
    if {![llength $c]} { continue }
    lassign [cs [report_control_sets -cells $c -return_string]] n ff
    regsub {^u_soc/} $u {} short
    puts $fs [format "  %6s control sets  %-60s" $n $short]
  }
  flush $fs
  close_design
}
close $fs
puts "Q_CTRL_SETS_DONE"
