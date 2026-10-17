#!/bin/bash
# Rehearse the EXACT initramfs script (runs/tg-shrink-root.premount) on a throwaway loop image: p1 vfat with the
# .go flag, p2 ext4 with about 470 MB of files; TG_* point it at the loop device, the log at /tmp, the console at
# stdout, and reboot at echo. Then check: p2's size, e2fsck, the data, the log on p1, the flag renamed; and that a
# second run does nothing (one-shot).
set -u
F=$HOME/tanager/rehearsal.img; rm -f $F; truncate -s 2G $F
printf 'label: dos\nstart=2048, size=131072, type=c, bootable\nstart=133120, type=83\n' | sfdisk -q $F
L=$(sudo losetup --find --show -P $F); echo "test disk $L"
sudo mkfs.vfat -n TESTBOOT ${L}p1 > /dev/null; sudo mkfs.ext4 -q -L testroot ${L}p2
sudo mkdir -p /mnt/tgr; sudo mount ${L}p1 /mnt/tgr; sudo touch /mnt/tgr/tg-shrink-root.go; sudo umount /mnt/tgr
sudo mount ${L}p2 /mnt/tgr; for i in 1 2; do sudo cp -a /usr/lib/aarch64-linux-gnu /mnt/tgr/copy$i 2>/dev/null; done
sum() { (cd /mnt/tgr && sudo find . -type f -print0 | sort -z | xargs -0 sudo sha256sum | sha256sum); }
sum > /tmp/tgs.before; sudo umount /mnt/tgr
min=$(sudo resize2fs -P ${L}p2 2>/dev/null | awk -F: '/minimum/ {gsub(/ /, "", $2); print $2}')
FS=$(( min * 4 * 11 / 10 / 1024 + 1 )); PT=$(( FS + 50 )); echo "minimum $((min * 4 / 1024)) MiB: TG_FS_MIB=$FS TG_PART_MIB=$PT"
sudo rm -f /tmp/tgs.log
echo "===== run 1 (armed)"
sudo TG_DISK=$L TG_TTY=/dev/stdout TG_LOG=/tmp/tgs.log TG_FS_MIB=$FS TG_PART_MIB=$PT TG_REBOOT=echo sh $HOME/tanager/runs/tg-shrink-root.premount; echo "script exit $?"
echo "p2 now $(cat /sys/block/${L##*/}/${L##*/}p2/size) sectors (want $((PT * 2048)))"
sudo e2fsck -f -n ${L}p2 > /dev/null 2>&1; echo "e2fsck -n exit $?"
sudo resize2fs ${L}p2 > /dev/null 2>&1; echo "grow exit $?"
sudo mount ${L}p2 /mnt/tgr; sum > /tmp/tgs.after; sudo umount /mnt/tgr
cmp -s /tmp/tgs.before /tmp/tgs.after && echo "DATA IDENTICAL" || echo "DATA DIFFERS"
sudo mount ${L}p1 /mnt/tgr; ls /mnt/tgr; echo "-- log on p1:"; grep -E "TG-SHRINK|p2 :" /mnt/tgr/tg-shrink-root.log; sudo umount /mnt/tgr
echo "===== run 2 (the flag is gone: must do nothing)"
sudo TG_DISK=$L TG_TTY=/dev/stdout TG_LOG=/tmp/tgs2.log TG_FS_MIB=$FS TG_PART_MIB=$PT TG_REBOOT=echo sh $HOME/tanager/runs/tg-shrink-root.premount; echo "script exit $?"; ls /tmp/tgs2.log 2>&1 | head -1
sudo losetup -d $L; rm -f $F /tmp/tgs.before /tmp/tgs.after; sudo rm -f /tmp/tgs.log /tmp/tgs2.log; echo "rehearsal done"
