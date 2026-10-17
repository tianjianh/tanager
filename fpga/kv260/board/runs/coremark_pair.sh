#!/bin/bash
# coremark_pair.sh APP TAG: the dual-core CoreMark point. The DR-141 bench Image (~/tanager/bench) boots with the bench
# device tree minus tanager.bench=1 (bench-manual-h02.dtb: harts 0 and 2, the PMU map), so the set doesn't
# start and a shell does. In it (runs/coremark_pair_cmds.txt): coremark-a alone, then two copies at once, each
# at least 10 s (argument 0). The image has no taskset, so each copy's CPU is sampled every second instead.
app=$1; tag=$2
cd ~/tanager/tg || exit 1
export TG_APP=$app TG_DIR=$HOME/tanager/bench
D=$TG_DIR
./tg.sh load > $D/load_cmpair_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_cmpair_$tag.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_cmpair_$tag.txt
./tg.sh th info | grep -E "core clock"
LOGIN_S=${LOGIN_S:-300} CMDS_S=${CMDS_S:-600} SH_DTB=bench-manual-h02.dtb \
  CMDS="$(cat $HOME/tanager/runs/coremark_pair_cmds.txt)" ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_cmpair_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
