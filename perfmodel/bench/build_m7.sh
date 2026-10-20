#!/bin/bash
# Builds M7's check programs into build/bench/<isa>/m7.jsonl (docs/spec/m7-smt2-plan.md):
#   m7_fprestore  a context switch's FP restore (32 flds in a row) between blocks of FP work (D3's free lists)
#   m7_fprestore2 the same with 64 flds a block (two harts holding all their f registers in F1)
#   ISAS=rv64gc bash bench/build_m7.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"
R="$TG_ROOT"
ISAS="${ISAS:-rv64gc}"

for isa in $ISAS; do
  OUT="$R/build/bench/$isa"
  mkdir -p "$OUT"
  tg_link "$isa" "$OUT/m7_fprestore.elf" -O2 -I"$R/bench/memsuite" -- "$R/bench/m7/fprestore.c"
  tg_link "$isa" "$OUT/m7_fprestore2.elf" -O2 -DPASSES=2 -I"$R/bench/memsuite" -- "$R/bench/m7/fprestore.c"
  echo "{\"name\":\"m7_fprestore\",\"group\":\"m7\",\"elf\":\"$OUT/m7_fprestore.elf\",\"stdin\":\"\",\"ff\":0}" \
    > "$OUT/m7.jsonl"
  echo "{\"name\":\"m7_fprestore2\",\"group\":\"m7\",\"elf\":\"$OUT/m7_fprestore2.elf\",\"stdin\":\"\",\"ff\":0}" \
    >> "$OUT/m7.jsonl"
  echo "$isa: m7 workloads built"
done
