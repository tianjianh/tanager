#!/bin/bash
# riscv_soak_report.sh COM5LOG [NETLOG]: the numbers for a soak in RISC-V mode. From the stress lines on COM5, every
# pass's span by the guest's uptime (a pass starts at the previous pass's up=, the first at STRESS start's up=), and
# the steady figures over the passes that no network check overlapped: a check runs from its "guest up A-B s" in
# NETLOG, and a pass overlaps it when its span meets [A - MARGIN_S, B] (MARGIN_S, default 15 s, covers SSH's handshake
# before A in logs from before riscv_net_check.sh started A there). A pass's time is the stress's own (the guest's clock,
# comparable with earlier runs); where it disagrees with the uptime span by more than 3 s the clock was stepped
# (timesyncd's first sync), and that pass's time is left out of the mean. The network checks are listed on their own:
# count, failures, and the range of the transfer rates.
L=$1; N=${2:-/dev/null}
tr -d '\r' < "$L" | grep -a -o -E "STRESS (start|pass|stop|FAIL|DMESG).*" | awk -v net="$N" -v margin="${MARGIN_S:-15}" '
  BEGIN { while ((getline l < net) > 0) if (match(l, /guest up [0-9.]+-[0-9.]+ s/)) {
            split(substr(l, RSTART + 9, RLENGTH - 11), u, "-"); na++; a[na] = u[1]; b[na] = u[2] } }
  /^STRESS start/ { for (i = 1; i <= NF; i++) if ($i ~ /^up=/) prev = substr($i, 4) + 0; start = $3 }
  /^STRESS (FAIL|DMESG)/ { bad++ }
  /^STRESS pass/ {
    n = $3; if (n in seen) next; seen[n] = 1; np++
    for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
    up = v["up"] + 0; w = $6 + 0; d = (prev > 0) ? up - prev : w; t0 = up - d; prev = up
    if ($4 != "ok=1") nfail++
    ov = 0; for (j = 1; j <= na; j++) if (t0 <= b[j] && up >= a[j] - margin) ov = 1
    if (ov) { nov++; ovl = ovl " " n; next }
    k++; sd += d; sc += v["cpu2"]; sm += v["mem2"]; sh += v["thr2"]
    if (w - d > 3 || d - w > 3) { nst++; stl = stl " " n } else { kw++; sw += w; if (mn == "" || w < mn) mn = w; if (w > mx) mx = w }
  }
  /^STRESS stop/ { stop = $0 }
  END {
    printf "stress: STRESS start %s; %d passes, %d failed, %d FAIL/DMESG lines; last up %.0f s (%.1f h)\n", start, np, nfail, bad, prev, prev / 3600
    printf "overlapped by a network check, left out: %d passes (%s )\n", nov, ovl
    if (nst) printf "clock stepped during: %d passes (%s ), their times left out\n", nst, stl
    if (k) printf "steady (%d passes): %.1f s per pass (%d-%d; by uptime %.1f s with the loop'"'"'s 1 s wait for q), cpu %.2f events/s, memory %.2f MiB/s, threads %.0f events\n", k, sw / kw, mn, mx, sd / k, sc / k, sm / k, sh / k
    if (stop != "") print stop
  }'
[ -s "$N" ] || exit 0
awk '/ check [0-9]+ / { n++; if ($4 != "OK:") f++
       for (i = 1; i <= NF; i++) if ($i == "MB/s," || $i == "MB/s;") { r = $(i - 1) + 0
         if ($(i - 2) == "down") { if (dmn == "" || r < dmn) dmn = r; if (r > dmx) dmx = r } else { if (umn == "" || r < umn) umn = r; if (r > umx) umx = r } }
       if ($0 ~ /apt: exit 0,/) aok++ }
     END { printf "network checks: %d, failed %d; up %.2f-%.2f MB/s, down %.2f-%.2f MB/s; apt-get update exit 0 in %d of %d\n", n, f, umn, umx, dmn, dmx, aok, n }' "$N"
