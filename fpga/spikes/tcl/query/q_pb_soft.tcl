# Why a pblock's own cells sit outside it (DR-181, after q_pb_spill.tcl): every pblock's properties, then its own leaf
# cells placed outside its sites, counted by the submodule they are in (two levels below the pblock's cell) and by
# name form (replicas and phys_opt's copies against synthesis's cells), with 12 samples (name, type, site, the cell's
# PBLOCK property). Writes pb_soft.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_pb_soft.tcl <placed.dcp>        (about 4 GB)
open_checkpoint [lindex $argv 0]
set fs [open pb_soft.txt w]
foreach pb [get_pblocks] {
  puts $fs "== $pb"
  foreach p [list_property $pb] { puts $fs [format "  %-24s %s" $p [get_property $p $pb]] }
  set ins [dict create]
  foreach s [get_property NAME [get_sites -quiet -of_objects $pb]] { dict set ins $s 1 }
  set by_sub [dict create]; set by_form [dict create]; set samples {}
  foreach c [get_cells -quiet -of_objects $pb] {
    set top [get_property NAME $c]
    current_instance -quiet
    current_instance -quiet $c
    set leaves [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE && LOC != ""}]
    foreach n [get_property NAME $leaves] ref [get_property REF_NAME $leaves] loc [get_property LOC $leaves] \
            pbp [get_property PBLOCK $leaves] {
      if {[dict exists $ins $loc]} { continue }
      set rel [string range $n [string length $top] end]
      set parts [split [string trimleft $rel /] /]
      set sub [expr {[llength $parts] > 2 ? [join [lrange $parts 0 1] /] : [llength $parts] > 1 ? [lindex $parts 0] : "(own level)"}]
      dict incr by_sub $sub
      set form [expr {[regexp {_replica(_\d+)?$|_rep(_\d+)?$|_rep__\d+$} $n] ? "replica" : \
                      [regexp {_bufg_place|_rewire|_psdsp|_hd|__phys_opt|_cascaded|_split} $n] ? "phys_opt" : "synthesis"}]
      dict incr by_form "$form [string range $ref 0 3]"
      if {[llength $samples] < 12 && [expr {[dict size $by_sub] + [llength $samples]}] % 3 == 0} {
        lappend samples [format "    %-90s %-10s %-16s pblock=%s" $n $ref $loc $pbp]
      }
    }
    current_instance -quiet
  }
  puts $fs "  outside, by submodule:"
  foreach {k v} [lsort -stride 2 -index 1 -integer -decreasing [dict get $by_sub]] { puts $fs [format "    %6d  %s" $v $k] }
  puts $fs "  outside, by name form and type:"
  foreach {k v} [lsort -stride 2 -index 1 -integer -decreasing [dict get $by_form]] { puts $fs [format "    %6d  %s" $v $k] }
  puts $fs "  samples:"
  foreach s $samples { puts $fs $s }
  flush $fs
}
close $fs
puts "Q_PB_SOFT_DONE"
