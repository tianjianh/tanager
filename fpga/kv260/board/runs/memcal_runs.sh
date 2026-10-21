#!/bin/bash
# memcal_runs.sh: verif-2's memcal-big.bin (tests/bench/mem; md5 aa8717894c1d1bd46ae196c176c2e122) twice on each of
# d4s2, d4r1 and d4r2, bare metal on the A53's Ubuntu.
# - Hart 0 runs it from 0x8000_0000 while the other harts park. It parks after MEMCAL-END, so --timeout ends each run.
# - This tanager-host refuses --kernel /dev/null, so each package's Image and virtio tree fill the two unused slots.
#   They load below 0x8400_0000, clear of memcal's image, stack and buffers.
# - Each app is loaded with tg.sh load (its dead-man armed), and k26-starter-kits comes back at the end.
# - Outputs go in ~/tanager/memcal/: memcal_<bitstream>_<n>.txt.
B=$HOME/tanager/memcal/memcal-big.bin; O=$HOME/tanager/memcal
[ "$(md5sum < $B | cut -c1-32)" = aa8717894c1d1bd46ae196c176c2e122 ] || { echo "memcal-big.bin's md5 differs: stop"; exit 1; }
cd ~/tanager/tg || exit 1
for v in d4s2 d4r1 d4r2; do
  export TG_APP=tanager-$v TG_DIR=$HOME/tanager/$v-smt2-c2-100
  ./tg.sh load > $O/load_$v.txt 2>&1 || { echo "$v: load failed"; tail -3 $O/load_$v.txt; continue; }
  grep -E "^loaded|^fan|^pl0" $O/load_$v.txt
  for n in 1 2; do
    ./tg.sh th boot --fw $B --kernel $TG_DIR/Image --dtb $TG_DIR/tanager-kv260-virtio.dtb --timeout 20 \
      > $O/memcal_${v}_$n.txt 2>&1 < /dev/null
    echo "$v run $n: exit $?, $(grep -c '^MEMCAL ' $O/memcal_${v}_$n.txt) MEMCAL lines, $(grep -c 'MEMCAL-END' $O/memcal_${v}_$n.txt) END"
  done
done
./tg.sh restore
echo "memcal runs done at $(date +%T)"
