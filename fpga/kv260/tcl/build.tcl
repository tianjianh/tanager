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
# TG_UNCORE_DSP (hex, e.g. 0x8403080000, the default): which register slices keep their data in DSPs
# (tg_uncore UNCORE_DSP, one bit per site; 0 is all fabric, 0xDEFFFFFFFFF every site but the AXI B slices)
set unc_gen {}; set unc_set {}
# TG_DEFINES (space-separated NAME=VALUE): Verilog defines for synthesis, e.g. the core's timing-cut
# profile (TG_TIMING_CUTS=0|1, DR-140). TG_PROFILE labels the build in summary.txt (and so the package).
set def_args {}
set defines [expr {[info exists ::env(TG_DEFINES)] ? $::env(TG_DEFINES) : ""}]
foreach d $defines { lappend def_args -verilog_define $d }
set profile [expr {[info exists ::env(TG_PROFILE)] ? $::env(TG_PROFILE) : "-"}]
if {[info exists ::env(TG_UNCORE_DSP)]} {
  lappend unc_gen -generic "UNCORE_DSP=64'h[format %016llX $::env(TG_UNCORE_DSP)]"
  lappend unc_set "UNCORE_DSP=$::env(TG_UNCORE_DSP)"
}
# The L2's data latency and the uncore's register slices, each on its own (kv260_top, DR-146): TG_L2_DATA_LAT
# (2 and up; unset or 0 picks by the clock: 4 above 150 MHz, else 2), TG_AR_SLICE, TG_B_SLICE, TG_D_SLICE,
# TG_W_SLICE, TG_XBAR_SLICE, TG_MEM_SLICE (0 or 1) and TG_XBAR_IN_SLICE (0-15, a bit per channel). Unset
# keeps tg_uncore_pkg's default; summary.txt lists the ones set. TG_DEBUG_CNT=1: the board debug counters.
# TG_VIRTIO_WINDOW=1: the forwarded virtio window, TG_HOST_DMA=1: the coherent host DMA port on
# M_AXI_HPM1_FPD (stage C, docs/spec/soc.md §8.1; without it reads there answer DECERR, writes are dropped).
foreach {v g hi} {TG_L2_DATA_LAT L2_DATA_LAT 8 TG_AR_SLICE AR_SLICE 1 TG_B_SLICE B_SLICE 1 TG_D_SLICE D_SLICE 1
                  TG_W_SLICE W_SLICE 1 TG_XBAR_IN_SLICE XBAR_IN_SLICE 15 TG_XBAR_SLICE XBAR_SLICE 1 TG_MEM_SLICE MEM_SLICE 1
                  TG_DEBUG_CNT DEBUG_CNT 1 TG_VIRTIO_WINDOW VIRTIO_WINDOW 1 TG_HOST_DMA HOST_DMA 1} {
  if {![info exists ::env($v)]} continue
  set val $::env($v)
  if {![string is integer -strict $val] || $val < 0 || $val > $hi || ($g eq "L2_DATA_LAT" && $val == 1)} {
    puts "ERROR: $v must be 0-$hi[expr {$g eq {L2_DATA_LAT} ? { but not 1} : {}}] (fpga/kv260/README.md)"
    exit 1
  }
  lappend unc_gen -generic "$g=$val"
  lappend unc_set "$g=$val"
}
# TG_PS_WINDOW=1: the PS window (stage D's D1, docs/spec/soc.md §8.2), the PS's peripheral registers through
# S_AXI_LPD. A map option (tg_map_pkg PS_WINDOW), so a define every file sees, the cores' PMA included. The
# block design has S_AXI_LPD and the PS's interrupts in every build, idle without the window.
if {[info exists ::env(TG_PS_WINDOW)]} {
  if {$::env(TG_PS_WINDOW) ni {0 1}} {
    puts "ERROR: TG_PS_WINDOW must be 0 or 1 (fpga/kv260/README.md)"
    exit 1
  }
  if {$::env(TG_PS_WINDOW)} {
    lappend def_args -verilog_define TG_PS_WINDOW=1
    lappend unc_set "PS_WINDOW=1"
  }
}
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
# TG_SYNTH_DIRECTIVE: synth_design's directive, AreaOptimized_high unless set (the coordinator, 10-16, DR-150:
# the two-core board build with the commit trace did not fit under Default, and spikes' full-chip fits and the
# area numbers already use AreaOptimized_high; at the board's clocks its timing cost is nil). Default gives the
# flow of the builds before 10-16 20:20. summary.txt records it.
set synth_dir [expr {[info exists ::env(TG_SYNTH_DIRECTIVE)] ? $::env(TG_SYNTH_DIRECTIVE) : "AreaOptimized_high"}]
stamp "synth_design ($synth_dir)"
synth_design -top kv260_top -part $part \
  -generic CORE_MHZ=$core_mhz -generic N_CORES=$n_cores -generic CORE_KIND=\"$kind\" -generic PMOD_UART=$pmod_uart \
  -generic FAN_WAVE=$fan_wave -generic FAN_INVERT=$fan_inv {*}$unc_gen {*}$def_args \
  -flatten_hierarchy rebuilt -directive $synth_dir
# Implicit and undriven nets in our own RTL fail the build (the coordinator, DR-150): a name used before its
# declaration becomes a one-bit wire in synthesis (Synth 8-11241 "undeclared symbol", 8-605 "same-named
# implicit nets", 8-8895 "already implicitly declared" at the real declaration), while Verilator finds the
# later declaration; tg_rename's rn_fire did this on the first smt2 board builds, and tg_uncore's debug
# counter select too. A name used before its declaration that Vivado resolves (8-6901) fails too, since the
# next such name may not resolve (core-2's 73e88bd, fpu-2's fd56b23 and tg_l2_bank's ev_pack removed the last
# ones). A net with no driver (8-3848) fails as well, as in spikes' synth_check.tcl. Messages about files
# outside the source tree ($root), such as Xilinx's generated PS IP in the run directory (dp_audio_ref_clk,
# irq_ipi_pl_*), are not ours and pass.
proc tg_check_implicit_nets {root logf} {
  if {![file exists $logf]} { puts "WARNING: no $logf to check for implicit nets"; return }
  set fh [open $logf r]
  set lines [split [read $fh] "\n"]
  close $fh
  set src [file normalize $root]
  set bad {}
  foreach l $lines {
    if {[regexp {\[Synth 8-(11241|605|8895|6901|3848)\]} $l] && [string first "$src/" $l] >= 0} { lappend bad $l }
  }
  if {[llength $bad]} {
    foreach l [lsort -unique $bad] { puts "ERROR: implicit or undriven net in our RTL: $l" }
    puts "ERROR: [llength $bad] implicit- or undriven-net message(s) in our RTL: declare every name before its first use, drive every net"
    exit 1
  }
  puts "TG_CHECK no implicit or undriven nets in our RTL"
}
tg_check_implicit_nets $root [file join [pwd] vivado.log]
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
# Placement and routing aim at a tighter core clock: TG_PR_UNC ns (default 1.0; 0 turns it off) of setup
# uncertainty on clk_core from placement through routing, taken back before the reports, which give the
# slack at the real period (DR-154, the coordinator, 10-17). At a plain 100 MHz target the placer
# under-works the cores; with 1.0 ns, spikes-2's headroom baseline closed main plus hart 1's filler with
# +1.065 ns (fpga/spikes/tcl/over_unc.tcl, the same method). summary.txt records it. timing.xdc sets no
# uncertainty of its own.
set pr_unc [expr {[info exists ::env(TG_PR_UNC)] ? $::env(TG_PR_UNC) : 1.0}]
if {![string is double -strict $pr_unc] || $pr_unc < 0 || $pr_unc > 3} {
  puts "ERROR: TG_PR_UNC must be 0-3 ns (fpga/kv260/README.md)"
  exit 1
}
# The core clock: Vivado derives it on the MMCM's CLKOUT0 and names it after the net, c0 (tg_clkgen). The
# first board build with this (d1_100, 10-17) found nothing with timing.xdc's pin query at this point, so
# the lookup tries the name, the pin and the BUFG's net, logs what each gave, retries once after a timing
# update, and without a clock places and routes as before (a warning; summary.txt says so).
proc tg_core_clock {} {
  foreach q {{get_clocks -quiet c0}
             {get_clocks -quiet -of_objects [get_pins -quiet u_clkgen/u_mmcm/CLKOUT0]}
             {get_clocks -quiet -of_objects [get_nets -quiet clk_core]}} {
    set c [uplevel #0 $q]
    puts "TG_PR_UNC clock query {$q}: [expr {[llength $c] ? $c : {none}}]"
    if {[llength $c] == 1} { return $c }
  }
  return {}
}
stamp "opt_design"
opt_design
tg_prim_check -file $rep/prim_check_opt.txt -fail 0
set pr_unc_note ""
if {$pr_unc > 0} {
  set core_clk [tg_core_clock]
  if {![llength $core_clk]} { update_timing -quiet; set core_clk [tg_core_clock] }
  if {[llength $core_clk]} {
    set_clock_uncertainty -setup $pr_unc $core_clk
  } else {
    puts "WARNING: TG_PR_UNC: no core clock found; placing and routing without the uncertainty"
    set pr_unc_note " not applied: no core clock found"
    set pr_unc 0
  }
}
stamp "place_design"
place_design
stamp "phys_opt_design"
phys_opt_design
stamp "route_design"
route_design
if {$pr_unc > 0} { set_clock_uncertainty -setup 0 $core_clk }   ;# the reports at the real period
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
puts $fh "profile=$profile defines=[expr {$defines eq {} ? {-} : $defines}] synth=$synth_dir"
puts $fh "pr_unc=$pr_unc (ns of setup uncertainty on clk_core for placement and routing, taken back before the reports)$pr_unc_note"
puts $fh "uncore=[expr {$unc_set eq {} ? {-} : $unc_set}]"
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
