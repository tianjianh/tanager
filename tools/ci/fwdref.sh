#!/bin/bash
# Forward references in the RTL, from Verilator's JSON dump of the synthesis view (tools/ci/fwdref.py;
# lint-all runs it for every configuration; DR-150, docs/spec/verification.md §4.3). Verilator links a
# name used before its declaration to the later declaration, so no simulation shows it, but Vivado makes
# a whole name in a port connection a new implicit net, undriven: the board's two-core hang (rn_fire).
# This finds that in about 5 s without Vivado; tools/ci/vivado_rtl_lint.sh asks Vivado itself. From the
# core track's fwdref (2026-10-17).
#   tools/ci/fwdref.sh [TREE=<repo root>] [CFG=smt2] [TOP=tanager_soc] [DEFS="+define+..."]
# Exit 1 on an implicit net in Vivado (the other forward references are listed), 2 if Verilator fails.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TREE="$ROOT" CFG=smt2 TOP=tanager_soc DEFS=
for kv in "$@"; do
  case "$kv" in
    TREE=*|CFG=*|TOP=*|DEFS=*) declare "${kv%%=*}=${kv#*=}" ;;
    *) echo "usage: $0 [TREE=<repo root>] [CFG=<cfg>] [TOP=<module>] [DEFS=\"+define+...\"]"; exit 2 ;;
  esac
done
source "$ROOT/tools/env.sh" > /dev/null 2>&1
out=$(mktemp -d "${TMPDIR:-/tmp}/fwdref.XXXXXX")
trap 'rm -rf "$out"' EXIT
cd "$TREE" || exit 2
# As Vivado reads it: SYNTHESIS defined, with the synthesis view's stand-ins and models for the Xilinx
# primitives (Makefile SYNTH_FLAGS), taken from this checkout
M="$ROOT/tests/unit/prim/models"
if ! verilator --json-only --json-only-output "$out/t.json" --json-only-meta-output "$out/m.json" \
     -Wno-fatal -Wno-lint -Wno-style --timing -Irtl/common "rtl/common/cfg/tg_cfg_$CFG.sv" -F rtl/rtl.f \
     +define+SYNTHESIS $DEFS "$ROOT/tools/ci/synth_lint/xilinx_stubs.sv" "$M/RAM32M16.sv" "$M/RAM64M8.sv" \
     "$M/RAM64X8SW.sv" "$M/SRL16E.sv" "$M/SRLC32E.sv" --top-module "$TOP" > "$out/verilator.log" 2>&1; then
  cat "$out/verilator.log"
  exit 2
fi
python3 -I "$ROOT/tools/ci/fwdref.py" "$out/t.json" "$out/m.json" rtl/
