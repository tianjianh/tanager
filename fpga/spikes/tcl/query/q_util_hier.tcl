# Per-unit LUTs of full-chip checkpoints, for comparing builds unit by unit (spikes §8.18: real hart 1 against
# §8.17's filler). For each <label>=<dcp>: report_utilization -hierarchical to depth 5, written as
# util_<label>.rpt. Compare two with fpga/spikes/scripts/util_diff.py. Synthesis checkpoints with
# -flatten_hierarchy none keep every module's own LUTs apart.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_util_hier.tcl <label=dcp>...      (about 5 GB)
foreach arg $argv {
  lassign [split $arg =] label dcp
  open_checkpoint $dcp
  report_utilization -hierarchical -hierarchical_depth 5 -hierarchical_min_primitive_count 0 -file util_$label.rpt
  close_design
}
puts "Q_UTIL_HIER_DONE"
