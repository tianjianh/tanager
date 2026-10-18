#!/bin/bash
# d1_run.sh pre|test: stage D's first milestone D1 (soc.md §8.2) with the SoC track's d1-smt2-c2-100 package
# (~/tanager/d1, staged as the app tanager-d1): the RISC-V reaches the PS's peripherals through the PS window.
#   pre:  load the app, step 0's read-only pre-checks (AFI FM6's width, RST_LPD_IOU2), restore k26-starter-kits
#   test: load, step 0 again, refuse unless TTC1's reset bit (TTC1_BIT, UG1087 RST_LPD_IOU2) is clear, then step 1
#         (ps_d1.bin: UART1's status and FIFO only, IOU_SLCR reads, TTC1's interrupt, TTC0 and UART0 denied),
#         step 2's checks (dmesg, UART1's driver counters, the console's getty, fancontrol), restore
# Every tanager-host call checks first that tanager-d1 holds the PL. Fan control stays with the A53's fancontrol.
mode=${1:-pre}; bit=${TTC1_BIT:-12}
cd ~/tanager/tg || exit 1
export TG_APP=tanager-d1 TG_DIR=$HOME/tanager/d1
H=$HOME/tanager/d1/tanager-host
ours() { sudo xmutil listapps | grep -q -E "^ *tanager-d1 .* 0->"; }
fan() { echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, AMS temp1 $(( $(cat /sys/devices/platform/ams/hwmon/hwmon*/temp1_input) / 1000 )) C, fancontrol $(systemctl is-active fancontrol)"; }
h() { ours || { echo "STOP: tanager-d1 does not hold the PL"; return 1; }; echo "\$ tanager-host $*"; sudo $H "$@"; }
uart1() { sudo cat /proc/tty/driver/xuartps 2>/dev/null | grep -E "^1:|mmio:0xFF010000" || echo "(no xuartps line for UART1)"; }
echo "tanager-host $(sha256sum $H | cut -c1-16), bitstream $(sha256sum /lib/firmware/xilinx/tanager-d1/tanager.bit.bin | cut -c1-16)"
./tg.sh load || { echo "load failed"; exit 1; }
fan
h info | grep -E "configuration|core clock|capabilities" || { ./tg.sh restore; exit 1; }
echo "== step 0: read-only pre-checks"
h psrd 0xFF9B0000; h psrd 0xFF9B0014; h psrd 0xFF5E0238
iou2=$(sudo $H psrd 0xFF5E0238 2>/dev/null | sed -n 's/^0x[0-9a-f]*: \(0x[0-9a-f]*\).*/\1/p')
echo "RST_LPD_IOU2 = ${iou2:-unread}; bits set: $( [ -n "$iou2" ] && for b in $(seq 0 31); do [ $(( iou2 >> b & 1 )) = 1 ] && printf '%d ' $b; done )"
if [ "$mode" = test ]; then
  if [ -z "$iou2" ] || [ $(( iou2 >> bit & 1 )) = 1 ]; then echo "STOP: TTC1 (bit $bit) held in reset or unread; not running ps_d1"; ./tg.sh restore; exit 1; fi
  echo "TTC1 (bit $bit) is out of reset"
  echo "== before step 1"; uart1; n0=$(sudo dmesg | wc -l); systemctl is-active serial-getty@ttyPS1
  echo "== step 1: ps_d1"
  h load --fw $HOME/tanager/d1/ps_d1.bin --kernel /dev/null --dtb /dev/null && h run --timeout 10; echo "run exit $?"
  echo "== step 2: the A53"
  sleep 2; echo "dmesg, new lines:"; sudo dmesg | tail -n +$((n0 + 1)) | tail -20; uart1; systemctl is-active serial-getty@ttyPS1
fi
fan
./tg.sh restore
fan
