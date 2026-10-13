#!/bin/bash
# quick.sh <isa> <bench-regex> <preset> [preset ...] [-- --set k=v ...]: compact results per preset.
R="$(cd "$(dirname "$0")/.." && pwd)"
isa="$1"; re="$2"; shift 2
presets=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do presets+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
for p in "${presets[@]}"; do
  echo "== $p $*"
  python3 "$R/scripts/tgrun.py" --isa "$isa" --preset "$p" --bench "$re" "$@" | cut -c1-120
done
