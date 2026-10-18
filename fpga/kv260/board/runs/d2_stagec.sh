#!/bin/bash
# d2_stagec.sh: stage C once on d2 (the SoC track's step 5: DR-156's four L1D misses with the host DMA): Debian from
# the RISC-V's own partition (/dev/mmcblk1p3) with virtio-net bridged. In the guest (runs/d2_stagec_cmds.txt,
# BLOBSHA filled in here): the file p3_test wrote on sc3 verified; 64 MiB written with fsync, the page cache
# dropped, read back and compared (virtio-blk DMA both ways); 64 MiB fetched from an HTTP server on the A53
# through br0, its sha256 checked (virtio-net DMA).
cd ~/tanager/tg || exit 1
export TG_APP=tanager-d2 TG_DIR=$HOME/tanager/d2pkg
D=$TG_DIR; HT=$HOME/tanager/httpd; P=/dev/mmcblk1p3
$HOME/tanager/runs/net_bridge_ensure.sh || { echo "no working br0: stopping"; exit 1; }
if findmnt -rn -S $P > /dev/null; then echo "$P is mounted on the A53: stopping"; exit 1; fi
mkdir -p $HT; [ -f $HT/blob64 ] || head -c 67108864 /dev/urandom > $HT/blob64
sha=$(sha256sum $HT/blob64 | cut -d" " -f1); echo "blob64 $sha"
ip=$(ip -4 -br addr show br0 | awk '{print $3}' | cut -d/ -f1); echo "the A53 on br0: $ip"
sed "s/BLOBSHA/$sha/g; s/A53IP/$ip/g" $HOME/tanager/runs/d2_stagec_cmds.txt > $D/stagec_cmds.txt
(cd $HT && exec python3 -m http.server 8000 --bind $ip) > /dev/null 2>&1 &
httpd=$!
./tg.sh load > $D/load_stagec.txt 2>&1 || { echo "load failed"; cat $D/load_stagec.txt; kill $httpd; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_stagec.txt
LOGIN_S=${LOGIN_S:-2400} DBG=1 CMDS_S=${CMDS_S:-1800} OFF_S=${OFF_S:-900} SH_KERNEL=u-boot.bin \
  SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=${SH_TIMEOUT:-6000} SH_USER=- SH_POWEROFF="sudo poweroff" \
  SH_ARGS="--blk $P --rng --net tanager0 --net-bridge br0 --dbg" CMDS="$(cat $D/stagec_cmds.txt)" ./tg.sh shell
kill $httpd 2>/dev/null
cp $D/linux_shell.txt $D/linux_shell_stagec.txt
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
