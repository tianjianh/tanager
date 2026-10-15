# Tanager: per-unit LUT budgets

*Plan §8.5, "Process": every configuration has per-unit LUT budgets in CI. This page sets them and describes the nightly check that holds the RTL to them.*

| | |
|---|---|
| Status | Proposed, 2026-10-13 (spikes track) |
| Target | v1 (`smt2`) dual-core at 200 MHz and ≤ 88% of the XCK26 after the §8.5 levers: ≤ 103K of 117,120 LUTs (§8.5's fill limit, measured by spike S6). D18 step 1 works against it (DR-116). v2 (`smt2_w3`): 49.7K per core at 180 MHz (AR-9, DR-117; §1.1) |
| Machine-readable form | [`fpga/budget/budgets.tsv`](../../fpga/budget/budgets.tsv); the check is [`fpga/budget`](../../fpga/budget) |
| Inputs | plan §8.2 per-unit estimates; the SMT2 study's per-structure cost ([smt2_report.md](smt2_report.md) §8.3); measured units: the scheduler (spike S2, [spikes.md](spikes.md) §4) and the FPU ([fpu.md](../spec/fpu.md), "Timing and area"); the §8.5 levers |

## 1. Budgets per core

LUTs in thousands. "Before" is the unit with no area recovery. "Levers" are the §8.5 savings that belong to that unit. The budget is what the unit may cost after them, also net of R14, the implementation lever (LUT6_2 packing, area directives on non-critical logic), which is spread over all units in proportion to their size.

| Unit (plan §8.2 row) | Plan, ST | ST before | ST levers | **ST budget** | SMT2 adds | SMT2 before | SMT2 levers | **SMT2 budget (v1)** |
|---|---|---|---|---|---|---|---|---|
| Front end | 6.1 | 6.1 | R7 0.2 | **5,540** | +1.0 | 7.1 | R7 0.2 | **6,480** |
| Decode, RVC | 1.6 | 1.6 | — | **1,500** | +0.15 | 1.75 | — | **1,640** |
| Rename, checkpoints, free lists | 1.6 | 1.6 | R3 0.3 | **1,220** | +1.3 | 2.9 | R3 0.45, R10 0.5 | **1,830** |
| ROB, commit, traps, CSRs, PMP | 3.6 | 3.6 | R1 0.75, R2 0.4, R7 0.15 | **2,160** | +4.21 | 7.81 | R1 1.5, R2 1.0, R7 0.15 | **4,840** |
| Issue queues and wakeup | 2.9 | **6.43 measured** (with MX) | — | **6,030** | (measured) | **8.90 measured** | — | **8,350** |
| Register files and bypass | 4.6 | 4.6 | (R8 rejected) | **4,320** | — | 4.6 | — | **4,320** |
| Integer execution | 4.0 | 4.0 | R4 0.5 | **3,290** | — | 4.0 | R4 0.5 | **3,290** |
| LSU | 6.4 | 6.4 | R9 0.25 | **5,770** | +1.07 | 7.47 | R9 0.25 | **6,780** |
| MMU | 2.2 | 2.2 | R6 0.4, R7 0.1 | **1,600** | +0.2 | 2.4 | R6 0.4, R7 0.1 | **1,780** |
| FPU (Goldschmidt, D17) | 4.7 | **7.62 measured** | R5 0.38 | **6,800** | — | 7.62 | R5 0.38 | **6,800** |
| **Core** | 37.7 | 44.2 | + R14 2.5 | **38,220** | +8.28 | 54.6 | + R14 3.0 | **46,120** |
| Uncore (SoC track) | 13.3 | 13.3 | R15 2.0 | **11,300** | | 13.3 | R15 2.5 | **10,800** |
| **SoC (2 cores + uncore)** | 88.7 | 101.6 | | **87,740 (74.9%)** | | 122.4 | | **103,040 (88.0%)** |

### 1.1 At 180 MHz: v2's budget, and v1's for reference

D18 puts IPC first: the no-IPC work, then a lower clock (about 180 MHz), then the levers that cost IPC. Lowering the clock is the user's decision (DR-137), so the 180 MHz figures here are references, not a plan. The 180 MHz fill test ([area_synth.md](area_synth.md) §5) closes v1 with wakeup tags at 93.4% and 95.3% fill, and v2 at 90.0%, 94.2% and 96.0%, with no trend with fill, so the ceiling is above the highest fill tested.

**v1 stays on its 200 MHz lines.** Moving them to 180 MHz would lower the target clock, which needs the user's approval (DR-137) and comes after D18 step 1 at the earliest (DR-116). For reference only, v1 at 180 MHz and 95% would be:

| v1 (smt2) | 200 MHz (the budget) | 180 MHz at 95% (reference) |
|---|---|---|
| SoC (2 cores + uncore) | 103,040 (88.0%) | 111,264 (95.0%) |
| Uncore | 10,800 | 10,800 |
| Core | 46,120 | 50,230 |

**v2 (smt2_w3) has its own lines at 180 MHz** (AR-9, DR-117; [area_recovery.md](area_recovery.md) §7.4): per core (110,280 − 10,800) / 2 = **49,740**, from the 94.2% fill with the uncore on budget. They assume v2 runs at 180 MHz, which is the user's decision (DR-137). Each line is v1's plus the 3-wide increment:

| Unit | v1 (smt2) | v2 (smt2_w3) | Increment, and its source |
|---|---|---|---|
| Front end | 6,480 | 6,480 | +0: S5 measured the same at width 3 |
| Decode | 1,640 | 2,340 | +700, plan §4.15 |
| Rename | 1,830 | 2,330 | +500, plan §4.15 |
| Issue queues | 8,350 | 7,240 | re-based on the tags scheduler: 7,703 × 0.94 (R14) |
| Execution (RF, bypass, ALUs) | 7,610 | 10,750 | +3,140: S3's third ALU, bypass and fourth bank (+3,433) less R14 |
| LSU and MMU | 8,560 | 8,560 | — |
| ROB, commit, CSRs | 4,840 | 5,240 | +400, plan §4.15 |
| FPU | 6,800 | 6,800 | — |
| **Core** | **46,120** | **49,740** | DSPs 91, block RAM 42.5 as smt2 |

- The v2 lines are **tracked, not enforced**: the nightly shows them as value / budget, but its exit status stays about v1 and ST until v2 work starts.
- **v1's issue-queue line predates the tags.** With tags (AR-1) and DR-113's settings the whole scheduler measures 4,228 / 4,750 at st / smt2 out of context, against budgets of 6,030 / 8,350.
- **R14 is now measured rather than assumed.** The budget run builds the core with `AreaOptimized_high` (DR-113), which takes 7.9% off at st, more than the 2.5K (5.7%) R14 assumed.

**The scheduler has MX (matrix wakeup) in every configuration.**
- Out of context, st closed without it (+0.110 ns).
- In the full chip at 76% fill (spike S6), the ST wakeup loop missed by 0.041 ns.
- MX takes that loop out of the 1-cycle path (+0.145 out of context) for 1.1K LUTs.

**Where the SMT2 additions sit.** The SMT2 study's §8.3 items, central values, put on their units:
- **Front end, +1.0K:** the second FTQ, history, RAS and fetch PC; the per-thread instruction-queue pointers; ICOUNT.
- **Decode, +0.15K:** a decode-to-rename queue per thread.
- **Rename, +1.3K:** the second rename and committed maps, and the second set of checkpoints.
- **ROB, commit and CSRs, +4.21K:**
  - the window step from ROB 48 to 80, +0.96K;
  - TID partitions, +0.25K;
  - the second CSR file, trap and interrupt state, +2.0K;
  - the second set of performance counters, +1.0K.
- **LSU, +1.07K:** LQ 16 → 24 and SQ 12 → 20, +0.72K; TID in the LSQ CAMs, +0.25K; sibling snoops and LR, +0.1K.
- **MMU, +0.2K:** the TID in the TLB tags.
- **Issue queues:** their growth (104 instead of 64 columns, caps) is in the measured 8.9K.

**Other resources, per core.**

| Unit | DSP48E2 | Block RAM (RAMB36 equivalents) |
|---|---|---|
| Front end | — | 30 (I$ 16, TAGE and BTB) |
| ROB, commit, CSRs | 18 (ST) / 36 (SMT2): the R1 counters, 18 per hart | 1 (R7: commit-time payload) |
| Integer execution | 18 (multiplier 16; the branch unit's pc + 2/4 adder 2, DR-131) | — |
| LSU | — | 9 (D$ data 8, LSQ data) |
| MMU | — | 2 (L2 TLB) |
| FPU | 37 (DR-110 35; the FMA's hi + 1 adder 2, DR-131) | 0.5 (seed ROM) |
| **Core** | **73 / 91** | **42.5** |
| Uncore | 140 (DR-136: registered selects in the crossbar, skid buffers, trace stream and L2) | 19 (DR-136: 2 RAMB18 for the host bridge) |

- **LUTRAM and flip-flops** have budgets only where a unit is measured: the scheduler (LUTRAM 300 / 310, flip-flops 7,540 / 10,000 for st / smt2) and the FPU (flip-flops 4,100, DR-110). The scheduler's are the measurement plus about 10%; the FPU's were too (3,450 flip-flops, 32 DSPs) until DR-110 raised them to 4,100 and 35 so the FPU can trade LUTs for registers and DSPs.
- **Everywhere else they are tracked, not judged.** The device-wide limits are about 57K LUTs of SLICEM sites for LUTRAM (plan §8.5) and 234K flip-flops.

## 2. What the budgets assume

- **Free levers at the top of their ranges:**
  - R1 1.5K (counters in DSPs);
  - R2 1.0K (cold CSRs in LUTRAM);
  - R14 3.0K;
  - R15 2.5K.

  With every one of them at its central value, v1 lands at about 105K (90%).
- **Levers with an IPC cost at their central values:** R6 (set-associative TLBs), R9 (strict store forwarding) and R10 (shared checkpoints). The area-recovery study (plan §8.5) judges them. If it rejects one, its LUTs have to come from the reserve.
- **The reserve,** measured options that are not in the budgets:

  | Option | Saves per core | Cost |
  |---|---|---|
  | ALU issue queues 10 → 8 rows | ≈1.0K (1.5K measured at smt2_w3) | 1.2–1.5% IPC (§8.1) |
  | SMT2 window at ROB 64 (§8.5 contingency) | ≈1.3K in the scheduler, plus ROB storage | −1.5% throughput |
  | **Last:** release builds without the commit trace (DR-121), release bitstreams only | 1,466, plus about 2.9K in the uncore's trace stream | no IPC; those builds lose FPGA lockstep (every development and test build keeps the trace) |

  - **Radix-4 divide/sqrt has left the reserve** (DR-118, the user's decision). Re-measured after the FPU's no-IPC pass it saves only 1,036 LUTs and fails the reverse rule (2.34% IPC per 1K LUTs against a 2.19% limit). It stays buildable behind `FDIV_RADIX4`, and the nightly still tracks it, but it is not an area lever.

- **The scheduler and FPU budgets were set below their measurements, and both units are now within them.**
  - The scheduler: 8,350 at smt2 and 6,030 at st, set against 8,895 and 6,425 (R14, about 6%, applied as to every unit). With wakeup tags (AR-1) and DR-113's settings it measures 4,750 and 4,228 out of context.
  - The FPU: 6,800, set against 7,622 (R5 and R14). After R5 and the no-IPC pass `tg_fpu` measures 5,700 at smt2.
- **The 3-wide configurations:** `smt2_w3` (v2) has per-unit lines at 180 MHz (AR-9, DR-117; §1.1), tracked until v2 work starts; `st_w3` is tracked without budgets.

## 3. The nightly check

**One command:**
```bash
fpga/budget/nightly.sh
```
It runs nightly from cron (see [`fpga/budget/README.md`](../../fpga/budget/README.md)):
1. It exports main's latest commit, so no checkout is touched.
2. It synthesises each unit of [`fpga/budget/units.tsv`](../../fpga/budget/units.tsv) out of context in each configuration, through synthesis and `opt_design`.
3. It runs the primitive check after both steps.
4. It compares LUTs, LUTRAM, flip-flops, DSP and block RAM with the budgets and with the previous night.
5. It writes the report to `$TANAGER_BUILD/budget/latest.md`.

It does nothing when main has not moved since the last run.

**Units it builds today:**
- the FPU, in all four configurations, plus the radix-4 variant;
- the scheduler, from the spike RTL until the core track merges its own;
- `tg_core`, a stub now, which grows into the whole-core check.

As the core track merges each unit, it gets a line in `units.tsv`; its budget is already in `budgets.tsv`.

**First run (2026-10-13, this branch, 13 syntheses in about 20 minutes):**

| Unit | st | smt2 | st_w3 | smt2_w3 |
|---|---|---|---|---|
| FPU | **7,518** / 6,800 | **7,518** / 6,800 | 7,518 | 7,518 |
| FPU, radix-4 (tracked) | | 6,079 | | |
| Scheduler | **6,470** / 6,030 | **8,909** / 8,350 | 8,842 | 12,424 |
| `tg_core` (stub) | 0 / 38,220 | 0 / 46,120 | 0 | 0 |

- **Over budget, as expected:** the FPU everywhere and the scheduler at st and smt2. The R5 and R14 work closes those gaps.
- **Primitive check:** clean everywhere. The FPU reports one stray block RAM, its seed ROM, which is inferred because `rtl/common/prim` has no ROM wrapper yet.

**Reading the report:**
- Each cell reads value / budget, bold when over, with Δ since the previous run.
- The exit status is 0 when every enforced unit is within budget and primitive-clean, and 1 otherwise.
- A unit that grows past its budget, or a memory that maps to the wrong primitives, shows the next morning.

## 4. The uncore, measured (SoC track)

**Unit:** `uncore` is `tg_uncore`: everything in `tanager_soc` except the cores, with the cores' ports as its ports, so nothing is trimmed. It uses the flow of §3 with 2 cores. A traffic-generator bitstream is not a measurement of the uncore: its generators use few of the ports, and synthesis trims the rest. Its uncore came to about 14.7K LUTs ([fpga/kv260/results.md](../../fpga/kv260/results.md)).

| Commit | Change | st LUTs | smt2 LUTs | FFs (smt2) | RAMB36 equiv. |
|---|---|---|---|---|---|
| aac20a2 | first measurement (L2 after lever R15) | 22,830 | 23,475 | 19,047 | 27 |
| e256b0e | L2: the same-set rule at S0 replaces the directory's write history (reverted in fc1031e: it adds bubbles; a reserve lever, [soc.md](../spec/soc.md) §Reserve levers) | 22,405 | 23,050 | 18,854 | 27 |
| 059a572 | interconnect: each arbiter over the ports that can reach it | 20,884 | 21,533 | 18,811 | 27 |
| fca6fe8 | commit-trace streaming into DDR replaces the block-RAM ring | 21,797 | 22,265 | 18,304 | **18** |
| fc1031e | L2: the write-history bypass back (the same-set rule moves to the reserve list, D18 step 1) | 22,315 | 22,783 | 18,493 | **18** |
| 4d5ca13 | main's DR-120 (`pma_of` by prefix match) | 21,724 | 22,284 | 18,493 | **18** |
| 4d5ca13 | the same under DR-113's settings (`-flatten none -directive AreaOptimized_high`; the budget flow's settings for the uncore since e7227d4, as for the core) | 20,066 | 20,560 | 18,479 | **18** |
| 11bf523 | crossbar: the caches' A-channel data, corrupt and mask as constants (−249, measured on fc1031e; cycle-identical) | ≈21,475 | ≈22,035 | | **18** |
| e7227d4 | L2: the MSHR state one-hot (54800a2, about −400; cycle-identical), with the crossbar change; DR-113's settings | 19,439 | 19,933 | 18,911 | **18** |
| 44767a1 | register slices in DSPs (DR-136): the crossbar's, the memory paths' AR, AW, W and R, the L2 banks' R; 83 DSPs; cycle-identical | 18,047 | 18,603 | 16,092 | **18** |
| **budget** | | **11,300** | **10,800** | | **18** |

**The uncore at 200 MHz** (st, out of context, placed and routed with `fpga/kv260/tcl/ooc_impl.tcl`; the placement is unconstrained, which DR-089 says can cost up to about 1 ns against the full chip; LUT counts after placement include `phys_opt_design`'s replication, so the budget table above is the one for area):

| Commit | Run | LUTs | FFs | DSP | WNS | TNS (failing endpoints) |
|---|---|---|---|---|---|---|
| 44767a1 | all slices in fabric, DR-113's settings | 19,796 | 19,057 | 1 | −1.779 ns | −4,146 ns (7,044) |
| 44767a1 | all slices in fabric, Vivado's default directive | 21,150 | 19,107 | 1 | −1.150 ns | −1,664 ns (3,962) |
| 44767a1 | slices in DSPs (the default), DR-113's settings | 18,465 | 16,056 | 84 | −2.004 ns | −7,964 ns (10,601) |
| 028a480 | the L2's S2 restructured (A + B + D, [l2.md](../spec/l2.md)), all fabric | 19,944 | 19,114 | 1 | −0.738 ns | −876 ns (2,824) |
| 028a480 | the same, slices in DSPs | 18,670 | 16,448 | 84 | −1.551 ns | −3,881 ns (6,590) |
| 0a29936 | + the injector's token bucket, one-hot L2 AR/probe picks and the window's single compare (the last two reverted in ca1aece), all fabric | 20,009 | 19,147 | 1 | −0.903 ns | −1,182 ns (3,101) |
| ca1aece | A + B + D and the token bucket, all fabric | 19,921 | 19,124 | 1 | −0.908 ns | −1,013 ns (2,984) |

- At 44767a1 the worst paths were the L2's S2 decision into the directory's block RAM (14–23 levels) in every run. The latency injectors, the memory windows, the crossbar and the memory slices also failed by 0.4–1.8 ns.
- **After the L2's S2 rework** (028a480; [l2.md](../spec/l2.md) §Timing), three all-fabric placements of the same S2 RTL gave WNS −0.738, −0.903 and −0.908 ns. An unconstrained out-of-context placement of the whole uncore varies by about 0.2 ns from run to run, so a single run's difference below that is not a result. Across the runs:
  - the injector's token bucket: −0.738 ns, then −0.17 ns in both runs after acec41c;
  - S2 into the directory RAM: −0.66 to −0.91 ns, the worst path in two of the three runs;
  - the L2's AR handshake (pick, MSHR LUTRAM, the window's range check, `ar_ready_i`, the AR pointer): about −0.70 ns, 60–70% of it wire. Cutting it needs the LUTRAM address from a register, which adds a cycle (a reserve item, DR-135);
  - the crossbar's B slices, the memory AR slices and the injector's AR-side writes: −0.5 to −0.85 ns.
- For reference only (DR-137: the clock is the user's decision): 180 MHz lengthens the period by 0.556 ns. At first order, the all-fabric uncore after the S2 rework would still miss 180 MHz by about 0.2–0.35 ns. Before the rework it missed by about 1.2 ns.
- `AreaOptimized_high` costs about 0.6 ns here for its 1.35K LUTs, and the DSP slices another 0.2 ns and about 3,500 failing endpoints: the slices behind the crossbar's arbiters (B −1.9, D −0.8 to −1.6, memory AR −1.3 to −1.5, A 0 and 1 −0.6 to −0.9 ns).
- So the uncore needs timing work for 200 MHz with or without the DSPs. The board builds run at 60–100 MHz, where every slice has slack. The full-chip fit decides per site through `UNCORE_DSP`.

**By block** (smt2, 059a572):

| Block | LUTs | FFs | RAMB36 | Notes |
|---|---|---|---|---|
| L2, two banks | 9,866 | 5,061 | 13 | About 4.9K per bank: 24 MSHRs at about 120 LUTs each, plus about 2K. Lever R15 took it from 18.4K ([l2.md](../spec/l2.md)) |
| Interconnect | 4,364 | 4,051 | — | arbiters about 2.1K; register slices about 2.0K (for 200 MHz) |
| Host bridge | 3,335 | 5,971 | 1 | the trace ring's 320-bit record readback is about 2.7K of the FFs |
| Devices | 1,614 | 1,176 | — | device bus 688, PLIC 565 (8 contexts), ACLINT 248, UART 113 |
| Latency injectors | 1,479 | 546 | 4 | the plan §5.6 experiment feature |
| AXI slices at the memory ports | 408 | 1,476 | — | for 200 MHz |
| Trace ring | 449 | 437 | 9 | one core, block RAM |

**Why it is above 13.3K.**
- The plan's interconnect estimate was 1.5K ([uncore.md](../spec/uncore.md)); it measures 4.4K even after the arbiter change.
- The per-bank L2 estimate (4–5K) is met only after R15.
- The host bridge, the devices and the M4 debug and experiment features (latency injector, commit trace) were outside the estimate or estimated lower.

**After streaming** (fca6fe8, smt2): the stream is 2,853 LUTs for two cores, about 1,000 of them LUTRAM. The ring was 449 LUTs plus 8 RAMB36 and 2 RAMB18. The host bridge fell from 3,335 to 1,667 LUTs, because the record readback left its read multiplexer and status crossing. Net: +732 LUTs and −9 RAMB36, so block RAM now meets its budget of 18. The primitive check is clean: 66 instances, no failures, warnings or strays.

**What no-IPC work is left** (estimates, written before streaming was measured):

| Item | LUTs | Other |
|---|---|---|
| Trace streaming replaces the ring ([uncore-trace.md](../spec/uncore-trace.md)) | +2.2K stream, −0.45K ring, −0.5K host readback = **+1.25K** | block RAM 27 → 18; host bridge −1.4K FFs |
| Host bridge register file and read multiplexer | −0.3K | |
| L2 remaining small items | −0.3K | |
| **Landing (smt2), feature set as today plus streaming** | **≈ 22K** | 18 RAMB36 |

No-IPC work cannot reach 10.8K: the floor is set by features, the clock and the MSHRs. These options need a coordinator decision; their order follows D18:

| Option | Saves (smt2) | Cost |
|---|---|---|
| Release build without the latency injectors and trace streaming (build parameters; verification and latency builds keep them) | ≈ 4.3K (stream 2.85K measured, injectors 1.5K) | no lockstep or latency sweeps on release bitstreams. The trace part is DR-121 (the user, 10-14): the last reserve lever, release bitstreams only. The injector part is still open |
| Remove the interconnect and memory-port register slices | ≈ 2.4K | timing: 200 MHz at risk; per D18 a lower clock (about 180 MHz, the user's decision, DR-137) comes before IPC cuts |
| L2 MSHRs 24 → 16 per bank | ≈ 2.0K | IPC at the long latency points (the last resort under D18) |
| L2 MSHRs 24 → 8 per bank | ≈ 3.9K | IPC (more) |
| Raise the uncore budget to the measured floor (≈ 18K for a release build) | — | about 7K over 10.8K: v1 lands at about 94% of the XCK26 (110K) instead of 88%, unless the core or the reserve gives it back |

## 5. History and lessons

*Updated with each merge (conventions §10).*

- **2026-10-13: first budgets.**
  - Derived from plan §8.2, the SMT2 study's per-structure split, the measured scheduler (8.9K at smt2) and FPU (7.6K), and the §8.5 levers per unit.
  - v1 lands at 103.0K (88.0%) only with the free levers at the top of their ranges.
- **ST revised the same night:** the S6 fill test showed st needs MX in the scheduler, +1.1K, so ST is 87.7K (74.9%).
- **The first budget runs, 13 syntheses in 20 minutes:** the FPU at 7,518 and the scheduler at 6,470 / 8,909 were over budget, as expected before R5 and R14.
- **2026-10-13/14: the uncore measured as its own unit (§4).** `tg_uncore` measured 23,475 → 22,265 LUTs at smt2 against 10.8K. Trace streaming brought block RAM to its budget of 18, and the options left need a decision (§4).
- **2026-10-14: the real core.**
  - Its first synthesis is 82.5K LUTs at st with the hierarchy kept, against the 38.2K core budget.
  - The budget flow now builds `tg_core` with `-flatten none` and reads every unit from that one report.
  - The breakdown points at seven PMP checkers (21.8K), the D-cache (13.2K) and rename (11.9K).
- **AR-1 measured:**
  - the scheduler with wakeup tags is 4,802 / 5,506 / 7,703 at st / smt2 / smt2_w3, 2.8K under its v1 budget of 8,350;
  - the FPU pass brought the FPU to 5,889.
- **2026-10-14 ~03:20: the memory incident.**
  - The nightly's `core_smt2_w3` synthesis ran with the hierarchy kept and 8 threads. Vivado forks one process per thread for a hierarchical synthesis, so it ran as a parent plus six children: about 14.5 GB.
  - Next to two full-device S6 runs of about 9 GB each, it exhausted WSL's 39 GB, and SSH and the sessions stalled for about 10 minutes. The coordinator stopped the budget synthesis, which also stopped that night's run.
  - **A second episode, 03:30–04:01:** another track's synthesis, started with the old `vivado_run.sh`, added about 10 GB. After 19 minutes of thrashing the kernel killed the S6 run `s6_smt2w3t_93_180` (since re-queued).
  - **The fix:**
    - `tools/vivado_run.sh` admits jobs by declared memory: 24 GB budget, 2 slots.
    - The budget flow declares each unit's total: `-mem` in `units.tsv`, 6 GB for the whole core, 4 for the others.
    - Unit syntheses (and the spike flow's synthesis step) run with at most 2 processes (`TANAGER_SYNTH_THREADS`).
- **DR-110: the FPU's flip-flop and DSP budgets raised.** Flip-flops 3,450 → 4,100 and DSPs 32 → 35, so the core's DSPs are 69 / 87 at st / smt2. LUTs are the scarce resource (D18: IPC first), so the FPU may spend registers and DSPs to save LUTs; its LUT budget stays 6,800.
- **The reserve follows the user's decisions:** radix-4 is out (DR-118); release builds without the commit trace are its last lever (DR-121).
- **DR-131: DSP lines for the T6 adders** (fpga_friendly.md T6): execute 16 → 18 (the branch unit's pc + 2/4, −50 LUTs) and the FPU 35 → 37 (the FMA's hi + 1, −54 LUTs), so the core's DSPs are 73 / 91. The table lines come with the FPU track's merge.
- **DR-136: the uncore's DSP and block RAM lines** (fpga_friendly.md §4): DSPs — → 140 for registered selects (the crossbar ≈80, memory-path skid buffers ≈16, the trace stream's output select 20–30, the L2's selects ≈16), block RAM 18 → 19 for the host bridge's read multiplexer. The SoC track estimates −4.0K LUTs, cycle-identical; v1 then uses ≈322 of 1,248 DSPs.
- **The 180 MHz fill test and v2's lines (§1.1).** The fill test closes v1 at up to 95.3% and v2 at up to 96.0% at 180 MHz. v2's per-unit lines go in at 180 MHz (AR-9, DR-117: 49,740 per core), tracked until v2 work starts. v1 stays at 200 MHz: its move to 180 MHz is the clock decision, after D18 step 1 (DR-116). The core's DSP lines follow DR-110 (69 / 87).
- **The core built as DR-113 builds it.** The budget run now synthesises `tg_core` with the hierarchy kept plus `AreaOptimized_high`: at st 56,461 → 52,024 LUTs (−7.9%; every unit 5–14% smaller; flip-flops and LUTRAM unchanged). From the next nightly, the core and its derived units read about 8% lower for that reason alone.
- **The core's memory, measured.** Sampled over Vivado's whole process tree, the st core peaks at 6.75 GB as built until now and 9.38 GB with the directive, against 6 GB declared. The core line now declares 12 GB, for the larger configurations. Vivado's log shows only the parent process, which is how 6 GB looked right.
- **The primitive check after synthesis:** the FPU divider's output queue reported 8 LUTRAM primitives against 7 expected, and `opt_design` removed the extra one. A `tg_ram_lut` instance now passes anywhere between the primitives that hold a loaded bit and the full mapping, so the nightly's post-synthesis check no longer fails on a primitive that is not trimmed yet.
- **Lessons:**
  - A job's memory is the sum of what it forks, not what its parent shows: declare that total, or cap the forking. Measure it over the process tree (PSS), not from Vivado's log.
  - Measure a unit before budgeting it: the estimate for the scheduler was off by 2–4×, while S3, S4 and S5 landed within plan.
  - Build with the hierarchy kept when counting. It is exact per module, and on this design it was also 5–6% smaller.
