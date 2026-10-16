#!/bin/bash
# make lint-all (docs/spec/verification.md §4.3): every configuration in DR-140's four elaborations,
# so that every switch's branches compile: the fallback (TIMING_CUTS=0), the default, and #2 and #8 each
# on top of the default (ROB_STORE_REPORT_LATE=1, DE_STAGE=1; both lint only). They run JOBS at a time
# (Verilator's lint is one thread and about 0.6 GB).
# An elaboration whose define no RTL file mentions is the default's, so it is skipped.
#   tools/ci/lint_all.sh [JOBS=6] [CFGS="st smt2 st_w3 smt2_w3"]
set -u
JOBS=6 CFGS="st smt2 st_w3 smt2_w3"
for kv in "$@"; do
  case "$kv" in
    JOBS=*|CFGS=*) declare "${kv%%=*}=${kv#*=}" ;;
    *) echo "usage: $0 [JOBS=N] [CFGS=\"st ...\"]"; exit 2 ;;
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
tasks=()
for c in $CFGS; do
  for p in "${profiles[@]}"; do tasks+=("$c${p:+ $p}"); done
done

# One line per elaboration as it finishes: PASS|FAIL <cfg> [<define>]
lint_one() {
  set -- $1
  local log="$LOGS/$1${2:+-${2/=/}}.log"
  if make --no-print-directory -C "$ROOT" lint CFG="$1" ${2:+"$2"} > "$log" 2>&1; then
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
printf '%s\n' "${tasks[@]}" | xargs -P "$JOBS" -I{} bash -c 'lint_one "$1"' _ {} | tee "$results"
fails=$(grep '^FAIL' "$results")
if [ -n "$fails" ]; then
  sed 's/.*(log: \(.*\))$/\1/' <<< "$fails" | while read -r log; do
    echo "---- $log"; { grep -E '^%(Error|Warning)' "$log" || tail -5 "$log"; } | head -20
  done
  echo "lint-all FAIL: $(grep -c . <<< "$fails") of ${#tasks[@]} elaborations ($((SECONDS - t0)) s)"
  exit 1
fi
echo "lint-all OK: ${#tasks[@]} elaborations ($((SECONDS - t0)) s)"
