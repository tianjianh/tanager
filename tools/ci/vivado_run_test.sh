#!/bin/bash
# A dry run of tools/vivado_run.sh's admission (docs/spec/conventions.md §9): fake lock directory, fake declarations
# held by sleeping processes, a fake MemAvailable and a fake vivado, so no Vivado runs and the host's real queue is
# never touched. Each case prints PASS or FAIL; the exit status is 1 on any failure.
#   [VIVADO_RUN=<a vivado_run.sh>] tools/ci/vivado_run_test.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="${VIVADO_RUN:-$ROOT/tools/vivado_run.sh}"   # VIVADO_RUN: another copy, e.g. an older one
T=$(mktemp -d "${TMPDIR:-/tmp}/vivado_run_test.XXXXXX")
L="$T/.locks"; mkdir -p "$L" "$T/bin"
cat > "$T/bin/vivado" <<'EOF'
#!/bin/bash
echo "fake vivado $*" > vivado.log
EOF
chmod +x "$T/bin/vivado"
echo "export PATH=$T/bin:\$PATH" > "$T/settings.sh"
export TANAGER_BUILD="$T" TANAGER_VIVADO_SETTINGS="$T/settings.sh" TANAGER_VIVADO_CPUS=all TANAGER_TRACK=test
export TANAGER_VIVADO_MEMINFO="$T/meminfo"
echo 8 > "$L/vivado.slots"; echo 56 > "$L/vivado.budget"
holders=()
hold() {   # hold <slot> <GB> <owner>: a running job's slot lock and declaration
  echo "$2" > "$L/vivado.$1.mem"; echo "$3" > "$L/vivado.$1.owner"
  ( exec 9>"$L/vivado.$1.lock"; flock 9; exec sleep 600 ) & holders+=($!)   # the sleep itself holds the lock
  for _ in $(seq 50); do flock -n "$L/vivado.$1.lock" true 2>/dev/null || return 0; sleep 0.1; done
}
release_all() {
  [ ${#holders[@]} -gt 0 ] && kill "${holders[@]}" 2>/dev/null; wait 2>/dev/null; holders=()
  rm -f "$L"/vivado.[0-9]*.mem "$L"/vivado.[0-9]*.owner "$L"/vivado.[0-9]*.lane
}
avail() { echo "MemAvailable:   $(( $1 * 1048576 )) kB" > "$T/meminfo"; }
fails=0 last_out=""
# case <name> <expect: run|wait> <GB> [grep for the start line]: a job of GB declared, given 6 s
case_() {
  local name=$1 expect=$2 gb=$3 want=${4:-} out rc
  mkdir -p "$T/run/$name"
  out=$(TANAGER_VIVADO_MEM_GB=$gb timeout 6 bash "$RUN" "$T/run/$name" /dev/null 2>&1); rc=$?; last_out=$out
  if { [ "$expect" = run ] && [ $rc = 0 ] && grep -q "fake vivado" "$T/run/$name/vivado.log" 2>/dev/null &&
       { [ -z "$want" ] || grep -q -- "$want" <<< "$out"; }; } ||
     { [ "$expect" = wait ] && [ $rc = 124 ] && grep -q "waiting for a slot or memory" <<< "$out"; }; then
    echo "PASS $name"
  else
    echo "FAIL $name (expected $expect, rc $rc): $(tr '\n' ' ' <<< "$out" | cut -c1-300)"; fails=$((fails + 1))
  fi
}

# Two full-chip builds hold 52 GB of the budget of 56
hold 0 26 bigA; hold 1 26 bigB
avail 40; case_ small-lane-admitted run 6 "the small-job lane"
avail 19; case_ small-lane-refused-low-memory wait 6
avail 20; case_ small-lane-at-the-limit run 6 "the small-job lane"
avail 40; case_ big-keeps-the-budget wait 10
avail 40; case_ nine-gb-is-not-small wait 9
echo 0 > "$L/vivado.small"
avail 40; case_ lane-closed wait 6
rm -f "$L/vivado.small"
echo 2 > "$L/vivado.slots"
avail 40; case_ lane-still-needs-a-slot wait 6
echo 8 > "$L/vivado.slots"
release_all
# Within the budget, a small job starts as before, not through the lane
avail 4; case_ small-within-budget run 6 "slot 0 (test, 6 GB declared)"
if grep -q "the small-job lane" <<< "$last_out"; then
  echo "FAIL small-within-budget used the lane"; fails=$((fails + 1)); fi
# A lane job's declaration counts for the next: 52 held plus a 6 GB lane job leaves no room for a 4 GB job either,
# unless the lane takes it too
hold 0 26 bigA; hold 1 26 bigB; hold 2 6 small
echo lane > "$L/vivado.2.lane"
avail 40; out=$(bash "$RUN" --status 2>&1)
if grep -q "2 6 small lane" <<< "$out" && grep -q "MemAvailable (40 GB now)" <<< "$out"; then echo "PASS status-shows-the-lane"
else echo "FAIL status-shows-the-lane: $(tr '\n' ' ' <<< "$out" | cut -c1-300)"; fails=$((fails + 1)); fi
avail 15; case_ lane-job-counts-for-the-next wait 4
avail 16; case_ lane-takes-the-next-small-one run 4 "the small-job lane: 58 GB declared of 56"
release_all
rm -rf "$T"
[ $fails = 0 ] && echo "vivado_run_test: PASS" || { echo "vivado_run_test: $fails FAIL"; exit 1; }
