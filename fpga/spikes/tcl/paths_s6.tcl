# Named paths for spike S6, the full-device dry run (sourced by ooc_run.tcl after routing).
# Core 0's spike structures in their full-chip surroundings, the L2 and the filler.
set tg_paths {
  {s2_wakeup_loop *g_core?0?*u_s2/u_wake/*w_q_reg*}
  {s2_issue       *g_core?0?*u_s2/*iss_payload*_reg*}
  {s3_alu_loop    *g_core?0?*u_s3/res_q_reg*}
  {s3_rf_read     *g_core?0?*u_s3/rf_q_reg*}
  {s4_m2          *g_core?0?*u_s4/ld_data_o_reg*}
  {s4_ag_bram     *g_core?0?*u_s4/g_way*}
  {s4_dtlb        *g_core?0?*u_s4/m2_ppn_q_reg*}
  {s5_nextpc      *g_core?0?*u_s5/fpc_q_reg*}
  {s5_icache_addr *g_core?0?*u_s5/g_way*}
  {s5_if3         *g_core?0?*u_s5/u_cmp/*}
  {l2_resp        *u_l2/c_out_reg*}
  {l2_uram        *u_l2/g_bank*u_data*}
  {core_l2_bus    *to_l2_q_reg*}
  {filler         *g_core?0?*u_fill/g_tile*}
}
