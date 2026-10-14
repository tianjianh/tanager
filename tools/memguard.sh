#!/bin/bash
# Memory guard for the build host (docs/spec/conventions.md §9). The kernel's OOM killer acts only after
# minutes of thrashing, while SSH and every agent session stall. This guard acts first: when MemAvailable
# falls under the floor, it stops one expendable job, logs it, and checks again.
#   tools/memguard.sh start    start in the background unless running; add an @reboot crontab entry
#   tools/memguard.sh stop | status | run (foreground) | dry (print the job it would stop now)
#   tools/memguard.sh once     one check now (also works piped: ssh host 'bash -s -- once' < memguard.sh)
# Expendable jobs: Vivado, compilers and linkers, Verilator models (V*), Spike, tgsim, QEMU, and any process
# whose oom_score_adj is raised (tools/vivado_run.sh, the soak). Among those holding at least 1 GB, the guard
# stops the one with the highest oom_score_adj (the soak, then Vivado, then builds) and, within that, the
# newest: it broke the budget, and stopping it loses the least work. Failing that, it stops the expendable
# job with the highest oom_score. Agent sessions, sshd, the tunnel and shells are never touched.
# Environment:
#   TANAGER_MEMGUARD_FLOOR_MB  act below this much MemAvailable (default 3072)
# The log is $TANAGER_BUILD/memguard.log.
set -u
build="${TANAGER_BUILD:-$HOME/tanager-build}"
floor_mb="${TANAGER_MEMGUARD_FLOOR_MB:-3072}"
log="$build/memguard.log"
lock="$build/.locks/memguard.lock"
pidfile="$build/.locks/memguard.pid"
self="$(realpath "${BASH_SOURCE[0]:-$0}")"
mkdir -p "$build/.locks"

note() { echo "$(date '+%F %T') $*" >> "$log"; }

# Sets AVAIL to MemAvailable in MB without forking, so the guard keeps working under memory pressure.
read_avail() {
  local k v u
  AVAIL=0
  while read -r k v u; do
    if [ "$k" = MemAvailable: ]; then AVAIL=$((v / 1024)); return; fi
  done < /proc/meminfo
}

expendable() {   # <comm> <oom_score_adj>
  [ "$2" -ge 500 ] && return 0
  case "$1" in
    vivado|cc1|cc1plus|lto1|ld|ld.bfd|ld.gold|spike|tgsim|qemu-system-*|verilator_bin*|V[a-z_]*) return 0 ;;
  esac
  return 1
}

victim() {
  local p pid comm adj st s badj=-1001 young=-1 ypid="" best=-1 bpid=""
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ "$pid" != "$$" ] && [ -O "$p" ] || continue
    { read -r comm < "$p/comm" && read -r adj < "$p/oom_score_adj" && read -r st < "$p/stat" &&
      read -r s < "$p/oom_score"; } 2>/dev/null || continue
    expendable "$comm" "$adj" || continue
    st=${st##*) }
    set -- $st
    # Fields after the command name: ${20} is the start time (ticks since boot), ${22} the RSS in pages.
    if [ $(( ${22} * 4 )) -ge 1048576 ]; then
      if [ "$adj" -gt "$badj" ] || { [ "$adj" -eq "$badj" ] && [ "${20}" -gt "$young" ]; }; then
        badj=$adj; young=${20}; ypid=$pid
      fi
    fi
    if [ "$s" -gt "$best" ]; then best=$s; bpid=$pid; fi
  done
  echo "${ypid:-$bpid}"
}

running() { ! flock -n "$lock" true 2>/dev/null; }

# One check: under the floor, stop one job. Returns 0 if it stopped one, 1 if memory is fine, 2 if no job
# is expendable.
guard_pass() {
  local pid info
  read_avail
  [ "$AVAIL" -lt "$floor_mb" ] || return 1
  pid=$(victim)
  if [ -z "$pid" ]; then note "MemAvailable ${AVAIL} MB < ${floor_mb} MB: no expendable job to stop"; return 2; fi
  info="$(ps -o pid=,rss=,etime=,args= -p "$pid" 2>/dev/null | cut -c1-160) cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)"
  note "MemAvailable ${AVAIL} MB < ${floor_mb} MB: SIGTERM ${info}"
  kill -TERM "$pid" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1; [ -d "/proc/$pid" ] || break; done
  read_avail
  if [ -d "/proc/$pid" ] && [ "$AVAIL" -lt "$floor_mb" ]; then note "SIGKILL $pid"; kill -KILL "$pid" 2>/dev/null; fi
  return 0
}

run() {
  exec {g}>"$lock"
  flock -n "$g" || { echo "memguard: already running" >&2; exit 0; }
  echo "$$" > "$pidfile"
  note "started: floor ${floor_mb} MB, pid $$"
  while true; do
    guard_pass
    case $? in 0) sleep 4 ;; 2) sleep 30 ;; esac
    sleep 1
  done
}

start() {
  if running; then
    echo "memguard already running (pid $(cat "$pidfile" 2>/dev/null))"
  else
    setsid nohup "$self" run </dev/null >>"$log" 2>&1 &
    sleep 1
    echo "memguard started (pid $(cat "$pidfile" 2>/dev/null))"
  fi
  { crontab -l 2>/dev/null | grep -v 'memguard\.sh'; echo "@reboot $self start >/dev/null 2>&1"; } | crontab -
}

stop() {
  local pid
  pid=$(cat "$pidfile" 2>/dev/null)
  if running && [ -n "$pid" ] && grep -q memguard "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" && echo "memguard stopped (pid $pid)"
  else
    echo "memguard not running"
  fi
}

status() {
  if running; then echo "memguard running (pid $(cat "$pidfile" 2>/dev/null))"; else echo "memguard not running"; fi
  tail -n 5 "$log" 2>/dev/null
}

case "${1:-}" in
  run) run ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  dry) pid=$(victim); if [ -n "$pid" ]; then ps -o pid=,rss=,etime=,args= -p "$pid" | cut -c1-160; else echo "no expendable job"; fi ;;
  once) guard_pass; echo "MemAvailable ${AVAIL} MB (floor ${floor_mb} MB)"; tail -n 2 "$log" 2>/dev/null ;;
  *) echo "usage: $0 start|stop|status|dry|once|run" >&2; exit 2 ;;
esac
