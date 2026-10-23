# Area switches: the bigger-chip checklist

The user, 10-22: "for the tricks that we used to save area like double pump, use block ram instead lutram, are they all documented or sitting behind switches? I just wanna make sure that oneday I have a larrger chip, I can turn them off cleanly".

This page lists every measure taken to fit Tanager on the KV260's XCK26. For each: what it is in hardware, what it saves a chip (two `smt2` cores, four harts), what it costs, its switch and default, how the other form is tested, and, where there is no switch, the way back. It starts from the coordinator's read-only audit of 10-22 (main 4fe536ec); the lint results are verif-2's on main e5b304cd.

- **Timing-only measures are left out:** DR-140's timing cuts, the AR slice and the floorplan buy clock speed, not area.
- **A chip** here is the product: `smt2` with hart 1 (`HART1=1`), two cores, `URF=1`, a release build (DR-180).
- **"Linted"** means `make lint-all` elaborates the form in Verilator, so it compiles and its signals are driven. It does not mean the form has run.
- The user's two examples are both the first row: the integer register file in UltraRAM (block RAM, not LUT RAM), read twice a cycle on a doubled clock (the double pump).

## How to turn everything off

One `make lint-all` elaboration, with hart 1, turns off every measure that has a switch at once, in the simulation and synthesis views (`tools/ci/lint_all.sh`):

```
make lint CFG=smt2 HART1=1 PMP_ENTRIES=16 TAGE_NT=4 TAGE_LI=12 XBAR_SLICE=1 MEM_SLICE=1 RTL_CFG=<tg_cfg_smt2.sv with ROB 96, LQ 32, SQ 24>
```

`lint-all` writes that configuration file itself (`WIN=96,32,24`: a copy of `rtl/common/cfg/tg_cfg_smt2.sv` with the three sizes set). URF and the release form are off when not given.

A board build of that chip (`fpga/kv260/tcl/build.tcl`, fpga/kv260/README.md):
- `TG_DEFINES="TG_HART1=1 TG_PMP_ENTRIES=16 TG_TAGE_NT=4 TG_TAGE_LI=12"`, `TG_XBAR_SLICE=1`, `TG_MEM_SLICE=1`;
- `TG_URF` unset;
- `TG_RELEASE` as wanted: the development features cost area but are not a measure to undo;
- the window: the three sizes edited in `tg_cfg_smt2.sv`, which has no define for them.

The hardwired rows below need RTL work first.

## Switchable, the other form kept and tested

| Measure (hardware) | Saves a chip | Costs | Switch (default) | The other form's tests | Docs |
|---|---|---|---|---|---|
| **URF:** the integer register file in UltraRAM, each copy read twice a cycle at `clk2x` (the double pump), instead of LUT RAM | 2,524 placed LUTs (1,290 a core) | 9 URAM a core, the `clk2x` clock, mid-cycle reads at about 1.2 ns of slack (spikes.md §8.16); no cycles | `TG_URF`, RTL default 0; product builds set 1 | Off is what every regress, soak and nightly boot runs; `build.tcl` drops `clk2x` without it. URF=1 is linted in both views with hart 1 off and, since 10-22, with hart 1 and the release form | DR-174; core-pipeline.md (register files) |
| **Release builds:** no latency injectors, commit trace, virtio window or host console; the PLIC keeps S-mode contexts and 1-bit priorities | Injectors 1,246 LUTs and 4 RAMB36; DR-180's blocks 1,783 LUTs, 3,170 FFs, 2 RAMB18; the trace 1,466 LUTs a core and 3,066 in the uncore | Development features only | `TG_RELEASE`, `TG_LAT_INJ`, `TG_COMMIT_TRACE`; the development build by default | Development is the simulation default. The release form is linted in both views (since 10-22 also with hart 1 and URF); `tests/unit/soc short` runs it (trafgen, and tcore with DMA and the PS window), and QEMU | DR-177, DR-180; soc.md §2.5 |
| **PMP with 8 entries** instead of 16 | 2,710 LUTs and 1,152 FFs, plus about 1.7K with hart 1 (area_recovery.md) | 8 regions; OpenSBI uses 6 | `TG_PMP_ENTRIES` = 8 | 16 is linted every run (since 10-22 also with hart 1) and runs in `make regress` and `make cycle-identical` with Spike following (verification.md §4.3, §4.5). Not in the soak or the nightly boots | DR-167 |
| **The walker starts at B3, not B2** (the ROB's head TLB check a cycle late) | about 390 LUTs (B2 cost +194 a core) | Boot +0.013% / +0.005% | `TG_ROB_HEAD_TLB_LATE`, on with the timing cuts | Through `TIMING_CUTS=0` (CI runs both profiles). Off alone on top of the cuts has never run | DR-144; core-pipeline.md §13 |
| **Area-directed tool settings** | ExploreArea −1,275 LUTs; AreaOptimized_high −7.9% on the `st` core | Paths may lengthen | `TG_OPT_DIRECTIVE`, `TG_SYNTH_DIRECTIVE` in `build.tcl` | Tool options: nothing in the RTL to go stale | DR-166; fpga/kv260/README.md |

## Switchable, the other form now linted (10-22) but not run

| Measure (hardware) | Saves a chip | Costs | Switch (default) | The other form's tests | Docs |
|---|---|---|---|---|---|
| **The uncore's register slices off:** the crossbar's and the memory ports' pipeline registers | 1,174 LUTs, 4,766 FFs, 21 DSPs (soc.md) | Timing on the long uncore paths (−3.17 ns, DR-186); slices give back about 1% of boot cycles, so a bigger chip wants them only for timing | `XBAR_SLICE`, `MEM_SLICE` (tanager_soc and tg_uncore parameters) = 0 | Linted on, with hart 1, in both views (`-GXBAR_SLICE=1 -GMEM_SLICE=1`). `tests/unit/soc short` runs trafgen with both slices on (tcore passed with them once, 10-22), and `tests/unit/xbar` the crossbar's. DR-136's DSP-held slice registers (`TG_UNCORE_DSP`) only act inside these slices, so they are inert while the slices are off | DR-186, DR-136; soc.md (reserve levers) |
| **TAGE with two tagged tables of 2K** instead of the plan's four of 4K | about 800 LUTs (four tables about 2,750, two about 1,950) | `make perf` −16.0% cycles against −16.8% with four | `TG_TAGE_NT`, `TG_TAGE_LI`, `TG_TAGE_TW`, `TG_TAGE_BI` = 2, 11, 9, 11; `make lint TAGE_NT= TAGE_LI= ...` (lint only) | Four tables of 4K are linted in both views with hart 1 (`TAGE_NT=4 TAGE_LI=12`, tags and base table at 9 and 11). Simulated only in DR-170's size study; not in any regress or the soak | DR-170; core-pipeline.md §12 |
| **The window:** ROB 80, LQ 24, SQ 20 and the issue queues as built | about 1.4K LUTs for ROB 96, LQ 32, SQ 24 (0.7K a core) | +1.84% throughput given up; a 1.3× SMT gain would need bigger structures (DR-184) | `rtl/common/cfg/tg_cfg_smt2.sv`'s localparams, no define | ROB 96, LQ 32, SQ 24 are linted in both views with hart 1 (each thread's half 48, 16, 12) and elaborate without RTL changes. Never simulated: the simulation builds take the configuration by `CFG`, so a run needs that file edited or a new configuration | DR-078 ("option, not adopted"), DR-184 |

## Hardwired: the way back is RTL work

The two with a cycle cost, the walker's shared PMP checker (DR-139) and FP conversions on the FMA (R5), stay as they are: the user decided on 10-22 to keep them documented here, with their way back, and to build no switches ("no need to do a switch now; just keep it in the doc").

| Measure (hardware) | Saves a chip | Costs | The way back |
|---|---|---|---|
| **FP banks of 64 with renaming across banks** (DR-179) instead of banks of 96 | 3,260 LUTs (1,630 a core) | FP pairs −0.18 / +0.14 / −0.34%; a select on each FP bank's write port; a rename rule only smt2-study's model has proved | No switch: `FXB = EXT_FD && HART1_ON` (tg_rename.sv) and `FP_PREGS_PER_BANK = 64` (tg_cfg_smt2.sv). The banks of 96 were one configuration line (caf4f560) that d33cf028 replaced; restoring the line alone leaves the crossing logic in, an untested combination. A switch (96 and `FXB` 0 together) is planned with fpu-2 and core-2 (the audit's gap 1). `sim/profile.mk` still says "FP banks of 96" |
| **The page walker shares the store-address port's PMP checker** (DR-139) | 1.66K LUTs (0.83K a core) | Up to +0.23% cycles on walk-heavy suites | No switch (tg_lsu.sv, tg_ptw.sv). The walker's own checker is dbbd0734's parent; DR-183 (PMP at fill) replaces this arrangement anyway |
| **Rename's payload in a LUTRAM** (DR-185, main 2e2e090f): the fields rename never reads (PC, instruction bits, prediction state, immediate, branch target, the units' controls; about 385 bits a slot) wait in a LUTRAM beside rename instead of the RN and DS registers | 2,908 FFs and 294 LUTs (1,454 and 147 a core, out of context) | None: cycle-identical by construction | No switch back to the registers: they are 196cb8ed's parent. `TG_PAY_WREG` (1, the default) registers decode's write into the LUTRAM; 0 writes it directly, about 1,540 FFs fewer (770 a core) if decode's paths close (spikes-2's preview without the register had 373 failing pins). `PAY_WREG=0` is linted on every configuration and, with hart 1, in the synthesis view (10-22) |
| **R5: FP→FP and integer→FP conversions on the FMA** (DR-067) | 1,224 LUTs (612 a core) | FCVT takes 5 cycles, not 2 (at most 0.09% IPC); the FMA's slack +0.34 → +0.08 ns | No switch (tg_fpu_misc.sv). The separate conversion paths are 12880f1b's parent |
| **fpu-2's levers 1a and 9:** the FMA's addend alignment and the divider's multipliers in DSP tiles | 580 LUTs (290 a core), +2 DSPs a core | None: cycle-identical | Not needed: it costs nothing. The old forms are 897bd3a3's first parent (fpu.md still describes them) |
| **Cycle-identical RAM, DSP and logic rewrites:** rename maps, ready tables and cold CSRs in LUT RAM, the DTLB as a LUT-RAM CAM, counters in DSPs, 16 wakeup tags | tens to hundreds of LUTs each | None measured (16 tags: 0.00%, DR-053) | Not needed: they cost nothing (core-pipeline.md, the area notes; fpga_friendly.md §4) |
| **Features deferred for area:** a block BTB, DTLB replay, checkpoints, 16 L1D miss entries, ASID tags and an L2 TLB | Block BTB about 1.2K (0.6K a core); checkpoints 4–6K (2–3K a core) | CoreMark −2.2% without the block BTB; DTLB replay +0.30% boot and checkpoints +2.5% left on the table; the ASID-less TLB's cost under Linux is unmeasured | Never built: new RTL. `TG_DC_MSHRS` takes only 1 or 4. `tg_cfg_smt2.sv`'s `TAGE_LOG = 12` ("4 tagged tables of 2^12") and `L1D_MSHRS = 16` are the plan's values, unused: tg_core_pkg's `TAGE_*` and `DC_MSHRS` decide what is built |

## When merged

| Measure | Switch | Its off form, to add then |
|---|---|---|
| DR-183's PMP checks at TLB fill (soc-2) | `PMP_FILL`, off by default | Lint both forms, with hart 1 too, and run regress and the soak with it on |
| DR-185's lever 2: the issue queues' readiness ANDs on CARRY8 chains (fpu-2, `tg_iq_cand`; on main since a8a0ac3c as `tg_issue`'s `CC` = 2'b01, the AND form at 0) | `TG_IQ_CC` (fpu-2's c86431d7: 1 the default, 0 the AND, 3 the select's chains too) | Cycle-identical by construction; `tests/unit/iq`'s `tb_iqcc` runs the primitive's model against the AND. Lint `IQ_CC=0` and `3` once the define is on main |
| DR-175's FP banks of 96 back (fpu-2's c86431d7) | `TG_FP_BANK96=1` | Into the bigger chip's elaboration, and the hardwired row above becomes a switch |

## Nothing to undo

Levers considered and never taken: DR-185's reserves (unary ops on ALU1 only, hart 0 running merged alone), the simple ALU and the partial-address search that were rejected, the queue trims. Radix-4 divide is off (`tg_fpu_pkg.sv`). The L2 keeps 24 miss entries a bank (DR-085); the reserve of going to 16 was never taken.

## What lint-all elaborates for this page

Four elaborations on `smt2`, added 10-22 (`tools/ci/lint_all.sh`, verification.md §4.3):
- the product's combination, `HART1=1 URF=1 RELEASE=1 LAT_INJ=0 COMMIT_TRACE=0`, in the simulation and synthesis views;
- the bigger chip's, `HART1=1 PMP_ENTRIES=16 TAGE_NT=4 TAGE_LI=12 XBAR_SLICE=1 MEM_SLICE=1 WIN=96,32,24`, in both views;
- DR-185's direct payload write, `PAY_WREG=0`, on every configuration, and `HART1=1 PAY_WREG=0` in the synthesis view: five more, 42–93 s each by hand at load 70.

- **The cost:** each takes 25–45 s of one thread (by hand at nice 10, host at load 70: the product's 33 s and 43 s, the bigger chip without the window 25 s, the window alone 23–28 s). The four together are about 150 s, so about 25 s more at six at a time of `lint-all`'s 751 s. `lint-all CFGS=smt2 VIVADO=0` with them: 33 of 33 in 451 s at load 70–82.
- **The slices on, run:** `tests/unit/soc short` adds trafgen with `XBAR_SLICE=1 MEM_SLICE=1`: a model build and about 34 s of simulation. tcore with both slices on passed once too (10-22).
