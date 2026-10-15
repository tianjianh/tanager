# Spike G4 (DR-136, for the SoC track): the v1 full chip in the board's own top, to see which of
# the uncore's register slices close with their main data register in DSP48E2s (tg_dsp_reg2) in
# the real placement. kv260_top as fpga/kv260/tcl/build.tcl builds it: the PS block design, the
# MMCM and both clocks, the PMOD console and the fan rule (DR-129), with real cores. Synthesis
# uses DR-113's settings (-flatten_hierarchy none, AreaOptimized_high), as the v1 budget does;
# without them two smt2 cores and the uncore do not fit the XCK26. Placement and routing use the
# board build's flow (opt, place, phys_opt, route; default directives).
# Run it only through tools/vivado_run.sh (conventions §9), e.g. by fpga/spikes/scripts/run_g4.sh:
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/g4_fit.tcl <repo-root> <cfg> <core_mhz> \
#       <uncore_dsp> [-n_cores N] [-constraints T] [-floorplan F] [-flatten M] [-synth_directive D]
#       [-dcp 0|1] [-synth_dcp D]
#   uncore_dsp   tg_uncore's UNCORE_DSP mask (e.g. 0xDCE03000000): one bit per register-slice site
#   -constraints a Tcl file sourced after synthesis (e.g. fpga/spikes/tcl/g3_false_paths.tcl); it
#                may write constraints.txt
#   -floorplan   a floorplan (fpga/spikes/tcl/fp/g4_*.tcl, with fp_lib.tcl's helpers), sourced after
#                the constraints; floorplan.txt and util_pblocks.rpt record it
#   -dcp 1       keep post_synth.dcp (after synthesis, before any constraint) and routed.dcp
#   -synth_dcp D start from such a post-synthesis checkpoint instead of synthesising (the same
#                design for every floorplan; its uncore_dsp argument must match the checkpoint's)
# Writes to the run directory: summary.txt (key value lines, with the uncore's figures),
# sites.txt (per register-slice site: its UNCORE_DSP bit, form, and the worst slack into and out
# of its main data register and into its control flops), sites_paths.rpt, uncore_paths.rpt,
# xbar_core.txt and xbar_core_paths.rpt (the crossbar's paths from and to the cores, by group),
# uncore_failing.txt (failing endpoints by block), uncore_internal.rpt, util.rpt, util_hier.rpt,
# timing_summary.rpt, timing.rpt, levels.rpt, prim_synth.txt, prim_opt.txt.

lassign $argv root cfg core_mhz uncore_dsp
set n_cores 2
set constraints ""
set flatten none
set synth_dir AreaOptimized_high
set keep_dcp 0
set floorplan ""
set synth_dcp ""
set rest [lrange $argv 4 end]
while {[llength $rest]} {
  set rest [lassign $rest k v]
  switch -- $k {
    -n_cores         { set n_cores $v }
    -constraints     { set constraints $v }
    -flatten         { set flatten $v }
    -synth_directive { set synth_dir $v }
    -dcp             { set keep_dcp $v }
    -floorplan       { set floorplan $v }
    -synth_dcp       { set synth_dcp $v }
    default { error "g4_fit.tcl: unknown option $k" }
  }
}
set mask [format %016llX $uncore_dsp]
set part xck26-sfvc784-2LV-c
# Synthesis forks one helper per thread (about 1-2 GB each): at most TANAGER_SYNTH_THREADS
# (default 2), as in ooc_run.tcl; placement and routing get 8.
set synth_threads [expr {[info exists ::env(TANAGER_SYNTH_THREADS)] ? $::env(TANAGER_SYNTH_THREADS) : 2}]
proc tg_kv {fh k v} { puts $fh [format "%-24s %s" $k $v] }
set t0 [clock seconds]

source [file join $root tools tcl tg_kv260_fan.tcl]
source [file join $root tools tcl tg_prim_check.tcl]
if {$synth_dcp ne ""} {
  set_param general.maxThreads 8
  open_checkpoint $synth_dcp
} else {
  create_project -in_memory -part $part
  set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
  set_param general.maxThreads $synth_threads

  # ---- the board top's sources, as build.tcl reads them ----
  source [file join $root fpga kv260 tcl ps_bd.tcl]
  tg_make_ps_bd [file normalize ./bd] $core_mhz
  read_verilog $::tg_ps_wrapper
  source [file join $root tools tcl tg_files.tcl]
  tg_read_rtl $root $cfg
  tg_read_f [file join $root fpga kv260 kv260.f]
  read_xdc [file join $root fpga kv260 xdc kv260.xdc]
  read_xdc [file join $root fpga kv260 xdc timing.xdc]

  synth_design -top kv260_top -part $part \
    -generic CORE_MHZ=$core_mhz -generic N_CORES=$n_cores -generic CORE_KIND=\"core\" \
    -generic PMOD_UART=1 -generic FAN_WAVE=$::tg_kv260_fan_bit -generic FAN_INVERT=$::tg_kv260_fan_invert \
    -generic "UNCORE_DSP=64'h$mask" \
    -flatten_hierarchy $flatten -directive $synth_dir
  set_param general.maxThreads 8
  if {$keep_dcp} { write_checkpoint -force post_synth.dcp }
}
# as build.tcl: the console pins and the fan are asynchronous to the PL clocks
set_false_path -from [get_ports pmod_uart_rxd]
set_false_path -to [get_ports pmod_uart_txd]
set_false_path -to [get_ports fan_en_b]
if {$constraints ne ""} { source [file join $root $constraints] }
close [open floorplan.txt w]
if {$floorplan ne ""} {
  source [file join $root fpga spikes tcl fp_lib.tcl]
  source [file join $root $floorplan]
}

set fh [open summary.txt w]
tg_kv $fh top kv260_top
tg_kv $fh cfg $cfg
tg_kv $fh n_cores $n_cores
tg_kv $fh core_mhz $core_mhz
tg_kv $fh uncore_dsp 0x$mask
tg_kv $fh synth [expr {$synth_dcp ne "" ? "from $synth_dcp" : "-flatten_hierarchy $flatten -directive $synth_dir"}]
tg_kv $fh floorplan [expr {$floorplan ne "" ? $floorplan : "none"}]
tg_kv $fh pblocks [llength [get_pblocks -quiet]]
report_utilization -file util_synth.rpt
tg_kv $fh prim_fail_synth [tg_prim_check -file prim_synth.txt -fail 0]
tg_kv $fh synth_s [expr {[clock seconds] - $t0}]

# Utilisation figures as report_utilization counts them (CLB LUTs = logic + memory).
proc tg_util {fh tag} {
  set r [report_utilization -return_string]
  foreach {key label} {
    lut_total {CLB LUTs}  lut_logic {LUT as Logic}  lut_mem {LUT as Memory}
    ff {CLB Registers}  bram_tile {Block RAM Tile}  uram {URAM}  dsp {DSPs}
  } {
    set v NA
    if {[regexp "\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9.\]+)" $r -> n]} { set v $n }
    tg_kv $fh ${tag}_$key $v
  }
}
tg_util $fh synth

# ---- implementation, as build.tcl ----
set t1 [clock seconds]
opt_design
tg_kv $fh prim_fail_opt [tg_prim_check -file prim_opt.txt -fail 0]
place_design
tg_kv $fh place_s [expr {[clock seconds] - $t1}]
phys_opt_design
set t2 [clock seconds]
route_design
tg_kv $fh route_s [expr {[clock seconds] - $t2}]
tg_kv $fh impl_s [expr {[clock seconds] - $t0}]
tg_util $fh impl
# the routed design first, so a failing report does not cost the implementation
if {$keep_dcp} { write_checkpoint -force routed.dcp }
source [file join $root fpga spikes tcl g4_reports.tcl]
puts "G4_FIT_DONE $cfg $core_mhz 0x$mask"
