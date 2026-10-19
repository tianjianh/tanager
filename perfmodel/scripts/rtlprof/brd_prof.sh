#!/bin/bash
# smt2-study (area_recovery.md 6.12): d4s2's boot to /init as the board runs it (smt2, two cores, board-like memory,
# the board's bench images and device tree, no serial timing), with the profile binds prof_m6.sv and prof_f2cut.sv:
# the stall profile of the whole boot to /init against §6.11's first 20M cycles.
T=/home/w/tanager-build/smt2-study/brd_d4s2
P=/home/w/tanager-build/smt2-study/m6prof
cd "$T" || exit 1
source tools/env.sh >/dev/null 2>&1
MP="-GMEM_LAT_MIN=22 -GMEM_LAT_MAX=22 -GMEM_READY_PCT=100 -GMEM_OOO=0 -GMEM_R_PCT=100 -GL2_SETS_TB=1024"
make -C tests/unit/boot build CFG=smt2 CORES=2 SERIAL=0 TAG=_brdprof JOBS=8 MEM_PARAMS="$MP" \
  TB="$T/tests/unit/boot/tb_boot.sv $P/prof_m6.sv $P/prof_f2cut.sv" || exit 1
B=/home/w/tanager-build/track-soc-160053/br-tanager_lp64d_bench/images
D=/home/w/tanager-build/track-soc-160053/board/d4s2-smt2-c2-100/tanager-kv260-bench.dtb
O=$(ls -d /home/w/tanager-build/brd_d4s2/tests/boot_brdprof_c2_t*_smt2 | head -1)
echo "binary: $O/tb_boot"
"$O/tb_boot" +seed=1 +fw=$B/fw_jump.bin +dtb=$D +kernel=$B/Image "+expect=Run /init as init process" +max_mcycles=200
