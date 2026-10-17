# Synthesis traps that no simulation here can see, checked in the run's own log after synth_design
# (the coordinator, 2026-10-17).
#
# A name used inside a generate block before its declaration becomes a new, undriven implicit net in
# Vivado: INFO Synth 8-11241 ("undeclared symbol ..., assumed default net type 'wire'"), then WARNING
# Synth 8-605 ("same-named implicit nets") and WARNING Synth 8-3848 ("Net ... does not have driver").
# Verilator resolves the name to the later declaration, so lint and every simulation pass while the
# hardware is wrong. From fn6 (0c4b011) to its fix (24ada50) that tied off rename's free-list pop in
# every synthesized core (spikes.md §8.6). Vivado reports 8-11241 as an INFO, so the ERROR and CRITICAL
# WARNING scans of the logs never saw it.
#
#   set mark [tg_synth_check_mark]   before synth_design: where this synthesis' messages start in the log
#   tg_synth_check ?mark?            after it: appends to synth_check.txt every Synth 8-11241, 8-605 and
#                                    8-3848 message about our sources, then the Synth 8-6901 forward
#                                    references ("used before its declaration": Vivado resolves those, so
#                                    they are listed, not failed), and errors out if there was any of the
#                                    first three
#
# Our sources are every file outside the run directory, where Vivado generates the IP's (the PS block's
# own 8-11241 and 8-3848 lines are there), and outside the Xilinx installation. A message without a file
# counts as ours. All four kinds come before "Finished RTL Elaboration" in the log.
# The log is vivado.log in the run directory, as tools/vivado_run.sh names it. If it cannot be read, or
# does not yet reach the end of RTL elaboration, the check warns and the wrapper's scan of the finished
# log (run_g4.sh, run_ooc.sh) fails the run instead.

proc tg_synth_check_mark {{log vivado.log}} {
  if {[file exists $log]} { return [file size $log] }
  return 0
}

proc tg_synth_check {{mark 0} {log vivado.log}} {
  set run [file normalize [pwd]]
  set xil [expr {[info exists ::env(XILINX_VIVADO)] ? [file normalize $::env(XILINX_VIVADO)] : "/nonexistent"}]
  set fo [open synth_check.txt a]
  set txt ""
  if {[file readable $log]} {
    set fh [open $log]
    seek $fh $mark
    set txt [read $fh]
    close $fh
  }
  if {[string first "Finished RTL Elaboration" $txt] < 0} {
    puts $fo "not checked: $log does not reach the end of RTL elaboration (the wrapper checks the finished log)"
    close $fo
    puts "WARNING: tg_synth_check: $log does not reach the end of RTL elaboration; the wrapper checks the finished log"
    return
  }
  set bad {}
  set fwd {}
  foreach line [split $txt "\n"] {
    if {![regexp {\[Synth 8-(11241|605|3848|6901)\]} $line -> id]} { continue }
    if {[regexp {\[([^][]+):[0-9]+\]\s*$} $line -> f]} {
      set f [file normalize $f]
      if {[string first "$run/" $f] == 0 || [string first "$xil/" $f] == 0} { continue }
    }
    if {$id eq "6901"} { lappend fwd $line } else { lappend bad $line }
  }
  set bad [lsort -unique $bad]
  set fwd [lsort -unique $fwd]
  puts $fo "implicit or undriven nets in our sources (Synth 8-11241, 8-605, 8-3848): [llength $bad]"
  foreach l $bad { puts $fo "  $l" }
  puts $fo "forward references in our sources (Synth 8-6901; Vivado resolves them): [llength $fwd]"
  foreach l $fwd { puts $fo "  $l" }
  close $fo
  if {[llength $bad]} {
    error "tg_synth_check: [llength $bad] implicit- or undriven-net message(s) in our sources, listed in synth_check.txt: declare each signal before its first use, and drive it"
  }
}
