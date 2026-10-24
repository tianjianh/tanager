# M9's indirect-target table (fpu-2's ITT, TG_ITT 1 or 2; DR-190) for ooc_run.tcl -paths on the product core: the new
# paths fpu-2 named (F2's decision from u_itt's read into the redirect; kr_q/krt_q and f3_ras_q/f3_rtop_q with the
# table's target muxed in; commit's training into the table's write), beside DR-191's families for side effects.
source [file join [file dirname [info script]] paths_dr191.tcl]
lappend tg_paths \
  {itt_to_any     *                     *u_itt*} \
  {itt_write      *u_itt*} \
  {itt_to_fpc     *u_fetch/fpc_q_reg*   *u_itt*} \
  {kr_q           *u_fetch/kr_q_reg*} \
  {krt_q          *u_fetch/krt_q_reg*} \
  {f3_ras_q       *u_fetch/f3_ras_q_reg*} \
  {f3_rtop_q      *u_fetch/f3_rtop_q_reg*} \
  {fpc_q          *u_fetch/fpc_q_reg*}
