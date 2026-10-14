# Tanager: per-unit LUT budgets

*Plan §8.5, "Process": every configuration has per-unit LUT budgets in CI. This page sets them and describes the nightly check that holds the RTL to them.*

| | |
|---|---|
| Status | Proposed, 2026-10-13 (spikes track) |
| Target | v1 (`smt2`) dual-core at ≤ 88% of the XCK26 after the §8.5 levers: ≤ 103K of 117,120 LUTs (§8.5's fill limit, measured by spike S6) |
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
| Integer execution | 16 (multiplier) | — |
| LSU | — | 9 (D$ data 8, LSQ data) |
| MMU | — | 2 (L2 TLB) |
| FPU | 32 (measured) | 0.5 (seed ROM) |
| **Core** | **66 / 84** | **42.5** |
| Uncore | — | 18 |

- **LUTRAM and flip-flops** have budgets only where a unit is measured: the scheduler (LUTRAM 300 / 310, flip-flops 7,540 / 10,000 for st / smt2) and the FPU (flip-flops 3,450). Each is the measurement plus about 10%.
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
  | Radix-4 divide/sqrt (`FDIV_RADIX4`, the D17 fallback) | 1.4K | −2.4% suite IPC |
  | SMT2 window at ROB 64 (§8.5 contingency) | ≈1.3K in the scheduler, plus ROB storage | −1.5% throughput |

- **The scheduler and FPU budgets are below today's measurements.**
  - The scheduler: 8,350 against 8,895 at smt2, and 6,030 against 6,425 at st. That is R14, about 6%, applied to it as to every unit.
  - The FPU: 6,800 against 7,622, from R5 (being built) and R14.
  - Until that work lands, the nightly check reports both as over budget. That is the gap it is there to track.
- **The 3-wide configurations** (`st_w3`, `smt2_w3`) are tracked without budgets until the v2 re-plan (plan §8.5: v2 lands at 97–109% after levers).

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
| e256b0e | L2: the same-set rule at S0 replaces the directory's write history | 22,405 | 23,050 | 18,854 | 27 |
| 059a572 | interconnect: each arbiter over the ports that can reach it | 20,884 | 21,533 | 18,811 | 27 |
| **budget** | | **11,300** | **10,800** | | **18** |

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

**What no-IPC work is left** (estimates):

| Item | LUTs | Other |
|---|---|---|
| Trace streaming replaces the ring ([uncore-trace.md](../spec/uncore-trace.md)) | +2.2K stream, −0.45K ring, −0.5K host readback = **+1.25K** | block RAM 27 → 18; host bridge −1.4K FFs |
| Host bridge register file and read multiplexer | −0.3K | |
| L2 remaining small items | −0.3K | |
| **Landing (smt2), feature set as today plus streaming** | **≈ 22K** | 18 RAMB36 |

No-IPC work cannot reach 10.8K: the floor is set by features, the clock and the MSHRs. These options need a coordinator decision; their order follows D18:

| Option | Saves (smt2) | Cost |
|---|---|---|
| Release build without the latency injectors and trace streaming (build parameters; verification and latency builds keep them) | ≈ 3.7K | no lockstep or latency sweeps on release bitstreams |
| Remove the interconnect and memory-port register slices | ≈ 2.4K | timing: 200 MHz at risk; per D18 a clock down to about 180 MHz comes before IPC cuts |
| L2 MSHRs 24 → 16 per bank | ≈ 2.0K | IPC at the long latency points (the last resort under D18) |
| L2 MSHRs 24 → 8 per bank | ≈ 3.9K | IPC (more) |
| Raise the uncore budget to the measured floor (≈ 18K for a release build) | — | about 7K over 10.8K: v1 lands at about 94% of the XCK26 (110K) instead of 88%, unless the core or the reserve gives it back |
