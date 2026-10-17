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
#   tg.sh ls-soc      core, FPGA lockstep steps 2-3: the SoC test traced to a file and checked, then live
#   tg.sh ls-linux    core, FPGA lockstep steps 4-5: Linux live through the checker (INJ_RD, LINUX_S)
#   tg.sh ls-plant    core: the lockstep failure path, a planted fault (PLANT) on the live SoC test
#   tg.sh bench       core: the DR-141 Linux workload set, BOOTS boots of BENCH_DIR's image, logs NAME_bootK.txt
#   tg.sh tracefile   core: boot with the commit trace into a file, show each hart's last records
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
# Is a process we started with sudo still there? /proc, not kill -0: sudo's real uid changes while it sets
# up, and kill -0 from ubuntu then fails (EPERM), which made shell give up on a boot that was running.
alive() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
# The dead-man is `bash -c "sleep; restore"`: kill that bash first (so the restore cannot run), then
# its sleep, which would otherwise stay behind as an orphan. Only a sleep: a restore already under way
# is left to finish, so the PL never stays without an app (and the fan without its PWM).
deadman_cancel() {
  if [ -f "$D/deadman.pid" ]; then
    local p kids; p=$(cat "$D/deadman.pid"); kids=$(pgrep -x -P "$p" sleep)
    kill "$p" 2>/dev/null; [ -n "$kids" ] && kill $kids 2>/dev/null
  fi
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
    while alive "$pid"; do
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
    # SH_DTB names the device tree in TG_DIR (default tanager-kv260.dtb), SH_ARGS adds tanager-host
    # options (stage C: --blk IMG --rng), and TH_DURING runs ';'-separated tanager-host commands from a
    # second session once the commands are done (stage C: "vq;dma status"). For Debian through U-Boot:
    # SH_KERNEL=u-boot.bin, SH_TIMEOUT (tanager-host's, default 900 s), SH_USER=- (autologin: type no
    # user name) and SH_POWEROFF="sudo poweroff". A53_DURING runs a shell command on the A53 after the
    # commands (stage C's network: an IPv6 ping on the TAP).
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    log=$D/linux_shell.txt; fifo=$D/console.in
    rm -f "$fifo"; mkfifo "$fifo"
    inj=${INJ_RD:-0}
    cmds=${CMDS:-"uname -a; cat /proc/cpuinfo; head -3 /proc/meminfo; uptime"}
    dtb=${SH_DTB:-tanager-kv260.dtb}; kern=${SH_KERNEL:-Image}; tmo=${SH_TIMEOUT:-900}
    echo "\$ tanager-host boot --inj-rd $inj --fw fw_jump.bin --kernel $kern --dtb $dtb ${SH_ARGS:+$SH_ARGS }--timeout $tmo < console"
    active "$APP" || exit 1
    t0=$(date +%s)
    # SH_ARGS unquoted on purpose: it holds several options
    sudo "$TH" boot --inj-rd "$inj" --fw "$D/fw_jump.bin" --kernel "$D/$kern" --dtb "$D/$dtb" ${SH_ARGS:-} --timeout "$tmo" < "$fifo" > "$log" 2>&1 &
    pid=$!
    exec 3> "$fifo"
    waitfor() { local i; for i in $(seq 1 "$2"); do grep -q "$1" "$log" && return 0; alive "$pid" || return 1; sleep 1; done; return 1; }
    if waitfor "tanager login:" "${LOGIN_S:-800}"; then
      echo "login prompt $(( $(date +%s) - t0 )) s after the load"
      user=${SH_USER:-root}
      if [ "$user" != - ]; then sleep 1; printf '%s\r' "$user" >&3; fi
      sleep 4
      # the marker is computed, so the console's echo of the typed line cannot match it early
      printf '%s; echo TG-$((40+2))-DONE\r' "$cmds" >&3
      if waitfor "TG-42-DONE" "${CMDS_S:-120}"; then echo "commands done $(( $(date +%s) - t0 )) s after the load"
      else echo "commands not done within ${CMDS_S:-120} s"; fi
      echo "injector while Linux runs (a second tanager-host, register reads only):"; th inj --stats
      [ -n "${DBG:-}" ] && { echo "debug counters after the boot:"; th dbg; }
      if [ -n "${TH_DURING:-}" ]; then
        IFS=';' read -r -a during <<< "$TH_DURING"
        for c in "${during[@]}"; do th $c; done   # unquoted: each entry is a command and its options
      fi
      # A53_DURING: a shell command on the A53 while the system runs (stage C: ping -6 ... %tanager0)
      [ -n "${A53_DURING:-}" ] && { echo "\$ (A53) $A53_DURING"; bash -c "$A53_DURING"; }
      printf '%s\r' "${SH_POWEROFF:-poweroff}" >&3
      waitfor "requested power-off" "${OFF_S:-120}" && echo "power-off reached the host $(( $(date +%s) - t0 )) s after the load"
    else
      echo "no login prompt"
      # DBG=1: read the SoC's debug counters (tanager-host dbg) while the system is still stuck
      if [ -n "${DBG:-}" ] && alive "$pid"; then
        echo "debug counters during the hang:"; th dbg; sleep 5; echo "and 5 s later:"; th dbg
        th inj --stats
      fi
    fi
    alive "$pid" && { sleep 2; sudo kill -INT "$pid"; }
    wait "$pid"; rc=$?
    exec 3>&-; rm -f "$fifo"
    echo "boot exit $rc; console in $log ($(wc -l < "$log") lines)"
    fan
    ;;
  ls-soc)
    # FPGA lockstep (verification track's RUNBOOK, steps 2 and 3): the SoC test's commit trace into a
    # file, checked offline, then live through a FIFO. Needs the core app; the checker is in LS_DIR.
    L=${LS_DIR:-$HOME/tanager/lockstep}
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    cd "$L" || exit 1
    echo "== step 2: the trace into a file"
    rm -f soc_board.trace
    th boot --fw soc_test.bin --kernel /dev/null --dtb /dev/null --lossless --trace "$L/soc_board.trace" --timeout 60 < /dev/null
    echo "boot exit $?; trace file $(stat -c %s soc_board.trace 2>/dev/null) bytes"
    ./tanager-lockstep --fw soc_test.bin soc_board.trace 2>&1 | tail -2
    echo "== step 3: live through a FIFO"
    rm -f tg.trace; mkfifo tg.trace
    ./tanager-lockstep --fw soc_test.bin --stats=5 tg.trace 2> ls_soc.log &
    lpid=$!
    th boot --fw soc_test.bin --kernel /dev/null --dtb /dev/null --lossless --trace-log2 16 --trace "$L/tg.trace" --timeout 120 < /dev/null
    echo "boot exit $?"
    wait "$lpid"; echo "checker exit $?"; tail -3 ls_soc.log
    fan
    ;;
  ls-linux)
    # FPGA lockstep (RUNBOOK steps 4 and 5): Linux live through the checker, INJ_RD injected read
    # cycles (default 0), the 768 MiB device tree for both. At the prompt: root, then poweroff.
    # LINUX_S bounds the whole run (default 5400 s). Logs in LS_DIR: console_linuxINJ.txt, ls_linuxINJ.log.
    L=${LS_DIR:-$HOME/tanager/lockstep}
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    cd "$L" || exit 1
    inj=${INJ_RD:-0}; lim=${LINUX_S:-5400}
    con=$L/console_linux$inj.txt; lsl=$L/ls_linux$inj.log; cin=$L/console.in
    rm -f tg.trace "$cin"; mkfifo tg.trace "$cin"
    cp "$D/Image" "$L/Image" 2>/dev/null
    # ZERO_MB: zero the first ZERO_MB MiB of the RISC-V window before the boot, so memory nobody wrote
    # reads 0 as in Spike (board/tg_zero.c: mmap of the carve-out, 8-byte stores; dd cannot write there).
    if [ "${ZERO_MB:-0}" -gt 0 ]; then
      sudo "$HOME/tanager/tg_zero" 0x840000000 "$ZERO_MB" || exit 1
    fi
    dtb=${LS_DTB:-tanager-kv260-768m.dtb}   # the RUNBOOK's padded tree: LS_DTB=tanager-kv260-768m-pad.dtb
    # LS_ARGS: extra checker options, e.g. --harts=4 for two cores (harts 0 and 2: Spike harts 0..3)
    ./tanager-lockstep ${LS_ARGS:-} --fw fw_jump.bin --kernel Image --dtb "$dtb" --stats=30 tg.trace 2> "$lsl" &
    lpid=$!
    active "$APP" || exit 1
    # LS_HOST_ARGS: extra tanager-host options, e.g. --freeze-time (p0g and later: mtime held while the
    # trace stalls the cores, so the plain 10 MHz tree works under the checker)
    echo "\$ tanager-host boot --inj-rd $inj --fw fw_jump.bin --kernel Image --dtb $dtb --lossless --trace-log2 16 --trace tg.trace ${LS_HOST_ARGS:+$LS_HOST_ARGS }--timeout $lim"
    t0=$(date +%s)
    sudo "$TH" boot --inj-rd "$inj" --fw fw_jump.bin --kernel Image --dtb "$dtb" \
      --lossless --trace-log2 16 --trace "$L/tg.trace" ${LS_HOST_ARGS:-} --timeout "$lim" < "$cin" > "$con" 2>&1 &
    pid=$!
    exec 3> "$cin"
    tok=""; tlog=""
    while alive "$pid"; do
      el=$(( $(date +%s) - t0 ))
      if [ -z "$tok" ] && grep -q "TANAGER-BOOT-OK" "$con"; then tok=$el; echo "TANAGER-BOOT-OK at $el s"; fi
      if [ -z "$tlog" ] && grep -q "tanager login:" "$con"; then
        tlog=$el; echo "login prompt at $el s"
        sleep 2; printf 'root\r' >&3
        # the root shell may take minutes under the checker: wait for its prompt, then poweroff
        for i in $(seq 1 360); do
          tail -c 4 "$con" | grep -q '# ' && break
          alive "$pid" || break; sleep 5
        done
        echo "shell prompt at $(( $(date +%s) - t0 )) s"; printf 'poweroff\r' >&3
      fi
      sleep 5
    done
    wait "$pid"; rc=$?
    exec 3>&-
    echo "boot exit $rc after $(( $(date +%s) - t0 )) s (TANAGER-BOOT-OK ${tok:-never} s, prompt ${tlog:-never} s)"
    wait "$lpid"; echo "checker exit $?"
    grep "records (" "$lsl" | tail -1; tail -2 "$lsl"
    rm -f "$cin"
    fan
    ;;
  ls-plant)
    # The failure path, live: the checker gets a fault planted at record PLANT (default 1000) and
    # stops with exit 2; tanager-host (6466df0 and later) should then end with exit 4, not stall.
    L=${LS_DIR:-$HOME/tanager/lockstep}
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    cd "$L" || exit 1
    rm -f tg.trace; mkfifo tg.trace
    ./tanager-lockstep --fw soc_test.bin --plant="${PLANT:-1000}" tg.trace > ls_plant.log 2>&1 &
    lpid=$!
    th boot --fw soc_test.bin --kernel /dev/null --dtb /dev/null --lossless --trace-log2 16 --trace "$L/tg.trace" --timeout 60 < /dev/null
    echo "boot exit $? (expect 4: the checker stopped)"
    wait "$lpid"; echo "checker exit $? (expect 2)"; grep -m1 "MISMATCH at" ls_plant.log
    rm -f tg.trace
    fan
    ;;
  bench)
    # The DR-141 Linux workload set (verification track): boot BENCH_DIR's fw_jump.bin, Image and
    # BENCH_DTB BOOTS times on the loaded profile; the set runs after TANAGER-BOOT-OK and powers off.
    # Each console goes to BENCH_DIR/NAME_bootK.txt; the checks are verif-2's (verification.md §4.6).
    B=${BENCH_DIR:-$HOME/tanager/bench}; name=${NAME:-$APP}; lim=${BENCH_S:-3600}
    dtb=${BENCH_DTB:-tanager-kv260-bench.dtb}; boots=${BOOTS:-1}
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    th info | grep -E "configuration|core clock"
    for k in $(seq 1 "$boots"); do
      log=$B/${name}_boot$k.txt
      active "$APP" || exit 1
      echo "== $name boot $k: tanager-host boot --fw fw_jump.bin --kernel Image --dtb $dtb --lossless --timeout $lim"
      t0=$(date +%s)
      sudo "$TH" boot --fw "$B/fw_jump.bin" --kernel "$B/Image" --dtb "$B/$dtb" --lossless --timeout "$lim" \
        < /dev/null > "$log" 2>&1 &
      pid=$!
      tok=""; tbeg=""
      while alive "$pid"; do
        el=$(( $(date +%s) - t0 ))
        [ -z "$tok" ] && grep -q "TANAGER-BOOT-OK" "$log" && { tok=$el; echo "TANAGER-BOOT-OK at $el s"; }
        [ -z "$tbeg" ] && grep -q "TGLB-BEGIN" "$log" && { tbeg=$el; echo "TGLB-BEGIN at $el s"; }
        sleep 2
      done
      wait "$pid"; rc=$?
      echo "boot exit $rc after $(( $(date +%s) - t0 )) s (TANAGER-BOOT-OK ${tok:-never} s, TGLB-BEGIN ${tbeg:-never} s)"
      tr -d '\r' < "$log" | grep -m1 "TGLB-INFO" || echo "CHECK: no TGLB-INFO line"
      # two perf events per hart (TGLB-BEGIN names the harts)
      h=$(tr -d '\r' < "$log" | grep -m1 -o "TGLB-BEGIN.* harts=[0-9]*" | grep -o "[0-9]*$")
      tr -d '\r' < "$log" | grep -q "TGLB-INFO.*counters=cycle,instret,time.*perf_events=$(( 2 * ${h:-1} )) " || echo "CHECK: info line lacks counters=cycle,instret,time / perf_events=$(( 2 * ${h:-1} )) for ${h:-1} hart(s) (old image?)"
      n=$(tr -d '\r' < "$log" | grep -c "^TGLB [a-z]")
      echo "measurement lines: $n (expect 54); CoreMark validated: $(grep -c "Correct operation validated" "$log") (expect 6)"
      tr -d '\r' < "$log" | grep -m1 "TGLB-END" || echo "CHECK: no TGLB-END line"
      tr -d '\r' < "$log" | grep -E "TGLB-FAIL|cycles=0 |cycles=-" | head -3
    done
    fan
    ;;
  tracefile)
    # Diagnostic: boot with the commit trace into a file (TRACE_S seconds), then show each hart's last
    # records. TF_FW/TF_KERNEL/TF_DTB name the images in TG_DIR (default fw_jump.bin, Image and
    # tanager-kv260-768m.dtb: the trace ring takes the top 256 MiB of the carve-out).
    deadman_cancel
    active "$APP" || { echo "$APP is not loaded"; exit 1; }
    trap '"$ME" restore' EXIT
    tf=$D/boot.trace; con=$D/trace_console.txt; rm -f "$tf"
    fw=${TF_FW:-fw_jump.bin}; kern=${TF_KERNEL:-Image}; dtb=${TF_DTB:-tanager-kv260-768m.dtb}
    # TRACE_WRAP=N keeps only the last 2^N records (--trace-wrap, written at exit): a bounded file even
    # if the system boots; without it every record streams to the file (fine for a hang, huge for a boot).
    wrap=""; [ -n "${TRACE_WRAP:-}" ] && wrap="--trace-wrap --trace-log2 $TRACE_WRAP"
    th boot --fw "$D/$fw" --kernel "$D/$kern" --dtb "$D/$dtb" --lossless --trace "$tf" $wrap --timeout "${TRACE_S:-60}" < /dev/null > "$con" 2>&1
    echo "boot exit $?; console $(wc -c < "$con") bytes; trace $(stat -c %s "$tf" 2>/dev/null) bytes"
    tr -d '\r' < "$con" | tail -5
    python3 - "$tf" <<'PYTF'
import struct, sys
f = open(sys.argv[1], "rb"); data = f.read(); n = len(data) // 64
print(f"{n} records")
last = {}; count = {}
for i in range(n):
    hdr, insn = struct.unpack_from("<II", data, i * 64)
    pc, val = struct.unpack_from("<QQ", data, i * 64 + 8)
    hart = (hdr >> 2) & 3; kind = hdr & 3
    count[hart] = count.get(hart, 0) + 1
    last.setdefault(hart, []).append((i, kind, (hdr >> 4) & 3, pc, insn, val))
    if len(last[hart]) > 12: last[hart].pop(0)
for h in sorted(last):
    print(f"hart lane {h}: {count[h]} records; last ones (record, kind 0 retire/1 trap/2 irq/3 wb, priv, pc, insn, value):")
    for (i, k, p, pc, insn, val) in last[h]:
        print(f"  {i:8d} k{k} p{p} pc={pc:#018x} insn={insn:#010x} val={val:#018x}")
PYTF
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
    sed -n '2,23p' "$ME"; exit 2
    ;;
esac
