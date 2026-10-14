# I/O delays for tg_exec out of context (sourced by ooc.tcl through TG_OOC_IO), on top of the
# defaults (inputs 1.5 ns after the clock, outputs 1.0 ns before it).
# The load result (ld_res_*) leaves the core's load result register (docs/spec/core-lsu.md, WB:
# the load bank is written from the load result register), as fld_* does for P4
# (fp_exec_io.tcl): clock-to-out plus routing across the core, not the operand bypass.
set_input_delay -clock clk 1.0 [get_ports {ld_res_valid ld_res_dst[*] ld_res_data[*]}]
