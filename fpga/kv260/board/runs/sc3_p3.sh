#!/bin/bash
# sc3_p3.sh TAG CMDSFILE: Debian on sc3 (100 MHz) from the RISC-V's own SD partition, /dev/mmcblk1p3, served whole
# as the virtio disk (the partition holds the file system alone, LABEL=tanager-root), booted by the SoC track's
# sdpart u-boot.bin (it tries extlinux on the whole virtio disk first). No network.
tag=$1; cmdsf=$2; P=/dev/mmcblk1p3
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc3 TG_DIR=$HOME/tanager/sdpart
D=$TG_DIR
cp $HOME/tanager/sc3/fw_jump.bin $D/fw_jump.bin && cp $HOME/tanager/sc3/tanager-kv260-virtio.dtb $D/tanager-kv260-virtio.dtb || exit 1
[ -b $P ] || { echo "no $P"; exit 1; }
if findmnt -rn -S $P > /dev/null; then echo "$P is mounted on the A53: stopping"; exit 1; fi
echo "$P: $(sudo blockdev --getsize64 $P) bytes, label $(sudo blkid -o value -s LABEL $P)"
echo "u-boot.bin $(sha256sum $D/u-boot.bin | cut -c1-16), tanager-host $(sha256sum /usr/local/bin/tanager-host | cut -c1-16)"
./tg.sh load > $D/load_p3_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_p3_$tag.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_p3_$tag.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-1800} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-6000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $P --rng --dbg" CMDS="$(cat $cmdsf)" ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_p3_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
