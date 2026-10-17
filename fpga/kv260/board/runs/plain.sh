#!/bin/bash
# plain.sh APP DIR TAG: load APP, boot DIR's images, log in, run the SMP test, read the counters
# (after the boot, or twice 5 s apart in a hang), poweroff; the board goes back to k26-starter-kits
app=$1; dir=$2; tag=${3:-run1}
cd ~/tanager/tg || exit 1
export TG_APP=$app TG_DIR=$dir
./tg.sh load > $dir/load_$tag.txt 2>&1 || { echo "load failed"; cat $dir/load_$tag.txt; exit 1; }
grep -E "^loaded|^fan|^pl0|^dead-man" $dir/load_$tag.txt
LOGIN_S=${LOGIN_S:-300} DBG=1 CMDS_S=${CMDS_S:-400} CMDS="$(cat ~/tanager/runs/smp_cmds.txt)" ./tg.sh shell
cp $dir/linux_shell.txt $dir/linux_shell_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
