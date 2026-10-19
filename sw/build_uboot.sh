#!/bin/bash
# U-Boot in S-mode for Tanager (DR-147, docs/spec/soc.md §8.1): qemu-riscv64_smode_defconfig with
# sw/uboot/tanager.config, built with the pinned Bootlin riscv64 toolchain (sw/env.sh SOC_RVTC).
# OpenSBI's fw_jump starts it at 0x8020_0000 with the device tree in a1; tanager-host loads
# u-boot.bin where the kernel went.
#   bash sw/build_uboot.sh        -> $SOC_BUILD/u-boot/u-boot.bin
# d4: D4's RISC-V mode (docs/spec/soc-d4-modes.md), Debian from the card through the PS's SD1: tanager-d4.config
# on top, in a tree of its own with sw/uboot/patches-d4 applied (the stage C build stays as it was).
#   bash sw/build_uboot.sh d4     -> $SOC_BUILD/u-boot-d4/u-boot.bin
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/env.sh"
bash "$here/fetch.sh" uboot rvtc
tc="$SOC_RVTC"
if [ ! -x "$tc/bin/riscv64-buildroot-linux-gnu-gcc" ]; then
  dest="${SOC_TC_DIR:-$SOC_BUILD/tc}"
  mkdir -p "$dest"
  tar -C "$dest" -xf "$SOC_DL/toolchain-external-custom/$RVTC_TAR"
  tc="$dest/$RVTC_NAME"
fi
case "${1:-}" in
  "") src="$SOC_BUILD/u-boot-$UBOOT_VER" out="$SOC_BUILD/u-boot" frags=("$here/uboot/tanager.config")
      [ -d "$src" ] || tar -C "$SOC_BUILD" -xf "$SOC_DL/uboot/$UBOOT_TAR" ;;
  d4) src="$SOC_BUILD/u-boot-$UBOOT_VER-d4" out="$SOC_BUILD/u-boot-d4"
      frags=("$here/uboot/tanager.config" "$here/uboot/tanager-d4.config")
      if [ ! -f "$src/.tanager-patched" ]; then
        rm -rf "$src" "$src.tmp"; mkdir -p "$src.tmp"
        tar -C "$src.tmp" -xf "$SOC_DL/uboot/$UBOOT_TAR"
        mv "$src.tmp/u-boot-$UBOOT_VER" "$src"; rmdir "$src.tmp"
        for p in "$here"/uboot/patches-d4/*.patch; do patch -s -p1 -d "$src" < "$p"; done
        touch "$src/.tanager-patched"
      fi ;;
  *) echo "usage: $0 [d4]" >&2; exit 2 ;;
esac
mkdir -p "$out"
x=(CROSS_COMPILE="$tc/bin/riscv64-buildroot-linux-gnu-")
make -C "$src" O="$out" "${x[@]}" qemu-riscv64_smode_defconfig
"$src/scripts/kconfig/merge_config.sh" -m -O "$out" "$out/.config" "${frags[@]}"
make -C "$src" O="$out" "${x[@]}" olddefconfig
make -C "$src" O="$out" "${x[@]}" -j"$SOC_JOBS"
ls -l "$out/u-boot.bin"
