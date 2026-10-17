#!/bin/bash
# bench.sh APP DIR NAME: load APP, then the DR-141 workload set once on DIR's bench device tree
# (copied into ~/tanager/bench as NAME-bench.dtb, with the bench set's own fw_jump.bin and Image)
app=$1; dir=$2; name=$3
cd ~/tanager/tg || exit 1
cp $dir/tanager-kv260-bench.dtb ~/tanager/bench/$name-bench.dtb || exit 1
export TG_APP=$app TG_DIR=$dir
./tg.sh load > $dir/load_bench.txt 2>&1 || { echo "load failed"; cat $dir/load_bench.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $dir/load_bench.txt
BENCH_DTB=$name-bench.dtb NAME=$name BOOTS=${BOOTS:-1} BENCH_S=${BENCH_S:-3600} ./tg.sh bench
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
