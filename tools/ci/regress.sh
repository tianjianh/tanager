#!/bin/bash
# Regression for one configuration (docs/spec/verification.md §4.3). Run after `source tools/env.sh`.
#   tools/ci/regress.sh [CFG=st] [CORE=core|tcore] [LAT=native] [SUITES="rv64ui-p ..."] [MARCH=rv64im]
#                       [SIMARGS="..."] [SELFTEST=1] [RANDN=100] [RANDFD=50] [ARCH=0] [ACTCFG=...] [JOBS=8]
#                       [TIMING_CUTS=0|1|both]   (the core's profiles, DR-140; sim/profile.mk) [COHN=20] [PGN=12]
#                       [DC_MSHRS=1|4]           (the L1D's misses in flight, DR-149; sim/profile.mk)
#                       [QUEUE_DECODE=0|1]       (G8's instruction-queue decode bits; sim/profile.mk)
#                       [SPEC_WAKE=0|1]          (M6's speculative load wakeup, DR-153; sim/profile.mk)
#                       [STA_BASE=0|1] [STEER_LA=0|1] (M6's store address on its base, its steering a group ahead; DR-169)
#                       [PMP_ENTRIES=8|16]       (the core's PMP entries, DR-167; lockstep's Spike takes the model's count)
#                       [STORE_PF=0|1]           (M6's ownership prefetch for stores, DR-171; sim/profile.mk)
# Steps: build tg_vsim and tg_replay; riscv-tests, our directed tests (interrupts), CoreMark A/B and
# Dhrystone, RANDN constrained-random programs, all with lockstep; the riscv-tests and directed tests
# again under trace back-pressure; with ARCH=1 the ACT4 tests of the
# core's configuration (tests/arch); the checker self-test and RANDFD random F/D programs (tg_replay);
# for CORE=core, PGN random programs with a probe at every GrantAck (forward progress: each store and
# atomic must use its line before giving it up) and COHN coherence programs on the two-core SoC
# (tests/coherence: atomics and LR/SC loops on one line from the same cycle, lockstep for every hart).
# Prints a summary and exits non-zero on any failure. TIMING_CUTS=both runs the default and the
# fallback side by side (make regress-profiles; below).
set -u
CFG=st CORE=core LAT=native SUITES="" MARCH="" SIMARGS="" SELFTEST=1 JOBS=8 RANDN=100 RANDFD=50 ARCH=0 ACTCFG="" TIMING_CUTS="" COHN=20 PGN=12 DC_MSHRS="" QUEUE_DECODE="" SPEC_WAKE="" STA_BASE="" STEER_LA="" PMP_ENTRIES="" STORE_PF=""
for kv in "$@"; do
  case "$kv" in
    CFG=*|CORE=*|LAT=*|SUITES=*|MARCH=*|SIMARGS=*|SELFTEST=*|JOBS=*|RANDN=*|RANDFD=*|ARCH=*|ACTCFG=*|TIMING_CUTS=*|COHN=*|PGN=*|DC_MSHRS=*|QUEUE_DECODE=*|SPEC_WAKE=*|STA_BASE=*|STEER_LA=*|PMP_ENTRIES=*|STORE_PF=*) declare "${kv%%=*}=${kv#*=}" ;;
    *) echo "usage: $0 [CFG=..] [CORE=..] [LAT=..] [SUITES=..] [MARCH=..] [SIMARGS=..] [SELFTEST=0|1] [RANDN=N] [RANDFD=N] [ARCH=0|1] [ACTCFG=..] [JOBS=N] [TIMING_CUTS=0|1|both] [COHN=N] [PGN=N] [DC_MSHRS=1|4] [QUEUE_DECODE=0|1] [SPEC_WAKE=0|1] [STA_BASE=0|1] [STEER_LA=0|1] [PMP_ENTRIES=8|16] [STORE_PF=0|1]"; exit 5 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WT="$(basename "$ROOT")"
BUILD="${TANAGER_BUILD:-$HOME/tanager-build}/$WT"

# TIMING_CUTS=both: DR-140's two profiles side by side, the default (unset) and the fallback (0), with
# half the jobs each. What both runs read is built first (tg_replay, the directed tests, the
# benchmarks and, with ARCH=1, the ACT4 tests), so that neither builds it while the other reads it.
# The Spike-only steps (the checker self-test and the random F/D programs) run once, in the
# default's run. If no RTL file mentions TG_TIMING_CUTS, the profiles are one build: only the default runs.
if [ "$TIMING_CUTS" = both ]; then
  args=()
  for kv in "$@"; do case "$kv" in TIMING_CUTS=*|JOBS=*) ;; *) args+=("$kv") ;; esac; done
  if ! grep -rqsw TG_TIMING_CUTS "$ROOT/rtl" --include='*.sv' --include='*.svh'; then
    echo "no RTL mentions TG_TIMING_CUTS, so the two profiles are one build: running the default only"
    exec "$0" "${args[@]}" JOBS="$JOBS"
  fi
  : "${RISCV_TESTS:?source tools/env.sh first}"
  BOTH="$BUILD/regress/$CFG-$CORE-both"
  mkdir -p "$BOTH"
  half=$(( JOBS > 1 ? JOBS / 2 : 1 ))
  t0=$SECONDS
  echo "== tg_replay and the test programs both profiles read"
  shared() {
    make -C "$ROOT/sim" JOBS="$JOBS" replay lockstep &&
      make -C "$ROOT/tests/isa" build-directed &&
      make -C "$ROOT/tests/bench" build MARCH="${MARCH:-rv64im}" &&
      { [ "$ARCH" != 1 ] || make -C "$ROOT/tests/arch" elfs CORE="$CORE" ${ACTCFG:+ACTCFG="$ACTCFG"}; }
  }
  shared > "$BOTH/shared.log" 2>&1 || { echo "   FAIL, log: $BOTH/shared.log"; exit 1; }
  echo "== the default and the fallback (TIMING_CUTS=0) side by side, $half jobs each"
  # Each run is a process group of its own, so that an interrupt stops its builds and simulations too.
  pd="" pf=""
  trap 'kill -TERM -- ${pd:+-$pd} ${pf:+-$pf} 2>/dev/null; exit 130' INT TERM HUP
  setsid "$0" "${args[@]}" JOBS="$half" > "$BOTH/default.log" 2>&1 < /dev/null & pd=$!
  setsid "$0" "${args[@]}" JOBS="$half" TIMING_CUTS=0 SELFTEST=0 RANDFD=0 > "$BOTH/fallback.log" 2>&1 < /dev/null & pf=$!
  wait $pd; rd=$?
  wait $pf; rf=$?
  trap - INT TERM HUP
  for p in default fallback; do
    r=$rd; [ $p = fallback ] && r=$rf
    echo
    echo "#### $p ($BOTH/$p.log)"
    if [ "$r" = 0 ]; then sed -n '/^==== regression summary/,$p' "$BOTH/$p.log"; else cat "$BOTH/$p.log"; fi
  done
  echo
  if [ "$rd" = 0 ] && [ "$rf" = 0 ]; then
    echo "REGRESS PASS: both profiles, the default and TIMING_CUTS=0 ($((SECONDS - t0)) s)"
    exit 0
  fi
  echo "REGRESS FAIL:$([ "$rd" = 0 ] || echo " the default")$([ "$rf" = 0 ] || echo " TIMING_CUTS=0") ($((SECONDS - t0)) s)"
  exit 1
fi
# DR-149's and G8's switches reach every make below through the environment (sim/profile.mk reads them)
[ -n "$DC_MSHRS" ] && export DC_MSHRS
[ -n "$QUEUE_DECODE" ] && export QUEUE_DECODE
[ -n "$SPEC_WAKE" ] && export SPEC_WAKE
[ -n "$STA_BASE" ] && export STA_BASE
[ -n "$STEER_LA" ] && export STEER_LA
[ -n "$PMP_ENTRIES" ] && export PMP_ENTRIES
[ -n "$STORE_PF" ] && export STORE_PF
TCS="${TIMING_CUTS:+-tc$TIMING_CUTS}${DC_MSHRS:+-m$DC_MSHRS}${QUEUE_DECODE:+-qd$QUEUE_DECODE}${SPEC_WAKE:+-sw$SPEC_WAKE}${STA_BASE:+-sb$STA_BASE}${STEER_LA:+-sl$STEER_LA}${PMP_ENTRIES:+-p$PMP_ENTRIES}${STORE_PF:+-spf$STORE_PF}"   # the build directories' suffix (sim/profile.mk)
LOGS="$BUILD/regress/$CFG-$CORE$TCS"
mkdir -p "$LOGS"
: "${RISCV_TESTS:?source tools/env.sh first}"

# What each core is expected to pass today (verification.md §4.1). The core track widens SUITES
# and MARCH as features land (M3: rv64ua/uc/si and -v; M5: uf/ud; benchmarks in rv64gc).
EXCL=(--exclude "$ROOT/tests/isa/exclude/tanager.txt")
if [ "$CORE" = tcore ]; then
  EXCL+=(--exclude "$ROOT/tests/isa/exclude/tcore.txt")
fi
[ -f "$ROOT/tests/isa/exclude/$CFG.txt" ] && EXCL+=(--exclude "$ROOT/tests/isa/exclude/$CFG.txt")
if [ "$CORE" = core ]; then   # M3: A, C, F, D, Zba/Zbb/Zbs, Zicond, S and U with Sv39
  SUITES="${SUITES:-rv64ui-p rv64um-p rv64ua-p rv64uc-p rv64uf-p rv64ud-p rv64mi-p rv64si-p rv64ui-v rv64um-v rv64ua-v rv64uc-v rv64uf-v rv64ud-v rv64uzba-v rv64uzbb-v rv64uzbs-v rv64uzicond-v}"
fi
SUITES="${SUITES:-rv64ui-p rv64um-p rv64mi-p}"
MARCH="${MARCH:-rv64im}"

declare -a NAMES RESULTS
step() {  # step <name> <log> <command...>
  local name="$1" log="$2"; shift 2
  local t0=$SECONDS
  echo "== $name"
  if "$@" > "$log" 2>&1; then
    RESULTS+=("PASS")
  else
    RESULTS+=("FAIL")
  fi
  NAMES+=("$name ($((SECONDS - t0)) s)")
  grep -E "passed, [0-9]+ failed|self-test:|^  (FAIL|TIMEOUT|HANG|MISMATCH|PROTOCOL|MISSED|OUTPUT|REF-FAIL|GEN-FAIL|SELFCHECK|NO-SUMMARY|LOCKSTEP)|repro:|^(coremark|dhrystone)" "$log" | sed 's/^/   /' | head -40
  [ "${RESULTS[-1]}" = PASS ] || echo "   log: $log"
}

step "build tg_vsim CFG=$CFG CORE=$CORE${TIMING_CUTS:+ TIMING_CUTS=$TIMING_CUTS} and tg_replay" "$LOGS/build.log" \
  make -C "$ROOT/sim" CFG="$CFG" CORE="$CORE" ${TIMING_CUTS:+TIMING_CUTS="$TIMING_CUTS"} JOBS="$JOBS" build replay
BIN="$BUILD/sim/$CFG-$CORE$TCS/tg_vsim"
REPLAY="$BUILD/sim/replay/tg_replay"

if [ "${RESULTS[0]}" = PASS ]; then
  step "riscv-tests ($SUITES), lockstep, lat=$LAT" "$LOGS/isa.log" \
    python3 "$ROOT/tests/isa/run_isa.py" --sim "$BIN" --suites "$SUITES" "${EXCL[@]}" --jobs "$JOBS" \
      --logdir "$LOGS/isa" --name "riscv-tests $CFG $CORE" -- --lat="$LAT" $SIMARGS
  step "directed tests (interrupts, WFI), lockstep, lat=$LAT" "$LOGS/directed.log" \
    make -C "$ROOT/tests/isa" directed CFG="$CFG" CORE="$CORE" ${TIMING_CUTS:+TIMING_CUTS="$TIMING_CUTS"} LAT="$LAT" JOBS="$JOBS" SIMARGS="$SIMARGS"
  step "CoreMark A/B and Dhrystone ($MARCH), lockstep, lat=$LAT" "$LOGS/bench.log" \
    make -C "$ROOT/tests/bench" run CFG="$CFG" CORE="$CORE" ${TIMING_CUTS:+TIMING_CUTS="$TIMING_CUTS"} MARCH="$MARCH" LAT="$LAT" JOBS="$JOBS" SIMARGS="$SIMARGS"
  # Trace back-pressure (verification.md §2.9)
  stall_pass() {
    python3 "$ROOT/tests/isa/run_isa.py" --sim "$BIN" --suites "$SUITES" "${EXCL[@]}" --jobs "$JOBS" \
      --logdir "$LOGS/isa-stall" --name "riscv-tests $CFG $CORE, trace stall" -- --lat="$LAT" --trace-stall=50 \
      $SIMARGS &&
    make -C "$ROOT/tests/isa" directed CFG="$CFG" CORE="$CORE" ${TIMING_CUTS:+TIMING_CUTS="$TIMING_CUTS"} LAT="$LAT" JOBS="$JOBS" \
      SIMARGS="--trace-stall=50 $SIMARGS"
  }
  step "riscv-tests and directed tests under trace back-pressure (--trace-stall=50), lockstep" \
    "$LOGS/stall.log" stall_pass
  if [ "$RANDN" != 0 ]; then
    step "random programs ($RANDN seeds, $MARCH, memory stress), lockstep" "$LOGS/random.log" \
      make -C "$ROOT/tests/random" CFG="$CFG" CORE="$CORE" ${TIMING_CUTS:+TIMING_CUTS="$TIMING_CUTS"} N="$RANDN" SEED=1 ISA="$MARCH" JOBS="$JOBS" SIMARGS="$SIMARGS"
  fi
  if [ "$PGN" != 0 ] && [ "$CORE" = core ]; then
    step "random programs with a probe at every GrantAck ($PGN seeds, --probe-grant=100), lockstep" "$LOGS/probe-grant.log" \
      make -C "$ROOT/tests/random" CFG="$CFG" CORE="$CORE" ${TIMING_CUTS:+TIMING_CUTS="$TIMING_CUTS"} N="$PGN" SEED=1 ISA="$MARCH" \
        STRESS=0 JOBS="$JOBS" WORK="$BUILD/random/$CFG-$CORE$TCS-probe-grant" SIMARGS="--probe-grant=100 $SIMARGS"
  fi
  if [ "$COHN" != 0 ] && [ "$CORE" = core ]; then
    step "coherence programs ($COHN seeds, two cores, AMOs, lotteries and LR/SC on one line), lockstep" "$LOGS/coherence.log" \
      make -C "$ROOT/tests/coherence" CFG="$CFG" ${TIMING_CUTS:+TIMING_CUTS="$TIMING_CUTS"} N="$COHN" SEED=1 JOBS="$JOBS"
  fi
  if [ "$ARCH" = 1 ]; then
    step "riscv-arch-test (ACT4${ACTCFG:+ $ACTCFG}), self-check and lockstep, lat=$LAT" "$LOGS/arch.log" \
      make -C "$ROOT/tests/arch" CFG="$CFG" CORE="$CORE" ${TIMING_CUTS:+TIMING_CUTS="$TIMING_CUTS"} ${ACTCFG:+ACTCFG="$ACTCFG"} JOBS="$JOBS" \
        SIMARGS="--lat=$LAT $SIMARGS"
  fi
  if [ "$SELFTEST" = 1 ]; then
    step "checker self-test (Spike against Spike, fault injection)" "$LOGS/selftest.log" \
      python3 "$ROOT/tools/ci/checker_selftest.py" --replay "$REPLAY" --jobs "$JOBS" --logdir "$LOGS/selftest" \
        --directed "$BUILD/directed"
  fi
  if [ "$RANDFD" != 0 ]; then
    step "random F/D programs ($RANDFD seeds, rv64gc), Spike against Spike with checker perturbations" \
      "$LOGS/random-fd.log" make -C "$ROOT/tests/random" replay ISA=rv64gc N="$RANDFD" SEED=1 JOBS="$JOBS"
  fi
fi

echo
echo "==== regression summary: CFG=$CFG CORE=$CORE${TIMING_CUTS:+ TIMING_CUTS=$TIMING_CUTS} LAT=$LAT ===="
fail=0
for i in "${!NAMES[@]}"; do
  printf '  %-4s  %s\n' "${RESULTS[$i]}" "${NAMES[$i]}"
  [ "${RESULTS[$i]}" = PASS ] || fail=1
done
[ $fail = 0 ] && echo "REGRESS PASS" || echo "REGRESS FAIL (logs in $LOGS)"
exit $fail
