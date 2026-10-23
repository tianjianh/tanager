#!/bin/bash
# Runs Vivado in batch mode under machine-wide slot and memory admission, so Vivado jobs from all
# sessions queue instead of exhausting the machine (docs/spec/conventions.md §9).
#   tools/vivado_run.sh <run-dir> <script.tcl> [tcl args...]
#   tools/vivado_run.sh --status      running jobs and the queue
# Environment:
#   TANAGER_VIVADO_SLOTS       concurrent Vivado jobs (default 1; tools/env.sh sets the host's value;
#                              .locks/vivado.slots, if present, overrides it live)
#   TANAGER_VIVADO_MEM_GB      memory this job may use, children included (default 10 = full device;
#                              out-of-context unit runs should declare 4)
#   TANAGER_VIVADO_MEM_BUDGET  total GB all running Vivado jobs may declare (default 24;
#                              .locks/vivado.budget, if present, overrides it live)
#   TANAGER_TRACK              owner for fair queueing (default: the track-* name in this script's path
#                              or the run directory, else "other")
#   TANAGER_VIVADO_CPUS        the CPUs Vivado runs on, a taskset list, or "all" (default: the P-cores on a
#                              hybrid host, /sys/devices/cpu_core/cpus; elsewhere all; .locks/vivado.cpus, if
#                              present, overrides it live, host-wide)
#   TANAGER_VIVADO_SMALL_GB    the small-job lane: a job declaring at most this many GB (default 8; 0 closes the
#                              lane; .locks/vivado.small, if present, overrides it live) may start outside the
#                              budget (below)
#   TANAGER_VIVADO_MEMINFO     where MemAvailable is read (default /proc/meminfo; tools/ci/vivado_run_test.sh)
# Admission is a fair queue. Each job takes a ticket. The next job admitted is the waiting one whose owner
# holds the fewest slots, oldest ticket first. It starts when a slot is free and the declared memory of
# the running jobs plus its own fits the budget. While it waits, the head of the queue holds the
# admission lock, so a later launch (including an older copy of this script) cannot take a freed slot
# first. Declarations, not free memory, are used, because Vivado's memory grows over minutes.
# The small-job lane: a job declaring at most TANAGER_VIVADO_SMALL_GB (8) also starts when the budget is full, if
# the host's MemAvailable is at least twice its declaration plus 8 GB. It still waits its turn in the queue and
# takes a slot, and its declaration counts against the budget for the jobs after it. Two full-chip builds (26 GB
# each) at a budget of 56 left 4 GB, and every lint, MR check and path query (6 GB) then waited 20-35 minutes
# with 32-40 GB of the host's memory free (the coordinator, 10-22).
# Vivado runs with a raised oom_score_adj, so under memory pressure the kernel kills a Vivado job,
# not sshd, the tunnel or the agent sessions. On a hybrid host (Intel P- and E-cores) it runs on the P-cores
# alone, where its one-thread phases run several times faster; elsewhere nothing changes.
# The log goes to <run-dir>/vivado.log. The exit status is Vivado's.
set -euo pipefail
lock_dir="${TANAGER_BUILD:-$HOME/tanager-build}/.locks"

# The CPUs this job's Vivado runs on (taskset's list; empty: all): .locks/vivado.cpus, else TANAGER_VIVADO_CPUS,
# else a hybrid host's P-cores; "all" pins nothing
vivado_cpus() {
  local c
  c=$(cat "$lock_dir/vivado.cpus" 2>/dev/null || echo "${TANAGER_VIVADO_CPUS:-}")
  if [ -z "$c" ] && [ -r /sys/devices/cpu_core/cpus ]; then c=$(cat /sys/devices/cpu_core/cpus); fi
  [ "$c" = all ] && c=
  echo "$c"
}
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
    echo "$i $(cat "$lock_dir/vivado.$i.mem" 2>/dev/null || echo 10) $(cat "$lock_dir/vivado.$i.owner" 2>/dev/null || echo unknown)$([ -e "$lock_dir/vivado.$i.lane" ] && echo " lane")"
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

meminfo="${TANAGER_VIVADO_MEMINFO:-/proc/meminfo}"
avail_gb() { awk '/^MemAvailable:/ {print int($2 / 1048576)}' "$meminfo" 2>/dev/null || echo 0; }
small_gb() { cat "$lock_dir/vivado.small" 2>/dev/null || echo "${TANAGER_VIVADO_SMALL_GB:-8}"; }

if [ "${1:-}" = "--status" ]; then
  echo "running (slot, declared GB, owner, \"lane\" if admitted outside the budget):"; running | sed 's/^/  /'
  echo "small-job lane: jobs of at most $(small_gb) GB, when MemAvailable ($(avail_gb) GB now) is at least twice theirs plus 8"
  echo "queued (ticket: pid owner), next first:"
  for f in "$qdir"/[0-9]*; do if [ -e "$f" ]; then echo "  ${f##*/}: $(cat "$f")"; fi; done
  echo "next: $(head_ticket)"
  exit 0
fi

[ $# -ge 2 ] || { echo "usage: $0 <run-dir> <script.tcl> [args...] | --status" >&2; exit 2; }
run_dir="$1"; tcl="$(realpath "$2")"; shift 2
slots_env="${TANAGER_VIVADO_SLOTS:-1}"
need="${TANAGER_VIVADO_MEM_GB:-10}"
budget_env="${TANAGER_VIVADO_MEM_BUDGET:-24}"
slots=$(cat "$lock_dir/vivado.slots" 2>/dev/null || echo "$slots_env")
budget=$(cat "$lock_dir/vivado.budget" 2>/dev/null || echo "$budget_env")
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
    # Next in line: keep the admission lock until a slot is free and the memory fits. The coordinator can
    # change the host's capacity live through .locks/vivado.slots and .locks/vivado.budget.
    while true; do
      slots=$(cat "$lock_dir/vivado.slots" 2>/dev/null || echo "$slots_env")
      budget=$(cat "$lock_dir/vivado.budget" 2>/dev/null || echo "$budget_env")
      used=$(running | awk '{s += $2} END {print s + 0}')
      # Within the budget, or a small job through the lane while the host has the memory
      lane=""
      if [ $(( used + need )) -gt "$budget" ] && [ "$need" -le "$(small_gb)" ]; then
        avail=$(avail_gb)
        [ "${avail:-0}" -ge $(( 2 * need + 8 )) ] && lane=1
      fi
      if [ $(( used + need )) -le "$budget" ] || [ -n "$lane" ]; then
        for ((i = 0; i < slots; i++)); do
          exec {fd}>"$lock_dir/vivado.$i.lock"
          if flock -n "$fd"; then
            echo "$need" > "$lock_dir/vivado.$i.mem"
            echo "$owner" > "$lock_dir/vivado.$i.owner"
            if [ -n "$lane" ]; then echo lane > "$lock_dir/vivado.$i.lane"; else rm -f "$lock_dir/vivado.$i.lane"; fi
            rm -f "$qfile"
            flock -u "$adm"; exec {adm}>&-
            cpus=$(vivado_cpus)
            echo "[vivado_run] slot $i ($owner, ${need} GB declared${lane:+, the small-job lane: ${used} GB declared of ${budget}, MemAvailable ${avail} GB}${cpus:+, CPUs $cpus}): $tcl in $run_dir ($(date '+%F %T'))"
            # Measure the job's peak memory: every 10 s, the summed RSS of all processes working under the
            # run directory (Vivado and its workers). Reported at the end and logged, so declarations can
            # follow measurements.
            peakf="$lock_dir/vivado.$i.peak"; echo 0 > "$peakf"
            rdir=$(realpath "$run_dir")
            # The sampler closes its copy of the slot lock (the job keeps it) and stops its sleep when killed,
            # so nothing holds the slot after the job ends.
            ( exec {fd}>&-
              trap 'kill "$slp" 2>/dev/null; exit 0' TERM
              while :; do
                sleep 10 & slp=$!; wait "$slp"
                s=0
                for p in $(ls -l /proc/[0-9]*/cwd 2>/dev/null | awk -v d="$rdir" '$NF == d || index($NF, d "/") == 1 {split($(NF-2), a, "/"); print a[3]}'); do
                  r=$(awk '/^VmRSS/ {print $2}' "/proc/$p/status" 2>/dev/null || true); s=$((s + ${r:-0}))
                done
                if [ "$s" -gt "$(cat "$peakf" 2>/dev/null || echo 0)" ]; then echo "$s" > "$peakf"; fi
              done ) </dev/null >/dev/null 2>&1 &
            sampler=$!
            set +e
            ( echo 800 > /proc/self/oom_score_adj 2>/dev/null || true
              source "$settings" >/dev/null && cd "$run_dir" && \
              ${cpus:+taskset -c "$cpus"} vivado -mode batch -nojournal -log vivado.log -source "$tcl" -tclargs "$@" ) </dev/null
            rc=$?
            kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
            set -e
            peak=$(awk '{printf "%.1f", $1 / 1048576}' "$peakf" 2>/dev/null || echo "?")
            rm -f "$lock_dir/vivado.$i.mem" "$lock_dir/vivado.$i.owner" "$lock_dir/vivado.$i.lane" "$peakf"
            exec {fd}>&-
            echo "$(date '+%F %T') $owner declared ${need} GB peak ${peak} GB rc=$rc $run_dir" >> "$lock_dir/vivado_peaks.log"
            echo "[vivado_run] done rc=$rc, peak ${peak} GB of ${need} GB declared ($(date '+%F %T'))"
            exit $rc
          fi
          exec {fd}>&-
        done
      fi
      [ $said -lt 2 ] && echo "[vivado_run] next in line ($owner, ${need} GB): waiting for a slot or memory (declared ${used} + ${need} GB of ${budget}, ${slots} slots$([ "$need" -le "$(small_gb)" ] && echo "; the small-job lane wants MemAvailable $(( 2 * need + 8 )) GB, the host has $(avail_gb)"))"
      said=2
      sleep 2
    done
  fi
  flock -u "$adm"
  [ $said -eq 0 ] && echo "[vivado_run] queued ($owner, ticket $ticket, ${need} GB); tools/vivado_run.sh --status shows the queue"
  said=1
  sleep 3
done
