# One family's worst paths in full (spikes §8.18, step 7's DS family for fpu-2): the <n> worst setup paths, one per
# endpoint (-nworst 1), from the registers matching <from> to those matching <to> ("-": any endpoint), each with every
# cell and pin, each level's delay and the nets' fanouts (report_timing -input_pins). Then one row per path, and the worst
# path into each endpoint register group (bit indices folded) among the worst 500 from <from>: slack, levels, logic and
# wire delay, start and end. Writes report_timing.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_report_timing.tcl <routed.dcp> <from glob> <to glob|-> [n=3]   (about 5 GB)
lassign $argv dcp from to n
if {$n eq ""} { set n 3 }
open_checkpoint $dcp
set fs [open report_timing.txt w]
proc short {s} { return [regsub -all {u_soc/g_core\[(\d)\]\.g_tgc\.u_core/} $s {c\1:}] }
proc row {p} {
  format "%7.3f %3d %5.2f %5.2f  %s -> %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] \
    [short [get_property NAME [get_property STARTPOINT_PIN $p]]] [short [get_property NAME [get_property ENDPOINT_PIN $p]]]
}
set fc [get_cells -quiet -hierarchical -filter "NAME =~ \"$from\" && IS_SEQUENTIAL"]
set sel [list -setup -from $fc -nworst 1]
if {$to ne "-"} {
  set tc [get_cells -quiet -hierarchical -filter "NAME =~ \"$to\" && IS_SEQUENTIAL"]
  lappend sel -to $tc
  puts $fs "from $from: [llength $fc] registers; to $to: [llength $tc] registers"
} else {
  puts $fs "from $from: [llength $fc] registers; to any endpoint"
}
set ps [get_timing_paths -quiet {*}$sel -max_paths $n]
puts $fs "== the $n worst paths, one per endpoint (slack, levels, logic / wire ns, start -> end)"
foreach p $ps { puts $fs [row $p] }
# The same selection again: report_timing -of_objects ignores -input_pins (Vivado 12-1072)
puts $fs "\n== the same $n paths in full (report_timing -input_pins)"
puts $fs [report_timing {*}$sel -max_paths $n -input_pins -return_string -no_header]
puts $fs "\n== the worst path into each endpoint register group, among the worst 500 from $from"
set grp [dict create]
foreach p [get_timing_paths -quiet -setup -from $fc -nworst 1 -max_paths 500] {
  set r [regsub -all {\[\d+\]} [get_property NAME [get_cells -of_objects [get_property ENDPOINT_PIN $p]]] {[]}]
  if {![dict exists $grp $r]} { dict set grp $r [list 1 $p] } else { dict set grp $r [list [expr {[lindex [dict get $grp $r] 0] + 1}] [lindex [dict get $grp $r] 1]] }
}
foreach r [dict keys $grp] {
  lassign [dict get $grp $r] k p
  puts $fs [format "%s  (%d endpoints)" [row $p] $k]
}
close $fs
puts "Q_REPORT_TIMING_DONE"
