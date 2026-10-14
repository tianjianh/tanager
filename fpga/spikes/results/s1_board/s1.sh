#!/bin/bash
# Spike S1 on the KV260 (board track). Run on the board as `ubuntu`, with the sudo rule for
# xmutil, systemctl restart dfx-mgr and /usr/local/bin/tg_s1. The fan rule: k26-starter-kits
# (Linux's fan PWM on A12) is loaded whenever S1 is not running.
#   s1.sh stage     copy the S1 files into the dfx-mgr app folder /lib/firmware/xilinx/tg-s1
#   s1.sh load      unload the default app, load tg-s1, check it, arm a 5-minute dead-man restore
#   s1.sh run       tg_s1 --quick, then the full run (results in ~/tanager/s1/), then restore
#   s1.sh restore   unload tg-s1 and reload k26-starter-kits
#   s1.sh status    the apps, the FPGA manager state and the fan
set -u -o pipefail
D=$HOME/tanager/s1
APP=tg-s1
FW=/lib/firmware/xilinx/$APP
DEFAULT=k26-starter-kits
TG=/usr/local/bin/tg_s1
ME=$(readlink -f "$0")

fan() {
  echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255," \
       "AMS temp1 $(( $(cat /sys/devices/platform/ams/hwmon/hwmon*/temp1_input) / 1000 )) C," \
       "fancontrol $(systemctl is-active fancontrol)"
}
active() { sudo xmutil listapps | awk -v a="$1" '$1 == a && $NF ~ /^0->/ { f = 1 } END { exit !f }'; }
deadman_cancel() {
  [ -f "$D/deadman.pid" ] && kill "$(cat "$D/deadman.pid")" 2>/dev/null
  rm -f "$D/deadman.pid"
}

case "${1:-}" in
  stage)
    [ -d "$FW" ] && [ -w "$FW" ] || { echo "$FW is missing or not writable (one-time setup)"; exit 1; }
    cp "$D/tg_s1.bit.bin" "$D/tg_s1.dtbo" "$D/shell.json" "$FW/" || exit 1
    sha256sum "$FW"/*
    sudo xmutil listapps | grep -q "^ *$APP " || { sudo systemctl restart dfx-mgr; sleep 3; }
    sudo xmutil listapps
    ;;
  load)
    [ -x "$TG" ] || { echo "no $TG"; exit 1; }
    sudo xmutil listapps | grep -q "^ *$APP " || { echo "$APP is not a dfx-mgr app yet (s1.sh stage)"; exit 1; }
    sudo xmutil unloadapp
    if ! sudo xmutil loadapp "$APP"; then echo "loadapp failed"; "$ME" restore; exit 1; fi
    sleep 1
    st=$(cat /sys/class/fpga_manager/fpga0/state)
    if ! active "$APP" || [ "$st" != operating ]; then
      echo "load not confirmed (fpga0 state: $st)"; "$ME" restore; exit 1
    fi
    echo "loaded $APP at $(date +%T); fpga0 $st"; fan
    mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug
    echo "pl0_ref (pl_clk0): $(sudo cat /sys/kernel/debug/clk/pl0_ref/clk_rate) Hz; S1's MMCM doubles it"
    journalctl -k --since "-40s" --no-pager | grep -i -E "fpga|overlay|afi|fclk" | tail -8
    nohup bash -c "sleep 300; '$ME' restore deadman" >/dev/null 2>&1 &
    echo $! > "$D/deadman.pid"
    echo "dead-man: $DEFAULT comes back at $(date -d '+300 seconds' +%T) unless 'run' or 'restore' runs first"
    ;;
  run)
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    fan
    sudo "$TG" --quick 2>&1 | tee "$D/s1_quick.txt" || { echo "quick run failed"; exit 1; }
    sudo "$TG" 2>&1 | tee "$D/s1_results.txt"
    fan
    { journalctl -k -n 50 --no-pager; cat /proc/cmdline; ls /sys/kernel/iommu_groups/; } > "$D/s1_board.txt" 2>&1
    ;;
  restore)
    if [ "${2:-}" = deadman ]; then echo "dead-man restore at $(date +%T)" >> "$D/deadman.log"; else deadman_cancel; fi
    sudo xmutil unloadapp
    sudo xmutil loadapp "$DEFAULT"
    sleep 1
    active "$DEFAULT" && echo "$DEFAULT loaded at $(date +%T)"
    fan
    ;;
  status)
    sudo xmutil listapps; echo "fpga0: $(cat /sys/class/fpga_manager/fpga0/state)"; fan
    ;;
  *)
    sed -n '2,9p' "$ME"; exit 2
    ;;
esac
