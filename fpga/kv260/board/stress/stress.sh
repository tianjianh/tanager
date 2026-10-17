#!/bin/bash
# Tanager two-core stress (board track). Each pass, every result checked against x86's:
#  - gcc -O2 builds t.c, which must print 5007905533300608;
#  - mt: two threads on one cache line, 4,000,000 atomic adds and 400,000 mutex-held adds;
#  - a 9-file project compiled two files at a time (xargs -P 2, as make -j2 would; make is not installed)
#    and linked, which must print 135808003256614222;
#  - sysbench cpu, memory and threads on two threads, 30 s each;
#  - new kernel messages that mean trouble (oops, BUG, panic, RCU stalls, lockups, hung tasks).
# One line per pass: "STRESS pass N ok=… fails=…". Type q on the console to stop after the current pass.
cd ~/stress || exit 1
T_EXP=5007905533300608; P_EXP=135808003256614222; M_EXP="mt ok 4000000 400000"
BAD='Oops|BUG:|Kernel panic|rcu_.*stall|rcu: INFO|watchdog: BUG|soft lockup|hard LOCKUP|segfault|Unable to handle|blocked for more than'
gcc -O2 -pthread -o mt mt.c || { echo "STRESS FAIL: mt does not build"; exit 1; }
n=0; fails=0; mark=$(sudo dmesg | wc -l)
echo "STRESS start $(date -u +%FT%TZ) up=$(cut -d' ' -f1 /proc/uptime)"
while :; do
  n=$((n+1)); t0=$(date +%s); ok=1
  r=$(gcc -O2 -o t t.c && ./t) || r="ERR $?"
  [ "$r" = "$T_EXP" ] || { ok=0; echo "STRESS FAIL pass $n: t printed '$r'"; }
  r=$(./mt) || r="ERR $?"
  [ "$r" = "$M_EXP" ] || { ok=0; echo "STRESS FAIL pass $n: mt printed '$r'"; }
  rm -f proj/p proj/*.o
  r=$(cd proj && ls *.c | xargs -P 2 -n 1 gcc -O2 -c && gcc -O2 -o p *.o && ./p) || r="ERR $?"
  [ "$r" = "$P_EXP" ] || { ok=0; echo "STRESS FAIL pass $n: proj printed '$r'"; }
  c=$(sysbench cpu --threads=2 --time=30 run | awk '/events per second/ {print $4}')
  m=$(sysbench memory --threads=2 --time=30 run | awk '/transferred/ {gsub("[(]", ""); print $4}')
  th=$(sysbench threads --threads=2 --time=30 run | awk '/total number of events/ {print $5}')
  [ -n "$c" ] && [ -n "$m" ] && [ -n "$th" ] || { ok=0; echo "STRESS FAIL pass $n: sysbench cpu=$c mem=$m thr=$th"; }
  now=$(sudo dmesg | wc -l); new=$(sudo dmesg | tail -n +$((mark + 1)) | grep -E "$BAD"); mark=$now
  [ -n "$new" ] && { ok=0; echo "STRESS DMESG pass $n:"; echo "$new" | head -8; }
  [ $ok = 1 ] || fails=$((fails + 1))
  echo "STRESS pass $n ok=$ok fails=$fails $(( $(date +%s) - t0 ))s cpu2=$c mem2=$m thr2=$th up=$(cut -d' ' -f1 /proc/uptime) load=$(cut -d' ' -f1-3 /proc/loadavg)"
  if read -r -t 1 -n 1 k && [ "$k" = q ]; then echo "STRESS stop after pass $n, fails=$fails"; break; fi
done
