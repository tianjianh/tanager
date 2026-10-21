#!/bin/bash
# Synthesis check of tg_ram_tdp's CASCADE_HEIGHT (spikes §7.1), needs a Vivado slot (declares 4 GB):
#   tests/unit/prim/synth/casc.sh            (after `source tools/env.sh`)
# Synthesizes, places and routes tg_prim_casc_top through casc.tcl in a fresh run folder, and checks casc.txt:
#   u_c0 (CASCADE_HEIGHT 0, the default): 2 RAMB36E2 in a depth cascade (FIRST and LAST, 36-bit ports)
#   u_c1 (CASCADE_HEIGHT 1): 2 RAMB36E2 side by side (NONE, 18-bit ports)
#   each port of u_c1 reads at least 0.3 ns faster, from the slowest bit's RAM delay (measured 0.40 on 2025.2:
#   CLK -> CASDOUT plus CASDIN -> DOUT, 1.79-1.81 ns, against a 2K x 18 port's CLK -> DOUT, 1.39-1.40)
#   both instances PRIM_OK in the primitive check (RAMB36_equiv 2)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
RD="${TANAGER_BUILD:-$HOME/tanager-build}/$(basename "$ROOT")/prim_casc_$(date +%m%d_%H%M%S)"
TANAGER_VIVADO_MEM_GB="${TANAGER_VIVADO_MEM_GB:-4}" bash "$ROOT/tools/vivado_run.sh" "$RD" \
  "$ROOT/tests/unit/prim/synth/casc.tcl" "$ROOT" > /dev/null 2>&1
r="$RD/casc.txt"
[ -f "$r" ] || { echo "FAIL prim casc: no report ($RD/vivado.log)"; exit 1; }
sed 's/^/  /' "$r"
if grep -q '^CASC_PASS' "$r"; then echo "PASS prim casc ($RD)"; else echo "FAIL prim casc ($r)"; exit 1; fi
