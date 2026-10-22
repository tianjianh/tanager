# Which input pins of a group of cells hold its near-critical endpoints (spikes §8.18, the DR-185 preview: is the payload
# LUTRAM's failure in its write address and enable, or its write data?). For the cells matching <glob> (NAME,
# -hierarchical, leaf cells), every setup path ending on one of their input pins with slack below <limit> ns, counted by
# the pin's class:
#   LUTRAM: ADDRH (the write address of RAM32M16/RAM64M8), ADDRA-G (read addresses), WE, DI (write data), WCLK;
#   others: the pin name with its index stripped.
# For each class: endpoints, endpoints failing, the worst slack, and the worst path's start, levels, logic and wire.
# Writes pin_classes.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_pin_classes.tcl <routed.dcp> <glob> [limit=1.0]   (about 5 GB)
lassign $argv dcp glob limit
if {$limit eq ""} { set limit 1.0 }
open_checkpoint $dcp
set fs [open pin_classes.txt w]
set cells [get_cells -quiet -hierarchical -filter "NAME =~ \"$glob\" && IS_PRIMITIVE"]
puts $fs "cells matching $glob: [llength $cells]"
set pins [get_pins -quiet -of_objects $cells -filter {DIRECTION == IN}]
puts $fs "their input pins: [llength $pins]"
set paths [get_timing_paths -quiet -setup -to $pins -max_paths 100000 -nworst 1 -slack_lesser_than $limit]
puts $fs "setup paths to them below $limit ns: [llength $paths]"
proc pclass {ref pin} {
  if {[string match RAM* $ref] && ![string match RAMB* $ref]} {
    if {[regexp {^ADDRH} $pin]} { return "LUTRAM write address (ADDRH)" }
    if {[regexp {^ADDR[A-G]} $pin]} { return "LUTRAM read address (ADDRA-G)" }
    if {[regexp {^WE} $pin]} { return "LUTRAM write enable (WE)" }
    if {[regexp {^DI} $pin]} { return "LUTRAM write data (DI)" }
    return "LUTRAM $pin"
  }
  return "$ref [regsub {\[?\d+\]?$} $pin {}]"
}
set cnt [dict create]
foreach p $paths {
  set ep [get_property ENDPOINT_PIN $p]
  set c [get_cells -of_objects $ep]
  set k [pclass [get_property REF_NAME $c] [get_property REF_PIN_NAME $ep]]
  set s [get_property SLACK $p]
  if {![dict exists $cnt $k]} { dict set cnt $k [list 0 0 99.0 {}] }
  lassign [dict get $cnt $k] n nf w wp
  incr n; if {$s < 0} { incr nf }
  if {$s < $w} { set w $s; set wp $p }
  dict set cnt $k [list $n $nf $w $wp]
}
puts $fs [format "%-34s %8s %8s %9s  %s" class endpoints failing worst "worst path: start (levels, logic / wire ns)"]
dict for {k v} $cnt {
  lassign $v n nf w wp
  set st [get_property NAME [get_property STARTPOINT_PIN $wp]]
  regsub {^u_soc/} $st {} st
  puts $fs [format "%-34s %8d %8d %9.3f  %s (%d levels, %.2f / %.2f)" $k $n $nf $w $st [get_property LOGIC_LEVELS $wp] \
    [get_property DATAPATH_LOGIC_DELAY $wp] [get_property DATAPATH_NET_DELAY $wp]]
}
close $fs
puts "Q_PIN_CLASSES_DONE"
