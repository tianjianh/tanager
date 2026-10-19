#!/bin/bash
# D4 modes, step 4's check before the board (docs/spec/soc-d4-modes.md): the mode check's hook (ubootenv.d-tanager-mode)
# run by U-Boot 2026.07's hush (the old parser, as the KV260's U-Boot 2023.01) on QEMU riscv64 virt, against an SD
# card image (sdhci-pci + sd-card) whose sector 2047 holds each test record, with p1 (ext4 here; FAT on the board)
# holding tanager/riscv.scr and the hook as a script image. Only the hook's two scratch addresses move into QEMU's RAM
# (0x1f000000 -> 0x9f000000, 0x21000000 -> 0xa1000000). It builds its own U-Boot (qemu-riscv64_smode_defconfig with
# the PCI SD controller, the boot command sourcing the hook) in $SOC_BUILD/u-boot-qtest, and needs sw/build_uboot.sh's
# tree and mkimage, qemu-system-riscv64, sfdisk and mke2fs. It found that U-Boot's hush takes an apostrophe inside
# double quotes as a syntax error, then crashes. Then riscv.cmd dry (below).
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

# riscv.cmd (steps 5 and 6) dry: its board addresses moved into RAM, the board-only commands (fpga, zynqmp,
# dcache, icache, go) stubbed or turned into the writes they make, the host bridge's ID and STATUS put in RAM first.
# Every line parses, and the flow is right: all the way to the park; out at once without our design; the uncore
# held again and out without the L2's initialisation.
D=$T/dry
rm -rf "$D"; mkdir -p "$D/p1/tanager"
sed -e 's/0xfffc0000/0x9c000000/g; s/0xfffc0004/0x9c000004/g' \
    -e 's/0xff5e00c0/0x9b0000c0/g; s/0xfd615000/0x9b001000/g; s/0xff0a0344/0x9b002344/g; s/0xff0a0348/0x9b002348/g' \
    -e 's/0xff0a002c/0x9b00202c/g; s/0xff180314/0x9b003314/g; s/0xff180318/0x9b003318/g' \
    -e 's/0xa0001404/0x9a001404/g; s/0xa00000\([0-9a-f][0-9a-f]\)/0x9a0000\1/g' \
    -e 's/0x840000000/0x90000000/g; s/0x840200000/0x90200000/g; s/0x842200000/0x92200000/g; s/ 0x10000000 / 0x88000000 /g' \
    -e 's/^fpga load \(.*\) || exit$/echo STUB fpga load \1/' \
    -e 's/^zynqmp mmio_write \(0x[0-9a-f]*\) 0x[0-9a-f]* \(0x[0-9a-f]*\)$/mw.l \1 \2/' \
    -e 's/^\(dcache\|icache\) flush$/echo STUB \1 flush/; s/^go \(.*\)$/echo STUB go \1/' \
    "$here/riscv.cmd" > "$D/riscv.cmd"
if grep -v '^#' "$D/riscv.cmd" | grep -q '0xff\|0xfd\|0xa000\|0x84\|^zynqmp\|^fpga\|^go \|^dcache\|^icache'; then
  echo "FAIL dry: a board address or command was left in"; fail=1
fi
"$mkimage" -A riscv -O linux -T script -C none -d "$D/riscv.cmd" "$D/p1/tanager/riscv.scr" > /dev/null
for f in tanager.bit.bin fw_jump.bin payload.bin tanager.dtb; do head -c 4096 /dev/urandom > "$D/p1/tanager/$f"; done
dry_case() {   # <name> <ID> <STATUS> <expect regex>
  local n=$1 img=$D/$1.img
  { echo "mw.l 0x9a000000 $2"; echo "mw.l 0x9a000014 $3"; cat "$T/hook.cmd"; } > "$D/hook_$n.cmd"
  "$mkimage" -A riscv -O linux -T script -C none -d "$D/hook_$n.cmd" "$D/p1/hook.scr" > /dev/null
  rm -f "$D/p1.ext4"; mke2fs -q -t ext4 -d "$D/p1" "$D/p1.ext4" 30M
  dd if=/dev/zero of="$img" bs=1M count=64 2>/dev/null
  echo "2048,61440,83" | sfdisk -q "$img" > /dev/null
  dd if="$D/p1.ext4" of="$img" bs=512 seek=2048 conv=notrunc 2>/dev/null
  printf 'TANAGERMr0\n' | dd of="$img" bs=512 seek=2047 count=1 conv=sync,notrunc 2>/dev/null
  timeout 120 qemu-system-riscv64 -M virt -m 1G -nographic -bios default -kernel "$O/u-boot.bin" \
    -device sdhci-pci -device sd-card,drive=sd -drive id=sd,file="$img",format=raw,if=none > "$D/$n.out" 2>&1
  if grep -q "HOOK-TEST-END" "$D/$n.out" && grep -Eq "$4" "$D/$n.out" && ! grep -q "syntax error" "$D/$n.out"; then
    echo "PASS dry $n"
  else
    echo "FAIL dry $n (log $D/$n.out)"; fail=1
  fi
  sed -n '/Executing script at a1000000/,/HOOK-TEST-END/p' "$D/$n.out" | grep -a "tanager\|STUB" | tr -d '\r' | sed 's/^/    /'
}
dry_case park 0x54474e52 0x4 "STUB go 0x9c000000"
dry_case noid 0x12345678 0x4 "the RISC-V did not start"
dry_case nol2 0x54474e52 0x0 "the L2 did not initialise"
grep -q "the host bridge answers" "$D/noid.out" && { echo "FAIL dry noid: went past the ID check"; fail=1; }
[ $fail = 0 ] && echo "hook_qtest: ALL PASS" || echo "hook_qtest: FAILED"
