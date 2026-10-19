#!/bin/bash
# smt2-study (area_recovery.md 6.12): Linux to /init in tb_boot as the board ran it, on the build host. RTL $1: d2
# (e65db3a) or d4s2 (03171ea with c261c1f's tg_fetch.sv), each a scratch worktree under smt2-study/brd_$1 whose
# tests/unit/boot/tb_boot.sv has CO_SIZE widened to 1 GiB for the board's device tree. smt2, two cores; the console on
# the host bridge (no serial timing: the CPU time alone); board-like memory (DDR 22 cycles, a 1,024-set L2); the
# board's bench OpenSBI and Image, and its bench device tree. The kernel log's timestamps are the CPU time to compare.
n=$1
[ -n "$n" ] || { echo "usage: brd_init.sh d2|d4s2"; exit 2; }
T=/home/w/tanager-build/smt2-study/brd_$n
cd "$T" || exit 1
source tools/env.sh >/dev/null 2>&1
MP="-GMEM_LAT_MIN=22 -GMEM_LAT_MAX=22 -GMEM_READY_PCT=100 -GMEM_OOO=0 -GMEM_R_PCT=100 -GL2_SETS_TB=1024"
make -C tests/unit/boot build CFG=smt2 CORES=2 SERIAL=0 TAG=_brd JOBS=8 MEM_PARAMS="$MP" || exit 1
B=/home/w/tanager-build/track-soc-160053/br-tanager_lp64d_bench/images
D=/home/w/tanager-build/track-soc-160053/board/d4s2-smt2-c2-100/tanager-kv260-bench.dtb
O=$(ls -d /home/w/tanager-build/brd_$n/tests/boot_brd_c2_t*_smt2 | head -1)
echo "binary: $O/tb_boot"
"$O/tb_boot" +seed=1 +fw=$B/fw_jump.bin +dtb=$D +kernel=$B/Image "+expect=Run /init as init process" +max_mcycles=200
