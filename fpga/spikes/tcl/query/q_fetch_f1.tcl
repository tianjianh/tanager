# F1's paths for the fetch timing study (the coordinator, 10-20: M7's step 5b adds the thread select to F1), per
# checkpoint and core, with every clock's setup uncertainty taken back: the worst path into fpc_q from anywhere and from
# fpc_q itself through each of F1's lookups (the ITLB's hit, its PTE's ph bit and PPN, the micro-BTB, the PMP checker,
# the queue's blk_ready), and the worst paths into the I$ data RAMs' and TAGE's table RAMs' address pins, the tag
# LUTRAMs' read addresses, and F2's registers loaded from F1. Writes fetch_f1.txt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/query/q_fetch_f1.tcl <label=routed.dcp>...   (about 5 GB)
proc worst {args} {
  set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 {*}$args]
  if {![llength $p]} { return "none" }
  set s [get_property NAME [get_property STARTPOINT_PIN $p]]
  set s [regsub {^u_soc/g_core\[\d\]\.g_tgc\.u_core/} $s {}]
  return [format "%.3f (%d levels, logic %.2f net %.2f) from %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] \
    [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] $s]
}
proc hpins {cell filt} {
  return [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "NAME == $cell"] -filter $filt]
}
set fs [open fetch_f1.txt w]
foreach arg $argv {
  lassign [split $arg =] label dcp
  open_checkpoint $dcp
  foreach c [get_clocks] { set_clock_uncertainty -setup 0 $c }
  puts $fs "== $label: $dcp"
  if {[llength [get_cells -quiet u_fetch]]} { set pres [list ""] } else {
    set pres [list "u_soc/g_core\[0\].g_tgc.u_core/" "u_soc/g_core\[1\].g_tgc.u_core/"]
  }
  foreach pre $pres {
    puts $fs "  -- core [expr {$pre eq {} ? {(out of context)} : $pre}]"
    set fpc [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/fpc_q_reg* && IS_SEQUENTIAL"]
    puts $fs "    into fpc_q from anywhere:        [worst -to $fpc]"
    puts $fs "    fpc_q -> fpc_q:                  [worst -from $fpc -to $fpc]"
    foreach {what cell filt} [list \
        "the ITLB's hit"         ${pre}u_fetch/u_itlb  {DIRECTION == OUT && REF_PIN_NAME =~ hit*} \
        "the ITLB's PTE ph"      ${pre}u_fetch/u_itlb  {DIRECTION == OUT && REF_PIN_NAME =~ pte*ph*} \
        "the ITLB's PTE ppn"     ${pre}u_fetch/u_itlb  {DIRECTION == OUT && REF_PIN_NAME =~ pte*ppn*} \
        "the micro-BTB"          ${pre}u_fetch/u_ubtb  {DIRECTION == OUT} \
        "the PMP checker"        ${pre}u_fetch/u_pmp   {DIRECTION == OUT} \
        "the queue's blk_ready"  ${pre}u_fetch/u_cmp   {DIRECTION == OUT && REF_PIN_NAME =~ blk_ready*}] {
      set pp [hpins $cell $filt]
      puts $fs [format "      through %-22s (%3d pins): %s" $what [llength $pp] [worst -from $fpc -through $pp -to $fpc]]
    }
    set ic [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_way* && PRIMITIVE_GROUP == BLOCKRAM"]
    set tg [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_tage.u_tage/g_tab* && PRIMITIVE_GROUP == BLOCKRAM"]
    set tb [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_tage.u_tage/g_base* && PRIMITIVE_GROUP == BLOCKRAM"]
    foreach {what rams} [list "the I\$ data RAMs" $ic "TAGE's tables" $tg "TAGE's base" $tb] {
      set ap [get_pins -quiet -of_objects $rams -filter {REF_PIN_NAME =~ ADDR*}]
      set ep [get_pins -quiet -of_objects $rams -filter {REF_PIN_NAME =~ EN* || REF_PIN_NAME =~ REGCE*}]
      puts $fs [format "    %-17s (%2d RAMs): address %s" $what [llength $rams] [worst -to $ap]]
      puts $fs [format "    %-17s            enable  %s" "" [worst -to $ep]]
    }
    set tl [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/g_way*u_tag* && REF_NAME =~ RAMD*"]
    puts $fs "    the tag LUTRAMs ([llength $tl]): through their read addresses to anywhere [worst -from $fpc -through [get_pins -quiet -of_objects $tl -filter {REF_PIN_NAME =~ RADR*}]]"
    foreach r {f2_wh_q f2_hw_q f2_pmpd_q f2_pa_q f2_fault_q f2_tm_q f2_hit_q f2_tgt_q f2_valid_q} {
      set c [get_cells -quiet -hierarchical -filter "NAME =~ ${pre}u_fetch/${r}_reg* && IS_SEQUENTIAL"]
      puts $fs [format "    into %-11s %s" $r [worst -to $c]]
    }
    flush $fs
  }
  close_design
}
close $fs
puts "Q_FETCH_F1_DONE"
