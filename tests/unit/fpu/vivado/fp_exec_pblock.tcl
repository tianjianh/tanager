# Floorplan test for tg_fp_exec out of context (sourced by ooc.tcl through TG_OOC_IO, after
# synthesis): confine the design to the smallest block of clock regions (one, or two stacked)
# that holds its DSPs and block RAM with room for its slices, and write which one it chose to
# pblock.txt. A measurement of what floorplanning P4 buys in the full-chip flow, not a flow rule.
proc tg_ncells {filt} { return [llength [get_cells -quiet -hier -filter $filt]] }
set need_dsp  [expr {[tg_ncells {REF_NAME == DSP48E2}] + 4}]
set need_bram [expr {[tg_ncells {REF_NAME == RAMB18E2}] + 2 * [tg_ncells {REF_NAME == RAMB36E2}] + 1}]
# LUTRAM primitives (RAM64M8, RAM32M16) take a whole SLICEM's eight LUTs
set luts [expr {[tg_ncells {REF_NAME =~ LUT*}] + [tg_ncells {REF_NAME =~ SRL*}] +
                8 * [tg_ncells {REF_NAME == RAM64M8 || REF_NAME == RAM32M16}]}]
set need_slc [expr {int(ceil($luts / 8.0 / 0.6))}]   ;# at most about 60% of the slices

# Sites of a list of clock regions whose name matches a pattern (by the regions' sites, or by the
# sites' CLOCK_REGION property)
proc tg_cr_sites {crs pat} {
  set n 0
  foreach cr $crs {
    set s [get_sites -quiet -of_objects $cr -filter "NAME =~ $pat"]
    if {![llength $s]} { set s [get_sites -quiet -filter "CLOCK_REGION == [get_property NAME $cr] && NAME =~ $pat"] }
    incr n [llength $s]
  }
  return $n
}
set pick {}
foreach span {1 2} {
  foreach cr [lsort [get_clock_regions]] {
    set crs [list $cr]
    if {$span == 2} {
      scan [get_property NAME $cr] "X%dY%d" x y
      set up [get_clock_regions -quiet "X${x}Y[expr {$y + 1}]"]
      if {$up eq ""} { continue }
      lappend crs $up
    }
    set d [tg_cr_sites $crs {DSP48E2_*}]
    set b [tg_cr_sites $crs {RAMB18_*}]
    set s [tg_cr_sites $crs {SLICE_*}]
    if {$d >= $need_dsp && $b >= $need_bram && $s >= $need_slc} { set pick $crs; break }
  }
  if {[llength $pick]} { break }
}
set fh [open pblock.txt w]
if {![llength $pick]} {
  puts $fh "no clock-region block fits: dsp $need_dsp bram $need_bram slices $need_slc"
  close $fh
  return
}
create_pblock pb_p4
set names {}
foreach cr $pick {
  set n [get_property NAME $cr]
  lappend names $n
  resize_pblock pb_p4 -add "CLOCKREGION_$n:CLOCKREGION_$n"
}
add_cells_to_pblock pb_p4 -top
puts $fh "pblock $names: dsp >= $need_dsp, bram >= $need_bram, slices >= $need_slc (luts $luts)"
close $fh
