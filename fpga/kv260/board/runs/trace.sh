#!/bin/bash
# trace.sh APP DIR TAG: load APP, boot with the commit trace into a wrapped ring (TRACE_S, default 60 s)
app=$1; dir=$2; tag=${3:-run1}
cd ~/tanager/tg || exit 1
export TG_APP=$app TG_DIR=$dir
./tg.sh load > $dir/load_$tag.txt 2>&1 || { echo "load failed"; cat $dir/load_$tag.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $dir/load_$tag.txt
TRACE_S=${TRACE_S:-60} TRACE_WRAP=${TRACE_WRAP:-16} ./tg.sh tracefile
cp $dir/boot.trace $dir/boot_$tag.trace 2>/dev/null
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
