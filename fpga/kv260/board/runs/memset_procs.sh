#!/bin/sh
# memset_procs.sh: memset 1 MiB's speed process by process (10-23), on the RISC-V's Debian as root with nothing else
# running. On u100 the pinned rerun (store_rows.sh) gave CPU 0 572k and CPU 2 534k cycles/op, then 566k and 572k: the
# speed moved between processes, not CPUs. Each process here is tg-lbench memset -n 5 1048576 on CPU 2, its
# AnonHugePages read 0.6 s in (is the buffer in a 2 MiB page?): 8 processes with THP as set (Debian: always), then 4
# with THP never (restored after). Each line: the process's AnonHugePages and its five runs' cycles per operation.
B=/home/tanager/baseline/bin; O=$(mktemp)
pua=$(cat /proc/sys/kernel/perf_user_access); echo 2 > /proc/sys/kernel/perf_user_access
thp=$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/mm/transparent_hugepage/enabled)
one() {
  taskset -c 2 "$B/tg-lbench" memset -n 5 1048576 > "$O" & p=$!
  sleep 0.6; ahp=$(awk '/^AnonHugePages/ { print $2 }' /proc/$p/smaps_rollup 2>/dev/null); wait $p
  awk -v t="$1" -v a="$ahp" '$1 == "TGLB" { for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
    s = s sprintf(" %.0f", v["cycles"] / v["ops"]) } END { print t ": AnonHugePages " a " kB, cycles/op" s }' "$O"
}
echo "MODE-BEGIN thp=$thp"
for k in 1 2 3 4 5 6 7 8; do one "always $k"; done
echo never > /sys/kernel/mm/transparent_hugepage/enabled
for k in 1 2 3 4; do one "never $k"; done
echo "$thp" > /sys/kernel/mm/transparent_hugepage/enabled
echo "$pua" > /proc/sys/kernel/perf_user_access; rm -f "$O"
echo "MODE-END thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled) perf_user_access=$(cat /proc/sys/kernel/perf_user_access)"
