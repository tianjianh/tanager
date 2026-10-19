#!/bin/bash
# d4m_step2.sh stage|pre|fanbit|a|b|bfail|post|probe4: step 2 of D4's boot-time modes (docs/spec/soc-d4-modes.md,
# DR-172) on the SoC track's package d4s1-smt2-c2-100 (its README.txt): the board's reset path, in ARM mode under
# tanager-host. Tests a and b each reset the whole board, A53 included (SSH drops, Ubuntu boots again).
#   stage   the package as the dfx-mgr app tanager-d4s1 (tg.sh stage)
#   pre     RESET_REASON, then load the app (tg.sh load), info, fan, BOARD_CTRL (0x1404, 0 after a load)
#   fanbit  README's optional step 3, quieter: the A53's PWM at 64 rather than 255 (fancontrol stopped, never 0),
#           BOARD_CTRL bit 0 on and off, fancontrol restarted
#   a       2(a): BOARD_CTRL bit 1, ps_reset.bin loaded, sync, run (the RISC-V writes RESET_CTRL's SOFT_RESET)
#   b       2(b): load the app again, the uncore out of reset (0x010 = 1), BOARD_CTRL bit 1, sync; the laptop then
#           sends the 3 s break on COM5 (serial_break.ps1)
#   bfail   if 2(b) didn't reset: BOARD_CTRL's hook bits, then BOARD_CTRL 0 and k26-starter-kits back
#   post    after a reset: uptime, the last boot's journal end, the fan, the apps, RESET_REASON
#   probe4  README's item 4, read-only probes for step 5 (the watchdogs, AFI_FS, SD1's taps)
# Every tanager-host call is refused unless tanager-d4s1 holds the PL (a read with no PL slave hangs the A53).
cd ~/tanager/tg || exit 1
export TG_APP=tanager-d4s1 TG_DIR=$HOME/tanager/d4s1-smt2-c2-100 DEADMAN_S=${DEADMAN_S:-1800}
P=$TG_DIR; H=$P/tanager-host
active() { sudo xmutil listapps | awk '$1 == "tanager-d4s1" && $NF ~ /^0->/ { f = 1 } END { exit !f }'; }
h() { active || { echo "refused: 'tanager-host $*' while tanager-d4s1 is not loaded"; return 1; }; echo "\$ tanager-host $*"; sudo $H "$@"; }
rr() { echo "RESET_REASON (0xFF5E0220) $1: $(sudo busybox devmem 0xFF5E0220 32)"; }
fan() { echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, AMS temp1 $(( $(cat /sys/devices/platform/ams/hwmon/hwmon*/temp1_input) / 1000 )) C, fancontrol $(systemctl is-active fancontrol)"; }
date -u +"== d4m_step2 ${1:-} %F %T UTC, A53 up $(cut -d' ' -f1 /proc/uptime) s"
case "${1:-}" in
stage)
  sha256sum $P/tanager.bit.bin $H | cut -c1-16,65-
  ./tg.sh stage;;
pre)
  pgrep -f "[t]anager-host (boot|run)" > /dev/null && { echo "a tanager-host boot or run is going: stop"; exit 1; }
  rr before
  ./tg.sh load || exit 1
  h info; h fan; h peek 0x1404;;
fanbit)
  h peek 0x1404 || exit 1
  sudo systemctl stop fancontrol
  pw=$(ls /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)
  echo 64 | sudo tee $pw > /dev/null; sleep 2; fan; h fan
  h poke 0x1404 1; sleep 2; h fan
  h poke 0x1404 0; sleep 2; h fan
  sudo systemctl start fancontrol; sleep 3; fan;;
a)
  h peek 0x1404 || exit 1
  h poke 0x1404 2
  # README's --kernel /dev/null --dtb /dev/null fails in this tanager-host ("/dev/null: No error information"), so
  # the package's own Image and virtio tree fill those slots: ps_reset.bin runs first and never reaches them
  h load --fw $P/ps_reset.bin --kernel $P/Image --dtb $P/tanager-kv260-virtio.dtb || exit 1
  sync; sync
  echo "run at $(date -u +%T.%N | cut -c1-12) UTC"
  h run;;
b)
  pgrep -f "[t]anager-host (boot|run)" > /dev/null && { echo "a tanager-host boot or run is going: stop"; exit 1; }
  rr before
  ./tg.sh load || exit 1
  h peek 0x1404
  h poke 0x010 1
  h poke 0x1404 2
  h peek 0x1404
  sync; sync
  echo "armed at $(date -u +%T) UTC: send the break now";;
bfail)
  h peek 0x1404
  h poke 0x1404 0
  ./tg.sh restore;;
post)
  echo "up since $(uptime -s) (A53 local time)"
  journalctl -b -1 -n 12 --no-pager -o short-iso 2>&1
  fan
  sudo xmutil listapps | awk '$NF ~ /^0->/ {print "active app: " $1}'
  rr after;;
probe4)
  for a in 0xfd4d0000 0xfd4d0004 0xff150000 0xff150004 0xfd615000 0xff180314 0xff180318; do
    printf '%s ' $a; sudo busybox devmem $a 32; done
  grep . /sys/class/watchdog/watchdog*/identity /sys/class/watchdog/watchdog*/state 2>/dev/null
  sudo dd if=/dev/mtd5 bs=1M 2>/dev/null | tr -c '[:print:]' '\n' | grep -i -m8 'wdt\|watchdog';;
*) echo "usage: $0 stage|pre|fanbit|a|b|bfail|post|probe4"; exit 2;;
esac
