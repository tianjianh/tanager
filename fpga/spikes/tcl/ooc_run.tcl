# Out-of-context synthesis, place and route of one spike top on the XCK26, with the reports
# docs/perf/spikes.md quotes. Run it only through tools/vivado_run.sh (conventions §9):
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/ooc_run.tcl <repo-root> <cfg> <top> \
#       <period-ns> [-g NAME=VALUE]... [-paths <file.tcl>] [-impl 0|1] [-dcp 0|1]
#       [-place <directive>] [-route <directive>] [-lut_target N [-lut_tol F]] [-extra 1]
#   -g      a top-level generic (repeatable)
#   -paths  a Tcl file that sets tg_paths: a list of {name to-glob ?from-glob?}; the worst
#           path ending at (and starting from) matching cells is reported per name
#   -impl 0 stops after synthesis (utilisation only)
#   -dcp 1  keeps a routed checkpoint (default 0: delete-after-report is the disk rule)
#   -lut_target N  after synthesis, stop (exit 3) unless CLB LUTs are within lut_tol
#           (default 0.025) of N: the S6 fill test must hit its utilisation
#   -extra 1  congestion and control-set reports (full-device runs)
# Writes to the run directory: summary.txt (key value lines), prim_synth.txt, prim_opt.txt,
# util.rpt, util_hier.rpt, timing.rpt (worst 20 paths), levels.rpt, paths.txt.

set root   [lindex $argv 0]
set cfg    [lindex $argv 1]
set top    [lindex $argv 2]
set period [lindex $argv 3]
set generics {}
set paths_file ""
set do_impl 1
set keep_dcp 0
set place_dir Default
set route_dir Default
set lut_target 0
set lut_tol 0.025
set extra 0
set rest [lrange $argv 4 end]
while {[llength $rest]} {
  set rest [lassign $rest k v]
  switch -- $k {
    -g      { lappend generics $v }
    -paths  { set paths_file $v }
    -impl   { set do_impl $v }
    -dcp    { set keep_dcp $v }
    -place  { set place_dir $v }
    -route  { set route_dir $v }
    -lut_target { set lut_target $v }
    -lut_tol    { set lut_tol $v }
    -extra      { set extra $v }
    default { error "ooc_run.tcl: unknown option $k" }
  }
}

set part xck26-sfvc784-2LV-c
set_param general.maxThreads 8
source [file join $root tools tcl tg_files.tcl]
source [file join $root tools tcl tg_prim_check.tcl]

proc tg_kv {fh k v} { puts $fh [format "%-24s %s" $k $v] }

set t0 [clock seconds]
read_verilog -sv [file join $root rtl common cfg tg_cfg_${cfg}.sv]
tg_read_f [file join $root rtl common common.f]
tg_read_f [file join $root fpga spikes spikes.f]

set gargs {}
foreach g $generics { lappend gargs -generic $g }
synth_design -top $top -part $part -mode out_of_context {*}$gargs

# One 200 MHz-class clock from a global buffer near the middle of the device, so the
# clock tree is routed as in a full design.
create_clock -period $period -name clk [get_ports clk]
set bufg [lindex [lsort [get_sites -filter {SITE_TYPE == BUFGCE && CLOCK_REGION == X1Y2}]] 0]
if {$bufg ne ""} { set_property HD.CLK_SRC $bufg [get_ports clk] }

set fh [open summary.txt w]
tg_kv $fh top $top
tg_kv $fh cfg $cfg
tg_kv $fh generics [join $generics ,]
tg_kv $fh period_ns $period

report_utilization -file util_synth.rpt
set nfail [tg_prim_check -file prim_synth.txt -fail 0]
tg_kv $fh prim_fail_synth $nfail
tg_kv $fh synth_s [expr {[clock seconds] - $t0}]

# Utilisation figures as report_utilization counts them (CLB LUTs = logic + memory).
proc tg_util {fh tag} {
  set r [report_utilization -return_string]
  foreach {key label} {
    lut_total {CLB LUTs}  lut_logic {LUT as Logic}  lut_mem {LUT as Memory}
    lut_dram {LUT as Distributed RAM}  lut_srl {LUT as Shift Register}
    ff {CLB Registers}  carry8 {CARRY8}  muxf7 {F7 Muxes}  muxf8 {F8 Muxes}
    bram_tile {Block RAM Tile}  uram {URAM}  dsp {DSPs}
  } {
    set v NA
    if {[regexp "\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9.\]+)" $r -> n]} { set v $n }
    tg_kv $fh ${tag}_$key $v
  }
}
tg_util $fh synth
if {$lut_target > 0} {
  set r [report_utilization -return_string]
  regexp {\|\s*CLB LUTs\*?\s*\|\s*([0-9]+)} $r -> luts
  tg_kv $fh lut_target $lut_target
  if {abs($luts - $lut_target) > $lut_tol * $lut_target} {
    tg_kv $fh lut_target_miss $luts
    close $fh
    puts "LUT_TARGET_MISS $luts vs $lut_target"
    exit 3
  }
}

if {$do_impl} {
  set t1 [clock seconds]
  opt_design
  set nfail [tg_prim_check -file prim_opt.txt -fail 0]
  tg_kv $fh prim_fail_opt $nfail
  place_design -directive $place_dir
  tg_kv $fh place_s [expr {[clock seconds] - $t1}]
  phys_opt_design
  set t2 [clock seconds]
  route_design -directive $route_dir
  tg_kv $fh route_s [expr {[clock seconds] - $t2}]
  set wns_route [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
  if {$wns_route ne "" && $wns_route < 0} {
    phys_opt_design
  }
  tg_kv $fh impl_s [expr {[clock seconds] - $t0}]
  tg_util $fh impl

  # Utilisation as Vivado reports it (CLB LUTs = logic + memory + SRL)
  report_utilization -file util.rpt
  report_utilization -hierarchical -hierarchical_depth 4 -file util_hier.rpt
  report_timing -max_paths 20 -nworst 1 -unique_pins -input_pins -sort_by slack -file timing.rpt
  report_timing -max_paths 1 -input_pins -file timing_worst.rpt
  report_timing_summary -max_paths 5 -file timing_summary.rpt
  report_design_analysis -logic_level_distribution -logic_level_dist_paths 2000 -file levels.rpt
  report_design_analysis -timing -max_paths 20 -file analysis.rpt
  if {$extra} {
    report_design_analysis -congestion -file congestion.rpt
    report_control_sets -verbose -file control_sets.rpt
    report_utilization -hierarchical -hierarchical_depth 2 -file util_hier2.rpt
  }

  set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
  tg_kv $fh wns_ns [format %.3f [get_property SLACK $p]]
  tg_kv $fh fmax_mhz [format %.1f [expr {1000.0 / ($period - [get_property SLACK $p])}]]
  tg_kv $fh worst_levels [get_property LOGIC_LEVELS $p]
  tg_kv $fh worst_logic_ns [get_property DATAPATH_LOGIC_DELAY $p]
  tg_kv $fh worst_net_ns [get_property DATAPATH_NET_DELAY $p]
  tg_kv $fh worst_from [get_property NAME [get_property STARTPOINT_PIN $p]]
  tg_kv $fh worst_to [get_property NAME [get_property ENDPOINT_PIN $p]]
  set h [get_timing_paths -max_paths 1 -nworst 1 -hold]
  tg_kv $fh whs_ns [format %.3f [get_property SLACK $h]]

  # Named paths
  set tg_paths {}
  if {$paths_file ne ""} {
    if {[file pathtype $paths_file] ne "absolute"} { set paths_file [file join $root $paths_file] }
    source $paths_file
  }
  set pf [open paths.txt w]
  foreach g $tg_paths {
    lassign $g name to from
    set to_cells [get_cells -quiet -hier -filter "NAME =~ \"$to\" && IS_SEQUENTIAL"]
    set args [list -max_paths 1 -nworst 1 -setup]
    if {[llength $to_cells] == 0} {
      puts $pf [format "%-22s none" $name]
      continue
    }
    lappend args -to $to_cells
    if {$from ne ""} {
      set from_cells [get_cells -quiet -hier -filter "NAME =~ \"$from\" && IS_SEQUENTIAL"]
      if {[llength $from_cells] == 0} {
        puts $pf [format "%-22s none" $name]
        continue
      }
      lappend args -from $from_cells
    }
    set q [get_timing_paths {*}$args]
    if {$q eq ""} {
      puts $pf [format "%-22s unconstrained" $name]
      continue
    }
    puts $pf [format "%-22s slack %7.3f levels %2d logic %.3f net %.3f  %s -> %s" $name \
      [get_property SLACK $q] [get_property LOGIC_LEVELS $q] \
      [get_property DATAPATH_LOGIC_DELAY $q] [get_property DATAPATH_NET_DELAY $q] \
      [get_property NAME [get_property STARTPOINT_PIN $q]] \
      [get_property NAME [get_property ENDPOINT_PIN $q]]]
    report_timing {*}$args -input_pins -file path_${name}.rpt
  }
  close $pf
  if {$keep_dcp} { write_checkpoint -force routed.dcp }
}
tg_kv $fh total_s [expr {[clock seconds] - $t0}]
close $fh
puts "OOC_RUN_DONE $top $cfg"
