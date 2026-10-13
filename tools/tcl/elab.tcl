# Elaborates the product RTL in Vivado for one configuration and top (no synthesis), to catch
# constructs Verilator accepts and Vivado does not.
#   tools/vivado_run.sh <run-dir> tools/tcl/elab.tcl <repo-root> <cfg> <top>
lassign $argv root cfg top
source [file join $root tools tcl tg_files.tcl]
tg_read_rtl $root $cfg
synth_design -rtl -top $top -part xck26-sfvc784-2LV-c -mode out_of_context
puts "ELAB_OK $cfg $top"
