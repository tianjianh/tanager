# Out-of-context synthesis of one RTL module, for area and timing studies (SoC track).
#   tools/vivado_run.sh <run-dir> fpga/kv260/tcl/ooc_synth.tcl <repo-root> <cfg> <top> <mhz> [GEN=VAL ...]
# Writes reports/ooc_utilization.rpt (hierarchical, not flattened), reports/ooc_timing.rpt and,
# with TG_OOC_CONES=1, reports/ooc_cones.txt.
set root [lindex $argv 0]
set cfg  [lindex $argv 1]
set top  [lindex $argv 2]
set mhz  [lindex $argv 3]
set gens [lrange $argv 4 end]
set part xck26-sfvc784-2LV-c
file mkdir reports
source [file join $root tools tcl tg_files.tcl]
tg_read_rtl $root $cfg
set_param general.maxThreads 8
set gargs {}
foreach g $gens { lappend gargs -generic $g }
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none {*}$gargs
create_clock -name clk -period [expr {1000.0 / $mhz}] [get_ports clk]
report_utilization -hierarchical -hierarchical_depth 3 -file reports/ooc_utilization.rpt
report_utilization -file reports/ooc_utilization_flat.rpt
report_timing_summary -max_paths 5 -file reports/ooc_timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fh [open reports/ooc_utilization_flat.rpt]
set txt [read $fh]
close $fh
set luts ?; set lutram ?; set ffs ?
regexp {\|\s*CLB LUTs\*?\s*\|\s*(\d+)} $txt -> luts
regexp {\|\s*LUT as Memory\s*\|\s*(\d+)} $txt -> lutram
regexp {\|\s*CLB Registers\s*\|\s*(\d+)} $txt -> ffs
puts "TG_OOC $top $gens LUT=$luts LUTRAM=$lutram FF=$ffs WNS=$wns"

# Optional (TG_OOC_CONES=1): LUTs in the input cone of each register group of the top module, for
# attributing logic that synthesis flattens into one module. A register group is one RTL variable
# (the cell name without _reg and indices); module-instance inputs count as groups named after
# the pin. "own" counts the LUTs that feed only that group; "cone" counts all of them.
if {[info exists ::env(TG_OOC_CONES)] && $::env(TG_OOC_CONES)} {
  set groups [dict create]
  foreach c [get_cells -filter {IS_SEQUENTIAL && REF_NAME =~ FD*}] {
    set g [regsub {_reg([\[_].*)?$} [get_property NAME $c] {}]
    dict lappend groups $g $c
  }
  foreach inst [get_cells -filter {!IS_PRIMITIVE}] {
    foreach p [get_pins -of $inst -filter {DIRECTION == IN}] {
      set g "[get_property NAME $inst]/[regsub {\[.*\]$} [get_property REF_PIN_NAME $p] {}]"
      dict lappend groups "pin:$g" $p
    }
  }
  foreach p [get_ports -filter {DIRECTION == OUT}] {
    dict lappend groups "out:[regsub {\[.*\]$} [get_property NAME $p] {}]" $p
  }
  set owner [dict create]
  set cone  [dict create]
  dict for {g objs} $groups {
    set pins {}
    foreach o $objs {
      if {[get_property CLASS $o] eq "cell"} {
        lappend pins {*}[get_pins -of $o -filter {DIRECTION == IN && REF_PIN_NAME != C}]
      } else {
        lappend pins $o
      }
    }
    set luts [get_cells -quiet [all_fanin -quiet -flat -only_cells $pins] -filter {REF_NAME =~ LUT*}]
    dict set cone $g [llength $luts]
    foreach l $luts { dict lappend owner [get_property NAME $l] $g }
  }
  set own [dict create]
  dict for {l gs} $owner {
    set gs [lsort -unique $gs]
    if {[llength $gs] == 1} { dict incr own [lindex $gs 0] }
  }
  set rows {}
  dict for {g n} $cone {
    set o 0
    if {[dict exists $own $g]} { set o [dict get $own $g] }
    lappend rows [list $g $n $o [llength [dict get $groups $g]]]
  }
  set fh [open reports/ooc_cones.txt w]
  puts $fh [format "%-40s %7s %7s %6s" group cone own bits]
  foreach r [lsort -integer -decreasing -index 1 $rows] {
    puts $fh [format "%-40s %7d %7d %6d" {*}$r]
  }
  puts $fh "LUTs feeding one group: [llength [dict keys $own]] groups; shared LUTs: [expr {[dict size $owner] - [tcl::mathop::+ 0 {*}[dict values $own]]}]"
  close $fh
}
