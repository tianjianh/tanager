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
  - **For 200 MHz:** the R-channel register slice in the L2 (d42dcd8) and `L2_DATA_LAT = 4` above
    150 MHz (dab6021) are in; the L2's remaining long path is the S2 decision (out-of-context section).

## L2 bank, out of context

`fpga/kv260/tcl/ooc_synth.tcl` synthesises `tg_l2_bank` alone (`-mode out_of_context`,
`-flatten_hierarchy none`, 200 MHz clock constraint, `st`), on RTL snapshots so that later edits do
not change what a run measures. With `TG_OOC_CONES=1` it also writes `reports/ooc_cones.txt`: the
LUTs in the input cone of each register group, which attributes logic that synthesis flattens into
one module. WNS is synthesis-estimated (unplaced wires).

**Lever R15, step by step** (24 MSHRs, 2 agents; each step passed the L2 short and long suites):

| Step | Commit | LUT (LUTRAM) | FF | WNS @ 200 MHz |
|---|---|---|---|---|
| first version | d42dcd8 | 9,923 (408) | 4,500 | -1.61 |
| MSHR payload in LUTRAM; ProbeAck lookup by set and way | 5c59424 | 7,711 (612) | 4,486 | -1.59 |
| round robin without rotation; D queue of rows in LUTRAM | f929a89 | 6,072 (780) | 3,262 | -0.70 |
| next state selected by the current state; victim tag only; D data after the arbiter | d2be865 | 5,640 (780) | 2,966 | -0.68 |
| directory written per way (byte enables); fill counters in LUTRAM | 2bd6f7c | 5,081 (788) | 2,626 | -1.37 |
| directory write enables from `p2_v_q` only | d480394 | 5,074 (788) | 2,626 | -0.93 |

The step-5 slack loss was the block RAM enable (the OR of the byte enables) waiting for the S2
decision; step 6 moved the decision onto the data inputs only. Block RAM: 5 RAMB36 + 1 RAMB18
before step 5, 6 + 1 after (the byte-aligned directory row). 16 URAM throughout.

**Final RTL by MSHRs and agents** (d480394):

| N_MSHR | N_AGENTS | LUT | FF | WNS @ 200 MHz |
|---|---|---|---|---|
| 24 | 1 | 4,906 | 2,576 | -0.68 |
| 24 | 2 | 5,074 | 2,626 | -0.93 |
| 24 | 4 | 5,185 | 2,726 | -1.34 |
| 16 | 1 | 3,914 | 2,056 | -0.64 |
| 16 | 2 | 4,140 | 2,090 | -1.00 |
| 8 | 1 | 2,992 | 1,536 | -0.60 |
| 8 | 2 | 3,131 | 1,554 | -0.69 |

Each MSHR costs about 120 LUTs and 65 FFs. Agents cost little: 4,906 / 5,074 / 5,185 LUTs at
1 / 2 / 4 agents with 24 MSHRs. The LUTRAM (788) does not change below 32 MSHRs. The bank without
MSHRs is about 2K LUTs.

