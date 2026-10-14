# Named paths for spike S4 (sourced by ooc_run.tcl after routing).
set tg_paths {
  {ag_bram    *u_data*         *ag_*_q_reg*}
  {ag_va      *m1_va_q_reg*}
  {m1_data    *m2_data_q_reg*}
  {m1_tlb     *m2_ppn_q_reg*}
  {m1_tlbhit  *m2_tlb_hit_q_reg*}
  {m1_tag     *m2_tag_q_reg*}
  {m2_data    *ld_data_o_reg*}
  {m2_hit     *ld_cancel_o_reg*}
}
