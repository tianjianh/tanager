# G4's reports on a routed checkpoint (g4_fit.tcl -dcp 1 keeps one): for a report that failed, or
# a new query on the same placement. Run it only through tools/vivado_run.sh (conventions §9):
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/g4_report.tcl <repo-root> <routed.dcp> \
#       <core_mhz> <uncore_dsp> [cfg]
# Writes what g4_fit.tcl writes after routing (fpga/spikes/tcl/g4_reports.tcl).
lassign $argv root dcp core_mhz uncore_dsp cfg
if {$cfg eq ""} { set cfg smt2 }
set mask [format %016llX $uncore_dsp]
set_param general.maxThreads 8
proc tg_kv {fh k v} { puts $fh [format "%-24s %s" $k $v] }
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
set t0 [clock seconds]
open_checkpoint $dcp
set fh [open summary.txt w]
tg_kv $fh checkpoint $dcp
tg_kv $fh cfg $cfg
tg_kv $fh core_mhz $core_mhz
tg_kv $fh uncore_dsp 0x$mask
tg_kv $fh pblocks [llength [get_pblocks -quiet]]
tg_util $fh impl
source [file join $root fpga spikes tcl g4_reports.tcl]
puts "G4_REPORT_DONE $dcp"
