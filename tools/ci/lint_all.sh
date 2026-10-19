#!/bin/bash
# make lint-all (docs/spec/verification.md §4.3): every configuration in six elaborations, so that
# every switch's branches compile: the fallback (TIMING_CUTS=0), the default, and #2, #8 and the commit
# trace off each on top of the default (ROB_STORE_REPORT_LATE=1, DE_STAGE=1, COMMIT_TRACE=0; lint only;
# DR-140, DR-146); the 4-miss L1D (DC_MSHRS=4, DR-149), G8's queue decode bits (QUEUE_DECODE=1) and M6's
# speculative load wakeup (SPEC_WAKE=1) each on top of the default; DR-169's two levers off (STA_BASE=0,
# STEER_LA=0) and DR-171's store prefetch off (STORE_PF=0), each on top of the default; the PMP entries the
# package does not default to (PMP_ENTRIES=8 or 16, DR-167); and the default's
# synthesis view (SYNTH=1: +define+SYNTHESIS, where a signal that
# synthesized logic reads but only simulation-only code drives is an error). They run JOBS at a time
# (Verilator's lint is one thread and about 0.6 GB).
# An elaboration whose define no RTL file mentions is the default's, so it is skipped.
# With them, the forward-reference check (tools/ci/fwdref.sh: Verilator's JSON dump of the synthesis
# view, about 7 s) for each configuration with the timing cuts on and off (FWDREF=1|0): it fails on a
# whole name in a port connection above its declaration, an undriven implicit net in Vivado (DR-150).
# Beside them, with VIVADO=1 (the default), Vivado's own reading of the RTL (tools/ci/vivado_rtl_lint.sh,
# DR-150): its simulator's parser and its RTL elaboration of the board top and the core, failing on a
# name used before its declaration and on implicit or undriven nets, which Verilator resolves its own
# way (the board's two-core hang, rn_fire). It goes through the Vivado admission and may wait there.
#   tools/ci/lint_all.sh [JOBS=6] [CFGS="st smt2 st_w3 smt2_w3"] [VIVADO=1]
set -u
JOBS=6 CFGS="st smt2 st_w3 smt2_w3" VIVADO=1
for kv in "$@"; do
  case "$kv" in
    JOBS=*|CFGS=*|VIVADO=*) declare "${kv%%=*}=${kv#*=}" ;;
    *) echo "usage: $0 [JOBS=N] [CFGS=\"st ...\"] [VIVADO=0|1]"; exit 2 ;;
  esac
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGS="${TANAGER_BUILD:-$HOME/tanager-build}/$(basename "$ROOT")/lint"
mkdir -p "$LOGS"
t0=$SECONDS

mentioned() { grep -rqsw "$1" "$ROOT/rtl" --include='*.sv' --include='*.svh'; }
profiles=()
if mentioned TG_TIMING_CUTS; then profiles+=("TIMING_CUTS=0"); else echo "lint-all: no RTL mentions TG_TIMING_CUTS; skipping TIMING_CUTS=0"; fi
profiles+=("")
if mentioned TG_ROB_STORE_REPORT_LATE; then profiles+=("ROB_STORE_REPORT_LATE=1"); else echo "lint-all: no RTL mentions TG_ROB_STORE_REPORT_LATE; skipping ROB_STORE_REPORT_LATE=1"; fi
if mentioned TG_DE_STAGE; then profiles+=("DE_STAGE=1"); else echo "lint-all: no RTL mentions TG_DE_STAGE; skipping DE_STAGE=1"; fi
if mentioned TG_COMMIT_TRACE; then profiles+=("COMMIT_TRACE=0"); else echo "lint-all: no RTL mentions TG_COMMIT_TRACE; skipping COMMIT_TRACE=0"; fi
if mentioned TG_DC_MSHRS; then profiles+=("DC_MSHRS=4"); else echo "lint-all: no RTL mentions TG_DC_MSHRS; skipping DC_MSHRS=4"; fi
if mentioned TG_QUEUE_DECODE; then profiles+=("QUEUE_DECODE=1"); else echo "lint-all: no RTL mentions TG_QUEUE_DECODE; skipping QUEUE_DECODE=1"; fi
if mentioned TG_SPEC_WAKE; then profiles+=("SPEC_WAKE=1"); else echo "lint-all: no RTL mentions TG_SPEC_WAKE; skipping SPEC_WAKE=1"; fi
if mentioned TG_STA_BASE; then profiles+=("STA_BASE=0"); else echo "lint-all: no RTL mentions TG_STA_BASE; skipping STA_BASE=0"; fi
if mentioned TG_STEER_LA; then profiles+=("STEER_LA=0"); else echo "lint-all: no RTL mentions TG_STEER_LA; skipping STEER_LA=0"; fi
if mentioned TG_PMP_ENTRIES; then  # the count other than the package's default (its line, as sim/profile.mk reads it)
  pmp_def=$(sed -n -E 's/^[[:space:]]*localparam[[:space:]]+int[[:space:]]+PMP_ENTRIES[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*;.*/\1/p' \
            "$ROOT/rtl/core/tg_core_pkg.sv")
  profiles+=("PMP_ENTRIES=$([ "$pmp_def" = 16 ] && echo 8 || echo 16)")
else echo "lint-all: no RTL mentions TG_PMP_ENTRIES; skipping PMP_ENTRIES"; fi
if mentioned TG_STORE_PF; then profiles+=("STORE_PF=0"); else echo "lint-all: no RTL mentions TG_STORE_PF; skipping STORE_PF=0"; fi
profiles+=("SYNTH=1")
tasks=()
for c in $CFGS; do
  for p in "${profiles[@]}"; do tasks+=("$c${p:+ $p}"); done
  tasks+=("$c FWDREF=1" "$c FWDREF=0")
done

# One line per elaboration as it finishes: PASS|FAIL <cfg> [<define>]
lint_one() {
  set -- $1
  local log="$LOGS/$1${2:+-${2/=/}}.log"
  local cmd=(make --no-print-directory -C "$ROOT" lint CFG="$1" ${2:+"$2"})
  # FWDREF=1|0: the forward-reference check with the timing cuts on (the default) or off
  case "${2:-}" in
    FWDREF=1) cmd=("$ROOT/tools/ci/fwdref.sh" CFG="$1") ;;
    FWDREF=0) cmd=("$ROOT/tools/ci/fwdref.sh" CFG="$1" DEFS=+define+TG_TIMING_CUTS=0) ;;
  esac
  if "${cmd[@]}" > "$log" 2>&1; then
    echo "PASS $*"
  else
    echo "FAIL $* (log: $log)"
  fi
}
export -f lint_one
export ROOT LOGS
# The lines go to stdout as they come, and to a file for the summary. (tee /dev/stderr would reopen
# a log that stderr is redirected to, truncating it and writing over the other stream.)
results=$(mktemp "$LOGS/.results.XXXXXX")
trap 'rm -f "$results"' EXIT
vpid=""
if [ "$VIVADO" = 1 ]; then
  "$ROOT/tools/ci/vivado_rtl_lint.sh" > "$LOGS/vivado-rtl-lint.log" 2>&1 &
  vpid=$!
fi
printf '%s\n' "${tasks[@]}" | xargs -P "$JOBS" -I{} bash -c 'lint_one "$1"' _ {} | tee "$results"
vfail=0
if [ -n "$vpid" ]; then
  wait "$vpid" || vfail=1
  grep '^vivado-rtl-lint: \|^    ' "$LOGS/vivado-rtl-lint.log"
fi
fails=$(grep '^FAIL' "$results")
if [ -n "$fails" ]; then
  sed 's/.*(log: \(.*\))$/\1/' <<< "$fails" | while read -r log; do
    echo "---- $log"; { grep -E '^%(Error|Warning)|IMPLICIT NET' "$log" || tail -5 "$log"; } | head -20
  done
fi
vsum=""
if [ -n "$vpid" ]; then
  if [ $vfail = 1 ]; then vsum=", Vivado's reading FAILED"
  elif grep -q '^vivado-rtl-lint: SKIP' "$LOGS/vivado-rtl-lint.log"; then vsum=", Vivado's reading skipped (no Vivado)"
  else vsum=", Vivado's reading clean"; fi
fi
if [ -n "$fails" ] || [ $vfail = 1 ]; then
  echo "lint-all FAIL: $(grep -c . <<< "$fails") of ${#tasks[@]} elaborations$vsum ($((SECONDS - t0)) s)"
  exit 1
fi
echo "lint-all OK: ${#tasks[@]} elaborations$vsum ($((SECONDS - t0)) s)"
