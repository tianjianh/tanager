# The failing setup endpoints of routed full chips by unit (spike G8, 2026-10-17): every failing path
# (one per endpoint, at most 20,000), counted by its start and end unit inside a core (u_lsu, u_fetch,
# u_dec, u_rn, u_rob, u_is, u_csr, ...; the uncore and the rest by their top block), with each pair's
# worst slack, logic levels and wire share. It answers which units fail at all, beyond a report's 20
# worst: e.g. whether the instruction queue's paths that QUEUE_DECODE targets (fetch -> decode -> rename)
# are among them. Any setup uncertainty on the core clock c0 is taken back first (seeded and
# over-constrained checkpoints carry theirs). Writes fail_units.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_fail_units.tcl <routed.dcp>...   (about 5 GB)
proc unit_of {name} {
  if {[regexp {g_core\[(\d)\]\.g_tgc\.u_core/([^/]+)} $name -> c u]} { return "c$c:$u" }
  if {[regexp {u_soc/u_uncore/([^/]+)} $name -> u]} { return "unc:$u" }
  return [lindex [split $name /] 0]
}
set fh [open fail_units.txt w]
foreach dcp $argv {
  open_checkpoint $dcp
  # a seeded or over-constrained run (seed_unc.tcl, over_unc.tcl) wrote its checkpoint before -pre_report took
  # its setup uncertainty back, so take it back here too (timing.xdc sets none)
  set_clock_uncertainty -setup 0 [get_clocks c0]
  # and clk2x's in a URF build (DR-174: over_unc.tcl over-constrains it too)
  set c2x [get_clocks -quiet -of_objects [get_pins -quiet u_clkgen/u_mmcm/CLKOUT2]]
  if {[llength $c2x]} { set_clock_uncertainty -setup 0 $c2x }
  set ps [get_timing_paths -setup -max_paths 20000 -nworst 1 -unique_pins -slack_lesser_than 0]
  set n [dict create]; set w [dict create]; set wl [dict create]; set ends [dict create]
  foreach p $ps {
    set s [unit_of [get_property NAME [get_property STARTPOINT_PIN $p]]]
    set e [unit_of [get_property NAME [get_property ENDPOINT_PIN $p]]]
    set k "$s -> $e"
    set sl [get_property SLACK $p]
    dict incr n $k
    dict incr ends $e
    if {![dict exists $w $k] || $sl < [dict get $w $k]} {
      dict set w $k $sl
      set lg [get_property DATAPATH_LOGIC_DELAY $p]; set nt [get_property DATAPATH_NET_DELAY $p]
      dict set wl $k [format "%2d levels, %3.0f%% wire  %s -> %s" [get_property LOGIC_LEVELS $p] [expr {100.0 * $nt / ($lg + $nt)}] \
        [get_property NAME [get_property STARTPOINT_PIN $p]] [get_property NAME [get_property ENDPOINT_PIN $p]]]
    }
  }
  puts $fh "== $dcp: [llength $ps] failing endpoints"
  puts $fh "  by end unit:"
  set rows {}
  dict for {e c} $ends { lappend rows [list $e $c] }
  foreach r [lsort -integer -decreasing -index 1 $rows] { puts $fh [format "    %-24s %6d" {*}$r] }
  puts $fh "  by start -> end unit (worst slack, its levels, wire share, start -> end):"
  set rows {}
  dict for {k c} $n { lappend rows [list $k $c [dict get $w $k] [dict get $wl $k]] }
  foreach r [lsort -real -index 2 $rows] { puts $fh [format "    %-44s %6d  %7.3f  %s" {*}$r] }
  close_design
  flush $fh
}
close $fh
puts "Q_FAIL_UNITS_DONE"
