#!/bin/bash
# D4 modes, step 4's check before the board (docs/spec/soc-d4-modes.md): the mode check's hook (ubootenv.d-tanager-mode)
# run by U-Boot 2026.07's hush (the old parser, as the KV260's U-Boot 2023.01) on QEMU riscv64 virt, against an SD
# card image (sdhci-pci + sd-card) whose sector 2047 holds each test record, with p1 (ext4 here; FAT on the board)
# holding tanager/riscv.scr and the hook as a script image. Only the hook's two scratch addresses move into QEMU's RAM
# (0x1f000000 -> 0x9f000000, 0x21000000 -> 0xa1000000). It builds its own U-Boot (qemu-riscv64_smode_defconfig with
# the PCI SD controller, the boot command sourcing the hook) in $SOC_BUILD/u-boot-qtest, and needs sw/build_uboot.sh's
# tree and mkimage, qemu-system-riscv64, sfdisk and mke2fs. It found that U-Boot's hush takes an apostrophe inside
# double quotes as a syntax error, then crashes.
#   bash sw/d4mode/hook_qtest.sh <package dir from sw/d4mode/build.sh>     -> "hook_qtest: ALL PASS"
set -u
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../env.sh" > /dev/null 2>&1
source "$here/../versions.sh" > /dev/null 2>&1
B=$SOC_BUILD
pkg=$1
T=$B/hook_qtest
U=$B/u-boot-$UBOOT_VER O=$B/u-boot-qtest
mkimage=$B/u-boot/tools/mkimage
[ -d "$U" ] && [ -x "$mkimage" ] || { echo "no $U or $mkimage: bash sw/build_uboot.sh first"; exit 1; }
mkdir -p "$T"
if [ ! -f "$O/u-boot.bin" ]; then
  cat > "$T/qtest.config" <<'CFG'
CONFIG_MMC=y
CONFIG_DM_MMC=y
CONFIG_CMD_MMC=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_PCI=y
CONFIG_BOOTDELAY=0
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="pci enum; mmc dev 0; setenv devtype mmc; setenv devnum 0; setenv distro_bootpart 1; if load mmc 0:1 0x90000000 hook.scr; then source 0x90000000; fi; echo HOOK-TEST-END; poweroff"
# CONFIG_TOOLS_LIBCRYPTO is not set
# CONFIG_TOOLS_MKEFICAPSULE is not set
# CONFIG_TOOLS_KWBIMAGE is not set
CFG
  x=(CROSS_COMPILE="$SOC_RVTC/bin/riscv64-buildroot-linux-gnu-")
  make -s -C "$U" O="$O" "${x[@]}" qemu-riscv64_smode_defconfig > "$T/build.log" 2>&1
  "$U/scripts/kconfig/merge_config.sh" -m -O "$O" "$O/.config" "$T/qtest.config" >> "$T/build.log" 2>&1
  make -s -C "$U" O="$O" "${x[@]}" olddefconfig >> "$T/build.log" 2>&1
  make -s -C "$U" O="$O" "${x[@]}" -j8 < /dev/null >> "$T/build.log" 2>&1 || { echo "u-boot build failed: $T/build.log"; exit 1; }
fi
sed -e 's/0x1f000000/0x9f000000/g; s/0x1f000004/0x9f000004/g; s/0x1f000008/0x9f000008/g; s/0x1f000009/0x9f000009/g; s/0x21000000/0xa1000000/g' \
  "$pkg/ubootenv.d-tanager-mode" > "$T/hook.cmd"
grep -q "0x1f0\|0x2100" "$T/hook.cmd" && { echo "an address was left unmoved"; exit 1; }
rm -rf "$T/p1"; mkdir -p "$T/p1/tanager"
cp "$pkg/tanager/riscv.scr" "$T/p1/tanager/"
"$mkimage" -A riscv -O linux -T script -C none -d "$T/hook.cmd" "$T/p1/hook.scr" > /dev/null
rm -f "$T/p1.ext4"; mke2fs -q -t ext4 -d "$T/p1" "$T/p1.ext4" 30M
fail=0
run_case() {   # <name> <record text or "">  <expect regex> <sector after: text or "">
  local n=$1 rec=$2 want=$3 after=$4 img=$T/$1.img
  dd if=/dev/zero of="$img" bs=1M count=64 2>/dev/null
  echo "2048,61440,83" | sfdisk -q "$img" > /dev/null
  dd if="$T/p1.ext4" of="$img" bs=512 seek=2048 conv=notrunc 2>/dev/null
  [ -n "$rec" ] && printf '%s\n' "$rec" | dd of="$img" bs=512 seek=2047 count=1 conv=sync,notrunc 2>/dev/null
  timeout 120 qemu-system-riscv64 -M virt -m 1G -nographic -bios default -kernel "$B/u-boot-qtest/u-boot.bin" \
    -device sdhci-pci -device sd-card,drive=sd -drive id=sd,file="$img",format=raw,if=none > "$T/$n.out" 2>&1
  local got; got=$(dd if="$img" bs=512 skip=2047 count=1 2>/dev/null | head -c 10 | tr -c 'A-Za-z0-9' '.')
  local ok=1
  grep -q "HOOK-TEST-END" "$T/$n.out" || ok=0
  grep -Eq "$want" "$T/$n.out" || ok=0
  if [ -n "$after" ]; then [ "$got" = "$after" ] || ok=0; else [ "$got" = ".........." ] || ok=0; fi
  if [ $ok = 1 ]; then echo "PASS $n: sector 2047 now '$got'"; else echo "FAIL $n: sector 2047 now '$got' (log $T/$n.out)"; fail=1; fi
  grep -a "tanager" "$T/$n.out" | sed 's/^/    /'
}
run_case none    ""           "tanager-mode: ARM mode" ""
run_case invalid "TANAGERMx9" "tanager-mode: ARM mode" "TANAGERMx9"
run_case arm     "TANAGERMa0" "tanager-mode: ARM mode" "TANAGERMa0"
run_case trial1  "TANAGERMr1" "tanager-mode: ARM mode" "TANAGERMr1"
run_case riscv   "TANAGERMr0" "the step 4 stub, returning to Ubuntu" "TANAGERMr1"
grep -q "the RISC-V did not start" "$T/riscv.out" || { echo "FAIL riscv: no fallback message"; fail=1; }
[ $fail = 0 ] && echo "hook_qtest: ALL PASS" || echo "hook_qtest: FAILED"
