#!/bin/bash
# Regression for one configuration (docs/spec/verification.md §4.3). Run after `source tools/env.sh`.
#   tools/ci/regress.sh [CFG=st] [CORE=core|tcore] [LAT=native] [SUITES="rv64ui-p ..."] [MARCH=rv64im]
#                       [SIMARGS="..."] [SELFTEST=1] [RANDN=100] [RANDFD=50] [ARCH=0] [ACTCFG=...] [JOBS=8]
#                       [TIMING_CUTS=0|1]   (the core's other profile, DR-140; sim/profile.mk)
# Steps: build tg_vsim and tg_replay; riscv-tests, our directed tests (interrupts), CoreMark A/B and
# Dhrystone, RANDN constrained-random programs, all with lockstep; the riscv-tests and directed tests
# again under trace back-pressure; with ARCH=1 the ACT4 tests of the
# core's configuration (tests/arch); the checker self-test and RANDFD random F/D programs (tg_replay).
# Prints a summary and exits non-zero on any failure.
set -u
CFG=st CORE=core LAT=native SUITES="" MARCH="" SIMARGS="" SELFTEST=1 JOBS=8 RANDN=100 RANDFD=50 ARCH=0 ACTCFG="" TIMING_CUTS=""
for kv in "$@"; do
  case "$kv" in
    CFG=*|CORE=*|LAT=*|SUITES=*|MARCH=*|SIMARGS=*|SELFTEST=*|JOBS=*|RANDN=*|RANDFD=*|ARCH=*|ACTCFG=*|TIMING_CUTS=*) declare "${kv%%=*}=${kv#*=}" ;;
    *) echo "usage: $0 [CFG=..] [CORE=..] [LAT=..] [SUITES=..] [MARCH=..] [SIMARGS=..] [SELFTEST=0|1] [RANDN=N] [RANDFD=N] [ARCH=0|1] [ACTCFG=..] [JOBS=N] [TIMING_CUTS=0|1]"; exit 5 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WT="$(basename "$ROOT")"
BUILD="${TANAGER_BUILD:-$HOME/tanager-build}/$WT"
TCS="${TIMING_CUTS:+-tc$TIMING_CUTS}"   # the profile's directory suffix (sim/profile.mk)
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
  grep -E "passed, [0-9]+ failed|self-test:|^  (FAIL|TIMEOUT|HANG|MISMATCH|PROTOCOL|MISSED|OUTPUT|REF-FAIL|GEN-FAIL|SELFCHECK|NO-SUMMARY)|repro:|^(coremark|dhrystone)" "$log" | sed 's/^/   /' | head -40
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
