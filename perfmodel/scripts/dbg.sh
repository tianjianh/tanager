#!/bin/bash
# Debug helper: run one workload functionally and show its output.  dbg.sh <isa> <name> [tgsim args]
R="$(cd "$(dirname "$0")/.." && pwd)"
isa="$1"; name="$2"; shift 2
elf="$R/build/bench/$isa/$name.elf"
stdin=""
[ "$name" = dhrystone ] && stdin=$'20000\n'
"$R/build/tgsim" --iss-only --stdin "$stdin" "$@" "$elf"
