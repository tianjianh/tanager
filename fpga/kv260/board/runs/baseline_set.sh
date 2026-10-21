#!/bin/bash
# baseline_set.sh N: one boot's share of the "d4r2 + PMP fix" Linux baseline (the coordinator, 10-21), on the RISC-V's
# Debian in RISC-V mode, as root (sudo bash), with nothing else running. Results go in ~tanager/baseline/boot_N/ and
# are printed between BASELINE-BEGIN and BASELINE-END.
#   1. The boot's timeline: the kernel's /init, systemd-analyze, the serial getty's start (the login on COM5).
#   2. The DR-141 set once (main's tg-lbench.sh 1 and its programs, built fresh: CoreMark A and B, Dhrystone, and their
#      rv64imafd bridge, plus the OS tests). The TGLB lines compare with stage C's by tests/bench/linux/tglb_compare.py.
#   3. The sc3/d4 workload (runs/bench_cmds.txt) without its network steps (the laptop's ICS serves no DHCP): gcc's
#      build and run, the stress's 9-file project build (stress/stress.sh's step, from ~/stress/proj), sysbench cpu on
#      1 and 2 threads, memory on 1 and 2 threads, threads on 2.
#   4. soc-2's memgap once.
N=$1; H=/home/tanager; D=$H/baseline/boot_$N
mkdir -p "$D" && cd "$D" || exit 1
{
echo "BASELINE-BEGIN boot $N $(date -u +%FT%TZ) up $(cut -d' ' -f1 /proc/uptime)"
echo "== timeline"
dmesg | grep -m1 "Run /init as init process"
systemd-analyze 2>&1 | head -1
echo "serial-getty@ttyS0 active at $(systemctl show serial-getty@ttyS0.service -p ActiveEnterTimestampMonotonic --value) us after boot"
echo "multi-user.target active at $(systemctl show multi-user.target -p ActiveEnterTimestampMonotonic --value) us after boot"
uname -r; grep -c ^processor /proc/cpuinfo; cat /proc/cmdline
echo "== DR-141 set (tg-lbench.sh 1)"
pua=$(cat /proc/sys/kernel/perf_user_access)
PATH=$H/baseline/bin:$PATH sh $H/baseline/bin/tg-lbench.sh 1
echo "$pua" > /proc/sys/kernel/perf_user_access   # back to what it was before tg-lbench.sh set 2
echo "== the sc3/d4 workload"
cd /tmp && printf '%s\n' '#include <stdio.h>' 'int main(void){unsigned long s=0;for(unsigned long i=0;i<100000000UL;i++)s+=i^(i>>3);printf("%lu\n",s);return 0;}' > t.c
{ time gcc -O2 -o t t.c; } 2>&1 | grep -E "real|user|sys" | tr '\n' ' ' | sed 's/^/gcc build: /'; echo
{ time ./t; } 2>&1 | tr '\n' ' ' | sed 's/^/run: /'; echo
rm -f t t.c; cd "$D"
P=$(mktemp -d /tmp/proj.XXXXXX) && cp $H/stress/proj/*.c "$P"/ && cd "$P"
{ time sh -c 'ls *.c | xargs -P 2 -n 1 gcc -O2 -c && gcc -O2 -o p *.o'; } 2>&1 | grep -E "real|user|sys" | tr '\n' ' ' | sed 's/^/proj build, 9 files two at a time: /'; echo
echo "proj prints $(./p) (the stress expects 135808003256614222)"
rm -f "$P"/*; rmdir "$P"; cd "$D"
echo "sysbench cpu 1 thread: $(sysbench cpu --threads=1 --time=20 run | grep -E 'events per second')"
echo "sysbench cpu 2 threads: $(sysbench cpu --threads=2 --time=20 run | grep -E 'events per second')"
echo "sysbench memory 1 thread: $(sysbench memory --time=20 run | grep -E 'transferred')"
echo "sysbench memory 2 threads: $(sysbench memory --threads=2 --time=20 run | grep -E 'transferred')"
echo "sysbench threads 2 threads: $(sysbench threads --threads=2 --time=10 run | grep -E 'total number of events')"
echo "== memgap"
$H/memgap/memgap
echo "BASELINE-END boot $N $(date -u +%FT%TZ) up $(cut -d' ' -f1 /proc/uptime)"
} 2>&1 | tee "$D/baseline_boot_$N.txt"
chown -R tanager:tanager "$H/baseline"
