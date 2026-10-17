#!/bin/bash
# l2err_stall.sh: C1 again (wrapped 2^16 trace ring, no --lossless, 20 s) with trace status and the L2
# error counter read at about +3, +6 and +12 s: does "trace on" mean "cores stalled"?
cd ~/tanager/tg || exit 1
export TG_APP=tanager-p0f TG_DIR=$HOME/tanager/p0f
D=$TG_DIR
./tg.sh load > $D/load_l2err_C3.txt 2>&1 || { echo "load failed"; cat $D/load_l2err_C3.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_l2err_C3.txt
( for t in 3 3 6; do sleep $t; echo "--- at about +$SECONDS s:"; ./tg.sh th trace status | tail -2; ./tg.sh th dbg | grep -E "L2 error"; done ) &
./tg.sh th boot --fw $D/fw_jump.bin --kernel $D/Image --dtb $D/tanager-kv260-768m.dtb \
  --trace $D/l2err_C3.trace --trace-wrap --trace-log2 16 --timeout 20 < /dev/null > $D/l2err_C3.console 2>&1
echo "boot exit $?"; tail -2 $D/l2err_C3.console
wait
rm -f $D/l2err_C3.trace
./tg.sh restore | tail -1
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
