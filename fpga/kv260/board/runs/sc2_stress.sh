#!/bin/bash
# sc2_stress.sh TAG: the two-core stress on sc2 (70 MHz) until stopped: Debian from sc2netc's image (no network),
# the guest's ~/stress/stress.sh in a loop with checked results; stress_monitor.sh logs every 30 min. Stop it with
# a "q" into the console FIFO (~/tanager/sc2netc/console.in): the guest finishes its pass, prints TG-42-DONE,
# and tg.sh powers it off.
tag=$1
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc2 TG_DIR=$HOME/tanager/sc2netc
D=$TG_DIR
cp $HOME/tanager/sc2/fw_jump.bin $D/fw_jump.bin && cp $HOME/tanager/sc2/tanager-kv260-virtio.dtb $D/tanager-kv260-virtio.dtb || exit 1
./tg.sh load > $D/load_stress_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_stress_$tag.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_stress_$tag.txt
mon=$D/stress_monitor_$tag.txt; : > $mon
$HOME/tanager/runs/stress_monitor.sh $mon &
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-259200} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-270000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $D/tanager-trixie.img --rng --dbg" CMDS="bash ~/stress/stress.sh" ./tg.sh shell
wait
cp $D/linux_shell.txt $D/linux_shell_stress_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
