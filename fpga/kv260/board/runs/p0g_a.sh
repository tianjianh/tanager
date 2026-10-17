#!/bin/bash
# p0g run a: the traced boot that made the L2 errors (wrapped 2^16 ring to /dev/null, 20 s), with dbg from a
# second session at about +6 s and run --dbg at the end: the first L2 error and the first refused burst
cd ~/tanager/tg || exit 1
export TG_APP=tanager-p0g TG_DIR=$HOME/tanager/p0g
D=$TG_DIR
./tg.sh load > $D/load_a.txt 2>&1 || { echo "load failed"; cat $D/load_a.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_a.txt
( sleep 6; echo "=== dbg from a second session, about 6 s into the boot:"; ./tg.sh th dbg ) &
./tg.sh th boot --fw $D/fw_jump.bin --kernel $D/Image --dtb $D/tanager-kv260-768m.dtb --trace /dev/null \
  --trace-log2 16 --trace-wrap --dbg --timeout 20 < /dev/null > $D/a_console.txt 2>&1
echo "boot exit $?"
wait
echo "=== run --dbg at the exit (from the console file):"
tr -d '\r' < $D/a_console.txt | sed -n '/tanager-host\] timeout/,$p'
./tg.sh restore | tail -1
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
