#!/bin/bash
# Stage B on the KV260 (board track): fpga/kv260/README.md's bring-up sequence. Run on the board as
# `ubuntu`. The fan rule: k26-starter-kits (Linux's fan PWM on A12) is loaded whenever Tanager is not.
# TG_APP names the dfx-mgr app and TG_DIR its files: the traffic generators by default (tanager,
# ~/tanager/tg), the core with TG_APP=tanager-m4 TG_DIR=~/tanager/m4.
#   tg.sh stage       copy tanager.bit.bin, tanager.dtbo, shell.json from TG_DIR into the dfx-mgr app
#                     folder /lib/firmware/xilinx/TG_APP; install ~/tanager/tanager-host
#   tg.sh load        unload the default app, load TG_APP (step 1), check it, arm a 10-minute dead-man
#   tg.sh steps       traffic generators, steps 2-5: info, widths, memory path at 0 and 250 cycles, console
#   tg.sh firstlight  core, step 6: soc_test.bin from TG_DIR, run until tohost
#   tg.sh linux       core, step 7: boot fw_jump.bin, Image, tanager-kv260.dtb from TG_DIR until
#                     TANAGER-BOOT-OK, power-off or LINUX_S seconds (default 1200); log in TG_DIR
#   tg.sh shell       core: boot (INJ_RD cycles), log in on the console, run CMDS, poweroff
#   tg.sh restore     unload TG_APP and reload k26-starter-kits
#   tg.sh status      the apps, the FPGA manager state, the PL clock and the fan
#   tg.sh th ARGS     one tanager-host call, refused unless TG_APP is loaded
set -u -o pipefail
D=${TG_DIR:-$HOME/tanager/tg}
APP=${TG_APP:-tanager}
FW=/lib/firmware/xilinx/$APP
DEFAULT=k26-starter-kits
TH=/usr/local/bin/tanager-host
ME=$(readlink -f "$0")
DEADMAN_S=600

fan() {
  echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255," \
       "AMS temp1 $(( $(cat /sys/devices/platform/ams/hwmon/hwmon*/temp1_input) / 1000 )) C," \
       "fancontrol $(systemctl is-active fancontrol)"
}
plclk() {
  mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug
  echo "pl0_ref (pl_clk0): $(sudo cat /sys/kernel/debug/clk/pl0_ref/clk_rate) Hz"
}
active() { sudo xmutil listapps | awk -v a="$1" '$1 == a && $NF ~ /^0->/ { f = 1 } END { exit !f }'; }
deadman_cancel() {
  [ -f "$D/deadman.pid" ] && kill "$(cat "$D/deadman.pid")" 2>/dev/null
  rm -f "$D/deadman.pid"
}
# Every tanager-host call first checks that the tanager app holds the PL. With another design (or
# none) loaded, nothing answers at 0xA000_0000 and the read hangs the A53 until a power cycle.
th() {
  active "$APP" || { echo "refused: 'tanager-host $*' while $APP is not loaded"; return 1; }
  echo "\$ tanager-host $*"; sudo "$TH" "$@"
}

case "${1:-}" in
  stage)
    for f in tanager.bit.bin tanager.dtbo shell.json tanager-host; do
      [ -f "$D/$f" ] || [ -f "$HOME/tanager/$f" ] || { echo "missing $f"; exit 1; }
    done
    [ -d "$FW" ] || sudo install -d -o ubuntu -g ubuntu "$FW"
    cp "$D/tanager.bit.bin" "$D/tanager.dtbo" "$D/shell.json" "$FW/" || exit 1
    sudo install -m 0755 /home/ubuntu/tanager/tanager-host /usr/local/bin/tanager-host || exit 1
    sha256sum "$FW"/* "$TH"
    sudo xmutil listapps | grep -q "^ *$APP " || { sudo systemctl restart dfx-mgr; sleep 3; }
    sudo xmutil listapps
    ;;
  load)
    [ -x "$TH" ] || { echo "no $TH"; exit 1; }
    sudo xmutil listapps | grep -q "^ *$APP " || { echo "$APP is not a dfx-mgr app yet (tg.sh stage)"; exit 1; }
    sudo xmutil unloadapp
    if ! sudo xmutil loadapp "$APP"; then echo "loadapp failed"; "$ME" restore; exit 1; fi
    sleep 1
    st=$(cat /sys/class/fpga_manager/fpga0/state)
    if ! active "$APP" || [ "$st" != operating ]; then
      echo "load not confirmed (fpga0 state: $st)"; "$ME" restore; exit 1
    fi
    echo "loaded $APP at $(date +%T); fpga0 $st"; fan; plclk
    journalctl -k --since "-40s" --no-pager | grep -i -E "fpga|overlay|afi|fclk|uio" | tail -8
    nohup bash -c "sleep $DEADMAN_S; '$ME' restore deadman" >/dev/null 2>&1 &
    echo $! > "$D/deadman.pid"
    echo "dead-man: $DEFAULT comes back at $(date -d "+$DEADMAN_S seconds" +%T) unless 'steps' or 'restore' runs first"
    ;;
  steps)
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    fan
    echo "== step 2: the host window"
    th info || exit 1
    echo "== step 3: fabric widths (FROMHOST is a 64-bit pair: the low half lands with the high half)"
    th poke 0x68 0x12345678 && th poke 0x6c 0x9abcdef0 && th peek 0x68 && th peek 0x6c || exit 1
    th poke 0x68 0 && th poke 0x6c 0
    echo "   and a 32-bit register (TG_LINES):"
    th poke 0xc8 0x2468 && th peek 0xc8 && th poke 0xc8 16384
    echo "== step 4: the memory path, no core"
    th tg start 16384 || exit 1
    echo "   window read back (hi, lo; size hi, lo):"
    th peek 0x24; th peek 0x20; th peek 0x2c; th peek 0x28
    for i in 1 2 3; do sleep 2; th tg status; done
    th info
    echo "== step 4, at 250 injected read cycles (options after the command: tanager-host c44622c and later)"
    th inj --inj-rd 250
    for i in 1 2 3; do sleep 2; th tg status; done
    th inj --stats
    th inj --inj-rd 0
    echo "== step 5: the console (two '.' per pass), also on the PMOD UART"
    if active "$APP"; then
      echo "\$ tanager-host run --timeout 5"
      sudo timeout -s INT 20 "$TH" run --timeout 5 < /dev/null; rc=$?
      echo; echo "run exit $rc"
    fi
    th tg status
    th info
    fan
    ;;
  console)
    # Diagnostic: does the host console (UART_TX pops) follow the generators' dots? Three cases, each a
    # 3-second run after tg start; UART_TX_LEVEL (0x104) is read first. Dots counted per case.
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    runc() {
      active "$APP" || return 1
      sudo timeout -s INT 15 "$TH" --timeout 3 run < /dev/null > "$D/run_$1.txt" 2>&1
      echo "run $1: exit $?, $(tr -cd . < "$D/run_$1.txt" | wc -c) dots; $(tr -d . < "$D/run_$1.txt" | tr -s '\r\n' ' ')"
    }
    echo "== A: tg start, 2 s, run 3 s"
    th tg start 16384 && sleep 2 && th tg status && th peek 0x104 && runc A
    echo "== B: tg start, 2 s, injector 250 for 2 s, back to 0, run 3 s"
    th tg start 16384 && sleep 2 && th --inj-rd 250 inj && sleep 2 && th --inj-rd 0 inj && th tg status && th peek 0x104 && runc B
    echo "== C: tg start, run at once"
    th tg start 16384 && th peek 0x104 && runc C
    fan
    ;;
  firstlight)
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    fan
    th info || exit 1
    th load --fw "$D/soc_test.bin" --kernel /dev/null --dtb /dev/null || exit 1
    if active "$APP"; then
      echo "\$ tanager-host run --timeout 10"
      sudo timeout -s INT 30 "$TH" run --timeout 10 < /dev/null; rc=$?
      echo; echo "run exit $rc"
    fi
    th info
    fan
    ;;
  linux)
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    fan
    th info || exit 1
    log=$D/linux_boot.txt
    lim=${LINUX_S:-1200}
    echo "\$ tanager-host boot --fw fw_jump.bin --kernel Image --dtb tanager-kv260.dtb --timeout $lim"
    active "$APP" || exit 1
    t0=$(date +%s)
    sudo "$TH" boot --fw "$D/fw_jump.bin" --kernel "$D/Image" --dtb "$D/tanager-kv260.dtb"       --timeout "$lim" < /dev/null > "$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      if grep -q "TANAGER-BOOT-OK" "$log"; then
        echo "TANAGER-BOOT-OK seen $(( $(date +%s) - t0 )) s after the load"
        sleep 5; sudo kill -INT "$pid"; break
      fi
      sleep 1
    done
    wait "$pid"; rc=$?
    echo "boot exit $rc after $(( $(date +%s) - t0 )) s; console in $log ($(wc -l < "$log") lines)"
    th info
    fan
    ;;
  shell)
    # Linux with a console session: boot (INJ_RD injected read cycles, default 0), log in as root at
    # the prompt, run CMDS, then poweroff, which the RISC-V reports to the host (syscon-poweroff).
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    log=$D/linux_shell.txt; fifo=$D/console.in
    rm -f "$fifo"; mkfifo "$fifo"
    inj=${INJ_RD:-0}
    cmds=${CMDS:-"uname -a; cat /proc/cpuinfo; head -3 /proc/meminfo; uptime"}
    echo "\$ tanager-host boot --inj-rd $inj --fw fw_jump.bin --kernel Image --dtb tanager-kv260.dtb --timeout 900 < console"
    active "$APP" || exit 1
    t0=$(date +%s)
    sudo "$TH" boot --inj-rd "$inj" --fw "$D/fw_jump.bin" --kernel "$D/Image" --dtb "$D/tanager-kv260.dtb" --timeout 900 < "$fifo" > "$log" 2>&1 &
    pid=$!
    exec 3> "$fifo"
    waitfor() { local i; for i in $(seq 1 "$2"); do grep -q "$1" "$log" && return 0; kill -0 "$pid" 2>/dev/null || return 1; sleep 1; done; return 1; }
    if waitfor "tanager login:" 800; then
      echo "login prompt $(( $(date +%s) - t0 )) s after the load"
      sleep 1; printf 'root\r' >&3; sleep 4
      printf '%s\r' "$cmds" >&3; sleep 6
      echo "injector while Linux runs (a second tanager-host, register reads only):"; th inj --stats
      printf 'poweroff\r' >&3
      waitfor "requested power-off" 120 && echo "power-off reached the host $(( $(date +%s) - t0 )) s after the load"
    else
      echo "no login prompt"
    fi
    kill -0 "$pid" 2>/dev/null && { sleep 2; sudo kill -INT "$pid"; }
    wait "$pid"; rc=$?
    exec 3>&-; rm -f "$fifo"
    echo "boot exit $rc; console in $log ($(wc -l < "$log") lines)"
    fan
    ;;
  restore)
    if [ "${2:-}" = deadman ]; then echo "dead-man restore at $(date +%T)" >> "$D/deadman.log"; else deadman_cancel; fi
    sudo xmutil unloadapp
    sudo xmutil loadapp "$DEFAULT"
    sleep 1
    active "$DEFAULT" && echo "$DEFAULT loaded at $(date +%T)"
    fan
    ;;
  th)
    shift; th "$@"
    ;;
  status)
    sudo xmutil listapps; echo "fpga0: $(cat /sys/class/fpga_manager/fpga0/state)"; plclk; fan
    ;;
  *)
    sed -n '2,18p' "$ME"; exit 2
    ;;
esac
