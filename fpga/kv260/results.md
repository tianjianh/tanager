# KV260 build results (SoC track)

Builds of `kv260_top` with `fpga/kv260/tcl/build.tcl` (Vivado 2025.2, xck26-sfvc784-2LV-c,
non-project, `-flatten_hierarchy rebuilt`, default directives). Reports stay in the run
directories under `$SOC_BUILD/vivado/`; no checkpoints are kept.

| Date | cfg | cores (kind) | clk_core | WNS / WHS (ns) | LUT | FF | URAM | RAMB36 / RAMB18 | Run time |
|---|---|---|---|---|---|---|---|---|---|
| 2026-10-13 | st | 2 (`tg_core` stubs) | 100 MHz | +2.463 / +0.004 | 6,641 (5.7%) | 4,399 | 32 | 14 / 2 | 6 min |
| 2026-10-13 | st | 2 (`tg_trafgen`) | 100 MHz | +0.928 / +0.011 | 28,706 (24.5%) | 15,101 | 32 | 14 / 6 | 15 min |
| 2026-10-13 | st | 2 (`tg_trafgen`), L2 after R15 (d480394) | 100 MHz | +1.701 / +0.014 | 20,530 (17.5%) | 13,521 | 32 | 16 / 6 | 29 min |
| 2026-10-13 | st | 2 (`tg_trafgen`), prim-check fixes (a2f3bc8) | 100 MHz | +1.093 / +0.010 | 20,235 (17.3%) | 13,520 | 32 | 16 / 6 | 10 min |
| 2026-10-13 | st | 2 (`tg_trafgen`), UART and L2 tables in `tg_ram_lut` (0aa82f0) | 100 MHz | +1.457 / +0.011 | 20,305 (17.3%) | 13,553 | 32 | 16 / 6 | 8 min |
| 2026-10-14 | st | 2 (`tg_trafgen`), trace streaming on `S_AXI_HP3_FPD` (fca6fe8) | 100 MHz | +1.306 / +0.011 | 21,372 (18.2%) | 13,823 | 32 | 16 / 4 | 10 min |
| 2026-10-14 | st | 2 (`tg_trafgen`), PMOD console on (`TG_PMOD_UART=1`; 3c86877 with the crossbar A-data change) | 100 MHz | +1.069 / +0.012 | 21,600 (18.4%) | 14,075 | 32 | 16 / 4 | 10 min |
| 2026-10-14 | st | 2 (`tg_trafgen`), fan on the PS's TTC0 PWM (DR-129; c8cc8be) | 100 MHz | +1.360 / +0.010 | 21,483 (18.3%) | 13,994 | 32 | 16 / 4 | 15 min |
| 2026-10-14 | st | 2 (`tg_trafgen`), fan on TTC0 and PMOD console on H12/B10 (343c5a4, `TG_PMOD_UART=1`) | 100 MHz | +1.231 / +0.011 | 21,592 (18.4%) | 14,068 | 32 | 16 / 4 | 12 min |
| 2026-10-14 | st | 2 (`tg_trafgen`), stage B: fan on TTC0, PMOD console on H12/B10 from `kv260.xdc` (5048957, `TG_PMOD_UART=1`) | 100 MHz | +1.104 / +0.011 | 21,567 (18.4%) | 14,068 | 32 | 16 / 4 | 14 min |
| 2026-10-14 | st | 1 (`tg_core`), M4: PMOD console, fan on TTC0 (db8aced, `TG_PMOD_UART=1`) | 100 MHz | **−3.761** / +0.011 | 66,066 (56.4%) | 36,991 | 32 | 64 / 5 | 44 min |
| 2026-10-14 | st | 1 (`tg_core`), M4, the same sources | 60 MHz | +1.114 / +0.010 | 65,324 (55.8%) | 36,889 | 32 | 64 / 5 | 33 min |
| 2026-10-14 | st | 1 (`tg_core`), M4 with the L2's one-hot MSHR state and the injector's statistic fix (20435b1) | 60 MHz | +0.153 / +0.010 | 64,921 (55.4%) | 37,321 | 32 | 64 / 5 | 24 min |

Notes:
- **Stub build:** the stub cores drive nothing, so synthesis removes the parts of the uncore that
  only requests would exercise. It checks the PS block design, the clocking, the CDC and the
  memory mapping (32 URAM for the 1 MiB L2), not the uncore's real timing. The traffic-generator
  build is the uncore timing number.
- **First traffic-generator build, by block** (LUTs; the generators are not product logic):
  - L2: 18,415 (bank 0: 9,484, of which 4,360 MSHR and engine logic, 3,010 attributed to the directory RAM
    wrapper, i.e. the S2 decision and row rewrite, and 1,477 to the data-array wrapper, i.e. write-data muxing);
  - interconnect: 1,296; host bridge: 1,222 (+3,023 FFs of crossing registers);
  - latency injectors: 999 + 797; generators: 2 x ~2,750.

  The uncore was about 24K LUTs against the plan's 13.3K; lever R15 (docs/spec/l2.md, Timing and
  area; the out-of-context section below) followed.
- **After R15 (a2f3bc8), by block:** L2 9,994 (two banks of about 5.0K); interconnect 1,332; host
  bridge 1,018 (+3,023 FFs); latency injectors 770 + 717; AXI slices 199 + 197; ACLINT, PLIC, UART and
  boot ROM 116; trace ring 46 (no trace sources in this build). Outside the generators (2,858 +
  2,632) the design is about 14.7K LUTs; with one agent per bank (M4) the L2 is about 0.3K smaller.
  The latency injectors (about 1.5K) are an experiment feature a product build could leave out.
- **Primitive check** (tools/tcl/tg_prim_check.tcl, reports/prim_check_{synth,opt}.txt): the first
  R15 build failed u_mline and u_mreq (opt_design removed RAM32M16s whose read-port slots were
  unused) and listed 78 stray inferred LUTRAMs, all in my blocks. 0aa82f0 has no failures, 4
  warnings (the byte-enabled directory takes 6 RAMB36 + 1 RAMB18 against 6.0 expected; the trace
  ring is trimmed without trace sources) and 32 strays, all inside the shared `tg_fifo` (the
  injectors' output buffers 26, the windows' W-order FIFOs 4, the L2's ReleaseAck queues 2): it infers
  LUTRAM although its header says flip-flop storage.
- **CDC** (0aa82f0): 525 crossing endpoints between `clk_core` and `clk_host`, all safe.
- **Trace streaming** (fca6fe8): the block design gains `S_AXI_HP3_FPD`, and the stream replaces the block-RAM trace ring, which takes 2 RAMB18 off this build. The traffic generators drive no trace records, so synthesis trims much of the stream in this build. Its real size is in the uncore measurement (docs/perf/budgets.md §4: 2.9K LUTs for two cores); this build checks the port, the block design and timing. The primitive check is clean: 63 instances, no failures, warnings or strays, now that tg_fifo maps through tg_ram_lut. CDC: 629 crossing endpoints, all safe.
- **PMOD console** (3c86877, `TG_PMOD_UART=1`): `pmod_uart_txd` placed at E10 and `pmod_uart_rxd` at D10, both LVCMOS33. Those were placeholders: the board's module is on J2 pins 1 and 2, H12 and B10, now the defaults.
  - DRC clean; primitive check clean (63 instances). CDC: 628 safe endpoints between the two clocks, plus the RXD input into the line's synchronizer (false path).
  - The synchronizer flops now carry ASYNC_REG, which this build lacked.
  - **Memory:** this build peaked at 16.6 GB, against the 12 GB the conventions declare for a full build. It now declares 20 (README).
- **Fan** (c8cc8be, DR-129): A12 (`fan_en_b`) is driven straight from `PS8_i/EMIOTTC0WAVEO[2]` through its output buffer, uninverted. Linux's `pwm-fan` and `fancontrol` regulate the fan.
  - DRC clean; primitive check clean (63 instances). It peaked at 16.6 GB of 20 declared.
  - The earlier PMOD build drove the fan low, so its bitstream was deleted (reports kept).
- **Fan and PMOD console together** (343c5a4): `fan_en_b` from `EMIOTTC0WAVEO[2]` at A12; `pmod_uart_txd` at H12; `pmod_uart_rxd` at B10, into the line's synchronizer.
  - DRC clean; primitive check clean (63 instances). It peaked at 16.7 GB of 20 declared.
  - Superseded by the stage B build below; its bitstream is deleted.
- **Stage B** (5048957): the same design, with the PMOD pins now in `kv260.xdc`. Synthesis read 87556b3, which is identical under `rtl/`, `fpga/` and `tools/`. `summary.txt` confirms the routed pins (H12, B10, A12) and the fan settings (TTC0 waveform 2, uninverted).
  - **Checks:** DRC has no errors and one warning, RTSTAT-10 (the unused count outputs of the host bridge's XPM FIFOs), as in the earlier builds. Primitive check clean: 66 instances after synthesis, 63 after `opt_design`. CDC: 628 safe endpoints between the two clocks, plus the RXD input (false path). It peaked at 16.7 GB of 20 declared.
  - **Board files:** `$SOC_BUILD/board/stage-b/`, made by `package.sh`: `tanager.bit.bin`, `tanager.dtbo`, `shell.json`, `tanager-host` (with the `tg start` and `run` fixes), `summary.txt` and `SHA256SUMS`.
  - **Console:** each generator writes one `.` per pass to the UART (`E` after a pass with an error), so the PMOD line carries about two characters per pass at 115200 baud. An earlier note here said the line would idle; `tb_soc` checks those characters.
- **M4, the real core** (db8aced; one `st` core, the PMOD console, the fan on TTC0; 58 DSPs).
  - **At 100 MHz it misses by 3.761 ns** on 3,914 endpoints, all inside the core, in two cross-unit path families that the core track's per-unit timing runs cannot see:
    - `u_lsu/r_data_q` → `u_rob/exr_cause_q`, `exr_rob_q`, `exr_mem_q`: 38 levels, 13.4–13.7 ns routed (41 levels, 11.5 ns after synthesis). From the load data into EX, then through what looks like the page-table walker's leaf logic, the DTLB, the load PMP check and the CSR file into the ROB's exception record.
    - `u_ex/wbq_q` → `u_rob/cmp_q`: 35 levels, about 13.3 ns, back and forth between EX, the LSU, the CSR file and rename.
    - Reported to the core track with the reports (`$SOC_BUILD/vivado/st_core_100_pmod/reports/timing_summary.rpt`); its bitstream is not for the board.
  - **At 60 MHz it closes**: +1.114 ns at db8aced, +0.153 ns at 20435b1 (the same core; placement moves its long paths by about 1 ns between runs). The core returns to 100 MHz once those paths are cut.
  - **20435b1 is the board's M4 bitstream:** the MR head's RTL, with the L2's one-hot MSHR state (−403 LUTs, +432 flip-flops against db8aced, as out of context) and the injector's latency sum fixed. Both builds: DRC without errors (DSP pipelining warnings, RTSTAT-10), primitive check clean (160 instances after synthesis and after `opt_design`), CDC all safe (913 endpoints between the two clocks at 60 MHz, plus the RXD input). Both peaked at 18.3 GB; a core build declares 22.
  - **Board files:** `$SOC_BUILD/board/m4/` (`package.sh`): the bitstream, overlay, `shell.json`, `tanager-host`, `soc_test.bin` (first light), `fw_jump.bin`, `Image` and the one-core device tree.
- **Worst paths:**
  - **Stub build:** L2 MSHR state -> `RREADY` -> injector buffer read enable (6.6 ns, 86% routing).
  - **Traffic-generator build:** 9.1 ns of 10 first; after R15 the worst path is the L2's S2 decision
    into the directory RAM (7.7–8.1 ns data path, 9–14 levels, slack +1.1 to +1.7 ns).
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

