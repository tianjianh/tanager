#!/bin/bash
# d3_run.sh pre|boot|post: stage D's D3 (soc.md §8.2, DR-163): the RISC-V's console on the PS's UART1 (COM7 on the
# laptop) with the A53's Ubuntu running, the SoC track's d3-uart1 package (~/tanager/d3) on d2's bitstream.
#   pre:  load d2 (dead-man 40 min); step 0: record the console level and the getty; the comparison boot without
#         UART1 (the PL console only; root logs in there and powers off); step 1: release UART1 (the getty masked
#         with --runtime, dmesg -n 1). From here no A53 shutdown or reboot until post.
#   boot: step 3: start tanager-host with the UART1 tree, detached (the PL console to pl_console_uart1.txt);
#         the laptop's COM7 session logs in as root (no password), runs step 4 and powers the RISC-V off
#   post: step 5, the last: unmask and start the getty, restore the console level; then k26-starter-kits
# Every tanager-host call checks first that tanager-d2 holds the PL. Run-time changes only; fancontrol stays up.
mode=${1:-pre}
cd ~/tanager/tg || exit 1
export TG_APP=tanager-d2 TG_DIR=$HOME/tanager/d3 DEADMAN_S=${DEADMAN_S:-2400}
D=$TG_DIR; H=$D/tanager-host; G=serial-getty@ttyPS1.service
holds() { sudo xmutil listapps | grep -q -E "^ *tanager-d2 .* 0->"; }
st() { echo "$(date +%T) fancontrol $(systemctl is-active fancontrol), pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, temp1 $(cat /sys/devices/platform/ams/hwmon/hwmon*/temp1_input), getty $(systemctl is-active $G), printk $(cat /proc/sys/kernel/printk)"; }
# boot DTB TIMEOUT OUT: tanager-host on DTB, the PL console's input a FIFO held open, its output to OUT, detached
boot() { holds || { echo "STOP: tanager-d2 does not hold the PL"; return 1; }
  rm -f $D/pl.in; mkfifo $D/pl.in; (exec sleep $(( $2 + 60 )) > $D/pl.in) &
  echo "\$ tanager-host boot --fw fw_jump.bin --kernel Image --dtb $1 --timeout $2"
  (cd $D && exec sudo setsid $H boot --fw fw_jump.bin --kernel Image --dtb $1 --timeout $2 < $D/pl.in > $3 2>&1) & }
case "$mode" in
pre)
  ./tg.sh load | grep -E "^loaded|^fan|^dead" || exit 1
  holds && sudo $H info | grep -E "configuration|core clock|capabilities"
  echo "== step 0"; cat /proc/sys/kernel/printk > $D/printk.saved; echo "printk: $(cat $D/printk.saved)"; st
  echo "== the comparison boot, without UART1"
  boot tanager-kv260.dtb 300 $D/pl_console_nouart1.txt || exit 1
  for i in $(seq 1 60); do grep -q "login:" $D/pl_console_nouart1.txt && break; sleep 2; done
  printf 'root\n' > $D/pl.in; sleep 3; printf 'cat /proc/consoles; poweroff\n' > $D/pl.in
  for i in $(seq 1 60); do pgrep -f "[t]anager-host boot.*tanager-kv260.dtb" > /dev/null || break; sleep 2; done
  grep -a -E "TANAGER-BOOT-OK|login:|ttyS0|ttyPS|Power down|tohost|exit" $D/pl_console_nouart1.txt | tr -d '\r' | tail -8
  echo "== step 1: release UART1"
  sudo systemctl mask --runtime --now $G; sudo dmesg -n 1
  echo "getty $(systemctl is-active $G); processes holding ttyPS1: $(sudo ls -l /proc/[0-9]*/fd 2>/dev/null | grep -c ttyPS1)"; st;;
boot)
  echo "== step 3: boot with UART1 as the RISC-V's console"
  [ "$(systemctl is-active $G)" = active ] && { echo "STOP: the getty is active (run pre first)"; exit 1; }
  boot tanager-kv260-uart1.dtb 900 $D/pl_console_uart1.txt; sleep 2; pgrep -a -f "[t]anager-host boot" | cut -c1-160;;
post)
  echo "== step 5: give UART1 back"
  pgrep -f "[t]anager-host boot" > /dev/null && { echo "STOP: tanager-host still runs"; exit 1; }
  sudo systemctl unmask --runtime $G; sudo systemctl start $G; sudo dmesg -n $(cut -f1 $D/printk.saved)
  st; ./tg.sh restore | tail -1; st;;
esac
