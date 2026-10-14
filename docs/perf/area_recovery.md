# Tanager area-recovery study: the model side

*Plan §8.5 and D18, triggered by spike S6. This study answers four questions:*
1. *What does each IPC-costing lever cost in IPC, ranked by IPC lost per LUT saved?*
2. *How does a lower clock compare with trimming?*
3. *Can each issue queue's readiness cover only the wakeup columns it can depend on?*
4. *What do v1 and v2 look like on the XCK26?*

| | |
|---|---|
| Status | Study for review. Input to plan §4.6, §8.2 and §8.5, to the per-unit budgets ([budgets.md](budgets.md)) and to the feature ledger. |
| Date | 2026-10-14 |
| Model | `tgsim` model version 3 with SMT2 (`SMT_VERSION` 1); suite revision 2; rv64gc built with GCC 15.2. The new options are off by default and change no earlier result (§2.2). See [`perfmodel/README.md`](../../perfmodel/README.md). |
| Configurations | v1 = `smt2`, the first release (plan §6.5, D15); v2 = `smt2_w3` (SMT2 study §9, plan rule 12) |
| Inputs | Spike results: [spikes.md](spikes.md) §4, §5, §8, §10. The nightly budget run: [budgets.md](budgets.md). The FPU track: [fpu.md](../spec/fpu.md). |
| Generated data | `perfmodel/results/area_tables.md` (every table, by pair group and latency) and `perfmodel/results/area_recovery.json`. `perfmodel/scripts/area.py` reproduces both (§2.5). |

Every IPC figure here is a model result. LUT savings are measured where a spike or track measured them, and estimated otherwise. Each table names its source.

**Names (D16).**
- **ST:** the single-thread bring-up configuration.
- **v1:** the 2-wide SMT2 first release.
- **v2:** SMT2 + 3-wide.
- **st_w3:** 3-wide without SMT2.

**Real RTL, first numbers (2026-10-14).** The first synthesis of the real core (`st`, M3 features on, no FPU) is **88K LUTs against its 38.2K budget**.
- **Where the excess is:** the core track traces it to simulation-first structures it is replacing with no-IPC fixes. These are the PMP checkers, the D$ state, the rename tables, the TLB CAMs and the LSU queues (§7.3).
- **Already measured:** the FPU is 5,889 LUTs after a no-IPC pass (budget 6,800), and the scheduler is 8.9K at smt2.
- **How to read this study:**
  - its verdicts are stated against the per-unit budgets of [budgets.md](budgets.md), not as absolute SoC totals;
  - **no IPC-costing lever should be chosen until the real core's units are re-measured after its area pass (D18)**.

---

## 1. Summary

### 1.1 Findings

1. **One exact scheduler change recovers most of the overrun at no IPC cost: wakeup tags (§5).**
   - **Which producers need ROB columns.** A row's readiness has one column per ROB entry (80 at v1, 96 at v2), and those columns are about half of the scheduler's LUTs. The dependency census shows that rows wait on them only for multi-cycle fixed-latency producers: MUL and complex Zbb, the FMA and FP misc/move ops, and serialised ops.
     - MX already covers every 1-cycle producer: 0 waits on a ROB column, out of 453M sources at v1.
     - LLTs cover loads, divides and long FP ops.
   - **The change.** A pool of 16 wakeup tags for those producers replaces the 80–96 ROB columns.
   - **IPC: exactly zero** at 16 tags, at 30/120/250 cycles, on all 42 pairs, the single-thread suite, v1, v2 and ST. Not one workload or pair moves. There were 0 tag stalls in 252 pair runs.
   - **Saving (estimated from the S2 fit, net of the pool's own logic):**

     | Configuration | Per core | Per SoC |
     |---|---|---|
     | v1 | 2.7–3.0K | 5.4–6.0K |
     | v2 | 4.7–5.0K | 9.4–10.0K |
     | ST | ≈1.0–1.2K | — |

   - **Window size no longer sets scheduler LUTs.** With tags, a ROB entry costs only its storage.
2. **Two planned levers are free in the model, and two v2 changes cost under 0.1%.**

   | Lever | Saves per core | Throughput / single thread @120 |
   |---|---|---|
   | R10, shared checkpoints | 0.5K | −0.01% / 0.00% |
   | R9, strict store forwarding | 0.2–0.3K | −0.03% / −0.00% |
   | R12, asymmetric third decoder (v2) | 0.15–0.25K | −0.03% / −0.06% |
   | Completion buffer 16 → 8 (v2) | 0.06K | −0.06% / 0.00% |

   R12 and the completion buffer are just past the 0.05% "free" bound, and both pass the reverse rule comfortably.

   [budgets.md](budgets.md) assumes R9 and R10; both hold. R6 (set-associative TLBs) cannot be modelled, because `tgsim` has no MMU.
3. **Most IPC-costing levers fail the reverse rule (§3, §4).**
   - **ALU queues 10 → 8 cost 2.6% throughput at v1** for 0.9K LUTs. They pass at v2 only without tags.
   - **R11 (shared register-file ports) fails:** −0.62% throughput and −1.66% single thread, plus 0.24 ns worse timing in S3.
   - **R13 (simple third ALU) fails:** −1.53% single thread.
   - **The LQ, SQ, STA-queue and LLT cuts all fail.**
   - **ROB 64 (v1) and ROB 80 / v1's window (v2) pass without tags, but not with them.** Tags remove the scheduler columns those cuts were saving.
   - **What passes and stays in reserve:** the FP-queue and LD-queue trims (≤ 0.3%), then the radix-4 divider (−0.4–0.8% throughput, −2.4–2.6% single thread).
4. **Readiness by thread (banked rows) is exact but not free** (§5.3).
   - **With SMT2 on,** no row ever waits on the other thread (0 sources). But binding rows to threads acts as a 50% issue-queue cap: −2.6% throughput at v1.
   - **With SMT off,** 1–4% of waits cross the two ROB halves. Steering around them costs 8–10% single-thread IPC.
   - **Rejected.** Wakeup tags save more, at no cost.
5. **v1 fits at 200 MHz with full structures, provided every unit meets its budget** (§7.1, §7.3).
   - **With the free levers:** 92–104K LUTs on the spikes' 99–110K projection, or 97–100K on the budgets' 103–105K basis. The 88% ceiling (103K) is crossed only at the very top of the range, by ≤1.2K.
   - **No IPC-costing lever and no lower clock is needed** in any other outcome.
   - **IPC first:** with tags, the window step the SMT2 study rejected (ROB 96, LQ 32, SQ 24) adds +1.84% throughput and +0.69% single thread for about 0.7K per core, and still fits.
6. **v2 still does not fit at 200 MHz across its whole range, but the gap shrinks from 10–25K per SoC to 2–18K** (§4.4, §7.2).
   - **With tags and the free levers:** 105–121K (90–103%). R11 and R13 are dropped, since they fail the rule.
   - **Even at a lower clock, v2 is worth more than v1 at 200 MHz.** With the free levers it has +21.7% throughput and +15.0% single thread over v1 at the same clock. At 190 MHz that is still +15.6% throughput and +9.3% single thread; at 180 MHz, +9.5% and +3.5%.
   - **v2's re-plan:**
     1. wakeup tags and the free levers;
     2. 180–190 MHz, if a fill test at that clock supports 92–96% fill;
     3. only then the passing radix-4 or 8-row ALU queues, which also buy S2 timing margin.
   - **st_w3** (3-wide without SMT2) fits easily, but gives up 15–22% of v1's throughput.
7. **The frequency trade** (§6). v1 barely has to choose. The free levers fit it at 200 MHz in almost every outcome; at the very top of its range, 0.7K of trims (−0.3% IPC) and a few MHz settle it. v2 does have to choose.
   - **In the lower fifth of its range,** radix-4 and 8-row ALU queues (≈−2.7%) hold 200 MHz.
   - **Above that,** holding 200 MHz takes every modelled cut (≈−7% throughput, −8% single thread) or more. That is worse than 190 MHz even by IPC × Fmax, so v2 belongs at 180–190 MHz, as D18 asks.

### 1.2 What the levers add up to

Per core, in rank order on top of wakeup tags, each step simulated as a whole. The share is of the core after the planned levers: v1 45.6K, v2 53.6K.

| Step | v1: saves | v1: throughput / single thread @120 | v2: saves | v2: throughput / single thread @120 |
|---|---|---|---|---|
| Wakeup tags (16) | 2.70–3.00K | 0.00% / 0.00% | 4.68–4.98K | 0.00% / 0.00% |
| + R10, R9 | 3.40–3.80K | −0.04% / −0.00% | 5.38–5.78K | −0.01% / 0.00% |
| + v1: FP queue 8, LD queue 4. v2: R12, completion buffer 8 | 3.74–4.14K | −0.21% / −0.29% | 5.59–6.09K | −0.10% / −0.06% |
| + radix-4 divide/sqrt | 5.15–5.55K | −0.66% / −2.70% | 7.00–7.50K | −0.77% / −2.62% |

### 1.3 Decisions for you

| # | Decision | Recommendation |
|---|---|---|
| AR-1 | Wakeup tags in the scheduler (plan §4.6) | **Adopt, for every configuration, with 16 tags.** No IPC cost anywhere; 24 tags give extra margin for dense FP code at +0.4–0.5K per core. First, confirm the LUT saving with one S2 build at 40 wakeup columns (§5.2); the design can be built in parallel. Proposed plan text is in §8.2. |
| AR-2 | R9 and R10 | **Adopt.** Both are free in the model, and [budgets.md](budgets.md) already assumes them. |
| AR-3 | v1 | **Keep D15's structures. Do not use any IPC-costing lever.** With AR-1 and AR-2, the scheduler comes in ≈2.5–2.8K under its budget, so v1 meets 103K if the other units meet theirs (§7.3). That is 92–104K on the planning projection, at 200 MHz (§7.1). Spend the headroom on IPC under the rule: the window step to ROB 96 / LQ 32 / SQ 24 gives +1.84% throughput for ≈0.7K per core. |
| AR-4 | v2 re-plan | **Keep smt2_w3** with wakeup tags, R9, R10, R12 and completion buffer 8. Drop R11 and R13. Target 180–190 MHz (D18 step 2), and measure the fill limit at that clock (AR-5). Hold radix-4 and 8-row ALU queues in reserve, in that order, and choose between them only after AR-7. Keep st_w3 as the fallback only if the fill test fails. |
| AR-5 | Fill test at 180–190 MHz | **Extend S6:** run v2's core (with tags) at 90%, 93% and 96% fill, timed at 5.56 ns. It decides v2's clock and whether v2 needs any lever beyond the free ones. |
| AR-6 | Reserve order (D18 step 3) | **v1:** FP queue 8, LD queue 4, radix-4. **v2:** radix-4, then 8-row ALU queues. Everything else fails the reverse rule (§3, §4). The order is a ranking, not a decision: none of these is used before AR-7. |
| AR-7 | Re-measure the real RTL | **After the core track's no-IPC area pass** (the `st` core is at 88K against its 38.2K budget), re-measure each unit against [budgets.md](budgets.md) and redo §7 with the measured numbers. Only then choose an IPC-costing lever, if one is still needed (D18). The radix-4 saving must be re-measured too: its 1.41K predates the FPU's no-IPC pass. |

---

## 2. Method

### 2.1 Configurations and metrics

| | v1 (`smt2`) | v2 (`smt2_w3`) |
|---|---|---|
| Width; ALUs | 2-wide; 2 | 3-wide; 3 |
| ROB | 80, static halves of 40 | 96, halves of 48 |
| LQ / completion buffer / SQ | 24 / 8 / 20 | 32 / 16 / 20 |
| Long-latency tags (LLTs) | 24, shared | 24, shared |
| Issue queues A0 / A1 (/ A2) / LD / STA / FP | 10 / 10 / 6 / 4 / 10, shared, ≤ 75% per thread | 10 / 10 / 10 / 6 / 4 / 10 |
| Checkpoints | 4 per thread | 4 per thread |
| Source | `results/smt2_rv64gc.json`, `greedy_bundles.final` | `greedy_w3.final` |

**Base results:**

| Configuration | WS_ref @30 / @120 / @250 | Single-thread suite IPC @30 / @120 / @250 | CoreMark/MHz |
|---|---|---|---|
| v1 | 1.359 / 1.428 / 1.446 | 1.256 / 0.991 / 0.828 | 5.31 |
| v2 | 1.668 / 1.739 / 1.746 | 1.445 / 1.140 / 0.951 | 6.11 |
| ST, for reference | 1.000 | 1.227 / 0.967 / 0.813 | 5.31 |

**How each lever is measured.** It is applied alone to each configuration it fits, at 30, 120 and 250 cycles of DRAM latency; 120 is the decision point. There are two metrics:
- **Throughput (WS_ref):** weighted speedup over the SMT2 study's 42 thread pairs, against ST running one program at a time. It is the geometric mean of three group means: memory + memory, compute + compute, and mixed.
- **Single-thread suite IPC:** the same core with SMT off (one hart; ROB, LQ, SQ and completion buffer merged). This is the run-time SMT-off mode (D16), and the mode that carries CoreMark's D11 target.

**A lever's IPC cost** is the larger of the two losses at 120 cycles. Both modes ship, so a lever must not buy one at the other's expense.

### 2.2 Model support

New `tgsim` options, all off by default:

| Option | Lever | What the model does |
|---|---|---|
| `smt_ckpt_shared` | R10 | the 4 checkpoints are one pool for both threads |
| `fwd_strict` (existing) | R9 | a load forwards only from a store with the same address and size; any other overlap waits for the store to drain |
| `rf_share_a2` | R11 | ALU2 reads through the STA port and the shared port, as S3's `RF3=1` build does. When an STA pick or an FP pick with an integer source takes the port, ALU2's pick waits a cycle. Store data yields to ALU2: it can wait in the SQ. |
| `dec_full` | R12 | decode slots from this index on take only ALU, branch, jump, multiply/divide and integer load/store. `dec_full=2` is the asymmetric third decoder. |
| `alu3_simple` | R13 | ALU2 executes add/sub, logic, compare, LUI/AUIPC and Zba shift-adds; every other ALU op steers to ALU0/1 |
| `iq_bank`, `iq_bank_llt` | banked readiness | every issue queue is two banks of rows, each waking only on its own half of the ROB (and of the LLTs) (§5.3) |
| `wake_tags` | wakeup tags | multi-cycle fixed-latency producers take one of N tags at dispatch, and rows wake on the tags instead of on ROB columns (§5.2) |
| `census` | (measurement) | classifies every dispatched source by what its row would wait on (§5.1) |

**Unchanged behaviour with the options off.** Checked with the final binary:
- **Single thread:** 9 runs against the M1 binary are bit-identical (three presets, all three latencies).
- **SMT2:** 42 cached pair runs (v1 freeze, v1 and v2, at 120 and 250 cycles) re-simulate identically.
- **So `MODEL_VERSION` stays 3,** and every earlier result stands.

### 2.3 LUT savings

Per core. The source of each number is given with it.

**The scheduler** (every issue queue, the woken vector W, the wakeup delay lines) is fitted to five measured MX builds:
- S2's st (6,425), smt2 (8,895), smt2_w3 (12,515) and smt2_w3 with 8-row ALU queues (10,986);
- the nightly budget run's st_w3 (8,842).

> LUTs ≈ 1.369 × rows × wakeup columns + 1.404 × rows × MX columns + 338 × ALU queues + 1.26K

- **Terms:** rows are every queue's rows (40 at v1, 50 at v2: `tg_cfg_smt2_w3.sv`). Wakeup columns are the ROB entries plus the LLTs (104 at v1, 120 at v2). MX columns are the ALU-queue rows (20 and 30).
- **Fit quality:** every build within 0.14K. The model also predicts the measured 1.53K saving of 8-row ALU queues at v2 as 1.61K.
- **Robustness:** six other model forms fitted to the same builds give a wakeup-tag saving of 3.5–4.05K at v1 and 5.3–5.6K at v2, before the pool's logic. That is 0–16% above this fit at v1, and within 3% of it at v2.
- **One correction to spikes.md §10:** smt2_w3 has 50 rows, not 46.

**Window storage outside the scheduler:**
- ROB status and payload, about 10 LUTs per entry (estimate; R7 moves the commit-time payload to BRAM);
- the LLT pool, about 10 per tag;
- the LQ CAM 40, the SQ 50, the completion buffer 8 and a checkpoint 125 per entry, as in `scripts/report.py`.

**Measured elsewhere:**
- R11: 0.74K (spike S3);
- the radix-4 divide/sqrt: 1.41K, plus 26 DSPs and a BRAM18 freed (FPU track). This was measured before the FPU's no-IPC pass, which brought the whole FPU to 5,889 LUTs, so it must be re-measured (§7.3).

**Estimates:**
- R9 0.2–0.3K, R12 0.15–0.25K and R13 0.3–0.5K (plan §8.5);
- the wakeup-tag pool's own logic, +0.5–0.8K (§5.2);
- banked queues: credited at 60–100% of the fit's halving, for their steering logic.

**Percentages** are of the core after the planned levers: the midpoint of each SoC projection, minus the 13.3K uncore, over two cores. That is 45.6K for v1 (99–110K) and 53.6K for v2 (113–128K).

### 2.4 Rule and ranking

- **The reverse acceptance rule** (plan §8.5): a lever qualifies if its LUT saving (% of the core) is at least its IPC cost (%).
  - At v1, 1K LUTs is 2.19% of the core, so a lever qualifies at up to 2.19% IPC lost per 1K LUTs saved. At v2 the limit is 1.87%.
- **Free:** a lever is called free if both of its losses are within 0.05% at 120 cycles.
- **Under D18,** a lever that qualifies but is not free is used only after the free tricks and a lower clock (§6, §7).
- **Combinations are greedy.**
  - Each step adds the qualifying lever with the least IPC lost per 1K LUTs.
  - Its saving is recomputed on top of the levers already taken. For example, once rows wake on tags, a smaller ROB saves only its storage.
  - Each step is simulated as a whole.

### 2.5 Reproducing

```bash
python3 perfmodel/scripts/area.py
```

```bash
python3 perfmodel/scripts/area.py --combos
```

```bash
python3 perfmodel/scripts/area.py --census
```

```bash
python3 perfmodel/scripts/area.py --tables
```

- **What they run:** in order, every lever alone; the combinations and options; the census; then the tables. About 3 hours on 8 threads from an empty cache.
- **Caching:** pair runs are cached in `results/smt/`, single-thread runs in `results/dse/`.

---

## 3. v1: the levers (Part 1)

Ranked by IPC lost per 1K LUTs saved at 120 cycles. The limit is 2.19% per 1K. Throughput is WS_ref; "single" is single-thread suite IPC. Latencies are 30 / 120 / 250 cycles.

| Rank | Lever | Saves per core | Throughput | Single | Loss per 1K @120 | Verdict |
|---|---|---|---|---|---|---|
| 1 | **Wakeup tags, 16** (instead of 80 ROB columns) | 2.70–3.00K | 0.00 / 0.00 / 0.00% | 0.00 / 0.00 / 0.00% | 0.00% | **free** |
| — | wakeup tags, 24 | 2.27–2.57K | 0.00% | 0.00% | 0.00% | free |
| — | wakeup tags, 12 | 2.92–3.22K | 0.00% | −0.05% (st −1.7%, nbody −0.9%) | 0.01% | free, no margin |
| 2 | **R10:** 4 checkpoints shared by the threads | 0.50K | −0.02 / −0.01 / −0.01% | 0.00% | 0.02% | **free** |
| 3 | **R9:** forwarding only from same-address, same-size stores | 0.20–0.30K | −0.02 / −0.03 / −0.04% | −0.00% | 0.12% | **free** |
| 4 | FP queue 10 → 8 | 0.34K | 0.00% | −0.06% | 0.18% | passes |
| 5 | checkpoints 4 → 2 per thread (instead of R10) | 0.50K | −0.08 / −0.04 / −0.03% | −0.12% | 0.24% | passes; R10 is better |
| 6 | LD queue 6 → 4 | 0.34K | −0.17 / −0.15 / 0.00% | −0.20% | 0.60% | passes |
| 7 | FP queue 10 → 6 | 0.68K | 0.00% | −0.60% | 0.88% | passes (E5: dense FP −12.7%) |
| 8 | ROB 80 → 64 | 1.04K | −0.94 / −1.54 / −1.96% | −0.49 / −0.26 / −0.18% | 1.49% | passes; **fails with tags** (saves 0.16K) |
| 9 | radix-4 divide/sqrt (D17 fallback) | 1.41K | −0.28 / −0.42 / −0.58% | −2.42% | 1.72% | passes |
| 10 | ALU queues 10 → 6 | 1.72K | −2.83 / −4.05 / −4.29% | −3.25% | 2.35% | fails |
| 11 | LLTs 24 → 16 | 0.52K | −0.62 / −1.34 / −1.20% | −0.16% | 2.58% | fails |
| 12 | ALU queues 10 → 8 | 0.88K | −1.84 / −2.63 / −2.73% | −1.31% | 2.97% | fails |
| 13 | SQ 20 → 16 | 0.20K | −0.47 / −0.70 / −0.70% | −0.24% | 3.52% | fails |
| 14 | banked readiness (§5.3) | 1.65–2.75K | −1.99 / −2.61 / −2.97% | −8.21% | 3.73% | fails |
| 15 | STA queue 4 → 2 | 0.34K | −0.15 / −0.25 / −0.18% | −1.33% | 3.91% | fails |
| 16 | SQ 20 → 12 | 0.40K | −1.22 / −1.72 / −1.73% | −0.79% | 4.30% | fails |
| 17 | banked readiness and LLTs | 2.05–3.41K | −2.64% @120 | −12.21% | 4.48% | fails |
| 18 | LQ 24 → 16 | 0.32K | −1.91 / −2.33 / −2.40% | −1.41% | 7.30% | fails |

**What the losses are.**
- **The window and the ALU queues bind on memory pairs.**
  - **ALU queues 10 → 8** cost 5.0% on memory + memory pairs and 2.9% on mixed pairs (compute pairs 0.0%): they hold the dependants of misses, as M1 found.
  - **ROB 64** costs 2.4% / 2.2% on the same groups. **LQ 16** costs 4.5% on memory pairs, **LLTs 16** 3.6%.
  - The per-group tables are in `results/area_tables.md`.
- **The FP queue binds only on dense FP.** The suite does not see the FP-queue trims; exception E5 (blocked matmul −12.7% at 6 rows) still applies.
- **The radix-4 divider costs single-thread FP divide and sqrt:** nbody −47% (its region is mostly sqrt and divide, README "Scoring"), st −43%, minver −11%, wikisort −5%. That is 2.4% of suite IPC; throughput loses only 0.4% (mixed pairs −1.0%).

**Greedy combination** (each step on top of the previous ones; saving per core, then throughput / single thread @120):
1. Wakeup tags: 2.70–3.00K, 0.00% / 0.00%.
2. R10: 3.20–3.50K, −0.01% / 0.00%.
3. R9: 3.40–3.80K, −0.04% / −0.00%.
4. FP queue 8: 3.57–3.97K, −0.04% / −0.08%. This step saves only 0.17K: with tags, a row costs half as much.
5. LD queue 4: 3.74–4.14K, −0.21% / −0.29%. Again 0.17K.
6. Radix-4: 5.15–5.55K, −0.66% / −2.70%.

Nothing else qualifies once the tags are in. ROB 64 drops out, because its saving falls from 1.04K to 0.16K.

---

## 4. v2: the levers and the re-plan (Parts 1 and 4)

### 4.1 The levers

The limit is 1.87% per 1K LUTs.

| Rank | Lever | Saves per core | Throughput @30 / @120 / @250 | Single @120 | Loss per 1K @120 | Verdict |
|---|---|---|---|---|---|---|
| 1 | **Wakeup tags, 16** (instead of 96 ROB columns) | 4.68–4.98K | 0.00 / 0.00 / 0.00% | 0.00% | 0.00% | **free** |
| — | wakeup tags, 24 / 12 | 4.13–4.43K / 4.95–5.25K | 0.00% / −0.00% | 0.00% / −0.03% (st −1.2%) | 0.00% / 0.01% | free |
| 2 | **R9** | 0.20–0.30K | −0.00 / +0.01 / +0.01% | 0.00% | 0.00% | **free** |
| 3 | **R10** | 0.50K | −0.01% | 0.00% | 0.01% | **free** |
| 4 | **R12:** third decoder for the common subset only | 0.15–0.25K | −0.12 / −0.03 / −0.01% | −0.06% | 0.31% | passes |
| 5 | FP queue 10 → 8 | 0.41K | 0.00% | −0.37% | 0.89% | passes |
| 6 | **Completion buffer 16 → 8** | 0.06K | −0.04 / −0.06 / −0.04% | 0.00% | 0.96% | passes |
| 7 | ALU queues 10 → 8 | 1.61K | −1.61 / −1.93 / −1.98% | −0.95% | 1.20% | passes; **fails with tags** (saves 0.95K) |
| 8 | ALU queues 10 → 6 | 3.12K | −3.20 / −3.94 / −4.22% | −2.36% | 1.26% | passes; fails with tags (1.80K) |
| 9 | v1's window (ROB 80, LQ 24, completion buffer 8) | 1.64K | −1.55 / −2.22 / −2.04% | −0.79% | 1.35% | passes; fails with tags (0.54K) |
| 10 | ROB 96 → 80 | 1.26K | −1.34 / −1.98 / −2.07% | −0.60% | 1.58% | passes; fails with tags (0.16K) |
| 11 | radix-4 divide/sqrt | 1.41K | −0.50 / −0.66 / −0.70% | −2.61% | 1.85% | passes |
| 12 | ROB 96 → 64 | 2.51K | −3.64 / −4.78 / −5.10% | −1.35% | 1.90% | fails |
| 13 | **R11:** ALU2 reads through the STA and shared ports | 0.74K | −0.69 / −0.62 / −0.64% | −1.66% | 2.24% | **fails**, and −0.32 ns in S3 |
| 14 | LQ 32 → 24 | 0.32K | −0.71 / −0.80 / −0.78% | −0.50% | 2.51% | fails |
| 15 | banked readiness | 2.60–4.34K | −2.40 / −2.79 / −2.44% | −9.52% | 2.74% | fails |
| 16 | LLTs 24 → 16 | 0.63K | −0.42 / −1.74 / −1.70% | −0.35% | 2.78% | fails |
| 17 | **R13:** simple third ALU | 0.30–0.50K | −0.07 / −0.09 / −0.10% | −1.53% | 3.83% | **fails** |

### 4.2 R11, R12 and R13

- **R11.** ALU2 loses its port pick in 3.7% of thread-cycles on the pairs and 2.3% of cycles single-threaded (slre: 22%). The single-thread cost (−1.66%) is nearly three times the throughput cost (−0.62%).
  - Most of it is Dhrystone, at −12.3%: its loop settles at 2.20 IPC instead of 2.51 once ALU2 cannot be relied on. The rest of the suite loses at most 3.3% (statemate).
  - It also fails on timing. S3 measured its build at −0.32 ns against −0.09 for replication, and it adds an arbitration term to the select loop, which S2 shows is the tighter loop. S3 already recommended replication for v2.
  - **Verdict: rejected.**
- **R12.** Decode stops at slot 2 in 3.5% of thread-cycles. The stopped op decodes a cycle later in slot 0 or 1, and the instruction queue absorbs the delay. Its cost is −0.03% throughput and −0.06% single thread.
  - The model keeps FP loads and stores out of slot 2, which is the conservative reading of "load/store".
  - **Verdict: passes.**
- **R13.** Its steering stalls are rare (0.4–0.5% of cycles). But with SMT off, every op ALU2 cannot take (shifts, Zbb, Zbs, min/max) queues on ALU0/1: −1.53% single thread.
  - Again almost all of it is Dhrystone, at −12.3%. It lands on exactly the IPC R11 gives (2.20): the same loop, bound the same way. Nothing else in the suite loses more than 1.2%.
  - **Verdict: rejected.**

### 4.3 Greedy combination

Each step is on top of the previous ones (saving per core, then throughput / single thread @120):
1. Wakeup tags: 4.68–4.98K, 0.00% / 0.00%.
2. R9: 4.88–5.28K, +0.01% / 0.00%.
3. R10: 5.38–5.78K, −0.01% / 0.00%.
4. R12: 5.53–6.03K, −0.04% / −0.06%.
5. Completion buffer 8: 5.59–6.09K, −0.10% / −0.06%.
6. Radix-4: 7.00–7.50K, −0.77% / −2.62%.

With tags in, nothing else qualifies. Once the ROB columns are gone, the 8-row ALU queues save 0.95K instead of 1.61K, and the window cuts about a third as much as before.

### 4.4 v2 re-plan options

Measured per core against v2 as planned. Throughput and single thread are at 120 cycles. The st_w3 rows run each pair one program at a time.

| Option | LUTs per core vs v2 | WS_ref @30 / @120 / @250 | vs v1 | Single thread | vs v1 |
|---|---|---|---|---|---|
| v2 as planned (`smt2_w3`) | 0 | 1.668 / 1.739 / 1.746 | +21.8% | 1.140 | +15.1% |
| **v2 + wakeup tags, R9, R10, R12, completion buffer 8** (the free set, §4.3 step 5) | **−5.59–6.09K** | ≈1.737 @120 (−0.10%) | **+21.7%** | 1.139 | **+15.0%** |
| ... + radix-4 (step 6) | −7.00–7.50K | −0.77% @120 | +20.9% | 1.110 | +12.0% |
| v2 + wakeup tags + R11, R12, R13 | −5.87–6.47K | 1.655 / 1.724 / 1.730 | +20.8% | 1.114 | +12.4% |
| ... + 8-row ALU queues | −6.82–7.42K | 1.630 / 1.693 / 1.697 | +18.6% | 1.103 | +11.3% |
| ... + v1's window | −7.36–7.96K | 1.610 / 1.663 / 1.670 | +16.5% | 1.095 | +10.5% |
| Without tags: R11–R13, 8-row ALU queues, ROB 64 / LQ 24 / CB 8 | −5.43–5.73K | 1.587 / 1.635 / 1.638 | +14.6% | 1.091 | +10.1% |
| st_w3, v2's window (ROB 96) | −4.5–9.3K (central −6.75K) | 1.200 / 1.207 / 1.182 | −15.4% | 1.140 | +15.1% |
| st_w3, v1's window (ROB 80) | −6.1–10.9K (central −8.4K) | 1.182 / 1.184 / 1.159 | −17.0% | 1.131 | +14.2% |
| st_w3, ST sizes (ROB 48) | −10.0–14.8K (central −12.25K) | 1.110 / 1.111 / 1.111 | −22.2% | 1.095 | +10.5% |
| v1 (2-wide SMT2) | about −10 to −12K (scheduler, window, 3-wide logic) | 1.359 / 1.428 / 1.446 | — | 0.991 | — |

**How to read the options.**
- **The free set keeps all of v2's gain over v1** (+21.7% throughput, +15.0% single thread) and saves 5.6–6.1K per core. No other option saves more per point of IPC.
- **The "without tags" row shows what the plan's own levers cost for a similar saving:** 5.4–5.7K per core, at −6.0% throughput and −4.3% single thread.
- **st_w3 removes the SMT2 logic** (4.5–9.3K per core) and gives up 15–22% of v1's throughput. Tags would save it a further ≈3.7K per core. It is the fallback if v2 cannot be placed at 180–190 MHz (§7.2).

---

## 5. Readiness only over the columns a queue can depend on (Part 3)

### 5.1 What a row can wait on: the census

A row's readiness is an AND-OR over the woken vector W. W has one column per wakeup ID:
- ROB entries plus LLTs: 104 columns at v1, 120 at v2;
- plus MX columns for the ALU-queue rows.

The rows × wakeup-columns term is two-thirds of the scheduler's LUTs, and the ROB columns alone are about half. So the question is which columns a row can ever need.

`census=1` answers it from the model. At dispatch, every source of every uop is classified by what its row would wait on:
- the value is ready;
- **MX:** a 1-cycle producer still in its ALU-queue row, or within the 2-cycle row hold after issue;
- a **ROB column:** any other producer that has not woken;
- an **LLT**;
- a producer of the **other thread**.

Two further counts are kept:
- ROB-column waits whose producer is a 1-cycle ALU op;
- MX or ROB-column waits on a producer in the other half of the ROB.

**v1, the 42 pairs at 120 cycles** (452.9M sources):

| Queue | Sources | Value ready | MX | ROB column | LLT column | Other thread | ROB column on a 1-cycle producer | ROB-column waits by producer |
|---|---|---|---|---|---|---|---|---|
| A0 | 204.7M | 66.4% | 14.2% | 3.3% | 16.1% | 0 | 0 | A1 92% (MUL, complex Zbb), FP 8% (FP → int) |
| A1 | 98.9M | 67.9% | 20.3% | 0.9% | 10.9% | 0 | 0 | A1 100% |
| LD | 84.0M | 71.0% | 22.6% | **0.0%** | 6.4% | 0 | 0 | — |
| STA | 36.0M | 83.5% | 16.1% | **0.0%** | 0.4% | 0 | 0 | — |
| FP | 29.3M | 43.7% | 0.0% | 5.5% | 50.8% | 0 | 0 | FP 100% |

**v1, single-thread suite.**
- **The pattern is the same:** ROB-column waits are 4.0% of A0's sources, 0.8% of A1's and 5.8% of the FP queue's, with none in LD or STA.
- **Waits across the two ROB halves** are 2.3% (A0), 2.7% (A1), 1.8% (LD), 1.5% (STA) and 1.0% (FP) of sources.

**v2 looks the same:** 0 cross-thread and 0 1-cycle ROB waits. ALU2's rows wait on ROB columns for 7.5% of their sources, all of them MUL or complex-Zbb results from A1. The full tables are in `results/area_tables.md`.

**Three facts follow.**
1. **No row ever waits on the other thread's producer:** 0 of 453M sources at v1 and 0 of 456M at v2. This holds by construction, since threads share no architectural registers, and the model finds nothing that creates one. With static ROB halves, a thread's rows need only its half's columns.
2. **No row ever waits on a ROB column for a 1-cycle producer** (0, everywhere).
   - MX names a 1-cycle producer while it is in its row and through the 2-cycle hold; after that, its value is ready.
   - Loads, divides and long FP ops wait on LLTs.
   - **Only multi-cycle fixed-latency producers use the ROB columns:** MUL and complex Zbb in IQ-A1, the FMA and FP misc/move ops in IQ-FP, and serialised ops. That is 2.0% of all sources.
   - The load and store-address queues never wait on a ROB column at all.
3. **With SMT off, 1–4% of waits cross the two ROB halves.** One thread's window spans both halves, so a static half-partition of the columns does lose real dependencies once SMT is off.

**So two exact partitions exist:**
- **by producer latency:** rows need columns only for multi-cycle fixed-latency producers;
- **by thread,** in SMT mode only: rows need only their thread's half.

A static column subset per queue, with ROB-index IDs, is not exact: any ROB entry can hold a producer for any queue. Hence §5.2 and §5.3.

### 5.2 Wakeup tags: exact and free

**Design.** Rows wake on a pool of N tags instead of one column per ROB entry:
- **Who takes a tag.** At dispatch, a uop takes a tag if it writes a register and is neither a 1-cycle ALU-queue op (MX covers it) nor an LLT producer. If no tag is free, dispatch waits.
- **What rows see.** N tag columns, the LLT columns and the MX columns. At v1 with N = 16, that is 40 wakeup columns instead of 104; at v2, 40 instead of 120; at ST, 32 instead of 64.
- **Wakeup.** The delay lines carry the tag instead of the ROB index (4 bits instead of 7).
- **Release.**
  - A tag is freed 2 cycles after its producer wakes, past the load-shadow cancel.
  - Its column is cleared in every row as it is freed. This is S2's column-clear variant, used here on 16 columns only; the LLT columns keep the guard.
- **No reused tag can be read.**
  - The ROB-indexed woken bit stays as a single vector of one bit per entry, as today. Dispatch reads it first, and waits on a tag only while that bit is clear.
  - The bit stays valid until commit, so a source whose producer has woken never waits on a tag that has since been reused.
  - The SQ's store-data check also reads that vector, and is unchanged.
- **Unchanged:** MX, the LLTs, the shadow cancel, flushes by ROB age and early retirement. Ops that retire early hold LLTs, not tags.

**Why it is exact:**
- 1-cycle producers have MX, then are ready;
- long producers have an LLT;
- every other producer holds a tag until it has woken.

The census finds no wait outside these three classes in any run. The only possible cost is a dispatch stall when the pool is empty.

**Measured cost:**

| Pool | Pair runs (126 per configuration) | Single-thread runs (99 per configuration) | IPC |
|---|---|---|---|
| 16 tags, v1 | 0 tag stalls | 78 stall cycles in 260M | **0.00%** everywhere: no workload or pair moves, at any latency |
| 16 tags, v2 | 0 tag stalls | 11,076 in 237M, almost all in st (5.4% of its cycles at 30 cycles, where the FMA pipe already limits it) | **0.00%** everywhere |
| 24 tags | 0 | 0 | 0.00% |
| 12 tags | ≤ 84 | up to 46% of st's cycles | st −1.2% to −1.7%, nbody −0.5% to −0.9%; suite −0.03% to −0.05% |
| 16 tags, ST | — | — | 0.00% at 30 / 120 / 250 |

**16 is the right size.** It never costs IPC in the suite. The FP queue (10 rows) plus the FMA and FP-misc pipelines bound the demand of dense FP code at about 17. 24 tags remove even st's stalls for +0.4–0.5K per core, which is worth keeping in mind when exception E5 (dense FP) is re-judged at M5.

**Saving and added logic, per core (estimates):**
- **Scheduler,** from the §2.3 fit at 40 wakeup columns: −3.50K at v1, −5.48K at v2 and −1.75K at ST.
- **Added logic, +0.5–0.8K:**
  - the tag free list (16 entries, 2–3 allocations per cycle);
  - a 4-bit tag field in the producer table;
  - the column clear on 16 columns (about 4 LUTs per column per queue, from S2 §4.1's +425 LUTs per queue at 104 columns);
  - the tag W bits.
- **Net: 2.7–3.0K at v1, 4.7–5.0K at v2, and about 1.0–1.2K at ST.**
- **Independent of the window:** a ROB entry now costs only its storage (§7.1).
- **Timing:** readiness shrinks from 104–120 W inputs to 40 per row, and the W bits that rows see come only from registered sources (delay lines, LLT completions). The 1-cycle loop is MX alone.
  - That should help the S2 path that limits v2 at S6 (MX issued → readiness → select → payload, −0.238 ns at 89%).
  - Not modelled; S2 will measure it.

**What synthesis must confirm.** The fit is calibrated on 64–120 columns, so 40 is an extrapolation. One S2 build, `tg_s2_sched_top` with 16 + 24 wakeup columns at v1's and v2's row counts, replaces the estimate. The tag pool itself is small and is not in S2.

### 5.3 Banked rows: exact, but not free

**Design.** Every queue is split into two banks of rows. A row's readiness covers only its bank's half of the ROB, every LLT and its bank's MX rows.
- **SMT2:** each thread uses its own bank. In the model this is the same as a 50% issue-queue cap instead of 75%.
- **SMT off:**
  - A uop takes the bank whose half holds its waiting producers. If they are in both halves, dispatch waits.
  - No dependency is dropped, so the design is exact. But a long dependency chain stays in one bank: half the rows.

**Cost:**

| | Throughput @120 | Single thread @120 | Saves per core |
|---|---|---|---|
| v1, banked | −2.61% (memory pairs −5.2%) | −8.21% | 1.65–2.75K |
| v1, banked + LLTs | −2.64% | −12.21% | 2.05–3.41K |
| v2, banked | −2.79% | −9.52% | 2.60–4.34K |

- **Where the single-thread loss comes from:** the bank stalls take 5.6% (v1) and 9.0% (v2) of single-thread cycles. The worst cases are stride (−54%), sha256 (−26%) and gather (−26%).
- **The alternative SMT-off mode** confines the thread to one ROB half, with every row switched to that half's columns. It costs −2.95% (v1) and −2.87% (v2) in single thread: less, but still not free.

**Verdict: rejected.** Wakeup tags save more and cost nothing. They also remove the ROB columns that banking would halve, so the two do not combine usefully.

### 5.4 MX columns per queue

The FP queue's rows almost never wait on MX: 0.0% of sources on the pairs, 0.4% single-threaded (int → FP moves of ALU results). Dropping its MX columns would save about 0.28K per core, at the cost of one cycle on those moves.

It is not exact, so it is not a free trick, and it is not pursued. The LD and STA queues need MX: 16–23% of their sources are address arithmetic.

---

## 6. The frequency trade (Part 2)

IPC × Fmax at 120 cycles, against full structures at 200 MHz. "Full structures" include the free levers (wakeup tags, R9, R10, and for v2 also R12 and completion buffer 8), since they cost nothing.

| Option | Saves per SoC | Clock | Throughput × clock | Single thread × clock |
|---|---|---|---|---|
| full structures | — | 200 MHz | 0.0% | 0.0% |
| full structures | — | 195 MHz | −2.5% | −2.5% |
| full structures | — | 190 MHz | −5.0% | −5.0% |
| full structures | — | 185 MHz | −7.5% | −7.5% |
| full structures | — | 180 MHz | −10.0% | −10.0% |
| v1 + FP queue 8, LD queue 4 | 0.7K | 200 MHz | −0.21% | −0.29% |
| v1 + radix-4 as well | 3.5K | 200 MHz | −0.66% | −2.70% |
| v1 + LLTs 16 (fails the rule) | 1.0K | 200 MHz | −1.34% | −0.16% |
| v2 + radix-4 | 2.8K | 200 MHz | −0.77% | −2.62% |
| v2 + R11, R12, R13 and 8-row ALU queues (R11, R13 and the queues fail the rule) | 4.3–4.9K | 200 MHz | −2.7% | −3.3% |
| v2 + those and v1's window | 5.4–6.0K | 200 MHz | −4.4% | −4.0% |

**Reading it.** D18 puts a lower clock before IPC-costing levers, and IPC × Fmax often agrees.
- **v1 barely has to choose** (§7.1). The free levers fit it at 200 MHz, except at the very top of the projection. There, 0.4–1.2K per SoC is left. FP queue 8 + LD queue 4 (0.7K, −0.3%) close most of it, and a clock a few MHz lower (≈195 MHz, if the fill test above 88% agrees) closes the rest.
- **v2, in the lower fifth of its range** (≤ 108K with the free set). Radix-4 and 8-row ALU queues hold 200 MHz for ≈−2.7% throughput and −3.6% single thread.
  - By IPC × Fmax that beats any clock below 195 MHz.
  - D18 would rather keep the IPC at a slightly lower clock, if the fill test allows it.
- **v2, in the middle and top of its range.** Holding 200 MHz takes more than the cuts can give.
  - In the middle (≈113K with the free set), every modelled cut together (radix-4, 8-row ALU queues, R11, R13, v1's window and 16 LLTs: ≈9K per SoC, ≈−7% throughput and −8% single thread) only just reaches 103K. That is worse than 190 MHz even by IPC × Fmax.
  - At the top, nothing reaches it.
  - **So v2 runs at 180–190 MHz with full structures,** provided the device can be filled to 92–96% at that clock (AR-5).
- **v2 at a lower clock still beats v1 at 200 MHz.** At 190 MHz, v2 with the free levers is +15.6% throughput and +9.3% single thread over v1 at 200 MHz; at 180 MHz, +9.5% and +3.5%. The trade is between versions of v2, not between v2 and v1.

---

## 7. The fit (Part 4)

### 7.1 v1

**Projections** (spikes §10, [budgets.md](budgets.md)):
- **Spikes:** 99–110K after the planned levers. That counts R1–R7, R10, R14 and R15, but not R9.
- **The budgets:** 103.0K with the free levers at the top of their ranges, and about 105K at their central values. Both count R6, R9 and R10.

| Basis | After the planned levers | + wakeup tags (−5.4–6.0K) and R9 (−0.4–0.6K, spikes basis only) | Fill | At 200 MHz (≤ 103K, 88%) |
|---|---|---|---|---|
| Budgets, free levers at the top | 103.0K | **97.0–97.6K** | 83% | fits, 5.4–6.0K to spare |
| Budgets, free levers central | ≈105K | **99.0–99.6K** | 85% | fits, 3.4–4.0K to spare |
| Spikes, low end | 99K | **92.4–93.2K** | 79% | fits |
| Spikes, high end | 110K | **103.4–104.2K** | 89% | 0.4–1.2K over. Close it with FP queue 8 + LD queue 4 (0.7K, −0.3%), then a few MHz of clock, or radix-4 (2.8K, −2.7% single thread) |

**v1's best-IPC configuration at ≥ 180 MHz:**
- D15's structures unchanged;
- wakeup tags (16), R9 and R10;
- every free lever of the first commit (R1–R5, R7, R14, R15);
- **no IPC-costing lever, at 200 MHz.**

Tags make a window step cheap, so IPC first suggests spending some of the headroom:

| v1 + wakeup tags, plus | Saves per core vs v1 as planned | Throughput @30 / @120 / @250 | Single thread @120 |
|---|---|---|---|
| ROB 96 (halves of 48) | 2.54–2.84K | +0.31 / +0.79 / +0.80% | +0.17% |
| ROB 96, LQ 32, SQ 24 (the SMT2 study's rejected window step) | 2.02–2.32K | +1.17 / +1.84 / +1.68% | +0.69% |

**The window step passes the acceptance rule now.** It costs ≈0.7K per core (1.5% of the core) for +1.84% throughput. The SMT2 study rejected it at 1.0K costed, and its true cost without tags was over 1.5K. With it, v1 still lands at 93.8–105.6K, which fits at 200 MHz except at the top of the spikes' range. It is an input for the rule (AR-3), not part of the fit.

### 7.2 v2

**The spikes' projection** (113–128K) counts every §8.5 lever, including R11, R12 and R13 at their estimates. This study changes that:
- **R11 and R13 fail the rule:** add back 2.1–2.5K per SoC.
- **R12 holds.** R9 and R10 are free.
- **Wakeup tags and completion buffer 8 are new:** −9.5–10.1K per SoC.

| v2 option | SoC | Fill | IPC vs v2 as planned (throughput / single @120) |
|---|---|---|---|
| Free set: tags, R9, R10, R12, completion buffer 8 | **105–121K** | 90–103% | −0.10% / −0.06% |
| + radix-4 | 102–118K | 87–101% | −0.77% / −2.62% |
| + radix-4 and 8-row ALU queues (the 8-row queues also give the S2 MX path +0.1–0.2 ns) | 100–116K | 85–99% | ≈−2.7% / −3.6% |
| Free set, keeping R11 and R13 instead | 103–118.5K | 88–101% | −0.87% / −2.31% |
| st_w3 with v1's window and tags | ≈90–105K (85–109K over the SMT-overhead range) | 77–90% | throughput −17% vs v1; single thread +14% vs v1 |

**Reading it.**
- **v2 fits at 200 MHz only at the bottom of its range.** The free levers must land low, and the S2, S3 and DTLB timing fixes must land too: S6 had v2 at 191 MHz at 89% with three failing paths.
- **Otherwise the re-plan is a lower clock, as D18 asks.**
  - At 180–190 MHz the S6 paths have 0.3–0.6 ns more slack, so the question becomes how full the device may be at that clock. S6 has no data above 89%.
  - With a fill limit of 92% (108K), v2 with the free set fits in the lower fifth of its range; with radix-4 and 8-row queues, in the lower half.
  - With 96% (112K), it fits in the lower half with the free set alone.
- **AR-5's fill test** (v2's core, 90/93/96% fill at 5.56 ns) is what decides. Until it runs, v2's re-plan should hold:
  1. the free set;
  2. the target of 180–190 MHz;
  3. radix-4, then 8-row ALU queues, in reserve;
  4. st_w3 as the fallback.

### 7.3 Against the per-unit budgets, and what must be re-measured

§7.1 and §7.2 use the planning projections (spikes §10, [budgets.md](budgets.md)). The real RTL has started to report, and its first numbers say the projections hold only once every unit meets its budget.

**The first synthesis of the real core** (`st`, M3 features on, no FPU) is 88K LUTs against the 38.2K ST budget. The core track traces the excess to simulation-first structures it is replacing with no-IPC fixes (D18 step 1):

| Structure (`st`) | LUTs now | Fix (no IPC cost), from the core track | Budget unit, ST / v1 ([budgets.md](budgets.md)) |
|---|---|---|---|
| PMP checkers | 18.5K | cache the PMP result in the TLB | ROB, commit, traps, CSRs, PMP: 2,160 / 4,840 |
| D$ state in flip-flops | 16.6K | being replaced | LSU: 5,770 / 6,780 |
| Rename tables in flip-flops | 13.4K | LUTRAM (R3) | Rename, checkpoints, free lists: 1,220 / 1,830 |
| TLB CAMs | 8.3K | a narrower PPN | MMU: 1,600 / 1,780 |
| LSU queues | 6.9K | being replaced | LSU |

**Where this study's verdicts land, unit by unit:**

| Unit | Budget, ST / v1 | Measured | With this study's verdicts |
|---|---|---|---|
| Issue queues and wakeup | 6,030 / 8,350 | 6,470 (st), 8,909 (smt2), 12,424 (smt2_w3); nightly run | **Wakeup tags:** ≈5.2–5.5K at st, ≈5.9–6.2K at smt2, ≈7.4–7.7K at smt2_w3. After R14 (≈6%, as the budgets assume), that is ≈4.9–5.2K and ≈5.6–5.8K: under budget by ≈0.8–1.1K at ST and ≈2.5–2.8K at v1. |
| FPU | 6,800 / 6,800 | 5,889 after a no-IPC pass | **0.9K under budget.** The radix-4 fallback is not needed for the FPU's budget, and its 1.41K saving predates the pass, so it must be re-measured. |
| Rename, checkpoints, free lists | 1,220 / 1,830 | real RTL: rename tables in flip-flops, 13.4K (being moved to LUTRAM) | The budget counts R10 (0.5K at v1). **R10 is free**, so that assumption holds. |
| LSU | 5,770 / 6,780 | real RTL: D$ state 16.6K, LSU queues 6.9K (being replaced) | The budget counts R9 (0.25K). **R9 is free**, so that assumption holds. |
| MMU | 1,600 / 1,780 | real RTL: TLB CAMs 8.3K (being narrowed) | The budget counts R6 (0.4K). R6 cannot be modelled (no MMU in `tgsim`), so it stays an assumption. |
| ROB, commit, traps, CSRs, PMP | 2,160 / 4,840 | real RTL: PMP checkers 18.5K (to be cached in the TLB) | No lever of this study. |

**What this means.**
- **The no-IPC verdicts stand, whatever the real numbers turn out to be.** Wakeup tags, R9 and R10 cost nothing, so they are D18 step 1 work, alongside the core track's fixes.
  - With tags, the scheduler goes from 0.6K over its v1 budget to ≈2.5–2.8K under.
  - The FPU is already 0.9K under its budget.
  - Together that is ≈3.4–3.7K per core of slack against the budgets, ≈7K per SoC. The other units may need it.
- **The IPC-costing verdicts are a ranking, not a decision.** They say which lever to use first if one is needed. Whether one is needed depends on what the units measure after the core's area pass. Until then, no IPC-costing lever is chosen (D18), and the reserve list (AR-6) stays a list.
- **The SoC fits of §7.1 and §7.2 assume every unit meets its budget.** Redo them with the measured per-unit numbers once the area pass lands (AR-7). v2 has no per-unit budgets yet; its scheduler with tags (≈7.4–7.7K) is an input for them.

---

## 8. Ledger entries and proposed plan text

### 8.1 Feature ledger

[feature_ledger.md](feature_ledger.md) gains an "Area recovery" section and a change-log line:
- **Adopted:** wakeup tags, R9 and R10; for v2, R12 and completion buffer 8.
- **Kept in reserve, in rank order:** FP queue 8, LD queue 4 and radix-4 (v1); radix-4 and 8-row ALU queues (v2).
- **Rejected:** R11, R13, banked readiness, and the ALU-queue, LQ, SQ, STA and LLT cuts.

### 8.2 Proposed text for plan §4.6 ("Wakeup")

Replace the "Wakeup IDs" and "Dependency vectors" bullets with:

- **Wakeup IDs (area-recovery study, 2026-10-14):** rows have dependency columns only for producers that MX and the LLTs do not cover.
  - **1-cycle producers:** MX names them while they are in their row and through the 2-cycle hold. After that their value is ready, so no row waits on their ROB column (census: 0 of 453M sources at v1).
  - **Long-latency producers** (loads, divides, FDIV/FSQRT): an LLT, as before.
  - **Multi-cycle fixed-latency producers** (MUL, complex Zbb and min/max on the 2-cycle path, FMA, FP misc and moves, serialised ops): one of 16 **wakeup tags**, taken at dispatch. Dispatch waits if none is free.
  - **Tag release:** 2 cycles after the producer wakes, past the shadow cancel. Its column is cleared in every row as it is freed.
  - **The ROB-indexed woken vector stays,** one bit per entry. Dispatch and the SQ's store-data check read it, and dispatch waits on a tag only while that bit is clear.
- **Dependency vectors** have 16 tag + 24 LLT columns at v1 and v2 (16 + 16 at ST), instead of 104 / 120 / 64, and are written once at dispatch.
  - **Model:** no IPC cost at 16 tags (`tgsim` `wake_tags`).
  - **Saving:** an estimated 2.7–3.0K LUTs per core at v1, 4.7–5.0K at v2 and 1.0–1.2K at ST, to be confirmed by one S2 build at 40 columns.

**For §8.5:**
- **R9 and R10:** measured at no IPC cost; adopted.
- **R11 and R13:** fail the reverse rule (−1.66% and −1.53% single thread); rejected.
- **R12:** passes (−0.06%).
- **The levers table gains a row:** wakeup tags.

**For the budgets** ([budgets.md](budgets.md)):
- **With wakeup tags, the scheduler measures about 5.6–5.8K at v1 after R14,** against its 8,350 budget, and 4.9–5.2K at ST against 6,030.
- **The budgets can keep their values:** the slack covers units still over (§7.3). v2's scheduler (≈7.4–7.7K) is an input for v2's budgets.
- **R9 and R10 are confirmed free,** as the budgets assume. R6 is still an assumption.

---

## 9. Limits and follow-ups

**Limits:**
- **Every LUT saving here except R11, radix-4 and the 8-row queues is an estimate.** The wakeup-tag saving extrapolates the S2 fit from 64–120 columns to 40. The banked queues' steering logic is costed as a 60–100% credit.
- **R6 is not modelled.** `tgsim` has no MMU, so the budgets' R6 (0.4K per core) is still an assumption.
- **min/max are 1-cycle ALU ops in `tgsim`.** S3 moved them to the 2-cycle path, so in RTL they take tags too. They are rare, and 16 tags leave room: there were no stalls on the pairs.
- **The suite has no dense-FP kernel** (exception E5). That is the code that would press on 16 tags (§5.2) and on the FP-queue trims. Re-judge both with E5 at M5.
- **The fill limit is measured only at 200 MHz, up to 89%** (S6).

**Follow-ups:**
1. **S2 build of the scheduler with wakeup tags:** 16 + 24 wakeup columns, at v1's and v2's row counts. It confirms §5.2's LUTs and measures the timing effect.
2. **S6 fill test at 5.56 ns** (180 MHz) for v2's core at 90/93/96% (AR-5).
3. **Re-run the SMT2 window sizing with tags' costs** (ROB entries at ≈10 LUTs). The rule now favours the window step (§7.1), and the same may hold for v2's ALU-queue step: in the SMT2 study it gave +1.06% at a costed 0.48K (in its last round).
4. **A merged pool of LLTs and wakeup tags** could cut the 40 columns further. Not modelled.
