# M9's indirect-target table after fpu-2's timing fix (188328af, 10-24) for ooc_run.tcl -paths: paths_itt2.tcl's, plus
# the path history's new registers (ipi_q, ipw_q) and, from the I$ data RAMs, every register of F2's decision and the
# restart (the question: back near the 15-17 levels the table off has, with krt_q and f3_rtop_q at about 7).
source [file join [file dirname [info script]] paths_itt2.tcl]
lappend tg_paths \
  {ipi_q          *ipi_q_reg*} \
  {ipw_q          *ipw_q_reg*} \
  {ka_q_ic        *u_fetch/ka_q_reg*          *u_fetch/g_way*u_data*} \
  {k_ovr_q_ic     *u_fetch/k_ovr_q_reg*       *u_fetch/g_way*u_data*} \
  {kr_q_ic        *u_fetch/kr_q_reg*          *u_fetch/g_way*u_data*} \
  {krt_q_ic       *u_fetch/krt_q_reg*         *u_fetch/g_way*u_data*} \
  {ki_q_ic        *u_fetch/ki_q_reg*          *u_fetch/g_way*u_data*} \
  {f3_ras_q_ic    *u_fetch/f3_ras_q_reg*      *u_fetch/g_way*u_data*} \
  {f3_rtop_q_ic   *u_fetch/f3_rtop_q_reg*     *u_fetch/g_way*u_data*} \
  {f3_itt_q_ic    *u_fetch/f3_itt_q_reg*      *u_fetch/g_way*u_data*} \
  {ipi_q_ic       *ipi_q_reg*                 *u_fetch/g_way*u_data*} \
  {ipw_q_ic       *ipw_q_reg*                 *u_fetch/g_way*u_data*} \
  {ras_push_ic    *u_ras/g_late.p_push_q_reg* *u_fetch/g_way*u_data*} \
  {ras_pop_ic     *u_ras/g_late.p_pop_q_reg*  *u_fetch/g_way*u_data*}
