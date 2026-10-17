#!/bin/bash
# sc_tcp.sh APP PKGDIR TAG: the TCP look at the internet download for the SoC track: the bench's setup (sc2netc's
# frozen image reset, bridged, tanager-host as installed) with runs/tcp_cmds.txt in the RISC-V (ss -ti every 5 s
# during a 112 MB apt-get download, nstat, ip -s link) and ip -s link of tanager0 and br0 on the A53
app=$1; pk=$2; tag=$3
cd ~/tanager/tg || exit 1
export TG_APP=$app TG_DIR=$HOME/tanager/sc2netc
D=$TG_DIR
$HOME/tanager/runs/net_bridge_ensure.sh || { echo "no working br0: stopping"; exit 1; }
cp --sparse=always $D/tanager-trixie.img.bench $D/tanager-trixie.img && echo "image reset from .bench"
cp $pk/fw_jump.bin $D/fw_jump.bin && cp $pk/tanager-kv260-virtio.dtb $D/tanager-kv260-virtio.dtb || exit 1
echo "host $(sha256sum /usr/local/bin/tanager-host | cut -c1-16)"
./tg.sh load > $D/load_tcp_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_tcp_$tag.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_tcp_$tag.txt
./tg.sh th info | grep -E "core clock"
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-3600} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-7200} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $D/tanager-trixie.img --rng --net tanager0 --net-bridge br0 --dbg" \
  A53_DURING="ip -s link show tanager0; ip -s link show br0" \
  CMDS="$(cat $HOME/tanager/runs/tcp_cmds.txt)" ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_tcp_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
