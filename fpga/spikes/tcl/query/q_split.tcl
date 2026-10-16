# Query on a G4 routed checkpoint: the worst path of the L2's split-bank family (rs_cur_q ->
# ms state) per bank, and the worst path into each bank's ms state from anywhere.
lassign $argv dcp
open_checkpoint $dcp
set fh [open q_split.txt w]
foreach b {0 1} {
  set bk "u_soc/u_uncore/u_l2/g_bank?${b}?.u_bank"
  set src [get_cells -quiet -hierarchical -filter "NAME =~ ${bk}/rs_cur_q_reg* && IS_SEQUENTIAL"]
  set dst [get_cells -quiet -hierarchical -filter "NAME =~ ${bk}/ms_reg* && IS_SEQUENTIAL"]
  puts $fh "bank $b: [llength $src] rs_cur_q cells, [llength $dst] ms cells"
  foreach {tag args} [list rs_to_ms [list -from $src -to $dst] any_to_ms [list -to $dst]] {
    set q [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup {*}$args]
    if {$q eq ""} { puts $fh "  $tag none"; continue }
    puts $fh [format "  %-10s %8.3f levels %2d logic %.3f net %.3f %s -> %s" $tag [get_property SLACK $q] \
      [get_property LOGIC_LEVELS $q] [get_property DATAPATH_LOGIC_DELAY $q] [get_property DATAPATH_NET_DELAY $q] \
      [get_property NAME [get_property STARTPOINT_PIN $q]] [get_property NAME [get_property ENDPOINT_PIN $q]]]
  }
}
close $fh
puts "Q_SPLIT_DONE"
