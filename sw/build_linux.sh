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

bash "$here/fetch.sh" >/dev/null
if [ ! -d "$br" ]; then
  tar -C "$SOC_BUILD" -xf "$SOC_DL/buildroot/$BUILDROOT_TAR"
fi

# GCC 15 for host tools too (standing decision); Buildroot honours HOSTCC/HOSTCXX.
export HOSTCC=gcc-15 HOSTCXX=g++-15
export BR2_DL_DIR="$SOC_DL"
unset CC CXX   # the target compilers come from Buildroot's toolchain, not from tools/env.sh

# Buildroot's dependency check wants a host cpio. If the system has none, a shim forwards to the
# host-cpio Buildroot builds for the rootfs (the check only tests that the command exists).
if ! command -v cpio >/dev/null; then
  mkdir -p "$SOC_BUILD/shim"
  cat > "$SOC_BUILD/shim/cpio" <<SHIM
#!/bin/sh
[ -x "$out/host/bin/cpio" ] || { echo "cpio shim: host-cpio not built yet" >&2; exit 1; }
exec "$out/host/bin/cpio" "\$@"
SHIM
  chmod +x "$SOC_BUILD/shim/cpio"
  export PATH="$SOC_BUILD/shim:$PATH"
fi

mkdir -p "$out"
if [ ! -f "$out/.config" ]; then
  make -C "$br" O="$out" BR2_EXTERNAL="$here/buildroot" "${name}_defconfig"
fi
if ! command -v /usr/bin/cpio >/dev/null && [ ! -x "$out/host/bin/cpio" ]; then
  make -C "$out" host-cpio
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
