#!/bin/bash
# Prepares the RISC-V's Debian on p3 for stage D's D4 (docs/spec/soc.md §8.2). Run inside it in stage C (root
# on the virtio disk, the network through the bridge), as root, with this directory copied next to it:
#   - the drivers Debian's kernel lacks, built by DKMS from the running kernel's own sources (tanager-ps-dkms:
#     the Arasan SD controller and the Cadence UART), rebuilt by DKMS on every kernel update;
#   - sdhci-of-arasan in the initrd, since D4's root is on the card, through a hook: udev loads it by modalias
#     only where the tree has SD1 (listed in /etc/initramfs-tools/modules it would load, and taint the kernel
#     as an out-of-tree module, at every boot; the board session, 10-18);
#   - an automatic login on UART1 (ttyPS0), as on the PL UART (the user tanager has no password), pulled in by
#     a udev rule when ttyPS0 appears: an enabled getty would make every stage C boot wait 91 s for it.
# Nothing changes for stage C: without the SD1 and UART1 nodes nothing loads.
#   sudo bash stage_d_prep.sh [--sd-only] [--config-only]
# --sd-only (the user's other choice, docs/spec/soc-d4-runsheet.md): only the SD controller's module; Debian's
# console and login stay on the PL UART. --config-only: the initrd hook and the login rule alone, for a p3 the
# DKMS part already ran on (it also removes the earlier modules-file line and getty enablement).
# Undo: dkms remove tanager-ps/1.0 --all; rm -rf /usr/src/tanager-ps-1.0; rm /etc/initramfs-tools/hooks/tanager-ps
# and update-initramfs -u; rm /etc/udev/rules.d/99-tanager-ttyps0.rules and the getty's drop-in directory
# (/etc/systemd/system/serial-getty@ttyPS0.service.d); optionally apt-get purge dkms linux-source-6.12
# linux-headers-$(uname -r).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ver=1.0
kver=$(uname -r)
sd_only=0 config_only=0
for a in "$@"; do
  case "$a" in
    --sd-only) sd_only=1 ;;
    --config-only) config_only=1 ;;
    *) echo "usage: $0 [--sd-only] [--config-only]" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "$0: run as root" >&2; exit 1; }

if [ $config_only = 0 ]; then
  apt-get update
  apt-get install -y --no-install-recommends dkms build-essential xz-utils "linux-headers-$kver" linux-source-6.12
  rm -rf "/usr/src/tanager-ps-$ver"
  cp -r "$here/tanager-ps-dkms" "/usr/src/tanager-ps-$ver"
  if [ $sd_only = 1 ]; then   # drop the Cadence UART from the package
    sed -i '/^BUILT_MODULE_NAME\[1\]/d; /^DEST_MODULE_LOCATION\[1\]/d' "/usr/src/tanager-ps-$ver/dkms.conf"
    sed -i 's/^obj-m := sdhci-of-arasan.o xilinx_uartps.o$/obj-m := sdhci-of-arasan.o/' "/usr/src/tanager-ps-$ver/Makefile"
  fi
  dkms remove "tanager-ps/$ver" --all 2>/dev/null || true
  dkms install "tanager-ps/$ver" -k "$kver"
fi

# The SD controller's module in the initrd, loaded by udev only where the tree has SD1
sed -i '/^sdhci-of-arasan$/d' /etc/initramfs-tools/modules
cat > /etc/initramfs-tools/hooks/tanager-ps <<'EOF'
#!/bin/sh
# Stage D's D4 (tanager-ps-dkms): the SD controller's module in the initrd; udev loads it by modalias only
# where the device tree has SD1, so other boots don't load (or taint the kernel with) the out-of-tree module.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
manual_add_modules sdhci-of-arasan
EOF
chmod 755 /etc/initramfs-tools/hooks/tanager-ps
update-initramfs -u -k "$kver"

# UART1's automatic login, pulled in by udev when ttyPS0 appears (D4's tree with the Cadence UART module)
systemctl disable serial-getty@ttyPS0.service 2>/dev/null || true
if [ $sd_only = 0 ]; then
  mkdir -p /etc/systemd/system/serial-getty@ttyPS0.service.d
  cp /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf /etc/systemd/system/serial-getty@ttyPS0.service.d/
  printf '%s\n' "# Stage D (tanager-ps-dkms): UART1's login when its tty appears" \
    'KERNEL=="ttyPS0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="serial-getty@ttyPS0.service"' \
    > /etc/udev/rules.d/99-tanager-ttyps0.rules
else
  rm -f /etc/udev/rules.d/99-tanager-ttyps0.rules
fi
systemctl daemon-reload

echo "== stage D drivers for $kver:"
modinfo -F filename sdhci-of-arasan
[ $sd_only = 1 ] || modinfo -F filename xilinx_uartps
lsinitramfs "/boot/initrd.img-$kver" | grep -E 'sdhci-of-arasan|sdhci-pltfm|cqhci|mmc_block'
echo "modules file lines: $(grep -c '^sdhci-of-arasan$' /etc/initramfs-tools/modules || true) (0: loaded on demand only)"
echo "serial-getty@ttyPS0: $(systemctl is-enabled serial-getty@ttyPS0.service 2>/dev/null || true) (disabled: started by udev)"
ls -la /etc/udev/rules.d/99-tanager-ttyps0.rules 2>/dev/null || true
ls -la "/boot/vmlinux-$kver" "/boot/initrd.img-$kver"
