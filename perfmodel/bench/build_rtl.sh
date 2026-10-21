#!/bin/bash
# Builds some of the model's workloads with the RTL simulation platform's runtime (tests/bench/bsp: crt0, the 16550
# console, tohost and the tg_marker region), so that tg_vsim and tgsim run the very same ELFs (scripts/rtlcal.py):
# Embench programs and 0.5 MiB working-set kernels. A one-line tgsim.h maps the sources' markers to tg_sim.h.
#   ISA=rv64gc bash bench/build_rtl.sh <output directory>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"
R="$TG_ROOT"
TP="$R/third_party"
RB="$R/../tests/bench/bsp"
OUT="${1:?usage: build_rtl.sh <output directory>}"
ISA="${ISA:-rv64gc}"
mkdir -p "$OUT/inc"
printf '#include "tg_sim.h"\n' > "$OUT/inc/tgsim.h"

rtl_link() {  # rtl_link <out.elf> <cflags...> -- <sources...>
  local out="$1"; shift
  local flags=() srcs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done
  shift
  srcs=("$@")
  "$TG_CC" $(tg_isa_flags "$ISA") "${flags[@]}" -I"$OUT/inc" -I"$RB" -static -nostartfiles -T "$RB/link.ld" \
    -Wl,--gc-sections -Wl,--no-warn-rwx-segments "$RB/crt0.S" "$RB/syscalls.c" "${srcs[@]}" -lm -o "$out"
}

for b in crc32 nsichneu huffbench matmult-int minver statemate edn ud; do
  d="$TP/embench-iot/src/$b/"
  rtl_link "$OUT/embench_$b.elf" -O2 -DCPU_MHZ=1 -DWARMUP_HEAT=1 -I"$TP/embench-iot/support" -w -- \
    "$d"*.c "$TP/embench-iot/support/main.c" "$TP/embench-iot/support/beebsc.c" "$R/bench/embench/boardsupport.c"
done
ms="$R/bench/memsuite"
rtl_link "$OUT/ws_chase1_512.elf" -O2 -I"$ms" -DCHAINS=1 -DHOPS=4000 -DFOOTPRINT_KB=512 -DWARM=1 -- "$ms/chase.c"
rtl_link "$OUT/ws_hash_512.elf" -O2 -I"$ms" -DSLOTS_LOG=16 -- "$ms/hashprobe.c"
rtl_link "$OUT/ws_copy_512.elf" -O2 -I"$ms" -DBYTES="(512 * 512u)" -DREPS=8 -DWARM=1 -- "$ms/copy.c"
# ~150-200 KiB of code walked in a fixed order, far past the 32 KiB L1I: the one program here the I$ next-line
# prefetch shows on (build_extra.sh's tk_bigcode, 4 passes)
python3 -I "$R/bench/bigcode/gen_bigcode.py" "$OUT/inc/bigcode.c" 1024
rtl_link "$OUT/tk_bigcode.elf" -O2 -DPASSES=4 -- "$OUT/inc/bigcode.c"
echo "$ISA: $(ls "$OUT"/*.elf | wc -l) RTL-platform workloads in $OUT"
