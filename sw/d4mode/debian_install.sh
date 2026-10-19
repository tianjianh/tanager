#!/bin/bash
# D4 modes, the RISC-V's side (docs/spec/soc-d4-modes.md, step 6): on the RISC-V's Debian (p3), as root, from the
# package directory sw/d4mode/build.sh makes. Run in stage C or in RISC-V mode:
#   sudo bash debian_install.sh          tanager-mode in /usr/local/sbin, tanager-mode-confirm.service enabled
#   sudo bash debian_install.sh --undo   both removed
# The unit runs `tanager-mode confirm` at every clean shutdown or reboot: in RISC-V mode (root on the card) it sets
# the record's trial back to 0, so the next boot is RISC-V mode again. In stage C (root on the virtio disk) the tool
# refuses the disk, and the unit's stop fails harmlessly. `tanager-mode arm` then `reboot` goes to ARM mode.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
unit=/etc/systemd/system/tanager-mode-confirm.service
[ "$(id -u)" = 0 ] || { echo "$0: run as root" >&2; exit 1; }
if [ "${1:-}" = --undo ]; then
  systemctl disable tanager-mode-confirm.service 2>/dev/null || true
  rm -f "$unit" /usr/local/sbin/tanager-mode
  systemctl daemon-reload
  echo "undone"
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: $0 [--undo]" >&2; exit 2; }
install -m 755 "$here/tanager-mode" /usr/local/sbin/tanager-mode
install -m 644 "$here/tanager-mode-confirm.service" "$unit"
systemctl daemon-reload
systemctl enable tanager-mode-confirm.service
systemctl start tanager-mode-confirm.service
systemctl is-active tanager-mode-confirm.service
/usr/local/sbin/tanager-mode status || echo "(not on the SD card: stage C)"
# RISC-V mode boots this Debian through U-Boot's extlinux from the card: its root must be found by label or UUID,
# not as stage C's /dev/vda (u-boot-update takes it from /etc/fstab, LABEL=tanager-root)
echo "extlinux: $(grep -m1 -o 'root=[^ ]*' /boot/extlinux/extlinux.conf || echo 'no root= line')"
grep -q 'root=\(LABEL\|UUID\|PARTUUID\)=' /boot/extlinux/extlinux.conf ||
  echo "$0: extlinux.conf's root= is no label or UUID: RISC-V mode would not find it" >&2
