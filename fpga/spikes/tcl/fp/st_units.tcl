# One pblock per unit of the st core, after the core track's floorplan brief: fetch next to decode
# next to rename; issue, execute, the LSU and the ROB together, with P4 beside execute; the I$ and
# D$ beside block-RAM columns; the CSRs with the ROB. Rows 0-239 from the bottom (60 per region);
# LUTs per row: X0 184, X1 144, X2 160. Each pblock is about 60-70% full.
#
#   rows       X0               X1                          X2
#   190-239                     decode + rename (195-239)   fetch (I$: 20 RAMB36 for 16)
#   145-194                     issue (145-194)             ROB + CSRs (150-189)
#    50-149    P4 (70-134)      execute (65-144)            LSU (50-149; D$: 40 RAMB36 for 32)
#
# P4's one RAMB36 has no site in X0, so its pblock adds X1 rows 55-64 (two RAMB36 sites).
# Sourced by fp_core.tcl with fp_lib.tcl's helpers.
tg_fp_pblock fetch  {u_fetch}      [tg_fp_rows X2 190 239]
tg_fp_pblock front  {u_de u_rn}    [tg_fp_rows X1 195 239]
tg_fp_pblock issue  {u_is}         [tg_fp_rows X1 145 194]
tg_fp_pblock rob    {u_rob u_csr}  [tg_fp_rows X2 150 189]
tg_fp_pblock exec   {u_ex}         [tg_fp_rows X1 65 144]
tg_fp_pblock p4     {g_p4.u_p4}    [tg_fp_rows X0 70 134] [tg_fp_rows X1 55 64]
tg_fp_pblock lsu    {u_lsu}        [tg_fp_rows X2 50 149]
