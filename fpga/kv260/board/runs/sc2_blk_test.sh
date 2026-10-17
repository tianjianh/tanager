#!/bin/bash
# The block-device test: boot 1 writes a 64 MiB file and its sha256, clean poweroff; then a read-only fsck of
# the image's root partition (a second loop device with partitions, read-only, e2fsck -fn); boot 2 checks the
# sha256 survived
D=$HOME/tanager/sc2netc; R=$HOME/tanager/runs
echo "===== boot 1: write"; $R/sc2_blkdev.sh w $R/blk_write_cmds.txt
echo "===== fsck (read-only) of the image's root partition"
lp=$(sudo losetup --find --show --read-only -P $D/tanager-trixie.img) && lsblk -o NAME,SIZE,FSTYPE,LABEL $lp
sudo e2fsck -fn ${lp}p1; echo "e2fsck exit $?"
sudo losetup -d $lp && echo "$lp detached"
echo "===== boot 2: verify"; $R/sc2_blkdev.sh v $R/blk_verify_cmds.txt
echo "block-device test done at $(date +%T)"
