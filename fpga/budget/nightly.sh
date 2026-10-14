#!/bin/bash
# Nightly per-unit budget run on main (plan §8.5; fpga/budget/README.md):
#   fpga/budget/nightly.sh [--force] [run_budget.py options]
# Exports main's latest commit (git archive: no checkout is touched), synthesises every unit
# of fpga/budget/units.tsv there out of context, and reports the budgets and the deltas
# against the previous run in $TANAGER_BUILD/budget/latest.md.
# - Does nothing when main has not moved since the last run (--force runs anyway).
# - Skips the run while the host drive has under 20 GB free (exit 3).
# - Vivado jobs queue for a slot through tools/vivado_run.sh like any other.
# Exit status: run_budget.py's (0 within budget, 1 over budget or primitive failures,
# 2 a synthesis did not finish), or 3 when skipped for disk space.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GIT=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir) || exit 2
OUT="${TANAGER_BUILD:-$HOME/tanager-build}/budget"
mkdir -p "$OUT"
force=0
if [ "${1:-}" = --force ]; then force=1; shift; fi

commit=$(git --git-dir="$GIT" rev-parse --short main) || exit 2
if [ $force = 0 ] && [ "$(cat "$OUT/last_commit" 2>/dev/null)" = "$commit" ]; then
  echo "$(date '+%F %T') budget: main is still $commit, nothing to do"
  exit 0
fi
free=$(df -BG --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$free" ] && [ "$free" -lt 20 ]; then
  echo "$(date '+%F %T') budget: host drive C: has $free GB free, under 20: skipped"
  exit 3
fi

src="$OUT/src"
rm -rf "$src"
mkdir -p "$src"
git --git-dir="$GIT" archive "$commit" | tar -x -C "$src" || exit 2
if [ ! -f "$src/fpga/budget/run_budget.py" ]; then
  echo "$(date '+%F %T') budget: main $commit does not have fpga/budget yet, nothing to do"
  rm -rf "$src"
  exit 0
fi
echo "$(date '+%F %T') budget: main $commit"
cd "$src" || exit 2
# shellcheck disable=SC1091
source tools/env.sh >/dev/null
python3 -I fpga/budget/run_budget.py --root "$src" --out "$OUT" --commit "$commit" "$@"
rc=$?
cd / && rm -rf "$src"
if [ $rc -ne 2 ]; then echo "$commit" > "$OUT/last_commit"; fi
echo "$(date '+%F %T') budget: done, exit $rc"
exit $rc
