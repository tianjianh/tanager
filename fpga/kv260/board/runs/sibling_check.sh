#!/bin/bash
# sibling_check.sh: soc-2's sibling check for the 16 MiB write gap (memgap wr16m 156 MiB/s on u100 and rc2 against
# d4r2's 182; 10-23), on the RISC-V's Debian as root with nothing else running. memgap's wr1m and wr16m on CPU 0,
# three times with CPU 0's thread sibling online and three times with it offline (the sibling back online after).
# While each run's wr16m runs (memgap has printed its wr1m line), the process's AnonHugePages is read from smaps_rollup:
# does the 16 MiB buffer sit in 2 MiB pages?
H=/home/tanager; M=$H/memgap/memgap; O=$(mktemp)
sib=$(tr ',-' '\n\n' < /sys/devices/system/cpu/cpu0/topology/thread_siblings_list | grep -v -x 0 | head -1)
echo "SIBCHECK-BEGIN $(date -u +%FT%TZ) cpu0's thread siblings: $(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list) (the other: cpu$sib)"
run() {
  taskset -c 0 "$M" -i 0 -t 2 > "$O" 2>&1 & local p=$! ahp=-
  while kill -0 $p 2>/dev/null; do
    if [ "$ahp" = - ] && grep -q "^MEMGAP wr1m" "$O"; then sleep 0.5; ahp=$(awk '/^AnonHugePages/ { print $2 }' /proc/$p/smaps_rollup 2>/dev/null); fi
    sleep 0.2
  done
  echo "$1: wr1m $(awk '/^MEMGAP wr1m/ { print $3 }' "$O") wr16m $(awk '/^MEMGAP wr16m/ { print $3 }' "$O") MiB/s, AnonHugePages during wr16m ${ahp} kB"
}
for k in 1 2 3; do run "sibling online, run $k"; done
echo 0 > /sys/devices/system/cpu/cpu$sib/online; echo "cpu$sib offline: online $(cat /sys/devices/system/cpu/online)"
for k in 1 2 3; do run "sibling offline, run $k"; done
echo 1 > /sys/devices/system/cpu/cpu$sib/online; echo "cpu$sib back online: online $(cat /sys/devices/system/cpu/online)"
rm -f "$O"
echo "SIBCHECK-END $(date -u +%FT%TZ)"
