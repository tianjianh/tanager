# Primitive counts of the routed design, checked against expectations (plan §8.3: Vivado can drop
# RAM ports silently). Writes a report and fails loudly on a mismatch.
proc tg_count {ref} { return [llength [get_cells -hierarchical -filter "PRIMITIVE_TYPE =~ $ref"]] }
proc tg_prim_check {rpt} {
  set uram  [tg_count "BLOCKRAM.URAM.*"]
  set bram36 [tg_count "BLOCKRAM.BRAM.RAMB36*"]
  set bram18 [tg_count "BLOCKRAM.BRAM.RAMB18*"]
  set dsp   [tg_count "ARITHMETIC.DSP.*"]
  set lutram [tg_count "CLB.LUTRAM.*"]
  set fh [open $rpt w]
  puts $fh "URAM288  $uram"
  puts $fh "RAMB36   $bram36"
  puts $fh "RAMB18   $bram18"
  puts $fh "DSP48E2  $dsp"
  puts $fh "LUTRAM   $lutram"
  close $fh
  puts "TG_PRIMS URAM=$uram RAMB36=$bram36 RAMB18=$bram18 DSP=$dsp LUTRAM=$lutram"
  # The L2 data arrays: 2 banks x 16 URAM (docs/spec/l2.md), unless the L2 is shrunk.
  if {$uram != 32} { puts "TG_PRIM_WARNING: expected 32 URAM for the 1 MiB L2, found $uram" }
}
