#!/bin/bash
# ddr_write2.sh: soc-2's two checks after u100's DDR write streaming read 14% below d4r2's (10-23), on the RISC-V's
# Debian with nothing else running (as tanager or root):
#   1. memgap's single-thread rows on each CPU (taskset -c 0 to 3): are the four harts symmetric?
#   2. DDR writes with one thread and with two, each thread on its own 16 MiB buffer, to see whether DDR writes
#      saturate:
#      - sysbench memory (16 MiB blocks, writes, local scope: one buffer per thread), pinned to one CPU, to two cores
#        (CPUs 0 and 2) and to one core (CPUs 0 and 1);
#      - two memgap processes at once, pinned to CPUs 0 and 2, whose wr16m tests overlap (each test runs 2 s in the
#        same order), beside one alone.
H=/home/tanager; M=$H/memgap/memgap; D=$(mktemp -d /tmp/ddrw2.XXXXXX)
echo "DDRW2-BEGIN $(date -u +%FT%TZ) online=$(cat /sys/devices/system/cpu/online)"
echo "== 1. memgap's single-thread rows on each CPU"
for c in $(seq 0 $(( $(nproc) - 1 ))); do
  echo "cpu$c: $(taskset -c $c $M -i 0 -t 1 | awk '/^MEMGAP (clock|rdtime|wr1k|wr1m|wr16m|rd16m|chase16k|chase256k|chase64m|ev1) / { printf "%s=%s ", $2, $3 }')"
done
echo "== 2a. DDR writes, 16 MiB per thread (sysbench memory: 16 MiB blocks, writes, local scope, 10 s)"
for p in "0:one thread" "0,2:two threads on two cores" "0,1:two threads on one core"; do
  c=${p%%:*}; n=$(echo "$c" | tr ',' '\n' | wc -l)
  echo "${p#*:} (CPUs $c): $(taskset -c "$c" sysbench memory --memory-block-size=16M --memory-total-size=10T --memory-scope=local --memory-oper=write --threads=$n --time=10 run | grep -E 'transferred')"
done
echo "== 2b. memgap's wr16m: one process alone, then two at once on CPUs 0 and 2"
echo "alone on cpu0: wr16m $(taskset -c 0 $M -i 0 -t 2 | awk '/^MEMGAP wr16m/ { print $3 }') MiB/s"
taskset -c 0 $M -i 0 -t 2 > "$D/mg0.txt" & p0=$!
taskset -c 2 $M -i 0 -t 2 > "$D/mg2.txt"; wait $p0
a=$(awk '/^MEMGAP wr16m/ { print $3 }' "$D/mg0.txt"); b=$(awk '/^MEMGAP wr16m/ { print $3 }' "$D/mg2.txt")
echo "two at once: cpu0 wr16m $a, cpu2 wr16m $b MiB/s, together $(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.1f", a + b }') MiB/s"
rm -f "$D"/mg0.txt "$D"/mg2.txt; rmdir "$D"
echo "DDRW2-END $(date -u +%FT%TZ)"
