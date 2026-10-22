# A routed full chip's congestion and its worst paths' units (spikes §8.18's hp1, the coordinator 10-21), with every
# clock's setup uncertainty taken back (routed.dcp keeps the over-constraint). Writes:
#   congestion.rpt   report_design_analysis -congestion (placed and routed congestion levels per direction)
#                    and -complexity, report_route_status
#   worst_paths.txt  per clock group (c0, clk2x and their crossings): WNS and WHS, and the 30 worst setup paths' start
#                    and end cells with levels, logic and wire
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_congestion.tcl <routed.dcp>          (about 6 GB)
open_checkpoint [lindex $argv 0]
foreach c [get_clocks] { set_clock_uncertainty -setup 0 $c }
set fr [open congestion.rpt w]
foreach cmd {{report_design_analysis -congestion -return_string} {report_design_analysis -complexity -return_string}
             {report_route_status -return_string}} {
  puts $fr "######## $cmd"
  if {[catch {puts $fr [eval $cmd]} e]} { puts $fr "failed: $e" }
}
close $fr
set fs [open worst_paths.txt w]
foreach c [get_clocks] {
  set n [get_property NAME $c]
  set ps [get_timing_paths -quiet -setup -to $c -max_paths 1 -nworst 1]
  set ph [get_timing_paths -quiet -hold -to $c -max_paths 1 -nworst 1]
  if {![llength $ps]} { continue }
  puts $fs [format "== clock %s: WNS %.3f, WHS %s" $n [get_property SLACK $ps] \
    [expr {[llength $ph] ? [format %.3f [get_property SLACK $ph]] : "-"}]]
}
puts $fs ""
puts $fs [format "%7s %3s %6s %6s  %-60s  %s" slack lvl logic wire start end]
foreach p [get_timing_paths -quiet -setup -max_paths 30 -nworst 1 -unique_pins] {
  set s [regsub {^u_soc/} [get_property NAME [get_property STARTPOINT_PIN $p]] {}]
  set e [regsub {^u_soc/} [get_property NAME [get_property ENDPOINT_PIN $p]] {}]
  puts $fs [format "%7.3f %3d %6.2f %6.2f  %-60s  %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] $s $e]
}
close $fs
puts "Q_CONGESTION_DONE"
