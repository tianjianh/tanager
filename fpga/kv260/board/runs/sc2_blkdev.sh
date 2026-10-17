#!/bin/bash
# sc2_blkdev.sh TAG CMDSFILE: Debian on sc2 (70 MHz) with virtio-blk served from a BLOCK DEVICE, a loop device of
# sc2netc's image (losetup, detached at the end), as the RISC-V's own SD partition will be (tanager-host
# c2cc421: BLKGETSIZE64 for a block device, fsync on flush). No network.
tag=$1; cmdsf=$2
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc2 TG_DIR=$HOME/tanager/sc2netc
D=$TG_DIR
cp $HOME/tanager/sc2/fw_jump.bin $D/fw_jump.bin && cp $HOME/tanager/sc2/tanager-kv260-virtio.dtb $D/tanager-kv260-virtio.dtb || exit 1
loop=$(sudo losetup --find --show $D/tanager-trixie.img) || { echo "losetup failed"; exit 1; }
echo "loop device: $loop ($(sudo blockdev --getsize64 $loop) bytes) for $D/tanager-trixie.img"
echo "tanager-host $(sha256sum /usr/local/bin/tanager-host | cut -c1-16)"
./tg.sh load > $D/load_blk_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_blk_$tag.txt; sudo losetup -d $loop; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_blk_$tag.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-1800} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-6000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $loop --rng --dbg" CMDS="$(cat $cmdsf)" ./tg.sh shell
sudo losetup -d $loop && echo "loop device $loop detached"
cp $D/linux_shell.txt $D/linux_shell_blk_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
