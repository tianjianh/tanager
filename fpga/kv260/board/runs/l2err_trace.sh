#!/bin/bash
# l2err_trace.sh TAG LOSSLESS: p0f boot on the 768m tree with the trace in a wrapped 2^16 ring for 20 s,
# with or without --lossless; the L2 error counter at +3 s and +10 s
tag=$1; ll=$2
cd ~/tanager/tg || exit 1
export TG_APP=tanager-p0f TG_DIR=$HOME/tanager/p0f
D=$TG_DIR
./tg.sh load > $D/load_l2err_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_l2err_$tag.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_l2err_$tag.txt
( for t in 3 7; do sleep $t; echo "dbg at about +$((t == 3 ? 3 : 10)) s:"; ./tg.sh th dbg | grep -E "L2 error|levels"; done ) &
./tg.sh th boot --fw $D/fw_jump.bin --kernel $D/Image --dtb $D/tanager-kv260-768m.dtb $ll \
  --trace $D/l2err_$tag.trace --trace-wrap --trace-log2 16 --timeout 20 < /dev/null > $D/l2err_$tag.console 2>&1
echo "boot exit $?"; tail -3 $D/l2err_$tag.console
wait
./tg.sh th dbg | grep -E "L2 error|levels"
rm -f $D/l2err_$tag.trace
./tg.sh restore | tail -1
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
