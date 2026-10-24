# The LSU's address CAMs in a post-synthesis checkpoint (spikes §8.18's area exploration, the coordinator 10-21): for
# core 0's lq_pa_q and sq_pa_q (one register per entry and bit), the LUTs their bits feed, the first level of every
# comparator and mux that reads them, and the next level (LUTs fed only by those). Per array: the entries, the bits
# per entry, the first-level LUTs, the LUTs per entry, the second level. Writes cam_cost.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_cam_cost.tcl <post_synth.dcp>        (about 5 GB)
open_checkpoint [lindex $argv 0]
set pre "u_soc/g_core\[0\].g_tgc.u_core/u_lsu/"
set fs [open cam_cost.txt w]
foreach arr {lq_pa_q sq_pa_q} {
  set ffs [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}${arr}_reg* && IS_SEQUENTIAL"]
  set ent [dict create]
  foreach c $ffs {
    if {[regexp "${arr}_reg\\\[(\\d+)\\\]\\\[(\\d+)\\\]" [get_property NAME $c] -> e b]} { dict incr ent $e }
  }
  set qn [get_nets -quiet -of_objects [get_pins -quiet -of_objects $ffs -filter {REF_PIN_NAME == Q}]]
  set l1 [lsort -unique [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $qn -filter {DIRECTION == IN}] -filter {REF_NAME =~ LUT*}]]
  set l1d [dict create]; foreach c $l1 { dict set l1d [get_property NAME $c] 1 }
  # the second level: LUTs every one of whose LUT inputs comes from the first level
  set l2 {}
  set on [get_nets -quiet -of_objects [get_pins -quiet -of_objects $l1 -filter {DIRECTION == OUT}]]
  foreach c [lsort -unique [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $on -filter {DIRECTION == IN}] -filter {REF_NAME =~ LUT*}]] {
    set ok 1
    foreach p [get_pins -quiet -of_objects $c -filter {DIRECTION == IN}] {
      set d [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects [get_nets -quiet -of_objects $p] -filter {DIRECTION == OUT}]]
      if {[llength $d] && [get_property REF_NAME $d] ne "" && [string match LUT* [get_property REF_NAME $d]] && ![dict exists $l1d [get_property NAME $d]]} { set ok 0; break }
    }
    if {$ok} { lappend l2 $c }
  }
  set ne [dict size $ent]
  set nb [expr {$ne ? [lindex [lsort -integer -decreasing [dict values $ent]] 0] : 0}]
  puts $fs [format "%-8s %2d entries x %2d bits (%d registers): first level %4d LUTs (%.1f an entry), second level %4d" \
    $arr $ne $nb [llength $ffs] [llength $l1] [expr {$ne ? double([llength $l1]) / $ne : 0}] [llength $l2]]
}
close $fs
puts "Q_CAM_COST_DONE"
