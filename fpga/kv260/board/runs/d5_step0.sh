#!/bin/bash
# d5_step0.sh: step 0 of D5 (GEM3 Ethernet owned by the RISC-V in RISC-V mode; the SoC track's
# docs/spec/soc-d5-gem3.md, the Steps table's row 0), read-only probes in ARM mode (Ubuntu on the A53):
# eth0's MAC, its link (it must be 1000/Full: on the RISC-V, GEM3's transmit clock is fixed at the boot firmware's
# rate), GEM3's clocks and lpd_lsbus from the common clock framework, and five PS registers. Every PS register is
# read with busybox devmem, never tanager-host psrd: psrd first reads the PL host bridge's ID, and with no Tanager
# bitstream loaded that read hangs the board (the coordinator, 10-19). Nothing is written.
date -u +"== d5_step0 %F %T UTC, A53 up $(cut -d' ' -f1 /proc/uptime) s"
echo "active app: $(sudo xmutil listapps | awk '$NF ~ /^0->/ {print $1}')"
echo "== eth0"
ip link show eth0
ip -4 -br addr show eth0; ip -4 -br addr show br0 2>/dev/null
if command -v ethtool > /dev/null; then sudo ethtool eth0 | grep -E "Speed|Duplex|Link detected|Port:|Auto-negotiation|Advertised link modes|Link partner advertised" -A1 | grep -v "^--"
else echo "(no ethtool)"; fi
echo "sysfs: speed $(cat /sys/class/net/eth0/speed 2>&1), duplex $(cat /sys/class/net/eth0/duplex 2>&1), carrier $(cat /sys/class/net/eth0/carrier 2>&1)"
echo "driver: $(basename "$(readlink -f /sys/class/net/eth0/device/driver)") on $(basename "$(readlink -f /sys/class/net/eth0/device)")"
echo "== clocks (common clock framework)"
mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug
sudo grep -E "^ *(clock|-)|gem|lsbus|tsu|iopll" /sys/kernel/debug/clk/clk_summary | head -40
echo "-- the device tree's clocks for GEM3:"; tr '\0' ' ' < /proc/device-tree/axi/ethernet@ff0e0000/clock-names 2>/dev/null; echo
echo "== PS registers (busybox devmem, always-on LPD and IOU blocks and GEM3, which Ubuntu's eth0 has clocked)"
for r in "0xFF5E005C CRL_APB GEM3_REF_CTRL" "0xFF5E0230 CRL_APB RST_LPD_IOU0" "0xFF180098 IOU_SLCR MIO_PIN_38" \
         "0xFF0A0064 GPIO DATA_1_RO" "0xFF0E0294 GEM3 DCFG6"; do
  set -- $r; echo "$1 $2 $3: $(sudo busybox devmem $1 32)"
done
