#!/bin/bash
# Runs one out-of-context spike through tools/vivado_run.sh and keeps its small reports in
# fpga/spikes/results/<name>/; the Vivado run directory is deleted afterwards (disk rule,
# conventions §9) unless KEEP=1.
#   fpga/spikes/scripts/run_ooc.sh <name> <cfg> <top> [ooc_run.tcl options...]
# The clock period is PERIOD (default 5.0 ns).
set -uo pipefail
[ $# -ge 3 ] || { echo "usage: $0 <name> <cfg> <top> [options]" >&2; exit 2; }
name="$1"; cfg="$2"; top="$3"; shift 3
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$root/tools/env.sh"
build="$TANAGER_BUILD/$(basename "$root")/ooc/$name"
res="$root/fpga/spikes/results/$name"
rm -rf "$build"; mkdir -p "$build" "$res"
bash "$root/tools/vivado_run.sh" "$build" "$root/fpga/spikes/tcl/ooc_run.tcl" \
  "$root" "$cfg" "$top" "${PERIOD:-5.0}" "$@" > "$build/run.out" 2>&1
rc=$?
for f in summary.txt paths.txt prim_synth.txt prim_opt.txt util_hier.rpt timing_worst.rpt levels.rpt; do
  [ -f "$build/$f" ] && cp "$build/$f" "$res/"
done
grep -E '^(ERROR|CRITICAL WARNING)' "$build/vivado.log" 2>/dev/null | head -20 > "$res/errors.txt"
[ -s "$res/errors.txt" ] || rm -f "$res/errors.txt"
echo "$name rc=$rc $(grep -E '^(wns_ns|impl_lut_total|worst_levels)' "$res/summary.txt" 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')"
[ "${KEEP:-0}" = 1 ] || rm -rf "$build"
exit $rc
