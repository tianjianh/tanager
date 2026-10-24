#!/bin/sh
# soak_rows.sh DIR...: memset 1 MiB's and the page-fault test's cycles per operation in every DR-141 set a soak kept
# (DIR/rN_{A,B,C}.tglb; A: the set on CPUs 2-3 beside the stress on 0-1, B: the reverse, C: both unpinned), per step:
# the count, the median and the range.
for d in "$@"; do
  for f in "$d"/r*_[ABC].tglb; do
    s=$(basename "$f" .tglb); s=${s##*_}
    awk -v s="$s" -v d="$(basename "$d")" '$1 == "TGLB" && ($2 == "memset-1048576" || $2 == "pagefault") {
      for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
      if (v["ops"] > 0) printf "%s %s %s %.1f\n", d, $2, s, v["cycles"] / v["ops"] }' "$f"
  done
done | sort -k1,1 -k2,2 -k3,3 -k4,4n | awk '{ k = $1 " " $2 " " $3; n[k]++; x[k, n[k]] = $4; if (!(k in o)) { o[k] = ++m; K[m] = k } }
  END { for (j = 1; j <= m; j++) { k = K[j]; c = n[k]; printf "%s: n=%d median %.0f (%.0f to %.0f)\n", k, c, (c % 2 ? x[k, (c + 1) / 2] : (x[k, c / 2] + x[k, c / 2 + 1]) / 2), x[k, 1], x[k, c] } }'
