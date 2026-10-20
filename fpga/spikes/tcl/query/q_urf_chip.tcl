# The UltraRAM register file (DR-174, URF) in a routed full chip: spikes.md §8.14's tier B. Writes urf_chip.txt:
#   - WNS and WHS per clock pair: the core clock (c0), clk2x (CLKOUT2 of the core clock's MMCM), and between them;
#   - per core, the worst path of each of the register file's path classes (tg_urf's slot plan, WMODE "edge"):
#       select -> port B's address (the early reads, a full cycle by tg_urf.xdc),
#       late address -> port A's address (half a cycle), the write through tg_urf's ports (a full cycle),
#       port B's held data -> the RF stage (a full cycle), port A's mid-cycle data -> the RF stage (half a cycle),
#       the half-cycle flag -> the UltraRAMs, the early banks' register -> the bank select;
#     with the time left after a mid-cycle read's data reaches its first LUT;
#   - per core, tg_irf's LUTs, LUTRAM, flip-flops and UltraRAMs (the URF and the store-data and trace ports' LUTRAM),
#     and the chip's UltraRAMs.
# Every clock's setup uncertainty is taken back first (the over-constrained checkpoints carry theirs).
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_urf_chip.tcl <routed.dcp>   (about 5 GB)
set dcp [lindex $argv 0]
open_checkpoint $dcp
set c0  [get_clocks c0]
set c2x [get_clocks -quiet -of_objects [get_pins -quiet u_clkgen/u_mmcm/CLKOUT2]]
set_clock_uncertainty -setup 0 $c0
if {[llength $c2x]} { set_clock_uncertainty -setup 0 $c2x }
set fh [open urf_chip.txt w]
puts $fh "== $dcp"
proc ws {args} {
  set p [get_timing_paths -quiet -max_paths 1 -nworst 1 {*}$args]
  return [expr {[llength $p] ? [format %.3f [get_property SLACK $p]] : "-"}]
}
if {![llength $c2x]} { puts $fh "no clk2x (CLKOUT2): not a URF build"; close $fh; puts "Q_URF_CHIP_DONE"; exit 0 }
foreach {title from to} [list "c0 -> c0" $c0 $c0 "c0 -> clk2x" $c0 $c2x "clk2x -> clk2x" $c2x $c2x "clk2x -> c0" $c2x $c0] {
  puts $fh [format "  %-16s WNS %7s  WHS %7s" $title [ws -setup -from $from -to $to] [ws -hold -from $from -to $to]]
}
puts $fh "  clk2x: [get_property NAME $c2x], [get_property PERIOD $c2x] ns"

proc worst {title args} {
  set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
  if {![llength $p]} { puts $::fh "    $title: no path"; return "" }
  puts $::fh [format "    %-38s %7.3f  req %6.3f  data %6.3f ns (logic %.3f, net %.3f) %2d levels  %s -> %s" $title \
    [get_property SLACK $p] [get_property REQUIREMENT $p] [get_property DATAPATH_DELAY $p] [get_property DATAPATH_LOGIC_DELAY $p] \
    [get_property DATAPATH_NET_DELAY $p] [get_property LOGIC_LEVELS $p] \
    [get_property NAME [get_property STARTPOINT_PIN $p]] [get_property NAME [get_property ENDPOINT_PIN $p]]]
  return $p
}
# the time left after the UltraRAM's data reaches its first LUT: the capture's required time less that arrival
proc left_after_uram {p} {
  set r [report_timing -of_objects $p -return_string]
  set req ""; set arr ""; set seen 0
  foreach ln [split $r "\n"] {
    if {[string match "*(Prop_URAM*" $ln]} { set seen 1; continue }
    if {$seen == 1 && [regexp {^\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s} $ln -> i c]} { set seen 2; continue }
    if {$seen == 2 && [regexp {net \(fo=.*\)\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s} $ln -> i c]} { set arr $c; set seen 3 }
    if {[regexp {^\s+required time\s+(-?[0-9]+\.[0-9]+)} $ln -> rq]} { set req $rq }
  }
  if {$req eq "" || $arr eq ""} { return "?" }
  return [format %.3f [expr {$req - $arr}]]
}
set pre_list {}
foreach c {0 1} { lappend pre_list "u_soc/g_core\[$c\].g_tgc.u_core" }
set i 0
foreach pre $pre_list {
  puts $fh "== core $i"
  incr i
  # tg_irf's tg_urf instance (u_ex/u_irf/g_urf.u_urf in core-2's build)
  set urf   [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}/u_ex/u_irf/*u_urf && IS_PRIMITIVE == 0"]
  set un    [get_property NAME $urf]
  set urams [get_cells -quiet -hierarchical -filter "NAME =~ ${un}/* && PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*"]
  if {[llength $urf] != 1 || ![llength $urams]} { puts $fh "    no URF under ${pre}/u_ex/u_irf ([llength $urf] instances)"; continue }
  puts $fh "    $un"
  set addr_a [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ ADDR_A*}]
  set addr_b [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ ADDR_B*}]
  set dout_a [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ DOUT_A*}]
  set dout_b [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ DOUT_B*}]
  set wport  [get_pins -quiet -of_objects $urf -filter {REF_PIN_NAME =~ we* || REF_PIN_NAME =~ waddr* || REF_PIN_NAME =~ wdata*}]
  set flag   [get_cells -quiet -hierarchical -filter "NAME =~ ${un}/t?_q_reg*"]
  set ebank  [get_cells -quiet -hierarchical -filter "NAME =~ ${un}/e_bank_q_reg*"]
  puts $fh "    [llength $urams] UltraRAMs: [lsort [get_property LOC $urams]]"
  worst "select -> port B address (10 ns)"   -from $c0 -through $addr_b
  worst "late address -> port A (5 ns)"      -from $c0 -through $addr_a -to $urams
  if {[llength $wport]} { worst "write -> UltraRAMs (10 ns)" -through $wport -to $urams }
  worst "port B held -> RF stage (10 ns)"    -through $dout_b -to $c0
  set p [worst "port A mid-cycle -> RF stage (5 ns)" -through $dout_a -to $c0]
  if {$p ne ""} { puts $fh "      left after the mid-cycle data reaches its first LUT: [left_after_uram $p] ns" }
  if {[llength $flag]}  { worst "half-cycle flag -> UltraRAMs" -from $flag -to $urams }
  if {[llength $ebank]} { worst "early bank -> bank select" -from $ebank }
  set r [report_utilization -cells [get_cells -hierarchical -filter "NAME == ${pre}/u_ex/u_irf"] -return_string]
  set u {}
  foreach {k label} {luts {CLB LUTs} lutram {LUT as Memory} ffs {CLB Registers} urams {URAM}} {
    if {[regexp "\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9\]+)" $r -> n]} { lappend u "$k $n" }
  }
  puts $fh "    tg_irf (URF + the LUTRAM ports): [join $u {, }]"
  flush $fh
}
puts $fh "chip UltraRAMs: [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]"
close $fh
puts "Q_URF_CHIP_DONE"
