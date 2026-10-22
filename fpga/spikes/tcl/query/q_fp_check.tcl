# Does a floorplan fit a checkpoint before placing it (spikes §8.18's hp1 with §8.17's pblocks, the coordinator
# 10-21)? Opens a post-synthesis checkpoint, sources fp_lib.tcl and the floorplan as g4_fit.tcl does (after
# synthesis, before opt_design), and leaves floorplan.txt: each pblock's cells' LUTs against its LUT sites.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_fp_check.tcl <root> <post_synth.dcp> <floorplan.tcl>
lassign $argv root dcp fp
open_checkpoint $dcp
close [open floorplan.txt w]
source [file join $root fpga spikes tcl fp_lib.tcl]
source [file join $root $fp]
puts "Q_FP_CHECK_DONE"
