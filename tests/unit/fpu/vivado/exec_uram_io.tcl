# I/O delays for tg_exec with IRF_URAM out of context (sourced by ooc.tcl through TG_OOC_IO,
# after exec_io.tcl): the issue-stage source tags (is_src1, is_src2) come from tg_issue,
# tg_iq's payload_sel AND-OR select gated by the grant, which the core registers in the same
# cycle (early_q). Assumed to arrive 2.5 ns after the clock (half the cycle); the URAM
# registers the address itself.
set_input_delay -clock clk 2.5 [get_ports {is_src1[*] is_src2[*]}]
