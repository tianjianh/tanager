# Tanager area-recovery study: the model side

*Plan §8.5 and D18, triggered by spike S6. This study answers four questions:*
1. *What does each IPC-costing lever cost in IPC, ranked by IPC lost per LUT saved?*
2. *How does a lower clock compare with trimming?*
3. *Can each issue queue's readiness cover only the wakeup columns it can depend on?*
4. *What do v1 and v2 look like on the XCK26?*

| | |
|---|---|
| Status | Study for review. Input to plan §4.6, §8.2 and §8.5, to the per-unit budgets ([budgets.md](budgets.md)) and to the feature ledger. §7 is redone from the measured RTL (AR-7). |
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

**Real RTL (AR-7 and since, 2026-10-14; §7).** The core track's no-IPC passes took the `st` core from 88K to **42,607 LUTs with F/D and AR-1, against its 38,220 budget** (+11%). The last two passes were FPGA-friendly (DR-123), measured with DR-113's synthesis settings (main 7d60948). AR-7 measured 56.5K after the first pass.
- **v1 today: ≈117.1K,** all measured with DR-113's settings:
  - two `smt2` cores at 45,055 each (main 7d60948);
  - the uncore at 18,603 (main 78e40f5);
  - plus hart 1's state at the budgets' 4.2K per core.

  At main's head, with the FPU track's latest merge estimated from its unit runs, it is ≈116.1K.
- **The limits:**
  - 103,040 at 200 MHz (88%);
  - 111,633 at 180 MHz (95.3%, the full fill test). Lowering the clock needs the user's explicit approval (DR-137), so the 180 MHz bar is a decision for the user, not a plan.
- **Hart 1's basis.** The budgets' 4.2K assumes second copies and leaves out the PMP descriptor select, which measures +2.3K per core.
  - In RAM form (conventions §7), hart 1 is ≈4.3K with that select, and v1 is ≈117.2K.
  - As second copies, hart 1 is ≈6.5K and v1 is ≈121.7K.

  See §7.7 and the M7 brief, [hart1_ram_form.md](hart1_ram_form.md).
- **Verdict:** v1 does not fit today, at 200 MHz or at 180 MHz. It fits at 200 MHz when its units meet their budgets, which sum to 103,040.
- **Closing the gap:** the remaining 14.1K is D18 step-1 work, unit by unit (52.6K at AR-7, 38.5K after the second pass, 24.0K after the third).
  - 7.8K of it is the uncore, which also misses 200 MHz out of context by 1.8–2.0 ns (the L2's S2 path, being restructured).
  - The clock (step 2) would be worth 8.6K, but only the user can approve it (DR-137; §7.7). The reserve (step 3) is ≈8.0K, ≈5.8K of it from release builds without the commit trace, its last lever (DR-121).
- **v2 (the third pass, old settings): 164.6K, 52.2K over its 180 MHz limit (112,441, 96.0%).** It needs a per-core budget (≈49.7K at 180 MHz; AR-9) and its own no-IPC pass on the 3-wide structures, which add +14.9K per core today.
- **How to read this study:**
  - its verdicts are stated against the per-unit budgets of [budgets.md](budgets.md);
  - no IPC-costing lever is chosen while step 1 has this much left to do (D18).

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
   - **What passes and stays in reserve:** the FP-queue and LD-queue trims (≤ 0.3%). The radix-4 divider (−0.4–0.8% throughput, −2.4–2.6% single thread) passed in the model, but at its measured 1,036 LUTs it fails the rule. The user took it out of the reserve (DR-118).
4. **Readiness by thread (banked rows) is exact but not free** (§5.3).
   - **With SMT2 on,** no row ever waits on the other thread (0 sources). But binding rows to threads acts as a 50% issue-queue cap: −2.6% throughput at v1.
   - **With SMT off,** 1–4% of waits cross the two ROB halves. Steering around them costs 8–10% single-thread IPC.
   - **Rejected.** Wakeup tags save more, at no cost.
5. **Measured RTL (AR-7 and since, §7): v1 does not fit today. It fits at 200 MHz once its units meet their budgets.**
   - **Today v1 is ≈117.1K** (118.4K at the fn2 merge, 119.6K at 4eb7ce0, 120.9K at 2cf1cd9, 127.0K after the third pass, 141.5K after the second, 155.7K at AR-7), against 103,040 at 200 MHz and 111,633 at 180 MHz. All its parts use DR-113's settings:
     - two `smt2` cores at 45,055 each (the core's FPGA-friendly passes, main 7d60948);
     - hart 1's state at the budgets' 4.2K per core;
     - the uncore at 18,603 (main 78e40f5).

     With hart 1 in RAM form and the measured PMP select (≈4.3K per core) it is ≈117.2K.
   - **The budgets sum to 103,040,** so meeting them is the fit.
     - With hart 1 on the budgets' basis, each core is 3.1K over its budget: LSU and MMU, rename, then ROB and CSRs, P4 and Execute.
     - Without hart 1, each core is under its budget.
     - The uncore is 7.8K over.
   - **Wakeup tags put the issue queues under budget:** 4,922 at `st` and 5,261 at `smt2`, against 6,030 and 8,350.
   - **The window step stays an option** (AR-3): +1.84% throughput for ≈0.7K per core with tags.
6. **v2 needs a budget, then a no-IPC pass on its 3-wide structures** (§7.4).
   - **The budget:** at 180 MHz the device takes 110.3K (94.2%). With the uncore at budget, that leaves ≈49.7K per core, ≈3.6K over v1's lines. The full fill test closes v2 at 96.0% (112,441), which could raise it to ≈50.8K (the coordinator's call).
   - **Today** v2 is 164.6K (two `smt2_w3` cores at 66,773: the third pass, with the old settings), 52.2K over its 180 MHz limit (112,441). The 3-wide increment is +14.9K per core, with rename at +4.48K against +0.5K planned. The plan estimated 6–8K in all.
   - **IPC still favours v2 at a lower clock:** at 190 MHz it beats v1 at 200 MHz by +15.6% throughput and +9.3% single thread.
7. **D18's order holds, and the measured gap makes it sharper** (§6, §7.5).
   - In the model, every trim costs less IPC than the clock it replaces.
   - But against the measured gap, step 2 (180 MHz, 8.6K) and the whole reserve (step 3, ≈8.0K with trace-free release builds, DR-121) together (16.6K) would exceed step 1's remaining 14.1K. Both are the user's decisions (DR-137, DR-135), not a path the project takes, and D18 takes step 1 first.
   - **Radix-4 is out of the reserve** (user, DR-118). It saves only 1.04K, measured after the FPU's no-IPC pass, and fails the rule.

### 1.2 What the levers add up to

Per core, in rank order on top of wakeup tags, each step simulated as a whole. The share is of the core after the planned levers: v1 45.6K, v2 53.6K.

| Step | v1: saves | v1: throughput / single thread @120 | v2: saves | v2: throughput / single thread @120 |
|---|---|---|---|---|
| Wakeup tags (16) | 2.70–3.00K | 0.00% / 0.00% | 4.68–4.98K | 0.00% / 0.00% |
| + R10, R9 | 3.40–3.80K | −0.04% / −0.00% | 5.38–5.78K | −0.01% / 0.00% |
| + v1: FP queue 8, LD queue 4. v2: R12, completion buffer 8 | 3.74–4.14K | −0.21% / −0.29% | 5.59–6.09K | −0.10% / −0.06% |
| + radix-4 divide/sqrt | 5.15–5.55K | −0.66% / −2.70% | 7.00–7.50K | −0.77% / −2.62% |

The radix-4 step is the model's result at the FPU track's first 1.41K. Re-measured after the FPU's no-IPC pass, it saves 1.04K and fails the rule, and it is no longer a lever (user, DR-118). The reserve's last v1 lever is now release builds without the commit trace (DR-121, §7.5).

### 1.3 Decisions and their status

AR-1 to AR-7 were proposed by this study and recorded in plan §8.5 (2026-10-14). AR-8 and AR-9 come from the AR-7 re-measurement (§7).

| # | Decision | Status |
|---|---|---|
| AR-1 | Wakeup tags (16), every configuration (plan §4.6) | **Adopted and built.** Measured (area_synth.md §3.1, core-pipeline.md §16): −1,623 / −3,389 / −4,812 LUTs at st / smt2 / smt2_w3 in the S2 harness, and −681 in the real `st` core (its 64-column window left less to take). |
| AR-2 | R9 and R10 | **Held as the first reserve.** Free in the model, but they share or reduce function, which D18 puts last even at ≈0% cost. |
| AR-3 | v1 keeps D15's structures and uses no IPC-costing lever | **Adopted.** The window step (ROB 96, LQ 32, SQ 24: +1.84% throughput, ≈0.7K per core) is an option, not adopted (user), until the measured fit leaves room. |
| AR-4 | v2 re-plan: `smt2_w3` with tags, R11 and R13 dropped, 180–190 MHz | Direction recorded; v2 comes after v1. §7.4 updates what it needs. |
| AR-5 | Fill test at 180–190 MHz | **v2 with tags closes 180 MHz at 94.2% fill** (110,280 LUTs; area_synth.md §5). v1 at 93% and the 90/95/96% points are running. |
| AR-6 | Reserve order (D18 step 3). v1: R9, R10, FP queue 8, LD queue 4, then release builds without the commit trace (DR-121, last; development builds keep it). v2: 8-row ALU queues | Ranking only. Radix-4 is out (user, DR-118). §7.5 re-prices the reserve against the measured gap. |
| AR-7 | Re-measure the real RTL after the area pass, then redo the fit | **Done (this update, §7).** |
| AR-8 | **The gap is implementation, not IPC** (§7.3–§7.5) | **Proposed.** Keep D18 step 1 going unit by unit against [budgets.md](budgets.md), in the order of §7.5, before any clock or reserve decision. The reserve is too small to matter at this gap. |
| AR-9 | **Budget v2 from the 180 MHz fill limit** (§7.4) | **Proposed.** Per core ≈49.7K with the uncore at budget (110.3K, 94%), against v1's 46.1K. The 3-wide additions must fit in the difference. |

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
- the radix-4 divide/sqrt: 1.41K, plus 26 DSPs and a BRAM18 freed (FPU track). Re-measured after the FPU's no-IPC pass, it is 1,036 LUTs (5,889 → 4,853), and at that saving radix-4 fails the reverse rule (§7.5).

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
- **st_w3 removes the SMT2 logic** (4.5–9.3K per core) and gives up 15–22% of v1's throughput. Tags would save it a further ≈3.7K per core. It does not avoid the 3-wide additions, so it is not a way around v2's budget (§7.4).

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
- **Independent of the window:** a ROB entry now costs only its storage (§7.6, AR-3).
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

**Reading it.** These readings use the planning projection. Against the measured RTL, the clock and the reserve are both small next to the remaining implementation work (§7.5). D18 puts a lower clock before IPC-costing levers, and IPC × Fmax often agrees.
- **v1 barely has to choose** (§7.6). The free levers fit it at 200 MHz, except at the very top of the projection. There, 0.4–1.2K per SoC is left. FP queue 8 + LD queue 4 (0.7K, −0.3%) close most of it, and a clock a few MHz lower (≈195 MHz, if the fill test above 88% agrees) closes the rest.
- **v2, in the lower fifth of its range** (≤ 108K with the free set). Radix-4 and 8-row ALU queues hold 200 MHz for ≈−2.7% throughput and −3.6% single thread.
  - By IPC × Fmax that beats any clock below 195 MHz.
  - D18 would rather keep the IPC at a slightly lower clock, if the fill test allows it.
- **v2, in the middle and top of its range.** Holding 200 MHz takes more than the cuts can give.
  - In the middle (≈113K with the free set), every modelled cut together (radix-4, 8-row ALU queues, R11, R13, v1's window and 16 LLTs: ≈9K per SoC, ≈−7% throughput and −8% single thread) only just reaches 103K. That is worse than 190 MHz even by IPC × Fmax.
  - At the top, nothing reaches it.
  - **So v2 runs at 180–190 MHz with full structures,** provided the device can be filled to 92–96% at that clock (AR-5).
- **v2 at a lower clock still beats v1 at 200 MHz.** At 190 MHz, v2 with the free levers is +15.6% throughput and +9.3% single thread over v1 at 200 MHz; at 180 MHz, +9.5% and +3.5%. The trade is between versions of v2, not between v2 and v1.

### 6.1 Each clock with its own latencies (measured in the model, 2026-10-14)

*The user asked whether 200 MHz is the right target for v1, since NaxRiscv reaches 135–150 MHz on this class of device without tuning. This is a measurement only: the target stays 200 MHz until the user decides (DR-137). `scripts/clock.py` reproduces it (`results/clock_rv64gc.json`). Its first run reproduces v1's single-thread suite IPC at 120 cycles from the area study exactly.*

**The setup.**
- **v1:** the release configuration (`smt2`, wakeup tags), running the single-thread suite with SMT off.
- **NaxRiscv:** the control (`nax`), on the same uncore, at 137 MHz (its RV64 figure, Artix-7 -3) and at 150 MHz.
- **What scales with the clock:** the DRAM latency, 184 ns (S1's idle 64-byte read), and the bandwidth, 3.2 GB/s per port (20 ns per line), both in that clock's cycles. The L2 hit is 2 cycles shorter at 150 MHz and below (`DATA_LAT` 2 instead of 4).
- **What stays fixed in cycles:** everything else.
  - The 4-cycle FMA missed 200 MHz by 1.88 ns, so it would close only below about 145 MHz; no clock here gains it.
  - No other 200 MHz pipelining is recorded as clock-dependent.

| Core | Clock (MHz) | DRAM / L2 hit (cycles) | Suite IPC | IPC × MHz | ÷ NaxRiscv at 137 | ÷ NaxRiscv at 150 | CoreMark/MHz (A / B) | CoreMark/s (A) ÷ NaxRiscv at 137 / 150 |
|---|---|---|---|---|---|---|---|---|
| v1 | 200 | 37 / 12 | 1.229 | 246 | **2.26** | **2.10** | 5.31 / 5.17 | 2.13 / 1.95 |
| v1 | 180 | 33 / 12 | 1.244 | 224 | 2.06 | 1.92 | 5.31 / 5.17 | 1.92 / 1.75 |
| v1 | 170 | 31 / 12 | 1.265 | 215 | 1.98 | 1.84 | 5.31 / 5.17 | 1.81 / 1.66 |
| v1 | 160 | 29 / 12 | 1.275 | 204 | 1.88 | 1.75 | 5.31 / 5.17 | 1.71 / 1.56 |
| v1 | 150 | 28 / 10 | 1.289 | 193 | 1.78 | 1.66 | 5.31 / 5.17 | 1.60 / 1.46 |
| NaxRiscv | 150 | 28 / 10 | 0.779 | 117 | 1.07 | 1.00 | 3.64 / 3.86 | 1.09 / 1.00 |
| NaxRiscv | 137 | 25 / 10 | 0.793 | 109 | 1.00 | 0.93 | 3.64 / 3.86 | 1.00 / 0.91 |

**Reading it:**
- **Performance follows the clock.** Fewer cycles of memory latency raise the suite IPC by only 1.3% at 180 MHz and 4.9% at 150 MHz. So IPC × MHz falls:

  | Clock | Change |
  |---|---|
  | 180 MHz | −8.9% |
  | 170 MHz | −12.5% |
  | 160 MHz | −17.0% |
  | 150 MHz | −21.3% |

  §6's table assumed fixed cycles (−10.0% at 180 MHz); with S1's latency the step is a little smaller.
- **Only the memory suite moves.** Kernels and Embench stay in the caches, so their IPC is the same at every clock (1.851 and 1.687). The memory suite's IPC rises from 0.594 at 200 MHz to 0.686 at 150 MHz.
- **CoreMark/MHz does not move** (5.31 / 5.17), so CoreMark/s scales with the clock alone.
- **Against NaxRiscv,** on suite performance:
  - at 200 MHz v1 is 2.26× the control at 137 MHz and 2.10× at 150 MHz;
  - at 150 MHz it is still 1.78× and 1.66×.

  The CoreMark/MHz ratio is 1.46× (A) and 1.34× (B) at every clock, D11's measure.
- **At the stress point** (1,250 ns: 250 cycles at 200 MHz, 188 at 150), latency tolerance widens the ratios a little. v1 at 200 MHz is 2.28× and 2.13× the control at 137 and 150 MHz, and −18.9% at 150 MHz.
- **Single thread only.** SMT2's throughput gain (WS_ref 1.43 at 120 cycles) comes on top at every clock. It was not rerun per clock.
- **The clock's area side is §7.7:**
  - the 180 MHz fill limit gives 8.6K more LUTs than 200 MHz's;
  - no fill test exists below 180 MHz;
  - `DATA_LAT` 2 would also shorten the L2's read pipeline.

**One extra pipeline stage at a unit boundary** (the user's question, 2026-10-14).
- **The method:** each point alone, against v1 at that clock's latencies (DRAM 184 ns), at 200 MHz and at 150 MHz.
- **"Same performance at"** is the clock that, without the stage, loses as much: 200 MHz × (1 + the suite IPC change).
- **The model points** name the knobs and code, so the core track can map each one to its RTL path.

| Point | Model change | Suite IPC at 200 | CoreMark/MHz A / B at 200 | Same performance at | Suite IPC at 150 |
|---|---|---|---|---|---|
| 1. Load-to-use | Every load result (hit, forward or miss) reaches its dependents a cycle later.<br>`abl_ld_use` (`Core::exec_load`'s result time); the speculative-wakeup shadow moves with it. | −1.88% | −5.69% / −5.23% | 196.2 MHz | −1.97% |
| 2. Branch mispredict penalty | The redirect reaches IF1 a cycle later, at execute and at commit.<br>`redirect_lat` and `commit_redirect` 1 → 2. | −0.28% | −0.16% / −0.19% | 199.4 MHz | −0.23% |
| 3. Execute completion to the ROB | Every uop is marked complete a cycle later, so commit and everything that waits for it slips.<br>`abl_done` (every completion time). | −0.10% | −0.01% / −0.01% | 199.8 MHz | −0.10% |
| 4. Exception or fault reporting only | No model point: `tgsim` takes no traps, and the suite raises none in its timed regions. | 0 | 0 | — | 0 |
| 5. Integer bypass and wakeup loop (upper bound) | A 1-cycle result wakes its dependents a cycle later, so dependent single-cycle ops lose back-to-back issue. Completion is unchanged.<br>`abl_alu` (`Core::do_issue`'s 1-cycle case). | −8.04% | −10.91% / −9.79% | 183.9 MHz | −8.31% |
| 6. L2 hit +2 (`DATA_LAT` 4 against 2) | `l2_lat` 12 against 10. | −0.65% | 0.00% / 0.00% | 198.7 MHz | −0.73% |

CoreMark/MHz moves the same at 150 MHz as at 200 MHz, because CoreMark stays in the L1s.

**Reading it:**
- **Loops cost; boundaries off the loops cost little.**
  - A stage at completion costs −0.10%, at the mispredict redirect −0.28%, and two in the L2 hit −0.65%.
  - Each is worth 0.2–1.3 MHz at 200 MHz.
- **Load-to-use is the expensive real candidate:** −1.9% on the suite and −5.2 to −5.7% on CoreMark, worth about 4 MHz at 200 MHz.
- **The integer wakeup loop is the upper bound:** −8.0% on the suite and about −10% on CoreMark. That is as much as running at 184 MHz, and 200 → 180 MHz costs 8.9% (above).
- **Exceptions:** a stage that only delays a fault's report costs nothing in the model. In hardware it costs as rarely as faults occur.
- **The knobs** (`abl_ld_use`, `abl_alu`, `abl_done`) default to 0. At 0 the model reproduces every earlier result exactly: the clock sweep, re-simulated from an empty cache with the new build, gives identical numbers.

---

## 7. The fit (Part 4), from the measured RTL (AR-7)

*Redone on 2026-10-14 from the real RTL. AR-7 measured it after the core track's no-IPC area pass, AR-1 and F/D, at c898f1e and cb8ff6c. This section has since been updated to the core track's second no-IPC pass at 5c124f2, the first build measured in all four configurations. §7.7 keeps the gap over time, and §7.6 the planning projection it replaced. §7.1–7.5 stay at 5c124f2 with the old synthesis settings. §7.7 has the later passes, with DR-113's settings. §7.1–7.5 move to them once the 3-wide configurations are measured with those settings too; the uncore now is.*

### 7.1 What is measured

| Item | LUTs | Source |
|---|---|---|
| `st` core: two no-IPC passes, AR-1 and F/D | **51,707** | core track's budget runs at 5c124f2 (`out14_*`): `tg_core` with the hierarchy kept, after `opt_design`, primitive check clean |
| `smt2` core (hart 0 only, see below) | **55,436** | same |
| `st_w3` core | **64,408** | same |
| `smt2_w3` core (hart 0 only) | **70,028** | same. The spikes track's `core_smt2w3_hier` (117,570) came from a snapshot before the area pass, with no F/D, and is not used. |
| Uncore at `smt2`: two L2 banks, crossbar, host bridge, trace, two latency injectors, PLIC, ACLINT, UART | **22,265** (21,797 at `st`) | SoC track's budget run, 2026-10-14 02:16 |
| Fill limit at 200 MHz | ≈88%: **103,040** | S6, v1 at 88.3% (+0.007 ns); also the sum of v1's budgets |
| Fill limit at 180 MHz | 94.2%: **110,280** | S6 at 5.556 ns, v2's core with tags (+0.049 ns; area_synth.md §5). v1 at 93% is still running. |

AR-7's first measurement (c898f1e, cb8ff6c) was `st` 56,461 and `smt2` 62,501 (§7.7).

**Not yet in the RTL: hart 1's state.** The `smt2` builds carry `tid` everywhere but run hart 0 only until M7 (core-pipeline.md §1). [budgets.md](budgets.md)'s SMT2 additions put the missing state at **≈4.2K per core** at v1 (3–6K) and ≈4.4K at v2, after R1 and R2:

| Part | v1 | v2 |
|---|---|---|
| Second FTQ, history, RAS and fetch PC | 1.0K | 1.0K |
| Decode-to-rename queue per thread | 0.15K | 0.2K |
| Second rename and committed maps, and checkpoints (less if the LUTRAM maps only deepen) | 1.3K | 1.45K |
| Second CSR file and counters (3.0K, less 1.35K from R1 and R2) | 1.65K | 1.65K |
| Sibling snoops and LR | 0.1K | 0.1K |

This estimate costs second copies and leaves out the PMP descriptor select (+2.3K per core, measured). §7.7 and the M7 brief ([hart1_ram_form.md](hart1_ram_form.md)) give the corrected bases: ≈4.3K per core in RAM form, ≈6.5K as copies.

### 7.2 Per unit, against the budgets (per core, 5c124f2)

**v1, and ST** ([budgets.md](budgets.md)):

| Unit | ST budget | `st` | Over | v1 budget | `smt2` (hart 0) | + hart 1 (est.) | v1 over |
|---|---|---|---|---|---|---|---|
| Front end | 5,540 | 5,004 | −536 | 6,480 | 5,004 | +1.0K | −476 |
| Decode | 1,500 | 1,677 | +177 | 1,640 | 1,677 | +0.15K | +187 |
| Rename | 1,220 | 4,541 | **+3,321** | 1,830 | 4,789 | +1.3K | **+4,259** |
| Issue queues and wakeup | 6,030 | 5,409 | −621 | 8,350 | 5,430 | — | **−2,920** |
| Execute (RF, bypass, integer units) | 7,610 | 8,636 | +1,026 | 7,610 | 8,631 | — | +1,021 |
| LSU and MMU | 7,370 | 13,266 | **+5,896** | 8,560 | 15,415 | +0.1K | **+6,955** |
| ROB, commit, traps, CSRs, PMP | 2,160 | 5,163 | **+3,003** | 4,840 | 6,363 | +1.65K | **+3,173** |
| FPU (P4) | 6,800 | 7,853 | +1,053 | 6,800 | 7,953 | — | +1,153 |
| **Core** (with glue) | **38,220** | **51,707** | **+13,487 (+35%)** | **46,120** | **55,436** | **+4.2K** | **+13,516 (+29%)** |

**v2,** against AR-9's per-unit lines ([budgets.md](budgets.md) §1.1; `budgets.tsv` in `track` mode until v2 work starts, spikes track 1db95bd):

| Unit | v2 line (proposed) | `smt2_w3` (hart 0) | + hart 1 (est.) | v2 over | 3-wide increment (`smt2_w3` − `smt2`) | Plan / spike estimate |
|---|---|---|---|---|---|---|
| Front end | 6,480 | 5,236 | +1.0K | −244 | +232 | 0 (S5) |
| Decode | 2,340 | 2,530 | +0.2K | +390 | +853 | +0.7K (§4.15) |
| Rename | 2,330 | 9,339 | +1.45K | **+8,459** | **+4,550** | +0.5K (§4.15) |
| Issue queues and wakeup | 7,240 | 7,815 | — | +575 | +2,385 | +2.2K (S2, tags) |
| Execute | 10,750 | 12,334 | — | +1,584 | +3,703 | +3.4K (S3) |
| LSU and MMU | 8,560 | 16,299 | +0.1K | **+7,839** | +884 | 0 |
| ROB, commit, traps, CSRs, PMP | 5,240 | 8,135 | +1.65K | **+4,545** | +1,772 | +0.4K (§4.15) |
| FPU (P4) | 6,800 | 8,134 | — | +1,334 | +181 | 0 |
| **Core** (with glue) | **49,740** | **70,028** | **+4.4K** | **+24,688 (+50%)** | **+14,592** | ≈7.2K |

**Notes.**
- **P4's register file.** P4 holds the FP register file (1,108), which the budgets count in "Register files and bypass", part of Execute's 7,610. Like for like, P4 is ≈0.2K under its budget and Execute ≈2.3K over.
- **Where v1's excess is.** The issue queues (wakeup tags put them there) and the front end are under budget. The excess is in:
  - the LSU and MMU: the second pass took 6.9K off, and 7.0K remain;
  - rename;
  - ROB, commit and CSRs;
  - Execute and P4.
- **Where the 3-wide increment is.** It measures +14.6K at `smt2` and +12.7K at `st`, against ≈7.2K in the plan.
  - **Rename is the outlier:** +4.55K, against +0.5K planned. It needs read and write ports for a third slot on the LUTRAM maps, plus the intra-group checks.
  - **ROB, commit and CSRs** come next at +1.8K, against +0.4K.
  - **Execute (+3.7K) and the issue queues (+2.4K) are close to the spikes' estimates.**
- **Uncore**, against its 10,800 budget:

  | Part | LUTs |
  |---|---|
  | L2, two banks (after R15) | 9,866 |
  | Crossbar | 4,366 |
  | Trace stream | 2,853 |
  | Host bridge | 1,667 |
  | Latency injectors | 1,481 |
  | PLIC, ACLINT, UART, device bus and AXI slices | 2,032 |
  | **Total** | **22,265** (+11.5K) |

### 7.3 Device totals (5c124f2)

| | v1: 2 × `smt2` | v2: 2 × `smt2_w3` |
|---|---|---|
| Two cores, measured | 110.9K | 140.1K |
| Hart 1's state, ×2 (M7, est.) | 8.4K | 8.8K |
| Uncore, measured | 22.3K | 22.3K |
| **Total** | **141.5K** (121% of the device) | **171.1K** (146%) |
| Over 103,040 (200 MHz, 88%; also the sum of v1's budgets) | 38.5K | 68.1K |
| Over 110,280 (180 MHz, 94.2%) | 31.3K | 60.8K |

**Today neither fits, at 200 MHz or 180 MHz. The gap is in implementation, not IPC.**
- **Where v1's 38.5K goes:**
  - each core is 13.5K over its budget once hart 1 is in;
  - the uncore is 11.5K over its budget.
- **Without hart 1's estimate,** the measured parts alone (two `smt2` cores and the uncore) come to 133.1K. That is 22.9K over the 180 MHz limit.
- **Progress:** AR-7 had v1 at 155.7K. The core's second no-IPC pass took 14.1K off.

### 7.4 What v1 and v2 need

**v1 fits at 200 MHz when its units meet their budgets.** The budgets sum to 103,040 by construction, so v1 needs:
- every core unit within its line of [budgets.md](budgets.md), with hart 1 included: 13.5K per core to find, 27.0K for two cores;
- the uncore down 11.5K to its 10.8K.

The free levers the budgets assume (R1, R2, R14, R15) are part of that. Wakeup tags already bring the issue queues ≈2.9K under budget. **No IPC-costing lever is needed if the units land; and if they do not, the levers cannot close the gap (§7.5).**

**v2 needs its own budget (AR-9) and its own no-IPC pass.**
- **The limit:** 110,280 at 180 MHz (94.2%). With the uncore at its 10.8K budget, that leaves **≈49.7K per core**, against v1's 46.1K. The 3-wide additions must therefore fit in ≈3.6K per core.
- **Today the 3-wide increment is +14.6K per core** (`smt2_w3` − `smt2`, measured). The plan estimated 6–8K.
- **The levers left for v2 do not cover the difference:**
  - R12 (0.2K) and completion buffer 8 (0.06K), both in v2's reserve;
  - 8-row ALU queues (≈1K, −1.9% throughput);
  - radix-4: out of the reserve (DR-118);
  - R11 and R13, rejected.
- **So v2 needs a no-IPC pass on the 3-wide structures,** as the 2-wide units got. It should start with rename (+4.55K, against +0.5K planned), then ROB and CSRs (+1.8K) and execute. v2 also needs every v1 unit at budget, and 180 MHz.
- **st_w3 does not avoid this.**
  - **What dropping SMT2 saves:** ≈7.9K per core. That is hart 1's state (≈4.2K) plus the SMT2 window and `tid` fields (3.7K, measured as `smt2` − `st`).
  - **What it does not:** its 3-wide increment is the same. Two `st_w3` cores and the `st` uncore come to 150.6K (129%).

### 7.5 D18's order against the measured gap (v1)

| D18 step | What | v1, per SoC |
|---|---|---|
| **1. No-IPC implementation** | Every unit to its budget line.<br>**Core:** LSU and MMU, rename, ROB and CSRs, Execute, then decode. The core track's next commit (c86fd95) is expected to take ≈1.2K more at `st`, and a `pma_of` fix ≈0.4K per core, pending approval.<br>**Uncore:** crossbar, trace, host bridge.<br>**R14's area directive on non-critical units:** on the scheduler it saved 8% beyond the kept hierarchy (area_synth.md §3); the whole-core runs with and without it are pending. | needs **38.5K** to reach 103,040 at 200 MHz, or **31.3K** to reach 110,280 at 180 MHz (it was 52.6K and 45.4K at AR-7) |
| **2. A lower clock** | 200 → 180 MHz moves the limit from 103,040 to 110,280 | **+7.2K** of room |
| **3. The reserve (AR-6)** | In order:<br>R9 0.5K, R10 1.0K;<br>FP queue 8 and LD queue 4, ≈0.7K with tags;<br>**last,** release builds without the commit trace (DR-121): 1,466 LUTs per core plus ≈2.9K for the uncore's trace stream, at no IPC cost. Development builds keep the trace.<br>**Not in AR-6:** the page walker sharing the STA's PMP checker (0.83K per core), which the core track holds back under D18; and radix-4, out (DR-118). | **≈8.0K**: ≈2.2K before the trace, ≈5.8K from it |

**What this means for AR-6:**
- **The reserve is about a fifth of the gap** (≈8.0K of 38.5K), and ≈2.2K before its last lever. Choosing an IPC-costing lever before step 1 has run its course would cost IPC and change little about the fit.
- **The ranking stands:** R9, R10, then FP queue 8 and LD queue 4.
- **Radix-4 is out** (user, DR-118). It fails the rule at its measured saving, and it stays buildable but is not an area lever.
- **Step 2 comes before the reserve,** as D18 has it. The two are now of similar size: 180 MHz gives ≥7.2K, and more under §7.7's full fill test.
- **Once step 1 lands, re-run this section** from the budget report (§7.7, `area_fit.py`). If the gap is then within ≈7K, 180 MHz closes it. Only a remainder beyond that calls on the reserve, in AR-6's order.
- **The commit trace is the reserve's last lever** (user, DR-121). It costs 1.47K per core at `st`, plus the uncore's 2.9K trace stream. Only release bitstreams drop it; development builds keep the lockstep trace.

### 7.6 The planning projection (superseded)

Before the real RTL, §7 fitted v1 and v2 from the spikes' projections and the per-unit budgets:
- **v1:** 92–104K with tags and R9, which fitted 200 MHz if every unit met its budget.
- **v2:** 105–121K with the free set, so it was re-planned around 180–190 MHz.

The per-unit view above replaces both. That projection's condition, "if every unit meets its budget", is exactly what the measured RTL does not yet do. Its other conclusions still hold:
- the window step costs ≈0.7K per core with tags (AR-3);
- v2 at 180–190 MHz beats v1 at 200 MHz (+15.6% throughput at 190 MHz);
- the frequency trade of §6.

### 7.7 The gap over time

Re-run after each step-1 milestone of the core, FPU and SoC tracks (AR-8). Each v1 row is two `smt2` cores with hart 1's state added (until M7 builds it), plus the uncore.

**The limits:**
- **103,040 at 200 MHz:** S6's 88%, and the sum of v1's budgets.
- **105,408 at 200 MHz:** the plan's 90% ceiling (DR-011), beyond what S6 tested.
- **111,633 at 180 MHz:** the full fill test closes v1 there, at 95.3% (area_synth.md §5). Lowering the clock needs the user's explicit approval (DR-137). So this column, and any sum of 180 MHz and the reserve, is a decision for the user, not a path the project takes.

Earlier versions of this table measured the 180 MHz column against 110,280 (94.2%), so every row is restated here.

**The settings.**
- From the third pass on, the budget flow builds the core with DR-113's settings: the hierarchy kept, plus `AreaOptimized_high` (814c4e7). The budgets assume them (R14), so those rows compare like with like.
- Earlier rows use the old settings, and so does every uncore figure before the last row.
- The core runs record no commit, so each row names its run.

**Step-1 saving** is what a row saved per SoC against the row before, by no-IPC, cycle-identical work. Since DR-123 that work is the FPGA-friendly program. The settings change has its own row.

```bash
python3 perfmodel/scripts/area_fit.py --core <core budget run>/latest.json --uncore <uncore budget run>/latest.json
```

| Date | Milestone | Settings | `st` core | `smt2` core | v1 dual-core | Step-1 saving (per SoC) | Over 103,040 / 105,408 (200 MHz) | Over 111,633 (180 MHz: the user's decision, DR-137) |
|---|---|---|---|---|---|---|---|---|
| 2026-10-13 | Planning projection (spikes §10) | — | — | — | 99–110K | — | −4K to +7K / −6K to +5K | −13K to −2K |
| 2026-10-14 01:30 | First real synthesis, d04ae26 (no FPU; P4 7,953 and hart 1 added) | old | 81,715 | 89,050 | ≈224.7K | — | ≈+121.6K / ≈+119.3K | ≈+113.0K |
| 2026-10-14 07:30 | AR-7: area pass, AR-1, F/D (c898f1e, cb8ff6c) | old | 56,461 | 62,501 | **155.7K** | ≈−69.0K | **+52.6K** / +50.3K | **+44.0K** |
| 2026-10-14 | Core track's second no-IPC pass, as reported first (a32d2aa, 8a5c651) | old | 50,768 | 54,506 | ≈141.3K (with the revert below) | — | ≈+38.3K / ≈+35.9K | ≈+29.7K |
| 2026-10-14 08:38 | Second pass at the core track's final head, 5c124f2: `out14_st`, `out14_smt2` | old | 51,707 | 55,436 | **141.5K** (120.8%) | −14.1K | **+38.5K** / +36.1K | **+29.9K** |
| 2026-10-14 10:07 | Third no-IPC pass with DR-120, before the FLW-boxing fix: `out20_st`, `out20_smt2` | old | 49,097 | 51,839 | 134.3K (114.7%) | −7.2K | +31.3K / +28.9K | +22.7K |
| 2026-10-14 11:25 | Third pass as merged (main 43a523e): `out23_st`, `out23_smt2` | cores DR-113; uncore old | 46,132 | 49,022 | 128.7K (109.9%) | −5.6K (the cores' settings) | +25.7K / +23.3K | +17.1K |
| 2026-10-14 13:02 | The uncore with DR-113's settings: the SoC track's MR at 4d5ca13 (`budget_mr3_dr113`), with the 11:25 cores | DR-113 (cores and uncore) | 46,132 | 49,022 | 127.0K (108.4%) | −1.7K (the uncore's settings) | +24.0K / +21.6K | +15.4K |
| 2026-10-14 15:13 | The core track's FPGA-friendly pass (DR-123, DR-125; MR pending at 2cf1cd9): `out29_st`, `out28_smt2`, with the 13:02 uncore | DR-113 | 43,342 | 45,992 | 120.9K (103.3%) | −6.1K | +17.9K / +15.5K | +9.3K |
| 2026-10-14 16:31 | Estimate with main's merges since: the FPU's DR-123 pass (4c60319), measured in the core at `st` (`out30_st` at 4eb7ce0, the core track's next branch: −337) and applied to `smt2`; the crossbar (89d8001: −249, measured with the old flow) | DR-113 (est.) | 43,005 | ≈45,655 | ≈120.0K (102.5%) | ≈−0.9K | ≈+17.0K / ≈+14.6K | ≈+8.4K |
| 2026-10-14 17:21 | Measured: the core track's next branch (4eb7ce0: the FPGA-friendly pass and main's merges; `out30_st`, `out30_smt2`) and the SoC track's uncore pass (e7227d4: the crossbar's constants and one-hot L2 MSHR state; `budget_onehot`) | DR-113 | 43,005 | 45,637 | 119.6K (102.1%) | −0.4K | +16.6K / +14.2K | +8.0K |
| 2026-10-14 17:46 | Measured, both merged: the core's second FPGA-friendly pass, fn2 (main 7d60948; `out33_st`, `out33_smt2` at e5c2b4f, the same RTL), with the 17:21 uncore (main 9be0707) | DR-113 | 42,607 | 45,055 | 118.4K (101.1%) | −1.2K | +15.4K / +13.0K | +6.8K |
| 2026-10-14 19:52 | Measured: the SoC's DR-136 pass, register slices in DSPs (main 78e40f5; `budget_dsp2` at 44767a1), with the fn2 cores | **DR-113** | **42,607** | **45,055** | **117.1K** (100.0%) | −1.3K | **+14.1K** / +11.7K | **+5.5K** |
| 2026-10-14 21:25 | Estimate at main's head (78e40f5): the FPU track's merge (3121edd) from its unit runs, P4 −123 / −122 and Execute −367 / −368 at `st` / `smt2` | DR-113 (est.) | ≈42,117 | ≈44,565 | ≈116.1K (99.2%) | ≈−1.0K | ≈+13.1K / ≈+10.7K | ≈+4.5K |

**The latest cores, per unit at `smt2` against the v1 budgets.** Measured at the core's second FPGA-friendly pass as merged (main 7d60948; `out33_smt2`), with DR-113's settings. Hart 1 is added on the budgets' basis, by `area_fit.py`.

| Unit | Measured | + hart 1 (budgets) | Budget | Over | At 4eb7ce0 | After the third pass | At 5c124f2 (old settings) |
|---|---|---|---|---|---|---|---|
| Front end | 4,738 | +1.0K | 6,480 | −742 | −742 | −742 | −476 |
| Decode | 1,437 | +0.15K | 1,640 | −53 | −53 | −53 | +187 |
| Rename | 3,032 | +1.3K | 1,830 | **+2,502** | +2,502 | +3,973 | +4,259 |
| Issue queues and wakeup | 5,261 | — | 8,350 | −3,089 | −3,089 | −3,082 | −2,920 |
| Execute | 7,822 | — | 7,610 | +212 | +212 | +408 | +1,021 |
| LSU and MMU | 11,698 | +0.1K | 8,560 | **+3,238** | +3,238 | +3,916 | +6,955 |
| ROB, commit, traps, CSRs, PMP | 3,799 | +1.65K | 4,840 | +609 | +1,191 | +2,095 | +3,173 |
| FPU (P4) | 7,096 | — | 6,800 | +296 | +296 | +425 | +1,153 |
| **Core** (with glue) | **45,055** | **+4.2K** | **46,120** | **+3,135** (+7%) | +3,717 | +7,102 | +13,516 |

**Reading it:**
- **fn2 took 582 more LUTs off each `smt2` core, all in the ROB and CSRs** (4,381 → 3,799):
  - the cold CSRs in one LUTRAM (R2), with xepc through the CSR read port;
  - the ROB's replay flag XOR-banked;
  - one PC adder at the ROB head.

  Since the 15:13 row, main's FPU pass took P4 −129 and Execute −196. Without hart 1 the core is 1,065 under its line.
- **What is left per core, +3.1K with hart 1 on the budgets' basis:**
  - the LSU and MMU +3.2K;
  - rename +2.5K;
  - the ROB and CSRs +0.6K;
  - P4 +0.3K and Execute +0.2K.

  The issue queues (−3.1K) and the front end (−0.7K) are under budget.
- **Not in these core runs: the FPU track's merge** (3121edd: execute's step 3, P4's steps 4 and 5).
  - Its unit runs take P4 −122 and Execute −368 at `smt2`: ≈0.49K per core, ≈1.0K per SoC. The 21:25 row estimates main's head with them.
  - In-core deltas have differed from unit-run ones before: round 1's Execute was −196 in the core against −52 alone. So the next core run replaces the estimate.
- **The uncore, measured: 18,603 at `smt2`** (the SoC's DR-136 pass, main 78e40f5, `budget_dsp2`, DR-113's settings).
  - The register slices moved into DSPs: −1,330 LUTs and −2.8K flip-flops, for 83 DSPs.
  - It is +7.8K over its 10,800 budget, over half of v1's gap.
  - The SoC will revisit the default per-site DSP mask after the S2 restructure, so the saving may shrink slightly.
- **Open risk: the uncore misses 200 MHz.**
  - Its out-of-context check fails by 1.8–2.0 ns on the L2's S2 path. The SoC restructures that path next.
  - Its numbers also assume DR-113's settings. Keeping the old ones would add back ≈1.7K per SoC (7.7%, as measured at 4d5ca13).
- **Pending, gated: DR-133,** execute's operand ports in UltraRAM: −597 per core when on, measured before execute's step 3 (fpu.md), −1.2K per SoC. It is in no row.
- **D18's steps against the remaining 14.1K:**
  - 180 MHz (step 2) would be worth 8.6K, but only the user can approve it (DR-137);
  - the reserve (step 3) is ≈8.0K in old-settings figures, and the user decides each of its levers (DR-135).

  Together (16.6K) they would exceed the gap. But they are the user's decisions, not a path the project takes, D18 takes step 1 first, and hart 1's basis moves the target (below).
- **`st`, for reference:** 42,607 against 38,220 (+4.4K): the LSU and MMU +3.0K, rename +1.6K, the ROB and CSRs +1.1K.

**Hart 1: three bases** (v1, per core). The M7 brief, [hart1_ram_form.md](hart1_ram_form.md), has the detail for each structure.
- **The budgets' basis** (4.2K, used in every row above) costs second copies. The SMT2 study (§8.3) priced flip-flop maps with 64-entry read selects, and second FTQ and RAS tables with their own ports. R1 and R2 were already off the CSRs.
- **The PMP descriptor select, measured.**
  - The 16 region descriptors (72 bits each) are read in parallel by the four `tg_pmp` checkers. So hart 1 needs its own 1,152 flip-flops, and every checker needs a select of the requesting hart's set.
  - Out of context with DR-113's settings, a checker grows from 891 to 1,467 LUTs (S = 1); fetch's (S = 2) grows from 958 to 1,534. That is +576 each, +2,304 for four: one LUT per two select bits.
  - Neither earlier estimate counted it, and it is the same in both forms.
- **RAM form** (conventions §7): the per-thread tables take `tid` as an address bit. The rest comes to ≈2.0K, plus the PMP select. fn2 built R2's cold-CSR table (xtvec, xscratch, xepc, xcause, xtval), so mepc and sepc no longer count as hot state.

| Basis | Hart 1 per core | v1 (7d60948 cores, 78e40f5 uncore) | Over 103,040 | Over 105,408 | Over 111,633 (the user's decision, DR-137) |
|---|---|---|---|---|---|
| Budgets (second copies, no PMP select) | 4.2K | 117.1K (100.0%) | +14.1K | +11.7K | +5.5K |
| Second copies with the PMP select | ≈6.5K | 121.7K (103.9%) | +18.7K | +16.3K | +10.1K |
| RAM form with the PMP select | ≈4.3K | **117.2K** (100.1%) | **+14.2K** | +11.8K | **+5.6K** |
| RAM form with the PMP select, plus DR-133 (pending, −597 per core) | ≈4.3K | 116.0K (99.1%) | +13.0K | +10.6K | +4.4K |

- **At main's head,** with the FPU track's merge estimated from its unit runs, each figure is ≈1.0K lower: ≈116.1K, ≈120.7K, ≈116.3K and ≈115.1K.

- **The RAM forms save ≈2.2K per core** (≈4.5K per SoC) against copies. The earlier ≈2.4K-per-core figure, and its v1 of ≈116.4K, left out the PMP select.
- **The PMP select is now hart 1's largest item.** The brief lists ways to cut it. Each costs cycles or function, so each would go on the reserve list for the user to decide (DR-135).
- **M7 replaces every estimate** with the first `smt2` synthesis that has hart 1's state (`area_fit.py --hart1 budgets|copies|ram` until then).

**Notes on the earlier rows.**
- **The second pass as reported first** measured the page walker sharing the STA's PMP checker. That sharing was reverted under D18 (DR-122), and the final head has its own checker back: +1.0K in lsu_mmu at `smt2`, against the 0.83K expected.
- **Added to the reserve since AR-7: release builds without the commit trace** (user, DR-121, the last v1 lever).
  - They save 1,466 LUTs per core at `st` (core track, measured with `trace_o` unconnected) and ≈2.9K for the uncore's trace stream: ≈5.8K per SoC, at no IPC cost.
  - Development builds keep the trace.

**v2.** Two `smt2_w3` cores with hart 1's state added (≈4.4K each), plus the uncore.
- **The limit:** 112,441 at 180 MHz, where the full fill test closes v2 (96.0%).
- **AR-9's per-core line** (49,740, now in `budgets.tsv`) came from the earlier 110,280.
  - It and v2's per-unit lines are sized at 180 MHz, so they are tracking targets only (DR-137).
  - At 96.0% the per-core line could be ≈50.8K.

```bash
python3 perfmodel/scripts/area_fit.py --cfg smt2_w3 --uncore-cfg smt2 --core <run>/latest.json --uncore <run>/latest.json
```

| Date | Milestone | Settings | `st_w3` core | `smt2_w3` core | v2 dual-core | Step-1 saving (per SoC) | Over 112,441 (180 MHz: a tracking target, DR-137) |
|---|---|---|---|---|---|---|---|
| 2026-10-14 07:30 | AR-7 estimate: `smt2` + (`st_w3` − `st` at 525e875) | old | — | ≈75.7K | ≈182.4K | — | ≈+70.0K |
| 2026-10-14 08:54 | Second pass at 5c124f2 (`out14_st_w3`, `out14_smt2_w3`), measured | old | 64,408 | 70,028 | **171.1K** (146%) | — | **+58.7K** |
| 2026-10-14 10:19 | Third pass, before the FLW-boxing fix (`out20_st_w3`, `out20_smt2_w3`) | old | 62,199 | 66,773 | **164.6K** (140.5%) | −6.5K | **+52.2K** |

- **No DR-113 run of the 3-wide configurations yet.** If the settings took the same 5.4% off `smt2_w3` as off `smt2`, the core would be ≈63.1K. With the DR-113 uncore, v2 would then be ≈155.6K, ≈+43.2K over 112,441. That is an estimate, not a row.
- **Per unit at the third pass** (old settings, against v2's lines; hart 1 added):
  - rename +8.4K;
  - the LSU and MMU +5.8K;
  - the ROB, commit and CSRs +3.6K;
  - Execute +1.6K and P4 +1.1K;
  - the issue queues +0.6K and decode +0.4K;
  - the front end −0.3K.

  The core is +21.4K over 49,740. Its 3-wide increment is +14.9K (`smt2_w3` − `smt2`, old settings), with rename +4.48K of it.

**Next rows:**
- the uncore's block-RAM-first pass (DR-135) and the SoC track's host-bridge rewrite;
- a core run at main's head (the FPU track's merge, now estimated);
- the SoC's S2 restructure (the uncore's 200 MHz miss, above) and its DSP-mask revisit;
- the 3-wide configurations under DR-113's settings, then §7.1–7.5 move to the latest pass;
- hart 1 at M7, which replaces every estimate.

---

## 8. Ledger entries and proposed plan text

### 8.1 Feature ledger

The ledger's "Area recovery" section records the decisions (plan §8.5, 2026-10-14):
- **Adopted:** wakeup tags.
- **First reserve:** R9 and R10; for v2, R12 and completion buffer 8. D18 puts sharing and reduced function last, even when they are free.
- **An option, not adopted:** the v1 window step.
- **Rejected:** R11, R13, banked readiness, and the ALU-queue, LQ, SQ, STA and LLT cuts.

This update (AR-7) changes it in three places:
- **Radix-4 left the reserve** (user, DR-118). Re-measured after the FPU's no-IPC pass, it saves 1,036 LUTs per core (5,889 → 4,853) and fails the reverse rule. It stays buildable but is not an area lever.
- **The net lines** move from the planning projection to the measured fit (§7).
- **The intro** records the re-measurement.

### 8.2 Plan text

Plan §4.6 and §8.5 record AR-1 to AR-9 (f550a00, e5bde85; AR-8 and AR-9 as DR-116 and DR-117). The AR-7 row records 155.7K, AR-7's measurement. Proposed addition after the core's second no-IPC pass:

> **Updated (5c124f2, all four configurations measured).**
> - **v1** is ≈141.5K: +38.5K at 200 MHz, +31.3K at 180 MHz.
> - **v2** is 171.1K: +60.8K at 180 MHz.
> - **The 3-wide increment** is +14.6K per core, against ≈3.6K of room under AR-9. Rename alone is +4.55K, against +0.5K planned.
> - **The page walker sharing the STA's PMP checker** (0.83K per core, reverted under D18) is a candidate for the reserve; AR-6 does not list it.

**For the budgets:**
- **Issue queues:** the scheduler with tags and the free settings measures 4,750 in S2 at `smt2`, against its 8,350 budget. In the real cores it is 5,430 (`smt2`) and 5,409 (`st`).
- **Radix-4:** its saving is 1.04K, not 1.4K.
- **v2:** AR-9's per-unit lines are in [budgets.md](budgets.md) §1.1 and `budgets.tsv` (spikes track, 1db95bd). They are in `track` mode, so the nightly reports them without failing on them until v2 work starts. The core's DSP budget is 87 at `smt2` and `smt2_w3` (DR-110).

The text first proposed for plan §4.6 (now recorded there) follows, for reference. It replaced the "Wakeup IDs" and "Dependency vectors" bullets with:

- **Wakeup IDs (area-recovery study, 2026-10-14):** rows have dependency columns only for producers that MX and the LLTs do not cover.
  - **1-cycle producers:** MX names them while they are in their row and through the 2-cycle hold. After that their value is ready, so no row waits on their ROB column (census: 0 of 453M sources at v1).
  - **Long-latency producers** (loads, divides, FDIV/FSQRT): an LLT, as before.
  - **Multi-cycle fixed-latency producers** (MUL, complex Zbb and min/max on the 2-cycle path, FMA, FP misc and moves, serialised ops): one of 16 **wakeup tags**, taken at dispatch. Dispatch waits if none is free.
  - **Tag release:** 2 cycles after the producer wakes, past the shadow cancel. Its column is cleared in every row as it is freed.
  - **The ROB-indexed woken vector stays,** one bit per entry. Dispatch and the SQ's store-data check read it, and dispatch waits on a tag only while that bit is clear.
- **Dependency vectors** have 16 tag + 24 LLT columns at v1 and v2 (16 + 16 at ST), instead of 104 / 120 / 64, and are written once at dispatch.
  - **Model:** no IPC cost at 16 tags (`tgsim` `wake_tags`).
  - **Saving:** an estimated 2.7–3.0K LUTs per core at v1, 4.7–5.0K at v2 and 1.0–1.2K at ST, to be confirmed by one S2 build at 40 columns.

The study's first proposal for §8.5 adopted R9 and R10 as free. The plan held them as the first reserve instead (AR-2), and recorded R11 and R13 as rejected and R12 in v2's reserve.

---

## 9. Limits and follow-ups

**Limits:**
- **Model-side LUT savings in §3–§5 are estimates,** except R11, radix-4 and the 8-row queues. The wakeup-tag saving has since been measured (§1.3, AR-1); §7 uses measured RTL throughout.
- **Hart 1's state is an estimate** (≈4.2K per core, §7.1) until M7 builds it. The `smt2` cores measured here run hart 0 only.
- **The uncore figure dates from 2026-10-14 02:16,** before any uncore area pass.
- **R6 is not modelled.** `tgsim` has no MMU, so the budgets' R6 (0.4K per core) is still an assumption.
- **min/max are 1-cycle ALU ops in `tgsim`.** S3 moved them to the 2-cycle path, so in RTL they take tags too. They are rare, and 16 tags leave room: there were no stalls on the pairs.
- **The suite has no dense-FP kernel** (exception E5). That is the code that would press on 16 tags (§5.2) and on the FP-queue trims. Re-judge both with E5 at M5.
- **The 180 MHz fill limit is measured with v2's core only** (94.2%). v1 at 93% and the 90/95/96% points are running.

**Follow-ups:**
1. ~~S2 build with wakeup tags~~: **done** (area_synth.md §3.1): −3.4K at smt2, −4.8K at smt2_w3, timing kept.
2. **S6 fill test at 5.56 ns:** v2 at 94.2% is **done**. v1 at 93% and the other points are running.
3. **Re-run §7 from the budget report after each step-1 milestone** (AR-8), and with hart 1 measured at M7.
4. **v2's budget lines (AR-9),** then a no-IPC pass on the 3-wide structures.
5. **Re-run the SMT2 window sizing with tags' costs** (ROB entries at ≈10 LUTs), once the measured fit leaves room (AR-3's option).
6. **A merged pool of LLTs and wakeup tags** could cut the 40 columns further. Not modelled.

---

## 10. History and lessons

**2026-10-13: the study starts.** Spike S6 triggers it (plan §8.5, D18). The S2 scheduler measures 8.9K LUTs at smt2 against the plan's 2.9K. v1 is projected at 99–110K against a ≈103K ceiling at 200 MHz.

**The model work:**
- **New `tgsim` options:** R10–R13, banked readiness, wakeup tags and a census, all off by default. Single-thread runs stay bit-identical to M1, and SMT2 pairs re-simulate identically.
- **Every lever measured alone:** on v1 and v2, at 30/120/250 cycles, over 42 pairs and the single-thread suite, then combined greedily. About 6,000 pair runs in all.

**What it found:**
- **Wakeup tags.** The census showed that rows need ROB-indexed wakeup columns only for multi-cycle fixed-latency producers. A pool of 16 tags replaced the 80–96 ROB columns at exactly zero IPC cost.
  - Estimated at −2.7 to −3.0K per core at v1 (net of the pool).
  - Measured in S2 at −3.4K (v1) and −4.8K (v2), and −4.75K with the free synthesis settings.
  - In the real `st` core, only −0.68K: a 64-column window and earlier payload trims left less to take.
- **The plan's IPC-costing levers mostly failed the reverse rule.** R11 and R13 cost 1.5–1.7% single-thread IPC, almost all of it Dhrystone. The window and queue cuts failed once tags were in.

**2026-10-14: decisions** (plan §8.5): AR-1 adopted and built; R9 and R10 held as the first reserve (D18: sharing and reduced function last, even when free); the v1 window step kept as an option.

**2026-10-14: AR-7.** The real RTL was re-measured after the core track's no-IPC area pass, and §7 was redone from it.
- **Measured:** `st` is 56,461 with F/D, `smt2` 62,501 (hart 0 only), and the uncore 22,265.
- **v1 comes to ≈155.7K** against 103.0K at 200 MHz. Every unit is over budget except the issue queues and the front end, and so is the uncore.
- **The IPC-costing reserve is worth ≈2.2K per SoC.**
- **Radix-4,** re-measured at 1.04K, fails the rule.
- **Later the same day the user took radix-4 out of the reserve (DR-118).** They added release builds without the commit trace as its last lever (DR-121, ≈5.8K per SoC), which brings the reserve to ≈8.0K.
- **The spikes track's `core_smt2w3_hier`** came from a pre-pass snapshot and was not used. v2's core is estimated from the measured 3-wide increment.

**2026-10-14: the second no-IPC pass, measured in all four configurations** (5c124f2):
- **The cores:** `st` 51,707, `smt2` 55,436, `st_w3` 64,408, `smt2_w3` 70,028.
- **v1 fell to ≈141.5K** (−14.1K since AR-7), most of it from the LSU and MMU.
- **v2 is 171.1K.** The first measured 3-wide increment is +14.6K per core against ≈7.2K planned, with rename at +4.55K against +0.5K. It replaces the AR-7 estimate built from a pre-AR-1, pre-F/D `st_w3`.
- **`area_fit.py`** turns each budget run into a row of §7.7.

**2026-10-14: the third no-IPC pass** (main 43a523e), the first rows with DR-113's synthesis settings:
- **The cores:** `st` 46,132 and `smt2` 49,022 with the new settings. With the old settings, before the FLW-boxing fix, they were `st` 49,097, `smt2` 51,839, `st_w3` 62,199 and `smt2_w3` 66,773.
- **The uncore with the same settings:** the SoC track measured 20,560 at 4d5ca13 (−7.7%).
- **v1 fell to ≈127.0K:** −14.5K since 5c124f2. Of that, 7.2K came from the core RTL, 5.6K from the cores' settings and 1.7K from the uncore's.
  - Each core is +7.1K over its budget.
  - The uncore (+9.8K) is 41% of the gap.
- **v2 is 164.6K** with the old settings.
- **§7.7's changes:** the 180 MHz column uses the full fill test's limits (111,633 for v1, 112,441 for v2), and the table gains the 90% line and a step-1 (FPGA-friendly) saving column.

**2026-10-14: the core track's FPGA-friendly pass** (DR-123, DR-125; MR pending at 2cf1cd9), with DR-113's settings:
- **The cores:** `st` 43,342 and `smt2` 45,992, cycle-identical to main. Without hart 1's estimate, the `smt2` core is under its 46,120 line.
- **v1 fell to ≈120.9K** (−6.1K). Per core:
  - rename −1.5K;
  - the ROB and CSRs −0.8K;
  - the LSU and MMU −0.7K.

  With main's merges since (the FPU's DR-123 pass, the crossbar) it is ≈120.0K.
- **Hart 1, a second estimate.** As a RAM address bit (conventions §7) its state is ≈2.4K per core, against the budgets' 4.2K for second copies. That puts v1 at ≈116.4K, ≈4.8K over the 180 MHz limit. DR-133 (pending) would take another 1.3K.

**2026-10-14: the uncore pass, the latest cores and the PMP select** (DR-113's settings throughout):
- **The uncore:** 19,933 at `smt2` (the SoC track's e7227d4: the crossbar's constants and one-hot L2 MSHR state), −627.
- **The cores:** 45,637 at `smt2` (the core track's next branch, 4eb7ce0, with main's FPU pass), −355.
- **v1 is ≈119.6K,** all measured, with hart 1 on the budgets' basis.
- **The PMP descriptor select, measured:** +576 LUTs at each of the four checkers, +2.3K per core.
  - It corrects the RAM-form estimate for hart 1 from ≈2.4K to ≈4.4K per core: v1 ≈119.9K, not ≈116.4K.
  - As copies, hart 1 would be ≈6.5K.
- **The M7 brief** ([hart1_ram_form.md](hart1_ram_form.md)) gives the form and cost of each per-thread structure.

**2026-10-14: the core's second FPGA-friendly pass (fn2), merged** (7d60948):
- **The cores:** `st` 42,607 and `smt2` 45,055. The −582 per core is all in the ROB and CSRs: the cold CSRs in one LUTRAM (R2), xepc through the CSR read port, the ROB's replay flag XOR-banked, and one PC adder at the ROB head.
- **v1 on each hart-1 basis:**
  - ≈118.4K on the budgets' basis;
  - ≈118.6K in RAM form with the PMP select (hart 1 ≈4.3K, mepc and sepc now cold);
  - ≈117.3K with DR-133;
  - ≈123.1K as copies.

**2026-10-14: the uncore's DR-136 pass and DR-137** (main 78e40f5):
- **The uncore:** 18,603 at `smt2`, with its register slices in DSPs: −1,330 LUTs and −2.8K flip-flops, for 83 DSPs. Its 200 MHz out-of-context check fails by 1.8–2.0 ns on the L2's S2 path.
- **v1 on each hart-1 basis, cores at 7d60948:**
  - ≈117.1K on the budgets' basis;
  - ≈117.2K in RAM form with the PMP select;
  - ≈116.0K with DR-133 (−597 per core);
  - ≈121.7K as copies.

  At main's head, the FPU track's merge takes ≈1.0K more (estimated).
- **DR-137:** lowering the clock to about 180 MHz needs the user's explicit approval. §7.7 now labels its 180 MHz figures, and any sum of 180 MHz and the reserve, as the user's decision. v2's AR-9 lines are tracking targets only.

**Lessons:**
- **Ask which consumers actually wait on a structure before sizing it.** The census turned a 4–5K "overrun" into an exact redesign. The same question asked of the window, the queues and the checkpoints only found IPC.
- **A fit is only as good as its per-unit inputs.** The first projections used planning estimates for every unit but the scheduler and the FPU. The first real synthesis was 88K at `st` against 38.2K, so the levers this study ranked were a small part of the real gap (§7).
- **Free in the model is not the same as free under D18.** R9 and R10 cost ≈0% IPC but share or reduce function, and the user puts those last.
- **The projection hid a 50K gap.** The planning fit put v1 at 92–104K, but the measured RTL is ≈155.7K. Lever studies rank the last few percent; the per-unit budget report, built from the real RTL, is what tells whether a design fits.
- **Check which commit a synthesis report comes from before using it.** A same-named run on another track's branch can predate a merge.
- **Re-cost an estimate once its form is chosen.** Hart 1's 4.2K assumed second copies and is now as large as the core's measured excess. With conventions §7's RAM forms the rest of it is ≈2.1K, but the PMP select adds 2.3K to either form.
- **Price the selects, not just the storage.** A per-thread table in RAM costs its storage. Per-thread state read in parallel costs a select at every reader. The PMP descriptors' four selects (+2.3K) outweigh every table in hart 1.
- **Mark the synthesis settings with every figure.** The third pass measured 51,839 at `smt2` with the old settings and 49,022 with DR-113's. Mixing the two misstates v1 by 5.6K.
