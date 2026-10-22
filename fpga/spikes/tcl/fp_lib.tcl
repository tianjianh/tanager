# Floorplan helpers for fp_core.tcl's floorplan files (fpga/spikes/tcl/fp/*.tcl).
#
# The XCK26 has 3 x 4 clock regions. Each column has its own resources per region (from
# report_clock_utilization): X0 11,040 LUTs, 144 DSPs, no block RAM; X1 8,640 LUTs, 12 RAMB36,
# 144 DSPs; X2 9,600 LUTs, 24 RAMB36, 16 URAM, 24 DSPs. A region is 60 CLB rows high, so a
# column has rows 0-239 from the bottom. The core's clock buffer sits in X1Y2 (rows 120-179).
#
#   tg_fp_rows <col> <lo> <hi> ?types?
#                                   pblock ranges for rows lo..hi (0-239) of clock-region column
#                                   col (X0, X1 or X2), full column width: SLICE, RAMB36, RAMB18,
#                                   DSP48E2 and URAM288 ranges (or only the given types), each
#                                   scaled to its own row pitch
#   tg_fp_cell <name>               a cell by its full name, matched exactly
#   tg_fp_pblock <name> <cells> <ranges...>
#                                   a pblock over the ranges with those cells; logs it, with the
#                                   cells' LUTs against the pblock's, to floorplan.txt
#   tg_fp_check ?warn? ?tight?      after the floorplan, before opt_design: floorplan.txt's estimate per
#                                   pblock, its cells' LUT primitives (logic and LUTRAM, before
#                                   opt_design trims; two may share a site) against its LUT sites.
#                                   Prints FLOORPLAN_OK, FLOORPLAN_WARN (above warn %, default 105) or
#                                   FLOORPLAN_TIGHT (above tight %, default 115) per pblock; returns the
#                                   highest share. The estimate runs high: hp1f's L2 bank 1 read 101%
#                                   here and its own LUTs filled 77% of its sites after placement
#                                   (spikes §8.18, DR-181).
#   tg_fp_check_placed ?warn? ?tight?
#                                   after place_design: each pblock's own LUTs after opt_design
#                                   (report_utilization -pblocks, CLB LUTs, Parent: its cells wherever
#                                   they sit) against its LUT sites. FLOORPLAN_OK, FLOORPLAN_WARN (above
#                                   warn %, default 85) or FLOORPLAN_TIGHT (above tight %, default 90:
#                                   resize it) per pblock; returns the highest share. Also logs the
#                                   share of its own LUT and LUTRAM cells placed outside it. hp1f, which
#                                   came within 0.1 ns of 100 MHz: 73%, 77% (the L2 banks) and 45% (the
#                                   crossbar), with 20%, 15% and 28% of their LUT cells outside.
#   tg_fp_spill <pblock>            {own LUT and LUTRAM cells placed, of them outside the pblock's sites}
#
# Columns are not split across their width, so neighbouring pblocks never share a site. A pblock
# only bounds its own cells: other cells may still use its free sites (Vivado's default), which a
# floorplan of a nearly full device relies on. Vivado 2025.2 creates these pblocks soft (IS_SOFT 1
# straight after tg_fp_pblock, before opt_design; nothing in this flow sets it): the placer keeps a
# pblock's cells near it but may place some outside, as it did hp1f's (spikes §8.18, DR-181). hp1f's
# result is with soft pblocks; hard ones are untested. The checks log IS_SOFT.

proc tg_fp_rows {col lo hi {types {SLICE RAMB36 RAMB18 DSP48E2 URAM288}}} {
  set crs [get_clock_regions [list ${col}Y0 ${col}Y1 ${col}Y2 ${col}Y3]]
  set ranges {}
  foreach pre $types {
    set s [get_sites -quiet -of_objects $crs -filter "NAME =~ ${pre}_X*"]
    if {![llength $s]} { continue }
    set xs {}; set ys {}
    foreach n [get_property NAME $s] {
      if {[regexp {_X(\d+)Y(\d+)$} $n -> a b]} { lappend xs $a; lappend ys $b }
    }
    set xs [lsort -integer -unique $xs]
    set ys [lsort -integer -unique $ys]
    set y0 [lindex $ys 0]
    set n  [llength $ys]
    set a [expr {$y0 + int(ceil($lo * $n / 240.0))}]
    set b [expr {$y0 + int(ceil(($hi + 1) * $n / 240.0)) - 1}]
    if {$b < $a} { continue }
    lappend ranges "${pre}_X[lindex $xs 0]Y${a}:${pre}_X[lindex $xs end]Y${b}"
  }
  return $ranges
}

# A cell by its full name, matched exactly (names with brackets need no glob)
proc tg_fp_cell {name} {
  set c [get_cells -quiet -hierarchical -filter "NAME == \"$name\""]
  if {![llength $c]} { error "tg_fp_cell: no cell $name" }
  return $c
}

proc tg_fp_pblock {name cells args} {
  set ranges [concat {*}$args]
  set pb [create_pblock $name]
  resize_pblock $pb -add $ranges
  set cells [get_cells -quiet $cells]
  if {![llength $cells]} { error "tg_fp_pblock $name: no cells" }
  add_cells_to_pblock $pb $cells
  # the cells' LUTs (logic and LUTRAM), counted from each hierarchical cell (current_instance, so
  # names with brackets need no -filter glob)
  set luts 0
  foreach c $cells {
    if {[get_property IS_PRIMITIVE $c]} {
      if {[string match CLB.LUT* [get_property PRIMITIVE_TYPE $c]]} { incr luts }
      continue
    }
    current_instance -quiet
    current_instance -quiet $c
    incr luts [llength [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ CLB.LUT.* || PRIMITIVE_TYPE =~ CLB.LUTRAM.*}]]
    current_instance -quiet
  }
  set slices [llength [get_sites -quiet -of_objects $pb -filter {NAME =~ SLICE_*}]]
  set names [expr {[llength $cells] > 12 ? "[llength $cells] cells" : [join [get_property NAME $cells] " "]}]
  set fh [open floorplan.txt a]
  puts $fh [format "%-10s %-40s LUT cells %6d / %6d LUT sites (%3.0f%%)  %s" $name $names \
    $luts [expr {8 * $slices}] [expr {$slices ? 100.0 * $luts / (8 * $slices) : 0}] $ranges]
  close $fh
  return $pb
}

# The floorplan's estimate, from floorplan.txt (tg_fp_pblock's lines), against two thresholds (header)
proc tg_fp_check {{warn 105} {tight 115}} {
  set hi 0.0
  if {![file exists floorplan.txt]} { puts "FLOORPLAN_CHECK: no floorplan.txt"; return $hi }
  set fh [open floorplan.txt r]
  foreach ln [split [read $fh] "\n"] {
    if {![regexp {^(\S+)\s+.*LUT cells\s+(\d+)\s*/\s*(\d+) LUT sites} $ln -> pb luts sites]} { continue }
    set p [expr {$sites ? 100.0 * $luts / $sites : 0.0}]
    if {$p > $hi} { set hi $p }
    set k [expr {$p > $tight ? "FLOORPLAN_TIGHT" : $p > $warn ? "FLOORPLAN_WARN" : "FLOORPLAN_OK"}]
    set soft [get_property -quiet IS_SOFT [get_pblocks -quiet $pb]]
    puts [format "%s %s: %d LUT cells for %d LUT sites, %.0f%% before opt_design, IS_SOFT %s (warn above %s%%, tight above %s%%)" \
      $k $pb $luts $sites $p $soft $warn $tight]
  }
  close $fh
  return $hi
}

# A placed pblock's own LUT and LUTRAM cells (leaves, not LUTRAM macros) and how many of them sit outside its sites
proc tg_fp_spill {pb} {
  set ins [dict create]
  foreach s [get_property NAME [get_sites -quiet -of_objects $pb -filter {NAME =~ SLICE_*}]] { dict set ins $s 1 }
  set n 0; set out 0
  foreach c [get_cells -quiet -of_objects $pb] {
    current_instance -quiet
    if {[get_property IS_PRIMITIVE $c]} {
      set leaves $c
    } else {
      current_instance -quiet $c
      set leaves [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT* || REF_NAME =~ RAMD* || REF_NAME =~ RAMS* || REF_NAME =~ SRL*}]
    }
    foreach loc [get_property LOC $leaves] {
      if {$loc eq ""} { continue }
      incr n
      if {![dict exists $ins $loc]} { incr out }
    }
    current_instance -quiet
  }
  return [list $n $out]
}

# Each pblock's own LUTs after placement against its LUT sites (header); writes util_pblocks.rpt
proc tg_fp_check_placed {{warn 85} {tight 90}} {
  set hi 0.0
  close [open util_pblocks.rpt w]
  foreach pb [get_pblocks -quiet] {
    set r [report_utilization -pblocks $pb -return_string]
    set fh [open util_pblocks.rpt a]; puts $fh $r; close $fh
    if {![regexp {\|\s*CLB LUTs\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|} \
          $r -> parent child nonas used fixed prohib avail]} {
      puts "FLOORPLAN_CHECK $pb: no CLB LUTs line in report_utilization -pblocks"
      continue
    }
    set own [expr {$parent + $child}]
    set p [expr {$avail ? 100.0 * $own / $avail : 0.0}]
    if {$p > $hi} { set hi $p }
    set k [expr {$p > $tight ? "FLOORPLAN_TIGHT" : $p > $warn ? "FLOORPLAN_WARN" : "FLOORPLAN_OK"}]
    lassign [tg_fp_spill $pb] n out
    puts [format "%s %s: its own %d LUTs for %d LUT sites, %.0f%% after placement, with %d of other cells' inside; %.0f%% of its %d LUT cells outside, IS_SOFT %s (warn above %s%%, tight above %s%%)" \
      $k $pb $own $avail $p $nonas [expr {$n ? 100.0 * $out / $n : 0.0}] $n [get_property -quiet IS_SOFT $pb] $warn $tight]
  }
  return $hi
}
