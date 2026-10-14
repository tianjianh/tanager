# Spike S1: the KV260 bitstream for the PL -> PS DDR latency and bandwidth measurement.
#   tools/vivado_run.sh <run-dir> fpga/spikes/s1/build.tcl <repo-root>
# Block design: Zynq UltraScale+ PS with the KV260 SOM preset; pl_clk0 (99.999 MHz) -> MMCM ->
# clk_core 200 MHz, which clocks M_AXI_HPM0_FPD (128-bit, SmartConnect to AXI4-Lite),
# S_AXI_HP1_FPD and S_AXI_HP2_FPD (128-bit) and the engines (tg_s1_bd). The fan enable
# (package pin A12) is held on. Outputs in the run directory: tg_s1.bit, tg_s1.bit.bin
# (for the Linux FPGA manager), tg_s1.dtbo, shell.json, reports.
set root [lindex $argv 0]
set part xck26-sfvc784-2LV-c
set here [file join $root fpga spikes s1]
set_param general.maxThreads 8

create_project -in_memory -part $part
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property target_language Verilog [current_project]
# module references need automatic compile order
set_property source_mgmt_mode All [current_project]
add_files -norecurse [list \
  [file join $root rtl common prim tg_ram_sdp.sv] \
  [file join $here rtl tg_s1_engine.sv] \
  [file join $here rtl tg_s1_top.sv] \
  [file join $here rtl tg_s1_bd.v]]
set_property file_type SystemVerilog [get_files *.sv]
update_compile_order -fileset sources_1

create_bd_design s1
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP3 {1} CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
  CONFIG.PSU__USE__S_AXI_GP4 {1} CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
  CONFIG.PSU__USE__FABRIC__RST {1} CONFIG.PSU__NUM_FABRIC_RESETS {1} \
] $ps

set clk [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_core]
set_property -dict [list CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200} \
  CONFIG.USE_LOCKED {true} CONFIG.USE_RESET {true} CONFIG.RESET_TYPE {ACTIVE_LOW} \
  CONFIG.RESET_PORT {resetn}] $clk
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_core]
set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
set eng [create_bd_cell -type module -reference tg_s1_bd s1]

connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins clk_core/clk_in1]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins clk_core/resetn] \
  [get_bd_pins rst_core/ext_reset_in]
connect_bd_net [get_bd_pins clk_core/locked] [get_bd_pins rst_core/dcm_locked]
connect_bd_net [get_bd_pins clk_core/clk_out1] [get_bd_pins rst_core/slowest_sync_clk] \
  [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins ps/saxihp1_fpd_aclk] \
  [get_bd_pins ps/saxihp2_fpd_aclk] [get_bd_pins sc/aclk] [get_bd_pins s1/clk]
connect_bd_net [get_bd_pins rst_core/peripheral_aresetn] [get_bd_pins sc/aresetn] \
  [get_bd_pins s1/rstn]
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M00_AXI] [get_bd_intf_pins s1/s_axi]
connect_bd_intf_net [get_bd_intf_pins s1/m0_axi] [get_bd_intf_pins ps/S_AXI_HP1_FPD]
connect_bd_intf_net [get_bd_intf_pins s1/m1_axi] [get_bd_intf_pins ps/S_AXI_HP2_FPD]
create_bd_port -dir O fan_en_b
connect_bd_net [get_bd_pins s1/fan_en_b] [get_bd_ports fan_en_b]

assign_bd_address
set seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces ps/Data] -filter {NAME =~ *s1*}]
if {[llength $seg] == 1} {
  set_property range 4K $seg
  set_property offset 0xA0000000 $seg
} else {
  puts "S1_NOTE engine segment not found by name; keeping the automatic address (see address_map.txt)"
}
validate_bd_design
save_bd_design

set bd [get_files s1.bd]
# synthesise the IPs with the design (no out-of-context IP runs in an in-memory project)
set_property synth_checkpoint_mode None $bd
generate_target all $bd
set wrapper [make_wrapper -files $bd -top]
add_files -norecurse $wrapper
set_property top s1_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Address map, for the A53 program and the report (best effort: never fails the build)
set fh [open address_map.txt w]
foreach s [get_bd_addr_segs -quiet] {
  if {[catch {format "%-48s %s %s" [get_property PATH $s] [get_property OFFSET $s] \
               [get_property RANGE $s]} line] == 0 && [string match "*SEG*" $line]} {
    puts $fh $line
  }
}
close $fh

synth_design -top s1_wrapper -part $part
read_xdc [file join $here tg_s1.xdc]
opt_design
place_design
phys_opt_design
route_design
report_utilization -file util.rpt
report_timing_summary -max_paths 10 -file timing_summary.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "S1_WNS $wns"

# Where the PS-PL interface sits (for the S6 floorplan): clock regions of the PL cells
# wired straight to the PS block.
# Best effort: a cell without a site (constants, clock buffers' leaves) is skipped.
set fh [open ps_location.txt w]
set ps [get_cells -quiet -hier -filter {REF_NAME == PS8}]
if {[llength $ps] == 1} {
  puts $fh "PS8 cell $ps site [get_property -quiet LOC $ps]"
  set regions [dict create]
  foreach n [get_nets -quiet -of_objects [get_pins -quiet -of_objects $ps]] {
    foreach c [get_cells -quiet -of_objects $n -filter {REF_NAME != PS8 && IS_PRIMITIVE}] {
      set site [get_sites -quiet -of_objects $c]
      if {[llength $site] != 1} continue
      set cr [get_property -quiet CLOCK_REGION $site]
      if {$cr ne ""} { dict incr regions $cr }
    }
  }
  dict for {k v} $regions { puts $fh "PL cells next to the PS in $k: $v" }
} else {
  puts $fh "PS8 cell not found"
}
close $fh
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force tg_s1.bit

# .bit.bin for the Linux FPGA manager
set bif [open tg_s1.bif w]
puts $bif "all: { tg_s1.bit }"
close $bif
exec bootgen -arch zynqmp -image tg_s1.bif -process_bitstream bin -w on
file copy -force [file join $here overlay shell.json] shell.json
exec dtc -@ -O dtb -o tg_s1.dtbo [file join $here overlay tg_s1.dtso]
puts "S1_BUILD_DONE wns=$wns"
