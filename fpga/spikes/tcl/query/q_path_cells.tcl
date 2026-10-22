# One worst setup path's cells in a routed checkpoint (spikes §8.18, hp1fs): from the cells matching <from> to those
# matching <to> (NAME globs, -hierarchical), the path's slack, then each pin it passes with its cell's type and the
# incremental delay (logic or wire). Writes path_cells.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_path_cells.tcl <routed.dcp> <from glob> <to glob>   (about 4 GB)
lassign $argv dcp from to
open_checkpoint $dcp
set fs [open path_cells.txt w]
set fc [get_cells -quiet -hierarchical -filter "NAME =~ \"$from\" && IS_SEQUENTIAL"]
set tc [get_cells -quiet -hierarchical -filter "NAME =~ \"$to\" && IS_SEQUENTIAL"]
puts $fs "from $from: [llength $fc] registers; to $to: [llength $tc] registers"
set p [get_timing_paths -quiet -setup -from $fc -to $tc -max_paths 1 -nworst 1]
if {![llength $p]} { puts $fs "no path"; close $fs; puts "Q_PATH_CELLS_DONE"; exit 0 }
puts $fs [format "slack %.3f, %d levels, logic %.3f, wire %.3f ns" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
  [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p]]
puts $fs [report_timing -of_objects $p -return_string -no_header]
close $fs
puts "Q_PATH_CELLS_DONE"
