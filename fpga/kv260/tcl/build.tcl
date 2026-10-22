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
# TG_L2_WB_PACE=1: the L2's write-back batching (tg_l2_bank WB_PACE, soc.md §8.5), with TG_L2_PACE_INIT (0-65535) the
# host-control block's L2_PACE at reset ([3:0] the batch, [15:4] the wait; unset: tg_uncore_pkg's L2_PACE_INIT_DEF).
# TG_VIRTIO_WINDOW=1: the forwarded virtio window, TG_HOST_DMA=1: the coherent host DMA port on
# M_AXI_HPM1_FPD (stage C, docs/spec/soc.md §8.1; without it reads there answer DECERR, writes are dropped).
# TG_LAT_INJ=0: a release build (DR-177), without the two AXI latency injectors; unset or 1 keeps them (a
# development build, for injected-latency tests). summary.txt says which.
# TG_RELEASE=1: a release build (DR-177, DR-180), the board's RISC-V-mode product: kv260_top RELEASE=1 (the PLIC's
# S-mode contexts alone with 1-bit priorities and no TTC1 source, no host console, the DMA port without its line
# counters or completion queue, the host bridge's crossings trimmed to the fields built), and with it LAT_INJ=0,
# VIRTIO_WINDOW=0 and TG_COMMIT_TRACE=0. It needs TG_PMOD_UART=1, the console then being the serial line alone, and
# refuses TG_LAT_INJ=1, TG_VIRTIO_WINDOW=1 or TG_COMMIT_TRACE=1 beside it. Unset or 0: a development build, as before.
set release [expr {[info exists ::env(TG_RELEASE)] ? $::env(TG_RELEASE) : 0}]
if {$release ni {0 1}} { puts "ERROR: TG_RELEASE must be 0 or 1 (fpga/kv260/README.md)"; exit 1 }
if {$release} {
  if {!$pmod_uart} {
    puts "ERROR: TG_RELEASE=1 needs TG_PMOD_UART=1: a release build's console is the serial line alone (DR-180)"
    exit 1
  }
  foreach v {TG_LAT_INJ TG_VIRTIO_WINDOW} {
    if {[info exists ::env($v)] && $::env($v) ne "0"} {
      puts "ERROR: TG_RELEASE=1 builds no [expr {$v eq {TG_LAT_INJ} ? {latency injectors} : {virtio window}}]: leave $v unset or 0"
      exit 1
    }
    set ::env($v) 0
  }
  if {[lsearch -regexp $defines {^TG_COMMIT_TRACE(=1)?$}] >= 0} {
    puts "ERROR: TG_RELEASE=1 builds no commit trace: leave TG_COMMIT_TRACE out of TG_DEFINES, or 0"
    exit 1
  }
  if {[lsearch -regexp $defines {^TG_COMMIT_TRACE=}] < 0} {
    lappend defines TG_COMMIT_TRACE=0
    lappend def_args -verilog_define TG_COMMIT_TRACE=0
  }
  lappend unc_gen -generic "RELEASE=1"
  lappend unc_set "RELEASE=1"
}
foreach {v g hi} {TG_L2_DATA_LAT L2_DATA_LAT 8 TG_AR_SLICE AR_SLICE 1 TG_B_SLICE B_SLICE 1 TG_D_SLICE D_SLICE 1
                  TG_W_SLICE W_SLICE 1 TG_XBAR_IN_SLICE XBAR_IN_SLICE 15 TG_XBAR_SLICE XBAR_SLICE 1 TG_MEM_SLICE MEM_SLICE 1
                  TG_DEBUG_CNT DEBUG_CNT 1 TG_VIRTIO_WINDOW VIRTIO_WINDOW 1 TG_HOST_DMA HOST_DMA 1 TG_LAT_INJ LAT_INJ 1
                  TG_L2_WB_PACE L2_WB_PACE 1 TG_L2_PACE_INIT L2_PACE_INIT 65535} {
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
# TG_URF=1: the core's integer register file in UltraRAM, double-pumped (DR-174; tg_core_pkg URF, off by
# default). A define every file sees, as the core's other switches: the core builds the UltraRAM file, and
# kv260_top adds clk2x, twice the core clock from its MMCM (tg_clkgen CLK2X), with xdc/timing_urf.xdc's clock
# constraints. Unset or 0 reads none of it: the build as before. TG_DEFINES must not set TG_URF.
set urf [expr {[info exists ::env(TG_URF)] ? $::env(TG_URF) : 0}]
if {$urf ni {0 1}} { puts "ERROR: TG_URF must be 0 or 1 (fpga/kv260/README.md)"; exit 1 }
if {[lsearch -regexp $defines {^TG_URF(=|$)}] >= 0} {
  puts "ERROR: TG_URF goes in its own variable, not in TG_DEFINES (fpga/kv260/README.md)"; exit 1
}
if {$urf} { lappend def_args -verilog_define TG_URF=1 }
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
# TG_FAN_PL (default 1): the fan's PL regulator (tg_fan, stage D's D2, DR-147): the duty is the larger of a curve
# of the PL SYSMON's temperature and the TTC waveform; 0 routes the waveform alone, as before.
set fan_pl [expr {[info exists ::env(TG_FAN_PL)] ? $::env(TG_FAN_PL) : 1}]
if {$fan_pl ni {0 1}} { puts "ERROR: TG_FAN_PL must be 0 or 1 (fpga/kv260/README.md)"; exit 1 }
# opt_design's directive (DR-166, the coordinator, 10-18): ExploreArea for board builds. On spikes-2's full M6
# chip it left 1,275 fewer LUTs than the default (116,511 against 117,786, flip-flops unchanged), and that
# netlist routed at 100 MHz (+0.725 ns, h100_m6fa) where the default's didn't place. TG_OPT_DIRECTIVE=Default
# gives the plain opt_design; summary.txt records the directive. Checked here, before synthesis.
set opt_dir [expr {[info exists ::env(TG_OPT_DIRECTIVE)] ? $::env(TG_OPT_DIRECTIVE) : "ExploreArea"}]
if {$opt_dir ni {Default Explore ExploreArea ExploreWithRemap ExploreSequentialArea AddRemap RuntimeOptimized NoBramPowerOpt}} {
  puts "ERROR: TG_OPT_DIRECTIVE must be one of opt_design's directives (fpga/kv260/README.md)"; exit 1
}
# place_design's directive (DR-187, the coordinator, 10-22): unset gives the plain place_design (Default).
# AltSpreadLogic_high made the product chip route where the default left it congested (spikes 8.18).
# summary.txt records it as place=. Checked here, before synthesis.
set place_dir [expr {[info exists ::env(TG_PLACE_DIRECTIVE)] ? $::env(TG_PLACE_DIRECTIVE) : "Default"}]
if {$place_dir ni {Default Explore EarlyBlockPlacement WLDrivenBlockPlacement ExtraNetDelay_high ExtraNetDelay_low
                   AltSpreadLogic_high AltSpreadLogic_medium AltSpreadLogic_low ExtraPostPlacementOpt ExtraTimingOpt
                   RuntimeOptimized Quick}} {
  puts "ERROR: TG_PLACE_DIRECTIVE must be one of place_design's directives (fpga/kv260/README.md)"; exit 1
}
# TG_CHECKPOINT=1 (DR-187): post_opt.dcp after opt_design (with the place-and-route uncertainty set) and
# post_place.dcp after phys_opt_design, in the run directory, so another placement or a reroute starts from one
# of them instead of from synthesis. Off by default (each is several hundred MB).
set ckpt [expr {[info exists ::env(TG_CHECKPOINT)] ? $::env(TG_CHECKPOINT) : 0}]
if {$ckpt ni {0 1}} { puts "ERROR: TG_CHECKPOINT must be 0 or 1 (fpga/kv260/README.md)"; exit 1 }
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
# TG_FLOORPLAN (DR-181, the coordinator, 10-21): spikes §8.17's g4_uncore floorplan, pblocks for the two L2 banks (in the
# URAM column) and the crossbar (beside them): fpga/spikes/tcl/fp/g4_uncore.tcl with fpga/spikes/tcl/fp_lib.tcl's helpers
# and checks, spikes-2's files, sourced where they are kept. hp1f at 97.2% placed reached WNS -0.096 ns with it and
# -2.098 ns without (spikes §8.18). Unset puts it on the product's shape (kind core, two cores) and leaves it off
# elsewhere; 1 on, 0 off. summary.txt says which, with each pblock's share.
set fp_on [expr {[info exists ::env(TG_FLOORPLAN)] ? $::env(TG_FLOORPLAN) : (($kind eq "core" && $n_cores == 2) ? 1 : 0)}]
if {$fp_on ni {0 1}} { puts "ERROR: TG_FLOORPLAN must be 0 or 1 (fpga/kv260/README.md)"; exit 1 }
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
# TG_URF=1: the clocks' constraints (timing_urf.xdc), and the register file's own exceptions, the core's, scoped
# to every tg_urf instance: the paths its slot plan gives a full core cycle, which would otherwise be timed at a
# half cycle. So a URF build without that file stops here.
if {$urf} {
  read_xdc [file join $root fpga kv260 xdc timing_urf.xdc]
  set urf_xdc [file join $root rtl core regfile tg_urf.xdc]
  if {![file exists $urf_xdc]} {
    puts "ERROR: TG_URF=1 needs $urf_xdc, the UltraRAM register file's timing exceptions (the core's URF)"; exit 1
  }
  read_xdc -ref tg_urf $urf_xdc
}

# ---- synthesis ----
# TG_SYNTH_DIRECTIVE: synth_design's directive, AreaOptimized_high unless set (the coordinator, 10-16, DR-150:
# the two-core board build with the commit trace did not fit under Default, and spikes' full-chip fits and the
# area numbers already use AreaOptimized_high; at the board's clocks its timing cost is nil). Default gives the
# flow of the builds before 10-16 20:20. summary.txt records it.
set synth_dir [expr {[info exists ::env(TG_SYNTH_DIRECTIVE)] ? $::env(TG_SYNTH_DIRECTIVE) : "AreaOptimized_high"}]
stamp "synth_design ($synth_dir)"
synth_design -top kv260_top -part $part \
  -generic CORE_MHZ=$core_mhz -generic N_CORES=$n_cores -generic CORE_KIND=\"$kind\" -generic PMOD_UART=$pmod_uart \
  -generic FAN_WAVE=$fan_wave -generic FAN_INVERT=$fan_inv -generic FAN_PL=$fan_pl {*}$unc_gen {*}$def_args \
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
# DR-181's floorplan (TG_FLOORPLAN, above), after synthesis and before opt_design, as spikes-2's g4_fit applies it. The
# pblocks are soft, Vivado 2025.2's default (nothing here sets IS_SOFT): the placer keeps their cells near them but may
# place some outside, as it did hp1f's. A cell the floorplan names that the netlist lacks stops the build (tg_fp_cell):
# a floorplan that silently didn't apply would be worse. tg_fp_check logs FLOORPLAN_OK, _WARN (above 105%) or _TIGHT
# (above 115%) per pblock: its cells' LUTs against its LUT sites, an estimate that runs high. TIGHT means spikes-2
# resizes that pblock before the next product build.
if {$fp_on} {
  stamp "floorplan (g4_uncore, DR-181)"
  close [open floorplan.txt w]
  source [file join $root fpga spikes tcl fp_lib.tcl]
  source [file join $root fpga spikes tcl fp g4_uncore.tcl]
  tg_fp_check
  file copy -force floorplan.txt $rep/floorplan.txt
}
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
# With TG_URF=1, clk2x (c2x, CLKOUT2) takes the same uncertainty: the register file's half-cycle paths between
# the two clocks then get it whichever clock Vivado charges it to.
proc tg_clk2x_clock {} {
  foreach q {{get_clocks -quiet c2x}
             {get_clocks -quiet -of_objects [get_pins -quiet u_clkgen/u_mmcm/CLKOUT2]}
             {get_clocks -quiet -of_objects [get_nets -quiet clk2x]}} {
    set c [uplevel #0 $q]
    puts "TG_PR_UNC clock query {$q}: [expr {[llength $c] ? $c : {none}}]"
    if {[llength $c] == 1} { return $c }
  }
  return {}
}
stamp "opt_design ($opt_dir)"
opt_design -directive $opt_dir
tg_prim_check -file $rep/prim_check_opt.txt -fail 0
report_utilization -file $rep/opt_utilization.rpt   ;# spikes-2's measurement copy only (not soc-2's build.tcl)
set pr_unc_note ""
if {$pr_unc > 0} {
  set core_clk [tg_core_clock]
  if {![llength $core_clk]} { update_timing -quiet; set core_clk [tg_core_clock] }
  if {[llength $core_clk] && $urf} {
    set core_clk [concat $core_clk [tg_clk2x_clock]]
    if {[llength $core_clk] != 2} {
      puts "ERROR: TG_PR_UNC: TG_URF=1 but no clk2x clock found"
      exit 1
    }
    set pr_unc_note " and on clk2x (TG_URF=1)"
  }
  if {[llength $core_clk]} {
    set_clock_uncertainty -setup $pr_unc $core_clk
  } else {
    puts "WARNING: TG_PR_UNC: no core clock found; placing and routing without the uncertainty"
    set pr_unc_note " not applied: no core clock found"
    set pr_unc 0
  }
}
if {$ckpt} { stamp "write_checkpoint post_opt"; write_checkpoint -force ./post_opt.dcp }
stamp "place_design ($place_dir)"
place_design -directive $place_dir
report_utilization -file $rep/place_utilization.rpt   ;# spikes-2's measurement copy only
if {$fp_on} {
  # each pblock's own LUTs against its sites, and its cells placed outside: FLOORPLAN_OK, _WARN (above 85%) or _TIGHT
  # (above 90%) in the log, the reports in reports/util_pblocks.rpt
  tg_fp_check_placed
  file copy -force util_pblocks.rpt $rep/util_pblocks.rpt
}
stamp "phys_opt_design"
phys_opt_design
if {$ckpt} { stamp "write_checkpoint post_place"; write_checkpoint -force ./post_place.dcp }
stamp "route_design"
route_design
if {$pr_unc > 0} { set_clock_uncertainty -setup 0 $core_clk }   ;# the reports at the real period
write_checkpoint -force routed.dcp   ;# spikes-2's measurement copy only: for later queries
stamp "reports"
report_timing_summary -max_paths 20 -report_unconstrained -file $rep/timing_summary.rpt
report_utilization -file $rep/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $rep/utilization_hier.rpt
report_clock_utilization -file $rep/clock_utilization.rpt
report_drc -file $rep/drc.rpt
report_cdc -file $rep/cdc.rpt
source [file join $root fpga kv260 tcl prim_check.tcl]
tg_prim_check $rep/primitives.rpt

# Each pblock's share for summary.txt, graded as spikes-2's checks grade them: before opt_design (floorplan.txt: its
# cells' LUTs against its LUT sites; warn above 105%, tight above 115%) and after placement (its own LUTs, Parent and
# Child of report_utilization -pblocks, against its sites; warn above 85%, tight above 90%), and the worst grade
proc tg_kv_pblocks {} {
  set pre [dict create]
  set fh [open floorplan.txt r]
  foreach ln [split [read $fh] "\n"] {
    if {[regexp {^(\S+)\s+.*LUT cells\s+(\d+)\s*/\s*(\d+) LUT sites} $ln -> pb luts sites] && $sites} {
      dict set pre $pb [expr {100.0 * $luts / $sites}]
    }
  }
  close $fh
  set worst OK
  set parts {}
  foreach pb [lsort [get_property NAME [get_pblocks -quiet]]] {
    set post ""
    set r [report_utilization -pblocks [get_pblocks $pb] -return_string]
    if {[regexp {\|\s*CLB LUTs\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|} \
          $r -> parent child - - - - avail] && $avail} {
      set post [expr {100.0 * ($parent + $child) / $avail}]
    }
    set p0 [expr {[dict exists $pre $pb] ? [dict get $pre $pb] : ""}]
    foreach {v w t} [list $p0 105 115 $post 85 90] {
      if {$v eq ""} { continue }
      if {$v > $t} { set worst TIGHT } elseif {$v > $w && $worst ne "TIGHT"} { set worst WARN }
    }
    lappend parts "$pb [expr {$p0 eq {} ? {-} : [format %.0f%% $p0]}]/[expr {$post eq {} ? {-} : [format %.0f%% $post]}]"
  }
  return "[join $parts {, }] (before opt_design / its own LUTs after placement; warn above 105 / 85%, tight above 115 / 90%): $worst"
}

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
puts $fh "opt=$opt_dir (opt_design's directive, DR-166)"
puts $fh "place=$place_dir (place_design's directive, DR-187)"
if {$urf} { puts $fh "urf=1 (DR-174: the integer register file in UltraRAM, clk2x at [expr {2 * $core_mhz}] MHz)" }
puts $fh "uncore=[expr {$unc_set eq {} ? {-} : $unc_set}]"
if {[info exists ::env(TG_LAT_INJ)] && !$::env(TG_LAT_INJ)} {
  puts $fh "lat_inj=0 (release: no latency injectors, DR-177)"
} else {
  puts $fh "lat_inj=1 (development: the two latency injectors)"
}
if {$release} {
  puts $fh "release=1 (DR-180: the PLIC's S contexts alone, no host console, no DMA line counters or completions, trimmed crossings; no injectors, virtio window or trace)"
} else {
  puts $fh "release=0 (development: every block)"
}
puts $fh "pmod_uart=$pmod_uart txd=[get_property PACKAGE_PIN [get_ports pmod_uart_txd]] rxd=[get_property PACKAGE_PIN [get_ports pmod_uart_rxd]]"
puts $fh "fan=ttc$::tg_kv260_fan_ttc.wave$fan_wave invert=$fan_inv pl=$fan_pl pin=[get_property PACKAGE_PIN [get_ports fan_en_b]]"
if {$fp_on} {
  puts $fh "floorplan=g4_uncore (DR-181: soft pblocks for the L2 banks and the crossbar) [tg_kv_pblocks]"
} else {
  puts $fh "floorplan=none (TG_FLOORPLAN=0, or not the product's shape)"
}
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
