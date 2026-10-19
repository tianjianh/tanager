# tb_urf in xsim with the vendor's URAM288_BASE model (spikes.md §8.14), run in Vivado's batch mode so
# it goes through the admission slots:
#   tools/vivado_run.sh <run-dir> fpga/spikes/uram/urf_sim.tcl <tree>     (about 2 GB)
# Compiles the vendor's URAM288_BASE model from the Vivado installation's sources (it has no precompiled
# xsim libraries), tg_urf, tg_ram_lut (the reference, behavioural: SYNTHESIS is not defined), the testbench
# and glbl, runs to the end and writes sim.log; fails unless the testbench prints TB_URF PASS.
set root [file normalize [lindex $argv 0]]
set xil  $::env(XILINX_VIVADO)
set u    $root/fpga/spikes/uram
proc run {args} {
  puts "== $args"
  if {[catch {exec -ignorestderr {*}$args 2>@1} out]} { puts $out; puts "URF_SIM_FAILED: $args"; exit 1 }
  puts $out
  return $out
}
run xvlog --sv $u/tg_urf.sv $root/rtl/common/prim/tg_ram_lut.sv $u/tb_urf.sv
run xvlog $xil/data/verilog/src/glbl.v $xil/data/verilog/src/unisims/URAM288_BASE.v
run xelab -timescale 1ns/1ps -s tb_urf_sim tb_urf glbl
set out [run xsim tb_urf_sim -R]
set fh [open sim.log w]; puts $fh $out; close $fh
if {![string match "*TB_URF PASS*" $out]} { puts "URF_SIM_FAILED: no TB_URF PASS"; exit 1 }
puts "URF_SIM_DONE"
