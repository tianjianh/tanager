#!/bin/bash
# st2, run 1: load, then a plain boot with the SMP test; counters after the boot or twice in a hang
cd ~/tanager/tg || exit 1
export TG_APP=tanager-st2 TG_DIR=$HOME/tanager/st2
./tg.sh load > $TG_DIR/load_run1.txt 2>&1 || { echo "load failed"; cat $TG_DIR/load_run1.txt; exit 1; }
cat $TG_DIR/load_run1.txt
LOGIN_S=120 DBG=1 CMDS_S=300 CMDS="$(cat $TG_DIR/smp_cmds.txt)" ./tg.sh shell
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
