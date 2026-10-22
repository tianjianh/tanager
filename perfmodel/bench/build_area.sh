#!/bin/bash
# Builds the area ideas' kernels into build/bench/<isa>/pa.jsonl (area_recovery.md §7.9, partial-address LQ/SQ search):
#   pa_copy<o>    64 pages copied a word at a time, the destination <o> bytes past its page boundary (0, 64)
#   pa_clear      64 pages cleared a word at a time
#   pa_memcpy<o>  the same copy with newlib's memcpy, a page at a time
#   ISAS=rv64gc bash bench/build_area.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"
R="$TG_ROOT"
ISAS="${ISAS:-rv64gc}"

for isa in $ISAS; do
  OUT="$R/build/bench/$isa"
  mkdir -p "$OUT"
  M="$OUT/pa.jsonl"
  : > "$M"
  add() { echo "{\"name\":\"$1\",\"group\":\"pa\",\"elf\":\"$OUT/$1.elf\",\"stdin\":\"\",\"ff\":0}" >> "$M"; }
  # no loop distribution: the copy and clear loops stay loops, not memcpy and memset calls
  F="-O2 -fno-tree-loop-distribute-patterns -I$R/bench/memsuite"
  for o in 0 64; do
    tg_link "$isa" "$OUT/pa_copy$o.elf" $F -DKIND=0 -DOFFSET=$o -- "$R/bench/area/pagecopy.c"
    add "pa_copy$o"
    tg_link "$isa" "$OUT/pa_memcpy$o.elf" $F -DKIND=2 -DOFFSET=$o -- "$R/bench/area/pagecopy.c"
    add "pa_memcpy$o"
  done
  tg_link "$isa" "$OUT/pa_clear.elf" $F -DKIND=1 -- "$R/bench/area/pagecopy.c"
  add pa_clear
  echo "$isa: $(wc -l < "$M") partial-address workloads"
done
