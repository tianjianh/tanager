#!/bin/bash
# Builds the M9 planning kernels into build/bench/<isa>/m9.jsonl (docs/spec/m9-plan.md; scripts/m9_plan.py):
#   m9_interp_switch    a bytecode interpreter dispatching through a switch: one indirect jump takes every opcode
#   m9_interp_threaded  the same with computed goto: an indirect jump at the end of every opcode's handler
#   m9_misalign         misaligned loads and stores, 3,584 of each, to check tgsim's m9_counts counters
#   ISAS=rv64gc bash bench/build_m9.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"
R="$TG_ROOT"
ISAS="${ISAS:-rv64gc}"

for isa in $ISAS; do
  OUT="$R/build/bench/$isa"
  mkdir -p "$OUT"
  M="$OUT/m9.jsonl"
  : > "$M"
  add() { echo "{\"name\":\"$1\",\"group\":\"m9\",\"elf\":\"$OUT/$1.elf\",\"stdin\":\"\",\"ff\":0}" >> "$M"; }
  tg_link "$isa" "$OUT/m9_interp_switch.elf" -O2 -I"$R/bench/memsuite" -DTHREADED=0 -- "$R/bench/m9/interp.c"
  add m9_interp_switch
  tg_link "$isa" "$OUT/m9_interp_threaded.elf" -O2 -I"$R/bench/memsuite" -DTHREADED=1 -- "$R/bench/m9/interp.c"
  add m9_interp_threaded
  tg_link "$isa" "$OUT/m9_misalign.elf" -O2 -I"$R/bench/memsuite" -- "$R/bench/m9/misalign.c"
  add m9_misalign
  echo "$isa: $(wc -l < "$M") M9 workloads"
done
