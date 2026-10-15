# Non-project build of the KV260 bitstream (docs/spec/soc.md §2.4).
#   tools/vivado_run.sh <run-dir> fpga/kv260/tcl/build.tcl <repo-root> <cfg> <kind> <core_mhz> [n_cores] [stop]
#     cfg:   st | smt2 | st_w3 | smt2_w3        kind: core | trafgen
#     stop:  synth | impl | bit (default bit)
# Reports go to <run-dir>/reports; checkpoints are not kept (conventions §9).
# Environment: TG_PMOD_UART=1 puts the RISC-V console on the PMOD connector (kv260_top PMOD_UART);
# its pins are in xdc/kv260.xdc (H12 / B10, PMOD J2 pins 1 and 2, with their source), and
# TG_PMOD_TXD / TG_PMOD_RXD override them.
lassign $argv root cfg kind core_mhz n_cores stop
set pmod_uart [expr {[info exists ::env(TG_PMOD_UART)] ? $::env(TG_PMOD_UART) : 0}]
# The commit the sources come from, for summary.txt (fpga/kv260/package.sh), taken before they are read.
# A snapshot without git (git archive, README) names it in TG_COMMIT.
if {[info exists ::env(TG_COMMIT)]} {
  set commit $::env(TG_COMMIT)
} elseif {[catch {exec git -C $root rev-parse --short=12 HEAD} commit]} {
  set commit unknown
} elseif {![catch {exec git -C $root status --porcelain --untracked-files=no -- rtl fpga tools} dirty] && $dirty ne ""} {
  append commit "+dirty"
}
# The fan stays under Linux's control (DR-129): A12 carries the PS TTC waveform that Linux's pwm-fan
# drives, as Kria's own PL design routes it. The facts live in tools/tcl/tg_kv260_fan.tcl, shared with
# spike S1 (TTC0 channel 2, uninverted); TG_FAN_TTC / TG_FAN_WAVE / TG_FAN_INVERT override them.
source [file join $root tools tcl tg_kv260_fan.tcl]
foreach {v g lo hi} {TG_FAN_TTC tg_kv260_fan_ttc 0 3 TG_FAN_WAVE tg_kv260_fan_bit 0 2 TG_FAN_INVERT tg_kv260_fan_invert 0 1} {
  if {[info exists ::env($v)]} { set ::$g $::env($v) }
  set val [set ::$g]
  if {![string is integer -strict $val] || $val < $lo || $val > $hi} {
    puts "ERROR: $v must be $lo-$hi (DR-129, fpga/kv260/README.md)"
    exit 1
  }
}
set fan_wave $::tg_kv260_fan_bit; set fan_inv $::tg_kv260_fan_invert
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
  -generic CORE_MHZ=$core_mhz -generic N_CORES=$n_cores -generic CORE_KIND=\"$kind\" -generic PMOD_UART=$pmod_uart \
  -generic FAN_WAVE=$fan_wave -generic FAN_INVERT=$fan_inv \
  -flatten_hierarchy rebuilt
# PMOD console pins (xdc/kv260.xdc) can be overridden; they are asynchronous to clk_core
if {[info exists ::env(TG_PMOD_TXD)]} { set_property PACKAGE_PIN $::env(TG_PMOD_TXD) [get_ports pmod_uart_txd] }
if {[info exists ::env(TG_PMOD_RXD)]} { set_property PACKAGE_PIN $::env(TG_PMOD_RXD) [get_ports pmod_uart_rxd] }
set_false_path -from [get_ports pmod_uart_rxd]
set_false_path -to [get_ports pmod_uart_txd]
set_false_path -to [get_ports fan_en_b]          ;# the PS TTC's PWM, unrelated to the PL clocks
report_utilization -file $rep/synth_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $rep/synth_utilization_hier.rpt
report_timing_summary -max_paths 10 -file $rep/synth_timing_summary.rpt
source [file join $root tools tcl tg_prim_check.tcl]
tg_prim_check -file $rep/prim_check_synth.txt -fail 0
if {$stop eq "synth"} { stamp "done (synth)"; exit 0 }

# ---- implementation ----
stamp "opt_design"
opt_design
tg_prim_check -file $rep/prim_check_opt.txt -fail 0
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
puts $fh "commit=$commit"
puts $fh "pmod_uart=$pmod_uart txd=[get_property PACKAGE_PIN [get_ports pmod_uart_txd]] rxd=[get_property PACKAGE_PIN [get_ports pmod_uart_rxd]]"
puts $fh "fan=ttc$::tg_kv260_fan_ttc.wave$fan_wave invert=$fan_inv pin=[get_property PACKAGE_PIN [get_ports fan_en_b]]"
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
