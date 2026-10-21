#!/bin/bash
# memgap_stagec.sh APP PKGDIR: soc-2's memory-gap set in stage C (Debian from p3 under tanager-host, as the stress
# runs; the RISC-V-mode half runs memgap_set.sh over SSH). The guest runs ~/memgap_set.sh stagec. When it prints
# MEMGAP-BRIDGE-NOW and starts its 60 s sysbench run, the A53 reads the PS's memory-path registers and the host
# bridge's DDR read latency (sudo sh ps-memregs --bridge, safe here: our bitstream holds the PL). Results go in
# ~/tanager/memgap/ on the A53: memregs_stagec.txt, the console log, and the guest's files from its MEMGAP-FILES block.
app=$1; pk=$2; P=/dev/mmcblk1p3; G=$HOME/tanager/memgap
cd ~/tanager/tg || exit 1
export TG_APP=$app TG_DIR=$HOME/tanager/sdpart
D=$TG_DIR
cp $pk/fw_jump.bin $D/fw_jump.bin && cp $pk/tanager-kv260-virtio.dtb $D/tanager-kv260-virtio.dtb || exit 1
if findmnt -rn -S $P > /dev/null; then echo "$P is mounted on the A53: stopping"; exit 1; fi
./tg.sh load > $D/load_memgap.txt 2>&1 || { echo "load failed"; cat $D/load_memgap.txt; exit 1; }
grep -E "^loaded|^fan|^pl0" $D/load_memgap.txt
: > $D/linux_shell.txt
( for i in $(seq 1 1800); do grep -a -q "MEMGAP-BRIDGE-NOW" $D/linux_shell.txt 2>/dev/null && break; sleep 2; done
  sleep 10; sudo sh $G/ps-memregs --bridge > $G/memregs_stagec.txt 2>&1; echo "ps-memregs --bridge exit $?" ) &
LOGIN_S=2400 DBG=1 CMDS_S=5400 OFF_S=900 SH_KERNEL=u-boot.bin SH_DTB=tanager-kv260-virtio.dtb SH_TIMEOUT=9000 \
  SH_USER=- SH_POWEROFF="sudo poweroff" SH_ARGS="--blk $P --rng --dbg" CMDS="cd ~/memgap && { [ -x memgap ] || gcc -O2 -pthread -o memgap memgap.c; } && bash ~/memgap_set.sh stagec" ./tg.sh shell
wait
cp $D/linux_shell.txt $G/linux_shell_memgap_stagec.txt
tr -d '\r' < $G/linux_shell_memgap_stagec.txt | sed -n '/MEMGAP-FILES-BEGIN/,/MEMGAP-FILES-END/p' > $G/files_stagec.txt
echo "guest files: $(grep -c '^== ' $G/files_stagec.txt)"
