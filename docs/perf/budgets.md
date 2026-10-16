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
| ca1aece | L2: the S2 restructure for 200 MHz (A + B + D, DR-137; +129 to +181 LUTs per bank), the injector's late select; cycle-identical | 18,359 | 18,903 | 16,190 | **18** |
| cd1f584 | `UNCORE_DSP` defaults to the sites that meet 200 MHz as DSPs (21 DSPs: −373 LUTs and −767 FFs against all fabric at `st`, 19,604; +872 against every site in DSPs), the ACLINT's compares in DSPs (−62), the injector's head slot (+32); cycle-identical | 19,231 | 19,664 | 18,249 | **18** |
| 9ee161c | the one-hot MSHR way and the AR slice on (DR-143), the tree picks, the skid entry's clock enable, the injector's head slot (+91 against cd1f584); cycle-identical but for the AR slice's cycle on every L2 fill (the user's decision) | 19,322 | | 18,343 at `st` | **18** |
| 2dc6eba | L2: the directory written at S3 (498aaa1: +169 LUTs and +100 FFs at `st`), the victim pick and its consequences selected late, the probe flags' enables (54189da, 2dc6eba: +174); cycle-identical | 19,665 | 20,098 | 18,719 | **18** |
| c972c58 | L2: the allocation's probes and Grant cap selected late, each MSHR's next probe agent (0449256, reverted in 5d9fef2); the trace's stop count from valid records; together −1; cycle-identical | 19,664 | | 18,443 at `st` | **18** |
| 5d9fef2 | 0449256 reverted: 2dc6eba's L2 plus the trace's stop count (both LUT-neutral); cycle-identical | 19,664 | | 18,443 at `st` | **18** |
| c91ac34 | L2: the response engine's shape in flip-flops (6670546: −18 LUTs, +100 FFs), the probe pick made a cycle ahead (+35, +10 FFs); cycle-identical | 19,681 | | 18,553 at `st` | **18** |
| 916fef5 | L2: the `ProbeAck` search on the one-hot hit way (−42); `D_SLICE`, `W_SLICE` and `XBAR_IN_SLICE`, off (0; reserve items: +160, +182 and +307 / +499 LUTs on, [soc.md](../spec/soc.md)); cycle-identical | 19,639 | | 18,553 at `st` | **18** |
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
  - the injector's token bucket, worst over both ports: −0.738 ns all fabric (−1.035 with the DSP mask), then −0.21 and −0.65 ns in the two all-fabric runs after acec41c (−0.743 with the DSP mask). The late `issue` itself still reaches the bucket's select and the beat buffer's read; e8a1e1d takes a LUTRAM read off it;
  - S2 into the directory RAM: −0.66 to −0.91 ns, the worst path in two of the three runs;
  - the L2's AR handshake (pick, MSHR LUTRAM, the window's range check, `ar_ready_i`, the AR pointer): about −0.70 ns, 60–70% of it wire. Cutting it needs the LUTRAM address from a register, which adds a cycle (a reserve item, DR-135);
  - the crossbar's B slices, the memory AR slices and the injector's AR-side writes: −0.5 to −0.85 ns.
- For reference only (DR-137: the clock is the user's decision): 180 MHz lengthens the period by 0.556 ns. At first order, the all-fabric uncore after the S2 rework would still miss 180 MHz by about 0.2–0.35 ns. Before the rework it missed by about 1.2 ns.
- `AreaOptimized_high` costs about 0.6 ns here for its 1.35K LUTs, and the DSP slices another 0.2 ns and about 3,500 failing endpoints: the slices behind the crossbar's arbiters (B −1.9, D −0.8 to −1.6, memory AR −1.3 to −1.5, A 0 and 1 −0.6 to −0.9 ns).
- So the uncore needs timing work for 200 MHz with or without the DSPs. The board builds run at 60–100 MHz, where every slice has slack. The full-chip fit decides per site through `UNCORE_DSP`.

**Per-site check of the DSP slices** (DR-136, DR-137), 200 MHz:
- **028a480 and ca1aece**, every site in DSPs. ca1aece gives the worst setup slack into and out of each site's DSPs (`ooc_impl.tcl`, `reports/ooc_dsp_sites.txt`). 028a480 gives only the failing endpoints at the DSPs.
- **b45c763**, with the first default (the sites that passed in both, memory R included). This is a second sample for the kept sites.

A site stays in DSPs only if it passed in every run that had it in DSPs:

| Bit | Site | 028a480 (in) | ca1aece in / out | b45c763 in / out | Default |
|---|---|---|---|---|---|
| 0, 1 | D slices, l1d 0 and 1 | −0.43, −0.41 | −0.15, −0.27 / +3.9 | | fabric |
| 4, 5 | D slices, l1i 0 and 1 | −0.58, −0.72 | −0.54, −0.56 / +3.9 | | fabric |
| 8, 9 | D slices, mmio 0 and 1 | −0.99, −0.83 | −0.66, −0.43 / +3.9 | | fabric |
| 16, 17 | A slices, L2 banks 0 and 1 | −0.41, −0.41 | +0.15 / +0.59, 0.00 / +0.01 | | fabric |
| 18 | A slice, boot ROM | −0.02 | +1.41 / +2.77 | | fabric |
| 19 | A slice, device bus | pass | +1.34 / +1.94 | +0.54 / +1.79 | **DSP** |
| 20 | A slice, error responder | −0.22 | +0.13 / +2.81 | | fabric |
| 24, 25 | C slices, banks 0 and 1 | pass | +0.52 / +1.77, +1.35 / +3.04 | +1.17 / +2.29, +1.73 / +2.38 | **DSP** |
| 28, 29 | B slices, cores 0 and 1 | −1.41, −1.55 | −0.79, −0.80 / +3.9 | | fabric |
| 32, 37 | memory AR, ports 0 and 1 | −1.17, −1.36 | −0.90, −0.67 / +3.9 | | fabric |
| 33, 38 | memory AW, ports 0 and 1 | pass | −0.05, +0.19 / +3.9 | | fabric |
| 34, 39 | memory W, ports 0 and 1 | pass | +1.13, +0.41 / +3.9 | +0.58, +0.50 / +3.9 | **DSP** |
| 35, 40 | memory R, ports 0 and 1 | pass | +2.05 / +0.003, +2.76 / +1.29 | +2.18 / −0.16, +2.11 / +0.05 | fabric (cd1f584) |
| 42, 43 | L2 R slices, banks 0 and 1 | pass | +0.60 / +1.00, +0.37 / −0.37 | | fabric |

The default is `64'h84_0308_0000`, with 21 DSPs at the sites, plus 4 for the ACLINT's compares at `st` and 1 in the UART. With the first default, b45c763's two placements compare like this (memory R in DSPs; it is about 138 LUTs and 274 FFs of the gap):

| b45c763, st | LUTs | FFs | DSP | WNS | TNS (failing endpoints) |
|---|---|---|---|---|---|
| all fabric | 19,925 | 19,192 | 5 | −0.983 ns | −1,415 ns (3,540) |
| the first default | 19,441 (−484) | 18,097 (−1,095) | 32 | −0.858 ns | −961 ns (2,771) |

- Neither run's worst path is a DSP site. Both are the L2's AR handshake or S2, as in the all-fabric runs.

**The S2 and probe work** (st, the default `UNCORE_DSP`, two placements of each design: Vivado's default and `ExtraTimingOpt`, set by `TG_OOC_PLACE`. Vivado is deterministic, so the second placement is the second sample):

| Commit | Run | LUTs | FFs | DSP | WNS | TNS (failing endpoints) |
|---|---|---|---|---|---|---|
| db8d1bf | the one-hot MSHR way, the AR slice on (DR-143); default placement | 19,589 | 18,765 | 26 | −0.720 ns | −395 ns (1,673) |
| db8d1bf | the same, `ExtraTimingOpt` | 19,684 | 18,779 | 26 | −0.493 ns | −140 ns (946) |
| 96aa4bc | + the tree picks; default placement | 19,641 | 18,742 | 26 | −0.961 ns | −736 ns (2,313) |
| 96aa4bc | + `B_SLICE` on (a reserve item, [soc.md](../spec/soc.md)); default placement | 19,579 | 18,894 | 26 | −0.603 ns | −295 ns (1,271) |
| 498aaa1 | + the directory written at S3 alone; `ExtraTimingOpt` | 19,828 | 18,840 | 26 | −0.812 ns | −466 ns (1,659) |
| 2dc6eba | + the directory written at S3, the victim pick and its consequences, the probe flags' enables; default placement | 19,935 | 18,850 | 26 | −0.263 ns | −43 ns (569) |
| 2dc6eba | the same, `ExtraTimingOpt` | 19,928 | 18,840 | 26 | −0.460 ns | −203 ns (1,105) |
| c972c58 | + the allocation's probes and Grant cap selected late, each MSHR's next probe agent (0449256), the trace's stop count; default placement | 19,928 | 18,841 | 26 | −0.499 ns | −337 ns (1,614) |
| c972c58 | the same, `ExtraTimingOpt` | 19,959 | 18,850 | 26 | −0.517 ns | −221 ns (1,244) |
| 5d9fef2 | 0449256 reverted (the RTL is 2dc6eba's plus the trace's stop count); default placement | 19,978 | 18,844 | 26 | −0.333 ns | −82 ns (864) |
| 5d9fef2 | the same, `ExtraTimingOpt` | 20,094 | 18,831 | 26 | −0.573 ns | −414 ns (1,894) |
| c91ac34 | + the response engine's shape in flip-flops, the probe pick made a cycle ahead; default placement | 19,979 | 18,961 | 26 | −0.322 ns | −33 ns (413) |
| c91ac34 | the same, `ExtraTimingOpt` | 19,998 | 18,940 | 26 | **+0.030 ns** | 0 (0) |

- db8d1bf's worst paths were S2 into the directory RAM's pins (−0.49, 400 endpoints in the `ExtraTimingOpt` run) and the probe flags; 2dc6eba's are the probe loop (`m_psent`, `pr_ptr_q`: about 55% of the worst 150 endpoints), S2 into the MSHR flags (`m_ppend`, `m_vtag`, `m_grant_t`: about 30%), the data array's URAM cascade inputs and the directory's read address, at −0.21 to −0.46 ns. The directory's pins no longer fail. c972c58's `ExtraTimingOpt` run fails at −0.52 ns in the data array's cascaded read address (the victim read-out's pick, its MSHR's set and way from the LUTRAM, then three URAMs of cascade), −0.49 ns in the probe loop and −0.48 ns at the L2's error flag: within the two placements' spread of 2dc6eba, with no single structure leading.
- The directory written at S3 alone moved S2's failing endpoints from the RAM's pins to the MSHR state (`sm1_q` → `ms`, 17 levels, −0.812 ns in that run) and left the probe flags (−0.695 ns) worst after it; the next two commits, which cut exactly those, bring the same placement settings to −0.460 ns. One sample each, so the attribution is approximate.
- **c91ac34 closes 200 MHz in the `ExtraTimingOpt` placement** (+0.030 ns, no failing endpoint), the first uncore run that does. Its default placement fails at −0.322 ns, TNS −33 ns over 413 endpoints: the L2 error flag (−0.32), the allocation's entry into the probe pick register (−0.30), the D channel's cross-bank credit (a bank's D queue and output arbiter, the crossbar's per-initiator D arbiter, the other bank's ready: −0.30) and the victim read-out's pick into the data array's address (−0.25).
- **The spread between runs.** 2dc6eba and 5d9fef2 differ only by the trace's stop count, a few LUTs off the L2, yet measure −0.263 / −0.460 and −0.333 / −0.573 ns. c972c58 and 5d9fef2, with and without 0449256, cross over between the two placements. So a single design varies by 0.1–0.2 ns per placement setting, and the two settings differ by 0.2–0.5 ns: below about 0.2 ns, two samples per design don't separate two designs. 0449256 was reverted for its structure (per-way logic that bought no level), not for its slack.
- The tree picks' run lost 0.24 ns against its base in the same placement, while the S2 path, which they don't touch, lost as much: placement, not the picks ([l2.md](../spec/l2.md) §Timing).
- In the budget flow (cd1f584, `st`), all fabric is 19,604 LUTs, 18,740 FFs and 5 DSPs, and the default is 19,231 LUTs, 17,973 FFs and 26 DSPs: the default saves 373 LUTs and 767 FFs for its 21 site DSPs. Every site in DSPs saved about 1,390 at 44767a1, so the per-site check gives back about 1,020 LUTs to hold 200 MHz at the sites.

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
