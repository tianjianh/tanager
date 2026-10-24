# The paths through one group of nets, by start (spikes §8.18, soc-2's DR-183 store checker after its ckm2 fix: what is
# left once the checker's select starts at a register). Every register in the fan-in of the nets matching <through>
# (get_nets -hierarchical), folded into register groups (bit indices folded). For each group, its worst setup path
# through those nets to the registers matching <to> ("-": any endpoint): slack, levels, logic and wire delay, start and
# end. Worst first, then the worst <k> groups' paths in full (report_timing -input_pins). Writes through.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_through.tcl <routed.dcp> <through net glob> <to glob|-> [k=2]   (about 5 GB)
lassign $argv dcp through to k
if {$k eq ""} { set k 2 }
open_checkpoint $dcp
set fs [open through.txt w]
proc short {s} { return [regsub -all {u_soc/g_core\[(\d)\]\.g_tgc\.u_core/} $s {c\1:}] }
proc row {p} {
  format "%7.3f %3d %5.2f %5.2f  %s -> %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] \
    [short [get_property NAME [get_property STARTPOINT_PIN $p]]] [short [get_property NAME [get_property ENDPOINT_PIN $p]]]
}
set nets [get_nets -quiet -hierarchical -filter "NAME =~ \"$through\""]
set tsel {}
if {$to ne "-"} {
  set tc [get_cells -quiet -hierarchical -filter "NAME =~ \"$to\" && IS_SEQUENTIAL"]
  set tsel [list -to $tc]
  puts $fs "through $through: [llength $nets] nets ([join [lmap n $nets {short $n}] {, }]); to $to: [llength $tc] registers"
} else {
  puts $fs "through $through: [llength $nets] nets ([join [lmap n $nets {short $n}] {, }]); to any endpoint"
}
set sc [get_cells -quiet -of_objects [all_fanin -quiet -flat -startpoints_only $nets] -filter {IS_SEQUENTIAL}]
set grp [dict create]
foreach c $sc { dict lappend grp [regsub -all {\[\d+\]} [get_property NAME $c] {[]}] $c }
puts $fs "start registers in their fan-in: [llength $sc] in [dict size $grp] groups"
set res {}
dict for {g cs} $grp {
  set p [get_timing_paths -quiet -setup -from $cs -through $nets {*}$tsel -max_paths 1 -nworst 1]
  if {[llength $p]} { lappend res [list [get_property SLACK $p] $g [llength $cs] $p] }
}
set res [lsort -real -index 0 $res]
puts $fs "== by start group, worst first (slack, levels, logic / wire ns, start -> end, registers in the group)"
foreach r $res { puts $fs "[row [lindex $r 3]]  ([lindex $r 2])" }
set i 0
foreach r [lrange $res 0 [expr {$k - 1}]] {
  incr i
  puts $fs "\n== group $i ([short [lindex $r 1]]) in full (report_timing -input_pins)"
  puts $fs [report_timing -setup -from [dict get $grp [lindex $r 1]] -through $nets {*}$tsel -max_paths 1 -nworst 1 \
    -input_pins -return_string -no_header]
}
close $fs
puts "Q_THROUGH_DONE"
