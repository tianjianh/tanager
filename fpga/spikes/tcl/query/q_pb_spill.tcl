# Where each pblock's own cells sit in a placed checkpoint (DR-181's check, spikes §8.18): for every pblock, its own
# leaf cells by kind (LUT, LUTRAM, register, CARRY8, MUXF, block RAM, UltraRAM, DSP) inside and outside its sites, the
# other cells placed inside it, the slices its own cells use inside and outside, and the outside ones' bounding box.
# Writes pb_spill.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_pb_spill.tcl <placed.dcp>        (about 4 GB)
proc kind {ref} {
  foreach {pat k} {LUT* lut RAMB* bram RAM* lutram SRL* lutram FD* ff CARRY* carry MUXF* muxf URAM* uram DSP* dsp} {
    if {[string match $pat $ref]} { return $k }
  }
  return other
}
proc xy {site} {
  if {[regexp {_X(\d+)Y(\d+)$} $site -> x y]} { return [list $x $y] }
  return {}
}
open_checkpoint [lindex $argv 0]
set kinds {lut lutram ff carry muxf bram uram dsp other}
set fs [open pb_spill.txt w]
foreach pb [get_pblocks] {
  set sites [get_sites -quiet -of_objects $pb]
  set ins [dict create]
  foreach s [get_property NAME $sites] { dict set ins $s 1 }
  set nslice [llength [get_sites -quiet -of_objects $pb -filter {NAME =~ SLICE_*}]]
  foreach k $kinds { set oin($k) 0; set oout($k) 0; set ain($k) 0 }
  set sin [dict create]; set sout [dict create]; set unplaced 0
  # own leaf cells, read inside each assigned cell's instance (names with brackets need no glob)
  foreach c [get_cells -quiet -of_objects $pb] {
    current_instance -quiet
    if {[get_property IS_PRIMITIVE $c]} {
      set leaves $c
    } else {
      current_instance -quiet $c
      set leaves [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE}]
    }
    foreach ref [get_property REF_NAME $leaves] loc [get_property LOC $leaves] {
      set k [kind $ref]
      if {$loc eq ""} { incr unplaced; continue }
      if {[dict exists $ins $loc]} {
        incr oin($k)
        if {[string match SLICE_* $loc]} { dict set sin $loc 1 }
      } else {
        incr oout($k)
        if {[string match SLICE_* $loc]} { dict set sout $loc 1 }
      }
    }
    current_instance -quiet
  }
  # every leaf cell placed on the pblock's sites
  foreach ref [get_property REF_NAME [get_cells -quiet -of_objects $sites]] { incr ain([kind $ref]) }
  puts $fs [format "== %s: %d slices (%d LUT sites), ranges %s" $pb $nslice [expr {8 * $nslice}] [get_property GRID_RANGES $pb]]
  puts $fs [format "  %-7s %8s %8s %8s %8s" kind own_in own_out other_in all_in]
  foreach k $kinds {
    if {!($oin($k) + $oout($k) + $ain($k))} { continue }
    puts $fs [format "  %-7s %8d %8d %8d %8d" $k $oin($k) $oout($k) [expr {$ain($k) - $oin($k)}] $ain($k)]
  }
  set bb ""
  if {[dict size $sout]} {
    set xs {}; set ys {}
    foreach s [dict keys $sout] { lassign [xy $s] x y; lappend xs $x; lappend ys $y }
    set xs [lsort -integer $xs]; set ys [lsort -integer $ys]
    set bb [format ", outside within SLICE_X%dY%d:SLICE_X%dY%d" [lindex $xs 0] [lindex $ys 0] [lindex $xs end] [lindex $ys end]]
  }
  puts $fs [format "  own cells' slices: %d inside, %d outside%s; %d own cells unplaced" [dict size $sin] [dict size $sout] $bb $unplaced]
  flush $fs
}
close $fs
puts "Q_PB_SPILL_DONE"
