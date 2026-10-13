#!/bin/bash
# Downloads the RISC-V GCC 15 cross toolchain and the benchmark sources (run as the normal user in
# WSL Ubuntu-24.04). Everything goes under ~/opt and perfmodel/third_party; nothing system-wide.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TP="$HERE/third_party"
mkdir -p "$TP" "$HOME/opt"

# 1. xPack GNU RISC-V Embedded GCC 15.2.0-1 (newlib), checksum-verified.
XV=15.2.0-1
XN=xpack-riscv-none-elf-gcc-$XV-linux-x64.tar.gz
XURL=https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$XV
if [ ! -x "$HOME/opt/xpack-riscv-none-elf-gcc-$XV/bin/riscv-none-elf-gcc" ]; then
  mkdir -p "$HOME/opt/dl"
  cd "$HOME/opt/dl"
  curl -fL --retry 3 -o "$XN" "$XURL/$XN"
  curl -fL --retry 3 -o "$XN.sha" "$XURL/$XN.sha"
  sha256sum -c "$XN.sha"
  tar -xzf "$XN" -C "$HOME/opt"
fi
"$HOME/opt/xpack-riscv-none-elf-gcc-$XV/bin/riscv-none-elf-gcc" --version | head -1

# 2. Benchmarks, pinned.
cd "$TP"
[ -d coremark ] || git clone -q https://github.com/eembc/coremark.git coremark
[ -d embench-iot ] || git clone -q --branch embench-1.0 --depth 1 https://github.com/embench/embench-iot.git embench-iot
mkdir -p dhrystone
[ -f dhrystone/dhry-c ] || curl -fL --retry 3 -o dhrystone/dhry-c http://www.netlib.org/benchmark/dhry-c
{
  echo "coremark    $(git -C coremark rev-parse HEAD)"
  echo "embench-iot $(git -C embench-iot rev-parse HEAD) (tag embench-1.0)"
  echo "dhrystone   netlib dhry-c sha256 $(sha256sum dhrystone/dhry-c | cut -d' ' -f1)"
  echo "toolchain   xpack-riscv-none-elf-gcc-$XV"
} > "$TP/VERSIONS.txt"
cat "$TP/VERSIONS.txt"
