#!/bin/bash
# Prepares the RISC-V's Debian on p3 for stage D's D4 (docs/spec/soc.md §8.2). Run inside it in stage C (root
# on the virtio disk, the network through the bridge), as root, with this directory copied next to it:
#   - the drivers Debian's kernel lacks, built by DKMS from the running kernel's own sources (tanager-ps-dkms:
#     the Arasan SD controller and the Cadence UART), rebuilt by DKMS on every kernel update;
#   - sdhci-of-arasan in the initrd, since D4's root is on the card;
#   - an automatic login on UART1 (ttyPS0), as on the PL UART: the user tanager has no password.
# Nothing changes for stage C: without the SD1 and UART1 nodes the drivers bind to nothing.
#   sudo bash stage_d_prep.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ver=1.0
kver=$(uname -r)
[ "$(id -u)" = 0 ] || { echo "$0: run as root" >&2; exit 1; }

apt-get update
apt-get install -y --no-install-recommends dkms build-essential xz-utils "linux-headers-$kver" linux-source-6.12
rm -rf "/usr/src/tanager-ps-$ver"
cp -r "$here/tanager-ps-dkms" "/usr/src/tanager-ps-$ver"
dkms remove "tanager-ps/$ver" --all 2>/dev/null || true
dkms install "tanager-ps/$ver" -k "$kver"

grep -qx sdhci-of-arasan /etc/initramfs-tools/modules || echo sdhci-of-arasan >> /etc/initramfs-tools/modules
update-initramfs -u -k "$kver"

mkdir -p /etc/systemd/system/serial-getty@ttyPS0.service.d
cp /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf /etc/systemd/system/serial-getty@ttyPS0.service.d/
systemctl enable serial-getty@ttyPS0.service

echo "== stage D drivers for $kver:"
modinfo -F filename sdhci-of-arasan xilinx_uartps
lsinitramfs "/boot/initrd.img-$kver" | grep -E 'sdhci-of-arasan|sdhci-pltfm|cqhci|mmc_block'
ls -la "/boot/vmlinux-$kver" "/boot/initrd.img-$kver"
