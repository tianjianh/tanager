# Out-of-context implementation of one RTL module with DR-113's synthesis settings, for area and
# placed-and-routed timing (SoC track; the uncore's DSP-select pass, DR-136).
#   TANAGER_VIVADO_MEM_GB=17 tools/vivado_run.sh <run-dir> fpga/kv260/tcl/ooc_impl.tcl <repo-root> <cfg> <top> <mhz> [GEN=VAL ...]
# (tg_uncore at st peaked at 14.4 GB.) TG_OOC_SLACK=1 also writes reports/ooc_failing.txt: the failing
# setup endpoints counted per instance two levels down and per cell kind, with each group's worst slack.
# TG_OOC_DIRECTIVE overrides the synthesis directive (default AreaOptimized_high; "Default" for Vivado's).
# clk runs at <mhz>; a clk_host port, if the module has one, at 100 MHz, asynchronous to clk.
# Writes reports/ooc_utilization.rpt (hierarchical), ooc_timing.rpt and a TG_OOC_IMPL summary line.
set root [lindex $argv 0]
set cfg  [lindex $argv 1]
set top  [lindex $argv 2]
set mhz  [lindex $argv 3]
set gens [lrange $argv 4 end]
set part xck26-sfvc784-2LV-c
file mkdir reports
source [file join $root tools tcl tg_files.tcl]
tg_read_rtl $root $cfg
set_param general.maxThreads 8
set gargs {}
foreach g $gens { lappend gargs -generic $g }
set directive [expr {[info exists ::env(TG_OOC_DIRECTIVE)] ? $::env(TG_OOC_DIRECTIVE) : "AreaOptimized_high"}]
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none -directive $directive {*}$gargs
create_clock -name clk -period [expr {1000.0 / $mhz}] [get_ports clk]
if {[llength [get_ports -quiet clk_host]]} {
  create_clock -name clk_host -period 10.0 [get_ports clk_host]
  set_clock_groups -asynchronous -group clk -group clk_host
}
opt_design
place_design
phys_opt_design
route_design
report_utilization -hierarchical -hierarchical_depth 3 -file reports/ooc_utilization.rpt
report_utilization -file reports/ooc_utilization_flat.rpt
report_timing_summary -max_paths 20 -file reports/ooc_timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set fh [open reports/ooc_utilization_flat.rpt]
set txt [read $fh]
close $fh
set luts ?; set ffs ?; set dsps ?
regexp {\|\s*CLB LUTs\*?\s*\|\s*(\d+)} $txt -> luts
regexp {\|\s*CLB Registers\s*\|\s*(\d+)} $txt -> ffs
regexp {\|\s*DSPs\s*\|\s*(\d+)} $txt -> dsps
puts "TG_OOC_IMPL $top $gens LUT=$luts FF=$ffs DSP=$dsps WNS=$wns WHS=$whs"
if {[info exists ::env(TG_OOC_SLACK)] && $::env(TG_OOC_SLACK)} {
  set cnt [dict create]
  set worst [dict create]
  foreach p [get_timing_paths -setup -max_paths 50000 -nworst 1 -unique_pins -slack_lesser_than 0] {
    set cell [get_cells -of_objects [get_property ENDPOINT_PIN $p]]
    set ref  [get_property REF_NAME $cell]
    set kind [expr {[string match DSP* $ref] ? "DSP" : [string match RAMB* $ref] ? "RAMB" :
                    [string match URAM* $ref] ? "URAM" : [string match FD* $ref] ? "FF" : $ref}]
    set key  "[join [lrange [split [get_property NAME $cell] /] 0 1] /] $kind"
    dict incr cnt $key
    set sl [get_property SLACK $p]
    if {![dict exists $worst $key] || $sl < [dict get $worst $key]} { dict set worst $key $sl }
  }
  set rows {}
  dict for {k n} $cnt { lappend rows [list $k $n [dict get $worst $k]] }
  set fh [open reports/ooc_failing.txt w]
  foreach r [lsort -real -index 2 $rows] { puts $fh [format "%-64s %6d %8.3f" {*}$r] }
  close $fh
}
