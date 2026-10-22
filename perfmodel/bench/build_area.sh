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
  # pa2.jsonl (§7.10): 64 KiB copies a set distance apart, and counter updates scattered over a table
  M="$OUT/pa2.jsonl"
  : > "$M"
  for o in 0 8 32 64 128 160 192 256 512 2048 4032; do   # 17 pages + o: the low 12 bits o apart, the low 16 not
    tg_link "$isa" "$OUT/pd_copy17p$o.elf" $F -DKIND=0 -DDIST="((17u<<12)+${o}u)" -- "$R/bench/area/copydist.c"
    add "pd_copy17p$o"
  done
  for d in 16 256; do   # 16 pages (64 KiB) and 256 pages (1 MiB) + 64: the low 16 bits, or the low 20, 64 apart
    tg_link "$isa" "$OUT/pd_copy${d}p64.elf" $F -DKIND=0 -DDIST="((${d}u<<12)+64u)" -- "$R/bench/area/copydist.c"
    add "pd_copy${d}p64"
    tg_link "$isa" "$OUT/pd_memcpy${d}p64.elf" $F -DKIND=2 -DDIST="((${d}u<<12)+64u)" -- "$R/bench/area/copydist.c"
    add "pd_memcpy${d}p64"
  done
  for t in 10 16 20; do   # 4 KiB (one page), 256 KiB and 4 MiB of counters
    tg_link "$isa" "$OUT/pd_scatter$t.elf" $F -DTABLE_LOG=$t -- "$R/bench/area/scatter.c"
    add "pd_scatter$t"
  done
  echo "$isa: $(wc -l < "$M") partial-address workloads in pa2"
done
