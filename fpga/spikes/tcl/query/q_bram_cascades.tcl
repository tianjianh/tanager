# Which block RAMs are depth cascades (spikes §7.1's fix F): per memory instance (the RAM cells' path above
# xpm_memory_base_inst), its RAMB36E2/RAMB18E2 count, how many sit in a cascade (CASCADE_ORDER_A or _B not NONE), and the
# read widths; then the worst setup slack of paths that start at the instance's RAMs. Writes bram_cascades.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_bram_cascades.tcl <routed.dcp>      (about 4 GB)
open_checkpoint [lindex $argv 0]
foreach c [get_clocks] { set_clock_uncertainty -setup 0 $c }
set fs [open bram_cascades.txt w]
set inst [dict create]
foreach r [get_cells -quiet -hierarchical -filter {PRIMITIVE_GROUP == BLOCKRAM}] {
  set n [get_property NAME $r]
  set k [regsub {/xpm_memory_base_inst/.*$} $n {}]
  dict lappend inst $k $r
}
puts $fs [format "%-80s %5s %5s  %-12s %s" instance rams casc widths "worst slack from its RAMs"]
dict for {k rams} $inst {
  set nc 0; set ws {}
  foreach r $rams {
    if {[get_property -quiet CASCADE_ORDER_A $r] ni {NONE {}} || [get_property -quiet CASCADE_ORDER_B $r] ni {NONE {}}} { incr nc }
    lappend ws "[get_property -quiet READ_WIDTH_A $r]/[get_property -quiet READ_WIDTH_B $r]"
  }
  set p [get_timing_paths -quiet -setup -from $rams -max_paths 1 -nworst 1]
  set sl [expr {[llength $p] ? [format %.3f [get_property SLACK $p]] : "-"}]
  puts $fs [format "%-80s %5d %5d  %-12s %s" $k [llength $rams] $nc [join [lsort -unique $ws] ,] $sl]
}
close $fs
puts "Q_BRAM_CASCADES_DONE"
