#!/bin/bash
# U-Boot in S-mode for Tanager (DR-147, docs/spec/soc.md §8.1): qemu-riscv64_smode_defconfig with
# sw/uboot/tanager.config, built with the pinned Bootlin riscv64 toolchain (sw/env.sh SOC_RVTC).
# OpenSBI's fw_jump starts it at 0x8020_0000 with the device tree in a1; tanager-host loads
# u-boot.bin where the kernel went.
#   bash sw/build_uboot.sh        -> $SOC_BUILD/u-boot/u-boot.bin
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
src="$SOC_BUILD/u-boot-$UBOOT_VER"
[ -d "$src" ] || tar -C "$SOC_BUILD" -xf "$SOC_DL/uboot/$UBOOT_TAR"
out="$SOC_BUILD/u-boot"
mkdir -p "$out"
x=(CROSS_COMPILE="$tc/bin/riscv64-buildroot-linux-gnu-")
make -C "$src" O="$out" "${x[@]}" qemu-riscv64_smode_defconfig
"$src/scripts/kconfig/merge_config.sh" -m -O "$out" "$out/.config" "$here/uboot/tanager.config"
make -C "$src" O="$out" "${x[@]}" olddefconfig
make -C "$src" O="$out" "${x[@]}" -j"$SOC_JOBS"
ls -l "$out/u-boot.bin"
