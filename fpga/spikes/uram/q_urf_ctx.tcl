# What a double-pumped UltraRAM integer register file would meet in a routed full chip (spikes.md
# §8.14, tier A's floorplan and budgets): per core, where today's register file (u_ex/u_irf, LUTRAM)
# and the registers around it sit against the free URAM288 sites, and how late each input reaches it.
#   - the URAM sites, used and free, by clock region;
#   - the read-address sources: today's issue -> RF registers (u_is), the LSU's store-data tag (u_lsu)
#     and anything else; for the issue -> RF registers, the worst path into them (the select output's
#     arrival: with the UltraRAM it would end at the URAM's address pins instead, a cycle later);
#   - the late store-data tag's arrival at the LUTRAM's read address (with the UltraRAM it must reach
#     the URAM by the mid-cycle edge);
#   - the write port's sources and the worst path into the LUTRAM's write pins (with the UltraRAM the
#     write lands at mid-cycle, so it must arrive 5 ns earlier);
#   - the read's endpoints (the RF-stage registers, the LSU's store-data capture) and the worst read path;
#   - every group's box and centre in RPM units and its distance to the nearest free URAM.
# The core clock's setup uncertainty is taken back first. Writes urf_ctx.txt.
#   tools/vivado_run.sh <run-dir> <tree>/fpga/spikes/uram/q_urf_ctx.tcl <routed.dcp>   (about 5 GB)
set dcp [lindex $argv 0]
open_checkpoint $dcp
set_clock_uncertainty -setup 0 [get_clocks c0]
set fh [open urf_ctx.txt w]
puts $fh "== $dcp (WNS [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]])"

proc box {cells} {
  set xs {}; set ys {}; set crs [dict create]; set sx {}; set sy {}
  foreach s [get_sites -quiet -of_objects $cells] {
    lappend xs [get_property RPM_X $s]; lappend ys [get_property RPM_Y $s]
    dict incr crs [get_property CLOCK_REGION $s]
    if {[regexp {^SLICE_X(\d+)Y(\d+)$} [get_property NAME $s] -> x y]} { lappend sx $x; lappend sy $y }
  }
  if {![llength $xs]} { return [list {} {} {} {} {} {} {} {}] }
  set n [llength $xs]
  set cx [expr {[tcl::mathop::+ {*}$xs] / $n}]; set cy [expr {[tcl::mathop::+ {*}$ys] / $n}]
  set xs [lsort -integer $xs]; set ys [lsort -integer $ys]
  set sb ""
  if {[llength $sx]} {
    set m [llength $sx]
    set sx [lsort -integer $sx]; set sy [lsort -integer $sy]
    # the middle 80% of the cells' slices (a pblock for a stand-in), and the median
    set lo [expr {$m / 10}]; set hi [expr {$m - 1 - $m / 10}]
    set sb [format "SLICE_X%dY%d:SLICE_X%dY%d median X%dY%d" [lindex $sx $lo] [lindex $sy $lo] [lindex $sx $hi] [lindex $sy $hi] \
      [lindex $sx [expr {$m / 2}]] [lindex $sy [expr {$m / 2}]]]
  }
  return [list [lindex $xs 0] [lindex $xs end] [lindex $ys 0] [lindex $ys end] $cx $cy $crs $sb]
}
set free_xy {}
proc nearest {cx cy} {
  set best ""; set bd 1e9
  foreach e $::free_xy {
    lassign $e s x y
    set d [expr {abs($x - $cx) + abs($y - $cy)}]
    if {$d < $bd} { set bd $d; set best $s }
  }
  return "$best at $bd"
}
proc line {title cells} {
  lassign [box $cells] x0 x1 y0 y1 cx cy crs sb
  if {$cx eq ""} { puts $::fh [format "    %-34s %5d cells, not placed" $title [llength $cells]]; return }
  puts $::fh [format "    %-34s %5d cells  x %4d-%4d  y %4d-%4d  centre (%d, %d)  nearest free URAM %s  regions %s" \
    $title [llength $cells] $x0 $x1 $y0 $y1 $cx $cy [nearest $cx $cy] $crs]
  if {$sb ne ""} { puts $::fh "      slices (middle 80%): $sb" }
}
proc worst {title args} {
  set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
  if {![llength $p]} { puts $::fh "    $title: no path"; return }
  puts $::fh [format "    %-34s slack %7.3f  data %6.3f ns (logic %.3f, net %.3f)  %2d levels  %s -> %s" $title \
    [get_property SLACK $p] [get_property DATAPATH_DELAY $p] [get_property DATAPATH_LOGIC_DELAY $p] \
    [get_property DATAPATH_NET_DELAY $p] [get_property LOGIC_LEVELS $p] \
    [get_property NAME [get_property STARTPOINT_PIN $p]] [get_property NAME [get_property ENDPOINT_PIN $p]]]
}
# the latest arrival at any of these pins on the worst path from these startpoints through them, from
# the launching register's clock pin (report_timing's cumulative time less the clock's arrival there)
proc arrive {title from pins} {
  set p [get_timing_paths -quiet -setup -from $from -through $pins -max_paths 1 -nworst 1]
  if {![llength $p]} { puts $::fh "    $title: no path"; return }
  set sp [get_property NAME [get_property STARTPOINT_PIN $p]]
  set r [report_timing -quiet -of_objects $p -return_string]
  set clk ""; set best -1; set bpin ""
  set names [get_property NAME $pins]
  foreach ln [split $r "\n"] {
    if {![regexp {\s(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+[rf]?\s*(\S+)\s*$} $ln -> incr cum pin]} { continue }
    if {$clk eq "" && $pin eq $sp} { set clk $cum }
    if {$clk ne "" && [lsearch -exact $names $pin] >= 0 && $cum > $best} { set best $cum; set bpin $pin }
  }
  if {$clk eq "" || $best < 0} { puts $::fh "    $title: no arrival found (startpoint $sp)"; return }
  puts $::fh [format "    %-34s arrives %.3f ns after the launching clock pin (%s at %s)" $title [expr {$best - $clk}] $sp $bpin]
}

# ---- UltraRAM sites ----
set usites [get_sites -filter {SITE_TYPE == URAM288}]
set used [dict create]
foreach c [get_cells -quiet -hierarchical -filter {REF_NAME =~ URAM288*}] { dict set used [get_property LOC $c] [get_property NAME $c] }
set byreg [dict create]; set freereg [dict create]
foreach s $usites {
  dict incr byreg [get_property CLOCK_REGION $s]
  if {![dict exists $used [get_property NAME $s]]} {
    dict incr freereg [get_property CLOCK_REGION $s]
    lappend free_xy [list [get_property NAME $s] [get_property RPM_X $s] [get_property RPM_Y $s]]
  }
}
puts $fh "URAM288 sites: [llength $usites] ($byreg); free [llength $free_xy] ($freereg)"
set fx {}; foreach e $free_xy { lappend fx "[lindex $e 0]([lindex $e 1],[lindex $e 2])" }
puts $fh "  free sites (RPM x, y): [lrange $fx 0 3] ... [lrange $fx end-3 end]"
set s0 [get_sites SLICE_X0Y0]; set s1 [get_sites SLICE_X1Y1]
puts $fh "  scale: SLICE_X0Y0 at ([get_property RPM_X $s0], [get_property RPM_Y $s0]), SLICE_X1Y1 at ([get_property RPM_X $s1], [get_property RPM_Y $s1])"

foreach c {0 1} {
  set pre "u_soc/g_core\[$c\].g_tgc.u_core"
  puts $fh "== core $c"
  set rams  [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}/u_ex/u_irf/* && REF_NAME =~ RAMD*"]
  set rd    [get_cells -quiet $rams -filter {NAME !~ */RAMH}]
  set radr  [get_pins -quiet -of_objects $rd -filter {REF_PIN_NAME =~ RADR*}]
  set wpins [get_pins -quiet -of_objects $rams -filter {REF_PIN_NAME =~ WADR* || REF_PIN_NAME == I || REF_PIN_NAME == WE}]
  set opins [get_pins -quiet -of_objects $rd -filter {REF_PIN_NAME == O}]
  line "register file (LUTRAM)" $rams
  # read-address sources by unit
  set src [get_cells -quiet -of_objects [all_fanin -quiet -flat -startpoints_only $radr] -filter {IS_SEQUENTIAL}]
  set is  [get_cells -quiet $src -filter "NAME =~ ${pre}/u_is/*"]
  set ls  [get_cells -quiet $src -filter "NAME =~ ${pre}/u_lsu/*"]
  set ot  [get_cells -quiet $src -filter "NAME !~ ${pre}/u_is/* && NAME !~ ${pre}/u_lsu/*"]
  line "read addresses: issue -> RF regs" $is
  line "read addresses: LSU (store data)" $ls
  line "read addresses: others" $ot
  if {[llength $ot]} { puts $fh "      others: [lsort -unique [lmap x [lrange [get_property NAME $ot] 0 40] {regsub {_reg.*$} [regsub {^.*u_core/} $x {}] {}}]]" }
  if {[llength $is]} {
    worst "into the issue -> RF regs (D)" -to [get_pins -of_objects $is -filter {REF_PIN_NAME == D}]
    worst "read: issue -> RF regs -> RF" -from $is -through $opins
  }
  if {[llength $ls]} {
    arrive "store-data tag at the LUTRAM" $ls $radr
    worst "read: store-data tag -> capture" -from $ls -through $opins
  }
  # write port
  set wsrc [get_cells -quiet -of_objects [all_fanin -quiet -flat -startpoints_only $wpins] -filter {IS_SEQUENTIAL}]
  line "write sources" $wsrc
  worst "into the LUTRAM's write pins" -to $wpins
  # read endpoints by unit
  set ep  [get_cells -quiet -of_objects [all_fanout -quiet -flat -endpoints_only $opins] -filter {IS_SEQUENTIAL}]
  set epx [get_cells -quiet $ep -filter "NAME =~ ${pre}/u_ex/*"]
  set epl [get_cells -quiet $ep -filter "NAME =~ ${pre}/u_lsu/*"]
  set epo [get_cells -quiet $ep -filter "NAME !~ ${pre}/u_ex/* && NAME !~ ${pre}/u_lsu/*"]
  line "read endpoints: RF stage (u_ex)" $epx
  line "read endpoints: LSU (store data)" $epl
  line "read endpoints: others" $epo
  if {[llength $epo]} { puts $fh "      others: [lsort -unique [lmap x [lrange [get_property NAME $epo] 0 40] {regsub {_reg.*$} [regsub {^.*u_core/} $x {}] {}}]]" }
  worst "read: worst into the RF stage" -through $opins -to $epx
  # the FP register file, for scale
  set frams [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}/u_p4/u_rf/* && REF_NAME =~ RAMD*"]
  line "FP register file (LUTRAM)" $frams
  flush $fh
}
close $fh
puts "Q_URF_CTX_DONE"
