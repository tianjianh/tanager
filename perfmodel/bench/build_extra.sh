#!/bin/bash
# Builds workloads that are outside the DSE suite into build/bench/<isa>/extra.jsonl:
#   coremark_N   CoreMark the way NaxRiscv's published RV64 figure was built (-O3, ee_u32 as a signed type),
#                used only to compare the NaxRiscv-like model with that figure; never a valid EEMBC score.
#   Targeted kernels for features the DSE suite does not exercise (the strided walk moved into the suite
#   as ms_stride in suite revision 2):
#   tk_histo     histogram of skewed bytes, store-to-load aliasing (memory-dependence prediction)
#   tk_bigcode   ~150-200 KiB of code walked in a fixed order (I-side prefetch, L1I size)
#   tk_bsearch_l2 binary search in a 256 KiB array, L2-resident (branch recovery, checkpoints)
#   tk_dgemm     L1-resident 4x4-blocked double matrix multiply (FP issue width: a second FMA pipe)
#   ISAS="rv64gc rv64gcb" bash bench/build_extra.sh
# The soft-float rv64imac suite (Embench comparable with NaxRiscv's RV64 figure) is a normal suite build:
#   ISAS=rv64imac bash bench/build_all.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"
R="$TG_ROOT"
TP="$R/third_party"
ISAS="${ISAS:-rv64gc rv64gcb}"
CM_ITER="${CM_ITER:-20}"
CM_N="-O3 -funroll-loops"
GEN="$R/build/gen"
mkdir -p "$GEN"
python3 "$R/bench/bigcode/gen_bigcode.py" "$GEN/bigcode.c" 1024

for isa in $ISAS; do
  OUT="$R/build/bench/$isa"
  mkdir -p "$OUT"
  M="$OUT/extra.jsonl"
  : > "$M"
  add() { echo "{\"name\":\"$1\",\"group\":\"$2\",\"elf\":\"$3\",\"stdin\":\"\",\"ff\":$4,\"meta\":$5}" >> "$M"; }
  tg_link "$isa" "$OUT/coremark_N.elf" $CM_N -DCM_U32_AS_S32 -DPERFORMANCE_RUN=1 -DITERATIONS=$CM_ITER \
    "-DFLAGS_STR=\"$CM_N, ee_u32 as int32_t\"" -I"$R/bench/coremark" -I"$TP/coremark" -- \
    "$TP/coremark/core_list_join.c" "$TP/coremark/core_main.c" "$TP/coremark/core_matrix.c" \
    "$TP/coremark/core_state.c" "$TP/coremark/core_util.c" "$R/bench/coremark/core_portme.c"
  add coremark_N coremark_alt "$OUT/coremark_N.elf" 0 "{\"iterations\":$CM_ITER,\"flags\":\"$CM_N, ee_u32 as int32_t\"}"
  ms="$R/bench/memsuite"
  tg_link "$isa" "$OUT/tk_histo.elf" -O2 -I"$ms" -- "$ms/histo.c"
  add tk_histo targeted "$OUT/tk_histo.elf" 1 "{}"
  tg_link "$isa" "$OUT/tk_bigcode.elf" -O2 -- "$GEN/bigcode.c"
  add tk_bigcode targeted "$OUT/tk_bigcode.elf" 1 "{}"
  tg_link "$isa" "$OUT/tk_bsearch_l2.elf" -O2 -I"$ms" -DN_LOG=16 -DQUERIES=40000 -- "$ms/bsearch.c"
  add tk_bsearch_l2 targeted "$OUT/tk_bsearch_l2.elf" 1 "{}"
  tg_link "$isa" "$OUT/tk_dgemm.elf" -O2 -- "$R/bench/fp/dgemm.c"
  add tk_dgemm targeted "$OUT/tk_dgemm.elf" 1 "{}"
  echo "$isa: $(wc -l < "$M") extra workloads, bigcode text $(size -A "$OUT/tk_bigcode.elf" 2>/dev/null | awk '/^\.text/ {print $2}') bytes"
done
