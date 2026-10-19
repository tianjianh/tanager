#!/bin/bash
# d4m_step6.sh copy|debian|install|riscv|post: step 6 of D4's boot-time modes (docs/spec/soc-d4-modes.md, DR-172) on
# the SoC track's package d4m-step6 (its README.md): Debian from p3 in RISC-V mode, its root read through SD1, the
# A53 parked. In RISC-V mode the A53 has no SSH; Debian is reached on COM5 (its console, autologin) from the laptop.
#   copy     the package onto p3's /root/stage-d6 (the RISC-V off; p3 checked clean after)
#   debian   stage C on d2 from p3: debian_install.sh (tanager-mode, the confirm unit; extlinux's root=), and stage
#            C's read rate of the same file system (/dev/vda) to set beside RISC-V mode's
#   install  the package's tanager/ onto p1 (/boot/firmware/tanager): U-Boot d4 as payload.bin
#   riscv    tanager-mode riscv and sync; the laptop then reboots the A53 with COM7 and COM5 logged
#   post     after Ubuntu is back: since when, the record, the fan, the apps, the last boot's end
cd ~/tanager/tg || exit 1
export TG_APP=tanager-d2 TG_DIR=$HOME/tanager/d2pkg
D=$TG_DIR; P=/dev/mmcblk1p3; K=$HOME/tanager/d4m-step6-pkg/d4m-step6; fw=/boot/firmware; mode=${1:-}
date -u +"== d4m_step6 $mode %F %T UTC, A53 up $(cut -d' ' -f1 /proc/uptime) s"
if [ "$mode" = stagec_d4s1 ]; then
  # step 6's diagnostic split: Debian from p3 in stage C on d4s1 itself (m6's configuration, BOARD_CTRL 0) with its
  # package's four-hart virtio tree, bounded: did RISC-V mode's panic come from m6 under Linux, or from the layout?
  export TG_APP=tanager-d4s1 TG_DIR=$HOME/tanager/d4s1-smt2-c2-100; D=$TG_DIR
  : ${LOGIN_S:=600} ${SH_TIMEOUT:=900} ${CMDS_S:=600}
  export LOGIN_S SH_TIMEOUT CMDS_S
fi
case "$mode" in
copy|debian|stagec_d4s1)
  if pgrep -f "[t]anager-host boot" > /dev/null; then echo "a boot is running: stop"; exit 1; fi
  if findmnt -rn -S $P > /dev/null; then echo "$P is mounted on the A53: stop"; exit 1; fi;;
esac
case "$mode" in
copy)
  (cd $K && sha256sum -c SHA256SUMS > /dev/null) || { echo "the package fails its SHA256SUMS"; exit 1; }
  sudo mount $P /mnt && sudo mkdir -p /mnt/root/stage-d6 && sudo cp -r $K/. /mnt/root/stage-d6/ && sudo chown -R 0:0 /mnt/root/stage-d6
  sudo sh -c "cd /mnt/root/stage-d6 && sha256sum -c SHA256SUMS" | grep -c ": OK$"
  grep -o 'root=[^ ]*' /mnt/boot/extlinux/extlinux.conf | sort | uniq -c
  sudo umount /mnt; sudo e2fsck -fn $P 2>&1 | tail -1; exit 0;;
debian)
  cmds='sudo bash /root/stage-d6/debian_install.sh; echo "debian_install exit $?"; systemctl is-enabled tanager-mode-confirm.service; findmnt -n /; cat /proc/cmdline; sudo dd if=/dev/vda of=/dev/null bs=1M count=256 iflag=direct 2>&1 | tail -1';;
stagec_d4s1)
  cmds='uname -r; nproc; cat /proc/cmdline; sudo dmesg | grep -i -E "smp:|oops|panic|BUG|segfault" | head; sudo dd if=/dev/vda of=/dev/null bs=1M count=64 iflag=direct 2>&1 | tail -1';;
install)
  (cd $K && sha256sum -c SHA256SUMS) || exit 1
  sudo cp $K/tanager/* $fw/tanager/ && sync
  (cd $K/tanager && for f in *; do echo "$(sha256sum < $f | cut -c1-16) $(sha256sum < $fw/tanager/$f | cut -c1-16) $f"; done)
  ls -la $fw/tanager; sudo /usr/local/sbin/tanager-mode status; exit 0;;
riscv)
  [ "$(tail -c +73 $fw/boot.scr.uimg | grep -a -c tanager-mode)" -ge 1 ] || { echo "no hook in boot.scr.uimg: stop"; exit 1; }
  cmp -s $K/tanager/payload.bin $fw/tanager/payload.bin || { echo "p1's payload.bin isn't step 6's: stop"; exit 1; }
  if pgrep -f "[t]anager-host boot" > /dev/null; then echo "a boot is running: stop"; exit 1; fi
  sudo /usr/local/sbin/tanager-mode riscv && sync; exit 0;;
post)
  echo "up since $(uptime -s)"
  sudo /usr/local/sbin/tanager-mode status
  echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, fancontrol $(systemctl is-active fancontrol)"
  sudo xmutil listapps | awk '$NF ~ /^0->/ {print "active app: " $1}'
  echo "RESET_REASON $(sudo busybox devmem 0xff5e0220 32)"
  echo "-- the last boot's end:"; journalctl -b -1 -n 4 --no-pager -o short-iso 2>&1; exit 0;;
*) echo "usage: $0 copy|debian|install|riscv|post"; exit 2;;
esac
./tg.sh load > $D/load_step6.txt 2>&1 || { echo "load failed"; cat $D/load_step6.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_step6.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-1800} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-6000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $P --rng --dbg" CMDS="$cmds" ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_step6_$mode.txt
echo "== the commands' output"
tr -d '\r' < $D/linux_shell_step6_$mode.txt | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | sed -n '/TG-$((40+2))-DONE/,/TG-42-DONE/p' | tail -n +2 | head -30
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
sudo e2fsck -fn $P 2>&1 | tail -1
