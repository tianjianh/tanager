#!/bin/bash
# Builds the working-set kernels into build/bench/<isa>/ws.jsonl: DR-141's Linux-like working sets of 0.5-4 MiB,
# which the DSE suite lacks (its kernels fit the L1s, its memsuite needs 8-32 MiB). Each runs without fast-forward
# and touches its data before the region, so the region starts with as much of the working set cached as fits.
#   ws_chase1_<k>  one random pointer chain over <k> KiB of 64-byte nodes (latency)
#   ws_chase8_<k>  eight chains over <k> KiB (memory-level parallelism)
#   ws_hash_<k>    lookups in a <k> KiB open-addressing hash table, half full (random reads, branches)
#   ws_copy_<k>    memcpy within <k> KiB (source and destination half each), about 2 MiB copied per region
#   ISAS=rv64gc bash bench/build_ws.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"
R="$TG_ROOT"
ISAS="${ISAS:-rv64gc}"

for isa in $ISAS; do
  OUT="$R/build/bench/$isa"
  mkdir -p "$OUT"
  M="$OUT/ws.jsonl"
  : > "$M"
  add() { echo "{\"name\":\"$1\",\"group\":\"ws\",\"elf\":\"$OUT/$1.elf\",\"stdin\":\"\",\"ff\":0,\"meta\":{\"kib\":$2}}" >> "$M"; }
  ms="$R/bench/memsuite"
  for k in 512 1024 2048 4096; do
    log=$(( $(printf '%s' "$k" | awk '{print int(log($1 * 128) / log(2) + 0.5)}') ))  # 8-byte slots in k KiB
    tg_link "$isa" "$OUT/ws_chase1_$k.elf" -O2 -I"$ms" -DCHAINS=1 -DHOPS=4000 -DFOOTPRINT_KB=$k -DWARM=1 -- "$ms/chase.c"
    add "ws_chase1_$k" $k
    tg_link "$isa" "$OUT/ws_chase8_$k.elf" -O2 -I"$ms" -DCHAINS=8 -DFOOTPRINT_KB=$k -DWARM=1 -- "$ms/chase.c"
    add "ws_chase8_$k" $k
    tg_link "$isa" "$OUT/ws_hash_$k.elf" -O2 -I"$ms" -DSLOTS_LOG=$log -- "$ms/hashprobe.c"
    add "ws_hash_$k" $k
    tg_link "$isa" "$OUT/ws_copy_$k.elf" -O2 -I"$ms" -DBYTES="($k * 512u)" -DREPS=$(( 4096 / k )) -DWARM=1 -- "$ms/copy.c"
    add "ws_copy_$k" $k
  done
  echo "$isa: $(wc -l < "$M") working-set workloads"
done
