#!/bin/bash
# smt2-study (area_recovery.md 6.12): how much code layout moves d2's and d4s2's IPC. make perf's CoreMark A and B and
# Dhrystone (rv64gc), relinked with their code PAD bytes later (padding after .text.init), on both trees' smt2 RTL
# (tg_vsim from make perf's cache) and the model (rtl_m2 as d2 and as M6, smt2).
set -u
L=/home/w/tanager-build/smt2-study/layout
T=/home/w/tanager-build/smt2-study/brd_d4s2
mkdir -p $L/bin
for p in d2:7be52a3949b2559c d4s2:9c19d67cd557092d; do
  [ -x $L/bin/vsim_${p%%:*} ] || cp /home/w/tanager-build/cycle-identical/build/${p##*:}/tg_vsim $L/bin/vsim_${p%%:*}
done
cd $T && source tools/env.sh >/dev/null 2>&1
B=$T/tests/bench
TP=$T/perfmodel/third_party
[ -f $TP/coremark/core_main.c ] || TP=/home/w/tanager/perfmodel/third_party
ARCH="-march=rv64gc -mabi=lp64d"
LINK="$ARCH -mcmodel=medany -static -nostartfiles -Wl,--gc-sections -Wl,--no-warn-rwx-segments -I$B/bsp"
LINK="$LINK $B/bsp/crt0.S $B/bsp/syscalls.c"
CM_SRC="$TP/coremark/core_list_join.c $TP/coremark/core_main.c $TP/coremark/core_matrix.c $TP/coremark/core_state.c"
CM_SRC="$CM_SRC $TP/coremark/core_util.c $B/coremark/core_portme.c"
for pad in 0 32 64 128 256 512 1024 2048; do
  o=$L/pad$pad; mkdir -p $o/gen
  sed "s|\*(.text.init)|*(.text.init) . = . + $pad;|" $B/bsp/link.ld > $o/link.ld
  riscv-none-elf-gcc $LINK -T $o/link.ld -O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las -DPERFORMANCE_RUN=1 \
    -DITERATIONS=10 '-DFLAGS_STR="A"' -I$B/coremark -I$TP/coremark $CM_SRC -lm -o $o/coremark_A.elf || exit 1
  riscv-none-elf-gcc $LINK -T $o/link.ld -O3 -funroll-loops -DPERFORMANCE_RUN=1 -DITERATIONS=10 '-DFLAGS_STR="B"' \
    -I$B/coremark -I$TP/coremark $CM_SRC -lm -o $o/coremark_B.elf || exit 1
  python3 -I $T/perfmodel/bench/dhrystone/unshar.py $TP/dhrystone/dhry-c $o/gen > /dev/null
  riscv-none-elf-gcc $ARCH -mcmodel=medany -O3 -fno-common -fno-inline -std=gnu89 -w -DTIME -Dmain=dhry_main -I$o/gen \
    -c $o/gen/dhry_1.c -o $o/gen/dhry_1.o || exit 1
  riscv-none-elf-gcc $LINK -T $o/link.ld -O3 -fno-common -fno-inline -std=gnu89 -w -DTIME '-DTG_STDIN="500\n"' \
    -I$o/gen $o/gen/dhry_1.o $o/gen/dhry_2.c $B/dhrystone/dhry_time.c -lm -o $o/dhrystone.elf || exit 1
done
echo built
run() {  # side elf -> "cycles instret"
  $L/bin/vsim_$1 --quiet --timeout=1000000000 --lat=native $2 | grep -o "region_cycles=[0-9]* region_instret=[0-9]*" \
    | sed 's/region_cycles=//; s/region_instret=//'
}
for pad in 0 32 64 128 256 512 1024 2048; do
  for prog in coremark_A coremark_B dhrystone; do
    for s in d2 d4s2; do
      ( r=$(run $s $L/pad$pad/$prog.elf); echo "rtl $s pad$pad $prog $r" ) &
    done
  done
  wait
done > $L/rtl.txt
echo rtl done
