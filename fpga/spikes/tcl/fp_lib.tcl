# Floorplan helpers for fp_core.tcl's floorplan files (fpga/spikes/tcl/fp/*.tcl).
#
# The XCK26 has 3 x 4 clock regions. Each column has its own resources per region (from
# report_clock_utilization): X0 11,040 LUTs, 144 DSPs, no block RAM; X1 8,640 LUTs, 12 RAMB36,
# 144 DSPs; X2 9,600 LUTs, 24 RAMB36, 16 URAM, 24 DSPs. A region is 60 CLB rows high, so a
# column has rows 0-239 from the bottom. The core's clock buffer sits in X1Y2 (rows 120-179).
#
#   tg_fp_rows <col> <lo> <hi>      pblock ranges for rows lo..hi (0-239) of clock-region column
#                                   col (X0, X1 or X2), full column width: SLICE, RAMB36, RAMB18,
#                                   DSP48E2 and URAM288 ranges, each scaled to its own row pitch
#   tg_fp_pblock <name> <cells> <ranges...>
#                                   a pblock over the ranges with those cells; logs it, with the
#                                   cells' LUTs against the pblock's, to floorplan.txt
#
# Columns are not split across their width, so neighbouring pblocks never share a site.

proc tg_fp_rows {col lo hi} {
  set crs [get_clock_regions [list ${col}Y0 ${col}Y1 ${col}Y2 ${col}Y3]]
  set ranges {}
  foreach pre {SLICE RAMB36 RAMB18 DSP48E2 URAM288} {
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

proc tg_fp_pblock {name cells args} {
  set ranges [concat {*}$args]
  set pb [create_pblock $name]
  resize_pblock $pb -add $ranges
  set cells [get_cells -quiet $cells]
  if {[llength $cells]} { add_cells_to_pblock $pb $cells }
  set luts 0
  foreach c $cells {
    if {[get_property IS_PRIMITIVE $c]} {
      if {[get_property PRIMITIVE_GROUP $c] in {LUT DISTRAM}} { incr luts }
      continue
    }
    current_instance -quiet
    current_instance -quiet $c
    incr luts [llength [get_cells -quiet -hierarchical -filter {PRIMITIVE_GROUP == LUT || PRIMITIVE_GROUP == DISTRAM}]]
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
