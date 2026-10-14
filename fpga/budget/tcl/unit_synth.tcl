# Out-of-context synthesis of one product unit for the per-unit LUT budgets (plan §8.5;
# fpga/budget/README.md). Run it only through tools/vivado_run.sh (conventions §9):
#   tools/vivado_run.sh <run-dir> fpga/budget/tcl/unit_synth.tcl <repo-root> <cfg> <top> \
#       [-g NAME=VALUE]... [-file <path>]...
#   -g     a top-level generic (repeatable)
#   -file  an extra source beyond rtl/rtl.f, relative to the repo root or absolute
#          (repeatable): units the core track has not adopted yet still live in fpga/spikes
#   -flatten  synth_design -flatten_hierarchy (default rebuilt; none keeps every module's
#          own LUTs apart, for breakdowns)
#   -directive  synth_design -directive (default Default)
# Synthesis, then opt_design (which trims logic with no load), no placement: the counts are
# what the unit costs, not how it routes. The primitive check runs after both steps.
# Writes to the run directory: summary.txt (key value lines), prim_synth.txt, prim_opt.txt,
# util.rpt and util_hier.rpt (after opt_design).

set root [lindex $argv 0]
set cfg  [lindex $argv 1]
set top  [lindex $argv 2]
set generics {}
set files {}
set flatten rebuilt
set directive Default
set rest [lrange $argv 3 end]
while {[llength $rest]} {
  set rest [lassign $rest k v]
  switch -- $k {
    -g    { lappend generics $v }
    -file { lappend files $v }
    -flatten { set flatten $v }
    -directive { set directive $v }
    default { error "unit_synth.tcl: unknown option $k" }
  }
}

set part xck26-sfvc784-2LV-c
# Synthesis of a hierarchical design forks one Vivado process per thread (about 1-2 GB each):
# at most TANAGER_SYNTH_THREADS (default 2), so the job stays inside its declared memory
# (conventions §9; run_budget.py declares it per unit).
set_param general.maxThreads [expr {[info exists ::env(TANAGER_SYNTH_THREADS)] ? $::env(TANAGER_SYNTH_THREADS) : 2}]
source [file join $root tools tcl tg_files.tcl]
source [file join $root tools tcl tg_prim_check.tcl]

proc tg_kv {fh k v} { puts $fh [format "%-20s %s" $k $v] }

# CLB counts from report_utilization, into summary keys <tag>_<key>
proc tg_util {fh tag} {
  set r [report_utilization -return_string]
  foreach {key label} {
    lut {CLB LUTs}  lut_logic {LUT as Logic}  lut_mem {LUT as Memory}
    lut_dram {LUT as Distributed RAM}  lut_srl {LUT as Shift Register}
    ff {CLB Registers}  carry8 {CARRY8}  bram {Block RAM Tile}  ramb36 {RAMB36/FIFO}
    ramb18 {RAMB18}  uram {URAM}  dsp {DSPs}
  } {
    set v 0
    if {[regexp "\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9.\]+)" $r -> n]} { set v $n }
    tg_kv $fh ${tag}_$key $v
  }
}

set fh [open summary.txt w]
tg_kv $fh top $top
tg_kv $fh cfg $cfg
tg_kv $fh generics [expr {[llength $generics] ? [join $generics ,] : "-"}]
set t0 [clock seconds]
tg_read_rtl $root $cfg
foreach f $files { read_verilog -sv [file join $root $f] }
set opts [list -top $top -part $part -mode out_of_context -flatten_hierarchy $flatten \
              -directive $directive]
if {[llength $generics]} { lappend opts -generic $generics }
synth_design {*}$opts
if {[llength [get_ports -quiet clk]]} {
  create_clock -name clk -period 5.0 [get_ports clk]
}
tg_kv $fh synth_s [expr {[clock seconds] - $t0}]
tg_kv $fh prim_fail_synth [tg_prim_check -file prim_synth.txt -fail 0]
tg_util $fh synth
opt_design
tg_kv $fh prim_fail_opt [tg_prim_check -file prim_opt.txt -fail 0]
set nstray 0
set pf [open prim_opt.txt r]
while {[gets $pf line] >= 0} { if {[string match "PRIM_STRAY *" $line]} { incr nstray } }
close $pf
tg_kv $fh prim_stray $nstray
tg_util $fh opt
report_utilization -file util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -hierarchical_min_primitive_count 0 -file util_hier.rpt
tg_kv $fh total_s [expr {[clock seconds] - $t0}]
close $fh
puts "UNIT_SYNTH_DONE $top $cfg"
