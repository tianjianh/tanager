#!/bin/bash
# Runs Vivado in batch mode under a machine-wide slot lock, so Vivado jobs from all sessions
# queue instead of thrashing the machine (docs/spec/conventions.md §9).
#   tools/vivado_run.sh <run-dir> <script.tcl> [tcl args...]
# TANAGER_VIVADO_SLOTS (default 1) sets how many Vivado jobs may run at once on this machine.
# The log goes to <run-dir>/vivado.log. The exit status is Vivado's.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <run-dir> <script.tcl> [args...]" >&2; exit 2; }
run_dir="$1"; tcl="$(realpath "$2")"; shift 2
slots="${TANAGER_VIVADO_SLOTS:-1}"
lock_dir="${TANAGER_BUILD:-$HOME/tanager-build}/.locks"
settings="${TANAGER_VIVADO_SETTINGS:-$HOME/Xilinx/2025.2/Vivado/settings64.sh}"
mkdir -p "$lock_dir" "$run_dir"

while true; do
  for ((i = 0; i < slots; i++)); do
    exec {fd}>"$lock_dir/vivado.$i.lock"
    if flock -n "$fd"; then
      echo "[vivado_run] slot $i: $tcl in $run_dir ($(date '+%F %T'))"
      set +e
      ( source "$settings" >/dev/null && cd "$run_dir" && \
        vivado -mode batch -nojournal -log vivado.log -source "$tcl" -tclargs "$@" ) </dev/null
      rc=$?
      set -e
      exec {fd}>&-
      echo "[vivado_run] done rc=$rc ($(date '+%F %T'))"
      exit $rc
    fi
    exec {fd}>&-
  done
  sleep 15
done
