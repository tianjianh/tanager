#!/bin/bash
# Runs spike G4 (fpga/spikes/tcl/g4_fit.tcl: the v1 full chip in kv260_top, with the uncore's
# register slices in DSPs per UNCORE_DSP) through tools/vivado_run.sh and keeps its small reports
# in fpga/spikes/results/<name>/; the Vivado run directory is deleted afterwards (disk rule,
# conventions §9) unless KEEP=1 or the run failed.
#   fpga/spikes/scripts/run_g4.sh <name> <cfg> <core_mhz> <uncore_dsp> [g4_fit.tcl options...]
set -uo pipefail
[ $# -ge 4 ] || { echo "usage: $0 <name> <cfg> <core_mhz> <uncore_dsp> [options]" >&2; exit 2; }
name="$1"; cfg="$2"; mhz="$3"; mask="$4"; shift 4
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$root/tools/env.sh"
build="$TANAGER_BUILD/$(basename "$root")/ooc/$name"
res="$root/fpga/spikes/results/$name"
rm -rf "$build"; mkdir -p "$build" "$res"
bash "$root/tools/vivado_run.sh" "$build" "$root/fpga/spikes/tcl/g4_fit.tcl" \
  "$root" "$cfg" "$mhz" "$mask" "$@" > "$build/run.out" 2>&1
rc=$?
for f in summary.txt sites.txt sites_paths.rpt uncore_paths.rpt xbar_core.txt xbar_core_paths.rpt \
         uncore_failing.txt uncore_internal.rpt prim_synth.txt prim_opt.txt util_hier.rpt \
         util.rpt timing_summary.rpt timing.rpt levels.rpt clock_utilization.rpt constraints.txt; do
  [ -f "$build/$f" ] && cp "$build/$f" "$res/"
done
grep -E '^(ERROR|CRITICAL WARNING)' "$build/vivado.log" 2>/dev/null | head -20 > "$res/errors.txt"
[ -s "$res/errors.txt" ] || rm -f "$res/errors.txt"
echo "$name rc=$rc $(grep -E '^(wns_ns|impl_lut_total|uncore_dsp48) ' "$res/summary.txt" 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')"
# a failed run keeps its directory (vivado.log) for the diagnosis
[ "${KEEP:-0}" = 1 ] || [ $rc -ne 0 ] || rm -rf "$build"
exit $rc
