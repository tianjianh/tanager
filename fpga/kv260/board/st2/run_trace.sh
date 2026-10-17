#!/bin/bash
# st2, run 2: load, then a boot with the commit trace into a wrapped ring (30 s), 768m tree, window zeroed
cd ~/tanager/tg || exit 1
export TG_APP=tanager-st2 TG_DIR=$HOME/tanager/st2
./tg.sh load > $TG_DIR/load_run2.txt 2>&1 || { echo "load failed"; cat $TG_DIR/load_run2.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $TG_DIR/load_run2.txt
TRACE_S=30 TRACE_WRAP=16 ./tg.sh tracefile
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
