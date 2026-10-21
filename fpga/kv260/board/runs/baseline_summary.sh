#!/bin/bash
# baseline_summary.sh BOOTFILE...: the Linux baseline's figures from baseline_set.sh's outputs (one file per boot), as
# Markdown rows: each boot's value, then the mean and the spread ((max - min) / mean) over the boots. The DR-141 rows
# (TGLB lines) are tests/bench/linux/tglb_compare.py's, on the build host; the boot's serial timeline is
# boot_timeline.sh's. Text only: it runs anywhere.
awk '
function add(k, v) { if (!(k in seen)) { seen[k] = 1; order[++nk] = k } val[k, FILENAME] = v }
function secs(s,   m) { m = 0; if (match(s, /[0-9]+m/)) m = substr(s, RSTART, RLENGTH - 1) * 60; sub(/^.*m/, "", s); return m + s }
FNR == 1 { files[++nf] = FILENAME }
/^\[ *[0-9.]+\] Run \/init as init process/ { match($0, /[0-9]+\.[0-9]+/); add("kernel stamp at /init (s)", substr($0, RSTART, RLENGTH)) }
/^Startup finished in/ {
  t = $0; sub(/^Startup finished in /, "", t); split(t, p, / \+ | = /)
  for (i in p) { u = p[i]; s = 0
    if (match(u, /[0-9]+min/)) s += substr(u, RSTART, RLENGTH - 3) * 60
    if (match(u, /[0-9.]+s/)) s += substr(u, RSTART, RLENGTH - 1)
    if (u ~ /\(kernel\)/) add("systemd-analyze: kernel (s)", s)
    else if (u ~ /\(initrd\)/) add("systemd-analyze: initrd (s)", s)
    else if (u ~ /\(userspace\)/) add("systemd-analyze: userspace (s)", s)
    else add("systemd-analyze: total (s)", s) } }
/^serial-getty@ttyS0 active at/ { add("ttyS0 getty active (s after boot)", $4 / 1e6) }
/^multi-user.target active at/ { add("multi-user.target (s after boot)", $4 / 1e6) }
/^gcc build:/ { add("gcc -O2 t.c, real (s)", secs($4)); add("gcc -O2 t.c, user + sys (s)", secs($6) + secs($8)) }
/^run: / { add("./t, 100 M iterations, real (s)", secs($4)) }
/^proj build/ { for (i = 1; i <= NF; i++) { if ($i == "real") r = $(i + 1); if ($i == "user") us = $(i + 1); if ($i == "sys") sy = $(i + 1) }
  add("9-file project, 2 at a time, real (s)", secs(r)); add("9-file project, user + sys (s)", secs(us) + secs(sy)) }
/^sysbench cpu 1 thread:/ { add("sysbench cpu, 1 thread (events/s)", $NF) }
/^sysbench cpu 2 threads:/ { add("sysbench cpu, 2 threads (events/s)", $NF) }
/^sysbench memory 1 thread:/ { v = $0; sub(/^.*\(/, "", v); add("sysbench memory 1 KiB, 1 thread (MiB/s)", v + 0) }
/^sysbench memory 2 threads:/ { v = $0; sub(/^.*\(/, "", v); add("sysbench memory 1 KiB, 2 threads (MiB/s)", v + 0) }
/^sysbench threads 2 threads:/ { add("sysbench threads, 2 threads, 10 s (events)", $NF) }
/^MEMGAP [a-z0-9]+ [0-9.]+ / { add("memgap " $2 " (" $4 ")", $3) }
END {
  h = "| | "; for (f = 1; f <= nf; f++) h = h "boot " f " | "; print h "mean | spread |"
  h = "|---|"; for (f = 1; f <= nf; f++) h = h "---|"; print h "---|---|"
  for (i = 1; i <= nk; i++) {
    k = order[i]; row = "| " k " | "; n = 0; sum = 0; lo = ""; hi = ""
    for (f = 1; f <= nf; f++) {
      if ((k, files[f]) in val) { v = val[k, files[f]]; row = row v " | "; n++; sum += v
        if (lo == "" || v < lo) lo = v; if (hi == "" || v > hi) hi = v }
      else row = row "- | " }
    m = n ? sum / n : 0
    fm = m >= 1000 ? "%.0f" : m >= 100 ? "%.1f" : m >= 1 ? "%.2f" : "%.3f"
    print row (n ? sprintf(fm, m) : "-") " | " (n > 1 && m != 0 ? sprintf("%.1f%%", 100 * (hi - lo) / m) : "-") " |"
  } }' "$@"
