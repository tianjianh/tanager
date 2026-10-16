# G4-FP (a), the coordinator's request (DR-142): the uncore's L2 banks and crossbar in pblocks, the
# cores and the rest of the uncore free. Each L2 bank (its MSHR state, tags and data URAMs) sits in
# the X2 column, which holds every URAM: its 16 URAMs in 64 rows of the URAM column (17-18
# sites), its logic in the 40 rows in the middle of those (6,400 LUTs for about 4.5K), and its 6
# RAMB36 in 20 rows (8 sites). Bank 0 is below bank 1, around the clock root's row (120). The
# crossbar sits in X1 beside both banks, rows 102-129 (4,032 LUTs for 2.5K, 67 DSPs for 13).
# Rows 0-239 from the bottom, 60 per clock region (fp_lib.tcl). Sourced by g4_fit.tcl -floorplan.
set b0 {u_soc/u_uncore/u_l2/g_bank[0].u_bank}
set b1 {u_soc/u_uncore/u_l2/g_bank[1].u_bank}
tg_fp_pblock l2b0 [tg_fp_cell $b0] [tg_fp_rows X2 56 119 URAM288] [tg_fp_rows X2 68 107 {SLICE DSP48E2}] \
  [tg_fp_rows X2 70 89 {RAMB36 RAMB18}]
tg_fp_pblock l2b1 [tg_fp_cell $b1] [tg_fp_rows X2 120 183 URAM288] [tg_fp_rows X2 132 171 {SLICE DSP48E2}] \
  [tg_fp_rows X2 135 154 {RAMB36 RAMB18}]
tg_fp_pblock xbar [tg_fp_cell u_soc/u_uncore/u_xbar] [tg_fp_rows X1 102 129]
