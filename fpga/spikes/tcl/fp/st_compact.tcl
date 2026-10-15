# The whole st core in one block of two columns by three regions (X1Y1:X2Y3, rows 60-239): 54,720
# LUTs for the core's 42.8K (78%), 108 RAMB36 and 504 DSPs, around the clock buffer in X1Y2.
# Sourced by fp_core.tcl with fp_lib.tcl's helpers.
tg_fp_pblock core [get_cells] [tg_fp_rows X1 60 239] [tg_fp_rows X2 60 239]
