# M9's indirect-target table after the coordinator's restructure (fpu-2, a6f51752, 10-24) for ooc_run.tcl -paths:
# paths_itt3.tcl's, plus kimm_q from the I$ data, every decision register from TAGE's tables, and fpc_q from f3_s_q
# (fpu-2's synthesized 26 levels against 24 off). The bar: the decision registers at the table-off depth from the I$ data.
source [file join [file dirname [info script]] paths_itt3.tcl]
lappend tg_paths \
  {kimm_q_ic      *u_fetch/kimm_q_reg*        *u_fetch/g_way*u_data*} \
  {k_ovr_q_tage   *u_fetch/k_ovr_q_reg*       *g_tage.u_tage/*} \
  {kr_q_tage      *u_fetch/kr_q_reg*          *g_tage.u_tage/*} \
  {f3_ras_q_tage  *u_fetch/f3_ras_q_reg*      *g_tage.u_tage/*} \
  {ki_q_tage      *u_fetch/ki_q_reg*          *g_tage.u_tage/*} \
  {f3_itt_q_tage  *u_fetch/f3_itt_q_reg*      *g_tage.u_tage/*} \
  {ipi_q_tage     *ipi_q_reg*                 *g_tage.u_tage/*} \
  {ipw_q_tage     *ipw_q_reg*                 *g_tage.u_tage/*} \
  {fpc_q_f3s      *u_fetch/fpc_q_reg*         *u_fetch/f3_s_q_reg*}
