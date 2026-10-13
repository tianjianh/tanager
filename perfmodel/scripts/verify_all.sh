#!/bin/bash
# Functional check of every workload on every built ISA (tgsim's ISS only).
R="$(cd "$(dirname "$0")/.." && pwd)"
status=0
for isa in ${ISAS:-rv64gc rv64gcb rv32im}; do
  echo "== $isa"
  python3 "$R/scripts/tgrun.py" --isa "$isa" --iss-only | grep -v ' OK$' || true
  python3 "$R/scripts/tgrun.py" --isa "$isa" --iss-only > /dev/null || status=1
done
exit $status
