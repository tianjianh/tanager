#!/bin/bash
# sc2_ab.sh HOSTBIN TAG: the SoC track's virtio-net A/B on the 20261015c image: tanager-host HOSTBIN (a file in
# sc2netc) serves the run. In the RISC-V: wait for the network, ping -s 1400 the A53, time apt-get update and
# apt-get download of the kernel package (IPv4: the laptop's sharing has no IPv6), with top. On the A53:
# tanager-host's CPU time every 15 s (utime+stime ticks of the oldest tanager-host), into hostcpu_TAG.txt
hb=$1; tag=$2
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc2 TG_DIR=$HOME/tanager/sc2netc
D=$TG_DIR
$HOME/tanager/runs/net_bridge_ensure.sh || { echo "no working br0: stopping"; exit 1; }
sudo install -m 0755 "$D/$hb" /usr/local/bin/tanager-host || exit 1
echo "tanager-host for this run: $(sha256sum /usr/local/bin/tanager-host | cut -c1-16) ($hb)"
./tg.sh load > $D/load_ab_$tag.txt 2>&1 || { echo "load failed"; cat $D/load_ab_$tag.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_ab_$tag.txt
( while sleep 15; do p=$(pgrep -o -x tanager-host); [ -n "$p" ] && echo "$(date +%s) $(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null)"; done ) > $D/hostcpu_$tag.txt 2>&1 &
sampler=$!
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-3600} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-7200} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $D/tanager-trixie.img --rng --net tanager0 --net-bridge br0 --dbg" \
  CMDS="$(cat $HOME/tanager/runs/ab_cmds.txt)" ./tg.sh shell
kill $sampler 2>/dev/null
cp $D/linux_shell.txt $D/linux_shell_ab_$tag.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
