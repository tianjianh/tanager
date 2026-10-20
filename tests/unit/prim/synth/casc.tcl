# Synthesis check of tg_ram_tdp's CASCADE_HEIGHT (spikes §7.1). Synthesizes tg_prim_casc_top out of context with the
# chips' settings (-flatten_hierarchy none, AreaOptimized_high), then places and routes it at 10 ns. Writes casc.txt:
#   per instance: its block RAMs, each with its cascade order and read width per port
#   per port: its read delay, the slowest of its 36 bits' RAM delays (each bit's path from the instance's RAMs to
#     the port's read register; its logic is the RAMs' own delay, placement-independent), with that bit's RAM
#     arcs, and the worst path's slack and wire
#   the primitive check's lines for both instances (tools/tcl/tg_prim_check.tcl, after opt_design)
#   a verdict, CASC_PASS or CASC_FAIL: u_c0 (the default) is a depth cascade of two RAMB36, u_c1 (CASCADE_HEIGHT 1)
#     two RAMB36 side by side, and each of u_c1's ports reads at least 0.3 ns faster than u_c0's (measured 0.40 on
#     2025.2: the slowest bit through the cascade, CLK -> CASDOUT plus CASDIN -> DOUT, 1.79-1.81 ns, against 1.39-1.40
#     at 2K x 18)
#   tools/vivado_run.sh <run-dir> tests/unit/prim/synth/casc.tcl <repo-root>      (tests/unit/prim/synth/casc.sh)
set root [lindex $argv 0]
set part xck26-sfvc784-2LV-c
set_param general.maxThreads 2
source [file join $root tools tcl tg_prim_check.tcl]
read_verilog -sv [file join $root rtl common prim tg_ram_tdp.sv] \
  [file join $root tests unit prim synth tg_prim_casc_top.sv]
synth_design -top tg_prim_casc_top -part $part -mode out_of_context -flatten_hierarchy none \
  -directive AreaOptimized_high
create_clock -name clk -period 10.0 [get_ports clk]
opt_design
tg_prim_check -file prim_casc.txt -fail 0
place_design
route_design

# the RAM arcs on a path, from its report: "<arc> <delay>"
proc ram_arcs {p} {
  set out {}
  set lines [split [report_timing -of_objects $p -return_string] "\n"]
  for {set i 0} {$i < [llength $lines]} {incr i} {
    if {[regexp {RAMB36E2 \((Prop_RAMB36E2_RAMB36_[A-Z]+(?:\[\d+\])?_[A-Z]+)} [lindex $lines $i] -> arc] &&
        [regexp {^\s+([0-9.]+)\s} [lindex $lines [expr {$i + 1}]] -> d]} {
      lappend out "$arc $d"
    }
  }
  return $out
}

set fs [open casc.txt w]
puts $fs "== tg_prim_casc_top: two 2K x 36 tg_ram_tdp, routed at 10 ns"
set bad {}
set lg [dict create]
foreach {tag inst h} {u_c0 g_c[0].u_c 0 u_c1 g_c[1].u_c 1} {
  set rams [lsort [get_cells -quiet -hierarchical -filter "NAME =~ ${inst}/* && PRIMITIVE_GROUP == BLOCKRAM"]]
  set casc 0
  set desc {}
  foreach r $rams {
    set oa [get_property -quiet CASCADE_ORDER_A $r]; set ob [get_property -quiet CASCADE_ORDER_B $r]
    if {$oa ne "NONE" || $ob ne "NONE"} { incr casc }
    lappend desc [format "%s {A %s, %s bits; B %s, %s bits}" [lindex [split $r /] end] $oa \
      [get_property -quiet READ_WIDTH_A $r] $ob [get_property -quiet READ_WIDTH_B $r]]
  }
  puts $fs "$tag $inst (CASCADE_HEIGHT $h): [llength $rams] [lsort -unique [get_property REF_NAME $rams]]"
  foreach d $desc { puts $fs "    $d" }
  if {[llength $rams] != 2} { lappend bad "$tag has [llength $rams] block RAMs, not 2" }
  if {$h == 0 && $casc == 0} { lappend bad "$tag (the default) builds no depth cascade" }
  if {$h == 1 && $casc != 0} { lappend bad "$tag (CASCADE_HEIGHT 1) still cascades" }
  set i [string index $tag end]
  foreach port {a b} {
    set regs [get_cells -quiet -hierarchical -filter "NAME =~ out_${port}${i}_reg* && IS_SEQUENTIAL"]
    set ps [get_timing_paths -quiet -setup -from $rams -to $regs -max_paths 100 -nworst 1 -unique_pins]
    if {[llength $ps] != 36} { lappend bad "$tag port $port: [llength $ps] paths to its register, not 36"; continue }
    set slow [lindex $ps 0]
    foreach q $ps {
      if {[get_property DATAPATH_LOGIC_DELAY $q] > [get_property DATAPATH_LOGIC_DELAY $slow]} { set slow $q }
    }
    set w [lindex $ps 0]
    set l [get_property DATAPATH_LOGIC_DELAY $slow]
    dict set lg $tag$port $l
    puts $fs [format "  port %s: read delay %.3f ns (the slowest bit: %s); worst path slack %.3f, wire %.3f" $port $l \
      [join [ram_arcs $slow] {, }] [get_property SLACK $w] [get_property DATAPATH_NET_DELAY $w]]
  }
}
foreach port {a b} {
  if {[dict exists $lg u_c0$port] && [dict exists $lg u_c1$port]} {
    set dl [expr {[dict get $lg u_c0$port] - [dict get $lg u_c1$port]}]
    puts $fs [format "port %s: CASCADE_HEIGHT 1 reads %.3f ns faster" $port $dl]
    if {$dl < 0.3} { lappend bad [format "port %s reads only %.3f ns faster" $port $dl] }
  }
}
set pf [open prim_casc.txt r]
foreach ln [split [read $pf] "\n"] {
  if {[string match "PRIM_*" $ln]} { puts $fs $ln }
  if {[regexp {^PRIM_(FAIL|WARN)} $ln]} { lappend bad "the primitive check: $ln" }
}
close $pf
puts $fs [expr {[llength $bad] ? "CASC_FAIL: [join $bad {; }]" : "CASC_PASS"}]
close $fs
puts "PRIM_CASC_DONE"
