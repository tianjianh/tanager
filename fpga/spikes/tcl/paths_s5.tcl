# Named paths for spike S5 (sourced by ooc_run.tcl after routing).
set tg_paths {
  {nextpc       *fpc_q_reg*}
  {icache_addr  *g_way*u_data*}
  {saved_pc     *saved_q_reg*}
  {if2_stage    *if3_*_q_reg*}
  {if2_carry    *carry_q_reg*}
  {if3_iq_write *u_cmp/g_bank*}
  {if3_state    *u_cmp/*_q_reg*}
  {iq_read      *out_insn_o_reg*}
}
