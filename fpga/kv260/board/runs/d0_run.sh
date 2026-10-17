#!/bin/bash
# d0_run.sh: stage D's D0 probes that need sc3 loaded (soc.md §8.2; the SoC track's d0-probes-20261017 package in
# ~/tanager/d0): four PS register reads with `tanager-host psrd`, then the ADMA probe `tanager-host dma adma`
# (two copies inside the RISC-V's carve-out: DDR -> HPM1 -> DDR). Every tanager-host call checks first that sc3
# holds the PL; AFI FM6's registers are read only if CRL_APB's RST_LPD_TOP shows its reset (bit 19) released;
# ADMA channel 8's runtime PM goes back to auto at the end. Fan control stays with the A53's fancontrol.
cd ~/tanager/tg || exit 1
export TG_APP=tanager-sc3 TG_DIR=$HOME/tanager/d0
H=$HOME/tanager/d0/tanager-host; DEV=/sys/bus/platform/devices/ffaf0000.dma-controller
ours() { sudo xmutil listapps | grep -q -E "^ *tanager-sc3 .* 0->"; }
fan() { echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, AMS temp1 $(( $(cat /sys/devices/platform/ams/hwmon/hwmon*/temp1_input) / 1000 )) C, fancontrol $(systemctl is-active fancontrol)"; }
h() { ours || { echo "STOP: tanager-sc3 does not hold the PL"; return 1; }; echo "\$ tanager-host $*"; sudo $H "$@"; }
echo "tanager-host $(sha256sum $H | cut -c1-16)"
./tg.sh load || { echo "load failed"; exit 1; }
fan
h info | grep -E "configuration|core clock|capabilities" || { ./tg.sh restore; exit 1; }
echo "== PS registers (read-only)"
h psrd 0xFF5E023C
rst=$(sudo $H psrd 0xFF5E023C 2>/dev/null | sed -n 's/^0x[0-9a-f]*: \(0x[0-9a-f]*\).*/\1/p')
h psrd 0xFF980000
if [ -n "$rst" ] && [ $(( rst >> 19 & 1 )) = 0 ]; then
  echo "RST_LPD_TOP = $rst: AFI FM6 (bit 19) is out of reset; reading its registers"
  h psrd 0xFF9B0000; h psrd 0xFF9B0014
else
  echo "RST_LPD_TOP = ${rst:-unread}: AFI FM6 (bit 19) held in reset or unknown; its registers are not read"
fi
echo "== ADMA probe"
S=$HOME/tanager/sc3
h load --fw $S/fw_jump.bin --kernel $S/Image --dtb $S/tanager-kv260-virtio.dtb || { ./tg.sh restore; exit 1; }   # sets the RAM window (the cores stay held)
echo "$DEV before: control=$(cat $DEV/power/control) runtime_status=$(cat $DEV/power/runtime_status)"
echo on | sudo tee $DEV/power/control > /dev/null
sleep 1
echo "$DEV with control=on: runtime_status=$(cat $DEV/power/runtime_status)"
h dma adma; rc=$?
echo "dma adma exit $rc"
echo auto | sudo tee $DEV/power/control > /dev/null
sleep 1
echo "$DEV after: control=$(cat $DEV/power/control) runtime_status=$(cat $DEV/power/runtime_status)"
h dma status
sudo dmesg | tail -n 5 | grep -i -E "dma|smmu|axi|error|abort|SError" || echo "dmesg: nothing about DMA, SMMU or bus errors in the last lines"
fan
./tg.sh restore
fan
