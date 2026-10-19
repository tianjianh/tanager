# Details for spikes.md §8.14's tier A verdict, in full path reports (detail.rpt):
#   1. tier A's routed urf_top: the probe UltraRAM's output-register path (its clock-to-out);
#   2. a routed full chip (h100_m6m), per core, with the core clock's setup uncertainty taken back:
#      - the worst store-data path from the LSU through the register file's read address (when the tag
#        reaches the LUTRAM: with the UltraRAM it must reach the URAM by mid-cycle),
#      - the worst path into the register file's write pins (with the UltraRAM it lands at mid-cycle),
#      - the worst path into today's issue -> RF registers (the select output, which the UltraRAM's
#        address register would take at the core edge).
#   tools/vivado_run.sh <run-dir> <tree>/fpga/spikes/uram/q_urf_detail.tcl <urf_top routed.dcp> <chip routed.dcp>
lassign $argv adcp cdcp
set fh [open detail.rpt w]
open_checkpoint $adcp
set p [get_timing_paths -quiet -setup -max_paths 1 -from [get_cells -hierarchical -filter {REF_NAME == URAM288_BASE && NAME =~ *u_probe}] \
         -to [get_cells -hierarchical -filter {NAME =~ *prb_q_reg*}]]
puts $fh "######## tier A: the probe's output register -> capture"
puts $fh [expr {[llength $p] ? [report_timing -of_objects $p -return_string] : "no path"}]
close_design
open_checkpoint $cdcp
set_clock_uncertainty -setup 0 [get_clocks c0]
foreach c {0 1} {
  set pre "u_soc/g_core\[$c\].g_tgc.u_core"
  set rams [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}/u_ex/u_irf/* && REF_NAME =~ RAMD*"]
  set rd   [get_cells -quiet $rams -filter {NAME !~ */RAMH}]
  set radr [get_pins -quiet -of_objects $rd -filter {REF_PIN_NAME =~ RADR*}]
  set wpin [get_pins -quiet -of_objects $rams -filter {REF_PIN_NAME =~ WADR* || REF_PIN_NAME == I || REF_PIN_NAME == WE}]
  set src  [get_cells -quiet -of_objects [all_fanin -quiet -flat -startpoints_only $radr] -filter {IS_SEQUENTIAL}]
  set ls   [get_cells -quiet $src -filter "NAME =~ ${pre}/u_lsu/*"]
  set is   [get_cells -quiet $src -filter "NAME =~ ${pre}/u_is/*"]
  foreach {title args} [list \
      "core $c: the store-data tag through the register file" [list -from $ls -through $radr] \
      "core $c: into the register file's write pins"          [list -to $wpin] \
      "core $c: into the issue -> RF registers"               [list -to [get_pins -quiet -of_objects $is -filter {REF_PIN_NAME == D}]]] {
    set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
    puts $fh "######## $title"
    puts $fh [expr {[llength $p] ? [report_timing -of_objects $p -return_string] : "no path"}]
  }
  # the write port's worst paths by source unit, to see which inputs are late
  set wsrc [get_cells -quiet -of_objects [all_fanin -quiet -flat -startpoints_only $wpin] -filter {IS_SEQUENTIAL}]
  puts $fh "######## core $c: worst path into the write pins by source unit"
  set units [lsort -unique [lmap x [get_property NAME $wsrc] {regsub {^.*u_core/([^/]+)/.*$} $x {\1}}]]
  foreach u $units {
    set us [get_cells -quiet $wsrc -filter "NAME =~ ${pre}/${u}/*"]
    if {![llength $us]} { continue }
    set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 -from $us -to $wpin]
    if {[llength $p]} {
      puts $fh [format "  %-12s %5d sources  data %6.3f ns  %2d levels  %s -> %s" $u [llength $us] [get_property DATAPATH_DELAY $p] \
        [get_property LOGIC_LEVELS $p] [get_property NAME [get_property STARTPOINT_PIN $p]] [get_property NAME [get_property ENDPOINT_PIN $p]]]
    }
  }
  flush $fh
}
close $fh
puts "Q_URF_DETAIL_DONE"
