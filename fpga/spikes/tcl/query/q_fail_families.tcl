# The failing setup endpoints of routed full chips by register family (the M6 guardrails, 2026-10-18):
# a family is the endpoint register or RAM with its bit indices, replica suffixes and RAM sub-cells
# dropped (e.g. c1:u_fetch/g_tage.gh_q, c0:u_rob/g_ft[].u_ft/g_m64.g_bank[].g_prim[].u_ram), counted with
# its worst slack, that path's levels, logic and wire, and its start family. Then the same with the
# front end's two deep cones taken out of timing (false paths), to show what would fail next:
#   F2's registers (u_fetch/f2_*) -> F3, TAGE and the RAS (u_fetch/f3_*, u_fetch/g_tage*, g_ras*), and
#   the instruction queue's head (u_fetch/u_cmp/head_q) -> the RAS (g_ras*).
# Finally the host bridge's core-reset replicas (u_host/crst_q*): their worst ten endpoints, passing or
# not, to tell congestion from a design path. The core clock's setup uncertainty is taken back first
# (the over-constrained checkpoints carry theirs). Writes fail_families.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_fail_families.tcl <routed.dcp>...   (about 5 GB)
proc fam {name} {
  set n [regsub {^u_soc/g_core\[(\d)\]\.g_tgc\.u_core/} $name {c\1:}]
  set n [regsub {^u_soc/u_uncore/} $n {unc:}]
  set n [regsub {/xpm_memory_base_inst/.*$} $n {/xpm}]
  set n [regsub {/(RAM[A-H](_D1)?|mem_reg_[0-9_]+)$} $n {}]
  set n [regsub -all {\[\d+\]} $n {[]}]
  set n [regsub -all {_rep(lica)?(_\d+)?(__\d+)?} $n {}]
  set n [regsub {_reg(\[\])*$} $n {}]
  return $n
}
proc cell_of {pin} { return [join [lrange [split $pin /] 0 end-1] /] }
proc families {fh title {top 0}} {
  set ps [get_timing_paths -setup -max_paths 20000 -nworst 1 -unique_pins -slack_lesser_than 0]
  set n [dict create]; set w [dict create]; set info [dict create]
  foreach p $ps {
    set e [fam [cell_of [get_property NAME [get_property ENDPOINT_PIN $p]]]]
    set sl [get_property SLACK $p]
    dict incr n $e
    if {![dict exists $w $e] || $sl < [dict get $w $e]} {
      dict set w $e $sl
      set lg [get_property DATAPATH_LOGIC_DELAY $p]; set nt [get_property DATAPATH_NET_DELAY $p]
      dict set info $e [format "%2d levels, %3.0f%% wire, from %s" [get_property LOGIC_LEVELS $p] \
        [expr {100.0 * $nt / ($lg + $nt)}] [fam [cell_of [get_property NAME [get_property STARTPOINT_PIN $p]]]]]
    }
  }
  puts $fh "  $title: [llength $ps] failing endpoints in [dict size $n] families"
  set rows {}
  dict for {e c} $n { lappend rows [list $e $c [dict get $w $e] [dict get $info $e]] }
  set i 0
  foreach r [lsort -real -index 2 $rows] {
    if {$top && [incr i] > $top} { puts $fh "    ... [expr {[llength $rows] - $top}] more"; break }
    puts $fh [format "    %7.3f %5d  %-64s %s" [lindex $r 2] [lindex $r 1] [lindex $r 0] [lindex $r 3]]
  }
}
set fh [open fail_families.txt w]
foreach dcp $argv {
  open_checkpoint $dcp
  set_clock_uncertainty -setup 0 [get_clocks c0]
  puts $fh "== $dcp (WNS [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]])"
  families $fh "all"
  set f2   [get_cells -quiet -hierarchical -filter {NAME =~ *u_fetch/f2_* && IS_SEQUENTIAL}]
  set f3t  [get_cells -quiet -hierarchical -filter {(NAME =~ *u_fetch/f3_* || NAME =~ *u_fetch/g_tage* || NAME =~ *g_ras*) && IS_SEQUENTIAL}]
  set head [get_cells -quiet -hierarchical -filter {NAME =~ *u_fetch/u_cmp/head_q* && IS_SEQUENTIAL}]
  set ras  [get_cells -quiet -hierarchical -filter {NAME =~ *g_ras* && IS_SEQUENTIAL}]
  puts $fh [format "  cones cut: F2 (%d cells) -> F3, TAGE and the RAS (%d); the queue head (%d) -> the RAS (%d)" \
    [llength $f2] [llength $f3t] [llength $head] [llength $ras]]
  if {[llength $f2] && [llength $f3t]} { set_false_path -from $f2 -to $f3t }
  if {[llength $head] && [llength $ras]} { set_false_path -from $head -to $ras }
  families $fh "without those cones" 25
  set crst [get_cells -quiet -hierarchical -filter {NAME =~ *u_uncore/u_host/crst_q* && IS_SEQUENTIAL}]
  if {[llength $crst]} {
    puts $fh "  the host bridge's core-reset registers ([llength $crst] cells): their worst ten endpoints"
    foreach p [get_timing_paths -quiet -setup -from $crst -max_paths 10 -nworst 1 -unique_pins] {
      puts $fh [format "    %7.3f  %2d levels, net %.3f ns  %s -> %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
        [get_property DATAPATH_NET_DELAY $p] [get_property NAME [get_property STARTPOINT_PIN $p]] [get_property NAME [get_property ENDPOINT_PIN $p]]]
    }
  }
  close_design
  flush $fh
}
close $fh
puts "Q_FAIL_FAMILIES_DONE"
