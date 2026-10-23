#!/bin/bash
# memcal_release.sh NAME BITSTREAM [RUNS] [FW SHA256]: soc-2's bare-metal check for the 16 MiB write gap (10-23): verif-2's
# memcal-big.bin on a release build, through tanager-host as memcal_runs.sh did on 10-21, on the A53 in ARM mode.
# FW runs another bare-metal program the same way (soc-2's wsd.bin, 10-23), refused unless its sha256 starts with SHA256.
# - The app tanager-NAME is d4r2's stage C app files (tanager.dtbo, shell.json) with BITSTREAM, copied into
#   /lib/firmware/xilinx/tanager-NAME (logged in fpga/kv260/README.md's change log); d4r2's Image and virtio tree fill
#   the two unused slots, below 0x8400_0000.
# - tg.sh load loads it (refused unless xmutil lists it; its dead-man armed), and tg.sh restore brings
#   k26-starter-kits back at the end, so the fan stays Linux's.
# - A release build has no console through the host: MEMCAL's lines come out on COM5, in the laptop's logger. Each
#   run's tanager-host output goes in ~/tanager/NAME-app/memcal_N.txt (for FW, its name: wsd_N.txt).
V=$1; BIT=$2; N=${3:-2}; B=${4:-$HOME/tanager/memcal/memcal-big.bin}; R=$HOME/tanager/d4r2-smt2-c2-100; D=$HOME/tanager/$V-app
[ -f "$BIT" ] || { echo "no $BIT"; exit 1; }
if [ -n "$4" ]; then
  [ -n "$5" ] && [ "$(sha256sum < "$B" | cut -c1-${#5})" = "$5" ] || { echo "$B's sha256 isn't $5…: stop"; exit 1; }
else
  [ "$(md5sum < "$B" | cut -c1-32)" = aa8717894c1d1bd46ae196c176c2e122 ] || { echo "memcal-big.bin's md5 differs: stop"; exit 1; }
fi
O=$(basename "$B" .bin); [ -z "$4" ] && O=memcal
mkdir -p "$D" && cp "$BIT" "$D/tanager.bit.bin" && cp "$R/tanager.dtbo" "$R/shell.json" "$R/Image" "$R/tanager-kv260-virtio.dtb" "$D/" || exit 1
echo "app files: $(cd "$D" && sha256sum tanager.bit.bin tanager.dtbo | cut -c1-16 | tr '\n' ' ')"
cd ~/tanager/tg || exit 1
export TG_APP=tanager-$V TG_DIR=$D
# staged as tg.sh stage does, but without its copy of ~/tanager/tanager-host over the installed one
FW=/lib/firmware/xilinx/tanager-$V
[ -d "$FW" ] || sudo install -d -o ubuntu -g ubuntu "$FW"
cp "$D/tanager.bit.bin" "$D/tanager.dtbo" "$D/shell.json" "$FW/" || exit 1
sudo xmutil listapps | grep -q "^ *tanager-$V " || { sudo systemctl restart dfx-mgr; sleep 3; }
sudo xmutil listapps | grep -q "^ *tanager-$V " || { echo "tanager-$V isn't a dfx-mgr app: stop"; exit 1; }
./tg.sh load > "$D/load.txt" 2>&1 || { echo "load failed"; tail -3 "$D/load.txt"; exit 1; }
grep -E "^loaded|^fan|^pl0" "$D/load.txt"
for n in $(seq 1 "$N"); do
  date -u +"run $n at %T UTC"
  ./tg.sh th boot --fw "$B" --kernel "$D/Image" --dtb "$D/tanager-kv260-virtio.dtb" --timeout 20 > "$D/${O}_$n.txt" 2>&1 < /dev/null
  echo "run $n: exit $?; $(tail -2 "$D/${O}_$n.txt" | tr '\n' ' ')"
done
./tg.sh restore
./tg.sh status | grep -E "k26|fan"
echo "done at $(date -u +%T)"
