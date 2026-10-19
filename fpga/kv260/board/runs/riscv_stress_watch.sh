#!/bin/bash
# riscv_stress_watch.sh LOG: watch a stress run in RISC-V mode on the laptop's COM5 log (no SSH to the board in RISC-V mode): every
# 5 minutes, the passes, a failed pass, a STRESS FAIL/DMESG line, kernel trouble, or no new pass for 12 minutes (a
# hang: the PMOD break is the way out). It ends on the first of these and prints why.
L=$1; last=0; tlast=$(date +%s)
while true; do
  c() { tr -d '\r' < "$L" | grep -a "$@"; }
  n=$(c -c "STRESS pass"); f=$(c -c -E "STRESS (FAIL|DMESG)|STRESS pass .*fails=[1-9]")
  t=$(c -c -E "Oops|BUG:|Kernel panic|rcu_.*stall|rcu: INFO|soft lockup|hard LOCKUP|blocked for more than")
  [ "$n" -gt "$last" ] && { last=$n; tlast=$(date +%s); }
  if [ "$f" -gt 0 ] || [ "$t" -gt 0 ]; then date -u +%T; echo "FAILURE: passes $n, fail lines $f, trouble lines $t"; c -E "STRESS pass" | tail -2; exit 0; fi
  if [ $(( $(date +%s) - tlast )) -gt 720 ]; then date -u +%T; echo "NO NEW PASS FOR 12 MINUTES: passes $n"; tail -c 600 "$L" | tr -d '\r'; exit 0; fi
  sleep 300
done
