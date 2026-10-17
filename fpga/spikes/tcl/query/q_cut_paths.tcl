# What g3_false_paths.tcl's cuts hide on routed full chips (spike G8, 2026-10-17). G3 to G8 cut two core
# path families that once missed 100 MHz (u_lsu*r_data_q_reg* -> u_rob*exr_*, and u_ex*wbq_q_reg* ->
# u_rob*cmp_q_reg*, which no longer matches any cell). The board flow has no such cut. This times each
# family with the cut taken back (reset_path), on each checkpoint, and writes cut_paths.txt: per core and
# family, the worst setup slack, logic levels, logic and wire delay, and the endpoints. It also writes
# the WNS with and without the cut, so a run's figures can be corrected.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_cut_paths.tcl <routed.dcp>...   (about 5 GB)
set fh [open cut_paths.txt w]
foreach dcp $argv {
  open_checkpoint $dcp
  set wns_cut [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
  puts $fh "== $dcp"
  puts $fh [format "  WNS with the cut     %7.3f" $wns_cut]
  foreach c {0 1} {
    set core "g_core?${c}?*u_core"
    foreach {from to} {u_lsu*r_data_q_reg* u_rob*exr_* u_ex*wbq_q_reg* u_rob*cmp_q_reg*} {
      set f [get_cells -quiet -hierarchical -filter "NAME =~ *${core}/${from} && IS_SEQUENTIAL"]
      set t [get_cells -quiet -hierarchical -filter "NAME =~ *${core}/${to} && IS_SEQUENTIAL"]
      if {![llength $f] || ![llength $t]} {
        puts $fh [format "  core %d %-20s -> %-16s no cells (%d / %d)" $c $from $to [llength $f] [llength $t]]
        continue
      }
      if {[catch {reset_path -from $f -to $t} err]} { puts $fh "  core $c $from -> $to: reset_path failed: $err"; continue }
      set p [get_timing_paths -quiet -from $f -to $t -max_paths 1 -nworst 1 -setup]
      if {![llength $p] || [get_property SLACK $p] eq ""} { puts $fh "  core $c $from -> $to: no timed path"; continue }
      set n [llength [get_timing_paths -quiet -from $f -to $t -max_paths 5000 -nworst 1 -unique_pins -setup -slack_lesser_than 0]]
      puts $fh [format "  core %d %-20s -> %-16s slack %7.3f  levels %2d  logic %.3f  net %.3f  failing endpoints %d  %s -> %s" \
        $c $from $to [get_property SLACK $p] [get_property LOGIC_LEVELS $p] [get_property DATAPATH_LOGIC_DELAY $p] \
        [get_property DATAPATH_NET_DELAY $p] $n [get_property NAME [get_property STARTPOINT_PIN $p]] [get_property NAME [get_property ENDPOINT_PIN $p]]]
    }
  }
  set wns_open [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
  puts $fh [format "  WNS without the cut  %7.3f" $wns_open]
  close_design
  flush $fh
}
close $fh
puts "Q_CUT_PATHS_DONE"
