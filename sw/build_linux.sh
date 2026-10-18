#!/bin/bash
# Builds a Tanager Linux image set with Buildroot (docs/spec/soc.md §5): OpenSBI fw_jump, the
# kernel Image with its initramfs built in, and the device trees.
#   bash sw/build_linux.sh [defconfig-name] [make targets...]   (default: tanager_lp64d)
# Output: $SOC_BUILD/br-<name>/images. Downloads come from $SOC_DL (sw/fetch.sh fills it).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../tools/env.sh"
source "$here/env.sh"
name="${1:-tanager_lp64d}"; shift || true
br="$SOC_BUILD/buildroot-$BUILDROOT_VER"
out="$SOC_BUILD/br-$name"

# br-tanager_lp64d/images/Image is the reference kernel that every boot check takes (tests/unit/boot,
# tools/ci/cycle_identical.py's newest */br-tanager_lp64d, core-2's boot curves): rebuilding it moves every
# boot baseline, and the boot checks fail while it is missing. So a rebuild of an existing one is refused;
# changed images get their own defconfig (tanager_lp64d_bench, tanager_lp64d_stage_d). To replace the
# reference on purpose, build it in another directory and rename it into place, and tell the coordinator,
# core-2 and verif-2 first.
if [ "$name" = tanager_lp64d ] && [ -e "$out/images/Image" ] && [ "${BR_REBUILD_REFERENCE:-0}" != 1 ]; then
  echo "build_linux.sh: $out/images/Image is the boot checks' reference kernel; not rebuilding it" >&2
  echo "  (another defconfig for changed images; BR_REBUILD_REFERENCE=1 only for an announced replacement)" >&2
  exit 1
fi

bash "$here/fetch.sh" >/dev/null
if [ ! -d "$br" ]; then
  tar -C "$SOC_BUILD" -xf "$SOC_DL/buildroot/$BUILDROOT_TAR"
fi

# GCC 15 for host tools too (standing decision); Buildroot honours HOSTCC/HOSTCXX.
export HOSTCC=gcc-15 HOSTCXX=g++-15
export BR2_DL_DIR="$SOC_DL"
unset CC CXX   # the target compilers come from Buildroot's toolchain, not from tools/env.sh

mkdir -p "$out"
if [ ! -f "$out/.config" ]; then
  make -C "$br" O="$out" BR2_EXTERNAL="$here/buildroot" "${name}_defconfig"
fi
make -C "$out" "$@"

# The kernel's effective size (Image header, image_size at offset 16) must stay below 32 MiB:
# OpenSBI's fw_jump places the DTB at 0x8220_0000, 32 MiB above the kernel (docs/spec/soc.md §3).
img="$out/images/Image"
if [ -f "$img" ]; then
  sz=$(python3 -I -c 'import sys,struct; print(struct.unpack_from("<Q", open(sys.argv[1],"rb").read(64), 16)[0])' "$img")
  echo "kernel effective size: $sz bytes"
  [ "$sz" -lt $((32 << 20)) ] || { echo "ERROR: kernel image_size $sz reaches the DTB at +32 MiB" >&2; exit 1; }
fi
ls -la "$out/images"
