# TG_DEBUG=1 builds (docs/spec/soc.md §9.2; read by build.tcl): the JTAG clock, the device TAP's TCK through USER3's
# BSCANE2 and a BUFG into tg_dtm. The DTM's request and answer cross into clk_core and back by toggles through
# xpm_cdc_single (their own constraints), with the fields held steady meanwhile, so the two clocks are asynchronous.
# 30 ns covers the adapter's TCK (OpenOCD's `adapter speed`, a few MHz to 33 MHz); dtmcs.idle covers the
# crossing's round trip up to about 50 MHz.
create_clock -period 30.000 -name jtag_tck [get_pins -hierarchical -filter {NAME =~ *u_bscan_dtmcs/TCK}]
set_clock_groups -asynchronous -group [get_clocks jtag_tck] \
  -group [get_clocks -of_objects [get_pins u_clkgen/u_mmcm/CLKOUT0]]
