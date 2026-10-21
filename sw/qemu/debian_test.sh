#!/bin/bash
# Boots the Debian image (sw/build_debian.sh) on QEMU virt the way the board starts it (DR-147, docs/spec/soc.md
# §8.1): OpenSBI's fw_jump, U-Boot (sw/build_uboot.sh) and its extlinux menu, Debian's kernel and initrd, the
# root file system on virtio-blk, to the serial console's automatic login; then a few commands and a power-off.
# QEMU's own device tree is used (its virtio-mmio slots are not the board's), so this checks the image and
# U-Boot, not the board's tree. The image is not written: QEMU runs on a throwaway copy-on-write overlay.
# QEMU's virtio-net, on its user network with no way out (restrict=on), checks the image's DHCP and DNS setup.
# The image is either the disk image or its file system alone, as on the RISC-V's SD partition (§8.2: no
# partition table, booted by U-Boot's whole-disk try): the root is then vda, not vda1.
# SMP=N runs N harts (default 2). HOTPLUG=1 also takes every hart but the first offline and back three times, which
# OpenSBI does with HSM stop and start (M7's four harts, docs/spec/m7-smt2-plan.md: SMP=4 HOTPLUG=1).
# RELEASE=1 runs on QEMU's own tree with the PLIC's M contexts made absent (-1), as a release build's trees have them
# (DR-180; QEMU's PLIC still has them, as a development build does). IRQS=1 moves the virtio and console interrupts
# to each hart in turn, with disk reads and console lines, and checks that every hart took some: every hart's S
# context works (with SMP=4 RELEASE=1, all four of a release build's).
#   [SMP=N] [HOTPLUG=1] [RELEASE=1] [IRQS=1] bash sw/qemu/debian_test.sh [image] [fw_jump.bin] [u-boot.bin]
# Exit status 0 on pass.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../env.sh"
img="$(realpath "${1:-$SOC_BUILD/debian/tanager-trixie.img}")"
fw="${2:-$SOC_BUILD/br-tanager_lp64d/images/fw_jump.bin}"
ub="${3:-$SOC_BUILD/u-boot/u-boot.bin}"
smp="${SMP:-2}"
hotplug="${HOTPLUG:-0}"
release="${RELEASE:-0}"
irqs="${IRQS:-0}"
out="$SOC_BUILD/qemu/debian"
mkdir -p "$out"
log="$out/boot.log"
ov="$out/overlay.qcow2"
fifo="$out/console.in"
rm -f "$ov" "$fifo" "$log"
qemu-img create -q -f qcow2 -F raw -b "$img" "$ov"
devs=(-drive file="$ov",format=qcow2,if=none,id=hd0 -device virtio-blk-device,drive=hd0
      -netdev user,id=n0,restrict=on -device virtio-net-device,netdev=n0)
dtb=()
if [ "$release" = 1 ]; then
  # QEMU's own tree for this machine, with each hart's M-mode PLIC context (hwirq 11) made -1, as sw/dts RELEASE=1 has
  qemu-system-riscv64 -M virt,dumpdtb="$out/qemu.dtb" -smp "$smp" -m 2G -nographic "${devs[@]}" > /dev/null
  dtc -q -I dtb -O dts -o "$out/qemu.dts" "$out/qemu.dtb"
  python3 - "$out/qemu.dts" "$out/qemu-rel.dts" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'(plic@[0-9a-f]+ \{[^}]*?interrupts-extended = <)([^>]*)(>)', s, re.S)
assert m, "no PLIC with interrupts-extended in QEMU's tree"
v = m.group(2).split()
assert len(v) % 2 == 0 and v[1::2].count("0x0b") > 0, v
v = [x if k % 2 == 0 or x != "0x0b" else "0xffffffff" for k, x in enumerate(v)]
open(sys.argv[2], "w").write(s[:m.start(2)] + " ".join(v) + s[m.end(2):])
PY
  dtc -q -I dts -O dtb -o "$out/qemu-rel.dtb" "$out/qemu-rel.dts"
  dtb=(-dtb "$out/qemu-rel.dtb")
fi
mkfifo "$fifo"
exec 3<>"$fifo"                       # the console's input, held open for the whole run

qemu-system-riscv64 -M virt -smp "$smp" -m 2G -nographic -no-reboot -bios "$fw" -kernel "$ub" "${dtb[@]}" \
  "${devs[@]}" < "$fifo" > "$log" 2>&1 &
qpid=$!
# The automatic login's shell prompt, within 15 minutes (systemd under TCG); then the commands and power-off
prompt='tanager@tanager:~\$'
for _ in $(seq 1 900); do
  grep -q "$prompt" "$log" 2>/dev/null && break
  kill -0 "$qpid" 2>/dev/null || break
  sleep 1
done
# Each command line goes in after the one before has printed its last line: typed-ahead input doesn't survive the IRQ
# rounds (Debian's sudo runs its commands in a pty, and something there drops the console's queued input)
wait_for() {  # <regex> <seconds>: the log has a line matching it; QEMU still running
  for _ in $(seq 1 "$2"); do
    grep -a -q -E "$1" "$log" 2>/dev/null && return 0
    kill -0 "$qpid" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}
if grep -q "$prompt" "$log"; then
  if [ "$irqs" = 1 ]; then
    # the PLIC's virtio and console interrupts to one hart at a time, then disk reads (direct, so the disk answers) and
    # console lines; each round prints how many of those interrupts that hart took meanwhile
    printf '%s\n' "irqs=\$(awk '/PLIC/ && /virtio|ttyS0/ {sub(\":\",\"\",\$1); printf \"%s \", \$1}' /proc/interrupts); echo IRQ-LIST \$irqs; for c in \$(seq 0 $((smp - 1))); do for i in \$irqs; do echo \$((1 << c)) | sudo tee /proc/irq/\$i/smp_affinity > /dev/null; done; b=\$(awk -v k=\$((c + 2)) '/PLIC/ && /virtio|ttyS0/ {s += \$k} END {print s}' /proc/interrupts); sudo dd if=/dev/vda of=/dev/null bs=64k count=64 skip=\$((c * 1024)) iflag=direct < /dev/null 2> /dev/null; for l in 1 2 3 4 5 6 7 8; do echo IRQ-LINE \$c \$l; done; a=\$(awk -v k=\$((c + 2)) '/PLIC/ && /virtio|ttyS0/ {s += \$k} END {print s}' /proc/interrupts); echo IRQ-HART \$c \$((a - b)); done" >&3
    wait_for "^IRQ-HART $((smp - 1)) [0-9]" 900 || true
  fi
  if [ "$hotplug" = 1 ]; then
    # every hart but the first offline, then online, three times; each round's sysfs lists, then the kernel's view
    cpus=$(seq -s ' ' 1 $((smp - 1)))
    printf '%s\n' "for r in 1 2 3; do for c in $cpus; do echo 0 | sudo tee /sys/devices/system/cpu/cpu\$c/online > /dev/null; done; echo HOTPLUG-ROUND \$r offline \$(cat /sys/devices/system/cpu/offline); for c in $cpus; do echo 1 | sudo tee /sys/devices/system/cpu/cpu\$c/online > /dev/null; done; echo HOTPLUG-ROUND \$r online \$(cat /sys/devices/system/cpu/online); done; echo HOTPLUG-CPUS \$(nproc)" >&3
    wait_for "^HOTPLUG-CPUS [0-9]" 900 || true
  fi
  printf '%s\n' 'cat /etc/debian_version; uname -r; findmnt -no SOURCE /; sudo -n true && echo SUDO-OK; readlink /etc/resolv.conf; systemctl show -p DefaultTimeoutStartUSec; /usr/lib/systemd/systemd-networkd-wait-online --timeout=60; ip -4 -br addr show scope global; sudo poweroff' >&3
  for _ in $(seq 1 300); do kill -0 "$qpid" 2>/dev/null || break; sleep 1; done
fi
kill "$qpid" 2>/dev/null && echo "QEMU killed (no power-off)" || true
wait "$qpid" 2>/dev/null || true
exec 3>&-
rm -f "$ov" "$fifo"
sed -i -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r//g' "$log"      # the console's colours and returns

fail=0
check() { if grep -q -E "$1" "$log"; then echo "  ok   $2"; else echo "  FAIL $2"; fail=1; fi; }
none()  { if grep -q -E "$1" "$log"; then echo "  FAIL $2"; fail=1; else echo "  ok   $2"; fi; }
echo "Debian on QEMU virt: $img, log $log"
check '^U-Boot 20'                                  "U-Boot starts"
check 'Retrieving file: .*vmlinu[xz]-'              "U-Boot's extlinux menu loads Debian's kernel"
check 'Retrieving file: .*initrd'                   "and its initrd"
check 'Linux version [0-9.]+.*riscv64'              "Debian's kernel starts"
check 'virtio_blk virtio[0-9]+: .*\[vda\]'          "virtio-blk disk vda (from the initramfs)"
check 'EXT4-fs \(vda1?\): mounted filesystem'       "the root file system mounts"
check 'Welcome to .*Debian GNU/Linux 13'            "systemd: Debian 13"
check 'tanager login: tanager \(automatic login\)'  "automatic login on the serial console"
check '^13\.[0-9]+'                                 "/etc/debian_version is 13.x"
check '^/dev/vda1?$'                                "the root is /dev/vda1, or /dev/vda for a file system alone"
check '^SUDO-OK'                                    "sudo without a password"
check '^\.\./run/systemd/resolve/stub-resolv\.conf$'   "/etc/resolv.conf is systemd-resolved's stub"
check ' 10\.0\.2\.15/24'                             "DHCP from QEMU's user network (systemd-networkd)"
check '^DefaultTimeoutStartUSec=10min$'              "systemd's start timeout raised for the board's clock"
check "smp: Brought up 1 node, $smp CPUs?"          "Linux brings up $smp harts"
check "riscv-plic: .* with $smp handlers for $((2 * smp)) contexts" "the PLIC: a handler for each hart's S context"
if [ "$irqs" = 1 ]; then
  for c in $(seq 0 $((smp - 1))); do
    n=$(sed -n "s/^IRQ-HART $c \([0-9]*\)\$/\1/p" "$log" | tail -1)
    if [ -n "$n" ] && [ "$n" -gt 0 ]; then echo "  ok   hart $c's S context took $n virtio and console interrupts"
    else echo "  FAIL hart $c's S context took none (${n:-no count})"; fail=1; fi
  done
fi
if [ "$hotplug" = 1 ]; then
  check "^HOTPLUG-ROUND 3 offline 1(-$((smp - 1)))?\$"  "three rounds: harts 1 to $((smp - 1)) offline (HSM stop)"
  check "^HOTPLUG-ROUND 3 online 0-$((smp - 1))\$"      "and back online (HSM start)"
  check "^HOTPLUG-CPUS $smp\$"                        "all $smp online at the end"
  none  'failed to come online|failed to stop|CPU[0-9]+: failed' "no hart failed to stop or start"
fi
check 'reboot: Power down'                          "power-off"
none  '\[FAILED\]'                                  "no systemd unit fails"
none  'unable to resolve host'                      "the hostname resolves (/etc/hosts)"
none  'Failed to connect to system scope bus'       "the system bus is up (dbus)"
[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
