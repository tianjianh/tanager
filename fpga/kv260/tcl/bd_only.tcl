# Generates only the PS block design and its wrapper (to inspect ports and the address map).
#   tools/vivado_run.sh <run-dir> fpga/kv260/tcl/bd_only.tcl <repo-root> [core_mhz]
lassign $argv root core_mhz
if {$core_mhz eq ""} { set core_mhz 100 }
create_project -in_memory -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
source [file join $root fpga kv260 tcl ps_bd.tcl]
if {![info exists ::env(TG_FAN_TTC)]} { puts "ERROR: set TG_FAN_TTC (DR-129, fpga/kv260/README.md)"; exit 1 }
tg_make_ps_bd [file normalize ./bd] $core_mhz $::env(TG_FAN_TTC)
puts "WRAPPER $::tg_ps_wrapper"
file copy -force $::tg_ps_wrapper ./tg_ps_wrapper.v
puts "BD_OK"
