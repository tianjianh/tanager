#!/bin/bash
# Builds every tgsim workload for the given ISAs and writes build/bench/manifest_<isa>.json.
#   ISAS="rv64gc rv64gcb rv32im" bash bench/build_all.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"
R="$TG_ROOT"
TP="$R/third_party"
ISAS="${ISAS:-rv64gc rv64gcb rv32im}"
CM_ITER="${CM_ITER:-20}"
DHRY_RUNS="${DHRY_RUNS:-20000}"
CM_A="-O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las"
CM_B="-O3 -funroll-loops"
DHRY_FLAGS="-O3 -fno-common -fno-inline"
EMB_FLAGS="-O2 -ffunction-sections -fdata-sections -std=gnu17"

GEN="$R/build/gen"
mkdir -p "$GEN/dhrystone"
python3 "$R/bench/dhrystone/unshar.py" "$TP/dhrystone/dhry-c" "$GEN/dhrystone" > /dev/null

for isa in $ISAS; do
  OUT="$R/build/bench/$isa"
  mkdir -p "$OUT"
  M="$OUT/manifest.jsonl"
  : > "$M"
  add() { echo "{\"name\":\"$1\",\"group\":\"$2\",\"elf\":\"$3\",\"stdin\":\"$4\",\"ff\":$5,\"meta\":$6}" >> "$M"; }

  # CoreMark, two flag sets (EEMBC core files unmodified; our port in bench/coremark)
  for fs in A B; do
    flags="CM_$fs"; flags="${!flags}"
    tg_link "$isa" "$OUT/coremark_$fs.elf" $flags -DPERFORMANCE_RUN=1 -DITERATIONS=$CM_ITER \
      "-DFLAGS_STR=\"$flags\"" -I"$R/bench/coremark" -I"$TP/coremark" -- \
      "$TP/coremark/core_list_join.c" "$TP/coremark/core_main.c" "$TP/coremark/core_matrix.c" \
      "$TP/coremark/core_state.c" "$TP/coremark/core_util.c" "$R/bench/coremark/core_portme.c"
    add "coremark_$fs" coremark "$OUT/coremark_$fs.elf" "" 0 "{\"iterations\":$CM_ITER,\"flags\":\"$flags\"}"
  done

  # Dhrystone 2.1 (Weicker's original source; ground rules: no inlining)
  tg_link "$isa" "$OUT/dhrystone.elf" $DHRY_FLAGS -std=gnu89 -fpermissive -w -DTIME -- \
    "$GEN/dhrystone/dhry_1.c" "$GEN/dhrystone/dhry_2.c" "$R/bench/dhrystone/dhry_time.c"
  add dhrystone dhrystone "$OUT/dhrystone.elf" "$DHRY_RUNS\\n" 0 "{\"runs\":$DHRY_RUNS,\"flags\":\"$DHRY_FLAGS\"}"

  # Embench-IoT 1.0 (CPU_MHZ=1, WARMUP_HEAT=1)
  for d in "$TP"/embench-iot/src/*/; do
    b="$(basename "$d")"
    tg_link "$isa" "$OUT/embench_$b.elf" $EMB_FLAGS -DCPU_MHZ=1 -DWARMUP_HEAT=1 -I"$TP/embench-iot/support" -w -- \
      "$d"*.c "$TP/embench-iot/support/main.c" "$TP/embench-iot/support/beebsc.c" "$R/bench/embench/boardsupport.c"
    add "embench_$b" embench "$OUT/embench_$b.elf" "" 0 "{\"flags\":\"$EMB_FLAGS\"}"
  done

  # Memory-latency kernels (fast-forwarded to the timed loop)
  ms="$R/bench/memsuite"
  build_ms() { local name="$1" src="$2"; shift 2; tg_link "$isa" "$OUT/ms_$name.elf" -O2 -I"$ms" "$@" -- "$ms/$src";
               add "ms_$name" memsuite "$OUT/ms_$name.elf" "" 1 "{}"; }
  build_ms chase1 chase.c -DCHAINS=1 -DHOPS=4000
  build_ms chase8 chase.c -DCHAINS=8 -DFILLER=0
  build_ms chase8f16 chase.c -DCHAINS=8 -DFILLER=16
  build_ms chase16 chase.c -DCHAINS=16 -DFILLER=0 -DHOPS=3000
  build_ms stream stream.c
  build_ms hashprobe hashprobe.c
  build_ms spmv spmv.c
  build_ms bsearch bsearch.c
  build_ms copy copy.c
  # Suite revision 2 (M1): independent misses whose consumers wait in the window
  build_ms stride stride.c
  build_ms gather gather.c
  echo "$isa: $(wc -l < "$M") workloads"
done
