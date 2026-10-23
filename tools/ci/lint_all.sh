#!/bin/bash
# make lint-all (docs/spec/verification.md §4.3): every configuration in six elaborations, so that
# every switch's branches compile: the fallback (TIMING_CUTS=0), the default, and #2, #8 and the commit
# trace off each on top of the default (ROB_STORE_REPORT_LATE=1, DE_STAGE=1, COMMIT_TRACE=0; lint only;
# DR-140, DR-146); the 4-miss L1D (DC_MSHRS=4, DR-149), G8's queue decode bits (QUEUE_DECODE=1) and M6's
# speculative load wakeup (SPEC_WAKE=1) each on top of the default; its filter off and with D$ misses left out
# (SPEC_WAKE_FILT=0 and 2), DR-169's two levers off (STA_BASE=0, STEER_LA=0), DR-171's store prefetch off (STORE_PF=0) and its prefetches in flight
# the package does not default to (STORE_PF_MAX=2 or 3), and DR-174's UltraRAM register file on (URF=1, in both
# views: URF=1 and URF=1
# SYNTH=1), each on top of the default; the PMP entries the
# package does not default to (PMP_ENTRIES=8 or 16, DR-167); and the default's
# synthesis view (SYNTH=1: +define+SYNTHESIS, where a signal that
# synthesized logic reads but only simulation-only code drives is an error). With hart 1, smt2 also elaborates the
# product's combination (URF=1 and the release form, in both views) and a bigger chip's, every area measure that has a
# switch off together (PMP_ENTRIES=16, four TAGE tables of 4K, the uncore's slices, a window of ROB 96, LQ 32, SQ 24:
# WIN=, a copy of the configuration's file; both views; docs/spec/area_switches.md). They run JOBS at a time
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
if mentioned TG_SPEC_WAKE_FILT; then profiles+=("SPEC_WAKE_FILT=0" "SPEC_WAKE_FILT=2"); else echo "lint-all: no RTL mentions TG_SPEC_WAKE_FILT; skipping SPEC_WAKE_FILT=0 and 2"; fi
if mentioned TG_STA_BASE; then profiles+=("STA_BASE=0"); else echo "lint-all: no RTL mentions TG_STA_BASE; skipping STA_BASE=0"; fi
if mentioned TG_STEER_LA; then profiles+=("STEER_LA=0"); else echo "lint-all: no RTL mentions TG_STEER_LA; skipping STEER_LA=0"; fi
if mentioned TG_PMP_ENTRIES; then  # the count other than the package's default (its line, as sim/profile.mk reads it)
  pmp_def=$(sed -n -E 's/^[[:space:]]*localparam[[:space:]]+int[[:space:]]+PMP_ENTRIES[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*;.*/\1/p' \
            "$ROOT/rtl/core/tg_core_pkg.sv")
  profiles+=("PMP_ENTRIES=$([ "$pmp_def" = 16 ] && echo 8 || echo 16)")
else echo "lint-all: no RTL mentions TG_PMP_ENTRIES; skipping PMP_ENTRIES"; fi
if mentioned TG_STORE_PF; then profiles+=("STORE_PF=0"); else echo "lint-all: no RTL mentions TG_STORE_PF; skipping STORE_PF=0"; fi
if mentioned TG_URF; then profiles+=("URF=1" "URF=1 SYNTH=1"); else echo "lint-all: no RTL mentions TG_URF; skipping URF=1"; fi
if mentioned TG_STORE_PF_MAX; then  # the count other than the package's default
  spm_def=$(sed -n -E 's/^[[:space:]]*localparam[[:space:]]+int[[:space:]]+STORE_PF_MAX[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*;.*/\1/p' \
            "$ROOT/rtl/core/tg_core_pkg.sv")
  profiles+=("STORE_PF_MAX=$([ "$spm_def" = 3 ] && echo 2 || echo 3)")
else echo "lint-all: no RTL mentions TG_STORE_PF_MAX; skipping STORE_PF_MAX"; fi
# DR-185's rename payload written straight into its LUTRAM (PAY_WREG=0; the package registers the write)
if mentioned TG_PAY_WREG; then profiles+=("PAY_WREG=0"); else echo "lint-all: no RTL mentions TG_PAY_WREG; skipping PAY_WREG=0"; fi
profiles+=("SYNTH=1")
# DR-177's release builds, without the two latency injectors (tanager_soc LAT_INJ, a parameter), in both views
if grep -qsw LAT_INJ "$ROOT/rtl/soc/tanager_soc.sv"; then profiles+=("LAT_INJ=0" "LAT_INJ=0 SYNTH=1")
else echo "lint-all: tanager_soc has no LAT_INJ; skipping LAT_INJ=0"; fi
# DR-180's release builds (tanager_soc RELEASE, a parameter, with the host DMA port), as the board's product: no
# injectors and no trace either, in both views
if grep -qsw RELEASE "$ROOT/rtl/soc/tanager_soc.sv"; then
  profiles+=("RELEASE=1 LAT_INJ=0 COMMIT_TRACE=0" "RELEASE=1 LAT_INJ=0 COMMIT_TRACE=0 SYNTH=1")
else echo "lint-all: tanager_soc has no RELEASE; skipping RELEASE=1"; fi
# M7's test mode (SOLO_TID=1, DR-175) exists only in the SMT2 configurations (TID_W = 1)
solo=""; if mentioned TG_SOLO_TID; then solo=1; else echo "lint-all: no RTL mentions TG_SOLO_TID; skipping SOLO_TID=1"; fi
# ... and its split mode (SPLIT=1), alone and with SOLO_TID=1
split=""; if mentioned TG_SPLIT; then split=1; else echo "lint-all: no RTL mentions TG_SPLIT; skipping SPLIT=1"; fi
# ... and hart 1 (HART1=1, step 5)
hart1=""; if mentioned TG_HART1; then hart1=1; else echo "lint-all: no RTL mentions TG_HART1; skipping HART1=1"; fi
# With hart 1 (the four-hart chip), the area switches together (docs/spec/area_switches.md): the product's (URF=1 and
# the release form) and a bigger chip's, every area measure with a switch off (PMP_ENTRIES=16, TAGE's four tables of
# 2^12, the uncore's register slices, a larger window), each in both views
area=()
if [ -n "$hart1" ]; then
  if mentioned TG_URF && grep -qsw RELEASE "$ROOT/rtl/soc/tanager_soc.sv"; then
    area+=("HART1=1 URF=1 RELEASE=1 LAT_INJ=0 COMMIT_TRACE=0" "HART1=1 URF=1 RELEASE=1 LAT_INJ=0 COMMIT_TRACE=0 SYNTH=1")
  else echo "lint-all: no TG_URF or tanager_soc RELEASE; skipping the product's combination"; fi
  if mentioned TG_PMP_ENTRIES && mentioned TG_TAGE_NT && grep -qsw MEM_SLICE "$ROOT/rtl/soc/tanager_soc.sv"; then
    big="HART1=1 PMP_ENTRIES=16 TAGE_NT=4 TAGE_LI=12 XBAR_SLICE=1 MEM_SLICE=1 WIN=96,32,24"
    area+=("$big" "$big SYNTH=1")
  else echo "lint-all: no TG_PMP_ENTRIES, TG_TAGE_NT or tanager_soc MEM_SLICE; skipping the bigger chip's combination"; fi
  # DR-185's direct payload write with hart 1 (its rows are per thread), as synthesis reads it
  if mentioned TG_PAY_WREG; then area+=("HART1=1 PAY_WREG=0 SYNTH=1"); fi
fi
tasks=()
for c in $CFGS; do
  for p in "${profiles[@]}"; do tasks+=("$c${p:+ $p}"); done
  tasks+=("$c FWDREF=1" "$c FWDREF=0")
  case "$c" in smt2*) [ -n "$solo" ] && tasks+=("$c SOLO_TID=1")
                     [ -n "$split" ] && tasks+=("$c SPLIT=1") && { [ -z "$solo" ] || tasks+=("$c SPLIT=1 SOLO_TID=1"); }
                     [ -n "$hart1" ] && tasks+=("$c HART1=1") && { [ -z "$solo" ] || tasks+=("$c HART1=1 SOLO_TID=1"); } ;; esac
  [ "$c" = smt2 ] && for p in "${area[@]}"; do tasks+=("$c $p"); done
done

# One line per elaboration as it finishes: PASS|FAIL <cfg> [<define>]
lint_one() {
  set -- $1
  local log="$LOGS/$1" p
  for p in "${@:2}"; do log+="-${p/=/}"; done   # a profile may set several variables (URF=1 SYNTH=1)
  log+=".log"
  local args=() p
  for p in "${@:2}"; do
    case "$p" in
      WIN=*)   # WIN=ROB,LQ,SQ: the configuration's file with those window sizes, in the log directory
        local rob lq sq cfg
        IFS=, read -r rob lq sq <<< "${p#WIN=}"
        cfg="$LOGS/tg_cfg_$1_win$rob-$lq-$sq.sv"
        sed -E -e "s/(localparam int ROB_ENTRIES *= *)[0-9]+;/\1$rob;/" -e "s/(localparam int LQ_ENTRIES *= *)[0-9]+;/\1$lq;/" \
          -e "s/(localparam int SQ_ENTRIES *= *)[0-9]+;/\1$sq;/" "$ROOT/rtl/common/cfg/tg_cfg_$1.sv" > "$cfg"
        grep -q "ROB_ENTRIES *= *$rob;" "$cfg" && grep -q "LQ_ENTRIES *= *$lq;" "$cfg" && grep -q "SQ_ENTRIES *= *$sq;" "$cfg" ||
          { echo "FAIL $* (tg_cfg_$1.sv has no ROB_ENTRIES, LQ_ENTRIES and SQ_ENTRIES lines to set)"; return; }
        args+=("RTL_CFG=$cfg") ;;
      *) args+=("$p") ;;
    esac
  done
  local cmd=(make --no-print-directory -C "$ROOT" lint CFG="$1" "${args[@]}")
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
