# DR-191's recurring families (spikes §8.18), for ooc_run.tcl -paths on the product core (tg_core, smt2, TG_HART1=1):
# the worst path into each family's registers, so a fix's out-of-context check shows its family's levels, logic and
# slack before and after. Names relative to tg_core.
set tg_paths {
  {lq_st_q        *u_lsu/lq_st_q_reg*}
  {r_data_q       *u_lsu/r_data_q_reg*}
  {lx_valid_q     *lx_valid_q_reg*}
  {m2_foh_q       *u_lsu/m2_foh_q_reg*}
  {chk_pa_q       *u_ptw/chk_pa_q_reg*}
  {ival_ram       *u_fetch/u_ival/*}
  {tage           *g_tage.u_tage/g_tab*}
  {lq_st_q_sn     *u_lsu/lq_st_q_reg*    *u_lsu/g_split.sn_*}
  {chk_pa_q_dtlb  *u_ptw/chk_pa_q_reg*   *u_dtlb/*}
}
