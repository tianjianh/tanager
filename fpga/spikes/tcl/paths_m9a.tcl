# M9's area package fit (the coordinator, 10-24): the full chip with TG_HPM=1, TG_LWT=1 and TG_ITT=2, against the
# pair of record (rec_u095 / rec_u105, all three off), for q_paths.tcl on each routed checkpoint: paths_itt5.tcl's
# families (every glob starts with *, so both cores match), plus fpc_q from f3_carry_q, the chip's own fpc_q family
# (+0.388 ns in rec_u095).
source [file join [file dirname [info script]] paths_itt5.tcl]
lappend tg_paths \
  {fpc_q_f3c      *u_fetch/fpc_q_reg*         *u_fetch/f3_carry_q_reg*}
