# ooc_run.tcl's named paths on an existing routed checkpoint (spikes §8.18: a new paths file against an older run, e.g.
# the indirect-target table's off run with paths_itt3.tcl, 10-24): the worst path into each named register group,
# optionally from another, in ooc_run.tcl's paths.txt format, and each in full (path_<name>.rpt).
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_paths.tcl <routed.dcp> <paths file>        (about 4 GB)
lassign $argv dcp paths_file
open_checkpoint $dcp
set tg_paths {}
source $paths_file
set pf [open paths.txt w]
foreach g $tg_paths {
  lassign $g name to from
  set to_cells [get_cells -quiet -hier -filter "NAME =~ \"$to\" && IS_SEQUENTIAL"]
  set args [list -max_paths 1 -nworst 1 -setup]
  if {[llength $to_cells] == 0} { puts $pf [format "%-22s none" $name]; continue }
  lappend args -to $to_cells
  if {$from ne ""} {
    set from_cells [get_cells -quiet -hier -filter "NAME =~ \"$from\" && IS_SEQUENTIAL"]
    if {[llength $from_cells] == 0} { puts $pf [format "%-22s none" $name]; continue }
    lappend args -from $from_cells
  }
  set q [get_timing_paths {*}$args]
  if {$q eq ""} { puts $pf [format "%-22s unconstrained" $name]; continue }
  puts $pf [format "%-22s slack %7.3f levels %2d logic %.3f net %.3f  %s -> %s" $name \
    [get_property SLACK $q] [get_property LOGIC_LEVELS $q] \
    [get_property DATAPATH_LOGIC_DELAY $q] [get_property DATAPATH_NET_DELAY $q] \
    [get_property NAME [get_property STARTPOINT_PIN $q]] [get_property NAME [get_property ENDPOINT_PIN $q]]]
  report_timing {*}$args -input_pins -file path_${name}.rpt
}
close $pf
puts "Q_PATHS_DONE"
