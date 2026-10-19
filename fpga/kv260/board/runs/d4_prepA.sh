#!/bin/bash
# d4_prepA.sh: stage D's D4 part A (soc.md §8.2; the user's DR-168: both modules): the RISC-V's Debian on p3 in
# stage C on d2, bridged for Debian's mirror, runs the SoC track's /root/stage-d/stage_d_prep.sh (copied there
# from the A53 with p3 unmounted), its output kept in /root/stage-d/prep.log and on the console; then a clean
# power-off. A failed DKMS build or apt step is reported, not worked around (the coordinator).
cd ~/tanager/tg || exit 1
export TG_APP=tanager-d2 TG_DIR=$HOME/tanager/d2pkg
D=$TG_DIR; P=/dev/mmcblk1p3
$HOME/tanager/runs/net_bridge_ensure.sh || { echo "no working br0: stopping"; exit 1; }
if findmnt -rn -S $P > /dev/null; then echo "$P is mounted on the A53: stopping"; exit 1; fi
./tg.sh load > $D/load_prepA.txt 2>&1 || { echo "load failed"; cat $D/load_prepA.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_prepA.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-10800} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-14400} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $P --rng --net tanager0 --net-bridge br0 --dbg" \
  CMDS="$(cat $HOME/tanager/runs/d4_prepA_cmds.txt)" ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_prepA.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
