#!/bin/bash
# d4m_step5.sh precheck|install|riscv|post: step 5 of D4's boot-time modes (docs/spec/soc-d4-modes.md, DR-172) on the
# SoC track's package d4m-step5 (its README.md): the first boot in RISC-V mode, bare metal. The A53's U-Boot runs
# p1's riscv.scr (the bitstream, the PS set-up, the images, the release, the park), the RISC-V runs OpenSBI and the
# test image, whose SBI system reset resets the board back into ARM mode (the record then says trial 1).
#   precheck  under Linux, with the same bitstream loaded by xmutil: the values riscv.scr writes and checks before
#             its first read of the PL (PL0_REF_CTRL, AFI_FS) and the host bridge's ID, then k26-starter-kits back
#   install   the package's tanager/ onto p1 (/boot/firmware/tanager), checked against its SHA256SUMS
#   riscv     tanager-mode riscv and sync; the laptop then reboots the A53 with COM7 and COM5 logged
#   post      after the board is back: since when, the record, the fan, the apps, the last boot's end
P=$HOME/tanager/d4m-step5-pkg/d4m-step5
fw=/boot/firmware
cd ~/tanager/tg || exit 1
export TG_APP=tanager-d4s1 TG_DIR=$HOME/tanager/d4s1-smt2-c2-100
H=$TG_DIR/tanager-host
active() { sudo xmutil listapps | awk '$1 == "tanager-d4s1" && $NF ~ /^0->/ { f = 1 } END { exit !f }'; }
date -u +"== d4m_step5 ${1:-} %F %T UTC, A53 up $(cut -d' ' -f1 /proc/uptime) s"
case "${1:-}" in
precheck)
  pgrep -f "[t]anager-host (boot|run)" > /dev/null && { echo "a tanager-host boot or run is going: stop"; exit 1; }
  echo "before the load: PL0_REF_CTRL $(sudo busybox devmem 0xff5e00c0 32), AFI_FS $(sudo busybox devmem 0xfd615000 32)"
  ./tg.sh load || exit 1
  echo "d4s1 loaded by xmutil: PL0_REF_CTRL $(sudo busybox devmem 0xff5e00c0 32) (riscv.scr writes 0x01010A00)," \
       "AFI_FS $(sudo busybox devmem 0xfd615000 32) (riscv.scr: bits 11:8 = 0x8)"
  active && { echo "\$ tanager-host peek 0x0 (riscv.scr expects 0x54474E52)"; sudo $H peek 0x0; sudo $H peek 0x1404; }
  ./tg.sh restore;;
install)
  (cd $P && sha256sum -c SHA256SUMS) || exit 1
  sudo cp $P/tanager/* $fw/tanager/ && sync
  (cd $P/tanager && for f in *; do echo "$(sha256sum < $f | cut -c1-16) $(sha256sum < $fw/tanager/$f | cut -c1-16) $f"; done)
  ls -la $fw/tanager
  sudo /usr/local/sbin/tanager-mode status;;
riscv)
  [ "$(tail -c +73 $fw/boot.scr.uimg | grep -a -c tanager-mode)" -ge 1 ] || { echo "no hook in boot.scr.uimg: stop"; exit 1; }
  cmp -s $P/tanager/riscv.scr $fw/tanager/riscv.scr || { echo "p1's riscv.scr isn't step 5's: stop"; exit 1; }
  sudo /usr/local/sbin/tanager-mode riscv && sync;;
post)
  echo "up since $(uptime -s)"
  sudo /usr/local/sbin/tanager-mode status
  echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, fancontrol $(systemctl is-active fancontrol)"
  sudo xmutil listapps | awk '$NF ~ /^0->/ {print "active app: " $1}'
  echo "RESET_REASON $(sudo busybox devmem 0xff5e0220 32)"
  echo "-- the last boot's end:"; journalctl -b -1 -n 4 --no-pager -o short-iso 2>&1;;
*) echo "usage: $0 precheck|install|riscv|post"; exit 2;;
esac
