#!/bin/bash
# Runs one program in tg_vsim, building it first if needed (docs/spec/verification.md §1).
#   sim/run.sh [CFG=st] [CORE=core|tcore] [tg_vsim options] program.elf
# Options and +plusargs go to tg_vsim (tg_vsim --help lists them).
set -e
CFG=st CORE=core
args=()
for a in "$@"; do
  case "$a" in
    CFG=*) CFG="${a#CFG=}" ;;
    CORE=*) CORE="${a#CORE=}" ;;
    *) args+=("$a") ;;
  esac
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
make --no-print-directory -s -C "$ROOT/sim" CFG="$CFG" CORE="$CORE" build >&2
exec "${TANAGER_BUILD:-$HOME/tanager-build}/$(basename "$ROOT")/sim/$CFG-$CORE/tg_vsim" "${args[@]}"
