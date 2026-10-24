# An A/B of two post-synthesis checkpoints (spikes §8.18's PMP bound, the coordinator 10-21): for each <label>=<dcp>,
# CLB LUTs (logic, memory) and registers after synthesis and after opt_design ExploreArea, the estimated WNS per clock
# after each (no placement: an estimate) with the core clock's five worst paths, and the LUTs of core 0's PMP instances
# and units. Writes explore_ab.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_explore_ab.tcl <label=dcp>...         (about 9 GB)
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
proc wns {} {
  set out {}
  foreach c [get_clocks] {
    set p [get_timing_paths -quiet -setup -to $c -max_paths 1 -nworst 1]
    if {[llength $p]} { lappend out "[get_property NAME $c] [format %.3f [get_property SLACK $p]]" }
  }
  return [join $out ", "]
}
# the core clock's worst setup paths (an estimate before placement): slack, levels, start and end, with the core prefix cut
proc worst {fs {n 5}} {
  foreach p [get_timing_paths -quiet -setup -max_paths $n -nworst 1 -to [get_clocks c0]] {
    set s [get_property NAME [get_property STARTPOINT_PIN $p]]
    set e [get_property NAME [get_property ENDPOINT_PIN $p]]
    regsub {^u_soc/} $s {} s; regsub {^u_soc/} $e {} e
    puts $fs [format "    %7.3f %3d  %-70s -> %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] $s $e]
  }
}
proc units {} {
  set pre "u_soc/g_core\[0\].g_tgc.u_core/"
  set out {}
  foreach u {u_fetch u_fetch/u_pmp u_lsu u_lsu/u_pmp_ld u_lsu/u_pmp_st u_lsu/u_ptw u_lsu/u_dtlb} {
    set c [get_cells -quiet -hierarchical -filter "NAME == ${pre}${u}"]
    if {![llength $c]} { lappend out "$u -"; continue }
    set n [llength [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}${u}/* && REF_NAME =~ LUT*"]]
    lappend out "$u $n"
  }
  return [join $out ", "]
}
set fs [open explore_ab.txt w]
foreach arg $argv {
  lassign [split $arg =] label dcp
  open_checkpoint $dcp
  set u [util]
  puts $fs [format "== %s: %s" $label $dcp]
  puts $fs [format "  synthesis: CLB LUTs %6d (logic %6d, memory %5d), registers %6d; est. WNS %s" [dict get $u lut] \
    [dict get $u logic] [dict get $u mem] [dict get $u ff] [wns]]
  puts $fs "  core 0's LUT cells: [units]"
  worst $fs
  opt_design -directive ExploreArea
  set u [util]
  puts $fs [format "  opt_design ExploreArea: CLB LUTs %6d (logic %6d, memory %5d), registers %6d; est. WNS %s" \
    [dict get $u lut] [dict get $u logic] [dict get $u mem] [dict get $u ff] [wns]]
  worst $fs
  flush $fs
  close_design
}
close $fs
puts "Q_EXPLORE_AB_DONE"
