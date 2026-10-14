# Out-of-context synthesis and implementation of one FPU unit (docs/spec/fpu.md, "Timing and area").
#   tools/vivado_run.sh <run-dir> tests/unit/fpu/vivado/ooc.tcl <repo-root> <cfg> <top> [period-ns]
#     [defines: A,B=1] [generics: STAGES=4,...]
# Writes utilisation and timing reports into the run directory; no checkpoints are kept.
# With TG_OOC_HIER=1 in the environment it only synthesises, keeping the module hierarchy, and
# reports utilisation per module (util_hier_synth.rpt): a breakdown, not a result.
# Inputs are constrained to arrive 1.5 ns after the clock (the core's operand bypass in front of
# the FPU); outputs leave from registers and must reach the core's writeback within 1.0 ns.
lassign $argv root cfg top period defines generics
if {$period eq ""} { set period 5.0 }
set part xck26-sfvc784-2LV-c
source [file join $root tools tcl tg_files.tcl]
set_part $part
tg_read_rtl $root $cfg
set hier [expr {[info exists ::env(TG_OOC_HIER)] && $::env(TG_OOC_HIER) eq "1"}]
set opts [list -top $top -part $part -mode out_of_context \
  -flatten_hierarchy [expr {$hier ? "none" : "rebuilt"}]]
set vdefs {}
foreach d [split $defines ","] { if {$d ne ""} { lappend vdefs $d } }
if {[llength $vdefs]} { lappend opts -verilog_define $vdefs }
set gens {}
foreach g [split $generics ","] { if {$g ne ""} { lappend gens $g } }
if {[llength $gens]} { lappend opts -generic $gens }
synth_design {*}$opts
create_clock -name clk -period $period [get_ports clk]
set ins [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay -clock clk 1.5 $ins
set_output_delay -clock clk 1.0 [get_ports -filter {DIRECTION == OUT}]
report_utilization -file util_synth.rpt
report_timing_summary -file timing_synth.rpt -max_paths 10
if {$hier} {
  report_utilization -hierarchical -file util_hier_synth.rpt
  set fh [open lut_cells.txt w]
  foreach c [get_cells -hier -filter {REF_NAME =~ LUT* || REF_NAME =~ CARRY*}] {
    puts $fh "[get_property REF_NAME $c] $c"
  }
  close $fh
  puts "OOC_RESULT top=$top breakdown only"
  return
}
opt_design
place_design
phys_opt_design
route_design
phys_opt_design
report_utilization -file util.rpt
report_utilization -hierarchical -file util_hier.rpt
report_timing_summary -file timing.rpt -max_paths 20
report_timing -max_paths 30 -nworst 1 -unique_pins -file paths.rpt
report_design_analysis -logic_level_distribution -file levels.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set lut [llength [get_cells -hier -filter {PRIMITIVE_GROUP == CLB && REF_NAME =~ LUT*}]]
puts "OOC_RESULT top=$top period=$period wns=$wns"
