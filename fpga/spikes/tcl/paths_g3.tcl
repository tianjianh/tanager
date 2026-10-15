# Named paths for DR-133 gate 3 (fpga/spikes/rtl/tg_g3_top.sv; sourced by ooc_run.tcl after
# routing): the paths IRF_URAM adds in core 0, its URAM inputs in core 1, and the L2's.
#   {name to-glob ?from-glob?}: the worst path ending at (and starting from) matching cells
set tg_paths {
  {is_to_uram     *g_core?0?*u_ex/g_uram*u_ur*      *g_core?0?*u_is/*}
  {uram_to_ex_a   *g_core?0?*u_ex/ex_a_q_reg*       *g_core?0?*u_ex/g_uram*u_ur*}
  {uram_to_ex_b   *g_core?0?*u_ex/ex_b_q_reg*       *g_core?0?*u_ex/g_uram*u_ur*}
  {ex_a_q         *g_core?0?*u_ex/ex_a_q_reg*}
  {core0_uram_in  *g_core?0?*u_ex/g_uram*u_ur*}
  {c1_is_to_uram  *g_core?1?*u_ex/g_uram*u_ur*      *g_core?1?*u_is/*}
  {c1_uram_to_ex_a *g_core?1?*u_ex/ex_a_q_reg*      *g_core?1?*u_ex/g_uram*u_ur*}
  {c1_uram_to_ex_b *g_core?1?*u_ex/ex_b_q_reg*      *g_core?1?*u_ex/g_uram*u_ur*}
  {core1_uram_in  *g_core?1?*u_ex/g_uram*u_ur*}
  {l2_uram        *u_l2/g_bank*u_data*}
  {l2_resp        *u_l2/c_out_reg*}
}
