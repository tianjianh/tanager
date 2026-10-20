# tg_urf's timing exceptions (DR-174, URF): read with -ref tg_urf (SCOPED_TO_REF) wherever the RTL is built
# with TG_URF=1, so ports and cells here are the instance's own. From spikes-2's urf_fit.tcl -edge 1
# (fpga/spikes/uram/README.md on claude/spikes-2-uram-rf). clk is the core clock and clk2x twice it, both from
# one MMCM with aligned rising edges; the UltraRAMs run on clk2x, everything around them on clk.
# Each copy's ports per core cycle (tg_urf.sv): at the core edge port A writes and port B reads an early
# port; at mid-cycle port A reads a late port and port B idles (EN_B low), holding its data.
set c0    [get_clocks -of_objects [get_ports clk]]
set urams [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]

# Early reads: the address (the issue select's output) is used at the core edge, a full core cycle after its
# launch; at the mid-cycle edge between, port B is disabled (EN_B, from the half-cycle flag, keeps its
# half cycle)
set addr_b [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ ADDR_B*}]
set_multicycle_path -setup 2 -end -from $c0 -through $addr_b
set_multicycle_path -hold  1 -end -from $c0 -through $addr_b

# The write lands at the core edge, a full cycle after its sources' launch, as tg_ram_lut's would. Port A's
# address and enable carry the mid-cycle late read too, through the half-cycle multiplexer, so only the
# paths through the write port's pins are relaxed: a late address keeps its half cycle even when its
# source also feeds the write
set wport [get_ports {we[*] waddr[*] wdata[*]}]
set_multicycle_path -setup 2 -end -through $wport -to $urams
set_multicycle_path -hold  1 -end -through $wport -to $urams

# Port B's data holds from the core edge to the next: a full cycle into the RF stage
set dout_b [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ DOUT_B*}]
set_multicycle_path -setup 2 -start -through $dout_b -to $c0
set_multicycle_path -hold  1 -start -through $dout_b -to $c0

# No exception: port A's mid-cycle data (DOUT_A) into the RF stage and the late addresses into ADDR_A (half
# a cycle each), the half-cycle flag into the multiplexers, EN and RDB_WR (clk2x's own cycle), and the
# early banks' register into the bank select (a core cycle)
