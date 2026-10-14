#!/bin/bash
# Boots the Tanager Linux images on QEMU virt with the Tanager device tree (docs/spec/soc.md §6).
#   bash sw/qemu/boot_test.sh [cores] [threads] [images-dir]     (default 2 1, br-tanager_lp64d)
# Passes when OpenSBI, Linux on every hart and the initramfs autotest all report, and QEMU exits
# through the device tree's power-off node. Exit status 0 on pass.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../../tools/env.sh"
source "$here/../env.sh"
cores="${1:-2}"; threads="${2:-1}"
images="${3:-$SOC_BUILD/br-tanager_lp64d/images}"
harts=$((cores * threads))
mem=0x40000000
out="$SOC_BUILD/qemu/${cores}x${threads}"
mkdir -p "$out"

make -s -C "$here/../dts" O="$out" CORES="$cores" THREADS="$threads" MEM="$mem" FPU=1 >/dev/null
log="$out/boot.log"
set +e
timeout 300 qemu-system-riscv64 -M virt -smp "$harts" -m 1G -nographic -no-reboot \
  -bios "$images/fw_jump.bin" -kernel "$images/Image" -dtb "$out/tanager-qemu.dtb" \
  -append "console=ttyS0,115200 earlycon tanager.autotest=1" > "$log" 2>&1
rc=$?
set -e
sed -i 's/\r$//' "$log"

fail=0
check() { if grep -q -E "$1" "$log"; then echo "  ok   $2"; else echo "  FAIL $2"; fail=1; fi; }
echo "QEMU boot test: $cores core(s) x $threads thread(s), log $log"
check '^OpenSBI v1\.9'                         "OpenSBI 1.9 banner"
check "Platform HART Count +: $harts\$"         "OpenSBI sees $harts harts"
check 'Machine model: Tanager device tree'     "Linux uses the Tanager device tree"
check "smp: Brought up 1 node, $harts CPU"      "Linux brings up $harts harts"
check 'riscv-plic: .*mapped 31 interrupts'     "PLIC with 31 sources"
check 'ttyS0 at MMIO 0x10000000 .*16550A'      "16550A console"
check "TANAGER-BOOT-OK .* harts=$harts"         "initramfs boot marker"
check 'TANAGER-AUTOTEST end'                   "autotest finished"
check 'reboot: Power down'                     "power-off through syscon-poweroff"
[ "$rc" -eq 0 ] && echo "  ok   QEMU exited cleanly" || { echo "  FAIL QEMU exit status $rc"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
