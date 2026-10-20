#!/bin/bash
# The KV260's device trees (soc-2, 10-20): every tree the board's packages carry, for one RUN_THREADS.
#   - 1 rebuilds today's, byte for byte: the stage C trees (first made for sc3's package), the bench tree, RISC-V
#     mode's.
#   - 2 gives M7's four harts (DR-175, docs/spec/m7-smt2-plan.md), for a bitstream with hart 1 on (step 5c).
#   bash sw/dts/board-trees.sh <out-dir> [1|2]          (default 1; ETH_MAC=xx:xx:xx:xx:xx:xx for another board)
#     tanager-kv260-virtio.dtb       stage C: 1 GiB, the forwarded virtio window (tanager-host's --dtb)
#     tanager-kv260-virtio-768m.dtb  the same in 768 MiB
#     tanager-kv260-bench.dtb        the Linux bench's (DR-141): the PMU event map, tanager.bench=1
#     tanager-kv260-riscv.dtb        RISC-V mode's, which sw/d4mode/build.sh puts in tanager/ as tanager.dtb: UART1 off
#                                    the stdout path, SD1, the board's reset, GEM3 with the board's MAC
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: board-trees.sh <out-dir> [1|2]}
rt=${2:-1}
mac=${ETH_MAC:-00:0a:35:2a:df:d8}
[ "$rt" = 1 ] || [ "$rt" = 2 ] || { echo "board-trees.sh: RUN_THREADS is 1 or 2" >&2; exit 2; }
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
one() {  # <name> <make variables...>
  local n=$1
  shift
  make -s -B -C "$here" O="$tmp/$n" CORES=2 THREADS=2 RUN_THREADS="$rt" "$@" > /dev/null
  cp "$tmp/$n/tanager-kv260.dtb" "$out/tanager-kv260-$n.dtb"
}
one virtio MEM=0x40000000 VIRTIO=1
one virtio-768m MEM=0x30000000 VIRTIO=1
one bench MEM=0x40000000 PMU=1 BOOTARGS="console=ttyS0,115200 earlycon tanager.bench=1"
one riscv MEM=0x40000000 UART1=1 UART1_STDOUT=0 SD1=1 BOARD_RESET=1 ETH=1 ETH_MAC="$mac"
echo "board-trees.sh: RUN_THREADS=$rt, $(( rt == 2 ? 4 : 2 )) harts, in $out"
