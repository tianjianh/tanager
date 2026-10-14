#!/bin/bash
# Continuous soak of main on the build host (docs/spec/verification.md §4.4). Each round runs
# constrained-random programs on the real core, every M3 switch on, in st, st_w3, smt2 and smt2_w3
# at once, with memory stress (latency 30-250), timer interrupts and trace back-pressure. Findings
# go to a triage list, $TANAGER_BUILD/soak/summary.md; they never gate merges.
# Strictly background: nice 19 and idle I/O, at most 12 simulations, no Vivado, no checkout touched
# (main is exported with git archive), holds while the host drive C: has under 20 GB free or the
# machine is busy.
#   tools/ci/soak.sh start | stop | status
set -u
SOAK="${TANAGER_BUILD:-$HOME/tanager-build}/soak"
CFGS="st st_w3 smt2 smt2_w3"
JOBS=3                  # simulations per configuration: 4 x 3 = 12 at most
SEEDS=400               # programs per configuration per round (about a minute)
M3_ISA=rv64imac_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs
M3_SPIKE="--isa=$M3_ISA --priv=MSU --pmp=16"
KEEP_FAILS=100          # failure directories kept (oldest go first)

log() { echo "$(date '+%F %T') soak: $*"; }
running() { [ -f "$SOAK/soak.pid" ] && kill -0 "$(cat "$SOAK/soak.pid")" 2>/dev/null; }

# Export main into $SOAK/src (no checkout is touched), turn every M3 switch on, build.
prepare() {
  local commit=$1 src="$SOAK/src/tanager"
  rm -rf "$SOAK/src" "$SOAK/build"
  mkdir -p "$src"
  git --git-dir="$SOAK_GIT" archive "$commit" rtl sim tests/random tools | tar -x -C "$src" || return 1
  sed -i -E "s/(localparam bit EXT_(SU|A|C|B|ZICOND)[[:space:]]*=[[:space:]]*)1'b0/\\11'b1/" \
    "$src/rtl/core/tg_core_pkg.sv"
  if grep -Eq "localparam bit EXT_(SU|A|C|B|ZICOND)[[:space:]]*=[[:space:]]*1'b0" "$src/rtl/core/tg_core_pkg.sv"; then
    log "could not turn the M3 switches on"; return 1
  fi
  (
    source "$src/tools/env.sh" >/dev/null 2>&1
    export CCACHE_DISABLE=1  # keep the tracks' ccache entries
    for cfg in $CFGS; do
      make -s -C "$src/sim" CFG="$cfg" CORE=core JOBS=12 TANAGER_BUILD="$SOAK/build" \
        ISA="$M3_ISA" PRIV=MSU PMP=16 build || exit 1
    done
    make -s -C "$src/sim" TANAGER_BUILD="$SOAK/build" replay || exit 1
  ) > "$SOAK/logs/build.log" 2>&1 || return 1
  # Trace back-pressure when tg_core's build has trace_stall_i: older mains report it through
  # print-trace-stall; newer ones always connect it.
  local ts=--trace-stall
  if grep -q "print-trace-stall" "$src/sim/Makefile" &&
     [ "$(make -s --no-print-directory -C "$src/sim" CORE=core print-trace-stall)" != 1 ]; then ts=""; fi
  echo "$ts" > "$SOAK/trace_stall"
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
      --replay "$SOAK/build/tanager/sim/replay/tg_replay" --n "$SEEDS" --seed "$seed" --isa rv64imac \
      --irq "$irq" --length 400 --stress $(cat "$SOAK/trace_stall") --jobs "$JOBS" --timeout 1200 --workdir "$work" \
      --name "soak $cfg" -- $M3_SPIKE ) > "$work/out.txt" 2>&1
  local res pass fail gen
  res=$(grep "passed, " "$work/out.txt" | tail -1)
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
    echo "- main: \`$commit\`, every M3 switch on, Spike \`$M3_SPIKE\`; random programs (rv64imac) with memory stress and timer interrupts on alternate rounds; trace back-pressure $stall"
    echo "- state: $state ($(date '+%F %T')); C: has $(df -BG --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc '0-9') GB free"
    echo "- findings are a triage list: they gate nothing until confirmed as core bugs (verification.md §4.4)"
    echo
    echo "## Programs per day and configuration"
    echo
    echo "| day | configuration | programs | failures |"
    echo "|---|---|---|---|"
    awk -F'\t' '{n[$1"|"$2]+=$4; f[$1"|"$2]+=$5} END {for (k in n) {split(k, a, "|"); print "| " a[1] " | " a[2] " | " n[k] " | " f[k] " |"}}' \
      "$SOAK/counts.tsv" 2>/dev/null | sort -r | head -40
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
  trap 'rm -f "$SOAK/soak.pid"; exit 0' TERM INT
  local commit seed free load irq
  while :; do
    [ -f "$SOAK/logs/soak.log" ] && [ "$(stat -c %s "$SOAK/logs/soak.log")" -gt 1000000 ] &&
      mv "$SOAK/logs/soak.log" "$SOAK/logs/soak.log.1"
    commit=$(git --git-dir="$SOAK_GIT" rev-parse --short main 2>/dev/null) || { sleep 600; continue; }
    free=$(df -BG --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$free" ] && [ "$free" -lt 20 ]; then
      log "holding: C: has $free GB free"; summarize "$commit" "holding (C: under 20 GB free)"; sleep 1800; continue
    fi
    # Between rounds nothing of ours runs: more than 20 runnable tasks means the tracks are busy.
    load=$(cut -d' ' -f4 /proc/loadavg); load=${load%/*}
    if [ "$load" -gt 20 ]; then
      summarize "$commit" "waiting ($load runnable tasks)"; sleep 300; continue
    fi
    if [ "$(cat "$SOAK/commit" 2>/dev/null)" != "$commit" ]; then
      log "building main $commit"
      if ! prepare "$commit"; then
        log "build of $commit failed (logs/build.log)"; summarize "$commit" "build failed, retry in 30 min"
        sleep 1800; continue
      fi
    fi
    seed=$(cat "$SOAK/next_seed" 2>/dev/null || echo 1000000)
    echo $((seed + 4 * SEEDS)) > "$SOAK/next_seed"
    irq=$(( (seed / (4 * SEEDS)) % 2 * 200 ))
    log "round: main $commit, seeds $seed..$((seed + 4 * SEEDS - 1)), irq $irq"
    summarize "$commit" "running"
    local i=0 cfg day; day=$(date +%F)
    for cfg in $CFGS; do
      campaign "$commit" "$cfg" $((seed + i * SEEDS)) "$irq" "$day" &
      i=$((i + 1))
    done
    wait
    summarize "$commit" "running"
  done
}

case "${1:-}" in
  run) run ;;
  start)
    if running; then echo "soak: already running (pid $(cat "$SOAK/soak.pid"))"; exit 0; fi
    mkdir -p "$SOAK/bin" "$SOAK/logs"
    # A private copy runs, so editing this file does not disturb the running loop.
    cp "$0" "$SOAK/bin/soak.sh"
    SOAK_GIT=$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir) || exit 2
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
  status)
    if running; then echo "soak: running (pid $(cat "$SOAK/soak.pid"))"; else echo "soak: not running"; fi
    [ -f "$SOAK/summary.md" ] && head -20 "$SOAK/summary.md"
    ;;
  *) echo "usage: $0 start | stop | status"; exit 2 ;;
esac
