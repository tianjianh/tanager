# The fetch-TAGE paths for fpu-2 (spikes §8.18, the DR-185 preview; fpu-2 owns the fix). Per core:
#   1. the 10 worst setup paths from the I$ data RAMs into the TAGE's registers (u_fetch/g_tage.*: tg_fetch's g_tage
#      block and tg_tage's own), one per endpoint: slack, levels, logic and net delay, start and end pins;
#   2. the full report (-input_pins) of the worst path;
#   3. every TAGE register with an endpoint within 1 ns from any start, by register (bit indices folded): endpoints,
#      the worst slack and its start;
#   4. the next families down: the 10 worst paths into fetch's other registers, and the full report of the worst.
# Writes tage_paths.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_tage_paths.tcl <routed.dcp>        (about 5 GB)
open_checkpoint [lindex $argv 0]
set fs [open tage_paths.txt w]
proc short {n} { return [regsub {^u_soc/g_core\[(\d)\]\.g_tgc\.u_core/} $n {c\1:}] }
proc row {p} {
  format "%7.3f %3d %5.2f %5.2f  %s -> %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] \
    [short [get_property NAME [get_property STARTPOINT_PIN $p]]] [short [get_property NAME [get_property ENDPOINT_PIN $p]]]
}
foreach c {0 1} {
  set core "u_soc/g_core\[$c\].g_tgc.u_core"
  set ram  [get_cells -quiet -hierarchical -filter "NAME =~ \"$core/u_fetch/g_way\[*\].u_data/u_mem/*\" && IS_SEQUENTIAL"]
  set tage [get_cells -quiet -hierarchical -filter "NAME =~ \"$core/u_fetch/g_tage.*\" && IS_SEQUENTIAL"]
  set fet  [get_cells -quiet -hierarchical -filter "NAME =~ \"$core/u_fetch/*\" && IS_SEQUENTIAL && NAME !~ \"$core/u_fetch/g_tage.*\""]
  puts $fs "######## core $c: [llength $ram] I\$ data RAM cells, [llength $tage] TAGE registers and RAMs, [llength $fet] other fetch sequential cells"
  puts $fs "  slack lvl logic  wire  start -> end"
  puts $fs "== 1. the worst paths from the I\$ data into the TAGE"
  set ps [get_timing_paths -quiet -setup -from $ram -to $tage -max_paths 10 -nworst 1]
  foreach p $ps { puts $fs [row $p] }
  puts $fs "== 2. the worst of them, in full"
  if {[llength $ps]} { puts $fs [report_timing -of_objects [lindex $ps 0] -input_pins -return_string -no_header] }
  puts $fs "== 3. the TAGE's registers with an endpoint within 1 ns (any start)"
  set fam [dict create]
  foreach p [get_timing_paths -quiet -setup -to $tage -max_paths 5000 -nworst 1 -slack_lesser_than 1.0] {
    set e [get_property ENDPOINT_PIN $p]
    set r [regsub -all {\[\d+\]} [get_property NAME [get_cells -of_objects $e]] {[]}]
    set s [get_property SLACK $p]
    if {![dict exists $fam $r]} { dict set fam $r [list 0 99.0 {}] }
    lassign [dict get $fam $r] n w st
    incr n
    if {$s < $w} { set w $s; set st [short [get_property NAME [get_property STARTPOINT_PIN $p]]] }
    dict set fam $r [list $n $w $st]
  }
  foreach {r v} [lsort -stride 2 -index {1 1} -real [dict get $fam]] {
    lassign $v n w st
    puts $fs [format "  %7.3f %5d  %-70s from %s" $w $n [short $r] $st]
  }
  puts $fs "== 4. the next families down: the worst paths into fetch's other registers"
  set ps [get_timing_paths -quiet -setup -to $fet -max_paths 10 -nworst 1]
  foreach p $ps { puts $fs [row $p] }
  if {[llength $ps]} { puts $fs [report_timing -of_objects [lindex $ps 0] -input_pins -return_string -no_header] }
  flush $fs
}
close $fs
puts "Q_TAGE_PATHS_DONE"
