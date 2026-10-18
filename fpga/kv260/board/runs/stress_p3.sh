#!/bin/bash
# stress_p3.sh APP PKGDIR TAG: the two-core stress on any stage C app (its fw_jump.bin and virtio tree from PKGDIR), until stopped or 72 h: Debian
# from the RISC-V's own partition (/dev/mmcblk1p3, booted by the SoC track's sdpart u-boot.bin; no network), the
# guest's ~/stress/stress.sh in a loop with checked results; stress_monitor.sh logs every 30 min. Stop it with a
# "q" into the console FIFO (~/tanager/sdpart/console.in): the guest finishes its pass, prints TG-42-DONE, and
# tg.sh powers it off.
app=$1; pk=$2; tag=$3; P=/dev/mmcblk1p3
cd ~/tanager/tg || exit 1
export TG_APP=$app TG_DIR=$HOME/tanager/sdpart
D=$TG_DIR
cp $pk/fw_jump.bin $D/fw_jump.bin && cp $pk/tanager-kv260-virtio.dtb $D/tanager-kv260-virtio.dtb || exit 1
[ -x $pk/tanager-host ] && $pk/tanager-host 2>&1 | grep -q "^  fan " && export FAN_HOST=$pk/tanager-host   # the PL regulator's status in the monitor
[ -b $P ] || { echo "no $P"; exit 1; }
if findmnt -rn -S $P > /dev/null; then echo "$P is mounted on the A53: stopping"; exit 1; fi
echo "$P: $(sudo blockdev --getsize64 $P) bytes, label $(sudo blkid -o value -s LABEL $P); u-boot.bin $(sha256sum $D/u-boot.bin | cut -c1-16), tanager-host $(sha256sum /usr/local/bin/tanager-host | cut -c1-16)"
./tg.sh load > $D/load_stress_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_stress_$tag.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_stress_$tag.txt
mon=$D/stress_monitor_$tag.txt; : > $mon
$HOME/tanager/runs/stress_monitor.sh $mon $D/linux_shell.txt &
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-259200} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-270000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $P --rng --dbg" CMDS="bash ~/stress/stress.sh" ./tg.sh shell
wait
cp $D/linux_shell.txt $D/linux_shell_stress_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
