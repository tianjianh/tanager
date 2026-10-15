# I/O delays for tg_fp_exec out of context (sourced by ooc.tcl through TG_OOC_IO), on top of the
# defaults (inputs 1.5 ns after the clock, outputs 1.0 ns before it).
# The F1 load write leaves the core's load result register (docs/spec/core-lsu.md, WB: "load bank
# written from the load result register"), so it arrives at clock-to-out plus routing, not after
# the core's operand bypass. 1.0 ns leaves about 0.9 ns for routing across the core. The contract
# (docs/spec/fpu.md, "The core's side of the contract") requires fld_* straight from that register.
set_input_delay -clock clk 1.0 [get_ports {fld_valid fld_idx[*] fld_data[*]}]
