# Tier A of spikes.md §8.14: urf_top (tg_urf, the double-pumped UltraRAM integer register file, and the
# RF stage around it) synthesized, placed and routed alone in the XCK26: the core clock at 100 MHz and the
# UltraRAMs' at 200 MHz, from one MMCM. Measurement only.
#   tools/vivado_run.sh <run-dir> <tree>/fpga/spikes/uram/urf_fit.tcl <tree> [-fp <floorplan.tcl>] [-generic K=V]...
# -fp: sourced after synthesis (URAM LOCs and pblocks that put each stand-in where its counterpart sits in
# a routed full chip). Constraints beyond the clocks, both from tg_urf's slot plan:
#   - slot 0's address: the select stand-in reaches the UltraRAM at the next core edge, a full core cycle
#     (at the mid-cycle edge between, the address multiplexer shows the late or the write address);
#   - early data the UltraRAM holds to the next core edge (port B through its write, NO_CHANGE; port A of
#     the copies without a late port, EN_A low at mid-cycle) is a full core cycle from the core edge.
# Writes summary.txt (worst slack per path class, the UltraRAM's clock-to-out with and without its output
# register, the time left after the late read's data reaches the bank select) and the reports.
set root [file normalize [lindex $argv 0]]
set fp ""; set gen {}; set edge 0
foreach {k v} [lrange $argv 1 end] { switch -- $k { -fp { set fp [file normalize $v] } -generic { lappend gen -generic $v }
  -edge { set edge $v } default { puts "ERROR: unknown option $k"; exit 1 } } }
# -edge 1: tg_urf's WMODE "edge" (the write at the core edge on port A; 3 early ports on port B, 3 late on A)
if {$edge} { lappend gen -generic NE=3 -generic NL=3 -generic {WMODE="edge"} }
set part xck26-sfvc784-2LV-c
set_param general.maxThreads 8
set t0 [clock seconds]
create_project -in_memory -part $part
read_verilog -sv [list $root/fpga/spikes/uram/tg_urf.sv $root/fpga/spikes/uram/urf_top.sv]
synth_design -top urf_top -part $part {*}$gen
set fh [open summary.txt w]
proc kv {k v} { puts $::fh [format "%-28s %s" $k $v]; flush $::fh }
kv synth_s [expr {[clock seconds] - $t0}]
kv floorplan [expr {$fp eq "" ? "none" : $fp}]
kv generics [expr {[llength $gen] ? $gen : "none"}]

create_clock -period 10.000 -name clk_in [get_ports clk_in]
set c0  [get_clocks -of_objects [get_pins u_mmcm/CLKOUT0]]
set c2x [get_clocks -of_objects [get_pins u_mmcm/CLKOUT2]]
kv clocks "[get_property NAME $c0] [get_property PERIOD $c0] ns, [get_property NAME $c2x] [get_property PERIOD $c2x] ns"
puts "URF_FIT top registers: [lsort -unique [lmap x [get_property NAME [get_cells -filter {IS_SEQUENTIAL}]] {regsub {_reg.*$} $x {}}]]"
set urams  [get_cells -hierarchical -filter {REF_NAME == URAM288_BASE && NAME =~ u_urf/*}]
if {$edge} {
  # every copy's port A reads a late port at mid-cycle; port B's early read holds to the next core edge
  set late_u $urams
  set held_u {}
} else {
  set late_u [get_cells -hierarchical -filter {REF_NAME == URAM288_BASE && NAME =~ u_urf/*g_copy?0?*}]
  set held_u [get_cells -hierarchical -filter {REF_NAME == URAM288_BASE && NAME =~ u_urf/* && NAME !~ *g_copy?0?*}]
}
set sel  [get_cells {sel_bank_q_reg* sel_idx_q_reg*}]
set held [concat [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ DOUT_B*}] \
                 [get_pins -quiet -of_objects $held_u -filter {REF_PIN_NAME =~ DOUT_A*}]]
set wrq  [get_cells {wr_we_q_reg* wr_a_q_reg* wr_d_q_reg*}]
if {![llength $sel] || ![llength $urams] || ![llength $late_u] || (!$edge && ![llength $held_u])} { puts "ERROR: URF_FIT cells not found: sel [llength $sel] urams [llength $urams] late [llength $late_u] held [llength $held_u]"; exit 1 }
set_multicycle_path -setup 2 -end -from $sel -to $urams
set_multicycle_path -hold  1 -end -from $sel -to $urams
set_multicycle_path -setup 2 -start -through $held -to $c0
set_multicycle_path -hold  1 -start -through $held -to $c0
# WMODE "edge": the write lands at the next core edge, a full core cycle (at the mid-cycle edge between,
# port A's multiplexer shows the late read)
if {$edge} {
  set_multicycle_path -setup 2 -end -from $wrq -to $urams
  set_multicycle_path -hold  1 -end -from $wrq -to $urams
}
if {$fp ne ""} { source $fp }

opt_design
place_design
phys_opt_design
route_design
kv impl_s [expr {[clock seconds] - $t0}]
write_checkpoint -force routed.dcp
report_timing_summary -max_paths 20 -file timing_summary.rpt
report_utilization -file util.rpt
report_utilization -hierarchical -file util_hier.rpt
report_pulse_width -file pulse_width.rpt

# ---- per path class ----
set ex   [get_cells ex_q_reg*]
set sdq  [get_cells sd_q_reg*]
set cap  [get_cells -hierarchical -filter {NAME =~ u_urf/*g_cap.cap_q_reg*}]
set lpin [get_pins -of_objects $late_u -filter {REF_PIN_NAME =~ DOUT_A*}]
set wtitle [expr {$edge ? "write port -> URAM (core edge, 10 ns)" : "write port -> URAM (slot 1, 5 ns)"}]
set ltitle [expr {$edge ? "late read -> RF stage (5 ns)" : "late read -> store-data capture (5 ns)"}]
set lto    [expr {$edge ? $ex : $sdq}]
set classes [list \
  "select -> URAM address (slot 0, 10 ns)"   [list -from $sel -to $urams] \
  "late address -> URAM (slot 1, 5 ns)"      [list -from [get_cells {late_*_q_reg*}] -to $urams] \
  $wtitle                                  [list -from $wrq -to $urams] \
  "half-cycle flag -> URAM"                  [list -from [get_cells u_urf/t?_q_reg] -to $urams] \
  "port A early -> mid-cycle capture"        [expr {[llength $cap] ? [list -from $late_u -to $cap] : {}}] \
  "captured early -> RF stage (5 ns)"        [expr {[llength $cap] ? [list -from $cap -to $ex] : {}}] \
  "held early (A, B) -> RF stage (10 ns)"    [list -through $held -to $ex] \
  $ltitle                                  [list -from $late_u -through $lpin -to $lto] \
  "bank select -> RF stage"                  [list -from [get_cells u_urf/e_bank_q_reg*] -to $ex] \
  "probe: OREG -> capture"                   [list -from [get_cells -quiet -hierarchical -filter {REF_NAME == URAM288_BASE && NAME =~ *u_probe}] -to [get_cells -quiet -hierarchical -filter {NAME =~ *prb_q_reg*}]] \
]
set rf [open paths.rpt w]
foreach {title args} $classes {
  if {![llength $args]} { kv "-" "$title: none in this mode"; continue }
  set ps [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
  set ph [get_timing_paths -quiet -hold  -max_paths 1 -nworst 1 {*}$args]
  if {![llength $ps]} { kv "-" "$title: no path"; continue }
  kv [format "%.3f" [get_property SLACK $ps]] [format "%s  (hold %s; data %.3f ns, logic %.3f, net %.3f, %d levels, req %.3f)  %s -> %s" \
    $title [expr {[llength $ph] ? [format %.3f [get_property SLACK $ph]] : "-"}] [get_property DATAPATH_DELAY $ps] \
    [get_property DATAPATH_LOGIC_DELAY $ps] [get_property DATAPATH_NET_DELAY $ps] [get_property LOGIC_LEVELS $ps] \
    [get_property REQUIREMENT $ps] [get_property NAME [get_property STARTPOINT_PIN $ps]] [get_property NAME [get_property ENDPOINT_PIN $ps]]]
  puts $rf "######## $title"
  puts $rf [report_timing -of_objects $ps -return_string]
}
close $rf

# ---- the UltraRAM's clock-to-out, and the time after the late data reaches the bank select ----
proc cells_of_path {p} {
  # the report's data-path lines: {incr cum pin}
  set out {}
  foreach ln [split [report_timing -of_objects $p -return_string] "\n"] {
    if {[regexp {\s(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+[rf]?\s*(\S+)\s*$} $ln -> incr cum pin]} { lappend out [list $incr $cum $pin $ln] }
  }
  return $out
}
foreach {title from thr to} [list \
    "no output register" $late_u $lpin $sdq \
    "output register"    [get_cells -quiet -hierarchical -filter {REF_NAME == URAM288_BASE && NAME =~ *u_probe}] {} [get_cells -quiet -hierarchical -filter {NAME =~ *prb_q_reg*}]] {
  if {![llength $from]} { continue }
  set args [list -from $from -to $to]
  if {[llength $thr]} { lappend args -through $thr }
  set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
  if {![llength $p]} { continue }
  set tco ""; set after ""
  set lines [cells_of_path $p]
  for {set i 0} {$i < [llength $lines]} {incr i} {
    lassign [lindex $lines $i] incr cum pin ln
    if {$tco eq "" && [string match "*(Prop_URAM*" $ln]} {
      set tco $incr
      # the next line is the route to the first cell after the UltraRAM: its arrival
      lassign [lindex $lines [expr {$i + 1}]] i2 c2 p2
      set after [list $c2 $p2]
    }
  }
  set req [get_property REQUIREMENT $p]
  kv "uram_tco ($title)" "$tco ns"
  if {$title eq "no output register" && [llength $after]} {
    # the data's arrival at the bank select, against the capture's required time
    set r [report_timing -of_objects $p -return_string]
    regexp {\srequired time\s+(-?[0-9]+\.[0-9]+)} $r -> rq
    kv "late: at the bank select" [format "%.3f ns (%s); required %.3f; left %.3f ns for the select and the route to the capture" \
      [lindex $after 0] [lindex $after 1] $rq [expr {$rq - [lindex $after 0]}]]
  }
}
set cu [get_cells u_urf]
set r [report_utilization -cells $cu -return_string]
foreach {k label} {luts {CLB LUTs} ffs {CLB Registers} urams {URAM}} {
  if {[regexp "\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9\]+)" $r -> n]} { kv "u_urf $k" $n }
}
kv wns_c0  [get_property SLACK [get_timing_paths -max_paths 1 -setup -to $c0]]
kv wns_c2x [get_property SLACK [get_timing_paths -max_paths 1 -setup -to $c2x]]
kv whs     [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
close $fh
puts "URF_FIT_DONE"
