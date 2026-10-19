#!/bin/bash
# d4m_step4.sh install|check|invalid|riscv|arm: step 4 of D4's boot-time modes (docs/spec/soc-d4-modes.md, DR-172)
# on the SoC track's package d4m-step4 (its README.md): the mode check in the A53's boot script, the RISC-V never
# started (p1's riscv.scr is a stub that returns). The reboots in between are the laptop's (`sudo systemctl reboot`
# over SSH), with COM7, the A53's console, logged read-only.
#   install  the package's install.sh (the hook, p1's tanager/, the tool; the old script and FIT kept as
#            *.tanager-pre), then the kept and new scripts compared
#   check    after a boot: since when, the record, the hook in boot.scr.uimg, the fan, the apps, the last boot's end
#   invalid  the README's invalid record (TANAGERMx9) into sector 2047
#   riscv    tanager-mode riscv: the next boot takes the RISC-V path (the stub), trial 0 -> 1
#   arm      tanager-mode arm
P=$HOME/tanager/d4m-step4-pkg/d4m-step4
fw=/boot/firmware
date -u +"== d4m_step4 ${1:-} %F %T UTC, A53 up $(cut -d' ' -f1 /proc/uptime) s"
case "${1:-}" in
install)
  pgrep -f "[t]anager-host (boot|run)" > /dev/null && { echo "a tanager-host boot or run is going: stop"; exit 1; }
  (cd $P && sha256sum -c SHA256SUMS)
  sudo bash $P/install.sh; echo "install.sh exit $?"
  ls -la $fw $fw/tanager /etc/flash-kernel/ubootenv.d/ /usr/local/sbin/tanager-mode
  echo "-- the kept script (boot.scr.uimg.tanager-pre) against the new one:"
  diff <(tail -c +73 $fw/boot.scr.uimg.tanager-pre | tr -d '\000') <(tail -c +73 $fw/boot.scr.uimg | tr -d '\000')
  echo "-- the kept FIT against the new one: $(cmp $fw/image.fit.tanager-pre $fw/image.fit > /dev/null 2>&1 && echo identical || echo differ)"
  sha256sum $fw/boot.scr.uimg* $fw/image.fit* | cut -c1-16,65-;;
check)
  echo "up since $(uptime -s)"
  sudo /usr/local/sbin/tanager-mode status
  sudo dd if=/dev/mmcblk1 bs=512 skip=2047 count=1 2>/dev/null | od -A d -c | head -3
  echo "boot.scr.uimg lines naming tanager-mode: $(tail -c +73 $fw/boot.scr.uimg | grep -a -c tanager-mode)"
  echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, fancontrol $(systemctl is-active fancontrol)"
  sudo xmutil listapps | awk '$NF ~ /^0->/ {print "active app: " $1}'
  echo "-- the last boot's end:"; journalctl -b -1 -n 4 --no-pager -o short-iso 2>&1;;
invalid)
  printf 'TANAGERMx9\n' | sudo dd of=/dev/mmcblk1 bs=512 seek=2047 count=1 conv=sync,notrunc,fsync
  sudo /usr/local/sbin/tanager-mode status;;
riscv|arm)
  sudo /usr/local/sbin/tanager-mode $1;;
*) echo "usage: $0 install|check|invalid|riscv|arm"; exit 2;;
esac
