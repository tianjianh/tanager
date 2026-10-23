#!/bin/bash
# OpenSBI's remote fences and IPI with a hart mask that names a stopped hart (soc.md §5, Tanager's patch set tg1):
# builds sw/qemu/sbi_mask, a bare-metal S-mode payload, and runs it on QEMU virt with four harts under fw_jump.bin.
# With fw_jump only the boot hart starts, so the others are stopped (HSM). tg1 (the default firmware, this tree's
# sw/build_opensbi.sh): the fences go through (error 0) and the IPI reaches the started hart (error 0, its own SSIP
# set); a hart that doesn't exist is still SBI_ERR_INVALID_PARAM (-3). EXPECT=upstream checks upstream 1.9's answers
# instead (the board's b0094d23...: -3 for every mask with the stopped hart, before any IPI).
#   [EXPECT=tg1|upstream] bash sw/qemu/sbi_mask_test.sh [fw_jump.bin]
# Exit status 0 on pass.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../env.sh"
source "$here/../versions.sh"
source "$here/../../tools/env.sh" > /dev/null              # the bare-metal toolchain (riscv-none-elf)
fw="$(realpath "${1:-$SOC_BUILD/opensbi-$OPENSBI_REV/platform/generic/firmware/fw_jump.bin}")"
expect="${EXPECT:-tg1}"
[ "$expect" = tg1 ] || [ "$expect" = upstream ] || { echo "sbi_mask_test.sh: EXPECT is tg1 or upstream" >&2; exit 2; }
out="$SOC_BUILD/qemu/sbi_mask"
mkdir -p "$out"
riscv-none-elf-gcc -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -fno-builtin -nostdlib \
  -Wall -Werror -T "$here/sbi_mask/link.ld" -o "$out/sbi_mask.elf" "$here/sbi_mask/start.S" "$here/sbi_mask/sbi_mask.c"
riscv-none-elf-objcopy -O binary "$out/sbi_mask.elf" "$out/sbi_mask.bin"
log="$out/run-$expect.log"
timeout 60 qemu-system-riscv64 -M virt -smp 4 -m 256M -nographic -bios "$fw" -kernel "$out/sbi_mask.bin" \
  > "$log" 2>&1 || true
fails=0
want() {  # a line of the log that must be there
  if grep -q -x -- "$1" <(tr -d '\r' < "$log"); then echo "  ok: $1"; else echo "  MISSING: $1"; fails=$((fails + 1)); fi
}
echo "sbi_mask_test: $(sha256sum "$fw" | cut -c1-16)... ($expect), log $log"
if [ "$expect" = tg1 ]; then s=0; ssip=1; else s=-3; ssip=0; fi
want "SBI-MASK rfence-stopped err=$s"
want "SBI-MASK rfence-asid-stopped err=$s"
want "SBI-MASK fencei-stopped err=$s"
want "SBI-MASK ipi-stopped err=$s ssip=$ssip"
want "SBI-MASK rfence-nohart err=-3"
want "SBI-MASK ipi-nohart err=-3"
want "SBI-MASK rfence-all err=0"
want "SBI-MASK done"
grep -q -E '^SBI-MASK hart [0-9]+ stopped [0-9]+' <(tr -d '\r' < "$log") || { echo "  MISSING: a stopped hart"; fails=$((fails + 1)); }
if [ "$fails" = 0 ]; then echo "sbi_mask_test: PASS"; else echo "sbi_mask_test: FAIL ($fails)"; exit 1; fi
