# Does opt_design's directive change the depth of fetch's paths? (the fetch timing study, 10-20: the chips, with
# ExploreArea (DR-166), map F2's cone in 19 levels; the out-of-context runs, with Default, in 15-16.) For each directive
# in turn, opens a post-synthesis checkpoint, runs opt_design, and reports per core the worst path's levels and
# estimated slack (no placement: the levels are what count) for F2's cone by endpoint family, the fpc loop and the
# queue head, plus the design's LUT count. Writes opt_levels.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_opt_levels.tcl <post_synth.dcp> <directive>...
proc lv {args} {
  set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
  if {![llength $p]} { return "none" }
  return [format "%2d levels (est. %.3f)" [get_property LOGIC_LEVELS $p] [get_property SLACK $p]]
}
set dcp [lindex $argv 0]
set fs [open opt_levels.txt w]
foreach dir [lrange $argv 1 end] {
  open_checkpoint $dcp
  set t0 [clock seconds]
  if {$dir eq "none"} { } elseif {$dir eq "Default"} { opt_design } else { opt_design -directive $dir }
  foreach c [get_clocks] { set_clock_uncertainty -setup 0 $c }
  set luts [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT*}]]
  puts $fs "== opt_design $dir ([expr {[clock seconds] - $t0}] s): $luts LUT cells"
  foreach pre [list "u_soc/g_core\[0\].g_tgc.u_core/" "u_soc/g_core\[1\].g_tgc.u_core/"] {
    set rams [concat \
      [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_way* && PRIMITIVE_GROUP == BLOCKRAM"] \
      [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_tage.u_tage/g_tab* && PRIMITIVE_GROUP == BLOCKRAM"]]
    set fpc  [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/fpc_q_reg* && IS_SEQUENTIAL"]
    set head [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/u_cmp/head_q_reg* && IS_SEQUENTIAL"]
    set rnq  [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_rn/rn_uop_q_reg* && IS_SEQUENTIAL"]
    puts $fs "  -- core $pre"
    foreach {what pat} {target u_fetch/f3_meta_q_reg?target* krt u_fetch/krt_q_reg* hit u_fetch/f3_meta_q_reg?hit* \
                        p_pop g_ras.u_ras/g_late.p_pop_q_reg* gp_n u_fetch/g_tage.gp_n_q_reg* kimm u_fetch/kimm_q_reg*} {
      set e [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}${pat} && IS_SEQUENTIAL"]
      puts $fs [format "    F2 -> %-7s %s" $what [lv -from $rams -to $e]]
    }
    puts $fs [format "    F2 -> %-7s %s" u_fgh [lv -from $rams -to [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_tage.u_fgh/* && REF_NAME =~ RAMD*"]]]
    puts $fs "    fpc loop       [lv -from $fpc -to $fpc]"
    puts $fs "    head -> rename [lv -from $head -to $rnq]"
  }
  flush $fs
  close_design
}
close $fs
puts "Q_OPT_LEVELS_DONE"
