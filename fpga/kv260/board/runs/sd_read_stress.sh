#!/bin/sh
# sd_read_stress.sh [SECONDS]: SD1 read stress on both CPUs of the RISC-V's Debian (as root), for the hunt for SD1's
# lost interrupt (s19b boot 1, 10-20). Both readers use O_DIRECT, so every read is an SD1 request and its interrupts:
# CPU 0 reads 4 KiB blocks from the card's middle (many small requests), CPU 1 reads 512 KiB blocks from its start
# (ADMA chains). After SECONDS (default 90) each gets SIGINT, so dd prints what it moved.
T=${1:-90}; D=/dev/mmcblk0
half=$(( $(cat /sys/block/mmcblk0/size) / 2 / 8 ))   # the card's middle, in 4 KiB blocks
taskset -c 0 timeout -s INT "$T" dd if=$D of=/dev/null bs=4k iflag=direct skip="$half" 2> /run/sdr_cpu0.txt &
taskset -c 1 timeout -s INT "$T" dd if=$D of=/dev/null bs=512k iflag=direct 2> /run/sdr_cpu1.txt &
wait
echo "cpu0 4k: $(tail -1 /run/sdr_cpu0.txt)"
echo "cpu1 512k: $(tail -1 /run/sdr_cpu1.txt)"
