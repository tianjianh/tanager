#!/bin/bash
# Synthesis test of the primitive check (tools/tcl/tg_prim_check.tcl), needs a Vivado slot:
#   tests/unit/prim/synth/run.sh            (after `source tools/env.sh`)
# Synthesises tg_prim_synth_top through fpga/budget/tcl/unit_synth.tcl and checks the report
# after opt_design:
#   u_a  PRIM_OK, RAM32M16 1 (2 without trimming), 14 of 20 read bits loaded
#   u_b  PRIM_OK, RAM64M8 4 (6 without trimming), 24 of 36 bits loaded
#   u_c  PRIM_OK, RAMB36_equiv 6.5 (bytes of 8)
#   u_d  PRIM_OK, RAMB36_equiv 0.5 (rom)
#   u_e  PRIM_OK, distributed
#   one PRIM_STRAY (f_mem), no PRIM_FAIL, no PRIM_WARN
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
RD="${TANAGER_BUILD:-$HOME/tanager-build}/$(basename "$ROOT")/prim_synth"
rm -rf "$RD"
bash "$ROOT/tools/vivado_run.sh" "$RD" "$ROOT/fpga/budget/tcl/unit_synth.tcl" "$ROOT" st \
  tg_prim_synth_top -file tests/unit/prim/synth/tg_prim_synth_top.sv > /dev/null 2>&1
r="$RD/prim_opt.txt"
[ -f "$r" ] || { echo "FAIL prim synth: no report ($RD/vivado.log)"; exit 1; }
bad=0
check() { grep -E "$1" "$r" > /dev/null || { echo "  missing: $2"; bad=1; }; }
check '^PRIM_OK \S*u_a .*14 of 20 read bits loaded.* expected \{RAM32M16 1\}' "u_a trimmed to 1 RAM32M16"
check '^PRIM_OK \S*u_b .*24 of 36 read bits loaded.* expected \{RAM64M8 4\}' "u_b trimmed to 4 RAM64M8"
check '^PRIM_OK \S*u_c .*bytes of 8.*RAMB36_equiv 6.5' "u_c byte-write 6.5"
check '^PRIM_OK \S*u_d .*rom.*RAMB36_equiv 0.5' "u_d block ROM 0.5"
check '^PRIM_OK \S*u_e .*rom.*distributed' "u_e distributed ROM"
[ "$(grep -c '^PRIM_STRAY' "$r")" -ge 1 ] || { echo "  missing: the stray memory"; bad=1; }
if grep -E '^PRIM_(FAIL|WARN)' "$r"; then bad=1; fi
if [ $bad = 0 ]; then echo "PASS prim synth"; else echo "FAIL prim synth ($r)"; exit 1; fi
rm -rf "$RD/.Xil"
