# KV260 build results (SoC track)

Builds of `kv260_top` with `fpga/kv260/tcl/build.tcl` (Vivado 2025.2, xck26-sfvc784-2LV-c,
non-project, `-flatten_hierarchy rebuilt`, default directives). Reports stay in the run
directories under `$SOC_BUILD/vivado/`; no checkpoints are kept.

| Date | cfg | cores (kind) | clk_core | WNS / WHS (ns) | LUT | FF | URAM | RAMB36 / RAMB18 | Run time |
|---|---|---|---|---|---|---|---|---|---|
| 2026-10-13 | st | 2 (`tg_core` stubs) | 100 MHz | +2.463 / +0.004 | 6,641 (5.7%) | 4,399 | 32 | 14 / 2 | 6 min |
| 2026-10-13 | st | 2 (`tg_trafgen`) | 100 MHz | +0.928 / +0.011 | 28,706 (24.5%) | 15,101 | 32 | 14 / 6 | 15 min |

Notes:
- **Stub build:** the stub cores drive nothing, so synthesis removes the parts of the uncore that
  only requests would exercise. It checks the PS block design, the clocking, the CDC and the
  memory mapping (32 URAM for the 1 MiB L2), not the uncore's real timing. The traffic-generator
  build is the uncore timing number.
- **Traffic-generator build, by block** (LUTs; the generators are not product logic):
  - L2: 18,415 (bank 0: 9,484, of which 4,360 MSHR and engine logic, 3,010 attributed to the directory RAM
    wrapper, i.e. the S2 decision and row rewrite, and 1,477 to the data-array wrapper, i.e. write-data muxing);
  - interconnect: 1,296; host bridge: 1,222 (+3,023 FFs of crossing registers);
  - latency injectors: 999 + 797; generators: 2 x ~2,750.

  The uncore is about 24K LUTs against the plan's 13.3K. The reduction plan is in
  docs/spec/l2.md (Timing and area).
- **Worst paths:**
  - **Stub build:** L2 MSHR state -> `RREADY` -> injector buffer read enable (6.6 ns, 86% routing).
  - **Traffic-generator build:** 9.1 ns of 10.
  - **For 200 MHz:** a register slice on the R channel between injector and L2, and a deeper URAM read
    latency (requested from the spikes track: a `tg_ram_sdp` read-latency parameter).
