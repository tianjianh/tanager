#!/bin/bash
# The KV260's device trees (soc-2, 10-20): every tree the board's packages carry, for one RUN_THREADS.
#   - 1 rebuilds the stage C trees (first made for sc3's package) and the bench tree byte for byte, and RISC-V mode's
#     as before but without the MAC (DR-192).
#   - 2 gives M7's four harts (DR-175, docs/spec/m7-smt2-plan.md), for a bitstream with hart 1 on (step 5c).
#   bash sw/dts/board-trees.sh <out-dir> [1|2]          (default 1)
#   RISC-V mode's trees carry no MAC (DR-192): riscv.cmd puts the board's own in at boot, from the ethaddr the A53's
#   U-Boot reads from the SOM's EEPROM, so one package serves every KV260. ETH_MAC=xx:xx:xx:xx:xx:xx fixes one in (a
#   test; the boot's fix-up still writes ethaddr over it).
#     tanager-kv260-virtio.dtb       stage C: 1 GiB, the forwarded virtio window (tanager-host's --dtb)
#     tanager-kv260-virtio-768m.dtb  the same in 768 MiB
#     tanager-kv260-bench.dtb        the Linux bench's (DR-141): the PMU event map, tanager.bench=1
#     tanager-kv260-riscv.dtb        RISC-V mode's, which sw/d4mode/build.sh puts in tanager/ as tanager.dtb: UART1 off
#                                    the stdout path, SD1, the board's reset, GEM3 (its MAC set at boot)
#     tanager-kv260-riscv-rel.dtb    the same for a release build (TG_RELEASE=1, DR-180): the PLIC's M contexts absent.
#                                    The product's; it boots a development build as well (nothing uses those contexts)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: board-trees.sh <out-dir> [1|2]}
rt=${2:-1}
mac=${ETH_MAC:-}
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
one riscv MEM=0x40000000 UART1=1 UART1_STDOUT=0 SD1=1 BOARD_RESET=1 ETH=1 ${mac:+ETH_MAC=$mac}
one riscv-rel MEM=0x40000000 UART1=1 UART1_STDOUT=0 SD1=1 BOARD_RESET=1 ETH=1 ${mac:+ETH_MAC=$mac} RELEASE=1
echo "board-trees.sh: RUN_THREADS=$rt, $(( rt == 2 ? 4 : 2 )) harts, in $out"
