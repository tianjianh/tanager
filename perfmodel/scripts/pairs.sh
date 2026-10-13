#!/bin/bash
# pairs.sh <isa> <workload> [N]: opcode mix and dependent adjacent pairs inside the timed region.
R="$(cd "$(dirname "$0")/.." && pwd)"
TGSIM_PAIRS="${3:-25}" bash "$R/scripts/dbg.sh" "$1" "$2" 2>&1 | sed -n '/^opcode mix/,$p'
