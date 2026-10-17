# What g3_false_paths.tcl's cuts hide on routed full chips (spike G8, 2026-10-17). G3 to G8 cut two core
# path families that once missed 100 MHz (u_lsu*r_data_q_reg* -> u_rob*exr_*, and u_ex*wbq_q_reg* ->
# u_rob*cmp_q_reg*, which no longer matches any cell). The board flow has no such cut.
# Vivado cannot take an exception back in a routed checkpoint (it has no reset_path), but it still times a
# false path's data path, so this reports, per core and family, the longest data path to each endpoint
# (one per endpoint, all of them): its delay, logic levels, logic and wire, and an estimated slack at the
# core clock's period, less the setup and skew that a timed register endpoint of the same clock shows
# (-offset, default 0.12 ns: G7r's DTLB -> rp_ra_q, 9.321 ns of data path at -0.768). Writes cut_paths.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_cut_paths.tcl [-offset N] <routed.dcp>...   (4 GB)
set offset 0.12
if {[lindex $argv 0] eq "-offset"} { set offset [lindex $argv 1]; set argv [lrange $argv 2 end] }
set fh [open cut_paths.txt w]
puts $fh "estimated slack = period - offset ($offset ns) - data path delay; the paths are cut, so Vivado gives no slack"
foreach dcp $argv {
  open_checkpoint $dcp
  set clk [get_clocks c0]
  set period [get_property PERIOD $clk]
  puts $fh "== $dcp (c0 $period ns; WNS [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]])"
  foreach c {0 1} {
    set core "g_core?${c}?*u_core"
    foreach {from to} {u_lsu*r_data_q_reg* u_rob*exr_* u_ex*wbq_q_reg* u_rob*cmp_q_reg*} {
      set f [get_cells -quiet -hierarchical -filter "NAME =~ *${core}/${from} && IS_SEQUENTIAL"]
      set t [get_cells -quiet -hierarchical -filter "NAME =~ *${core}/${to} && IS_SEQUENTIAL"]
      if {![llength $f] || ![llength $t]} {
        puts $fh [format "  core %d %-20s -> %-16s no cells (%d / %d)" $c $from $to [llength $f] [llength $t]]
        continue
      }
      set ps [get_timing_paths -quiet -from $f -to $t -setup -max_paths 1000 -nworst 1 -unique_pins]
      if {![llength $ps]} { puts $fh "  core $c $from -> $to: no path"; continue }
      set worst ""; set wd -1; set over 0
      foreach p $ps {
        set d [get_property DATAPATH_DELAY $p]
        if {$d eq ""} { continue }
        if {$d > $wd} { set wd $d; set worst $p }
        if {$period - $offset - $d < 0} { incr over }
      }
      if {$worst eq ""} { puts $fh "  core $c $from -> $to: no data path delay"; continue }
      puts $fh [format "  core %d %-20s -> %-16s %d endpoints, longest %.3f ns (levels %d, logic %.3f, net %.3f): est. slack %7.3f; %d endpoints est. failing  %s -> %s" \
        $c $from $to [llength $ps] $wd [get_property LOGIC_LEVELS $worst] [get_property DATAPATH_LOGIC_DELAY $worst] \
        [get_property DATAPATH_NET_DELAY $worst] [expr {$period - $offset - $wd}] $over \
        [get_property NAME [get_property STARTPOINT_PIN $worst]] [get_property NAME [get_property ENDPOINT_PIN $worst]]]
    }
  }
  close_design
  flush $fh
}
close $fh
puts "Q_CUT_PATHS_DONE"
