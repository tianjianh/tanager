#!/bin/sh
# memgap_set.sh MODE: soc-2's memory-gap set on the RISC-V's Debian (sw/d4mode/memgap.c; soc-d4-modes.md, "RISC-V
# mode's memory gap"), the same in RISC-V mode and stage C on one bitstream. ~/memgap/memgap must be built already
# (gcc -O2 -pthread -o memgap memgap.c).
# - The probe's watch is stopped first (it returns at the next boot), so nothing else runs.
# - memgap runs three times.
# - Then sysbench memory, 20 s each, at 1 KiB and 1 MiB blocks: two threads global (sysbench's default), two threads
#   local, and one thread.
# - In stage C a last 60 s run at 1 MiB blocks follows a MEMGAP-BRIDGE-NOW line, so the A53 can read the host
#   bridge's DDR latency meanwhile (ps-memregs --bridge).
# Results go in ~/memgap/: memgap_MODE_N.txt and sysbench_MODE.txt, and all of them are printed at the end between
# MEMGAP-FILES-BEGIN and MEMGAP-FILES-END, so the console log holds them too.
M=$1; D=$HOME/memgap
cd "$D" || exit 1
sudo pkill -f "^/bin/sh /sd1-irq-probe watch"; sleep 1
echo "MEMGAP-SET $M start $(date -u +%FT%TZ) up $(cut -d' ' -f1 /proc/uptime), watches left $(pgrep -c -f '^/bin/sh /sd1-irq-probe watch')"
for n in 1 2 3; do ./memgap > "memgap_${M}_$n.txt" 2>&1; echo "memgap run $n exit $?"; done
S="sysbench_$M.txt"; : > "$S"
for b in 1K 1M; do
  for a in "--threads=2" "--threads=2 --memory-scope=local" "--threads=1"; do
    r=$(sysbench memory --memory-block-size=$b $a --time=20 run | grep -E "transferred")
    echo "block $b $a: $r" >> "$S"
  done
done
if [ "$M" = stagec ]; then
  echo "MEMGAP-BRIDGE-NOW"
  r=$(sysbench memory --memory-block-size=1M --threads=2 --time=60 run | grep -E "transferred")
  echo "block 1M --threads=2 --time=60 (with the A53's ps-memregs --bridge): $r" >> "$S"
fi
echo "MEMGAP-FILES-BEGIN"
for f in memgap_${M}_*.txt "$S"; do echo "== $f"; cat "$f"; done
echo "MEMGAP-FILES-END"
echo "MEMGAP-SET $M end $(date -u +%FT%TZ)"
