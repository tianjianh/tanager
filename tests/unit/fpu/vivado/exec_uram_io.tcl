# I/O delays for tg_exec with IRF_URAM out of context (sourced by ooc.tcl through TG_OOC_IO,
# after exec_io.tcl): the issue-stage source tags (iss_src_d) are tg_iq's payload_sel, the
# select's AND-OR output, which the core registers in the same cycle (early_q). Assumed to
# arrive 2.5 ns after the clock (half the cycle); the URAM registers the address itself.
set_input_delay -clock clk 2.5 [get_ports {iss_src_d[*]}]
