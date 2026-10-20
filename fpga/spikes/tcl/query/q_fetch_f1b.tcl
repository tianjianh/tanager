# The full reports of F1's near paths after q_fetch_f1.tcl (the fetch timing study, 10-20), per core of a full chip:
# the worst path into TAGE's and the I$'s RAM enables (F2's hold chain), into fpc_q from the queue (u_cmp) and F3's
# registers, and into f2_pmpd_q. Every clock's setup uncertainty taken back. Writes fetch_f1b.rpt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_fetch_f1b.tcl <label=routed.dcp>...   (about 5 GB)
set fr [open fetch_f1b.rpt w]
foreach arg $argv {
  lassign [split $arg =] label dcp
  open_checkpoint $dcp
  foreach c [get_clocks] { set_clock_uncertainty -setup 0 $c }
  foreach pre [list "u_soc/g_core\[0\].g_tgc.u_core/" "u_soc/g_core\[1\].g_tgc.u_core/"] {
    set tg  [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_tage.u_tage/g_tab* && PRIMITIVE_GROUP == BLOCKRAM"]
    set ic  [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_way* && PRIMITIVE_GROUP == BLOCKRAM"]
    set fpc [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/fpc_q_reg* && IS_SEQUENTIAL"]
    set cmp [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/u_cmp/* && IS_SEQUENTIAL"]
    set f3  [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/f3_* && IS_SEQUENTIAL"]
    set pmd [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/f2_pmpd_q_reg* && IS_SEQUENTIAL"]
    foreach {what args} [list \
        "tage-en" [list -to [get_pins -quiet -of_objects $tg -filter {REF_PIN_NAME =~ EN*}]] \
        "icache-en" [list -to [get_pins -quiet -of_objects $ic -filter {REF_PIN_NAME =~ EN*}]] \
        "cmp-fpc" [list -from $cmp -to $fpc] \
        "f3-fpc" [list -from $f3 -to $fpc] \
        "pmpd" [list -to $pmd]] {
      set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
      puts $fr "######## $label $pre $what"
      if {[llength $p]} { puts $fr [report_timing -of_objects $p -return_string] }
    }
  }
  close_design
}
close $fr
puts "Q_FETCH_F1B_DONE"
