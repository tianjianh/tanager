#!/bin/bash
# sc_bench.sh APP PKGDIR TAG: the stage C workload on bitstream APP (its fw_jump.bin and virtio device tree from
# PKGDIR) with sc2netc's frozen Debian image (gcc and sysbench installed: tanager-trixie.img.bench, copied fresh
# each run): boot time, gcc build and run, sysbench, ping and a 112 MB download (runs/bench_cmds.txt)
app=$1; pk=$2; tag=$3
cd ~/tanager/tg || exit 1
export TG_APP=$app TG_DIR=$HOME/tanager/sc2netc
D=$TG_DIR
$HOME/tanager/runs/net_bridge_ensure.sh || { echo "no working br0: stopping"; exit 1; }
cp --sparse=always $D/tanager-trixie.img.bench $D/tanager-trixie.img && echo "image reset from .bench"
cp $pk/fw_jump.bin $D/fw_jump.bin && cp $pk/tanager-kv260-virtio.dtb $D/tanager-kv260-virtio.dtb || exit 1
echo "fw $(sha256sum $D/fw_jump.bin | cut -c1-16), dtb $(sha256sum $D/tanager-kv260-virtio.dtb | cut -c1-16), host $(sha256sum /usr/local/bin/tanager-host | cut -c1-16)"
./tg.sh load > $D/load_bench_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_bench_$tag.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_bench_$tag.txt
./tg.sh th info | grep -E "configuration|core clock|capabilities"
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-3600} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-7200} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $D/tanager-trixie.img --rng --net tanager0 --net-bridge br0 --dbg" \
  CMDS="$(cat $HOME/tanager/runs/bench_cmds.txt)" ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_bench_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
