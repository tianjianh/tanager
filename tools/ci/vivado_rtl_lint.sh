#!/bin/bash
# Vivado's own reading of the RTL as a lint (beside lint-all's elaborations; DR-150;
# docs/spec/verification.md §4.3): its simulator's parser (xvlog) and its RTL elaboration of the board
# top and the core. Verilator, and so every simulation and Verilator lint here, resolves a name used
# before its declaration to the later declaration. In a port connection inside a generate block Vivado
# makes it a new implicit net instead, undriven, and says so only in an INFO (Synth 8-11241). That was
# the board's two-core hang of 2026-10-16: rn_fire in tg_rename, every free list's pop undriven,
# invisible to the soak. This fails on the parser's errors and on those messages for our own files
# (rtl/, fpga/kv260/).
# It runs through the Vivado admission (tools/vivado_run.sh): one ticket for every configuration, about
# 6 GB declared and 8 minutes once admitted.
#   tools/ci/vivado_rtl_lint.sh [TREE=<repo root>] [SPECS="kv260_top:st:1 kv260_top:smt2:2 tg_core:st tg_core:smt2"]
#                               [MEM=GB] [CHECK=<run dir>: only read that earlier run's logs again]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TREE="$ROOT" SPECS="kv260_top:st:1 kv260_top:smt2:2 tg_core:st tg_core:smt2" MEM=6 CHECK=
for kv in "$@"; do
  case "$kv" in
    TREE=*|SPECS=*|MEM=*|CHECK=*) declare "${kv%%=*}=${kv#*=}" ;;
    *) echo "usage: $0 [TREE=<repo root>] [SPECS=\"<top>:<cfg>[:<cores>] ...\"] [MEM=GB] [CHECK=<run dir>]"; exit 2 ;;
  esac
done
# The physical path, as Vivado's messages name the files (Tcl's file normalize)
TREE="$(cd "$TREE" && pwd -P)"
RUN="${CHECK:-${TANAGER_BUILD:-$HOME/tanager-build}/$(basename "$ROOT")/vivado-rtl-lint}"
# The messages of this class in Vivado 2025.2's elaboration, as the board builds of 2026-10-16 showed
# them: 8-11241 (an INFO) "undeclared symbol, assumed default net type 'wire'": a new implicit net, as
# rn_fire became in each generate block; 8-605 "same-named implicit nets"; 8-8895 "already implicitly
# declared" (a name connected before its declaration, then declared); 8-6901 "used before its
# declaration" (bound to the later declaration, as Verilator does, so correct, but the same mistake);
# 8-3848 "does not have driver"
GATE='Synth 8-11241|Synth 8-605|Synth 8-8895|Synth 8-6901|Synth 8-3848'

if [ -z "$CHECK" ]; then
  source "$ROOT/tools/env.sh" > /dev/null 2>&1
  if [ -z "${TANAGER_VIVADO_SETTINGS:-}" ] || [ ! -f "${TANAGER_VIVADO_SETTINGS}" ]; then
    echo "vivado-rtl-lint: SKIP (no Vivado on this host)"; exit 0
  fi
  rm -rf "$RUN"
  mkdir -p "$RUN"
  TANAGER_VIVADO_MEM_GB=$MEM bash "$ROOT/tools/vivado_run.sh" "$RUN" "$ROOT/tools/ci/vivado_rtl_lint.tcl" "$TREE" $SPECS \
    > "$RUN/launcher.log" 2>&1
fi
log="$RUN/vivado.log"
fail=0
for cfg in $(for spec in $SPECS; do cut -d: -f2 <<< "$spec"; done | sort -u); do
  xl="$RUN/xvlog_$cfg/xvlog.log"
  st=$(sed -n "s/^TG_RTL_LINT xvlog $cfg //p" "$log" 2>/dev/null | tail -1)
  if [ -z "$st" ] || [ ! -f "$xl" ]; then echo "vivado-rtl-lint: FAIL xvlog $cfg: no parse (see $log)"; fail=1; continue; fi
  if [ "$st" = clean ]; then echo "vivado-rtl-lint: PASS xvlog $cfg"; continue; fi
  # Every file's first error, in file order (the "module ... ignored" lines that follow them left out)
  errs=$(grep -E '^ERROR: ' "$xl" | grep -v 'VRFC 10-8530' | awk '!seen[$0]++')
  echo "vivado-rtl-lint: FAIL xvlog $cfg: $(grep -c . <<< "$errs") error(s) (a name used before its declaration, a repeated block name, a net declared twice)"
  sed "s#$TREE/##; s/^/    /" <<< "${errs:-(see $xl)}" | head -20
  fail=1
done
for spec in $SPECS; do
  IFS=: read -r top cfg cores <<< "$spec"; cores=${cores:-1}
  part=$(sed -n "/^TG_RTL_LINT begin $top $cfg $cores\$/,/^TG_RTL_LINT end $top $cfg $cores\$/p" "$log")
  if [ -z "$part" ] || ! grep -q "^TG_RTL_LINT end $top $cfg $cores\$" <<< "$part"; then
    echo "vivado-rtl-lint: FAIL $spec: no elaboration (see $log)"; fail=1; continue
  fi
  if grep -q "^TG_RTL_LINT error" <<< "$part" || grep -qE '^ERROR: ' <<< "$part"; then
    echo "vivado-rtl-lint: FAIL $spec: elaboration error"; grep -E '^ERROR: |^TG_RTL_LINT error' <<< "$part" | head -5 | sed 's/^/    /'
    fail=1; continue
  fi
  # Our own files only: Xilinx's PS IP has seven undriven pins in every build (bd_*, outside the tree)
  hits=$(grep -E "^(INFO|WARNING|CRITICAL WARNING): \[($GATE)\].*\[$TREE/(rtl|fpga/kv260)/" <<< "$part" | sort -u)
  if [ -n "$hits" ]; then
    echo "vivado-rtl-lint: FAIL $spec: $(wc -l <<< "$hits") message(s) of the implicit- and undriven-net class in our RTL"
    sed "s#$TREE/##; s/^/    /" <<< "$hits" | head -30
    fail=1
  else
    echo "vivado-rtl-lint: PASS $spec"
  fi
done
[ $fail = 0 ] && echo "vivado-rtl-lint: PASS ($SPECS)" || echo "vivado-rtl-lint: FAIL (log: $log)"
exit $fail
