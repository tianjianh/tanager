# KV260 build results (SoC track)

Builds of `kv260_top` with `fpga/kv260/tcl/build.tcl` (Vivado 2025.2, xck26-sfvc784-2LV-c,
non-project, `-flatten_hierarchy rebuilt`, default directives). Reports stay in the run
directories under `$SOC_BUILD/vivado/`; no checkpoints are kept.

| Date | cfg | cores (kind) | clk_core | WNS / WHS (ns) | LUT | FF | URAM | RAMB36 / RAMB18 | Run time |
|---|---|---|---|---|---|---|---|---|---|
| 2026-10-13 | st | 2 (`tg_core` stubs) | 100 MHz | +2.463 / +0.004 | 6,641 (5.7%) | 4,399 | 32 | 14 / 2 | 6 min |

Notes:
- **Stub build:** the stub cores drive nothing, so synthesis removes the parts of the uncore that
  only requests would exercise. It checks the PS block design, the clocking, the CDC and the
  memory mapping (32 URAM for the 1 MiB L2), not the uncore's real timing. The traffic-generator
  build is the uncore timing number.
