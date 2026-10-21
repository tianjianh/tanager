# How many LUTs opt_design's directives leave on one post-synthesis checkpoint (spikes §8.18: the product chip with
# real hart 1 does not fit; which flow lever recovers area at no IPC). For each directive: open the checkpoint, run
# opt_design -directive <d> (Default: the plain opt_design), and record CLB LUTs, LUT as logic, LUT as memory,
# registers and the run time. Writes opt_directives.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_opt_directives.tcl <post_synth.dcp> <directive>...  (about 9 GB)
proc util {} {
  set r [report_utilization -return_string]
  set out {}
  foreach {k label} {lut {CLB LUTs} logic {LUT as Logic} mem {LUT as Memory} ff {CLB Registers}} {
    set v 0
    if {[regexp "\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9.\]+)" $r -> n]} { set v $n }
    lappend out $k $v
  }
  return $out
}
set dcp [lindex $argv 0]
set fs [open opt_directives.txt w]
puts $fs "== $dcp"
foreach d [lrange $argv 1 end] {
  open_checkpoint $dcp
  set t0 [clock seconds]
  if {$d eq "Default"} { opt_design } else { opt_design -directive $d }
  set u [util]
  puts $fs [format "%-24s CLB LUTs %6d (logic %6d, memory %5d), registers %6d, %4d s" $d [dict get $u lut] \
    [dict get $u logic] [dict get $u mem] [dict get $u ff] [expr {[clock seconds] - $t0}]]
  flush $fs
  close_design
}
close $fs
puts "Q_OPT_DIRECTIVES_DONE"
