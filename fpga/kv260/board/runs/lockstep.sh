#!/bin/bash
# lockstep.sh APP DIR NAME HARTS: load APP, then Linux live through the checker with DIR's 768 MiB tree
# (copied into ~/tanager/lockstep as NAME-768m.dtb) and --harts=HARTS; logs renamed with NAME
app=$1; dir=$2; name=$3; harts=$4
cd ~/tanager/tg || exit 1
L=$HOME/tanager/lockstep
cp $dir/tanager-kv260-768m.dtb $L/$name-768m.dtb || exit 1
cmp $dir/fw_jump.bin $L/fw_jump.bin || { echo "fw_jump.bin differs from the lockstep set's"; exit 1; }
export TG_APP=$app TG_DIR=$dir
./tg.sh load > $dir/load_ls.txt 2>&1 || { echo "load failed"; cat $dir/load_ls.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $dir/load_ls.txt
LS_DTB=$name-768m.dtb LS_ARGS="--harts=$harts" LINUX_S=${LINUX_S:-7200} INJ_RD=${INJ_RD:-0} ./tg.sh ls-linux
inj=${INJ_RD:-0}
mv $L/console_linux$inj.txt $dir/ls_console_$name.txt; mv $L/ls_linux$inj.log $dir/ls_$name.log
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
