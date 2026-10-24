# Writes the board image from a routed checkpoint as build.tcl's bitstream stage does: write_bitstream, then bootgen's
# .bit.bin for the Linux FPGA manager (fpgautil / xmutil). The fan, PMOD and every other board setting come from the
# checkpoint (synthesis generics and the XDCs). Also reports the checkpoint's timing as it stands. spikes §8.18: the
# first product chip that closes 100 MHz (the coordinator, 10-22). Writes tanager.bit, tanager.bit.bin, timing_bit.rpt.
#   tools/vivado_run.sh <run-dir> fpga/spikes/tcl/write_bit_from_dcp.tcl <routed.dcp>        (about 8 GB)
open_checkpoint [lindex $argv 0]
report_timing_summary -max_paths 5 -file timing_bit.rpt
write_bitstream -force ./tanager.bit
set fh [open ./tanager.bif w]
puts $fh "all: { [file normalize ./tanager.bit] }"
close $fh
exec bootgen -arch zynqmp -image ./tanager.bif -process_bitstream bin -w on
puts "WRITE_BIT_DONE"
