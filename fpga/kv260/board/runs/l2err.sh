#!/bin/bash
# l2err.sh TAG SIZE: p0f plain boot (no trace) on the 768m tree with the window SIZE; the L2 error
# counter at +3 s and +8 s from a second session, and after the shell's commands
tag=$1; size=$2
cd ~/tanager/tg || exit 1
export TG_APP=tanager-p0f TG_DIR=$HOME/tanager/p0f
D=$TG_DIR
./tg.sh load > $D/load_l2err_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_l2err_$tag.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_l2err_$tag.txt
( for t in 3 8; do sleep $t; echo "dbg at about +$t s:"; ./tg.sh th dbg | grep -E "L2 error|levels"; done ) &
LOGIN_S=120 DBG=1 CMDS_S=60 SH_DTB=tanager-kv260-768m.dtb SH_ARGS="--size $size" \
  CMDS="free -m; head -1 /proc/meminfo; dmesg | grep -i -E 'memory|Machine model'" ./tg.sh shell
wait
cp $D/linux_shell.txt $D/linux_shell_l2err_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
