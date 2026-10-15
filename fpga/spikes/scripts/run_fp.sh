#!/bin/bash
# Runs one floorplan experiment (fpga/spikes/tcl/fp_core.tcl: re-place and re-route a core
# checkpoint under a floorplan) through tools/vivado_run.sh and keeps its small reports in
# fpga/spikes/results/<name>/; the Vivado run directory is deleted afterwards (disk rule,
# conventions §9) unless KEEP=1 or the run failed.
#   fpga/spikes/scripts/run_fp.sh <name> <checkpoint.dcp> <floorplan.tcl | none> [fp_core.tcl options...]
set -uo pipefail
[ $# -ge 3 ] || { echo "usage: $0 <name> <checkpoint.dcp> <floorplan.tcl | none> [options]" >&2; exit 2; }
name="$1"; dcp="$2"; fp="$3"; shift 3
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$root/tools/env.sh"
build="$TANAGER_BUILD/$(basename "$root")/ooc/$name"
res="$root/fpga/spikes/results/$name"
rm -rf "$build"; mkdir -p "$build" "$res"
bash "$root/tools/vivado_run.sh" "$build" "$root/fpga/spikes/tcl/fp_core.tcl" \
  "$root" "$dcp" "$fp" "$@" > "$build/run.out" 2>&1
rc=$?
for f in summary.txt floorplan.txt regions.txt util.rpt util_hier.rpt util_pblocks.rpt timing_worst.rpt \
         levels.rpt paths.tsv fam_*.rpt; do
  for g in $build/$f; do [ -f "$g" ] && cp "$g" "$res/"; done
done
# the routed design, for queries (outside git: about 30 MB)
[ -f "$build/routed.dcp" ] && cp "$build/routed.dcp" "$TANAGER_BUILD/$(basename "$root")/fp/${name}_routed.dcp"
grep -E '^(ERROR|CRITICAL WARNING)' "$build/vivado.log" 2>/dev/null | head -20 > "$res/errors.txt"
[ -s "$res/errors.txt" ] || rm -f "$res/errors.txt"
echo "$name rc=$rc $(grep -E '^(wns_ns|wire_share_2000|failing_endpoints) ' "$res/summary.txt" 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')"
# a failed run keeps its directory (vivado.log) for the diagnosis
[ "${KEEP:-0}" = 1 ] || [ $rc -ne 0 ] || rm -rf "$build"
exit $rc
