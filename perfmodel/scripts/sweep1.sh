#!/bin/bash
# sweep1.sh <isa> <bench-regex> <preset> <param> "<values>" [extra --set k=v ...]: one-parameter sweep.
R="$(cd "$(dirname "$0")/.." && pwd)"
isa="$1"; re="$2"; preset="$3"; param="$4"; values="$5"; shift 5
for v in $values; do
  echo "== $param=$v $*"
  python3 "$R/scripts/tgrun.py" --isa "$isa" --preset "$preset" --bench "$re" --set "$param=$v" "$@" | cut -c1-118
done
