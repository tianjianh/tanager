#!/bin/bash
# d4_fixup.sh copy|fix|check: the SoC track's fixes for part A's two side effects (stage_d_prep.sh --config-only,
# 5a74c34), applied at the start of D4's slot (the coordinator). No network is needed (no apt, no DKMS).
#   copy:  the new stage_d_prep.sh onto p3's /root/stage-d (the RISC-V off; p3 checked clean after)
#   fix:   stage C on d2 from p3: `stage_d_prep.sh --config-only` (the initrd hook instead of the modules-file line,
#          the ttyPS0 getty disabled, the udev rule), logged to /root/stage-d/fixup.log
#   check: the next stage C boot: no sdhci lines under "Loading essential drivers", /proc/sys/kernel/tainted 0,
#          no ttyPS0 device job, the getty disabled, the initrd still holding sdhci-of-arasan
cd ~/tanager/tg || exit 1
export TG_APP=tanager-d2 TG_DIR=$HOME/tanager/d2pkg
D=$TG_DIR; P=/dev/mmcblk1p3; mode=${1:-}
if pgrep -f "[t]anager-host boot" > /dev/null; then echo "a boot is running: stop"; exit 1; fi
if findmnt -rn -S $P > /dev/null; then echo "$P is mounted on the A53: stop"; exit 1; fi
case "$mode" in
copy)
  sudo mount $P /mnt && sudo cp ~/tanager/d4pkg/debian/stage_d_prep.sh /mnt/root/stage-d/stage_d_prep.sh && sudo chown 0:0 /mnt/root/stage-d/stage_d_prep.sh
  sudo sha256sum /mnt/root/stage-d/stage_d_prep.sh ~/tanager/d4pkg/debian/stage_d_prep.sh | cut -c1-16
  sudo umount /mnt; sudo e2fsck -fn $P 2>&1 | tail -1;;
fix)
  cmds='sudo bash -c '"'"'bash /root/stage-d/stage_d_prep.sh --config-only 2>&1 | tee /root/stage-d/fixup.log; echo "stage_d_prep exit ${PIPESTATUS[0]}" | tee -a /root/stage-d/fixup.log'"'"'';;
check)
  cmds='echo "tainted: $(cat /proc/sys/kernel/tainted)"; lsmod | grep -E "sdhci|uartps" || echo "no sdhci or uartps module loaded"; echo "getty: $(systemctl is-enabled serial-getty@ttyPS0.service 2>&1)"; systemctl list-jobs --no-pager | tail -3; sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -E "sdhci|cqhci|mmc_block"; grep -c "^sdhci-of-arasan$" /etc/initramfs-tools/modules; ls -la /etc/initramfs-tools/hooks/tanager-ps /etc/udev/rules.d/99-tanager-ttyps0.rules; sudo dmesg | grep -i -E "sdhci|taint" || echo "no sdhci or taint line in dmesg"';;
*) echo "usage: $0 copy|fix|check"; exit 2;;
esac
[ "$mode" = copy ] && exit 0
./tg.sh load > $D/load_$mode.txt 2>&1 || { echo "load failed"; cat $D/load_$mode.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_$mode.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-1800} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-6000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $P --rng --dbg" CMDS="$cmds" ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_fixup_$mode.txt
if [ "$mode" = check ]; then
  echo "== the boot's own lines"
  tr -d '\r' < $D/linux_shell_fixup_check.txt | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -a -E "Loading essential drivers|sdhci|taint|ttyPS0" | head -8
fi
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
