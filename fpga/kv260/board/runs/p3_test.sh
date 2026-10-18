#!/bin/bash
# The RISC-V's own partition (DR-147, stage D's groundwork): boot 1 writes a 64 MiB file and its sha256, then a
# clean power-off; a read-only fsck of p3 on the A53 (the partition is the file system itself); boot 2 checks
# the sha256 survived
R=$HOME/tanager/runs
echo "===== boot 1: write"; $R/sc3_p3.sh w $R/p3_write_cmds.txt
echo "===== fsck (read-only) of /dev/mmcblk1p3"
sudo e2fsck -fn /dev/mmcblk1p3; echo "e2fsck exit $?"
echo "===== boot 2: verify"; $R/sc3_p3.sh v $R/p3_verify_cmds.txt
echo "p3 test done at $(date +%T)"
