# Floorplan runs of one core, for the core track's timing pass (its floorplan brief: wire is
# 65-75% of every deep path at 200 MHz). Opens a checkpoint of tg_core out of context (one clock,
# as the core track's unit timing flow builds it), clears its placement and routing, applies a
# floorplan (pblocks per unit, fpga/spikes/tcl/fp/*.tcl, with fp_lib.tcl's helpers), then places
# and routes again and reports the families of paths that cross units, as that flow does, so the
# runs compare with its unconstrained baseline.
# Run it only through tools/vivado_run.sh (conventions §9), e.g. by fpga/spikes/scripts/run_fp.sh:
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/fp_core.tcl <repo-root> <checkpoint.dcp> \
#       <floorplan.tcl | none> [-place D] [-route D] [-dcp 0|1]
#   none re-places and re-routes without pblocks: the control for run-to-run variation
# Writes to the run directory: summary.txt (key value lines), floorplan.txt, util.rpt,
# util_hier.rpt, util_pblocks.rpt, timing.rpt, timing_worst.rpt, levels.rpt, paths.tsv (the worst
# path into each of the 2,000 worst endpoints, with the units it crosses), fam_<name>.rpt,
# regions.txt (each unit's slices per clock region).

lassign $argv root dcp fp
set place_dir Default
set route_dir Default
set keep_dcp 0
set rest [lrange $argv 3 end]
while {[llength $rest]} {
  set rest [lassign $rest k v]
  switch -- $k {
    -place { set place_dir $v }
    -route { set route_dir $v }
    -dcp   { set keep_dcp $v }
    default { error "fp_core.tcl: unknown option $k" }
  }
}
proc tg_kv {fh k v} { puts $fh [format "%-24s %s" $k $v] }
set t0 [clock seconds]
set_param general.maxThreads 8

open_checkpoint $dcp
set clk [get_clocks]
set period [get_property PERIOD [lindex $clk 0]]
route_design -unroute
place_design -unplace
set fh [open summary.txt w]
tg_kv $fh checkpoint $dcp
tg_kv $fh floorplan $fp
tg_kv $fh period_ns $period
close [open floorplan.txt w]
if {$fp ne "none"} {
  source [file join $root fpga spikes tcl fp_lib.tcl]
  source [file join $root $fp]
}
tg_kv $fh pblocks [llength [get_pblocks -quiet]]

set t1 [clock seconds]
place_design -directive $place_dir
tg_kv $fh place_s [expr {[clock seconds] - $t1}]
phys_opt_design
set t2 [clock seconds]
route_design -directive $route_dir
tg_kv $fh route_s [expr {[clock seconds] - $t2}]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
tg_kv $fh wns_route_ns [format %.3f $wns]
if {$wns ne "" && $wns < 0} { phys_opt_design }
tg_kv $fh impl_s [expr {[clock seconds] - $t0}]

report_utilization -file util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -hierarchical_min_primitive_count 0 -file util_hier.rpt
if {[llength [get_pblocks -quiet]]} { report_utilization -pblocks [get_pblocks] -file util_pblocks.rpt }
report_timing -max_paths 30 -nworst 1 -unique_pins -input_pins -sort_by slack -file timing.rpt
report_timing -max_paths 1 -input_pins -file timing_worst.rpt
report_design_analysis -logic_level_distribution -logic_level_dist_paths 2000 -file levels.rpt

set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
tg_kv $fh wns_ns [format %.3f [get_property SLACK $p]]
tg_kv $fh fmax_mhz [format %.1f [expr {1000.0 / ($period - [get_property SLACK $p])}]]
tg_kv $fh worst_levels [get_property LOGIC_LEVELS $p]
tg_kv $fh worst_logic_ns [get_property DATAPATH_LOGIC_DELAY $p]
tg_kv $fh worst_net_ns [get_property DATAPATH_NET_DELAY $p]
tg_kv $fh worst_from [get_property NAME [get_property STARTPOINT_PIN $p]]
tg_kv $fh worst_to [get_property NAME [get_property ENDPOINT_PIN $p]]
tg_kv $fh whs_ns [format %.3f [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]]
# total negative slack and failing endpoints, from the design timing summary's first row
set r [report_timing_summary -no_detailed_paths -no_check_timing -return_string]
if {[regexp {WNS\(ns\)\s+TNS\(ns\)\s+TNS Failing Endpoints[^\n]*\n\s*-[- ]+\n\s*(-?[0-9.]+)\s+(-?[0-9.]+)\s+([0-9]+)\s+([0-9]+)} \
      $r -> - tns nfail nend]} {
  tg_kv $fh tns_ns $tns
  tg_kv $fh failing_endpoints "$nfail of $nend"
}

# The worst path into each of the 2,000 worst endpoints, with the units it crosses (as the core
# track's paths.tsv)
set fp_tsv [open paths.tsv w]
puts $fp_tsv "slack\tlevels\tlogic_ns\tnet_ns\tstart\tend\tunits"
set wire_sum 0.0; set delay_sum 0.0
foreach q [get_timing_paths -max_paths 2000 -nworst 1 -setup] {
  set units {}
  foreach c [get_cells -quiet -of_objects $q] {
    set u [lindex [split [get_property NAME $c] /] 0]
    if {[llength $units] == 0 || [lindex $units end] ne $u} { lappend units $u }
  }
  set ln [get_property DATAPATH_LOGIC_DELAY $q]; set nn [get_property DATAPATH_NET_DELAY $q]
  set wire_sum [expr {$wire_sum + $nn}]; set delay_sum [expr {$delay_sum + $ln + $nn}]
  puts $fp_tsv [format "%.3f\t%d\t%.3f\t%.3f\t%s\t%s\t%s" [get_property SLACK $q] [get_property LOGIC_LEVELS $q] \
    $ln $nn [get_property NAME [get_property STARTPOINT_PIN $q]] [get_property NAME [get_property ENDPOINT_PIN $q]] \
    [join $units >]]
}
close $fp_tsv
tg_kv $fh wire_share_2000 [format %.3f [expr {$delay_sum > 0 ? $wire_sum / $delay_sum : 0}]]

# The worst path into each family's endpoints (the core track's groups)
foreach {name pats} {de {u_de/dred_pc_reg*} rnuop {u_rn/rn_uop_q_reg*} iqptr {u_fetch/u_cmp/head_q_reg* u_fetch/u_cmp/occ_q_reg*}
                     fpc {u_fetch/fpc_q_reg*} f2 {u_fetch/f2_*_q_reg*} dc {u_lsu/u_dc/g_data*} map {u_rn/u_imap/*}
                     robx {u_rob/exr_*} robrw {u_rob/g_rw*} robft {u_rob/g_ft*} lsuq {u_lsu/lq_st_q_reg* u_lsu/sq_*_q_reg*}} {
  set cells {}
  foreach pat $pats {
    set cells [concat $cells [get_cells -quiet -hier -filter "NAME =~ \"$pat\" && (IS_SEQUENTIAL || PRIMITIVE_GROUP == BLOCKRAM || PRIMITIVE_GROUP == DISTRAM)"]]
  }
  if {![llength $cells]} { tg_kv $fh fam_$name none; continue }
  set q [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -to $cells]
  if {$q eq ""} { tg_kv $fh fam_$name unconstrained; continue }
  tg_kv $fh fam_$name [format "slack %.3f levels %d logic %.3f net %.3f %s -> %s" [get_property SLACK $q] \
    [get_property LOGIC_LEVELS $q] [get_property DATAPATH_LOGIC_DELAY $q] [get_property DATAPATH_NET_DELAY $q] \
    [get_property NAME [get_property STARTPOINT_PIN $q]] [get_property NAME [get_property ENDPOINT_PIN $q]]]
  report_timing -of_objects $q -input_pins -file fam_$name.rpt
}
# The worst path into each named group of endpoints (as the core track's summary)
foreach {name glob} {ds_ren {*ds_ren_q_reg*} rdytab {*u_irdy* *u_frdy*} rmap {*u_imap* *u_fmap*} fl {*u_fl*}} {
  set cells {}
  foreach g $glob { set cells [concat $cells [get_cells -quiet -hier -filter "NAME =~ \"$g\" && IS_SEQUENTIAL"]] }
  if {[llength $cells] == 0} { tg_kv $fh path_$name none; continue }
  set q [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -to $cells]
  if {$q eq ""} { tg_kv $fh path_$name unconstrained; continue }
  tg_kv $fh path_$name [format "slack %.3f levels %d %s -> %s" [get_property SLACK $q] \
    [get_property LOGIC_LEVELS $q] [get_property NAME [get_property STARTPOINT_PIN $q]] \
    [get_property NAME [get_property ENDPOINT_PIN $q]]]
}

# Each unit's slices (sites holding its LUTs) per clock region, and where the block RAM and DSPs went
set rf [open regions.txt w]
foreach blk [get_cells -filter {!IS_PRIMITIVE}] {
  current_instance -quiet
  current_instance -quiet $blk
  set cnt [dict create]
  foreach cr [get_property CLOCK_REGION [get_sites -quiet -of_objects \
      [get_cells -quiet -hierarchical -filter {PRIMITIVE_GROUP == LUT || PRIMITIVE_GROUP == DISTRAM}]]] {
    if {$cr ne ""} { dict incr cnt $cr }
  }
  current_instance -quiet
  set line [format "%-12s" [get_property NAME $blk]]
  foreach k [lsort [dict keys $cnt]] { append line [format " %s:%d" $k [dict get $cnt $k]] }
  puts $rf $line
}
foreach ref {RAMB36E2 RAMB18E2 DSP48E2} {
  set cnt [dict create]
  foreach cr [get_property CLOCK_REGION [get_sites -quiet -of_objects [get_cells -quiet -hier -filter "REF_NAME == $ref"]]] {
    if {$cr ne ""} { dict incr cnt $cr }
  }
  set line [format "%-12s" $ref]
  foreach k [lsort [dict keys $cnt]] { append line [format " %s:%d" $k [dict get $cnt $k]] }
  puts $rf $line
}
close $rf
if {$keep_dcp} { write_checkpoint -force routed.dcp }
tg_kv $fh total_s [expr {[clock seconds] - $t0}]
close $fh
puts "FP_CORE_DONE $fp"
