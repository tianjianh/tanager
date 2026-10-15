#!/bin/sh
# The Linux workload set (DR-141; docs/spec/verification.md §4.6): every test RUNS times (3), one
# TGLB line per run, between a TGLB-BEGIN and a TGLB-END line. Run as root: it opens the cycle
# counter to user mode where the kernel allows it.
#   tg-lbench.sh [RUNS]
R=${1:-3}
rc=0
# User-mode rdcycle needs the SBI PMU driver and its legacy access mode (tglb.h).
[ -w /proc/sys/kernel/perf_user_access ] && echo 2 > /proc/sys/kernel/perf_user_access
echo "TGLB-BEGIN version=1 kernel=$(uname -r) harts=$(grep -c ^processor /proc/cpuinfo) runs=$R"
step() { "$@" || { echo "TGLB-FAIL $*"; rc=1; }; }
step tg-lbench info
step tg-lbench forkexec -n "$R" 1000 /bin/true
step tg-lbench syscall -n "$R" 1000000
for s in 64 4K 1M; do
  step tg-lbench memcpy -n "$R" "$s"
  step tg-lbench memset -n "$R" "$s"
done
step tg-lbench pipe -n "$R" 64K 16M
step tg-lbench tmpfs -n "$R" 64K 16M /tmp/tglb.dat
step tg-lbench pagefault -n "$R" 64
step tg-lbench tlbwalk -n "$R" 64 1000000
step tg-lbench gen /tmp/tglb.txt 4
step tg-lbench exec -n "$R" -l gzip -- gzip -c /tmp/tglb.txt
step tg-lbench exec -n "$R" -l sha256sum -- sha256sum /tmp/tglb.txt
rm -f /tmp/tglb.txt
k=1
while [ "$k" -le "$R" ]; do
  step coremark-a 0 "$k"   # 0: CoreMark runs at least 10 s, its condition for a valid result
  step coremark-b 0 "$k"
  step dhrystone 1000000 "$k"
  k=$((k + 1))
done
echo "TGLB-END status=$rc"
exit $rc
