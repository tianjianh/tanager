#!/bin/bash
# stage C, real work under Debian: on the network through br0 (made sure of first), install gcc and
# sysbench from Debian's mirror, build and time a small C program, and a short sysbench set
# (runs/debian_work_cmds.txt); then sudo poweroff
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc2 TG_DIR=$HOME/tanager/sc2net
D=$TG_DIR
$HOME/tanager/runs/net_bridge_ensure.sh || { echo "no working br0: stopping"; exit 1; }
./tg.sh load > $D/load_work.txt 2>&1 || { echo "load failed"; cat $D/load_work.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_work.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-5400} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-9000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $D/tanager-trixie.img --rng --net tanager0 --net-bridge br0 --dbg" TH_DURING="vq" \
  CMDS="$(cat $HOME/tanager/runs/debian_work_cmds.txt)" ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_work.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
