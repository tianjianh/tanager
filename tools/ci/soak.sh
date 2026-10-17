#!/bin/bash
# Continuous soak of main on the build host (docs/spec/verification.md §4.4). Each round runs
# constrained-random programs on the real core, every M3 switch on, in st, st_w3, smt2 and smt2_w3
# at once, with memory stress (latency 30-250), timer interrupts and trace back-pressure, then, once
# main has tests/coherence, coherence programs on the two-core SoC (verification.md §6.5). Findings
# go to a triage list, $TANAGER_BUILD/soak/summary.md; they never gate merges.
# Strictly background: nice 19 and idle I/O, at most 8 simulations, no Vivado, no checkout touched
# (main is exported with git archive), the first out-of-memory victim (oom_score_adj 900); it starts
# no program while MemAvailable is under 12 GB (no build under 16 GB), and holds while the host
# drive C: has under 12 GB free, WSL's own root filesystem has under 15 GB free, or the machine is busy.
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
C_MIN_GB=12             # hold while the host drive C:, which holds WSL's virtual disk, has less free
WSL_MIN_GB=15           # or WSL's root filesystem has less free (df /: it binds once the disk is capped)
BUILD_MEM_GB=16         # nor a build, so that one keeps MemAvailable above MEM_GB
SEEDS=400               # programs per configuration per round (about a minute)
VM_PCT=33               # share of the programs that run in S-mode under Sv39 (tg_rand --vm)
# Spike's ISA follows the core's switches: the M3 string, with f and d once tg_core has EXT_FD.
M3_ISA=rv64imac_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs
M3FD_ISA=rv64imafdc_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs
spike_args() { echo "--isa=$(cat "$SOAK/spike_isa" 2>/dev/null) --priv=MSU --pmp=16"; }
KEEP_FAILS=100          # failure directories kept (oldest go first)
COH_CFGS="st smt2"      # coherence rounds: two cores, harts 0 and 1, or 0 and 2 (thread 0 of each smt2 core)
COH_SEEDS=20            # coherence programs per configuration per round (about 30 s)
COH_MODES=lottery,amo   # LR/SC loops hang on today's RTL (no LR/SC hold yet), so they stay out

log() { echo "$(date '+%F %T') soak: $*"; }
# What the soak builds from a commit: a main that changes none of it needs no rebuild.
fingerprint() {
  git --git-dir="$SOAK_GIT" rev-parse "$1:rtl" "$1:sim" "$1:tests/random" "$1:tools" 2>/dev/null | tr '\n' ' '
  local p  # paths an older main lacks, one at a time: rev-parse stops at the first missing one
  for p in tests/unit tests/coherence; do git --git-dir="$SOAK_GIT" rev-parse -q --verify "$1:$p" 2>/dev/null; done | tr '\n' ' '
}
mem_gb() { awk '/^MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo; }
# The PID must still be a soak: after a restart the old number can belong to anything.
running() { [ -f "$SOAK/soak.pid" ] && grep -qa "soak.sh" "/proc/$(cat "$SOAK/soak.pid")/cmdline" 2>/dev/null; }

# Export main into $SOAK/src (no checkout is touched), turn every M3 switch on, build.
prepare() {
  local commit=$1 src="$SOAK/src/tanager"
  rm -f "$SOAK/commit"  # an interrupted build must never be used
  rm -rf "$SOAK/src" "$SOAK/build"
  mkdir -p "$src"
  # The coherence programs, once main has them, with the two-core SoC testbench they run on
  local paths="rtl sim tests/random tools" coh=""
  if git --git-dir="$SOAK_GIT" rev-parse -q --verify "$commit:tests/coherence" > /dev/null &&
     git --git-dir="$SOAK_GIT" rev-parse -q --verify "$commit:tests/unit/boot" > /dev/null; then
    paths="$paths tests/unit tests/coherence"; coh=1
  fi
  git --git-dir="$SOAK_GIT" archive "$commit" $paths | tar -x -C "$src" || return 1
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
  # DR-140's timing cuts: once main's core package has the switch and its sim/ the profiles, both are
  # built and the rounds alternate between them (verification.md §4.4).
  local tcs=""
  if grep -q "TG_TIMING_CUTS" "$pkg" && [ -f "$src/sim/profile.mk" ]; then tcs="0 1"; fi
  (
    source "$src/tools/env.sh" >/dev/null 2>&1
    export CCACHE_DISABLE=1  # keep the tracks' ccache entries
    for cfg in $CFGS; do
      for tc in ${tcs:-default}; do
        make -s -C "$src/sim" CFG="$cfg" CORE=core JOBS="$BUILD_JOBS" TANAGER_BUILD="$SOAK/build" \
          ISA="$isa" PRIV=MSU PMP=16 $([ "$tc" != default ] && echo "TIMING_CUTS=$tc") build || exit 1
      done
    done
    make -s -C "$src/sim" TANAGER_BUILD="$SOAK/build" replay || exit 1
    if [ -n "$coh" ]; then  # the default profile only
      for cfg in $COH_CFGS; do
        make -s -C "$src/tests/unit/boot" build CFG="$cfg" CORES=2 VTHREADS=1 JOBS="$BUILD_JOBS" \
          TANAGER_BUILD="$SOAK/build" || exit 1
      done
      make -s -C "$src/sim" TANAGER_BUILD="$SOAK/build" lockstep || exit 1
    fi
  ) > "$SOAK/logs/build.log" 2>&1 || return 1
  # The coherence rounds' DDR timing: the board's (18-26 cycles, fixed and jittered) once tb_axi_mem
  # takes it at run time, the testbench's own before; and the cycle limit, short where tb_boot allows
  if [ -n "$coh" ]; then
    local lat=default limit="--max-mcycles 1"
    grep -q "mem_lat_min" "$src/tests/unit/common/tb_axi_mem.sv" && lat=board
    grep -q "max_kcycles" "$src/tests/unit/boot/tb_boot.sv" && limit="--max-kcycles 400"
    echo "--lat $lat $limit" > "$SOAK/coh"
  else
    echo > "$SOAK/coh"
  fi
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
  # Miss-heavy rounds (DR-149: misses in flight, probes against them), once main's generator has --miss
  if grep -q -- '"--miss"' "$src/tests/random/run_random.py"; then echo 1; else echo; fi > "$SOAK/miss_ok"
  echo "$tcs" > "$SOAK/timing_cuts"
  fingerprint "$commit" > "$SOAK/fingerprint"
  echo "$commit" > "$SOAK/commit"
}

# One configuration's campaign; failures keep the program, the end of the log and a repro line.
campaign() {
  local commit=$1 cfg=$2 seed=$3 irq=$4 day=$5 tc=${6:-} miss=${7:-} work="$SOAK/work/$2"
  local sim="$SOAK/build/tanager/sim/$cfg-core${tc:+-tc$tc}/tg_vsim" label="$cfg${tc:+-tc$tc}"
  rm -rf "$work"
  mkdir -p "$work"
  ( source "$SOAK/src/tanager/tools/env.sh" >/dev/null 2>&1
    python3 "$SOAK/src/tanager/tests/random/run_random.py" --sim "$sim" \
      --replay "$SOAK/build/tanager/sim/replay/tg_replay" --n "$SEEDS" --seed "$seed" --isa "$(cat "$SOAK/prog_isa")" \
      --irq "$irq" --length 400 --stress $(cat "$SOAK/trace_stall") $(cat "$SOAK/mem_gate" 2>/dev/null) \
      $(cat "$SOAK/vm" 2>/dev/null) ${miss:+--miss $miss} \
      --jobs "$JOBS" --timeout 1200 --workdir "$work" \
      --name "soak $label" -- $(spike_args) ) > "$work/out.txt" 2>&1
  local res pass fail gen
  res=$(grep "passed, " "$work/out.txt" | tail -1)
  if [ -z "$res" ]; then  # the runner itself failed: a harness error, not a result
    echo "$(date '+%F %T') $label on $commit: $(tail -1 "$work/out.txt" | cut -c1-200)" >> "$SOAK/errors.log"
    return 0
  fi
  pass=$(echo "$res" | sed -n 's/.*: \([0-9]*\) passed.*/\1/p')
  fail=$(echo "$res" | sed -n 's/.* \([0-9]*\) failed.*/\1/p')
  gen=$(echo "$res" | sed -n 's/.* \([0-9]*\) generator failures.*/\1/p')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$label" "$commit" "$((${pass:-0} + ${fail:-0}))" "${fail:-0}" \
    "${gen:-0}" >> "$SOAK/counts.tsv"
  [ -d "$work/failures" ] || return 0
  local f s d
  for f in "$work"/failures/r*.elf; do
    [ -f "$f" ] || continue
    s=$(basename "$f" .elf); s=${s#r}
    d="$SOAK/fail/$(date +%Y%m%d-%H%M%S)-$label-s$s"
    mkdir -p "$d"
    cp "$f" "$work/failures/r$s.S" "$d/" 2>/dev/null
    tail -n 80 "$work/failures/r$s.log" > "$d/tail.log" 2>/dev/null
    { echo "main $commit, every M3 switch on (rtl/core/tg_core_pkg.sv), CFG=$cfg${tc:+ TIMING_CUTS=$tc}, seed $s"
      grep -A1 "seed $s:" "$work/out.txt" | sed -n 's/.*repro: //p' | \
        sed "s#$work/failures/#$d/#; s#$sim#tg_vsim#"
      grep -m1 "seed $s:" "$work/out.txt" | sed 's/^ *//'
    } > "$d/repro.txt"
  done
  ls -1d "$SOAK"/fail/*/ 2>/dev/null | head -n -"$KEEP_FAILS" | xargs -r rm -rf
}

# One configuration's coherence programs (tests/coherence); failures are kept as campaign()'s are.
coh_campaign() {
  local commit=$1 cfg=$2 seed=$3 day=$4 work="$SOAK/work/coh-$2" label="coh-$2" harts=0,1
  local tb="$SOAK/build/tanager/tests/boot_c2_t1_$2/tb_boot"
  [ "$cfg" = smt2 ] && harts=0,2
  rm -rf "$work"
  mkdir -p "$work"
  ( source "$SOAK/src/tanager/tools/env.sh" >/dev/null 2>&1
    python3 "$SOAK/src/tanager/tests/coherence/run_coh.py" --tb "$tb" \
      --lockstep "$SOAK/build/tanager/sim/lockstep/tanager-lockstep" --harts "$harts" --modes "$COH_MODES" \
      $(cat "$SOAK/coh") --n "$COH_SEEDS" --seed "$seed" --jobs 4 --workdir "$work" --name "soak $label" \
  ) > "$work/out.txt" 2>&1
  local res pass failed hung lsm gen
  res=$(grep "passed, " "$work/out.txt" | tail -1)
  if [ -z "$res" ]; then
    echo "$(date '+%F %T') $label on $commit: $(tail -1 "$work/out.txt" | cut -c1-200)" >> "$SOAK/errors.log"
    return 0
  fi
  pass=$(echo "$res" | sed -n 's/.*: \([0-9]*\) passed.*/\1/p')
  failed=$(echo "$res" | sed -n 's/.* \([0-9]*\) failed.*/\1/p')
  hung=$(echo "$res" | sed -n 's/.* \([0-9]*\) hung.*/\1/p')
  lsm=$(echo "$res" | sed -n 's/.* \([0-9]*\) lockstep mismatches.*/\1/p')
  gen=$(echo "$res" | sed -n 's/.* \([0-9]*\) generator failures.*/\1/p')
  failed=$(( ${failed:-0} + ${hung:-0} + ${lsm:-0} ))   # a hang and a lockstep mismatch are failures too
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$day" "$label" "$commit" "$((${pass:-0} + failed))" "$failed" "${gen:-0}" \
    >> "$SOAK/counts.tsv"
  [ -d "$work/failures" ] || return 0
  local f s d
  for f in "$work"/failures/c*.bin; do
    [ -f "$f" ] || continue
    s=$(basename "$f" .bin); s=${s#c}
    d="$SOAK/fail/$(date +%Y%m%d-%H%M%S)-$label-s$s"
    mkdir -p "$d"
    cp "$f" "$work/failures/c$s.S" "$work/failures/c$s.elf" "$d/" 2>/dev/null
    tail -n 80 "$work/failures/c$s.log" > "$d/tail.log" 2>/dev/null
    { echo "main $commit, every M3 switch on (rtl/core/tg_core_pkg.sv), two cores CFG=$cfg (harts $harts), seed $s"
      grep -A1 "seed $s:" "$work/out.txt" | sed -n 's/.*repro: //p' | sed "s#$work/failures/#$d/#; s#$tb#tb_boot#"
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
    echo "- main: \`$commit\`, every extension switch on, Spike \`$(spike_args)\`; random programs ($(cat "$SOAK/prog_isa" 2>/dev/null)$([ -n "$(cat "$SOAK/vm" 2>/dev/null)" ] && echo ", ${VM_PCT}% in S-mode under Sv39")) with memory stress and timer interrupts on alternate rounds$([ -n "$(cat "$SOAK/timing_cuts" 2>/dev/null)" ] && echo " (alternate pairs of rounds), the core's timing cuts (DR-140) off and on in alternate rounds"); trace back-pressure $stall"
    [ -n "$(cat "$SOAK/coh" 2>/dev/null)" ] &&
      echo "- coherence programs on the two-core SoC (tests/coherence, $COH_MODES; \`$(cat "$SOAK/coh")\`): $COH_SEEDS per round in each of $COH_CFGS"
    echo "- state: $state ($(date '+%F %T')); C: has $(df -BG --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc '0-9') GB free, WSL $(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9') GB"
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
  local commit seed free wfree load irq
  while :; do
    state_note=""
    [ -f "$SOAK/logs/soak.log" ] && [ "$(stat -c %s "$SOAK/logs/soak.log")" -gt 1000000 ] &&
      mv "$SOAK/logs/soak.log" "$SOAK/logs/soak.log.1"
    commit=$(git --git-dir="$SOAK_GIT" rev-parse --short main 2>/dev/null) || { sleep 600; continue; }
    free=$(df -BG --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$free" ] && [ "$free" -lt "$C_MIN_GB" ]; then
      log "holding: C: has $free GB free"; summarize "$commit" "holding (C: under $C_MIN_GB GB free)"; sleep 1800; continue
    fi
    wfree=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$wfree" ] && [ "$wfree" -lt "$WSL_MIN_GB" ]; then
      log "holding: WSL's root filesystem has $wfree GB free"
      summarize "$commit" "holding (WSL under $WSL_MIN_GB GB free)"; sleep 1800; continue
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
    # With both timing-cut profiles built, the profile alternates every round and the timer interrupts
    # every second round, so four rounds cover all four pairs.
    local r=$(( seed / (4 * SEEDS) )) tc=""
    if [ -n "$(cat "$SOAK/timing_cuts" 2>/dev/null)" ]; then
      tc=$(( r % 2 )); irq=$(( (r / 2) % 2 * 200 ))
    else
      irq=$(( r % 2 * 200 ))
    fi
    # Every third round mostly keeps misses in flight (tg_rand --miss 12; DR-149).
    local miss=""
    [ -n "$(cat "$SOAK/miss_ok" 2>/dev/null)" ] && [ $(( r % 3 )) = 2 ] && miss=12
    log "round: main $commit, seeds $seed..$((seed + 4 * SEEDS - 1)), irq $irq${tc:+, timing cuts $tc}${miss:+, miss-heavy}"
    summarize "$commit" "running${state_note:+; $state_note}"
    local i=0 cfg day; day=$(date +%F)
    for cfg in $CFGS; do
      campaign "$commit" "$cfg" $((seed + i * SEEDS)) "$irq" "$day" "$tc" "$miss" &
      i=$((i + 1))
    done
    wait
    if [ -n "$(cat "$SOAK/coh" 2>/dev/null)" ]; then  # then the coherence programs, 4 simulations each
      for cfg in $COH_CFGS; do coh_campaign "$commit" "$cfg" "$seed" "$day" & done
      wait
    fi
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
