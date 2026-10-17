#!/bin/bash
# Rehearsal of the A53 root shrink on a throwaway 2 GiB image file (p1 64 MiB vfat, p2 ext4 to the end, about
# 470 MB of files): the same guarded sequence the initramfs script will run. Size from resize2fs -P (minimum
# + 10 %), the partition 50 MiB above the filesystem; e2fsck -f; resize2fs (stop if it fails); check that the
# filesystem fits the new partition (stop if not); sfdisk -N 2; re-read; e2fsck; grow to the partition;
# compare checksums; append p3. Nothing on the real disk is touched.
set -u
F=$HOME/tanager/rehearsal.img; rm -f $F; truncate -s 2G $F
printf 'label: dos\nstart=2048, size=131072, type=c, bootable\nstart=133120, type=83\n' | sfdisk -q $F
L=$(sudo losetup --find --show -P $F); echo "test disk $L"
stop() { echo "STOP: $*"; sudo umount /mnt/tgr 2>/dev/null; sudo losetup -d $L; rm -f $F; exit 1; }
sudo mkfs.vfat -n TESTBOOT ${L}p1 > /dev/null; sudo mkfs.ext4 -q -L testroot ${L}p2
sudo mkdir -p /mnt/tgr; sudo mount ${L}p2 /mnt/tgr
for i in 1 2; do sudo cp -a /usr/lib/aarch64-linux-gnu /mnt/tgr/copy$i 2>/dev/null; done
sudo du -sh /mnt/tgr
sum() { (cd /mnt/tgr && sudo find . -type f -print0 | sort -z | xargs -0 sudo sha256sum | sha256sum); }
sum > /tmp/tgr.before; sudo umount /mnt/tgr
DISK=$L; ROOT=${L}p2; D=$(basename $L)
sudo e2fsck -f -y $ROOT > /dev/null 2>&1; r=$?; echo "e2fsck -f -y exit $r"; [ $r -le 1 ] || stop "e2fsck"
min=$(sudo resize2fs -P $ROOT 2>/dev/null | awk -F: '/minimum/ {gsub(/ /, "", $2); print $2}')
[ -n "$min" ] || stop "no minimum from resize2fs -P"
FS_MIB=$(( min * 4 * 11 / 10 / 1024 + 1 )); PART=$(( (FS_MIB + 50) * 2048 ))
echo "minimum $min blocks ($((min * 4 / 1024)) MiB): filesystem target $FS_MIB MiB, partition $((PART / 2048)) MiB"
time sudo resize2fs $ROOT ${FS_MIB}M; r=$?; echo "resize2fs exit $r"; [ $r = 0 ] || stop "resize2fs failed: the partition is left alone"
bs=$(sudo dumpe2fs -h $ROOT 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /, "", $2); print $2}')
bc=$(sudo dumpe2fs -h $ROOT 2>/dev/null | awk -F: '/^Block count/ {gsub(/ /, "", $2); print $2}')
echo "filesystem $((bs * bc)) bytes, new partition $((PART * 512)) bytes"
[ -n "$bs" ] && [ -n "$bc" ] && [ $((bs * bc)) -le $((PART * 512)) ] || stop "the filesystem would not fit the new partition"
sudo e2fsck -f -n $ROOT > /dev/null 2>&1 || stop "e2fsck after resize2fs"
start=$(cat /sys/block/$D/${D}p2/start); echo "p2 start $start"
echo "$start,$PART" | sudo sfdisk -q -N 2 $DISK; echo "sfdisk exit $?"
sudo partx -u $DISK; size=$(cat /sys/block/$D/${D}p2/size); echo "p2 size now $size (want $PART)"; [ "$size" = "$PART" ] || stop "p2 size"
sudo sfdisk -d $DISK | grep -E "p[12] :"
sudo e2fsck -f -n $ROOT > /dev/null 2>&1; echo "e2fsck -n on the new partition: exit $?"
sudo resize2fs $ROOT > /dev/null 2>&1; echo "grow to the partition: exit $?"
sudo mount $ROOT /mnt/tgr; sum > /tmp/tgr.after; df -h /mnt/tgr | tail -1; sudo umount /mnt/tgr
cmp -s /tmp/tgr.before /tmp/tgr.after && echo "DATA IDENTICAL after the shrink" || echo "DATA DIFFERS"
echo ",+,83" | sudo sfdisk -q --append $DISK; sudo partx -a $DISK 2>/dev/null; sudo partx -u $DISK
lsblk -o NAME,START,SIZE $L
sudo losetup -d $L; rm -f $F /tmp/tgr.before /tmp/tgr.after; echo "rehearsal done, test image removed"
