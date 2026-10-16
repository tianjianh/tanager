# G7's placement variant (DR-148, for the core track): G4-FP (a)'s L2 banks and crossbar, plus each
# core's LSU in one pblock with the block-RAM sites its D$ needs, so the LSU's logic sits beside its
# D$ data arrays (32 RAMB36) and against the crossbar. Each pblock is the X2 column's two block-RAM
# columns at its end of the device plus 62 rows of X1 beside the crossbar: about 17.9K LUTs (the
# LSU is 11.6K at G6, so about 65% full) and 37 RAMB36. G4-FP (b)'s LSU pblocks were 88-90% full and
# did not finish routing.
#   rows      X1                         X2
#   184-239                              core 1's LSU (with X1 130-191)
#   130-191   core 1's LSU
#   120-183                              L2 bank 1
#   102-129   crossbar
#    56-119                              L2 bank 0
#    40-101   core 0's LSU
#     0-55                               core 0's LSU (with X1 40-101)
# Sourced by g4_fit.tcl -floorplan.
source [file join $root fpga spikes tcl fp g4_uncore.tcl]
tg_fp_pblock lsu0 [tg_fp_cell {u_soc/g_core[0].g_tgc.u_core/u_lsu}] [tg_fp_rows X1 40 101] [tg_fp_rows X2 0 55]
tg_fp_pblock lsu1 [tg_fp_cell {u_soc/g_core[1].g_tgc.u_core/u_lsu}] [tg_fp_rows X1 130 191] [tg_fp_rows X2 184 239]
