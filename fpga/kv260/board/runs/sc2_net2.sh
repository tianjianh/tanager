#!/bin/bash
# stage C network, step 2: Debian on sc2 with virtio-net bridged into br0 (net_bridge_up.sh first): the
# RISC-V takes its own lease from the laptop's connection sharing, syncs its clock, resolves names and
# reaches Debian's mirror (apt update: package lists only, nothing installed)
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc2 TG_DIR=$HOME/tanager/sc2net
D=$TG_DIR
ip -br link show br0 > /dev/null 2>&1 || { echo "no br0: run net_bridge_up.sh first"; exit 1; }
./tg.sh load > $D/load_net2.txt 2>&1 || { echo "load failed"; cat $D/load_net2.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_net2.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-2400} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-6000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $D/tanager-trixie.img --rng --net tanager0 --net-bridge br0 --dbg" TH_DURING="vq" \
  A53_DURING='ip -br link show master br0; ip=$(ip neigh show dev br0 | awk "/02:74:6e:67:72:01/ {print \$1}" | head -1); echo "the RISC-V at ${ip:-?}"; [ -n "$ip" ] && ping -c3 -W2 $ip' \
  CMDS="ip -4 -br addr; networkctl status eth0 --no-pager | head -16; ping -c3 -W2 192.168.137.177; resolvectl query deb.debian.org | head -3; timedatectl | head -6; sudo apt-get update 2>&1 | tail -5" \
  ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_net2.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
