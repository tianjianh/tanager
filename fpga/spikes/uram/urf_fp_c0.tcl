# Tier A's floorplan (spikes.md §8.14): urf_top laid out as core 0 is in h100_m6m (main 31e65c6), from
# q_urf_ctx.tcl's urf_ctx.txt (the middle 80% of each group's slices):
#   issue -> RF registers (the select stand-in)       SLICE_X38Y212:SLICE_X58Y235
#   RF-stage registers (ex_q)                         SLICE_X24Y194:SLICE_X35Y233
#   write sources (the write-port stand-ins, and the LD/STA bypass sources, which are among them)
#                                                     SLICE_X23Y194:SLICE_X40Y232
#   the LSU's store-data tag sources (the late stand-in) SLICE_X43Y171:SLICE_X56Y183
#   the LSU's store-data capture (sd_q)               SLICE_X45Y197:SLICE_X53Y202
# The nine copies take the free UltraRAMs level with the RF stage (URAM288_X0Y52-X0Y60, RPM y 406-468
# against the RF stage's 390-490), the probe the next one. The rest (tg_urf's address multiplexers,
# captures, bank select and half-cycle flag, and the LFSRs) is placed freely.
set i 52
foreach b {0 1 2} {
  foreach c {0 1 2} {
    set_property LOC URAM288_X0Y$i [get_cells "u_urf/g_bank\\\[$b\\\].g_copy\\\[$c\\\].u_uram"]
    incr i
  }
}
set_property LOC URAM288_X0Y$i [get_cells -quiet g_probe.u_probe]
proc pb {name range cells} {
  create_pblock $name
  resize_pblock [get_pblocks $name] -add $range
  add_cells_to_pblock [get_pblocks $name] $cells
  set_property IS_SOFT FALSE [get_pblocks $name]
}
pb pb_sel  SLICE_X38Y212:SLICE_X58Y235 [get_cells {sel_bank_q_reg* sel_idx_q_reg*}]
pb pb_ex   SLICE_X24Y194:SLICE_X35Y233 [get_cells ex_q_reg*]
pb pb_wr   SLICE_X23Y194:SLICE_X40Y232 [get_cells {wr_we_q_reg* wr_a_q_reg* wr_d_q_reg* byp_s_q_reg* byp_d_q_reg*}]
pb pb_late SLICE_X43Y171:SLICE_X56Y183 [get_cells {late_en_q_reg* late_bank_q_reg* late_idx_q_reg*}]
pb pb_sd   SLICE_X45Y197:SLICE_X53Y202 [get_cells sd_q_reg*]
