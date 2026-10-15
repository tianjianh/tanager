#!/bin/bash
# Continuous soak of main on the build host (docs/spec/verification.md §4.4). Each round runs
# constrained-random programs on the real core, every M3 switch on, in st, st_w3, smt2 and smt2_w3
# at once, with memory stress (latency 30-250), timer interrupts and trace back-pressure. Findings
# go to a triage list, $TANAGER_BUILD/soak/summary.md; they never gate merges.
# Strictly background: nice 19 and idle I/O, at most 8 simulations, no Vivado, no checkout touched
# (main is exported with git archive), the first out-of-memory victim (oom_score_adj 900); it starts
# no program while MemAvailable is under 12 GB (no build under 16 GB), and holds while the host
# drive C: has under 20 GB free or the machine is busy.
#   tools/ci/soak.sh start     start it (also at every boot, from main's checkout: an @reboot crontab entry)
#   tools/ci/soak.sh stop      stop it until the next start or boot
#   tools/ci/soak.sh disable   stop it and remove the @reboot entry
#   tools/ci/soak.sh status
set -u
SOAK="${TANAGER_BUILD:-$HOME/tanager-build}/soak"
CFGS="st st_w3 smt2 smt2_w3"
JOBS=2                  # simulations per configuration: 4 x 2 = 8 at most
BUILD_JOBS=4            # a tg_core model compile peaks at 0.63 GB (smt2_w3, measured): -j4 needs ~3 GB
MEM_GB=12               # start no program while MemAvailable is under this
BUILD_MEM_GB=16         # nor a build, so that one keeps MemAvailable above MEM_GB
SEEDS=400               # programs per configuration per round (about a minute)
VM_PCT=33               # share of the programs that run in S-mode under Sv39 (tg_rand --vm)
# Spike's ISA follows the core's switches: the M3 string, with f and d once tg_core has EXT_FD.
M3_ISA=rv64imac_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs
M3FD_ISA=rv64imafdc_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs
spike_args() { echo "--isa=$(cat "$SOAK/spike_isa" 2>/dev/null) --priv=MSU --pmp=16"; }
KEEP_FAILS=100          # failure directories kept (oldest go first)

log() { echo "$(date '+%F %T') soak: $*"; }
# What the soak builds from a commit: a main that changes none of it needs no rebuild.
fingerprint() { git --git-dir="$SOAK_GIT" rev-parse "$1:rtl" "$1:sim" "$1:tests/random" "$1:tools" 2>/dev/null | tr '\n' ' '; }
mem_gb() { awk '/^MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo; }
# The PID must still be a soak: after a restart the old number can belong to anything.
running() { [ -f "$SOAK/soak.pid" ] && grep -qa "soak.sh" "/proc/$(cat "$SOAK/soak.pid")/cmdline" 2>/dev/null; }

# Export main into $SOAK/src (no checkout is touched), turn every M3 switch on, build.
prepare() {
  local commit=$1 src="$SOAK/src/tanager"
  rm -f "$SOAK/commit"  # an interrupted build must never be used
  rm -rf "$SOAK/src" "$SOAK/build"
  mkdir -p "$src"
  git --git-dir="$SOAK_GIT" archive "$commit" rtl sim tests/random tools | tar -x -C "$src" || return 1
  # Every extension switch on: the M3 set the core track tests, and F/D once it exists.
  local pkg="$src/rtl/core/tg_core_pkg.sv"
  sed -i -E "s/(localparam bit EXT_[A-Z0-9_]+[[:space:]]*=[[:space:]]*)1'b0/\\11'b1/" "$pkg"
  if grep -Eq "localparam bit EXT_[A-Z0-9_]+[[:space:]]*=[[:space:]]*1'b0" "$pkg"; then
    log "could not turn the extension switches on"; return 1
  fi
  if grep -q "localparam bit EXT_FD" "$pkg"; then
    echo "$M3FD_ISA" > "$SOAK/spike_isa"; echo rv64gc > "$SOAK/prog_isa"
  else
    echo "$M3_ISA" > "$SOAK/spike_isa"; echo rv64imac > "$SOAK/prog_isa"
  fi
  local isa; isa=$(cat "$SOAK/spike_isa")
  (
    source "$src/tools/env.sh" >/dev/null 2>&1
    export CCACHE_DISABLE=1  # keep the tracks' ccache entries
    for cfg in $CFGS; do
      make -s -C "$src/sim" CFG="$cfg" CORE=core JOBS="$BUILD_JOBS" TANAGER_BUILD="$SOAK/build" \
        ISA="$isa" PRIV=MSU PMP=16 build || exit 1
    done
    make -s -C "$src/sim" TANAGER_BUILD="$SOAK/build" replay || exit 1
  ) > "$SOAK/logs/build.log" 2>&1 || return 1
  # Trace back-pressure when tg_core's build has trace_stall_i: older mains report it through
  # print-trace-stall; newer ones always connect it.
  local ts=--trace-stall
  if grep -q "print-trace-stall" "$src/sim/Makefile" &&
     [ "$(make -s --no-print-directory -C "$src/sim" CORE=core print-trace-stall)" != 1 ]; then ts=""; fi
  echo "$ts" > "$SOAK/trace_stall"
  # Older mains' random runner has no --mem-gate; the check between rounds still applies.
  if grep -q -- "--mem-gate" "$src/tests/random/run_random.py"; then echo "--mem-gate $MEM_GB"; else echo; fi \
    > "$SOAK/mem_gate"
  # A third of the programs in S-mode under Sv39, once main's generator has --vm (verification.md §6.2)
  if grep -q -- '"--vm"' "$src/tests/random/run_random.py"; then echo "--vm $VM_PCT"; else echo; fi > "$SOAK/vm"
  fingerprint "$commit" > "$SOAK/fingerprint"
  echo "$commit" > "$SOAK/commit"
}

# One configuration's campaign; failures keep the program, the end of the log and a repro line.
campaign() {
  local commit=$1 cfg=$2 seed=$3 irq=$4 day=$5 work="$SOAK/work/$2"
  local sim="$SOAK/build/tanager/sim/$cfg-core/tg_vsim"
  rm -rf "$work"
  mkdir -p "$work"
  ( source "$SOAK/src/tanager/tools/env.sh" >/dev/null 2>&1
    python3 "$SOAK/src/tanager/tests/random/run_random.py" --sim "$sim" \
      --replay "$SOAK/build/tanager/sim/replay/tg_replay" --n "$SEEDS" --seed "$seed" --isa "$(cat "$SOAK/prog_isa")" \
      --irq "$irq" --length 400 --stress $(cat "$SOAK/trace_stall") $(cat "$SOAK/mem_gate" 2>/dev/null) \
      $(cat "$SOAK/vm" 2>/dev/null) \
      --jobs "$JOBS" --timeout 1200 --workdir "$work" \
      --name "soak $cfg" -- $(spike_args) ) > "$work/out.txt" 2>&1
  local res pass fail gen
  res=$(grep "passed, " "$work/out.txt" | tail -1)
  if [ -z "$res" ]; then  # the runner itself failed: a harness error, not a result
    echo "$(date '+%F %T') $cfg on $commit: $(tail -1 "$work/out.txt" | cut -c1-200)" >> "$SOAK/errors.log"
    return 0
  fi
  pass=$(echo "$res" | sed -n 's/.*: \([0-9]*\) passed.*/\1/p')
  fail=$(echo "$res" | sed -n 's/.* \([0-9]*\) failed.*/\1/p')
  gen=$(echo "$res" | sed -n 's/.* \([0-9]*\) generator failures.*/\1/p')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$cfg" "$commit" "$((${pass:-0} + ${fail:-0}))" "${fail:-0}" \
    "${gen:-0}" >> "$SOAK/counts.tsv"
  [ -d "$work/failures" ] || return 0
  local f s d
  for f in "$work"/failures/r*.elf; do
    [ -f "$f" ] || continue
    s=$(basename "$f" .elf); s=${s#r}
    d="$SOAK/fail/$(date +%Y%m%d-%H%M%S)-$cfg-s$s"
    mkdir -p "$d"
    cp "$f" "$work/failures/r$s.S" "$d/" 2>/dev/null
    tail -n 80 "$work/failures/r$s.log" > "$d/tail.log" 2>/dev/null
    { echo "main $commit, every M3 switch on (rtl/core/tg_core_pkg.sv), CFG=$cfg, seed $s"
      grep -A1 "seed $s:" "$work/out.txt" | sed -n 's/.*repro: //p' | \
        sed "s#$work/failures/#$d/#; s#$sim#tg_vsim#"
      grep -m1 "seed $s:" "$work/out.txt" | sed 's/^ *//'
    } > "$d/repro.txt"
  done
  ls -1d "$SOAK"/fail/*/ 2>/dev/null | head -n -"$KEEP_FAILS" | xargs -r rm -rf
}

summarize() {
  local commit=$1 state=$2 out="$SOAK/summary.md.tmp" cutoff stall=on
  # One line per day, configuration and commit; 30 days kept.
  cutoff=$(date -d '30 days ago' +%F)
  awk -F'\t' -v c="$cutoff" '$1 >= c {k = $1 "\t" $2 "\t" $3; n[k] += $4; f[k] += $5; g[k] += $6}
    END {for (k in n) print k "\t" n[k] "\t" f[k] "\t" g[k]}' "$SOAK/counts.tsv" 2>/dev/null | sort > "$SOAK/counts.tmp" &&
    mv "$SOAK/counts.tmp" "$SOAK/counts.tsv"
  [ -n "$(cat "$SOAK/trace_stall" 2>/dev/null)" ] || stall="off (main's tg_core build has no trace_stall_i yet)"
  { echo "# Soak of main (tools/ci/soak.sh)"
    echo
    echo "- main: \`$commit\`, every extension switch on, Spike \`$(spike_args)\`; random programs ($(cat "$SOAK/prog_isa" 2>/dev/null)$([ -n "$(cat "$SOAK/vm" 2>/dev/null)" ] && echo ", ${VM_PCT}% in S-mode under Sv39")) with memory stress and timer interrupts on alternate rounds; trace back-pressure $stall"
    echo "- state: $state ($(date '+%F %T')); C: has $(df -BG --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc '0-9') GB free"
    echo "- findings are a triage list: they gate nothing until confirmed as core bugs (verification.md §4.4)"
    echo
    echo "## Programs per day and configuration"
    echo
    echo "| day | configuration | programs | failures |"
    echo "|---|---|---|---|"
    awk -F'\t' '{n[$1"|"$2]+=$4; f[$1"|"$2]+=$5} END {for (k in n) {split(k, a, "|"); print "| " a[1] " | " a[2] " | " n[k] " | " f[k] " |"}}' \
      "$SOAK/counts.tsv" 2>/dev/null | sort -r | head -40
    if [ -s "$SOAK/errors.log" ]; then
      tail -n 20 "$SOAK/errors.log" > "$SOAK/errors.tmp" && mv "$SOAK/errors.tmp" "$SOAK/errors.log"
      echo
      echo "## Harness errors (campaigns without a result; newest last)"
      echo
      tail -n 5 "$SOAK/errors.log" | sed 's/^/- /'
    fi
    echo
    echo "## Failures to triage (newest first)"
    echo
    local d
    for d in $(ls -1d "$SOAK"/fail/*/ 2>/dev/null | sort -r | head -30); do
      echo "- \`$(basename "$d")\`: $(sed -n 3p "$d/repro.txt")"
      echo "  - repro: \`$(sed -n 2p "$d/repro.txt")\`"
    done
  } > "$out" && mv "$out" "$SOAK/summary.md"
}

run() {
  mkdir -p "$SOAK/logs" "$SOAK/fail"
  echo $$ > "$SOAK/soak.pid"
  echo 900 > /proc/self/oom_score_adj  # the first out-of-memory victim; everything it starts inherits it
  # A build made before the Spike and program ISAs were recorded is rebuilt.
  [ -s "$SOAK/spike_isa" ] && [ -s "$SOAK/prog_isa" ] || rm -f "$SOAK/commit"
  [ -s "$SOAK/commit" ] && [ ! -s "$SOAK/fingerprint" ] && fingerprint "$(cat "$SOAK/commit")" > "$SOAK/fingerprint"
  trap 'rm -f "$SOAK/soak.pid"; exit 0' TERM INT
  local commit seed free load irq
  while :; do
    state_note=""
    [ -f "$SOAK/logs/soak.log" ] && [ "$(stat -c %s "$SOAK/logs/soak.log")" -gt 1000000 ] &&
      mv "$SOAK/logs/soak.log" "$SOAK/logs/soak.log.1"
    commit=$(git --git-dir="$SOAK_GIT" rev-parse --short main 2>/dev/null) || { sleep 600; continue; }
    free=$(df -BG --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$free" ] && [ "$free" -lt 20 ]; then
      log "holding: C: has $free GB free"; summarize "$commit" "holding (C: under 20 GB free)"; sleep 1800; continue
    fi
    if [ "$(mem_gb)" -lt "$MEM_GB" ]; then
      summarize "$commit" "waiting (MemAvailable $(mem_gb) GB, under $MEM_GB)"; sleep 120; continue
    fi
    # Between rounds nothing of ours runs: more than 20 runnable tasks means the tracks are busy.
    load=$(cut -d' ' -f4 /proc/loadavg); load=${load%/*}
    if [ "$load" -gt 20 ]; then
      summarize "$commit" "waiting ($load runnable tasks)"; sleep 300; continue
    fi
    if [ "$(cat "$SOAK/commit" 2>/dev/null)" != "$commit" ] && [ -s "$SOAK/commit" ] &&
       [ "$(fingerprint "$commit")" = "$(cat "$SOAK/fingerprint" 2>/dev/null)" ]; then
      log "main $commit changes nothing the soak builds: no rebuild"
      echo "$commit" > "$SOAK/commit"
    fi
    if [ "$(cat "$SOAK/commit" 2>/dev/null)" != "$commit" ]; then
      if [ "$(mem_gb)" -lt "$BUILD_MEM_GB" ]; then
        # Too little memory to build main now: keep soaking the previous build, if there is one
        # (programs take about 12 MB each), and try again after the round.
        if [ -s "$SOAK/commit" ]; then
          state_note="main $commit waits for $BUILD_MEM_GB GB to build"
          commit=$(cat "$SOAK/commit")
        else
          summarize "$commit" "waiting ($BUILD_MEM_GB GB available needed to build; MemAvailable $(mem_gb) GB)"
          sleep 120; continue
        fi
      else
        log "building main $commit"
        if ! prepare "$commit"; then
          log "build of $commit failed (logs/build.log)"; summarize "$commit" "build failed, retry in 30 min"
          sleep 1800; continue
        fi
      fi
    fi
    seed=$(cat "$SOAK/next_seed" 2>/dev/null || echo 1000000)
    echo $((seed + 4 * SEEDS)) > "$SOAK/next_seed"
    irq=$(( (seed / (4 * SEEDS)) % 2 * 200 ))
    log "round: main $commit, seeds $seed..$((seed + 4 * SEEDS - 1)), irq $irq"
    summarize "$commit" "running${state_note:+; $state_note}"
    local i=0 cfg day; day=$(date +%F)
    for cfg in $CFGS; do
      campaign "$commit" "$cfg" $((seed + i * SEEDS)) "$irq" "$day" &
      i=$((i + 1))
    done
    wait
    summarize "$commit" "running${state_note:+; $state_note}"
  done
}

case "${1:-}" in
  run) run ;;
  start)
    SOAK_GIT=$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir) || exit 2
    # Start again after a WSL restart, with main's copy of this script (as tools/memguard.sh does).
    { crontab -l 2>/dev/null | grep -v 'tools/ci/soak\.sh'
      echo "@reboot /bin/bash $(dirname "$SOAK_GIT")/tools/ci/soak.sh start >/dev/null 2>&1"; } | crontab -
    if running; then echo "soak: already running (pid $(cat "$SOAK/soak.pid"))"; exit 0; fi
    mkdir -p "$SOAK/bin" "$SOAK/logs"
    # A private copy runs, so editing this file does not disturb the running loop.
    cp "$0" "$SOAK/bin/soak.sh"
    export SOAK_GIT TANAGER_BUILD="${TANAGER_BUILD:-$HOME/tanager-build}"
    nohup setsid nice -n 19 ionice -c3 "$SOAK/bin/soak.sh" run >> "$SOAK/logs/soak.log" 2>&1 < /dev/null &
    sleep 2
    running && echo "soak: started (pid $(cat "$SOAK/soak.pid")); summary in $SOAK/summary.md" ||
      { echo "soak: did not start, see $SOAK/logs/soak.log"; exit 1; }
    ;;
  stop)
    if ! running; then echo "soak: not running"; rm -f "$SOAK/soak.pid"; exit 0; fi
    pid=$(cat "$SOAK/soak.pid")
    kill -TERM -- -"$pid" 2>/dev/null   # the whole process group: builds and simulations too
    for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -KILL -- -"$pid" 2>/dev/null
    rm -f "$SOAK/soak.pid"
    echo "soak: stopped"
    ;;
  disable)  # stop it and do not start it at boot either
    crontab -l 2>/dev/null | grep -v 'tools/ci/soak\.sh' | crontab -
    "$0" stop
    ;;
  status)
    if running; then echo "soak: running (pid $(cat "$SOAK/soak.pid"))"; else echo "soak: not running"; fi
    [ -f "$SOAK/summary.md" ] && head -20 "$SOAK/summary.md"
    ;;
  *) echo "usage: $0 start | stop | disable | status"; exit 2 ;;
esac
