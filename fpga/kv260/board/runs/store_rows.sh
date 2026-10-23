#!/bin/sh
# store_rows.sh: the coordinator's rerun of the two store-heavy DR-141 rows (10-23), on the RISC-V's Debian as root,
# with nothing else running. rc2's one set had memset 1 MiB +9.3% and the page-fault test +4.7% against u100; soc-2
# found no RTL cause, and in simulation only a busy sibling hart slows them. So each row runs 5 times, pinned to CPU 0
# and then to CPU 2 (one hart of each core, its sibling idle):
#   tg-lbench memset -n 5 1048576     tg-lbench pagefault -n 5 64
# The TGLB lines carry the cycle counts (tagged with the CPU); the last lines give each row's median cycles per
# operation per CPU, with the range over the five runs.
B=/home/tanager/baseline/bin; T=$(mktemp)
pua=$(cat /proc/sys/kernel/perf_user_access); echo 2 > /proc/sys/kernel/perf_user_access
echo "STOREROWS-BEGIN $(date -u +%FT%TZ) $(uname -r) online=$(cat /sys/devices/system/cpu/online) load=$(cut -d' ' -f1-3 /proc/loadavg)"
for c in 0 2; do
  taskset -c "$c" "$B/tg-lbench" memset -n 5 1048576 | sed "s/^TGLB /TGLB cpu$c /" | tee -a "$T"
  taskset -c "$c" "$B/tg-lbench" pagefault -n 5 64 | sed "s/^TGLB /TGLB cpu$c /" | tee -a "$T"
done
echo "$pua" > /proc/sys/kernel/perf_user_access
echo "== medians, cycles per operation"
awk '$1 == "TGLB" {
    delete v; for (i = 4; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
    if (v["ops"] > 0) { k = $2 " " $3; n[k]++; x[k, n[k]] = v["cycles"] / v["ops"] } }
  END { for (k in n) {
      m = n[k]; for (i = 1; i <= m; i++) a[i] = x[k, i]
      for (i = 2; i <= m; i++) { t = a[i]; j = i - 1; while (j > 0 && a[j] > t) { a[j + 1] = a[j]; j-- } a[j + 1] = t }
      printf "%s: median %.0f cycles/op over %d runs (%.0f to %.0f)\n", k, a[int((m + 1) / 2)], m, a[1], a[m] } }' "$T" | sort
rm -f "$T"
echo "STOREROWS-END $(date -u +%FT%TZ)"
