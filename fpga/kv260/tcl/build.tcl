# Non-project build of the KV260 bitstream (docs/spec/soc.md §2.4).
#   tools/vivado_run.sh <run-dir> fpga/kv260/tcl/build.tcl <repo-root> <cfg> <kind> <core_mhz> [n_cores] [stop]
#     cfg:   st | smt2 | st_w3 | smt2_w3        kind: core | trafgen
#     stop:  synth | impl | bit (default bit)
# Reports go to <run-dir>/reports; checkpoints are not kept (conventions §9).
lassign $argv root cfg kind core_mhz n_cores stop
if {$n_cores eq ""} { set n_cores 1 }
if {$stop eq ""} { set stop bit }
set part xck26-sfvc784-2LV-c
set rep [file normalize ./reports]
file mkdir $rep
set t0 [clock seconds]
proc stamp {msg} { puts "TG_STAGE [clock format [clock seconds] -format %T] $msg" }

create_project -in_memory -part $part
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_param general.maxThreads 8

# ---- PS block design ----
stamp "block design"
source [file join $root fpga kv260 tcl ps_bd.tcl]
tg_make_ps_bd [file normalize ./bd] $core_mhz
read_verilog $::tg_ps_wrapper

# ---- RTL ----
source [file join $root tools tcl tg_files.tcl]
tg_read_rtl $root $cfg
tg_read_f [file join $root fpga kv260 kv260.f]
read_xdc [file join $root fpga kv260 xdc kv260.xdc]
read_xdc [file join $root fpga kv260 xdc timing.xdc]

# ---- synthesis ----
stamp "synth_design"
synth_design -top kv260_top -part $part \
  -generic CORE_MHZ=$core_mhz -generic N_CORES=$n_cores -generic CORE_KIND=\"$kind\" \
  -flatten_hierarchy rebuilt
report_utilization -file $rep/synth_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $rep/synth_utilization_hier.rpt
report_timing_summary -max_paths 10 -file $rep/synth_timing_summary.rpt
if {$stop eq "synth"} { stamp "done (synth)"; exit 0 }

# ---- implementation ----
stamp "opt_design"
opt_design
stamp "place_design"
place_design
stamp "phys_opt_design"
phys_opt_design
stamp "route_design"
route_design
stamp "reports"
report_timing_summary -max_paths 20 -report_unconstrained -file $rep/timing_summary.rpt
report_utilization -file $rep/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $rep/utilization_hier.rpt
report_clock_utilization -file $rep/clock_utilization.rpt
report_drc -file $rep/drc.rpt
report_cdc -file $rep/cdc.rpt
source [file join $root fpga kv260 tcl prim_check.tcl]
tg_prim_check $rep/primitives.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "TG_TIMING WNS=$wns WHS=$whs"
set fh [open $rep/summary.txt w]
puts $fh "cfg=$cfg kind=$kind core_mhz=$core_mhz n_cores=$n_cores"
puts $fh "WNS=$wns WHS=$whs"
puts $fh "runtime_s=[expr {[clock seconds] - $t0}]"
close $fh
if {$stop eq "impl"} { stamp "done (impl)"; exit 0 }

# ---- bitstream ----
stamp "write_bitstream"
write_bitstream -force ./tanager.bit
# .bit.bin for the Linux FPGA manager (fpgautil / xmutil), made by bootgen
set fh [open ./tanager.bif w]
puts $fh "all: { [file normalize ./tanager.bit] }"
close $fh
exec bootgen -arch zynqmp -image ./tanager.bif -process_bitstream bin -w on
stamp "done"
