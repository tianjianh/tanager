#!/bin/bash
# hart_check.sh TAG: one RISC-V-mode boot's health check for a new hart layout (the four-hart bring-up, 10-22), on the
# RISC-V's Debian as root, with nothing else running. The board runs without the lockstep checker, so wrong results
# have to show up in self-checking work: every line ends in PASS or FAIL, and the last line counts the FAILs.
#   1. Who is up: the kernel, the harts (Linux's CPU number against /proc/cpuinfo's hart id), the timeline.
#   2. Kernel messages that mean trouble since boot (oops, BUG, panics, RCU stalls, lockups, hung tasks, SBI/HSM
#      errors, CPUs that failed to come up).
#   3. On each hart alone (taskset): CoreMark A, which validates its own CRCs, and t.c's loop, which must print
#      5007905533300608.
#   4. On each pair of harts, on one core and across cores: the stress's mt.c (two threads on one cache line,
#      atomic and mutex-held adds; it must print "mt ok 4000000 400000"), and memgap's pingpong time. mt runs
#      under taskset; memgap pins its own two threads, so it is given the pair with -c (main 4fe536ec on; before
#      that it always used CPUs 0 and 1, one core's two harts on a four-hart tree).
#   5. All harts at once: the stress's 9-file project built N files at a time (it must print 135808003256614222),
#      and sysbench cpu and threads on N threads.
# Uses ~/baseline/bin (the DR-141 programs), ~/stress (t.c, mt.c, proj/) and ~/memgap/memgap; results in
# ~/hartcheck/TAG/.
T=${1:-check}; H=/home/tanager; D=$H/hartcheck/$T
mkdir -p "$D" && cd "$D" || exit 1
fails=0
ok() { echo "$1 PASS${2:+ $2}"; }
bad() { echo "$1 FAIL${2:+ $2}"; fails=$((fails + 1)); }
{
echo "HARTCHECK-BEGIN $T $(date -u +%FT%TZ) up $(cut -d' ' -f1 /proc/uptime)"
uname -r; cat /proc/cmdline
n=$(nproc); echo "online CPUs: $(cat /sys/devices/system/cpu/online) (nproc $n)"
# Linux CPU number -> hart id, in /proc/cpuinfo's order
awk -F': *' '/^processor/ { c = $2 } /^hart[ 	]*:/ { print c, $2 }' /proc/cpuinfo > harts.txt
while read -r c h; do echo "cpu$c = hart $h, siblings $(cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list 2>/dev/null)"; done < harts.txt
dmesg | grep -m1 "Run /init as init process"; systemd-analyze 2>&1 | head -1
echo "== kernel messages"
dmesg > dmesg.txt
# HC_DMESG_FROM=N skips the boot's first N kernel lines: a soak passes the count at its step's start, so that a line
# already counted in an earlier step doesn't fail every later one. Default 0: the whole boot.
TROUBLE="Oops|BUG:|Kernel panic|rcu.*(stall|detected)|soft lockup|hard lockup|hung_task|blocked for more than|Unable to handle|sbi.*(fail|error)|hsm.*(fail|error)|failed to (start|come online)|CPU[0-9]+: failed"
k=$(tail -n +$(( ${HC_DMESG_FROM:-0} + 1 )) dmesg.txt | grep -c -i -E "$TROUBLE")
[ "$k" = 0 ] && ok "dmesg" "no trouble lines${HC_DMESG_FROM:+ after line $HC_DMESG_FROM}" || { bad "dmesg" "$k trouble lines:"; tail -n +$(( ${HC_DMESG_FROM:-0} + 1 )) dmesg.txt | grep -i -E "$TROUBLE" | head -20; }
grep -E "smp: |SBI|riscv-pmu|timebase|clocksource" dmesg.txt | head -12
echo "== each hart alone"
printf '%s\n' '#include <stdio.h>' 'int main(void){unsigned long s=0;for(unsigned long i=0;i<100000000UL;i++)s+=i^(i>>3);printf("%lu\n",s);return 0;}' > t.c
gcc -O2 -o t t.c && cp $H/stress/mt.c . && gcc -O2 -pthread -o mt mt.c || bad "build" "t.c or mt.c does not build"
while read -r c h; do
  out=$(taskset -c "$c" $H/baseline/bin/coremark-a 0 1 2>&1)
  ips=$(echo "$out" | awk -F': *' '/Iterations\/Sec/ { print $2 }')
  echo "$out" | grep -q "Correct operation validated" && ok "coremark-a cpu$c (hart $h)" "$ips iterations/s" || bad "coremark-a cpu$c (hart $h)" "$(echo "$out" | grep -i -E "error|valid" | head -3 | tr '\n' ' ')"
  s=$(date +%s.%N); r=$(taskset -c "$c" ./t); e=$(awk -v a="$s" -v b="$(date +%s.%N)" 'BEGIN { printf "%.2f", b - a }')
  [ "$r" = 5007905533300608 ] && ok "t cpu$c (hart $h)" "$e s" || bad "t cpu$c (hart $h)" "printed $r"
done < harts.txt
echo "== pairs of harts"
cpus=$(cut -d' ' -f1 harts.txt | tr '\n' ' ')
for a in $cpus; do for b in $cpus; do
  [ "$a" -lt "$b" ] || continue
  r=$(taskset -c "$a,$b" ./mt 2>&1 | tail -1)
  [ "$r" = "mt ok 4000000 400000" ] && ok "mt cpu$a+cpu$b" || bad "mt cpu$a+cpu$b" "printed '$r'"
  p=$($H/memgap/memgap -c "$a,$b" -i 0 -t 0.5 2>&1 | awk '/^MEMGAP pingpong/ { print $3 }')
  echo "pingpong cpu$a+cpu$b: $p ns/round-trip"
done; done
echo "== all harts at once"
P=$(mktemp -d /tmp/proj.XXXXXX) && cp $H/stress/proj/*.c "$P"/ && cd "$P"
s=$(date +%s.%N); ls *.c | xargs -P "$n" -n 1 gcc -O2 -c && gcc -O2 -o p *.o; e=$(awk -v a="$s" -v b="$(date +%s.%N)" 'BEGIN { printf "%.2f", b - a }')
r=$(./p 2>&1); [ "$r" = 135808003256614222 ] && ok "proj, $n at a time" "$e s" || bad "proj, $n at a time" "printed '$r'"
rm -f "$P"/*; rmdir "$P"; cd "$D"
echo "sysbench cpu, $n threads: $(sysbench cpu --threads=$n --time=10 run | grep -E 'events per second')"
echo "sysbench threads, $n threads: $(sysbench threads --threads=$n --time=10 run | grep -E 'total number of events')"
k2=$(dmesg | wc -l); k1=$(wc -l < dmesg.txt)
[ "$k2" -le "$k1" ] && ok "dmesg after the checks" "no new lines" || { echo "new kernel lines during the checks:"; dmesg | tail -n +$((k1 + 1)) | head -20; dmesg | tail -n +$((k1 + 1)) | grep -q -i -E "$TROUBLE" && bad "dmesg after the checks" "trouble" || ok "dmesg after the checks" "new lines, none of them trouble"; }
echo "HARTCHECK-END $T fails=$fails $(date -u +%FT%TZ) up $(cut -d' ' -f1 /proc/uptime)"
} 2>&1 | tee "$D/hartcheck_$T.txt"
chown -R tanager:tanager "$H/hartcheck"
