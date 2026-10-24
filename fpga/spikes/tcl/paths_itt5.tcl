# M9's indirect-target table with its keys in LUT RAM, checked at F1 (fpu-2, bf29152f, 10-24) for ooc_run.tcl -paths:
# paths_itt4.tcl's, plus fetch's predicted-slot registers phit_q and pslot_q (F1's key check, else the micro-BTB's slot),
# and fpc_q from the I$ data and from f3_start_q (a6f51752's mode 1 was 4 levels deeper than off from f3_start_q).
source [file join [file dirname [info script]] paths_itt4.tcl]
lappend tg_paths \
  {phit_q         *u_fetch/phit_q_reg*} \
  {pslot_q        *u_fetch/pslot_q_reg*} \
  {fpc_q_ic       *u_fetch/fpc_q_reg*         *u_fetch/g_way*u_data*} \
  {fpc_q_f3st     *u_fetch/fpc_q_reg*         *u_fetch/f3_start_q_reg*}
