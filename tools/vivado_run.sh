#!/bin/bash
# Runs Vivado in batch mode under machine-wide slot and memory admission, so Vivado jobs from all
# sessions queue instead of exhausting the machine (docs/spec/conventions.md §9).
#   tools/vivado_run.sh <run-dir> <script.tcl> [tcl args...]
# Environment:
#   TANAGER_VIVADO_SLOTS       concurrent Vivado jobs (default 1; tools/env.sh sets the host's value)
#   TANAGER_VIVADO_MEM_GB      memory this job may use, children included (default 10 = full device;
#                              out-of-context unit runs should declare 4)
#   TANAGER_VIVADO_MEM_BUDGET  total GB all running Vivado jobs may declare (default 24)
# A job starts only when a slot is free AND the declared memory of the running jobs plus its own fits
# the budget. Declarations, not free memory, are used, because Vivado's memory grows over minutes.
# Vivado runs with a raised oom_score_adj, so under memory pressure the kernel kills a Vivado job,
# not sshd, the tunnel or the agent sessions.
# The log goes to <run-dir>/vivado.log. The exit status is Vivado's.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <run-dir> <script.tcl> [args...]" >&2; exit 2; }
run_dir="$1"; tcl="$(realpath "$2")"; shift 2
slots="${TANAGER_VIVADO_SLOTS:-1}"
need="${TANAGER_VIVADO_MEM_GB:-10}"
budget="${TANAGER_VIVADO_MEM_BUDGET:-24}"
lock_dir="${TANAGER_BUILD:-$HOME/tanager-build}/.locks"
settings="${TANAGER_VIVADO_SETTINGS:-$HOME/Xilinx/2025.2/Vivado/settings64.sh}"
mkdir -p "$lock_dir" "$run_dir"
[ "$need" -le "$budget" ] || { echo "[vivado_run] job declares ${need} GB > budget ${budget} GB" >&2; exit 2; }

# Sum of the memory declared by running jobs, over every held slot lock, not only this host's slot count.
# A held slot with no declaration (a job started by an older vivado_run.sh, such as one from a branch that
# has not merged main) counts as a full-device run, 10 GB.
declared() {
  local sum=0 f i
  for f in "$lock_dir"/vivado.[0-9]*.lock; do
    [ -e "$f" ] || continue
    flock -n "$f" true 2>/dev/null && continue
    i=${f%.lock}; i=${i##*.}
    sum=$((sum + $(cat "$lock_dir/vivado.$i.mem" 2>/dev/null || echo 10)))
  done
  echo "$sum"
}

waited=0
while true; do
  # One admission at a time, so two jobs never pass the memory check together.
  exec {adm}>"$lock_dir/vivado.admit.lock"
  flock "$adm"
  if [ $(( $(declared) + need )) -le "$budget" ]; then
    for ((i = 0; i < slots; i++)); do
      exec {fd}>"$lock_dir/vivado.$i.lock"
      if flock -n "$fd"; then
        echo "$need" > "$lock_dir/vivado.$i.mem"
        exec {adm}>&-
        echo "[vivado_run] slot $i (${need} GB declared): $tcl in $run_dir ($(date '+%F %T'))"
        set +e
        ( echo 800 > /proc/self/oom_score_adj 2>/dev/null || true
          source "$settings" >/dev/null && cd "$run_dir" && \
          vivado -mode batch -nojournal -log vivado.log -source "$tcl" -tclargs "$@" ) </dev/null
        rc=$?
        set -e
        rm -f "$lock_dir/vivado.$i.mem"
        exec {fd}>&-
        echo "[vivado_run] done rc=$rc ($(date '+%F %T'))"
        exit $rc
      fi
      exec {fd}>&-
    done
  fi
  exec {adm}>&-
  [ $waited -eq 0 ] && echo "[vivado_run] waiting for a slot or memory (declared $(declared) + ${need} > ${budget} GB, or all ${slots} slots busy)"
  waited=1
  sleep 15
done
