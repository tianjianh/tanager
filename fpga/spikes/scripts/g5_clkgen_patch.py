#!/usr/bin/env python3
"""Measurement-only patch for spike G5 (DR-145): lets a snapshot's tg_clkgen make 125 MHz.

tg_clkgen runs its MMCM's VCO at 1200 MHz, so the core clock must divide 1200 (100, 120, 150,
200 ...). 125 MHz does not. The patch picks a 1000 MHz VCO when the clock does not divide 1200
but divides 1000 (125 MHz: divide by 8; the 100 MHz host clock: divide by 10). A real 125 MHz
board build needs the same change in the SoC track's tg_clkgen.
  g5_clkgen_patch.py <snapshot>/fpga/kv260/rtl/tg_clkgen.sv
"""
import sys

p = sys.argv[1]
s = open(p).read()
rep = [
    ("  localparam real CORE_DIV = 1200.0 / CORE_MHZ;\n\n  if ((1200 % CORE_MHZ) != 0) begin : g_bad_mhz\n    $error(\"tg_clkgen: CORE_MHZ must divide 1200\");\n  end",
     "  // measurement patch (spike G5): a 1000 MHz VCO for clocks that do not divide 1200 (125 MHz)\n"
     "  localparam int  VCO      = ((1200 % CORE_MHZ) == 0) ? 1200 : 1000;\n"
     "  localparam real CORE_DIV = VCO * 1.0 / CORE_MHZ;\n\n"
     "  if ((VCO % CORE_MHZ) != 0) begin : g_bad_mhz\n    $error(\"tg_clkgen: CORE_MHZ must divide 1200 or 1000\");\n  end"),
    ("    .CLKFBOUT_MULT_F  (12.0),", "    .CLKFBOUT_MULT_F  (VCO / 100.0),"),
    ("    .CLKOUT1_DIVIDE   (12),", "    .CLKOUT1_DIVIDE   (VCO / 100),"),
]
for a, b in rep:
    assert a in s, "tg_clkgen changed: " + a[:40]
    s = s.replace(a, b, 1)
open(p, "w").write(s)
print("patched", p)
