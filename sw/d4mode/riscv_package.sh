#!/bin/bash
# RISC-V mode's board package (docs/spec/firmware_switches.md, soc-d4-modes.md): a build.tcl run's bitstream with
# OpenSBI, U-Boot d4, the RISC-V mode trees, riscv.cmd and a README, laid out as sw/d4mode/install.sh puts them on the
# card's p1. The M8 release image of record (rc3u095r, 10-23) is this script's package of spikes-2's rc3_u095r run.
#   README=<template> [FW=...] [UBOOT=...] [ETH_MAC=...] [SOURCE_DATE_EPOCH=...] \
#     bash sw/d4mode/riscv_package.sh <run-dir> <name> [out-root]    -> <out-root>/<name>-riscv/, <name>-riscv.tar.gz
# - <run-dir>: a fpga/kv260/tcl/build.tcl run directory with tanager.bit.bin, reports/summary.txt (release=1 takes the
#   release trees, DR-180; core_mhz, commit, defines, place and urf go in the README) and reports/utilization.rpt.
#   The bitstream must be built with hart 1 (TG_HART1=1: the trees list four harts).
# - out-root: default $SOC_BUILD/board.
# - README: the template of the package's H1-README.txt. @NAME@, @COMMIT@, @MHZ@, @C2X@, @DEFINES@, @URF@, @PLACE@ and
#   @TIMING@ are filled from the run. The release image of record's is sw/d4mode/package/README-rc3.in.
# - FW: OpenSBI's fw_jump.bin, default sw/build_opensbi.sh's. It must have FW_SHA's sha256, default OpenSBI 1.9 with
#   patch set tg1 as tools/ci/cycle_identical.py pins it; FW_SHA= (empty) takes any.
# - UBOOT: U-Boot d4, default sw/build_uboot.sh d4's: payload.bin in the package.
# - The trees (sw/dts/board-trees.sh 2, four harts): tanager.dtb is tanager-kv260-riscv-rel.dtb for a release build,
#   tanager-kv260-riscv.dtb otherwise; tanager-h01.dtb is the same with CORES=1 (harts 0 and 1), the fallback tree.
#   ETH_MAC: the board's MAC, default this KV260's (board-trees.sh).
# - SOURCE_DATE_EPOCH: riscv.scr's image time (mkimage), default the commit's time, so a package rebuilds byte for byte.
#   SHA256SUMS lists the files in sort's order under the caller's locale, as build.sh does (rc3's: en_US.UTF-8).
# Needs sw/build_uboot.sh's stage C build for mkimage (sw/d4mode/build.sh) and the device-tree compiler.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
source "$here/../env.sh"
[ $# -eq 2 ] || [ $# -eq 3 ] || { echo "usage: README=<template> $0 <run-dir> <name> [out-root]" >&2; exit 2; }
run=$1 name=$2 root=${3:-$SOC_BUILD/board}
readme=${README:?README=<template> (the release image of record: sw/d4mode/package/README-rc3.in)}
fw=${FW:-$SOC_BUILD/opensbi-$OPENSBI_REV/platform/generic/firmware/fw_jump.bin}
uboot=${UBOOT:-$SOC_BUILD/u-boot-d4/u-boot.bin}
fw_sha=${FW_SHA-62349a65652ae1676c27f94738098ab6442b1851b436029e2d0bad2c5726fc78}
mac=${ETH_MAC:-00:0a:35:2a:df:d8}
S=$run/reports/summary.txt U=$run/reports/utilization.rpt
for f in "$run/tanager.bit.bin" "$S" "$U" "$readme" "$fw" "$uboot"; do
  [ -f "$f" ] || { echo "$0: no $f" >&2; exit 1; }
done
grep -q '^profile=.* defines=.*\bTG_HART1=1\b' "$S" || { echo "$0: $run wasn't built with TG_HART1=1" >&2; exit 1; }
[ -z "$fw_sha" ] || [ "$(sha256sum < "$fw" | cut -c1-64)" = "$fw_sha" ] ||
  { echo "$0: $fw is not OpenSBI ${fw_sha:0:8}... (FW_SHA= takes another)" >&2; exit 1; }
rel=$(grep -q '^release=1' "$S" && echo 1 || echo 0)
mhz=$(sed -n 's/.* core_mhz=\([0-9]*\).*/\1/p' "$S" | head -1)
[ -n "$mhz" ] || { echo "$0: no core_mhz in $S" >&2; exit 1; }
place=$(sed -n 's/^place=\([^ ]*\).*/\1/p' "$S")
commit=$(sed -n 's/^commit=//p' "$S")
defs=$(sed -n 's/.* defines=\(.*\) synth=.*/\1/p' "$S")
timing="$(sed -n 's/^WNS=//p' "$S" | sed 's/^/WNS=/'); $(grep -a -m1 'CLB LUTs' "$U" |
  awk -F'|' '{gsub(/ /,"",$3); gsub(/ /,"",$7); print $3" LUTs placed ("$7"%)"}')"
if grep -q '^urf=1' "$S"; then
  urf="the UltraRAM register file (TG_URF=1, DR-174) with clk2x at $((2 * mhz)) MHz"
else
  urf="without the UltraRAM register file (URF=0)"
fi
rv=$root/$name-riscv
[ ! -e "$rv" ] || { echo "$0: $rv exists: pick a new name or out-root" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ETH_MAC=$mac bash "$top/sw/dts/board-trees.sh" "$tmp/trees" 2 > /dev/null
make -s -B -C "$top/sw/dts" O="$tmp/h01" CORES=1 THREADS=2 RUN_THREADS=2 MEM=0x40000000 UART1=1 UART1_STDOUT=0 SD1=1 \
  BOARD_RESET=1 ETH=1 ETH_MAC="$mac" RELEASE=$rel > /dev/null
tree=$tmp/trees/tanager-kv260-riscv$([ "$rel" = 1 ] && echo -rel).dtb
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$top" log -1 --format=%ct)}
mkdir -p "$root"
bash "$here/build.sh" "$rv" "$here/riscv.cmd" "$run/tanager.bit.bin" "$fw" "$uboot" "$tree" > /dev/null
cp "$tmp/h01/tanager-kv260.dtb" "$rv/tanager/tanager-h01.dtb"
sed -e "s|@NAME@|$name|g" -e "s|@COMMIT@|$commit|" -e "s|@TIMING@|$timing|" -e "s|@DEFINES@|$defs|" -e "s|@URF@|$urf|" \
  -e "s|@MHZ@|$mhz|g" -e "s|@C2X@|$((2 * mhz))|g" -e "s|@PLACE@|${place:-Default}|g" "$readme" > "$rv/H1-README.txt"
(cd "$rv" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -C "$root" -cf - "$name-riscv" |
  gzip -n > "$rv.tar.gz"
echo "riscv_package.sh: $rv ($([ "$rel" = 1 ] && echo "a release build: tanager-kv260-riscv-rel.dtb" ||
  echo "a development build: tanager-kv260-riscv.dtb"), $mhz MHz, SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
sha256sum "$rv.tar.gz" "$rv/tanager/tanager.bit.bin"
for f in tanager.dtb tanager-h01.dtb; do
  echo "$f: $(dtc -q -I dtb -O dts "$rv/tanager/$f" | grep -c 'device_type = "cpu"') harts"
done
