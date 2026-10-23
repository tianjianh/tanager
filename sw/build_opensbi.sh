#!/bin/bash
# OpenSBI fw_jump (generic platform) from the pinned source (sw/versions.sh): the firmware for
# simulation boots (tests/unit/boot) without a Buildroot build. OpenSBI needs a linker that makes
# PIEs, which the bare-metal xPack toolchain lacks, so it builds with the pinned Bootlin riscv64
# toolchain (unpacked once, sw/env.sh SOC_RVTC: this worktree's or the shared copy; Buildroot keeps using
# the archive). The ISA is the
# toolchain's (rv64gc): OpenSBI runs FP code only when misa has F or D, so the image also boots the
# core before F/D. The generic platform's defaults put the next stage at 0x8020_0000 and the device
# tree at 0x8220_0000, as docs/spec/soc.md §5 does.
# Its PMP regions come from the device tree: one per device it uses (console, reset syscons, ACLINT, PLIC), the size of
# that node's reg. Keep each a whole number of 4 KiB pages (sw/dts checks it): a region smaller than a page costs every
# 4K page its cached PMP result in the core, -23.6% on a store loop (docs/spec/soc.md §4, "PMP regions: whole pages").
# A firmware change that adds regions of its own must keep the same rule.
# Tanager's patches (sw/buildroot/patches/opensbi, Buildroot's own patch folder for the package) go on in order, into
# a source and a build folder named for the patch set (OPENSBI_REV): a new set builds beside the old one, whose
# fw_jump.bin trees not yet on it keep using.
#   bash sw/build_opensbi.sh            -> $SOC_BUILD/opensbi-$OPENSBI_REV/platform/generic/firmware/fw_jump.bin
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/env.sh"
bash "$here/fetch.sh" opensbi rvtc
tc="$SOC_RVTC"
if [ ! -x "$tc/bin/riscv64-buildroot-linux-gnu-gcc" ]; then
  dest="${SOC_TC_DIR:-$SOC_BUILD/tc}"
  mkdir -p "$dest"
  tar -C "$dest" -xf "$SOC_DL/toolchain-external-custom/$RVTC_TAR"
  tc="$dest/$RVTC_NAME"
fi
src="$SOC_BUILD/opensbi-$OPENSBI_VER-$OPENSBI_REV"
out="$SOC_BUILD/opensbi-$OPENSBI_REV"
if [ ! -d "$src" ]; then
  tmp="$(mktemp -d "$SOC_BUILD/opensbi-src.XXXXXX")"
  tar -C "$tmp" -xf "$SOC_DL/opensbi/$OPENSBI_TAR"
  for p in "$here"/buildroot/patches/opensbi/*.patch; do
    patch -d "$tmp/opensbi-$OPENSBI_VER" -p1 --no-backup-if-mismatch < "$p"
  done
  mv "$tmp/opensbi-$OPENSBI_VER" "$src"
  rmdir "$tmp"
fi
make -C "$src" O="$out" -j8 PLATFORM=generic CROSS_COMPILE="$tc/bin/riscv64-buildroot-linux-gnu-" \
  FW_TEXT_START=0x80000000 FW_PAYLOAD=n FW_DYNAMIC=n FW_JUMP=y
ls -l "$out/platform/generic/firmware/fw_jump.bin"
