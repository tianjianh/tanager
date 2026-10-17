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
         util.rpt timing_summary.rpt timing.rpt levels.rpt clock_utilization.rpt constraints.txt \
         floorplan.txt util_pblocks.rpt regions.txt synth_check.txt; do
  [ -f "$build/$f" ] && cp "$build/$f" "$res/"
done
# the checkpoints (-dcp 1), for queries and later floorplans (outside git)
for d in post_synth routed; do
  [ -f "$build/$d.dcp" ] && cp "$build/$d.dcp" "$TANAGER_BUILD/$(basename "$root")/fp/${name}_$d.dcp"
done
grep -E '^(ERROR|CRITICAL WARNING)' "$build/vivado.log" 2>/dev/null | head -20 > "$res/errors.txt"
[ -s "$res/errors.txt" ] || rm -f "$res/errors.txt"
# The synthesis check's backstop (fpga/spikes/tcl/synth_check.tcl): an implicit or undriven net in our
# sources (Synth 8-11241, 8-605, 8-3848 about any file outside the run directory and the Xilinx installation) fails
# the run even if the check inside the run could not read the log.
imp=$(grep -E '\[Synth 8-(11241|605|3848)\]' "$build/vivado.log" 2>/dev/null | grep -vF "[$(realpath -m "$build")/" | grep -v '/Xilinx/' | sort -u)
if [ -n "$imp" ]; then
  { echo "implicit or undriven nets in our sources (Synth 8-11241, 8-605, 8-3848): declare each signal before its first use, and drive it"; echo "$imp"; } > "$res/synth_check_failed.txt"
  [ $rc -ne 0 ] || rc=1
fi
echo "$name rc=$rc $(grep -E '^(wns_ns|impl_lut_total|uncore_dsp48) ' "$res/summary.txt" 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')"
# a failed run keeps its directory (vivado.log) for the diagnosis
[ "${KEEP:-0}" = 1 ] || [ $rc -ne 0 ] || rm -rf "$build"
exit $rc
