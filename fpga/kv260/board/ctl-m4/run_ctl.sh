#!/bin/bash
# control: the M4 bitstream (20435b1, which booted Linux in lockstep on 10-15) traced for 2 s, unwrapped,
# with the same images, the newest tanager-host and today's board
cd ~/tanager/tg || exit 1
export TG_APP=tanager-m4 TG_DIR=$HOME/tanager/ctl-m4
./tg.sh load > $TG_DIR/load_ctl.txt 2>&1 || { echo "load failed"; cat $TG_DIR/load_ctl.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $TG_DIR/load_ctl.txt
./tg.sh th info
TRACE_S=2 ./tg.sh tracefile
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
