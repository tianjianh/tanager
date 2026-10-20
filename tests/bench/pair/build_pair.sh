#!/bin/bash
# Builds the pair runner's programs and images (tests/bench/pair; pair.h; the M7 plan's exit 2): smt2-study's 13
# programs (perfmodel/scripts/smt.py, MEM and COMP) from the model's sources, each linked at both slots' bases
# with the pair runtime, then one image per pair (perfmodel's make_pairs, read from smt.py) and one per program
# alone (hart 0 runs it at its slot's base, hart 1 parks). The memory kernels run at 1-3 MiB, far past the 32 KiB
# L1 in tg_vsim's flat memory, so their setup is short enough for RTL runs. With REPEAT=1 (exit 2's method,
# verification.md §4.8) each memory kernel repeats its region until the pair ends instead of running again from the
# top with its set-up; their sources must have the switch (perfmodel/bench/memsuite, smt2-study's).
#   [REPEAT=1|0] build_pair.sh <output directory>
set -euo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
P="$W/tests/bench/pair"
OUT="${1:?usage: build_pair.sh <output directory>}"
TP="${TP:-$( [ -f "$W/perfmodel/third_party/coremark/core_main.c" ] && echo "$W/perfmodel/third_party" || echo "$HOME/tanager/perfmodel/third_party")}"
[ -f "$TP/coremark/core_main.c" ] || { echo "build_pair: no perfmodel/third_party (perfmodel/scripts/fetch_deps.sh)" >&2; exit 2; }
CC=riscv-none-elf-gcc
ARCH="-march=rv64gc -mabi=lp64d -mcmodel=medany"
CM_ITER="${CM_ITER:-3}"
DHRY_RUNS="${DHRY_RUNS:-3000}"
REPEAT="${REPEAT:-1}"
CM_A="-O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las"
DHRY_FLAGS="-O3 -fno-common -fno-inline"
EMB_FLAGS="-O2 -ffunction-sections -fdata-sections -std=gnu17"
MS="$W/perfmodel/bench/memsuite"
mkdir -p "$OUT/prog" "$OUT/img" "$OUT/gen"

# link <name> <slot> <cflags...> -- <sources...>: the program at slot 0 (0x8010_0000) or 1 (0x8810_0000)
link() {
  local name="$1" slot="$2"; shift 2
  local flags=() srcs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done
  shift
  srcs=("$@")
  local base=$((slot == 0 ? 0x80100000 : 0x88100000))
  "$CC" $ARCH "${flags[@]}" -I"$P/inc" -I"$P" -static -nostartfiles -T "$P/pair_prog.ld" \
    -Wl,--defsym=PAIR_BASE=$base -Wl,--defsym=PAIR_SIZE=0x8000000 -Wl,--gc-sections -Wl,--no-warn-rwx-segments \
    "$P/pair_crt0.S" "$P/pair_syscalls.c" "${srcs[@]}" -lm -o "$OUT/prog/$name.s$slot.elf"
  riscv-none-elf-objcopy -O binary "$OUT/prog/$name.s$slot.elf" "$OUT/prog/$name.s$slot.bin"
}

# ms <name> <slot> <source> <flags...>: a memory kernel, repeating its region with REPEAT=1
ms() {
  local name="$1" slot="$2" src="$3"; shift 3
  if [ "$REPEAT" = 1 ] && ! grep -qw REPEAT "$MS/$src"; then
    echo "build_pair: $MS/$src has no REPEAT switch (smt2-study's memsuite change); REPEAT=0 restarts from the top" >&2
    exit 2
  fi
  local rep=()
  [ "$REPEAT" = 1 ] && rep=(-DREPEAT=1)
  link "$name" "$slot" -O2 -I"$MS" "${rep[@]}" "$@" -- "$MS/$src"
}

python3 -I "$W/perfmodel/bench/dhrystone/unshar.py" "$TP/dhrystone/dhry-c" "$OUT/gen" > /dev/null
for slot in 0 1; do
  ms ms_gather "$slot" gather.c -DTAB_LOG=17
  ms ms_stride "$slot" stride.c -DROWS=256
  ms ms_spmv "$slot" spmv.c -DCOLS_LOG=17
  ms ms_hashprobe "$slot" hashprobe.c -DSLOTS_LOG=17
  ms ms_chase8 "$slot" chase.c -DCHAINS=8 -DFILLER=0 -DFOOTPRINT_MB=2 -DWARM=1
  ms ms_stream "$slot" stream.c "-DN_ELEMS=(1u << 17)"
  ms ms_copy "$slot" copy.c "-DBYTES=(1u << 20)" -DWARM=1
  link coremark_A "$slot" $CM_A -DPERFORMANCE_RUN=1 -DITERATIONS="$CM_ITER" "-DFLAGS_STR=\"$CM_A\"" \
    -I"$W/perfmodel/bench/coremark" -I"$TP/coremark" -- "$TP/coremark/core_list_join.c" "$TP/coremark/core_main.c" \
    "$TP/coremark/core_matrix.c" "$TP/coremark/core_state.c" "$TP/coremark/core_util.c" \
    "$W/perfmodel/bench/coremark/core_portme.c"
  "$CC" $ARCH $DHRY_FLAGS -std=gnu89 -w -DTIME -Dmain=dhry_main -I"$OUT/gen" -c "$OUT/gen/dhry_1.c" -o "$OUT/gen/dhry_1.o"
  link dhrystone "$slot" $DHRY_FLAGS -std=gnu89 -w -DTIME "-DTG_STDIN=\"$DHRY_RUNS\\n\"" -I"$OUT/gen" -- \
    "$OUT/gen/dhry_1.o" "$OUT/gen/dhry_2.c" "$W/tests/bench/dhrystone/dhry_time.c"
  for b in nsichneu huffbench minver matmult-int; do
    d="$TP/embench-iot/src/$b/"
    link "embench_$b" "$slot" $EMB_FLAGS -DCPU_MHZ=1 -DWARMUP_HEAT=1 -I"$TP/embench-iot/support" -w -- \
      "$d"*.c "$TP/embench-iot/support/main.c" "$TP/embench-iot/support/beebsc.c" "$W/perfmodel/bench/embench/boardsupport.c"
  done
done

# image <name> <hart0 slot> <hart1 slot> <active> [slot0 program] [slot1 program]
image() {
  local name="$1" h0="$2" h1="$3" active="$4" s0="${5:-}" s1="${6:-}"
  "$CC" $ARCH -nostdlib -nostartfiles -static -T "$P/pair_top.ld" -Wl,--no-warn-rwx-segments \
    -DHART0_SLOT="$h0" -DHART1_SLOT="$h1" -DACTIVE="$active" \
    ${s0:+"-DSLOT0_BIN=\"$OUT/prog/$s0.s0.bin\""} ${s1:+"-DSLOT1_BIN=\"$OUT/prog/$s1.s1.bin\""} \
    "$P/pair_top.S" -o "$OUT/img/$name.elf"
}
progs=$(python3 -I - "$W/perfmodel/scripts/smt.py" <<'EOF'
import ast, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)
env = {}
for node in tree.body:   # MEM and COMP, then make_pairs, evaluated without importing the model
    if isinstance(node, ast.Assign) and any(getattr(t, "id", "") in ("MEM", "COMP") for t in node.targets):
        exec(compile(ast.Module([node], []), "smt.py", "exec"), env)
    if isinstance(node, ast.FunctionDef) and node.name == "make_pairs":
        exec(compile(ast.Module([node], []), "smt.py", "exec"), env)
for p in env["MEM"] + env["COMP"]:
    print("prog", p)
for g, a, b in env["make_pairs"]():
    print("pair", g, a, b)
EOF
)
n=0
while read -r kind a b c; do
  if [ "$kind" = prog ]; then
    image "alone-$a-s0" 0 -1 1 "$a" ""
    image "alone-$a-s1" 1 -1 1 "" "$a"
  else
    image "pair-$b+$c" 0 1 2 "$b" "$c"
    n=$((n + 1))
  fi
done <<< "$progs"
# What the model and the RTL must share: every ELF's md5 (md5sum -c in $OUT) and the tree they came from
(cd "$OUT" && md5sum prog/*.elf img/*.elf > manifest.md5)
echo "build_pair.sh $(date '+%F %T %Z') tree $(git -C "$W" describe --always --dirty --abbrev=10 2>/dev/null || echo unknown)" \
  "REPEAT=$REPEAT" > "$OUT/build.info"
echo "build_pair: $(ls "$OUT/prog"/*.elf | wc -l) program builds, $(ls "$OUT/img"/alone-*.elf | wc -l) alone images, $n pairs in $OUT"
