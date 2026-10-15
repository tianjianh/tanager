# After routing tg_exec out of context (ooc.tcl through TG_OOC_POST): the worst paths to the
# address-generation outputs (ld_ag_addr, sta_ag_addr), which the LSU registers (its address stage),
# into ag_paths.rpt, and their worst slack on the OOC_AG line of the log.
report_timing -to [get_ports {ld_ag_addr[*] sta_ag_addr[*]}] -max_paths 4 -nworst 1 -file ag_paths.rpt
set ag [get_timing_paths -to [get_ports {ld_ag_addr[*] sta_ag_addr[*]}] -max_paths 1]
puts "OOC_AG slack=[get_property SLACK $ag] levels=[get_property LOGIC_LEVELS $ag]"
