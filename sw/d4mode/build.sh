#!/bin/bash
# D4 modes' package for the KV260 (docs/spec/soc-d4-modes.md): what install.sh puts on the A53's Ubuntu (the mode
# check's hook, the tanager-mode tool, p1's tanager/ files) and Debian's unit, with riscv.scr made by mkimage
# from a U-Boot script (the U-Boot build's mkimage: bash sw/build_uboot.sh first).
#   bash sw/d4mode/build.sh <out-dir> [riscv.cmd [tanager.bit.bin fw_jump.bin payload.bin tanager.dtb]]
# Default riscv-stub.cmd: step 4, the RISC-V path returns at once. With riscv.cmd (steps 5 and 6) the four files it
# loads go in tanager/ under those names: the bitstream, OpenSBI, the payload (U-Boot d4, or step 5's test image) and
# the RISC-V mode tree.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../env.sh"
[ $# -eq 1 ] || [ $# -eq 2 ] || [ $# -eq 6 ] || { echo "usage: $0 <out-dir> [riscv.cmd [bit fw payload dtb]]" >&2; exit 2; }
out=$1 cmd=${2:-$here/riscv-stub.cmd}
mkimage=$SOC_BUILD/u-boot/tools/mkimage
[ -x "$mkimage" ] || { echo "$0: no $mkimage (bash sw/build_uboot.sh)" >&2; exit 1; }
rm -rf "$out"
mkdir -p "$out/tanager"
"$mkimage" -A arm64 -O linux -T script -C none -n "tanager riscv.scr" -d "$cmd" "$out/tanager/riscv.scr" > /dev/null
cp "$here/tanager-mode" "$here/ubootenv.d-tanager-mode" "$here/install.sh" "$here/tanager-mode-confirm.service" "$here/debian_install.sh" \
  "$here/README.md" "$out/"
chmod 755 "$out/tanager-mode" "$out/install.sh" "$out/debian_install.sh"
cp "$cmd" "$out/tanager/riscv.cmd"
if [ $# -eq 6 ]; then
  cp "$3" "$out/tanager/tanager.bit.bin"
  cp "$4" "$out/tanager/fw_jump.bin"
  cp "$5" "$out/tanager/payload.bin"
  cp "$6" "$out/tanager/tanager.dtb"
fi
(cd "$out" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)
ls -la "$out" "$out/tanager"
