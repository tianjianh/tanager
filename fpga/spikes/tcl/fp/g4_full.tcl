# G4-FP (b), the coordinator's request (DR-142): (a)'s L2 banks and crossbar, plus each core's LSU
# against them, so the cores' L1 ports face the crossbar. One pblock per whole core does not fit:
# at 44.6K LUTs a core needs 38% of the XCK26, and two such pblocks around the uncore's would be
# over 90% full, so only the LSU (10.8K LUTs and the D$'s 32 RAMB36, the cores' side of the
# crossbar paths) is placed; the rest of each core is free.
#   rows      X1                         X2
#   184-239   core 0's LSU (130-183)     core 0's LSU (184-239)
#   120-183                              L2 bank 1
#   102-129   crossbar
#    56-119                              L2 bank 0
#     0-55    core 1's LSU (50-101)      core 1's LSU (0-55)
# Each LSU gets about 16K LUTs (67% full) and 33-35 RAMB36. Sourced by g4_fit.tcl -floorplan.
source [file join $root fpga spikes tcl fp g4_uncore.tcl]
tg_fp_pblock lsu0 [tg_fp_cell {u_soc/g_core[0].g_tgc.u_core/u_lsu}] [tg_fp_rows X1 130 183] [tg_fp_rows X2 184 239]
tg_fp_pblock lsu1 [tg_fp_cell {u_soc/g_core[1].g_tgc.u_core/u_lsu}] [tg_fp_rows X1 50 101] [tg_fp_rows X2 0 55]
