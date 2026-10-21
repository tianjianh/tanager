#!/bin/sh
# sd1_probe_undo.sh: on the RISC-V's Debian (p3), as root, the undo of the SD1 interrupt hunt's set-up, as
# fpga/kv260/README.md's change log lists it (10-20). The hunt is done: DR-176's fix, d4r2, 60 of 60 clean boots.
#   - the probe and its initramfs hook and init-top script (the board track's RAM-root versions);
#   - soc-2's originals kept in /usr/local/lib/sd1probe/, with the static busybox;
#   - sd1-irq-watch.service (disabled since boot 38) and sd_read_stress.sh;
#   - iomem=relaxed: /etc/default/u-boot back from its .tanager-pre copy, then u-boot-update;
#   - busybox, purged (installed for the probe's devmem); its purge rebuilds the initramfs, and so does the last step.
# Every file is named; nothing is removed by a recursive delete.
set -u
for f in /usr/local/sbin/sd1-irq-probe /etc/initramfs-tools/hooks/sd1-irq-probe \
         /etc/initramfs-tools/scripts/init-top/sd1-irq-probe /usr/local/lib/sd1probe/busybox \
         /usr/local/lib/sd1probe/hook.soc2 /usr/local/lib/sd1probe/init-top.soc2 \
         /etc/systemd/system/sd1-irq-watch.service /home/tanager/sd_read_stress.sh; do
  [ -e "$f" ] && rm "$f" && echo "removed $f"
done
rmdir /usr/local/lib/sd1probe && echo "removed /usr/local/lib/sd1probe/"
systemctl daemon-reload
if [ -e /etc/default/u-boot.tanager-pre ]; then
  mv /etc/default/u-boot.tanager-pre /etc/default/u-boot && u-boot-update > /dev/null && echo "u-boot: $(grep U_BOOT_PARAMETERS /etc/default/u-boot)"
fi
grep -c iomem=relaxed /boot/extlinux/extlinux.conf | sed 's/^/extlinux lines with iomem=relaxed: /'
DEBIAN_FRONTEND=noninteractive apt-get purge -y busybox > /tmp/purge_busybox.txt 2>&1; echo "busybox purge exit $?"
update-initramfs -u > /tmp/uir_undo.txt 2>&1; echo "update-initramfs exit $?"
lsinitramfs /boot/initrd.img-$(uname -r) | grep -c -E "sd1probe|sd1-irq" | sed 's/^/initramfs entries for the probe: /'
dpkg -l busybox 2>/dev/null | grep -c "^ii" | sed 's/^/busybox installed: /'
