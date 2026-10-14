#!/bin/bash
# Runs Vivado in batch mode under machine-wide slot and memory admission, so Vivado jobs from all
# sessions queue instead of exhausting the machine (docs/spec/conventions.md §9).
#   tools/vivado_run.sh <run-dir> <script.tcl> [tcl args...]
#   tools/vivado_run.sh --status      running jobs and the queue
# Environment:
#   TANAGER_VIVADO_SLOTS       concurrent Vivado jobs (default 1; tools/env.sh sets the host's value)
#   TANAGER_VIVADO_MEM_GB      memory this job may use, children included (default 10 = full device;
#                              out-of-context unit runs should declare 4)
#   TANAGER_VIVADO_MEM_BUDGET  total GB all running Vivado jobs may declare (default 24)
#   TANAGER_TRACK              owner for fair queueing (default: the track-* name in this script's path
#                              or the run directory, else "other")
# Admission is a fair queue. Each job takes a ticket. The next job admitted is the waiting one whose owner
# holds the fewest slots, oldest ticket first. It starts when a slot is free and the declared memory of
# the running jobs plus its own fits the budget. While it waits, the head of the queue holds the
# admission lock, so a later launch (including an older copy of this script) cannot take a freed slot
# first. Declarations, not free memory, are used, because Vivado's memory grows over minutes.
# Vivado runs with a raised oom_score_adj, so under memory pressure the kernel kills a Vivado job,
# not sshd, the tunnel or the agent sessions.
# The log goes to <run-dir>/vivado.log. The exit status is Vivado's.
set -euo pipefail
lock_dir="${TANAGER_BUILD:-$HOME/tanager-build}/.locks"
qdir="$lock_dir/queue"
mkdir -p "$lock_dir" "$qdir"

# Running jobs, one line each: "<slot> <declared GB> <owner>", over every held slot lock, not only this
# host's slot count. A held slot with no declaration (a job started by an older vivado_run.sh) counts as
# a full-device run, 10 GB.
running() {
  local f i
  for f in "$lock_dir"/vivado.[0-9]*.lock; do
    [ -e "$f" ] || continue
    flock -n "$f" true 2>/dev/null && continue
    i=${f%.lock}; i=${i##*.}
    echo "$i $(cat "$lock_dir/vivado.$i.mem" 2>/dev/null || echo 10) $(cat "$lock_dir/vivado.$i.owner" 2>/dev/null || echo unknown)"
  done
  return 0
}

# The waiting job that goes next: its owner holds the fewest slots, then it has the oldest ticket.
# Entries of jobs that have exited are dropped.
head_ticket() {
  local f pid own run
  run=$(running)
  for f in "$qdir"/[0-9]*; do
    [ -e "$f" ] || continue
    read -r pid own < "$f" 2>/dev/null || continue
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$f"; continue; fi
    echo "$(printf '%s\n' "$run" | awk -v o="$own" '$3 == o' | grep -c . || true) ${f##*/}"
  done | sort -k1,1n -k2,2 | head -n 1 | awk '{print $2}'
}

if [ "${1:-}" = "--status" ]; then
  echo "running (slot, declared GB, owner):"; running | sed 's/^/  /'
  echo "queued (ticket: pid owner), next first:"
  for f in "$qdir"/[0-9]*; do if [ -e "$f" ]; then echo "  ${f##*/}: $(cat "$f")"; fi; done
  echo "next: $(head_ticket)"
  exit 0
fi

[ $# -ge 2 ] || { echo "usage: $0 <run-dir> <script.tcl> [args...] | --status" >&2; exit 2; }
run_dir="$1"; tcl="$(realpath "$2")"; shift 2
slots="${TANAGER_VIVADO_SLOTS:-1}"
need="${TANAGER_VIVADO_MEM_GB:-10}"
budget="${TANAGER_VIVADO_MEM_BUDGET:-24}"
settings="${TANAGER_VIVADO_SETTINGS:-$HOME/Xilinx/2025.2/Vivado/settings64.sh}"
owner="${TANAGER_TRACK:-$(printf '%s %s' "$(realpath "$0")" "$(realpath -m "$run_dir")" | grep -o 'track-[a-z0-9]*' | head -n 1 || true)}"
owner="${owner:-other}"
mkdir -p "$run_dir"
[ "$need" -le "$budget" ] || { echo "[vivado_run] job declares ${need} GB > budget ${budget} GB" >&2; exit 2; }

# Take a ticket. The counter has its own lock, so a job can join the queue while the head holds the
# admission lock.
exec {tk}>"$lock_dir/vivado.ticket.lock"
flock "$tk"
ticket=$(( $(cat "$lock_dir/vivado.ticket" 2>/dev/null || echo 0) + 1 ))
echo "$ticket" > "$lock_dir/vivado.ticket"
qfile="$qdir/$(printf '%09d' "$ticket")"
echo "$$ $owner" > "$qfile"
exec {tk}>&-
trap 'rm -f "$qfile"' EXIT
exec {adm}>"$lock_dir/vivado.admit.lock"

said=0
while true; do
  flock "$adm"
  if [ "$(head_ticket)" = "${qfile##*/}" ]; then
    # Next in line: keep the admission lock until a slot is free and the memory fits.
    while true; do
      used=$(running | awk '{s += $2} END {print s + 0}')
      if [ $(( used + need )) -le "$budget" ]; then
        for ((i = 0; i < slots; i++)); do
          exec {fd}>"$lock_dir/vivado.$i.lock"
          if flock -n "$fd"; then
            echo "$need" > "$lock_dir/vivado.$i.mem"
            echo "$owner" > "$lock_dir/vivado.$i.owner"
            rm -f "$qfile"
            flock -u "$adm"; exec {adm}>&-
            echo "[vivado_run] slot $i ($owner, ${need} GB declared): $tcl in $run_dir ($(date '+%F %T'))"
            set +e
            ( echo 800 > /proc/self/oom_score_adj 2>/dev/null || true
              source "$settings" >/dev/null && cd "$run_dir" && \
              vivado -mode batch -nojournal -log vivado.log -source "$tcl" -tclargs "$@" ) </dev/null
            rc=$?
            set -e
            rm -f "$lock_dir/vivado.$i.mem" "$lock_dir/vivado.$i.owner"
            exec {fd}>&-
            echo "[vivado_run] done rc=$rc ($(date '+%F %T'))"
            exit $rc
          fi
          exec {fd}>&-
        done
      fi
      [ $said -lt 2 ] && echo "[vivado_run] next in line ($owner, ${need} GB): waiting for a slot or memory (declared ${used} + ${need} GB of ${budget}, ${slots} slots)"
      said=2
      sleep 2
    done
  fi
  flock -u "$adm"
  [ $said -eq 0 ] && echo "[vivado_run] queued ($owner, ticket $ticket, ${need} GB); tools/vivado_run.sh --status shows the queue"
  said=1
  sleep 3
done
