# Vivado's own reading of the RTL for lint-all (DR-150; docs/spec/verification.md §4.3): its simulator's
# parser (xvlog) and its RTL elaboration (synth_design -rtl) of the board top and the core. Verilator
# resolves a name used before its declaration to the later declaration; for a whole name in a port
# connection Vivado makes a new implicit net instead, undriven: the board's two-core hang of 2026-10-16
# (rn_fire in tg_rename's generate blocks). Only Vivado sees that, so this runs it, and
# tools/ci/vivado_rtl_lint.sh reads the messages. Run through tools/vivado_run.sh:
#   vivado_run.sh <run-dir> tools/ci/vivado_rtl_lint.tcl <repo-root> <top>:<cfg>[:<cores>] ...
# <top> is kv260_top (with the PS block design, as fpga/kv260/tcl/build.tcl makes it) or tg_core.
set root [file normalize [lindex $argv 0]]
set part xck26-sfvc784-2LV-c
source [file join $root tools tcl tg_files.tcl]
source [file join $root fpga kv260 tcl ps_bd.tcl]
# The block design routes the fan's PWM (DR-129); build.tcl sources these facts first, and so does this
if {[file exists [file join $root tools tcl tg_kv260_fan.tcl]]} { source [file join $root tools tcl tg_kv260_fan.tcl] }
# First the simulator's parser (xvlog), which is stricter than synthesis: a name used before its
# declaration in an expression is an error there (VRFC 10-3380), where synthesis and Verilator may
# take the later declaration. One parse per configuration package, of the RTL and the board top's own
# files (the PS wrapper is generated, so it is left out), SYNTHESIS defined as in synthesis.
# xvlog stops at the first file with an error and keeps nothing from that run, packages included. So
# the packages go first, in a run of their own, and then the other files; after a file with an error
# it starts again after that file. One run gives every file's first error (no macro crosses files).
# The logs go to xvlog.log in the current directory.
proc tg_xvlog {root files} {
  set pkgs {}
  set mods {}
  foreach f $files {
    set fh [open $f r]
    set src [read $fh]
    close $fh
    if {[regexp -line {^\s*package\s+(?:\w+\s+)?\w+\s*;} $src]} { lappend pkgs $f } else { lappend mods $f }
  }
  set all ""
  set rc 0
  set n 0
  foreach phase {pkgs mods} {
    set rest [set $phase]
    while {[llength $rest]} {
      incr n
      set failed [catch {exec xvlog -sv -d SYNTHESIS -log xvlog_$n.log -i [file join $root rtl common] {*}$rest 2>@1} out]
      if {![file exists xvlog_$n.log]} {
        append all "ERROR: xvlog did not run: $out\n"
        set rc 1
        break
      }
      set fh [open xvlog_$n.log r]
      set log [read $fh]
      close $fh
      append all $log
      if {!$failed} break
      set rc 1
      # A package with an error: the other files would only repeat it
      if {$phase eq "pkgs"} break
      # The file of the last error (a module's "ignored due to previous errors" names the module's file)
      set last ""
      foreach {- f} [regexp -all -inline -line {^ERROR: .*\[(.+):\d+\]$} $log] { set last $f }
      set i [lsearch -exact $rest $last]
      if {$i < 0} break
      set rest [lrange $rest [expr {$i + 1}] end]
    }
    if {$rc && $phase eq "pkgs"} break
  }
  set fh [open xvlog.log w]
  puts -nonewline $fh $all
  close $fh
  return $rc
}
set done_cfgs {}
foreach spec [lrange $argv 1 end] {
  set cfg [lindex [split $spec :] 1]
  if {$cfg in $done_cfgs} continue
  lappend done_cfgs $cfg
  set files [list [file join $root rtl common cfg tg_cfg_${cfg}.sv]]
  foreach f [tg_f_files [file join $root rtl rtl.f]] { lappend files $f }
  foreach f [tg_f_files [file join $root fpga kv260 kv260.f]] { lappend files $f }
  file mkdir xvlog_$cfg
  set here [pwd]
  cd xvlog_$cfg
  set rc [tg_xvlog $root $files]
  cd $here
  puts "TG_RTL_LINT xvlog $cfg [expr {$rc ? "errors" : "clean"}]"
}
foreach spec [lrange $argv 1 end] {
  lassign [split $spec :] top cfg cores
  if {$cores eq ""} { set cores 1 }
  create_project -in_memory -part $part
  set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
  set_param general.maxThreads 4
  set gen {}
  if {$top eq "kv260_top"} {
    tg_make_ps_bd [file normalize ./bd_${cfg}_${cores}] 100
    read_verilog $::tg_ps_wrapper
  }
  tg_read_rtl $root $cfg
  if {$top eq "kv260_top"} {
    tg_read_f [file join $root fpga kv260 kv260.f]
    set gen [list -generic N_CORES=$cores -generic CORE_KIND=\"core\"]
  }
  puts "TG_RTL_LINT begin $top $cfg $cores"
  if {[catch {synth_design -rtl -top $top -part $part {*}$gen} err]} {
    puts "TG_RTL_LINT error $top $cfg $cores: $err"
  }
  puts "TG_RTL_LINT end $top $cfg $cores"
  close_project
}
