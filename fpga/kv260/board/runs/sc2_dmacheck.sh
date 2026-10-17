#!/bin/bash
# sc2 step 1 again, with the SoC track's tanager-host 2fc4a71 (it releases the uncore itself for dma
# read/write/check, the cores held): load, then dma check, dma status and vq
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc2 TG_DIR=$HOME/tanager/sc2
D=$TG_DIR; NEW=$HOME/tanager/host-2fc4a71/tanager-host
./tg.sh load > $D/load_dmacheck.txt 2>&1 || { echo "load failed"; cat $D/load_dmacheck.txt; exit 1; }
grep -E "^loaded|^fan" $D/load_dmacheck.txt
# the same guard as tg.sh's th: only while tanager-sc2 holds the PL
nh() { sudo xmutil listapps | awk -v a="$TG_APP" '$1 == a && $NF ~ /^0->/ { f = 1 } END { exit !f }' || { echo "refused: $TG_APP not loaded"; return 1; }; echo "\$ tanager-host(2fc4a71) $*"; sudo "$NEW" "$@"; }
nh load --fw $D/fw_jump.bin --kernel $D/Image --dtb $D/tanager-kv260-virtio.dtb
nh dma check
nh dma check
nh dma status
nh info | grep -E "status|virtio"
nh vq
./tg.sh restore | tail -1
echo "orphan sleeps after the run: $(pgrep -c -x sleep -P 1)"
