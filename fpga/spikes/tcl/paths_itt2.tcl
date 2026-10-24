# M9's indirect-target table after the coordinator's trim (fpu-2, 7ba9b0a0, 10-24), for ooc_run.tcl -paths on the
# product core: DR-191's families and paths_itt.tcl's, plus the trimmed table's registers (ki_q, kit_q, f3_itt_q,
# f3_itgt_q) and F2's decision (ka_q, k_ovr_q, kimm_q, the stack's push and pop), each also from TAGE's tables, the start
# fpu-2 saw at 20-21 levels in the untrimmed mode 1 (15-17 with the table off).
source [file join [file dirname [info script]] paths_itt.tcl]
lappend tg_paths \
  {ki_q           *u_fetch/ki_q_reg*} \
  {kit_q          *u_fetch/kit_q_reg*} \
  {f3_itt_q       *u_fetch/f3_itt_q_reg*} \
  {f3_itgt_q      *u_fetch/f3_itgt_q_reg*} \
  {ka_q           *u_fetch/ka_q_reg*} \
  {k_ovr_q        *u_fetch/k_ovr_q_reg*} \
  {kimm_q         *u_fetch/kimm_q_reg*} \
  {ras_push       *u_ras/g_late.p_push_q_reg*} \
  {ras_pop        *u_ras/g_late.p_pop_q_reg*} \
  {ka_q_tage      *u_fetch/ka_q_reg*         *g_tage.u_tage/*} \
  {kimm_q_tage    *u_fetch/kimm_q_reg*       *g_tage.u_tage/*} \
  {ras_push_tage  *u_ras/g_late.p_push_q_reg* *g_tage.u_tage/*} \
  {ras_pop_tage   *u_ras/g_late.p_pop_q_reg*  *g_tage.u_tage/*}
