# Named paths for spike S3 (sourced by ooc_run.tcl after routing).
set tg_paths {
  {alu_loop   *res_q_reg*   *res_q_reg*}
  {alu_any    *res_q_reg*}
  {flags      *alu_flags_o_reg*}
  {rf_read    *rf_q_reg*}
  {rf_write   *u_irf/g_bank*}
  {base       *base_q_reg*}
}
