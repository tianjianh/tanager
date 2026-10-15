# Out-of-context implementation of one RTL module with DR-113's synthesis settings, for area and
# placed-and-routed timing (SoC track; the uncore's DSP-select pass, DR-136).
#   TANAGER_VIVADO_MEM_GB=12 tools/vivado_run.sh <run-dir> fpga/kv260/tcl/ooc_impl.tcl <repo-root> <cfg> <top> <mhz> [GEN=VAL ...]
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
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none -directive AreaOptimized_high {*}$gargs
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
