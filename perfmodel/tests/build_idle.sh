#!/bin/bash
# Builds tests/idle.c (the near-idle SMT sibling used by scripts/smt.py --validate) -> build/tests/idle_rv64gc.elf
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/bench/toolchain.sh"
tg_link rv64gc "$HERE/build/tests/idle_rv64gc.elf" -O2 -- "$HERE/tests/idle.c"
"$HERE/build/tgsim" --preset v1_freeze --json /dev/stdout "$HERE/build/tests/idle_rv64gc.elf" |
  python3 -c "import json,sys; r=json.load(sys.stdin); g=r['region']; print('idle:', g['instr'], 'instructions,', g['cycles'], 'cycles, error:', repr(r['error']))"
