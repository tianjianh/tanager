#!/bin/bash
# OpenSBI fw_jump (generic platform) from the pinned source (sw/versions.sh): the firmware for
# simulation boots (tests/unit/boot) without a Buildroot build. OpenSBI needs a linker that makes
# PIEs, which the bare-metal xPack toolchain lacks, so it builds with the pinned Bootlin riscv64
# toolchain (unpacked once under $SOC_BUILD/tc; Buildroot keeps using the archive). The ISA is the
# toolchain's (rv64gc): OpenSBI runs FP code only when misa has F or D, so the image also boots the
# core before F/D. The generic platform's defaults put the next stage at 0x8020_0000 and the device
# tree at 0x8220_0000, as docs/spec/soc.md §5 does.
#   bash sw/build_opensbi.sh            -> $SOC_BUILD/opensbi/platform/generic/firmware/fw_jump.bin
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/env.sh"
bash "$here/fetch.sh" opensbi rvtc
tc="$SOC_BUILD/tc/$RVTC_NAME"
if [ ! -x "$tc/bin/riscv64-buildroot-linux-gnu-gcc" ]; then
  mkdir -p "$SOC_BUILD/tc"
  tar -C "$SOC_BUILD/tc" -xf "$SOC_DL/toolchain-external-custom/$RVTC_TAR"
fi
src="$SOC_BUILD/opensbi-$OPENSBI_VER"
[ -d "$src" ] || tar -C "$SOC_BUILD" -xf "$SOC_DL/opensbi/$OPENSBI_TAR"
make -C "$src" O="$SOC_BUILD/opensbi" -j8 PLATFORM=generic CROSS_COMPILE="$tc/bin/riscv64-buildroot-linux-gnu-" \
  FW_TEXT_START=0x80000000 FW_PAYLOAD=n FW_DYNAMIC=n FW_JUMP=y
ls -l "$SOC_BUILD/opensbi/platform/generic/firmware/fw_jump.bin"
