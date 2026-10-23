#!/bin/bash
# fh_p1.sh backup|install K|tree F|back|riscv|status: p1's RISC-V-mode files for the four-hart bring-up (the coordinator,
# 10-22: soc-2's two-core, two-hart product form at 80 MHz), on the A53 in ARM mode. riscv.scr reads the files in
# /boot/firmware/tanager/; the current two-core 100 MHz image (d4r2 with the PMP-fixed tree) stays on p1 in
# /boot/firmware/tanager-d4r2-100/, so going back to it is one copy.
#   backup     tanager/ to the kept image's folder (FH_BACKUP, below), once (it won't overwrite one), checked file by file
#   install K  the package K's tanager/ files (K holds SHA256SUMS and tanager/) into tanager/, after K's check; the
#              files the package doesn't have stay as they are, and each one is listed
#   tree F     the tree F (a path) as tanager/tanager.dtb
#   back       the kept image's folder into tanager/: that image again
#   riscv      the boot hook present, then tanager-mode riscv and sync (the laptop then reboots the A53)
#   status     tanager/ and every tanager-*/ kept image with hashes, the mode record, p1's free space, the fan and
#              the apps
# FH_BACKUP=NAME names the kept image's folder for backup, install and back (default tanager-d4r2-100): for the
# four-hart 100 MHz bring-up, FH_BACKUP=tanager-dr187b-80 keeps dr187b's 80 MHz image for the switch back.
fw=/boot/firmware; A=$fw/tanager; B=$fw/${FH_BACKUP:-tanager-d4r2-100}; mode=${1:-}
date -u +"== fh_p1 $* %F %T UTC, A53 up $(cut -d' ' -f1 /proc/uptime) s"
hashes() { (cd "$1" && for f in *; do printf '%s %s\n' "$(sha256sum < "$f" | cut -c1-16)" "$f"; done); }
case "$mode" in
backup)
  [ -e "$B" ] && { echo "$B exists: no overwrite"; hashes "$B"; exit 1; }
  sudo mkdir "$B" && sudo cp -p "$A"/* "$B"/ && sync
  for f in "$A"/*; do cmp -s "$f" "$B/$(basename "$f")" || { echo "backup differs: $(basename "$f")"; exit 1; }; done
  echo "backup: $(ls "$B" | wc -l) files, $(du -sh "$B" | cut -f1)"; hashes "$B"; df -h "$fw" | tail -1;;
install)
  K=$2; [ -d "$K/tanager" ] || { echo "no $K/tanager"; exit 1; }
  [ -e "$B" ] || { echo "no kept image in $B yet: run backup first"; exit 1; }
  (cd "$K" && sha256sum -c SHA256SUMS > /dev/null) || { echo "$K fails its SHA256SUMS"; exit 1; }
  sudo cp "$K"/tanager/* "$A"/ && sync
  (cd "$K/tanager" && for f in *; do echo "$(sha256sum < "$f" | cut -c1-16) $(sha256sum < "$A/$f" | cut -c1-16) $f (package, p1)"; done)
  echo "kept from before:"; for f in "$A"/*; do [ -e "$K/tanager/$(basename "$f")" ] || echo "  $(basename "$f")"; done;;
tree)
  F=$2; [ -f "$F" ] || { echo "no $F"; exit 1; }
  sudo cp "$F" "$A/tanager.dtb" && sync && cmp -s "$F" "$A/tanager.dtb" && echo "tanager.dtb is now $(basename "$F") ($(sha256sum < "$F" | cut -c1-16))";;
back)
  [ -d "$B" ] || { echo "no $B"; exit 1; }
  sudo cp "$B"/* "$A"/ && sync
  for f in "$B"/*; do cmp -s "$f" "$A/$(basename "$f")" || { echo "differs after the copy: $(basename "$f")"; exit 1; }; done
  echo "tanager/ holds $(basename "$B")'s image again (files it doesn't have are left, and riscv.scr doesn't read them)"; hashes "$A";;
riscv)
  [ "$(tail -c +73 $fw/boot.scr.uimg | grep -a -c tanager-mode)" -ge 1 ] || { echo "no hook in boot.scr.uimg: stop"; exit 1; }
  if pgrep -f "[t]anager-host boot" > /dev/null; then echo "a stage C boot is running: stop"; exit 1; fi
  sudo /usr/local/sbin/tanager-mode riscv && sync && sudo /usr/local/sbin/tanager-mode status;;
status)
  echo "-- tanager/:"; hashes "$A"
  for d in "$fw"/tanager-*/; do [ -d "$d" ] && { echo "-- $(basename "$d")/ (kept):"; hashes "$d"; }; done
  sudo /usr/local/sbin/tanager-mode status; df -h "$fw" | tail -1
  echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, fancontrol $(systemctl is-active fancontrol)"
  sudo xmutil listapps | awk '$NF ~ /^0->/ {print "active app: " $1}'
  echo "RESET_REASON $(sudo busybox devmem 0xff5e0220 32)";;
*) echo "usage: $0 backup|install K|tree F|back|riscv|status"; exit 2;;
esac
