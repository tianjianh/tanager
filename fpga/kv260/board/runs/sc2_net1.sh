#!/bin/bash
# stage C network, step 1: Debian through U-Boot on sc2 with virtio-net (slot 2) on a TAP device that
# tanager-host makes and removes (tanager0). Host-only: nothing on the A53 changes. IPv6 link-local pings
# both ways; vq during the run; the counters at the exit (--dbg)
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc2 TG_DIR=$HOME/tanager/sc2net
D=$TG_DIR
./tg.sh load > $D/load_net1.txt 2>&1 || { echo "load failed"; cat $D/load_net1.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_net1.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-900} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-4800} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $D/tanager-trixie.img --rng --net tanager0 --dbg" TH_DURING="vq" \
  A53_DURING="ip -br link show tanager0; ip -6 -br addr show dev tanager0; ping -6 -c3 -W2 ff02::1%tanager0" \
  CMDS="dmesg | grep -i -E 'virtio_net|eth0'; ip -br link; ip -br addr; ping -6 -c3 -W2 ff02::1%eth0; networkctl status eth0 --no-pager | head -12" \
  ./tg.sh shell
cp $D/linux_shell.txt $D/linux_shell_net1.txt
ip -br link show tanager0 2>&1 | head -1
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
