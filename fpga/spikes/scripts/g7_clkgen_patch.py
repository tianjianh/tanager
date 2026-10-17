#!/usr/bin/env python3
"""Measurement-only patch for spike G7 (DR-148): lets a snapshot's tg_clkgen build CORE_MHZ=115.

No MMCM VCO that is a multiple of 100 MHz (which keeps clk_host at exactly 100 MHz) divides to
115 MHz in CLKOUT0's eighths, so tg_clkgen stops with $error. The patch uses the nearest rate at or
above it, VCO 1600 MHz / 13.875 = 115.315 MHz (8.672 ns), as the coordinator chose; the core is then
timed 0.024 ns tighter than at 115.000. Other clocks are unchanged.
  g7_clkgen_patch.py <snapshot>/fpga/kv260/rtl/tg_clkgen.sv
"""
import sys

p = sys.argv[1]
s = open(p).read()
old = ("  localparam int  VCO      = pick_vco(CORE_MHZ);\n"
       "  localparam real CORE_DIV = real'(VCO) / real'(CORE_MHZ);")
new = ("  // measurement patch (spike G7): 115 MHz as 1600 / 13.875 = 115.315 MHz, clk_host at 100 MHz\n"
       "  localparam int  VCO      = (CORE_MHZ == 115) ? 1600 : pick_vco(CORE_MHZ);\n"
       "  localparam real CORE_DIV = (CORE_MHZ == 115) ? 13.875 : real'(VCO) / real'(CORE_MHZ);")
assert old in s, "tg_clkgen's VCO choice changed"
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("patched", p)
