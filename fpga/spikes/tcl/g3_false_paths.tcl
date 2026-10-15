# DR-133 gate 3 and spike G4 only (fpga/spikes/rtl/tg_g3_top.sv through ooc_run.tcl -constraints,
# after the clock exists; kv260_top through g4_fit.tcl -constraints, after synthesis, where the
# cores are u_soc/g_core[c].g_tgc.u_core). The real cores carry two known cross-unit path families
# that miss even 100 MHz (the SoC's M4 build: 3.76 ns short at 10 ns; the core track owns them):
#   u_lsu ... r_data_q -> u_rob ... exr_*   (38 levels, about 13.5 ns)
#   u_ex ... wbq_q     -> u_rob ... cmp_q   (35 levels, about 13.3 ns)
# They are cut here, so the run measures what it asks (gate 3: the UltraRAM paths; G4: the uncore's
# register slices) with less of the placer's effort on them. constraints.txt records how many
# cells each cut covers.
set cfh [open constraints.txt w]
puts $cfh "false paths (gate 3 and G4 only; the core track owns these paths):"
foreach c {0 1} {
  set core "g_core?${c}?*u_core"
  foreach {from to} {u_lsu*r_data_q_reg* u_rob*exr_* u_ex*wbq_q_reg* u_rob*cmp_q_reg*} {
    set f [get_cells -quiet -hierarchical -filter "NAME =~ *${core}/${from} && IS_SEQUENTIAL"]
    set t [get_cells -quiet -hierarchical -filter "NAME =~ *${core}/${to} && IS_SEQUENTIAL"]
    puts $cfh [format "  core %d: %-20s (%5d cells) -> %-16s (%5d cells)" $c $from [llength $f] $to [llength $t]]
    if {[llength $f] && [llength $t]} { set_false_path -from $f -to $t }
  }
}
close $cfh
