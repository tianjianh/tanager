#!/bin/bash
# Builds tests/hello.c for each ISA, runs it on tgsim (functional and timing) and compares the output
# with a native build of the same source.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/bench/toolchain.sh"
OUT="$HERE/build/tests"
mkdir -p "$OUT"
gcc-15 -O2 -DTG_NATIVE -o "$OUT/hello_native" "$HERE/tests/hello.c"
"$OUT/hello_native" > "$OUT/expected.txt"
status=0
for isa in rv64gc rv64gcb rv32im rv32imac; do
  tg_link "$isa" "$OUT/hello_$isa.elf" -O2 -- "$HERE/tests/hello.c"
  "$HERE/build/tgsim" --iss-only "$OUT/hello_$isa.elf" 2> "$OUT/iss_$isa.txt" > /dev/null || true
  for preset in tanager_v1 nax; do
    "$HERE/build/tgsim" --preset "$preset" --json "$OUT/hello_${isa}_$preset.json" "$OUT/hello_$isa.elf" || true
  done
  if diff -q "$OUT/expected.txt" "$OUT/iss_$isa.txt" > /dev/null; then echo "$isa: output matches native"
  else echo "$isa: OUTPUT DIFFERS"; diff "$OUT/expected.txt" "$OUT/iss_$isa.txt" || true; status=1; fi
  python3 - "$OUT" "$isa" <<'EOF'
import json, sys
out, isa = sys.argv[1], sys.argv[2]
for p in ("tanager_v1", "nax"):
    r = json.load(open(f"{out}/hello_{isa}_{p}.json"))
    g = r["region"]
    print(f"  {p:11s} exit={r['exit_code']} err='{r['error']}' region: instr={g['instr']} cycles={g['cycles']} "
          f"ipc={g['instr']/max(1,g['cycles']):.3f} total_instr={r['total']['instr']}")
EOF
done
exit $status
