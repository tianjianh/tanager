#!/bin/bash
# Boots the Debian image (sw/build_debian.sh) on QEMU virt the way the board starts it (DR-147, docs/spec/soc.md
# §8.1): OpenSBI's fw_jump, U-Boot (sw/build_uboot.sh) and its extlinux menu, Debian's kernel and initrd, the
# root file system on virtio-blk, to the serial console's automatic login; then a few commands and a power-off.
# QEMU's own device tree is used (its virtio-mmio slots are not the board's), so this checks the image and
# U-Boot, not the board's tree. The image is not written: QEMU runs on a throwaway copy-on-write overlay.
# QEMU's virtio-net, on its user network with no way out (restrict=on), checks the image's DHCP and DNS setup.
# The image is either the disk image or its file system alone, as on the RISC-V's SD partition (§8.2: no
# partition table, booted by U-Boot's whole-disk try): the root is then vda, not vda1.
#   bash sw/qemu/debian_test.sh [image] [fw_jump.bin] [u-boot.bin]
# Exit status 0 on pass.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../env.sh"
img="$(realpath "${1:-$SOC_BUILD/debian/tanager-trixie.img}")"
fw="${2:-$SOC_BUILD/br-tanager_lp64d/images/fw_jump.bin}"
ub="${3:-$SOC_BUILD/u-boot/u-boot.bin}"
out="$SOC_BUILD/qemu/debian"
mkdir -p "$out"
log="$out/boot.log"
ov="$out/overlay.qcow2"
fifo="$out/console.in"
rm -f "$ov" "$fifo" "$log"
qemu-img create -q -f qcow2 -F raw -b "$img" "$ov"
mkfifo "$fifo"
exec 3<>"$fifo"                       # the console's input, held open for the whole run

qemu-system-riscv64 -M virt -smp 2 -m 2G -nographic -no-reboot -bios "$fw" -kernel "$ub" \
  -drive file="$ov",format=qcow2,if=none,id=hd0 -device virtio-blk-device,drive=hd0 \
  -netdev user,id=n0,restrict=on -device virtio-net-device,netdev=n0 < "$fifo" > "$log" 2>&1 &
qpid=$!
# The automatic login's shell prompt, within 15 minutes (systemd under TCG); then the commands and power-off
prompt='tanager@tanager:~\$'
for _ in $(seq 1 900); do
  grep -q "$prompt" "$log" 2>/dev/null && break
  kill -0 "$qpid" 2>/dev/null || break
  sleep 1
done
if grep -q "$prompt" "$log"; then
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
check 'reboot: Power down'                          "power-off"
none  '\[FAILED\]'                                  "no systemd unit fails"
none  'unable to resolve host'                      "the hostname resolves (/etc/hosts)"
none  'Failed to connect to system scope bus'       "the system bus is up (dbus)"
[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
