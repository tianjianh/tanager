# PS block design for the KV260 (docs/spec/soc.md §2.2). Sourced by build.tcl and bd_only.tcl
# inside an in-memory project whose board_part is kv260_som. Creates block design `tg_ps` in
# $bd_dir and its wrapper; returns the wrapper path in ::tg_ps_wrapper.
#   M_AXI_HPM0_FPD  32-bit AXI4 master to the host bridge, at 0xA000_0000 (clocked by clk_host)
#   S_AXI_HP1_FPD   128-bit AXI4 slave from L2 bank 0 (clocked by clk_core)
#   S_AXI_HP2_FPD   128-bit AXI4 slave from L2 bank 1 (clocked by clk_core)
#   S_AXI_HP3_FPD   128-bit AXI4 slave from the commit-trace stream, writes only (clocked by clk_core)
#   pl_clk0 = 100 MHz, pl_resetn0, pl_ps_irq0[0]
#   fan_wave[2:0]   the fan PWM's TTC waveform outputs on EMIO (DR-129; tools/tcl/tg_kv260_fan.tcl, which the
#                   caller sources first)
proc tg_make_ps_bd {bd_dir core_mhz} {
  create_bd_design -dir $bd_dir tg_ps
  set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
  apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
  set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP0 {0} \
    CONFIG.PSU__USE__S_AXI_GP1 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP3 {1} \
    CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
    CONFIG.PSU__USE__S_AXI_GP4 {1} \
    CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
    CONFIG.PSU__USE__S_AXI_GP5 {1} \
    CONFIG.PSU__SAXIGP5__DATA_WIDTH {128} \
    CONFIG.PSU__USE__S_AXI_GP6 {0} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__FPGA_PL1_ENABLE {0} \
    CONFIG.PSU__USE__IRQ0 {1} \
  ] $ps
  set fan_pin [tg_kv260_fan_ps $ps]

  # External ports with fixed names
  set m_hpm0 [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_HPM0]
  set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {32} CONFIG.ADDR_WIDTH {40} \
    CONFIG.FREQ_HZ {100000000}] $m_hpm0
  connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] $m_hpm0

  foreach {port pin} {S_AXI_HP1 S_AXI_HP1_FPD S_AXI_HP2 S_AXI_HP2_FPD S_AXI_HP3 S_AXI_HP3_FPD} {
    set s [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 $port]
    set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {128} CONFIG.ADDR_WIDTH {49} \
      CONFIG.ID_WIDTH {6} CONFIG.FREQ_HZ [expr {int($core_mhz * 1000000)}] \
      CONFIG.HAS_REGION {0} CONFIG.HAS_QOS {0} CONFIG.HAS_LOCK {0} CONFIG.HAS_CACHE {1} CONFIG.HAS_PROT {1} \
      CONFIG.MAX_BURST_LENGTH {16} CONFIG.NUM_READ_OUTSTANDING {32} CONFIG.NUM_WRITE_OUTSTANDING {32}] $s
    connect_bd_intf_net $s [get_bd_intf_pins $ps/$pin]
  }

  set clk_host [create_bd_port -dir I -type clk -freq_hz 100000000 clk_host]
  set_property CONFIG.ASSOCIATED_BUSIF {M_AXI_HPM0} $clk_host
  connect_bd_net $clk_host [get_bd_pins $ps/maxihpm0_fpd_aclk]
  set clk_core [create_bd_port -dir I -type clk -freq_hz [expr {int($core_mhz * 1000000)}] clk_core]
  set_property CONFIG.ASSOCIATED_BUSIF {S_AXI_HP1:S_AXI_HP2:S_AXI_HP3} $clk_core
  connect_bd_net $clk_core [get_bd_pins $ps/saxihp1_fpd_aclk]
  connect_bd_net $clk_core [get_bd_pins $ps/saxihp2_fpd_aclk]
  connect_bd_net $clk_core [get_bd_pins $ps/saxihp3_fpd_aclk]

  set pl_clk0 [create_bd_port -dir O -type clk pl_clk0]
  connect_bd_net [get_bd_pins $ps/pl_clk0] $pl_clk0
  set pl_resetn0 [create_bd_port -dir O -type rst pl_resetn0]
  connect_bd_net [get_bd_pins $ps/pl_resetn0] $pl_resetn0
  set irq [create_bd_port -dir I -from 0 -to 0 -type intr pl_ps_irq0]
  connect_bd_net $irq [get_bd_pins $ps/pl_ps_irq0]
  set fan_wave [create_bd_port -dir O -from 2 -to 0 fan_wave]
  connect_bd_net $fan_pin $fan_wave

  # Address map: the host bridge's 64 KiB at the start of the HPM0 aperture; the HP ports see all
  # of DDR (the carve-out is chosen at run time, docs/spec/host.md).
  assign_bd_address
  set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces $ps/Data] -filter {NAME =~ "*M_AXI_HPM0*"}]
  if {$seg ne ""} {
    set_property offset 0xA0000000 $seg
    set_property range 64K $seg
  }
  validate_bd_design
  save_bd_design

  set bd_file [get_files tg_ps.bd]
  set_property synth_checkpoint_mode None $bd_file
  generate_target all $bd_file
  set ::tg_ps_wrapper [make_wrapper -files $bd_file -top]
  report_bd_diffs -quiet
  puts "TG_PS address map:"
  foreach s [get_bd_addr_segs -excluded false] {
    catch {puts [format "  %-60s %s %s" [get_property NAME $s] [get_property OFFSET $s] [get_property RANGE $s]]}
  }
}
