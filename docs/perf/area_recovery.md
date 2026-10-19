# Tanager area-recovery study: the model side

*Plan §8.5 and D18, triggered by spike S6. This study answers four questions:*
1. *What does each IPC-costing lever cost in IPC, ranked by IPC lost per LUT saved?*
2. *How does a lower clock compare with trimming?*
3. *Can each issue queue's readiness cover only the wakeup columns it can depend on?*
4. *What do v1 and v2 look like on the XCK26?*

| | |
|---|---|
| Status | Study for review. Input to plan §4.6, §8.2 and §8.5, to the per-unit budgets ([budgets.md](budgets.md)) and to the feature ledger. §7 is redone from the measured RTL (AR-7). §7.8 ranks the area levers for M6's set at 100 MHz (2026-10-18). |
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

**Real RTL (AR-7 and since, 2026-10-14 and 15; §7).** The core track's no-IPC passes took the `st` core from 88K to **42,045 LUTs with F/D and AR-1, against its 38,220 budget** (+10%). The last passes were FPGA-friendly (DR-123), and fn4 adds the user's DR-139 (the walker shares STA's PMP checker). All are measured with DR-113's synthesis settings (main 6dd8d96). AR-7 measured 56.5K after the first pass.
- **v1 today: ≈116.7K,** all measured with DR-113's settings:
  - two `smt2` cores at 44,720 each (fn4, main 6dd8d96);
  - the uncore at 18,903 (main 951c235);
  - plus hart 1's state at the budgets' 4.2K per core.

  At main's head, with the FPU track's P4 steps 7 and 8 estimated from their unit runs, it is ≈116.4K at most.
- **The limits:**
  - 103,040, the sum of the budgets (S6's 88% at 200 MHz);
  - the fill test by clock (plan §8.5): 93.4% closes 200 MHz (109,407), or 95.3% (111,652) if a miss on a harness path alone is accepted; 98.3% closes 180 and 170 MHz (≈115.2K); 99.3% closes 150 MHz (116,301).

  Which clock and fill to plan for is the user's decision (DR-137), so each ceiling is a decision for the user, not a plan.
- **Hart 1's basis.** The budgets' 4.2K assumes second copies and leaves out the PMP descriptor select, which measures +1.7K per core with DR-139's three checkers.
  - In RAM form (conventions §7), hart 1 is ≈3.7K with that select, and v1 is ≈115.7K.
  - As second copies, hart 1 is ≈5.9K and v1 is ≈120.2K.

  See §7.7 and the M7 brief, [hart1_ram_form.md](hart1_ram_form.md).
- **Verdict:** v1 does not fit the budgets today. In RAM form it is 6.3K over 200 MHz's clean ceiling, 0.5K over 180 and 170 MHz's, and 0.6K under 150 MHz's, each the user's decision (DR-137). It fits at 200 MHz when its units meet their budgets, which sum to 103,040.
- **Closing the gap:** the remaining 13.7K over the budgets is D18 step-1 work, unit by unit (52.6K at AR-7, 38.5K after the second pass, 24.0K after the third).
  - 8.1K of it is the uncore. After the L2's S2 restructure it still misses 200 MHz out of context, by 0.74–0.91 ns all in fabric (from 1.78 ns).
  - Each core is 2.8K over with hart 1 on the budgets' basis, and 1.4K under without it.
  - The clock (step 2) and the reserve (step 3, ≈8.0K, ≈5.8K of it from release builds without the commit trace, DR-121) are the user's decisions (DR-137, DR-135; §7.7). 180 MHz's ceiling is 5.8K above 200 MHz's clean one.
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
   - **Today v1 is ≈116.7K** (117.1K after DR-136, 118.4K at the fn2 merge, 119.6K at 4eb7ce0, 120.9K at 2cf1cd9, 127.0K after the third pass, 141.5K after the second, 155.7K at AR-7), against the budgets' 103,040. All its parts use DR-113's settings:
     - two `smt2` cores at 44,720 each (fn4, main 6dd8d96);
     - hart 1's state at the budgets' 4.2K per core;
     - the uncore at 18,903 (main 951c235).

     With hart 1 in RAM form and the measured PMP select (≈3.7K per core) it is ≈115.7K. Against the measured fill ceilings (the user's decision, DR-137), that is 6.3K over 200 MHz's 109,407 (93.4%), 0.5K over 180 and 170 MHz's ≈115.2K (98.3%), and 0.6K under 150 MHz's 116,301 (99.3%).
   - **The budgets sum to 103,040,** so meeting them is the fit.
     - With hart 1 on the budgets' basis, each core is 2.8K over its budget: rename, the LSU and MMU, then the ROB and CSRs, decode and P4.
     - Without hart 1, each core is under its budget.
     - The uncore is 8.1K over.
   - **Wakeup tags put the issue queues under budget:** 4,922 at `st` and 5,261 at `smt2`, against 6,030 and 8,350.
   - **The window step stays an option** (AR-3): +1.84% throughput for ≈0.7K per core with tags.
6. **v2 needs a budget, then a no-IPC pass on its 3-wide structures** (§7.4).
   - **The budget:** at 180 MHz the device takes 110.3K (94.2%). With the uncore at budget, that leaves ≈49.7K per core, ≈3.6K over v1's lines. The full fill test closes v2 at 96.0% (112,441), which could raise it to ≈50.8K (the coordinator's call).
   - **Today** v2 is 164.6K (two `smt2_w3` cores at 66,773: the third pass, with the old settings), 52.2K over its 180 MHz limit (112,441). The 3-wide increment is +14.9K per core, with rename at +4.48K against +0.5K planned. The plan estimated 6–8K in all.
   - **IPC still favours v2 at a lower clock:** at 190 MHz it beats v1 at 200 MHz by +15.6% throughput and +9.3% single thread.
7. **D18's order holds, and the measured gap makes it sharper** (§6, §7.5).
   - In the model, every trim costs less IPC than the clock it replaces.
   - But against the measured gap, the clock (step 2) and the reserve (step 3) are both large enough to matter: in RAM form v1 is 6.3K over 200 MHz's clean ceiling and 0.5K over 180 MHz's (98.3%), and the whole reserve is ≈8.0K with trace-free release builds (DR-121). Both are the user's decisions (DR-137, DR-135), not a path the project takes, and D18 takes step 1 first.
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
- **v1:** the release configuration (`smt2`, wakeup tags), running the single-thread suite with SMT off. It has the plan's L1D (16 MSHRs, with prefetchers); §6.2 models v1 as built.
- **NaxRiscv:** the control (`nax`), on the same uncore, at 137 MHz (its RV64 figure, Artix-7 -3) and at 150 MHz.
- **What scales with the clock:** the DRAM latency, 184 ns (S1's idle 64-byte read), and the bandwidth, 3.2 GB/s per port (20 ns per line), both in that clock's cycles. The L2 hit is 2 cycles shorter at 150 MHz and below (`DATA_LAT` 2 instead of 4). §6.2 corrects the bandwidth: a port moves 16 bytes per cycle at any clock, so a line takes 4 cycles.
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

### 6.2 The DR-145 clocks: v1 as built, at 94–150 MHz (measured in the model, 2026-10-16)

*DR-145 (the user, 10-16) makes 125 MHz the preferred clock and 100 MHz the minimum for v1 as scoped (2 cores × SMT2), after a study. Every resulting change needs the user's approval. This is the model's part of the study. `scripts/clock_low.py` reproduces it on the build host (`results/clock_low_rv64gc.json`), and its first run reproduces v1's single-thread suite IPC at 120 cycles from the area study exactly.*

> **Superseded in part by §6.3 (2026-10-17).** "v1 as built" here was built only on the memory side: the L1D's misses in flight and the prefetchers. It kept the plan's front end, recovery and latencies, which the RTL does not have yet. Calibrated to the RTL, v1 with 4 misses in flight at 100 MHz reaches about half of NaxRiscv's single-thread performance at 135–150 MHz, not the 1.13× / 1.04× below. The relative effects of the clock and of the misses in flight still stand.

**The setup.**
- **v1 as built.** The model is calibrated to the RTL, not to the plan:
  - one L1D miss in flight and one I-cache refill at a time (core-lsu.md, core-pipeline.md; the plan's 16 and 4 MSHRs are M6);
  - no prefetcher in the L1s or the L2;
  - the release configuration's window, queues and predictors (`smt2`, wakeup tags).

  The rows with 2 or 4 L1D misses in flight are the non-blocking-cache option.
- **One fix to the model.** With one L1D MSHR and SMT2, the model starved one thread's store drain for good. Loads book the MSHR at their access time (issue + 3), while the drain asks at the current cycle, so a sibling's stream of misses always got there first. After 500K cycles of no commits, the deadlock check stopped runs such as stride+spmv and chase8+copy.
  - `drain_guard` 16 now gives a committed store that has waited 16 cycles the next MSHR.
  - At 0 (the default) every earlier result is identical.
  - How the RTL arbitrates its one MSHR between the load pipe and the drain is not documented (core-lsu.md). Whether a thread's drain can starve behind its sibling's misses in `smt2` is a question for the core track.
- **NaxRiscv:** the control (`nax`), on the same uncore (so without an L2 prefetcher either), at 135 and 150 MHz.
  - Its core follows NaxRiscv's README and RTD pages, with 2 L1D refill slots. It matches NaxRiscv's published RV32 IPC within 9%, and its published RV64 DMIPS/MHz and Embench score within 2% ([dse_report.md](dse_report.md) §3).
  - NaxRiscv's published RV64 Fmax is 137 MHz on Artix-7 -3 (its RTD Performance page). 135 and 150 MHz on the XCK26 are the points asked for, not published figures.
- **1 thread:** one core alone, with the whole L2 and both HP ports.
- **4 threads:** both cores busy, each running SMT2 pairs (`smt.py`'s 42 suite pairs, and 16 working-set pairs). The model has one core, so each core gets half the L2's ways and MSHRs and one HP port.
  - NaxRiscv runs the 4 threads on a dual-core without SMT, each core time-slicing the same pairs: its throughput on a pair is the mean of the two programs' IPC.
  - Dual-core is the largest NaxRiscv SMP build published to meet timing: the 37C3 demo ran two RV64GC cores at 100 MHz, and NaxRiscv issue #89 reports trouble above two.
- **Memory at each clock:**
  - DRAM 184 ns (S1's idle read): 17, 18, 23, 25 and 28 cycles at 94, 100, 125, 135 and 150 MHz;
  - bandwidth: each HP port moves 16 bytes per cycle (S1's 3.2 GB/s per port is 128 bits at 200 MHz), so a line takes 4 cycles at any clock;
  - the L2 hit: 10 cycles (`DATA_LAT` 2, allowed up to 150 MHz).
- **The profiles** (DR-140, DR-144):
  - **the default:** the LSU's address-stage split (its TLB and PMP check a stage later) and a register on the atomics' read data are on. The extra store-completion cycle is off. The ROB head's TLB lookup comes a cycle later, from a register;
  - **the fallback:** none of these;
  - **the model** has one point for them: the address-stage split's extra cycle on a store's completion (`abl_st_done`). The atomics register and the ROB head's lookup have none, since the workloads use no atomics and the model has no TLBs.
- **Workloads:**
  - the suite: kernels, Embench and memsuite (8–32 MiB);
  - new working-set kernels (DR-141's 0.5–4 MiB, `bench/build_ws.sh`): a pointer chase on 1 and on 8 chains, hash-table lookups and memcpy, at 0.5, 1, 2 and 4 MiB, each warmed before its region.
- **Performance** is IPC × MHz, and the 4-thread figure is both cores' throughput × MHz. Each cell below is v1's figure divided by NaxRiscv's at 135 MHz / at 150 MHz.

| Clock | L1D misses in flight | 1 thread: suite | 1 thread: memsuite | 1 thread: 0.5–4 MiB | 4 threads: suite | 4 threads: memsuite | 4 threads: 0.5–4 MiB |
|---|---|---|---|---|---|---|---|
| 94 MHz | 1 (as built) | 0.82 / 0.75 | 0.58 / 0.55 | 0.62 / 0.58 | 0.96 / 0.89 | 0.53 / 0.51 | 0.68 / 0.64 |
| 94 MHz | 2 | 0.97 / 0.89 | 0.95 / 0.91 | 0.82 / 0.76 | 1.21 / 1.12 | 0.99 / 0.96 | 1.17 / 1.10 |
| 94 MHz | 4 | 1.07 / 0.99 | 1.29 / 1.24 | 0.97 / 0.90 | 1.44 / 1.34 | 1.66 / 1.60 | 1.55 / 1.46 |
| **100 MHz** | 1 (as built) | 0.86 / 0.79 | 0.60 / 0.58 | 0.66 / 0.61 | 1.00 / 0.93 | 0.53 / 0.51 | 0.69 / 0.65 |
| **100 MHz** | 2 | 1.02 / 0.94 | 0.98 / 0.94 | 0.86 / 0.80 | 1.26 / 1.17 | 1.00 / 0.97 | 1.21 / 1.14 |
| **100 MHz** | 4 | 1.13 / 1.04 | 1.34 / 1.29 | 1.02 / 0.95 | 1.51 / 1.40 | 1.71 / 1.64 | 1.61 / 1.52 |
| **125 MHz** | 1 (as built) | 1.03 / 0.95 | 0.64 / 0.62 | 0.77 / 0.71 | 1.19 / 1.10 | 0.57 / 0.55 | 0.76 / 0.71 |
| **125 MHz** | 2 | 1.21 / 1.12 | 1.06 / 1.02 | 1.01 / 0.94 | 1.50 / 1.39 | 1.09 / 1.05 | 1.33 / 1.25 |
| **125 MHz** | 4 | 1.36 / 1.25 | 1.49 / 1.44 | 1.20 / 1.11 | 1.82 / 1.68 | 1.88 / 1.82 | 1.80 / 1.69 |
| 150 MHz (reference) | 1 (as built) | 1.18 / 1.09 | 0.68 / 0.65 | 0.87 / 0.81 | 1.36 / 1.26 | 0.60 / 0.58 | 0.81 / 0.77 |
| 150 MHz (reference) | 2 | 1.40 / 1.29 | 1.12 / 1.08 | 1.15 / 1.07 | 1.71 / 1.59 | 1.13 / 1.09 | 1.42 / 1.33 |
| 150 MHz (reference) | 4 | 1.57 / 1.45 | 1.60 / 1.55 | 1.37 / 1.27 | 2.10 / 1.94 | 2.02 / 1.95 | 1.95 / 1.83 |
| NaxRiscv, 135 MHz | 2 (refill slots) | 1.00 / 0.92 | 1.00 / 0.96 | 1.00 / 0.93 | 1.00 / 0.93 | 1.00 / 0.96 | 1.00 / 0.94 |
| NaxRiscv, 150 MHz | 2 (refill slots) | 1.09 / 1.00 | 1.04 / 1.00 | 1.08 / 1.00 | 1.08 / 1.00 | 1.04 / 1.00 | 1.06 / 1.00 |

Every v1 row uses the default profile. The fallback changes nothing measurable (below).

**Reading it:**
- **As built, v1 loses to NaxRiscv on memory work at every clock here.** Its L1D takes one miss at a time, against NaxRiscv's two refill slots.
  - With one thread it reaches 0.58–0.68× NaxRiscv at 135 MHz on memsuite, and 0.62–0.87× on the working sets. Even working sets that fit in the L2 (0.5–1 MiB) run at 0.87× NaxRiscv's IPC.
  - On the suite it is 0.82× at 94 MHz, 0.86× at 100 MHz and 1.03× at 125 MHz.
  - Per clock, its lead is 1.11× on the suite and 0.69× on memsuite. DR-145 put the lead needed to win at 100–125 MHz at about 1.2–1.5×.
  - On code that stays in the caches (the kernels and Embench) its lead is 1.37–1.43×. So the core is ahead; the L1D's one miss at a time holds it back.
- **Misses in flight are worth more than the clock.**
  - At 125 MHz, a second L1D miss in flight adds 18% on the suite and 65% on memsuite with one thread, and 27% and 91% with four threads.
  - Four in flight add 32% and 132% with one thread, and 53% and 230% with four threads.
  - Going from 100 to 125 MHz adds 19–20% on the suite and 8–11% on memsuite. Going from 94 to 100 MHz adds 5–6% and 3–4%.
- **With four misses in flight, v1 leads NaxRiscv at 100 MHz and above, against NaxRiscv at 135 and at 150 MHz:**
  - one thread on the suite: 1.13 / 1.04 at 100 MHz, 1.36 / 1.25 at 125 MHz;
  - four threads on the suite: 1.51 / 1.40 and 1.82 / 1.68.

  Only one thread's working sets at 100 MHz stay at NaxRiscv's level (1.02 / 0.95). With two misses in flight, v1 leads at 125 MHz (1.21 / 1.12 on the suite), but at 100 MHz it falls behind NaxRiscv at 150 MHz (0.94).
- **What the RTL would cost is not measured here.** Earlier studies assumed the plan's L1D, which has 16 MSHRs and a stride prefetcher (M6). The LUTs and timing of 2 or 4 misses in flight are a question for the core track.
- **Four threads:**
  - SMT2 adds to v1's lead on compute: 1.19 / 1.10 on the suite at 125 MHz as built, against 1.03 / 0.95 with one thread.
  - As built, the two threads share the one miss at a time, so memsuite with four threads is 0.57 / 0.55. With four misses in flight it is 1.88 / 1.82.
- **The profiles.** In the model, the default's extra store-completion cycle changes the results only within noise:
  - one thread: under 0.01%;
  - four threads, the suite and memsuite: at most 0.3%;
  - four threads, the working sets: −0.8% to +2.1%. That is the pair method's noise: a few pairs that chase pointers through the one MSHR swing by up to 43%, while 46–48 of the 58 pairs move by under 0.1%.

  The measured costs below are the better guide.
- **CoreMark:**
  - v1 gets 5.31 CoreMark/MHz at every MSHR count, since CoreMark stays in the L1s.
  - The model's NaxRiscv gets 3.63 on the same binary, so v1 is 1.46× per MHz.
  - NaxRiscv's published 4.94 CoreMark/MHz comes from a modified build ([dse_report.md](dse_report.md) §3.2), so it doesn't compare directly.

**What this means for the choice** (each change is the user's call, DR-145):
- **As built,** 125 MHz roughly ties NaxRiscv at 135 MHz on the suite and loses on memory work. 100 MHz loses on both.
- **The L1D's misses in flight decide whether v1 leads.** With four, v1 leads at 100 MHz, and clearly at 125 MHz, with one thread or four.
- **The profiles don't move the clock choice.** They cost under 0.3% here and 0.25% on the board under Linux.

**The profiles, as measured outside the model.** The model has a point only for the store-completion cycle, and only on bare-metal code. These are the measured costs of the default against the fallback, as extra cycles (DR-140, DR-141, DR-144):
- **The cuts:**
  - **The LSU's address-stage split** (TLB and PMP check moved a stage later, so a store completes a cycle later) costs +0.16% / +0.09% on the RTL's benchmarks (`st` / `smt2`). The ISA tests cost up to +1.6%, in their page-table setup walks.
  - **The register on the atomics' read data** costs 0 on the benchmarks and +0.14% on the ISA tests.
  - **The ROB head's TLB lookup a cycle later, from a register** costs 0 on CoreMark and Dhrystone, and up to +0.16% on the stress tests.
- **The simulated Linux boot** (first 20M cycles): the default costs +0.08% / +0.12%, plus 0.013% / 0.005% for the ROB head's TLB lookup.
- **The board under Linux** (one `st` core at 60 MHz, 18 tests):
  - the default costs 0.25% on average;
  - the address-stage split and the atomics register together cost memcpy 1 MiB 1.9%, Dhrystone 1.5% and tlbwalk 1.1%, and syscall runs 2.4% faster.
- **In neither profile:** DR-143's register slice on the L2's memory reads adds a cycle to every L2 fill, +0.06% / +0.13% on the boot. The model leaves it out for v1 and NaxRiscv alike.

**Notes.**
- **The guard's own effect.** With one MSHR, `drain_guard` raises one thread's results by 0.4% on the suite and 1.1–1.3% on memsuite and the working sets. With four MSHRs it changes nothing.
- **§6.1's bandwidth was optimistic.**
  - It took 20 ns per line. But an HP port moves 16 bytes per cycle at any clock, so a line takes 4 cycles; at 150–170 MHz §6.1 used 3.
  - It also modelled one port, where one core alone has two.
- **§6.1's v1 had the plan's L1D, 16 MSHRs with prefetchers.** It put v1 at 1.78× NaxRiscv at 137 MHz on the suite at 150 MHz. As built, the same comparison is 1.18× at 135 MHz.

### 6.3 tgsim calibrated to the RTL as built (measured, 2026-10-17)

*The user asked why the hardware runs at about half the model's IPC. The RTL measures 2.73 CoreMark/MHz (flag set A) and about 1.39 DMIPS/MHz; the model's v1 gave 5.31 and 3.98. The model ran the plan's core. §6.2's "v1 as built" changed only the memory side, and kept a front end, a recovery and latencies the RTL does not have yet.*

*This section calibrates tgsim to the RTL program by program, then adds the M6 features back one at a time. It is a measurement only: no RTL or decision changes. `scripts/rtlcal.py` and `scripts/m6_steps.py` reproduce it on the build host.*

**The core as built, now a preset (`rtl_m2`).** This is revision 1, which this section's results use. §6.4's revision 2 adds four misses in flight and the RTL's issue queues and store address. The RTL (core-pipeline.md §1, §3, §5; core-lsu.md) has:
- **M2's front end:** the 64-entry, 2-way micro-BTB is the only predictor. 512 2-bit counters only decide whether it learns a branch. Decode repairs JAL targets and wrong targets of predicted-taken branches. There is no TAGE, block BTB, RAS or FTQ (`fe_m2`).
- **Recovery and wakeup:**
  - every mispredict recovers at commit;
  - loads wake their dependants on the confirmed result, 5 cycles;
  - MUL-to-use is 5, through a tag delay line with no MUL bypass;
  - no early retirement or completion buffer.
- **Memory side:** one L1D miss and one I$ refill at a time, no prefetchers, a radix-2 divider, and DR-140's default profile.

**Method: the same binaries in both simulators.**
- **tgsim's ISS runs the RTL platform's ELFs:** the 16550 console, `tohost` and `tg_marker`.
- **The RTL:** tg_vsim at main 6b0cbd8 (`st`, the default profile), the core on a flat memory of 30 cycles ("native") or 120, without an L2.
- **The programs:**
  - the RTL bench: CoreMark A and B with 2 iterations, and Dhrystone with 500 runs, on rv64im and rv64gcb;
  - 11 of the model's suite programs built with the RTL's runtime (`bench/build_rtl.sh`, rv64gc): 8 Embench programs and three 0.5 MiB working-set kernels.

**What the comparison calibrated** (from the RTL's commit trace and `scripts/rtl_mpcmp.py`):
- **The flush acts the cycle after commit.** A mispredict's refill, from its retire to the next retire, takes 13.5 cycles in the RTL against 11.9 in the model (`commit_redirect` 2).
- **The RTL trains its predictor on the wrong path too.**
  - Past a loop's exit it runs the loop again until the commit flush, and those copies of the branch train it not taken (`m2_wp_train` 2).
  - Found as loop branches that mispredict twice per entry in the RTL: CoreMark B's `bltu` at 0x80002eac, 1,297 against 653.
- **An L1 refill costs 13 cycles beyond the memory's latency** (`l1_fill_extra` 13). A dependent miss takes the latency plus 18 cycles in the RTL, against plus 5 in the model; the pointer chase now matches to 0.0%.
- **Store-to-load forwarding:** a forward completes at M2 like a hit (5), and a load waiting for the store's data replays (8).
- **MUL-to-use is 5,** from the spec. crc32's loop carries its dependence through a multiply.

**What the model cannot express, and what stands in for it:**
- **The wrong path.**
  - tgsim follows the correct path only. The RTL fetches, executes and trains its predictor on the wrong path until the commit flush.
  - The model stands in for this only at loop exits (`m2_wp_train`). Everywhere else it is missing, which leaves Dhrystone on rv64gcb and statemate 15–22% optimistic.
  - Wrong-path work taking issue slots, the one L1D MSHR or cache lines is not modelled either.
- **Recovery at commit itself is expressed** (`ckpt` 0 with `commit_redirect` 2). What it costs through the long wrong path is the item above.
- **When training happens.** The RTL trains the micro-BTB and its counters at execute; the model trains them at fetch, on the correct path.
- **The L1 refill is one lumped number** (`l1_fill_extra` 13) for the RTL's request, beats, install and load replay, fitted on the pointer chase. In the model, those parts cannot overlap other work the way they might in the RTL.
- **A load waiting for a store's data** replays in the RTL. The model charges a fixed 8 cycles from the data (`ld_fwd_wait`); no program here is sensitive enough to fit it.
- **Not found:** minver's FP path, where the model is 16% slow, and statemate's 30% slower execution between mispredicts.

**The result**, region cycles at native latency. At 120 cycles every program is within 2 points of these, except the copy and hash kernels.

| Program | Build | RTL | Model (`rtl_m2`) | Model's error |
|---|---|---|---|---|
| CoreMark A | rv64im | 659,278 | 622,706 | −5.5% |
| CoreMark B | rv64im | 694,227 | 686,747 | −1.1% |
| Dhrystone | rv64im | 170,736 | 155,952 | −8.7% |
| CoreMark A | rv64gcb | 758,871 | 722,094 | −4.8% |
| CoreMark B | rv64gcb | 682,060 | 686,698 | +0.7% |
| Dhrystone | rv64gcb | 191,865 | 162,443 | **−15.3%** |
| Embench crc32 | rv64gc | 2,621,397 | 2,364,400 | −9.8% |
| Embench edn | rv64gc | 2,322,031 | 2,298,473 | −1.0% |
| Embench huffbench | rv64gc | 2,908,025 | 2,773,471 | −4.6% |
| Embench matmult-int | rv64gc | 3,003,049 | 2,829,049 | −5.8% |
| Embench minver (FP) | rv64gc | 879,179 | 1,016,337 | **+15.6%** |
| Embench nsichneu | rv64gc | 5,359,581 | 4,955,210 | −7.5% |
| Embench statemate | rv64gc | 1,309,877 | 1,019,953 | **−22.1%** |
| Embench ud | rv64gc | 3,852,798 | 4,110,472 | +6.7% |
| Pointer chase, 1 chain, 0.5 MiB | rv64gc | 192,100 | 192,058 | 0.0% |
| memcpy, 0.5 MiB | rv64gc | 3,280,466 | 3,011,439 | −8.2% (−2.9% at 120) |
| Hash lookups, 0.5 MiB | rv64gc | 4,959,153 | 5,503,455 | +11.0% (+2.9% at 120) |

**Reading it:**
- **13 of the 17 programs are within 10%.** CoreMark is within 6% on both builds. Over all 17, the model is 4% optimistic on the geometric mean, with a mean absolute error of 7.6%.
- **Dhrystone on rv64gcb and statemate (the model is 15–22% optimistic): the RTL mispredicts more.**
  - It trains at execute on the wrong path, and with recovery at commit the wrong paths are long.
  - Dhrystone's always-taken `beq a4,a5,pc+6` (0x8000021c) mispredicts on all 500 calls in the RTL and 3 times in the model.
  - statemate takes 10% more refills on its data-dependent branches.
  - A correct-path model can follow wrong paths only for the loop-exit case above.
  - Between mispredicts, statemate also runs about 30% slower in the RTL. The cause is not found.
- **minver (the model is 16% pessimistic): FP.** The FPU's latencies match the RTL's (FMA 5, FMISC 2, divide 19 / 23), so the cause is in the model's FP issue path. Not found yet.
- **Checked against core-2's RTL counters** on its RAS head (f34b08a, `st`, native, the bench's rv64im ELFs):
  - **CoreMark A with the RAS:** 15.8 mispredicts per 1,000 instructions in the model, against 16.3 flushes in the RTL.
  - **The RAS's effect:**
    - CoreMark: −1.9% (A) and −0.8% (B) cycles in the model, against −1% to −2.3% in the RTL.
    - Dhrystone: +24% DMIPS/MHz in the model's suite build, against +22.7% in the RTL (1.667 → 2.046). On the bench ELFs the model takes 23% of the cycles off, against the RTL's 18.5%.
  - **Dhrystone with the RAS:** 13.3 mispredicts per 1,000 instructions in the model, against 18.6 flushes in the RTL. This is the wrong-path training above.
  - **How much runs on the wrong path:** the RTL resolves 37.6K conditional branches in Dhrystone, about 13K of them on the correct path. Most of its branch work is on the wrong path.
- **Why the model's v1 was twice the RTL,** largest first:
  - the front end: M2's micro-BTB alone predicts far worse than TAGE-lite with a block BTB and a RAS, and with recovery at commit each mispredict costs about 13 cycles;
  - one L1D miss in flight;
  - the latencies above.

**The M6 features, from the core as built** (DR-152 sets the clock to 100 MHz, and DR-153 starts M6, so this ranking sets M6's build order).
- **Workload:** the single-thread suite (rv64gc) at 100 MHz's latencies, with 115 MHz's alongside.
- **The SoC's uncore:** an L2 hit of 10 cycles, DRAM of 18 cycles at 100 MHz (21 at 115), and no L2 prefetcher.
- **The LUTs** are estimates per core, not measurements:
  - the plan's (feature_ledger.md: shares of the ≈41K-LUT core; DR-149 for 4 misses in flight);
  - for the RAS and the block BTB with FTQ, which the plan never estimated, this study's.

| Feature, alone on the core as built (100 MHz) | Suite IPC | CoreMark/MHz (A) | Dhrystone DMIPS/MHz | Suite at 115 MHz | LUTs per core | Suite gain per 1K LUTs |
|---|---|---|---|---|---|---|
| The core as built (`rtl_m2`) | 0.474 | 2.34 | 1.81 | 0.465 | — | — |
| TAGE-lite (4 × 4K) | +38.8% | +76.7% | +20.8% | +38.6% | 0.82K (+6 BRAM36) | +47% |
| 4 L1D misses in flight (DR-149) | +24.3% | 0 | 0 | +24.5% | 0.55K | +44% |
| Block BTB and FTQ (1K × 4, 32; fetch-directed prefetch) | +24.1% | +46.1% | +25.6% | +23.9% | ≈0.6K (this study's estimate) | +40% |
| RAS (32) | +3.2% | +1.4% | +24.1% | +3.2% | ≈0.1K (this study's estimate) | +32% |
| Checkpoint recovery (4) | +15.1% | +10.7% | +20.3% | +14.9% | 0.5K | +30% |
| 16 L1D and 4 L1I MSHRs (from 1) | +33.5% | 0 | 0 | +33.9% | ≈1.2K | +28% |
| Speculative wakeup (hit predictor, 2-cycle shadow) | +5.3% | +15.9% | +8.3% | +5.3% | 0.5K | +11% |
| Prefetchers (L1D stride, ownership, L2 stream, I$ next-line) | +3.2% | 0 | 0 | +3.7% | ≈0.95K | +3% |

**Stacked in the recommended order.** Each step adds the remaining feature with the best suite gain per LUT on top of the stack (100 MHz):

| Step | Suite IPC | CoreMark/MHz (A) | Dhrystone DMIPS/MHz | LUTs added | Running LUT total | Step's suite gain per 1K LUTs |
|---|---|---|---|---|---|---|
| The core as built | 0.474 | 2.34 | 1.81 | — | 0 | — |
| + TAGE-lite | 0.658 | 4.13 | 2.19 | 0.82K | 0.82K | +47% |
| + 4 misses in flight | 0.858 | 4.13 | 2.19 | 0.55K | 1.37K | +55% |
| + RAS | 0.895 | 4.24 | 2.86 | 0.10K | 1.47K | +44% |
| + block BTB and FTQ | 0.979 | 4.68 | 3.72 | 0.60K | 2.07K | +16% |
| + 16 L1D and 4 L1I MSHRs | 1.053 | 4.69 | 3.72 | 0.65K | 2.72K | +12% |
| + prefetchers | 1.130 | 4.69 | 3.72 | 0.95K | 3.67K | +8% |
| + speculative wakeup | 1.166 | 5.27 | 3.79 | 0.50K | 4.17K | +6% |
| + checkpoint recovery | 1.182 | 5.31 | 3.79 | 0.50K | 4.67K | +3% |

In the plan's order, the suite runs 0.474 → 0.489 (RAS) → 0.687 (TAGE-lite) → 0.751 (block BTB and FTQ) → 0.759 (checkpoints) → 0.784 (speculative wakeup) → 1.024 (4 misses) → 1.101 (16 MSHRs) → 1.182 (prefetchers). Both orders end at the same core.

**Reading it:**
- **Where IPC per LUT runs out: after the first three steps.**
  - TAGE-lite, 4 misses in flight and the RAS cost about 1.5K LUTs. They take the suite from 0.474 to 0.895 (+89%), CoreMark from 2.34 to 4.24 and Dhrystone from 1.81 to 2.86.
  - Every later step returns 16% per 1K LUTs or less: the block BTB and FTQ +16%, 16 MSHRs +12%, the prefetchers +8%, speculative wakeup +6% and checkpoints +3%.
  - The remaining 3.2K LUTs add another 32% on the suite.
- **The front end matters most for CoreMark and Dhrystone.** TAGE-lite alone adds 77% on CoreMark. The block BTB and FTQ, with the RAS, add the rest: CoreMark 4.68 and Dhrystone 3.72.
- **Checkpoint recovery is worth 15% alone but 1–3% once the front end predicts well,** so it goes last.
- **Misses in flight do nothing for CoreMark and Dhrystone,** which fit in the L1. But they are the largest gain on the suite after TAGE-lite.
- **The RAS is cheap and helps Dhrystone most** (+24% alone, +31% after TAGE-lite and the misses). Starting M6 with it, as core-2 has, costs little whatever comes next.
- **100 against 115 MHz:** every feature's gain is within 0.5 points at both clocks.
- **The LUT figures decide the order**, and two are this study's estimates. If the RAS cost 0.3K it would still return 14% per 1K LUTs. If the block BTB and FTQ cost 1K, they would fall to about +9%.
- **The plan's whole M6 core** is 2.5× the core as built on the suite, 2.3× on CoreMark and 2.1× on Dhrystone.

**The block BTB and FTQ step, broken down** (core-2's question before building it, 2026-10-17; `scripts/m6_btb.py`). These start from the recommended stack before that step (TAGE-lite, 4 misses in flight, the RAS), at 100 MHz:

| Front end | Suite IPC | CoreMark/MHz (A) | Dhrystone DMIPS/MHz |
|---|---|---|---|
| As ranked: TAGE-lite's and the RAS's redirects at decode | 0.895 | 4.24 | 2.86 |
| core-2's (c48b1ce): TAGE-lite overrides at F2 with pre-decoded direct targets (1-cycle bubble); returns at decode | 0.965 | 4.56 | 3.27 |
| The same, with a 2-cycle bubble | 0.948 | 4.50 | 3.18 |
| core-2's, with returns also repaired from the RAS at F2 (1-cycle bubble) | **0.981** | 4.58 | **3.72** |
| The same, with a 2-cycle bubble | 0.966 | 4.52 | 3.67 |
| The plan's: block BTB (1K × 4), FTQ with fetch-directed prefetch, RAS at fetch | 0.979 | **4.68** | 3.72 |
| The plan's, without fetch-directed prefetch | 0.979 | 4.68 | 3.72 |

**Reading it:**
- **Most of the step's gain came from the ranking's decode-time redirects.**
  - These were TAGE-lite's taken branches without a micro-BTB target (36 decode redirects per 1,000 instructions on CoreMark) and the RAS's returns.
  - Repairing both at F2 from pre-decode, as core-2's front end already does for branches, gets all of it on the suite and on Dhrystone.
  - On Dhrystone the returns alone are 3.27 → 3.72. Repaired at decode, each of the 17.5 returns per 1,000 instructions that the micro-BTB misses waits about 7 cycles behind a backed-up instruction queue.
- **What a block BTB adds after that is indirect jumps' targets.** CoreMark goes from 4.58 to 4.68 (+2.2%): its 0.9 indirect mispredicts per 1,000 instructions don't fit in the 64-entry micro-BTB. The suite as a whole gains nothing.
- **Not from these:**
  - zero-bubble taken prediction beyond 64 blocks: the model's main BTB costs a 2-cycle bubble, which is more bubble cycles than a 1-cycle F2 override;
  - fetch-directed prefetch: 0, because one I$ refill at a time leaves it nothing to issue and the suite fits the I$;
  - prediction running ahead of fetch: not modelled.
- **The F2 bubble:** 2 cycles instead of 1 costs about 1.6% on the suite.
- **Checked against core-2's c48b1ce counters** (CoreMark A, the bench's rv64im ELF, native), with the model running core-2's structure:
  - mispredicts: 4.9 per 1,000 instructions in the RTL against 2.5 in the model (the RTL's wrong-path training again);
  - F2 overrides: 21.6 against 14.9;
  - decode redirects: 2.0 against 1.4.

  The RTL's counts may include wrong-path fetch.

**§6.2 and DR-149 with the core as built** (one core alone, the same uncore and NaxRiscv model as §6.2):
- **At 100 MHz with 4 misses in flight,** v1 reaches 0.56× NaxRiscv at 135 MHz and 0.52× at 150 MHz on the suite, and 0.72× / 0.69× on memsuite.
- **With 1 miss** it reaches 0.45× / 0.42×.
- **So §6.2's "v1 leads NaxRiscv at 100 MHz with 4 misses" does not hold for the core as built.** It assumed the plan's front end and recovery.
- **Per clock,** v1 as built with 4 misses in flight does 0.76× NaxRiscv's work on the suite.

### 6.4 The first M6 stack, checked against the RTL (measured, 2026-10-17)

*core-2 measured M6's first three steps in RTL: the RAS, TAGE-lite overriding at F2, and returns repaired at F2 with the straddler fix, all on main cee5332's four misses in flight. With make perf, CoreMark gained 25% and Dhrystone 49–64%. With §6.3's settings for the same stack, the model said 42–58% and 101–104%. This section finds why, in the RTL itself, and folds the answer into `rtl_m2`. It is a measurement only: no RTL or decision changes. `scripts/m6_rtlcheck.py` reproduces it on the build host.*

**Method.**
- **The same ELFs:** make perf's own (`tests/bench`: CoreMark with 10 iterations, Dhrystone with 500 runs), rv64im and rv64gc, on tg_vsim's memory at native latency, timed regions.
- **The RTL:** a scratch build of core-2's measured head (96a1c81: bdd787c on main cee5332). Measurement-only profile binds (`scripts/rtlprof/`) count:
  - F2's refetches by kind;
  - commit's flushes by cause, with the PCs of replayed loads;
  - rename's stalls by cause;
  - decode's take per cycle.

  The build reproduces core-2's scores exactly: 3.808, 3.607, 2.426 and 2.431. A second build profiles main (17f9c46, the same core as cee5332).
- **Steady state:** in both simulators, the 20-iteration / 1,000-run whole runs minus the 10 / 500 ones, so start-up and printf cancel. A whole run alone misleads on Dhrystone: printf takes half its cycles, and there the model is slower than the RTL.

**Per program: main → the stack, the RTL against the model as each correction is added** (CoreMark/MHz and DMIPS/MHz):

| Program | RTL | 1. §6.3's settings | 2. + TAGE-lite as built | 3. + the RTL's issue queues | 4. + the store address waits for its data (`rtl_m2` now) |
|---|---|---|---|---|---|
| CoreMark A rv64im | 3.056 → 3.808 (+24.6%) | 3.236 → 4.634 (+43.2%) | 3.236 → 4.339 (+34.1%) | 3.136 → 4.079 (+30.1%) | 3.120 → 3.961 (+27.0%) |
| CoreMark B rv64im | 2.896 → 3.607 (+24.6%) | 2.935 → 4.481 (+52.7%) | 2.935 → 4.253 (+44.9%) | 2.841 → 3.936 (+38.5%) | 2.817 → 3.780 (+34.2%) |
| Dhrystone rv64im | 1.632 → 2.426 (+48.7%) | 1.825 → 3.665 (+100.9%) | 1.825 → 3.668 (+101.0%) | 1.720 → 3.232 (+87.9%) | 1.654 → 2.563 (+55.0%) |
| CoreMark A rv64gc | 3.064 → 3.779 (+23.3%) | 3.203 → 4.556 (+42.2%) | 3.203 → 4.309 (+34.5%) | 3.112 → 4.041 (+29.8%) | 3.097 → 3.859 (+24.6%) |
| CoreMark B rv64gc | — → 3.577 | 2.834 → 4.463 (+57.5%) | 2.834 → 4.247 (+49.8%) | 2.763 → 3.927 (+42.2%) | 2.741 → 3.719 (+35.7%) |
| Dhrystone rv64gc | 1.483 → 2.431 (+63.9%) | 1.797 → 3.673 (+104.4%) | 1.797 → 3.632 (+102.1%) | 1.716 → 3.258 (+89.9%) | 1.679 → 2.501 (+48.9%) |

- **Error on the stack's own score:** +21–51% at step 1, +14–51% at step 2, +7–34% at step 3 and +2–6% at step 4.
- **What is left in the gains:** CoreMark B (+34% against +25%) and Dhrystone rv64gc (+49% against +64%). Both come from the model's base, which is 2.7% slow on the first and 13% fast on the second.
- **Where the scores come from:** the RTL's rv64gc CoreMark scores on the stack are this build's. core-2's message gave main's CoreMark A rv64gc.

**What the model did not have, largest first.** Each is the RTL as built, and each now has a knob:
1. **The store address waits for its data.**
   - **The rule:** rename makes a store's IQ-STA row depend on its data register as well as its base (`tg_rename.sv`: `iq_dep` and `iq_mdep` take rs2 for every C_ST). core-lsu.md describes the STA pipe as address-only, with the data captured later through the shared port.
   - **What it does:** a younger load to the same address can issue first. It reads the old value and is replayed at commit. The rows also hold IQ-STA's four entries until the data is ready.
   - **Dhrystone:** this happens twice per run, at two loads:
     - `Proc_2`'s read of `Int_1_Loc`, whose store waits for a `divw`;
     - main's read of `Int_3_Loc`, after `Proc_7` stores it through a pointer.

     That is 7.1 replays per 1,000 instructions in the RTL's steady state, and none in the model, which issued store addresses on their base alone (`sta_split` 1).
   - **With `sta_split` 0** the model replays as the RTL does: Dhrystone 2.0 per run; on main, ud 7,390 against 7,395 and huffbench 99 against 72.
2. **The issue queues are banked by dispatch slot, and a row is held two cycles after its select** (`tg_iq.sv`, plan §4.15).
   - **Banks:** decode slot k's uop writes only bank k, so a group waits until both its slots' banks have a row. IQ-STA's four rows are two per slot. Rename steers an ALU op to queue k mod 2 unless that bank is full.
   - **The hold:** a row is freed two cycles after its select, by the speculative-wakeup shadow, which is there whether or not speculative wakeup is on. Dispatch reuses it three cycles after the select.
   - **How much it holds dispatch:** with the stack, a full bank held the dispatch stage in 26% of CoreMark A's cycles and 19% of Dhrystone's. The model treated each queue as one pool, freed at issue.
   - **Knobs:** `iq_slot_bank` 1, `iq_hold` 3.
3. **TAGE-lite as built mispredicts about twice as often as the model's.**
   - **The RTL** reads TAGE once per 16-byte block:
     - a 2K-block base with a counter per slot;
     - four 1K-entry tables of two slot-tagged sub-entries;
     - histories of 4/9/18/40 conditional-branch bits, the lookup one block behind;
     - training from commit through a 4-entry queue, one request every two cycles.
   - **The model's TAGE-lite** was per branch, with path history, 8–64 bits and 4K entries.
   - **Accuracy:** CoreMark A's mispredict flushes are 2.9 per 1,000 instructions in the RTL's steady state. The model's TAGE-lite left 1.4, 1.2 of them direction.
   - **Knob:** `m2_btage` reproduces the RTL's flushes: 3.4K against 3.5K in CoreMark A's 2-iteration run (core-2's profile), and 2.7 against 2.9 per 1,000 instructions in steady state.
   - **Within it:**
     - the block form (sub-entries, branch-only history) is most of the loss: CoreMark −5% of the stack's score;
     - the one-block lag and the queue's drops (2% of requests) move it under 1%;
     - 1K against 4K entries changes nothing on these programs (+0.0–0.2%).
4. **Smaller:**
   - a block ends before its third conditional branch and is refetched (`m2_cut`);
   - an F2 override costs 2 cycles, as F2's action is registered (`m2_f2_bubble` 2);
   - the FTQ has 32 entries (`m2_ftq`), almost never full.

   Each moves the stack by 1% or less.

**The three suspects named before the check:**
- **The bench build's CoreMark against the suite's.** §6.3's +77% for TAGE-lite alone was a different setup: the suite's CoreMark build on the SoC's uncore at 100 MHz, with the model's own TAGE redirecting at decode. On make perf's ELFs the same model gave +43%. The model-against-RTL gap on identical ELFs was items 1–3 above, not the build.
- **The wrong-path training.** TAGE trains at commit in the RTL, so it sees no wrong path, as in the model. The micro-BTB's wrong-path training at loop exits (`m2_wp_train` 2 against 0) moves the stack under 0.2%.
- **TAGE's size and update timing.** Neither matters: 1K against 4K entries, and the training queue, are each under 1%. Its block form is item 3.

**What remains.**
- **More F2 refetches in the RTL:** 25 against 18 per 1,000 instructions in CoreMark A, counting overrides and cuts, partly on the wrong path the model does not run.
- **But the RTL's instruction queue hides them:** decode is starved in only 2–3% of its cycles on CoreMark, and 7% on Dhrystone, mostly refilling after its replays. With the stack, the RTL is held by its backend, not its front end.

**`rtl_m2` recalibrated** (revision 2, keyed separately in dse's cache; it tracks main):
- **The changes:**
  - `l1d_mshr` 4: four misses in flight are main's default since DR-156;
  - `iq_slot_bank` 1, `iq_hold` 3, `sta_split` 0: items 1 and 2.
- **Against main** (17f9c46, at native latency) on §6.3's 17 programs:

  | Model | Mean error | Worst |
  |---|---|---|
  | Revision 1 with four misses | 8.6% | 22.1% (statemate) |
  | + the issue queues | 7.3% | 18.3% (ws_hash) |
  | + the store address (revision 2) | 7.5% | 19.7% (minver) |

  Revision 2 moves:
  - Dhrystone rv64gcb −15.3% → −2.5%;
  - statemate −22.1% → −7.8%;
  - crc32 −9.8% → −6.5%;
  - matmult-int −5.9% → +11.9%, and ud +6.7% → +12.1%.
- **Why the store-address rule stays despite matmult-int and ud:** on core-2's stack those two match the RTL (+0.4% and 0.0%), and so do the replay counts (minver 1,111 against 1,107, edn 1,318 against 1,231).
- **The M6 stack's knobs** join `rtl_m2` when the stack lands on main: `ras` 32, `m2_dir` 1, `dirpred` 2, `m2_f2` 1, `m2_ras_f2` 1, `m2_btage` 1, `m2_cut` 1, `m2_f2_bubble` 2, `m2_ftq` 32.
- **§6.3's M6 tables were made with revision 1** (one miss, no issue-queue rules) and stand as history. Ranking M6's remaining steps on revision 2 is a separate run.

**Two RTL questions for core-2** (`m6_rtlcheck.py --levers`; the model's estimates, not decisions):

| Lever, in the recalibrated model | Main: CoreMark / Dhrystone | The stack: CoreMark / Dhrystone |
|---|---|---|
| The store address issues on its base alone, as core-lsu.md describes (rs2 left out of IQ-STA's dependencies) | +0.5–0.9% / +2–4% | +3–6% / **+26–30%** |
| A row is freed at its select while speculative wakeup is off (no shadow to keep) | −0.3–+1.6% / +3–4% | +0.3–3.5% / +4–5% |
| Both | +0.1–2.6% / +5–8% | +4–10% / +20–21% |

- **The first lever looks like the larger of the two.** Store data already has its own capture path, so the STA may not need to wait for it.
- **The second only matters while speculative wakeup stays off.** M6's speculative wakeup needs the shadow.

### 6.5 What M6's remaining pieces buy per 1K LUTs, from main with the RAS (modelled, 2026-10-18)

*The user's next M6 choice is about area. DR-162 accepted a few MHz below 100, and TAGE-lite then measured at twice its estimate. This section estimates what each remaining piece buys per 1K LUTs, and what each further 1K buys when they are stacked. It starts from main as it is: four misses in flight, speculative wakeup, and the RAS. The model is `rtl_m2` revision 3 with the RAS (`scripts/m6_area.py`, on the build host).*

**The base, checked against the RTL first.**
- **The RTL:** core-2's RAS head (58674a7: the RAS at decode on main c841a27, speculative wakeup on).
- **The model:** `rtl_m2` revision 3, which adds main's speculative wakeup:
  - an integer load's dependants issue three cycles after it, with no hit predictor;
  - a load that does not complete in M2 cancels the integer queues' issues of the next three cycles;
  - FP loads wake on the confirmed result.

  The RAS is added explicitly until it lands on main.
- **The fit** (make perf's ELFs and the 11 RTL-built suite programs, native latency; `results/rtlcal_rashead_r3.json`):
  - CoreMark within 3% (A −2.8% / −0.8%, B +3.0% / +1.6% cycles, rv64im / rv64gc);
  - Dhrystone 6–10% optimistic;
  - the mean over 17 programs is 7.7%. minver, ws_hash, ws_copy, matmult-int and ud are outside 10%, as in §6.4.

  These runs reproduce core-2's RAS-head scores exactly: 3.461, 3.274 and 2.122.

**Setup.**
- **Suite:** the single-thread suite (rv64gc, 33 programs) on the SoC's uncore at 100 MHz, as §6.3 ran it: the 1 MiB L2 with a 10-cycle hit, and DRAM at 18 cycles.
- **Bench:** make perf's ELFs (CoreMark 10 iterations, Dhrystone 500 runs; rv64im and rv64gc; latency 30 and 120). The geometric mean of cycles, as make perf reports it.
- **TAGE-lite** is core-2's form at F2, with returns still repaired at decode, as in core-2's size study. Its 1–4 tables use that study's histories (`btage_nt`).
- **LUTs per chip** are two smt2 cores; the L2 stream prefetcher counts once.
  - **Measured where core-2 has measured:** TAGE-lite's whole-core estimates from `reports/m6-tage-size.md`, and the F2 return repair.
  - **Estimated elsewhere:**
    - more misses in flight: DR-149's measured +543 LUTs in the D$ for entries 1 → 4, per entry;
    - everything else: the plan's ledger (feature_ledger.md).
  - **Where measured since, the ledger ran 2–3× low:** TAGE-lite came in at 2.2× its estimate, and the four misses at 2.6–3×.

**Each piece alone** (gain against main with the RAS; for the memory side and checkpoints, also on top of TAGE-lite 4 × 1K):

| Piece | LUTs per chip (source) | Suite IPC | make perf cycles (model) | make perf (RTL, core-2) | Suite gain per 1K LUTs | After TAGE-lite 4 × 1K: suite gain |
|---|---|---|---|---|---|---|
| TAGE-lite 1 × 1K | 1,880 (measured) | +35.8% | −16.7% | −12.3% | +19.0% | — |
| TAGE-lite 2 × 1K | 2,540 (measured) | +40.0% | −20.5% | −16.0% | +15.7% | — |
| TAGE-lite 3 × 1K | 2,840 (measured) | +39.9% | −21.2% | −16.6% | +14.1% | — |
| TAGE-lite 4 × 1K | 3,180 (measured) | +40.5% | −21.4% | −16.8% | +12.7% | — |
| Returns repaired at F2 (with TAGE-lite) | 60 (measured, within noise) | +0.1% | −0.1% | | +1.7% | — |
| 8 L1D misses in flight (from 4) | ≈1,200 (estimate) | +4.5% | 0 | | +3.8% | +4.6% |
| 16 L1D misses in flight | ≈3,400 (estimate) | +6.1% | 0 | | +1.8% | +6.2% |
| 4 I$ refills (from 1) | ≈500 (estimate) | 0 | 0 | | 0 | 0 |
| L1D stride prefetcher | ≈600 (ledger) | +0.9% | 0 | | +1.5% | +0.8% |
| Ownership prefetch for stores | ≈200 (ledger) | +0.2% | 0 | | +0.9% | +0.2% |
| L2 stream prefetcher | ≈150 (ledger, once per chip) | +2.2% | 0 | | +14.9% | +2.2% |
| I$ next-line prefetch | ≈200 (ledger) | 0 | 0 | | 0 | 0 |
| Checkpoint recovery (4) | ≈1,000 (ledger) | +16.0% | −8.2% | | +16.0% | +2.1% |

**Stacked, what each further 1K of LUTs buys.**
- **Order:** each step is the piece with the best marginal suite gain per LUT from the runs above. Each step is measured on top of the ones before it.
- **Suite IPC** is against main with the RAS's 0.613.
- **The RTL column** is core-2's size study, at the same TAGE-lite size.

| Step | LUTs added per chip | Running total per chip | Suite IPC | make perf cycles (model / RTL) | Step's suite gain per 1K LUTs | Step's bench speed-up per 1K LUTs |
|---|---|---|---|---|---|---|
| + TAGE-lite 1 × 1K | 1,880 | 1,880 | 0.832 (+35.8%) | −16.7% / −12.3% | +19.0% | +10.7% |
| + L2 stream prefetcher | ≈150 | ≈2,030 | 0.851 (+38.8%) | −16.7% | +15.0% | 0 |
| + TAGE-lite's second table | 660 | ≈2,690 | 0.877 (+43.1%) | −20.5% / −16.0% | +4.7% | +7.3% |
| + 8 L1D misses in flight | ≈1,200 | ≈3,890 | 0.917 (+49.7%) | −20.5% | +3.8% | 0 |
| + Checkpoint recovery (4) | ≈1,000 | ≈4,890 | 0.934 (+52.4%) | −21.7% | +1.8% | +1.5% |
| + Returns repaired at F2 | 60 | ≈4,950 | 0.935 (+52.5%) | −21.7% | +1.3% | +0.6% |
| + L1D stride prefetcher | ≈600 | ≈5,550 | 0.959 (+56.5%) | −21.7% | +4.3% | 0 |
| + Ownership prefetch for stores | ≈200 | ≈5,750 | 0.957 (+56.2%) | −21.7% | −0.9% | 0 |
| + 8 → 16 L1D misses in flight | ≈2,200 | ≈7,950 | 0.981 (+60.0%) | −21.7% | +1.1% | 0 |
| + 4 I$ refills | ≈500 | ≈8,450 | 0.981 (+60.0%) | −21.7% | 0 | 0 |
| + I$ next-line prefetch | ≈200 | ≈8,650 | 0.981 (+60.2%) | −22.0% | +0.4% | +1.7% |
| + TAGE-lite's third table | 300 | ≈8,950 | 0.982 (+60.2%) | −22.7% / −16.6% | +0.2% | +3.0% |
| + TAGE-lite's fourth table | 340 | ≈9,290 | 0.988 (+61.2%) | −22.7% / −16.8% | +1.8% | +0.1% |

**Reading it.**
- **TAGE-lite's first table buys the most per LUT.** It costs 1.9K LUTs per chip, measured, and the RTL gives −12.3% make perf cycles.
  - The model says −16.7% on the bench and +36% on the suite. Its first step is optimistic by about 4.4 points on the bench, where the RTL's speed-up is 0.7× the model's, so expect the suite's real gain nearer +25%.
  - The steps between sizes match the RTL: 1 → 2 tables −3.8 against −3.6 points, 2 → 3 −0.7 against −0.6, 3 → 4 −0.2 against −0.2.
- **The second table is the next best measured buy.** 660 LUTs per chip give −3.6 points of make perf in RTL, and +3.1% on the suite in the model. The third and fourth tables add 640 LUTs per chip for −0.8 points in RTL: the least value of the TAGE-lite options.
- **On the memory side,** 8 misses in flight (+4.5% on the suite, all of it memory-bound programs) and the L2 stream prefetcher (+2.2%) are the cheaper buys. 16 misses (+1.1% per 1K after 8) and the stride prefetcher come later.
  - All their LUTs are estimates. If they run 2–3× high, as TAGE-lite and the four misses did, their gains per 1K halve or worse.
  - The bench shows nothing for them: CoreMark and Dhrystone fit in the L1.
- **Checkpoint recovery** is worth +16% alone but +2.1% after TAGE-lite, since fewer mispredicts are left to recover from quickly.
- **The I-side pieces** (4 I$ refills, next-line prefetch) show nothing, because no suite program has more code than the L1I. Linux does: the ledger's exception E1 found +34% and +30% on a ~200 KiB-code kernel trace. They should be judged on the board's Linux runs.
- **Where IPC per LUT drops:** after about 2.7K LUTs per chip (TAGE-lite with two tables and the L2 stream prefetcher), every further 1K buys under 5% on the suite. After about 5K, it buys under 2%, except the stride prefetcher, at 4%.

**Limits.**
- **Single-thread only:** SMT2's two threads, which raise the value of misses in flight, are not run.
- **The suite is a proxy;** Linux is the workload.
- **The clock:** the memory-side gains are at 100 MHz's DRAM latency. A few MHz less changes them by under a point.

### 6.6 Speculative wakeup's cancels, measured in the RTL (2026-10-18)

*§6.5's model overshot TAGE-lite's first step on the bench by about 4 points, and the suspect was the cancels of speculative wakeup. fpu-2 profiled the RTL's cancels by cause on the RAS head and the TAGE-lite build, with simulation-only counters (`claude/track-fpu-395911-swprof`; the tables are in fpu-2's `swprof/` on the build host). This section fits the model to that profile (`scripts/m6_swfit.py`).*

**What the RTL cancels on** (steady state, the RAS head):
- **D$ row clashes:** half of CoreMark's cancels (1.7–2.6 per 1K instructions) and three quarters of Dhrystone's (10).
  - **The rule** (`tg_lsu.sv`, `m1_clash`): a load reads its D$ row at AG while stores drain through port B. If a store to the load's 16-byte block is acked in the load's AG cycle or the cycle before, the load read old data and retries. The cycle before counts because of the registered port-B write, a default timing cut.
  - **Where they happen:** loads that follow a store to the same block. On Dhrystone it is reloads of stack slots just written. On statemate, edn and ud it is adjacent bytes and halfwords.
- **Wrong-path faults,** the other half on CoreMark: loads past a mispredict that fault in M1 on bare metal's unmapped addresses. They are flushed with the wrong path, which the model does not run. With TAGE-lite they fall to a quarter–a third.
- **The store-data capture lagging,** 6–15% of cancels: the store's data register was written, but its value was not yet in the SQ's data RAM (one capture a cycle). There are no forwards that fail to cover, no late producers, and no misses on the bench.
- **The cost:** about 4 integer ops killed and replayed per cancel, and 3.6–3.8 cycles from the failed check to completion.

**In the model, now in `rtl_m2` revision 4:**
- **`dc_row_clash`** (`clash_delay` 4), the RTL's rule on two paths:
  - a load reading the D$ as such a store drains;
  - a load whose forwarding store, committed at the SQ's head or next, drains before the load's M1. The model used to forward these, because it decides at issue; the RTL searches the SQ at M1, when the store is gone.
- **`spec_fwd`:** with speculative wakeup, a forward completing at M2 wakes its dependants as a hit does, in 3 cycles rather than 5.

**What they move** (each program's 500-run / 10-iteration region, the model against the RTL):

| Program | RAS head, revision 3 | RAS head, revision 4 | TAGE-lite build, revision 3 | TAGE-lite build, revision 4 |
|---|---|---|---|---|
| CoreMark A rv64im | −2.8% | −2.9% | −4.9% | −4.5% |
| CoreMark B rv64im | +3.0% | +3.0% | −6.1% | −6.3% |
| Dhrystone rv64im | −6.4% | −1.0% | −10.3% | −9.5% |
| CoreMark A rv64gc | −0.8% | −0.9% | −4.3% | −4.1% |
| CoreMark B rv64gc | +1.6% | +1.6% | −8.2% | −8.4% |
| Dhrystone rv64gc | −10.3% | −8.2% | −13.6% | −11.1% |

- **On the 17 programs** against the RAS head, the mean error goes from 7.7% to 7.3%. Statemate improves from −9.0% to −8.5%; the worst is still minver at +19.8%.
- **The clash count is still low:** 0.5–1.0 per 1K instructions on CoreMark against the RTL's 1.7–3.0. The model also makes twice the RTL's forwards. In the RTL, more of the loads that follow a store meet it as it drains, and fewer while it waits in the SQ. The cycle effect on CoreMark stays under 0.5%.

**TAGE-lite's first step is not the cancels.**
- **What remains:** with both rules, the TAGE-lite build is still 4–8% optimistic on CoreMark, against −3% to +3% on the RAS head.
- **Why not the cancels:** the RTL's cancels come to about 1% of CoreMark's cycles, and the model's rules move it under 0.5%.
- **The next suspect** is the front end, now that speculative wakeup speeds up the backend. §6.4 found the RTL refetching at F2 about 40% more often than the model, which the slower backend used to hide.

**A trap in the method: Dhrystone's two lengths are two layouts.**
- **The layouts:** the 1000-run ELF lays its code out 0x54 bytes later than the 500-run one (CoreMark's are identical), so their difference mixes two binaries.
- **The RAS head is layout-sensitive in RTL:** 134.1K cycles per 500 runs in one binary and 127.8K in the other. TAGE-lite removes most of the difference: 117.8K and 118.3K.
- **What it does to make perf:** its +13.9% for TAGE-lite on Dhrystone is +8.0% in the other binary.
- **The fix:** compare Dhrystone binary by binary, as the table above does.

**For §6.5:** revision 4 moves Dhrystone by a few points and CoreMark by under 0.5%, so its ranking stands. Its script pins revision 3.

### 6.7 The front end of the TAGE-lite build, measured in the RTL (2026-10-18)

*§6.4 found the RTL refetching at F2 about 40% more often than the model, and §6.6 left the TAGE-lite build 4–8% optimistic. This section profiles every F2 refetch and redirect by cause in the RTL, on the tree core-2 will merge: fpu-2's `claude/track-fpu-395911-f2cut` at 1e4a503, which is c149fce's M6 set (the RAS, two-table TAGE-lite, returns and straddlers at F2, four misses, speculative wakeup) with F2 restructured, cycle for cycle the same as c149fce. The bind is measurement-only (`scripts/rtlprof/prof_f2cut.sv`). It ran on make perf's ELFs (timed regions) and on the Linux boot's first 20M cycles (`tb_boot`, one core). `scripts/m6_fe.py` sets the model beside it (`results/m6_fe_rv64.json`).*

**How a cause is costed:** in each cycle rename can take a group but the instruction queue offers fewer than two instructions, the missing decode slots are charged to the front end's last event. With no event in the last 32 cycles they go to "steady fetch". The model counts the same way. A run of back-to-back I$ misses counts as one event, so in the boot part of their cost falls to steady fetch (item 2 below).

**What the RTL loses, by cause** (rv64gc, percent of cycles; events per 1K instructions in brackets):

| Cause, in hardware terms | CoreMark A | CoreMark B | Dhrystone | Boot, first 20M cycles |
|---|---|---|---|---|
| I$ miss: fetch waits for the line | 0.06% | 0.06% | 0.29% (0.1) | **9.60%** (7.3) |
| Steady fetch: no front-end event in the last 32 cycles | 0.09% | 0.08% | 0.12% | **4.34%** |
| Trap, interrupt or serializing instruction (CSR access, fence, xRET): the refill after its flush | – | – | – | **1.58%** (3.4) |
| Mispredict: the refill after its flush at commit | **1.60%** (4.0) | **1.29%** (3.7) | 0.02% | **1.50%** (6.6) |
| Replay at commit (on the bench, a load that ran before an older store to its address): the refill | 0.38% (0.9) | 0.42% (1.0) | **2.62%** (7.0) | 0.45% (2.2) |
| ITLB walk | – | – | – | 0.89% (0.8) |
| F2: the taken exit is at another slot than the micro-BTB's | 0.55% (3.3) | 0.33% (5.7) | **1.99%** (17.9) | 0.30% (8.1) |
| F2: a taken branch the micro-BTB missed | 0.39% (9.4) | 0.54% (5.3) | 0.14% (7.6) | 0.99% (13.4) |
| F2: a JAL the micro-BTB missed | 0.24% (1.2) | 0.38% (1.4) | **1.08%** (7.9) | 0.52% (6.1) |
| F2: the rest (returns, TAGE-lite not taken, straddlers, the cut) | 0.63% (14.1) | 0.39% (14.9) | 0.53% (22.6) | 1.04% (21.0) |
| **All F2 refetches** | **1.81%** (28.0) | **1.64%** (27.3) | **3.74%** (56.0) | **2.85%** (48.7) |
| **All lost decode slots** | **3.9%** | **3.5%** | **6.8%** | **21.2%** |

- **There are no bogus micro-BTB predictions, no FTQ-full cycles and no decode redirects** in any run. The boot runs at IPC 0.84, and rename holds decode in 30% of its cycles.
- **The boot has no model column:** the model runs bare-metal ELFs only, without traps or virtual memory.
- **Each F2 refetch is a 2-cycle bubble,** 4 decode slots. The instruction queue hides about three quarters of it: on CoreMark a refetch costs 0.9 slots on average.

**The answer to §6.4's question: mostly a gap in the model, and little IPC.**
- **The count:** on CoreMark A rv64gc the RTL refetches at F2 28.0 times per 1K instructions, against the model's 18.0.
- **Two of the RTL's rules were missing from the model:**
  - **Straddlers.** A 32-bit instruction that crosses into the next 16-byte block is decoded with that block: F2 holds its first half, and it is one of that block's branches. The micro-BTB never predicts or trains it. The model fetched it as a block of its own and trained it at slot 0 of the block before. So the model never saw the cut before a block's third branch on rv64gc (the RTL: 4.3 per 1K). On Dhrystone rv64gc it made 7 bogus predictions per 1K and 2.7× the RTL's missed JALs.
  - **The micro-BTB's training way.** The RTL rewrites the way that predicted the instruction, else a pseudo-random way (`tg_exec`'s `upd_way`). The model rewrote the way that hit the block, so a block's second exit always evicted its first. That kept returns the RTL loses: 0.1 missed per 1K on Dhrystone, against the RTL's 5.1.
- **A counting window too:** the model charged a flush's refill from the commit and the RTL from its flush, two cycles later. That alone made the model's refill look 4 slots longer per flush (9.7 against 5.6). The model now counts from the restart: 5.1–5.6 slots per mispredict on CoreMark, the RTL's 5.2–5.6.
- **What is left costs little:** all F2 refetches cost the RTL 1.6–1.8% of CoreMark's cycles, 3.7% of Dhrystone's and 2.9% of the boot's.

**`rtl_m2` revision 5** adds both rules (`m2_strad`, `m2_ub_way`):

| rv64gc | CoreMark A: RTL / revision 4 / revision 5 | Dhrystone: RTL / revision 4 / revision 5 |
|---|---|---|
| Cuts before a third branch, per 1K | 4.27 / 0.00 / 4.09 | 0.01 / 0 / 0 |
| Taken straddlers, per 1K | 1.51 / 0 / 1.77 | 0.01 / 0 / 0.01 |
| Bogus micro-BTB predictions, per 1K | 0 / 0.01 / 0 | 0 / 6.98 / 0 |
| JALs the micro-BTB missed, per 1K | 1.15 / 1.09 / 0.95 | 7.86 / 21.05 / 7.79 |
| Returns the micro-BTB missed, per 1K | 0.17 / 0.18 / 0.18 | 5.12 / 0.08 / 6.35 |
| Exits at another slot, per 1K | 3.32 / 1.67 / 2.01 | 17.93 / 13.94 / 20.94 |
| All F2 refetches, per 1K | 28.0 / 18.0 / 21.2 | 56.0 / 73.5 / 66.2 |
| All lost decode slots, % of cycles | 3.9 / 4.1 / 3.7 | 6.8 / 11.9 / 8.0 |
| Decode held by rename, % of cycles | 18.2 / 11.9 / 10.3 | 17.7 / 10.9 / 10.6 |
| The region's cycles against the RTL | – / −3.5% / −5.6% | – / −3.3% / −6.8% |

- **The front end now matches within a point on CoreMark** (3.6–3.8% of cycles lost against the RTL's 3.0–3.9%, both ISAs). On Dhrystone the model still loses 1.2–2 points more. Its faster backend leaves the queue emptier when a refetch comes, so each missed JAL costs it 3.3 slots against the RTL's 2.2.
- **The whole-program error grows,** because the front end no longer hides the backend:
  - the TAGE-lite build is −5.0% to −7.2% against the RTL (revision 4: −3.3% to −6.8%);
  - on the RAS head's 17 programs the mean error goes from 7.3% to 7.6%, with nsichneu at −10.0%. The other outliers are the same as before: minver, ws_hash, ws_copy and matmult-int.
- **The rest is in the backend.** Rename holds decode in 17.7–22.2% of the RTL's cycles and 10.3–12.9% of the model's. CoreMark's ordering replays are also twice the RTL's in the model (1.7 against 0.9 per 1K). Splitting rename's stalls by cause in both simulators (ROB full, an issue-queue bank full, LQ or SQ full, no free register) is the next profile, for revision 6.

**Each RTL cause above 1%: real, or the model's** (the model's estimates on revision 5, the M6 set, over make perf and the 11 RTL-suite programs):
1. **The boot's I$ misses (9.6%, about 12% with those that fell to steady fetch): real.** The boot's first 20M cycles are mostly first-touch code: 7.3 misses per 1K instructions, 23 cycles each, with the I$ busy refilling 14% of the time. The levers are an I$ prefetcher (next line, or fetch-directed: the model has both) or a larger I$, not fetch's logic. The suite has almost no I$ misses, so §6.5 left the I-side pieces for Linux to judge. This is the first Linux figure, but a cold boot overstates steady-state Linux, so the board's workloads should decide.
2. **The boot's steady fetch (4.3%): mostly I$ misses and FENCE.I, split by a second run's counters.** In 86% of its starved cycles F2 is empty. The reasons, as shares of all its starved cycles:
   - **59% (about 2.6% of the boot's cycles):** fetch parked on an I$ miss or an ITLB walk. The bind charges a run of back-to-back misses to the first miss's event, so after 32 cycles they fall here; they belong with item 1.
   - **19% (about 0.8%):** the I$ invalidate after a FENCE.I (item 8).
   - **14% (about 0.6%):** F2 holding a block or delivering one too short to fill decode.
   - **8% (about 0.3%):** none of the stall reasons the bind reads.
3. **The mispredict refill (1.3–1.6% on CoreMark, 1.5% on the boot): real, but the pipeline's own depth.** Fetch restarts at the flush and reaches decode 3 cycles later; the model has the same. The levers are fewer mispredicts (TAGE-lite's tables) or recovery before commit (checkpoints, §6.5: about +2% per 1K LUTs). The refill itself stays.
4. **Dhrystone's ordering-replay refill (2.6%): real, and the backend's.** A store's address op waits for its data register (rename's IQ-STA dependency on rs2, still in the f2cut tree). So a younger load to the same address runs first and is replayed, 7 times per 1K instructions. The refill is the smaller part of each replay. §6.4's lever removes the whole: the store address issuing on its base alone, model +26–30% on Dhrystone and +3–6% on CoreMark with the stack. It drops a dependency, and store data already has its own capture path (§6.6), so it should add no LUTs; core-2 would confirm. It also gates the front end's levers on Dhrystone: with F2's bubble at 0 the model's Dhrystone gets 4–5% *slower*, because loads overtake waiting stores more often.
5. **The boot's refill after traps, interrupts and serializing instructions (1.6%): real.** 3.4 such flushes per 1K instructions at 11 slots each. Without the FENCE.Is among them the rest cost 5.6 slots each, a mispredict's refill; FENCE.I's invalidate (item 8) makes up the difference.
6. **Exits at another slot (2.0% on Dhrystone): real.** The micro-BTB holds one exit per block: a second way holding the same block is shadowed, as the lookup takes way 0. A block whose exits take turns, such as a call and a branch around it, gets the wrong one at F1, and F2's pre-decode and TAGE-lite redirect it. The model has the same, at 2.5%.
   - **The lever is a 1-cycle F2 redirect,** which halves every refetch's bubble: at most +1.8% on the geometric mean (CoreMark A rv64gc +1.9%, Dhrystone rv64gc +1.6%, nsichneu +26%).
   - **It does not fit:** F2's decision is the 19–21-level cone that §8.12's restructure just fitted into 100 MHz, so it cannot join the next-PC loop.
7. **JALs the micro-BTB missed (1.1% on Dhrystone, 0.5% on the boot): real.** These are evictions from the 64-entry, 2-way micro-BTB with random replacement.
   - **128 entries:** +0.3% on the geometric mean (CoreMark 0 to +0.2%, Dhrystone rv64gc +0.4%, nsichneu +6%) for about 70 LUTs per core. Each way becomes a 64-deep LUTRAM with the same one-LUT read.
   - **256 entries:** +0.8% (nsichneu +15%) for about 370 LUTs per core.
   - **Linux should judge it:** the boot's micro-BTB misses (taken branches and JALs) cost 1.5% of its cycles.
8. **FENCE.I's I$ invalidate (1.7% of the boot's cycles, split between items 2 and 5): real, and boot-heavy.** The I$ clears one set a cycle, so fetch waits 64 cycles after every FENCE.I (32 KiB, 64 sets). The boot's first 20M cycles run 5,410 of them, 0.32 per 1K instructions: code patching, and OpenSBI's remote FENCE.I. A small generation count per line would let most FENCE.Is take a cycle and sweep only when the count wraps, for a few tens of LUTs. Steady-state Linux runs few FENCE.Is, so the board should count them before anyone changes the I$.

**Is any worth an RTL change before M6 merges? Not in the front end.**
- **Its losses are of three kinds:** the pipeline's own refill depth, a cold boot's I$ misses and FENCE.Is, or F2 refetches that the instruction queue mostly hides (1.6–1.8% of CoreMark's cycles in all).
- **The levers on them are out of reach or small:** a 1-cycle F2 redirect does not fit 100 MHz (+1.8% at most), and a 128-entry micro-BTB buys +0.3% on the suite. The micro-BTB is better judged under Linux.
- **The one change worth weighing before the merge is in the backend:** the store address waiting for its data (§6.4's question for core-2). It costs Dhrystone 2.6% of its cycles in refills alone, and 26–30% overall in the model.

### 6.8 Rename's stalls on the TAGE-lite build, measured in the RTL (2026-10-18)

*§6.7 left the model 5–7% optimistic, with rename holding decode in 17.7–22.2% of the RTL's cycles against 10.3–12.9% of the model's. This section splits those cycles by cause in both simulators on the same tree (fpu-2's f2cut, 1e4a503), with a measurement-only bind (`scripts/rtlprof/prof_rs.sv`), on make perf's regions and the RTL suite's 11 programs. `scripts/m6_rs.py` sets the model beside it (`results/m6_rs_rv64.json`). It also gives the model's prediction for fpu-2's prototype of the store address issuing on its base alone.*

**How a cycle is charged:**
- **The order:** each cycle decode is held (rename's `!de_take`) goes to the first of these causes:
  - a flush;
  - the dispatch stage holding a group whose slot's bank of an issue queue is full (by queue, slot 0 first);
  - the ROB, LQ or SQ without room for the group;
  - a free list short; wakeup tags or LLTs short; the divide and FP-op limits;
  - serializing uops; and the rest.
- **The blocking bank's rows:** when a queue's bank stops dispatch, its rows are counted by state (waiting on a source, ready but not yet granted, issued and held).
- **IQ-STA's rows by what they wait on:** a shadow of each row's two sources (their wakeup columns and MX rows, taken at dispatch) splits them into waiting on the base, waiting only on the store's data, or neither.

**What holds rename in the RTL** (percent of cycles; rv64im is within half a point of rv64gc):

| Cause | CoreMark A | CoreMark B | Dhrystone | crc32 | edn | matmult-int | minver | statemate | ws_hash |
|---|---|---|---|---|---|---|---|---|---|
| IQ-A0 bank full | 5.4 | 8.1 | 2.6 | 6.9 | 0.4 | – | 0.8 | 0.2 | 35.8 |
| IQ-A1 bank full | 5.7 | 6.2 | – | 17.2 | 14.6 | – | – | – | 1.8 |
| IQ-LD bank full | 3.9 | 5.1 | 2.6 | – | 0.1 | – | 0.6 | 8.1 | – |
| IQ-STA bank full | 2.5 | 2.2 | 11.5 | – | 0.3 | 17.8 | 11.7 | 38.6 | – |
| ROB, LQ, SQ, free lists, tags | – | – | – | – | – | – | 3.5 | – | 6.8 |
| Flush, divide limits, the rest | 0.7 | 0.6 | 0.9 | – | 0.3 | 0.1 | 2.7 | – | 1.5 |
| **All** | **18.2** | **22.2** | **17.7** | **24.1** | **15.6** | **17.8** | **19.4** | **46.9** | **45.9** |
| ALU op stopped while the other ALU queue's bank had a row | 10.0 | 12.1 | 2.2 | 17.2 | 3.7 | – | 0.5 | 0.1 | 31.9 |

- **Almost every held cycle is an issue queue's bank.** The ROB, LQ, SQ, free lists and tags hold rename only on minver (ROB 3.2%), ws_hash (ROB 6.8%) and the streaming kernels. ws_copy is held 85% of its cycles, mostly by the SQ.

**The ALU queues: rename steers by flags a cycle old.**
- **The rule** (`tg_rename.sv`): rename picks an ALU op's queue: slot k's queue k mod 2 if its bank for slot k has a row, else the other. It reads the banks' registered `bank_free_q`, which do not count the group the dispatch stage writes in the same cycle.
- **What goes wrong:** two groups in a row can aim at a bank's last row, and the second waits at dispatch. Its queue and its destination register's bank were fixed at rename, so it cannot move.
- **How much:** in 80–90% of the RTL's ALU-queue stalls on CoreMark the stopped op is an ALU op, and the other ALU queue's bank for its slot has a row. That is 10–12% of CoreMark's cycles, 17% of crc32's and 32% of ws_hash's.
- **The model picked the queue at dispatch, with the rows as they stood.** It had a third of the RTL's ALU-queue stalls on CoreMark (3.1% against 11.1%).

**`rtl_m2` revision 6** steers as the RTL does (`iq_steer_rn`): a cycle before dispatch, from the flags of the cycle before that, and the op keeps its queue.

| Model against the RTL | Revision 5 | Revision 6 |
|---|---|---|
| CoreMark (both ISAs) | −5.0% to −6.5% | −0.5% to −1.1% |
| Dhrystone | −6.8% / −7.2% | −4.7% / −5.9% |
| crc32 | −3.4% | 0.0% |
| Decode held, CoreMark A rv64gc (RTL 18.2%) | 10.3% | 15.1% |
| Mean error over the 17 programs on this tree | 5.7% | 4.2% |
| Mean error over the RAS head's 17 (§6.6) | 7.6% | 7.5% |

**IQ-STA, and what the store address on its base alone would change.**
- **CoreMark:** IQ-STA holds rename 2.2–2.5% of cycles, and the model has the same (2.1–3.6%). Rows waiting only for their data are rare: 5–8% of those cycles have one.
- **Dhrystone:** IQ-STA holds rename 11.1–11.5% of cycles, against the model's 7.1–7.6%. Of the blocking bank's two rows:
  - 0.3–0.4 wait only for their data (29–32% of these cycles have one);
  - 1.5–1.7 are in their select cycle or held for the speculative-wakeup shadow, as in the model.
- **matmult-int, minver, ud, edn:** the data wait dominates. 69–97% of their IQ-STA stalls have a row waiting only for its data, as in the model.
- **statemate's 39%** is stores arriving faster than one slot's two rows turn over (3 cycles each): its rows are ready or held, not waiting on data.
- **So the lever explains little of the held-cycle gap.** On CoreMark the gap was the steering, and IQ-STA matches. On Dhrystone, IQ-STA is 4 of the 7–9 points. In the model the lever leaves Dhrystone's held cycles where they were (12.6–12.9% before, 13.6–13.7% after). Its gain there comes from removing the ordering replays (7 per 1K instructions; §6.7).

**The model's predictions** (speedup of each change over the model as built; these sit beside fpu-2's prototype when its numbers come):

| Program | STA on its base, revision 5 / 6 | Steering fix (revision 6) | Both (revision 6) |
|---|---|---|---|
| CoreMark A rv64gc / rv64im | +3.4% / +3.0%; +2.5% / +1.9% | +6.0%; +6.3% | +9.6%; +7.8% |
| CoreMark B rv64gc / rv64im | +4.4% / +2.9%; +3.9% / +3.0% | +6.6%; +6.4% | +11.0%; +10.7% |
| Dhrystone rv64gc / rv64im | +15.0% / +14.8%; +14.6% / +13.3% | +3.3%; +3.4% | +26.4%; +28.0% |
| matmult-int, minver, ud | +20.5%, +28.5%, +15.2% / +20.5%, +28.2%, +12.1% | 0, −0.1%, +6.2% | +20.5%, +28.5%, +14.1% |
| crc32, edn | 0, +1.6% / 0, +1.4% | +3.6%, +0.3% | +3.6%, +3.1% |
| Geometric mean, 17 programs | +6.2% / +5.7% | +2.5% | +9.3% |

- **The lever's Dhrystone gain is half of §6.4's estimate** (+26–30% on revision 2). Speculative wakeup, the row clash and the RTL's front end have come in since.
- **The steering fix** (`iq_steer_rn` 2) is a rename that counts the dispatch stage's group when it reads the ALU queues' bank flags. In RTL:
  - **tg_iq** keeps a second registered flag per bank, "at least two rows free" (one LUT on five rows).
  - **Rename** reads a bank as free only if that flag is set or the dispatch stage's op in the same slot does not take that bank.
  - **Cost:** about 15 LUTs per core and one LUT level on rename's steering. The flags are registers, but core-2 owns the path and would check it.
  - **Exactness:** rename fires only when the dispatch stage writes its group in the same cycle, so the correction is exact. Rows freed in that cycle are not seen, which only errs toward the other queue.

**What is still open:**
- **The ALU queues:** with revision 6 the model's held cycles are 3.1–3.3 points under the RTL's on CoreMark. The RTL's blocking ALU-queue banks hold more rows that are ready but not granted: 1.5–2.0 against the model's 0.5–0.7, beyond each grant's own cycle. A1's select was blocked for a MUL, DIV or CSR result in 13–21% of its stalls.
- **Dhrystone's IQ-STA:** 11.1–11.5% in the RTL against 7.1–7.6% in the model.
- **Outliers:**
  - **ws_hash:** the model is 14% slow, yet the RTL holds rename for 46% of cycles against the model's 6.5%. The gap is elsewhere, likely its memory side.
  - **ws_copy:** the model is 14% fast, though both hold rename about 82–85% of cycles, mostly on the SQ.

### 6.9 DR-169's levers measured, and Dhrystone rv64im's race (2026-10-18)

*fpu-2 built §6.8's two levers on the f2cut tree, each behind a switch: STA_BASE (a store's address issues on its base alone) and STEER_LA (rename's steering counts the group in the dispatch stage). The tree is `claude/track-fpu-395911-sta` at a857a07. fpu-2 measured both levers on the 17 programs, and DR-169 approved them. This section:*
- *sets fpu-2's measurements beside the model's predictions;*
- *explains the one program where they disagreed (Dhrystone rv64im);*
- *folds the levers into `rtl_m2` revision 7, with two more RTL rules found on the way.*

*The bind is `scripts/rtlprof/prof_sta.sv` (the rename profile plus the loads: M2 verdicts, cancels by cause, replays by PC). The script is `scripts/m6_lev.py` (`results/m6_lev_rv64.json`).*

**Measured against predicted** (speedup over the tree without the levers: RTL / revision 6, as §6.8 predicted / revision 7):

| Program | STA_BASE alone | STEER_LA alone | Both |
|---|---|---|---|
| CoreMark A rv64gc / rv64im | +1.6 / +3.0 / +3.5%; +0.7 / +1.9 / +2.2% | +6.9 / +6.0 / +5.8%; +6.4 / +6.3 / +5.7% | +8.1 / +9.6 / +9.7%; +6.9 / +7.8 / +8.0% |
| CoreMark B rv64gc / rv64im | +1.8 / +2.9 / +3.2%; +1.7 / +3.0 / +3.3% | +6.9 / +6.6 / +6.1%; +6.5 / +6.4 / +6.2% | +9.1 / +11.0 / +10.6%; +8.6 / +10.7 / +9.9% |
| Dhrystone rv64gc | +18.0 / +14.8 / +12.5% | +2.1 / +3.3 / +3.3% | +23.3 / +26.4 / +13.8% |
| Dhrystone rv64im | +5.0 / +13.3 / +3.5% | +2.2 / +3.4 / +3.3% | +10.2 / +28.0 / +12.2% |
| matmult-int, minver, ud | +18.7, +23.2, +17.4 / +20.5, +28.2, +12.1 / +20.5, +27.3, +12.1% | 0, −0.1, −0.7 / 0, −0.1, +6.2 / 0, −0.1, +4.5% | +19.1, +22.4, +18.8 / +20.5, +28.5, +14.1 / +20.5, +27.3, +14.3% |
| crc32, edn | 0, +0.1 / 0, +1.4 / −3.3, +1.7% | +3.6, +4.5 / +3.6, +0.3 / +3.6, +0.9% | +3.6, +5.4 / +3.6, +3.1 / +3.5, +3.4% |
| **Geometric mean, 17 programs** | **+5.03 / +5.70 / +4.90%** | **+2.25 / +2.52 / +2.36%** | **+7.84 / +9.33 / +7.74%** |

- **The predictions held on the means:** revision 6 was 0.3–1.5 points high; revision 7 is within 0.15 points on all three.
- **Per program,** CoreMark's STA_BASE gain is over-predicted by 1–2 points. Dhrystone moves with the race below.

**Dhrystone rv64im: one race per run.**
- **The symptom:** with STA_BASE, rv64gc's ordering replays all go, but rv64im keeps one per run (498 in 500 runs). Every one is at Proc_4's first load, `lbu Ch_1_Glob`.
- **The race** (traced in RTL, cycle by cycle):
  - Proc_5 stores Bool_Glob, then Ch_1_Glob (both gp-relative), and returns. main then calls Proc_4, whose first instruction loads Ch_1_Glob. On rv64im that load dispatches one cycle after the store.
  - IQ-STA issues one address a cycle, oldest first. The older `sw` issues, and a speculative-wakeup cancel returns it: a load in its shadow did not complete in M2. It issues again two cycles later, so the `sb`'s address issues one cycle after the load.
  - The load searched the SQ before the store's address was there, so it is replayed at commit: about 23 cycles each, the whole 11.7K cycles between rv64im and rv64gc.
- **Why rv64gc escapes:** there the `sb` straddles a 16-byte block, so the load arrives 3–4 cycles later and the store wins.
- **It is the code's layout, not a missing model rule.**
  - With revision 7's drain cycle the model replays at this pair on both binaries: 4.2–4.4 per 1K instructions, against the RTL's 3.5 on rv64im and none on rv64gc. So the model's Dhrystone is −7.2% on rv64im and +3.5% on rv64gc.
  - A memory-dependence predictor would end such repeats in RTL: a load that was replayed waits for older store addresses the next time (the model's `mdp`). It is not costed here.

**Two RTL rules the model lacked, now in revision 7:**
1. **The store-wait cancel** (`fwd_wait_cancel`).
   - **The rule:** a load that finds an older store's address without its data (the LSU's STQ verdict at M2) does not complete in M2, so speculative wakeup cancels its shadow, as it does for a miss. The model charged nothing for it.
   - **Why it matters now:** with STA_BASE such loads are common, at 7–10 per 1K instructions on Dhrystone and 0.5–1.5 on CoreMark.
2. **The drain's cycle** (`drain_delay` 1).
   - **The rule:** the ROB reports retiring stores in the commit cycle, and the SQ's committed pointer is registered. So a store writes the D$ 1–4 cycles after its commit: 63% after one, 23% after two, 10% after three (measured on Dhrystone). The model wrote it in its commit cycle, so fewer younger loads met the drain inside the row-clash window.
   - **With the cycle,** the model's clashes rise toward the RTL's but stay under: statemate from 5.0 to 17.5 per 1K against 26.3, Dhrystone rv64gc from 4.1 to 8.7 against 16.0.
   - **Not the rest of it:** a retry that reads the row again (`clash_rearm`) moved nothing, so it stays off.
- **Both rules hold without the levers too:** on 1e4a503 they take the 17-program error from 4.23% to 3.93%.

**`rtl_m2` revision 7** is revision 6 plus STA_BASE (`sta_split` 1), STEER_LA (`iq_steer_rn` 2) and the two rules.

| On the levers tree (a857a07) | Revision 6 with the levers | Revision 7 |
|---|---|---|
| Mean error, 17 programs | 5.40% | 4.17% |
| CoreMark | −1.7% to −2.8% | −1.4% to −2.1% |
| Dhrystone rv64gc / rv64im | −7.1% / −19.0% | +3.5% / −7.2% |
| statemate, minver | −5.1%, −9.0% | −2.5%, −7.7% |

**What is still open:**
- **The memory side:** ws_copy (−13%) and ws_hash (+14%).
- **minver (−7.7%) and edn (−5.5%):** minver's row clashes are still three times the model's, and its store waits twice.
- **Row clashes in general:** the model's are 1.5–3 times under the RTL's, even with the drain cycle.
- **Decode held by rename:** on Dhrystone the model has 11% against the RTL's 20–21%, yet its cycles are within 4–7%. crc32 is held 48% in RTL and 21% in the model, with equal cycles; its time is set by the loop's dependency chain.
- **The race above,** which a memory-dependence predictor would remove in RTL.

### 6.10 Ordering replays in the Linux boot: the predictor parked (2026-10-18)

*§6.9's race raised a memory-dependence predictor: a small table of load PCs that were replayed for ordering, whose loads then wait for older store addresses. The coordinator's rule was to judge it on Linux, parking it if replays cost under about 0.5% of the boot's cycles. This section measures it on the levers tree (a857a07, both levers, one `st` core), over the Linux boot's first 20M cycles in `tb_boot`. The bind is `scripts/rtlprof/prof_rpl.sv`.*

**How a replay is costed:** each replay flush at commit is timed until the replayed instruction commits again. Nothing commits in between, so that is the commit stall it causes. Replays are counted in two kinds:
- **ordering replays:** a younger load ran before an older store to its bytes;
- **DTLB retries:** the ROB head missed the DTLB and now translates.

| First 20M cycles of the boot (16.8M instructions) | Count | Per 1K instructions | Commit-stall cycles | Share of cycles |
|---|---|---|---|---|
| Ordering replays | 1,158 | 0.07 | 17,370 (15 each) | **0.09%** |
| DTLB retries | 29,608 | 1.76 | 492,906 (17 each) | **2.45%** |

- **The predictor is parked.** Ordering replays cost 0.09% of the boot's cycles, a fifth of the bar.
- **A table would catch them, but they are worth little:**
  - they come from 35 load PCs, and 97% are repeats at a PC that replayed before;
  - a 16-entry table of single bits, indexed by PC, would catch 98.8% (a 256-entry table the same 97% as an exact set);
  - the most replayed are the kernel's early code at physical addresses (400 at one PC), one kernel load (201) and OpenSBI's `sbi_memcmp`, at its reload of the return address from the stack (145).
- **Gain at most 0.08% of the boot's cycles,** less the waits the table would add. The model runs bare-metal programs only (no traps or virtual memory), so it cannot replay the boot itself.
- **Dhrystone rv64im's race is a benchmark effect:** it costs that binary 11%, and the boot almost nothing.

**DTLB retries cost 30 times as much.**
- **The mechanism:** a load or store that misses the DTLB is marked; the walker fetches the translation; and at the ROB head the instruction and everything after it are flushed and refetched (M3's design, core-mmu.md). That is about 17 cycles of commit stall per miss, beyond the walk.
- **The cost:** 1.76 misses per 1K instructions, 2.45% of the boot's cycles. §6.7's front-end profile saw part of this as its "replay" refill.
  - *Corrected (§6.11, follow-up 13):* the bind took each recommit from the commit trace, a cycle late, so each stall here is a cycle long. DTLB retries cost 2.31% (16 cycles each), and ordering replays 0.08%.
- **The levers would be:** a DTLB miss waiting in the LQ for the walk and replaying from there, as a cache miss does, so younger instructions are not flushed; or fewer misses (a larger DTLB).
- **Judge it on steady state:** the boot's first 20M cycles touch many new pages, so steady-state Linux workloads on the board should decide.

### 6.11 M6's remaining pieces re-ranked on main's M6 set, with the boot measured (2026-10-19)

*The first M6 set is on main (31e65c6): the RAS, TAGE-lite with two 2K tables, F2's returns and straddlers, the restructured F2 and DR-169's levers. DR-167's approved reserve leaves about 4K LUTs a chip for M6's later pieces (PMP with 8 entries, about 2.7K, and release builds without the latency injectors, about 1.3K). This section re-ranks the remaining pieces as IPC per 1K LUTs. The model gives make perf, the suite and Linux-like kernels; a measurement-only bind on main gives the Linux boot, which the model cannot run (`scripts/m6_rank.py`, `scripts/rtlprof/prof_m6.sv`, on the build host).*

**Setup.**
- **The model's base:** `rtl_m2` revision 7 with main's M6 set: the 32-entry RAS, TAGE-lite with two tagged tables of 2K entries and its training queue, F2's returns, the 32-entry FTQ and the branch cut. Each piece is added alone and run on:
  - **make perf:** its ELFs (CoreMark A and B, Dhrystone; rv64im and rv64gc) at native and 120-cycle latency, the geometric mean of cycles;
  - **the suite** on the SoC's uncore at 100 MHz, as §6.5;
  - **Linux-like kernels** on the same uncore, outside the suite: `tk_bigcode` (200 KiB of code), `tk_bsearch_l2` (47 branch mispredicts per 1K, L2-resident) and DR-141's working sets (`ws_chase1`, `ws_chase8`, `ws_hash`, `ws_copy` at 0.5–4 MiB).
- **The base against main's RTL** (make perf, rv64gc, native latency): CoreMark A 4.63 per MHz against 4.55 (+1.6%), B 4.38 against 4.27 (+2.6%), Dhrystone 2.97 against 3.08 DMIPS per MHz (−3.3%).
- **The boot:** main at 31e65c6, one `st` core, `tb_boot`, the first 20M cycles, run twice:
  - with the testbench's memory: a 64-set (64 KiB) L2 and DDR at 4–12 cycles;
  - with board-like memory: the board's 1,024-set (1 MiB) L2 and DDR fixed at 22 cycles.

  The bind charges every cycle without a commit to the ROB head's state, and measures what each piece would remove (below).
- **LUTs per chip:** two cores, with the L2 stream prefetcher once. The sources:
  - **more misses in flight:** DR-156's measured +668 LUTs per `st` core for entries 1 → 4, scaled per entry;
  - **the ledger's pieces:** its estimates ×2–3, as measured features ran over theirs;
  - **the DTLB retry and FENCE.I:** this study's count of the added structures (no ledger line);
  - **the micro-BTB:** `tg_ubtb` synthesized out of context at 64 entries is 119 LUTs (55 logic, 64 LUTRAM), as the same count gave (110). 128 and 256 entries come from that count: +64 and +376 per core.

**Where the boot's cycles go.** 52% of cycles commit nothing (board memory; the testbench's memory in parentheses where it differs; IPC 0.83 and 0.84).

| Cycles without a commit | Share of cycles |
|---|---|
| ROB empty: fetch parked on an I$ refill | 4.46% (6.23%) |
| ROB empty: the I$ sweep after FENCE.I | 1.72% |
| ROB empty: an ITLB walk | 0.57% |
| ROB empty: the refill after a mispredict | 5.86% (4.95%) |
| ROB empty: the refill after a replay flush (DTLB or ordering) | 1.44% (1.43%) |
| ROB empty: the refill after a trap, interrupt or serializing flush | 2.23% (2.30%) |
| ROB empty: other (decode-side bubbles, and the refill after an I$ refill restarts fetch) | 10.76% (8.80%) |
| Head: a load or store waiting for its DTLB check or walk | 2.32% (2.34%) |
| Head: a load waiting on a D$ miss | 7.73% (7.71%) |
| Head: another load (in the pipe, waiting for a store or its replay slot) | 6.58% (6.72%) |
| Head: a store | 1.87% (2.02%) |
| Head: a serializing op (fences, CSRs, WFI) | 0.87% (0.66%) |
| Head: another op executing | 5.26% (5.44%) |
| Head: complete, retiring nothing (the cycle after a flush, or an ordering replay's) | 0.51% (0.52%) |

*Corrected by follow-up 13 (below).* The first version of this table counted commits from the commit trace, which reports a cycle's retirements a cycle later. It charged each stall's last cycle, in which the head retires, to "complete, commit held" (4.29%, 4.40%); each row above has its share back.

What the bind found beside the stack:
- **The store drain is the boot's largest single stall.**
  - The drain takes one committed store at a time. A store that misses waits for its line, with write permission, before the next store can drain.
  - It waits on a line 18.9% of cycles (15.7%). While it does, rename is held by a full SQ 12.7% of cycles (9.6%).
  - The early boot clears and fills pages, so these misses come in long sequential runs, one line at a time.
- **The D$'s four miss entries almost never run out.** All four were busy 451 cycles in 20M (80), and loads waited for a free one 333 cycles (60). More misses in flight buy nothing in the boot; DR-156 measured 1 → 4 at +1.29%.
- **The I$:** fetch is parked on a refill 12.8% of cycles (15.7%), at 169K refills (175K).
  - 29% of refills are for the line after the previous refill's: a sequential run. 13% are for the line after the last block fetch delivered.
  - Those two kinds hold 2.65% and 0.88% of cycles with nothing committing (3.58% and 1.42%).
- **FENCE.I:** 5,410 sweeps of 64 cycles, 1.72% of cycles, all with the ROB empty.
- **DTLB retries:** 25.6K loads and 4.0K stores.
  - Each waits about 26 cycles at the head for its walk, then stalls commit 16–17 cycles after the flush.
  - A load replayed from the LQ instead (5 cycles after its page's DTLB fill) would save 1.62% of cycles (1.57%), and stores 0.16%.
- **Mispredicts:** 6.5 per 1K instructions. Recovery at commit waits 3.6 cycles on average from resolution; 95% wait 5 cycles or less, and 2% over 20.
- **The micro-BTB:** 320K F2 overrides of a taken branch or jump it missed, 92K returns and 41K straddlers.
  - Shadow tables kept with its updates held the block in 128 entries for 32% more of the branch cases and 36% more returns. In 256 entries, 38% and 50% more.
  - The 64-entry mirror already held 28% of them: the entry's branch lay before the fetch's entry point.
  - Each override costs decode 1.9 slots (returns 1.1, straddlers 3.4; prof_f2cut).

**Each piece alone** (make perf: geomean cycles, minus is faster. The boot: the estimated share of its cycles, board memory with the testbench's memory in parentheses, and the bound the estimate comes from):

| Piece | What it adds | LUTs per chip | make perf (model) | Suite (model) | Linux-like (model) | Boot estimate (RTL) | Boot bound | Boot gain per 1K LUTs |
|---|---|---|---|---|---|---|---|---|
| Ownership prefetch for stores | When a store's address resolves, its line is requested with write permission through a D$ miss entry, so the drain finds it | 400–600 (ledger 0.24%) | 0 | +0.6% | +4.2% (`ws_copy` +21%) | **+4.22%** (3.18%) | 12.7% (9.6%) | **8.4%** |
| FENCE.I by generation | A 2-bit generation per I$ line in place of its valid bit; FENCE.I steps it, and a background sweep clears stale lines, so fetch restarts at once | 100–600 | 0 | 0 | 0 | **+1.72%** | 1.72% | **4.9%** |
| Micro-BTB 128 entries | 64 sets of 2 ways in RAM64M8 LUTRAM in place of 32 | 130–150 | −0.1% (+0.9% as built) | 0 | 0 | +0.59% (0.62%) | — | 4.2% |
| DTLB retry from the LQ (loads) | A load that misses the DTLB waits in the LQ for the walk's fill and replays through translation, with no flush | 400–1,200 | 0 | — | — | +1.62% (1.57%) | 5.4% (with the walk at the head) | 2.0% |
| I$ next-line prefetch with a second refill | Two refills in flight; a miss of line L also fetches L+1, and the first hit on a prefetched line fetches the next | 1,000–1,500 | −0.4% | 0 | +2.0% (`tk_bigcode` +43.5%) | +2.65% (3.58%) | 3.5% (5.0%) | 2.1% |
| I$ FDIP, next-line and 4 refills | Prefetch along the predicted path while fetch waits | 2,600–3,900 | −0.6% | 0 | +4.2% (`tk_bigcode` +111%) | +3.53% (5.00%) | 8.4% (10.9%) | 1.1% |
| Checkpoints (4) | Mispredicts recover at resolution from one of four rename-map copies | 2,000–3,000 (ledger 1.22%) | **−1.7%** (CoreMark A +2.2%, B +3.2%) | +2.2% | +1.2% (`tk_bsearch_l2` +7.5%) | +2.46% (2.54%) | — | 1.0% |
| Micro-BTB 256 entries | 128 sets in RAM128X1D | 750–800 | −0.1% (+1.5% as built) | +0.1% | 0 | +0.73% (0.77%) | — | 0.9% |
| Early retirement | Loads and long ops retire before their result, with an 8-entry completion buffer | 3,900–5,800 (ledger 2.36%) | 0 | +0.9% | +0.4% | at most 4.9% (3.8%) | 4.9% (rename held by a full ROB, a missing load at the head) | at most 1.0% |
| 8 L1D misses in flight | Four more D$ miss entries | 1,800–2,000 (DR-156) | 0 | +4.5% | +12.7% (all `ws_chase8`, +71%) | 0 | 0 | 0 |
| 16 L1D misses in flight | Twelve more | 5,400–6,000 (DR-156) | 0 | +6.1% | +12.7% | 0 | 0 | 0 |
| L2 stream prefetcher | Sequential-miss streams detected in the L2, fetched ahead from DDR | 300–900 (ledger 0.43% of the SoC, ×2 if per bank) | 0 (no L2 on make perf's memory) | +2.5% | +5.5% (`ws_copy` +27%) | not measurable (no prefetcher in the L2 to profile) | — | — |
| L1D stride prefetcher | A PC-indexed stride table | 1,200–1,800 | 0 | +0.8% | +0.3% | — | — | — |
| 4 I$ refills alone | — | 1,000–1,500 | 0 | 0 | 0 | 0 (fetch waits on its own miss) | — | 0 |

How each boot estimate is made:
- **Ownership prefetch:** the cycles rename is held by a full SQ while the drain waits on a line, times 0.33. That factor is the model's: on `ws_copy` the prefetch saves 0.33 cycles per such cycle.
- **FENCE.I:** the sweep's cycles.
- **Micro-BTB:** the overrides the larger shadow holds beyond the mirror's, at the decode slots each costs, two a cycle.
- **DTLB retry:** each retry's commit stall, less a replay that completes 5 cycles after the page's DTLB fill (or at the head's arrival, if earlier).
- **I$ next-line:** the cycles with nothing committing while fetch is parked on the line after the previous refill's. The refill after fetch restarts is not counted, so this is low by up to about 5 cycles per refill.
- **Checkpoints:** each mispredict's wait from resolution to commit, plus the flush's cycle after commit. The model saves 1.25–1.38 cycles per cycle of wait on make perf, which is what this gives.

**The top three that fit the room, by boot gain per 1K LUTs:**

| Rank | Piece | LUTs per chip | make perf | Boot (board memory / testbench memory) |
|---|---|---|---|---|
| 1 | Ownership prefetch for stores | 400–600 | 0 | +4.2% / +3.2% |
| 2 | FENCE.I by generation | 100–600 | 0 | +1.7% / +1.7% |
| 3 | Micro-BTB at 128 entries | 130–150 | −0.1% (race-free); +0.9% as built | +0.6% / +0.6% |
| | **Together** | **630–1,350** | about 0 | **about +6.5% / +5.5%** |

- **About 2.6–3.4K of the room is still left after them, enough for the next two:**
  - the DTLB retry from the LQ: +1.6% for 400–1,200 LUTs;
  - the I$ next-line prefetch with a second refill: +2.7% of the boot and −0.4% make perf cycles, for 1,000–1,500 LUTs.

  These two buy 3–4 times the micro-BTB's absolute gain at about 2.0–2.1% per 1K. All five come to about 2.0–4.1K LUTs a chip and about +11% of the boot, if their gains add: each removes a different stall.
- **Recommendation: build the ownership prefetch and FENCE.I by generation first.** Then build the I$ next-line prefetch in place of the micro-BTB as the third: it is the larger and better-measured gain, and the only one of the five that also helps make perf. Then the DTLB retry, and the micro-BTB at 128 if room is left.
- **Pros:**
  - all three target the boot's measured stalls;
  - the first two are small and local: one is a new request source for the D$'s existing miss entries, the other a 2-bit generation in the I$'s valid bits;
  - none touches the next-PC loop.
- **Cons:**
  - make perf barely moves;
  - the ownership prefetch's estimate leans on the model's `ws_copy` (0.33 of the stall);
  - the prefetch takes miss entries that loads also use: four suffice in the boot today, but not if SMT2's second hart adds misses;
  - the I$ prefetch changes fetch's refill (core-2's area) from one line to two;
  - the LUTs are estimates (×2–3 on the ledger's), so each wants a prototype's measured count before it merges.
- **Not chosen:**
  - **Checkpoints:** the best for make perf (−1.7%) and +2.5% of the boot, but 2–3K LUTs at 1.0% per 1K.
  - **Early retirement:** 3.9–5.8K, more than the room.
  - **8 or 16 misses:** nothing in the boot. Their Linux-like gain is one kernel, eight independent pointer chains.
  - **The L2 stream prefetcher:** the model's best Linux-like buy per LUT (+5.5% for 300–900, once per chip). It cannot be measured in the boot without a prefetcher in the L2, so it should be judged on the board's steady state. It may also speed the boot's page clears where they miss the L2.
  - **The micro-BTB at 256:** 0.9% per 1K.
- **The micro-BTB's make perf as built is a race, not the table.** A faster front end moves Dhrystone's store–load race (§6.9): 4.4 → 5.1 replays per 1K, −2.5% Dhrystone. With the model's memory-dependence predictor in base and piece alike, it is −0.1% (CoreMark A +0.05%, B −0.1%).

**Limits.**
- **The boot is early boot.** Its page clears, code patching (FENCE.I) and first-touch translations weigh more than they will in steady state. The steady-state picture is the model's Linux-like kernels and, later, the board.
- **`tb_boot`'s memory is not the board's.** Hence the second run: the store and I$ estimates move by a quarter to a third between the two memories, and the rest stay put.
- **The boot runs one hart.** SMT2's second hart adds misses in flight, which raises the value of more miss entries and lowers the store prefetch's free entries.
- **The micro-BTB's LUTs at 128 and 256 entries** are the count that matched 64 entries' synthesis. The two larger syntheses waited behind full-device runs and were cancelled.

**Follow-up 13 (2026-10-19): the 4.3% "commit held" was the bind's, not the core's.** The question was whether it is the testbench's trace back-pressure or something real in the commit logic. It is neither.
- **The cause: the commit trace lags retirement by a cycle.** `tg_rob` registers the trace (`trace_valid_o`), so it reports a cycle's retirements a cycle later. The bind took "this cycle commits" from the trace but read the head's state live. So each stall's last cycle, in which the head is complete and retires, read as a complete head with nothing committed.
- **The fix:** the bind now takes commits from the ROB's own decision (`ret`, and traps and interrupts) in the cycle it is made.
- **Both boots rerun** (identical cycles and instructions):
  - the old definition counts exactly the same 862,346 and 884,361 cycles;
  - the new one counts 102,732 and 105,121 (0.51% and 0.52%).
- **What stops the remaining complete heads:**

  | What stops a complete head (board memory / testbench memory) | Cycles |
  |---|---|
  | The registered flush cycle after a flush: the ROB discards the wrong path, whose first op can be complete | 101,580 / 103,977 |
  | An ordering replay's flush | 1,152 / 1,144 |
  | The ROB not ready: the trace stream's back-pressure | 0 / 0 |
  | A store in its PMP check (S2) or denied (S3); a load's replay mark on its way | 0 / 0 |
  | Anything else | 0 / 0 |

  - **No back-pressure:** `tb_boot` enables the trace stream only with `+trace_out`, and these runs had none.
  - **The other flush cycles** (about 200K flushes in all) fall in the rows of their head's state, or under ROB empty.
- **No free gain.**
  - The flush cycle is the registered recovery, the model's `commit_redirect` 2.
  - Taking it combinationally would put commit's decision and fetch's redirect on one path.
  - Checkpoints remove the mispredicts' share of it.
- **What changes in §6.11:**
  - the stack above;
  - the DTLB retry's estimate, from 1.75% to 1.62%: its recommit came from the trace too, so each stall was a cycle long;
  - the I$ estimates, by under 0.05 points.

  The ranking is unchanged.
- **§6.10's replay stalls were a cycle long each, for the same reason:**
  - DTLB retries cost 2.31% of the boot, not 2.45%;
  - ordering replays cost 0.08%, not 0.09%.

  Its verdict stands. `prof_rpl.sv` now times recommits from the ROB as well (not re-run).

**Decisions:** none here; the choice is the coordinator's under DR-154, or the user's. Model revisions: none (the base is revision 7). The model gains a counter, `mp_wait_cycles`, for checkpoints' bound.

**Learned:**
- **The early boot's largest single stall is the store drain:** one store at a time, each waiting on its line.
- **The four D$ miss entries are almost never all busy in the boot.** The model's "Linux-like" gain for more of them is a single eight-chain kernel.
- **Read a Linux-like geomean kernel by kernel.** The gains of 8 misses, the L2 stream prefetcher and the store prefetch each come from one of the four working-set kernels.
- **A front-end change can move a store–load race.** Read its make perf race-free before trusting the sign.
- **`rtl_m2`'s early retirement needs the completion buffer.** `lqcb` is 0 in `rtl_m2`, which leaves only divides retiring early.
- **A LUTRAM structure can be costed by counting its primitives.** The micro-BTB's count was within 10% of its synthesis.
- **Time a cycle's commits where they are decided, not from a registered report of them** (follow-up 13). The commit trace lags retirement by a cycle. A stack built from it charged each stall's last cycle to a "commit held" class that does not exist.

### 6.12 The model and the RTL against the board's first M6 Linux run (2026-10-19)

*MR18 ran M6 on the board for the first time (`fpga/kv260/board/d4s2`): DR-141's Linux set, three boots, on d4s2 (M6 with core-2's micro-BTB target check), against d2 (sc3's core with DR-156's four misses).*

*The coordinator asked three questions:*
- *where tgsim's M6 preset (`rtl_m2` revision 7) lands against each program, within ~10%;*
- *why Dhrystone is 8% below simulation when CoreMark is slightly above;*
- *whether the boot profile with board-like memory predicts the board's /init gain.*

*What was run, all on the build host:*
- *The RTL's make perf on both bitstreams' trees:*
  - *d2: `e65db3a`;*
  - *d4s2: `03171ea` with `c261c1f`'s `tg_fetch.sv`.*

  *Each tree ran in the board's configuration (smt2) and in make perf's (st).*
- *The model on the same ELFs (`scripts/m6_board.py`).*
- *Linux to /init in `tb_boot` on both trees, set up as the board runs it:*
  - *smt2, two cores, one hart each;*
  - *the console without serial timing, so the kernel's timestamps are the CPU time (the board's console time is taken off its own timestamps);*
  - *board-like memory;*
  - *the board's bench OpenSBI, Image and 1 GiB device tree. This needs `tb_boot`'s 256 MiB window widened, done in the scratch trees only.*

**What the board runs, against make perf.**
- **The core is the smt2 build, one hart per core.** Until M7, an smt2 core gives its one thread the whole smt2 window:
  - **its size:** ROB 80, LQ 24, SQ 20 and 24 LLTs, against st's 48, 16, 12 and 16;
  - **no per-thread limits yet:** the per-thread halves and the 75% issue-queue caps are not wired (`tg_issue` leaves `tg_iq`'s `room` unused).
- **CoreMark and Dhrystone are the Linux set's own programs:**
  - static glibc builds from 10-15, without compressed code (the set moved to rv64gc on 10-17);
  - not make perf's bare-metal ELFs.
- **The console:** the kernel prints its 55 timestamped lines before /init (3,965 characters) synchronously at 115200 baud. That is 0.34 s of the 0.93 s to /init, the same on both bitstreams.

**1. Per program: the board, the RTL and the model.** IPC on rv64gc. The RTL and the model run make perf's ELFs at native latency; the board runs its own builds. The model's smt2 is `rtl_m2` with ROB 80, LQ 24, SQ 20 and 24 LLTs.

| Program | Board, d2 → d4s2 | RTL smt2, d2 → d4s2 | Model smt2, d2 → M6 | Model against the board (M6) | Model against the RTL (M6) |
|---|---|---|---|---|---|
| CoreMark A | 0.943 → 1.563 | 1.033 → 1.534 | 1.029 → 1.563 | **0.0%** | +1.9% |
| CoreMark B | 0.791 → 1.498 | 0.954 → 1.459 | 0.912 → 1.498 | **0.0%** | +2.6% |
| Dhrystone | 0.802 → 1.599 | 0.746 → 1.608 | 0.791 → 1.510 | −5.5% (not the same program) | −6.1% |

- **Per MHz** (CoreMark/MHz; DMIPS/MHz):
  - the board: 4.61, 4.36, 2.82;
  - the RTL, smt2: 4.54, 4.27, 3.20;
  - the RTL, st (main's figures; the micro-BTB check changes none): 4.55, 4.27, 3.08;
  - the model, smt2: 4.63, 4.38, 3.00.
- **Within ~10% everywhere it can run:**
  - **M6:** the model is within 2.6% of the RTL on CoreMark and 6.1% on Dhrystone.
  - **d2's core:** within 0.3–6.0% of the RTL.
  - **rv64im:** within 0.2–5.3%, except Dhrystone M6 at +9.2%. Its RTL replays the store–load race of §6.9 once a run, and the model replays it less.
  - **The window:** smt2's larger window changes nothing for CoreMark in either simulator. Dhrystone rv64gc gains 4% in the RTL and 1% in the model.
- **The Linux-level tests have no model number:**
  - fork+exec −25.3%, syscall −15.1%, page fault −15.4%, tmpfs read −44.3%, gzip −21.4% cycles;
  - the model runs bare-metal programs only (no operating system, no MMU);
  - their check is the boot (question 3).
- **d2's CoreMark is slow on the board, not d4s2's fast:**
  - **d2's CoreMark on the board** is 9% (A) and 17% (B) below its own RTL simulation. d4s2 is within 2–3% above its simulation.
  - **So the board's d2 → d4s2 CoreMark gain** (−39.9%, −47.5% cycles) is larger than the RTL's (−32.6%, −34.6%) and the model's (−34.1%, −39.1%).
  - **Not the code's placement, nor its generation:**
    - make perf's programs relinked with their code 32 B to 2 KiB later move d2's IPC by 0.1–0.2% in RTL (d4s2's by about 1%; `scripts/rtlprof/layout.sh`);
    - the two builds' hot CoreMark functions are the same code: `core_list_find` and `matrix_mul_matrix` identical, the others of equal length.
  - **Not d2's bitstream either:** d2's boot, translated as user code is, matches the board within 2–3% in simulation (question 3).
  - **Still unidentified:** something in d2's user-mode CoreMark runs on the board costs it 9–17%. It only colours the board's d2 → d4s2 CoreMark gain, not M6's figures.

**2. Why Dhrystone is lower on the board.** The core is not slower. Per instruction, the board runs Dhrystone at 1.599 IPC, against the RTL's 1.608 on rv64gc (−0.6%). Three things differ between the board's 2.82 and the simulation's 3.08:
- **The program: 13% more instructions.** The board's build executes 323 instructions per run, against 286 for make perf's ELF.
  - glibc's `strcpy` and `strcmp` are each called through an IFUNC stub: an indirect call.
  - glibc's `strcpy` is its generic `stpcpy`-based copy. The bare-metal build copies the 31-byte literal with `memcpy` and uses newlib's tuned `strcmp`.
  - CoreMark's two builds execute the same instructions within 0.5%, so its board and simulation numbers compare like for like.
- **The configuration:** smt2's larger window is worth 4% on Dhrystone rv64gc in the RTL (3.20 against st's 3.08). The coordinator's comparison mixed the board's smt2 with st's simulation.
- **The race:** make perf's rv64im ELF, without compressed code like the board's build, replays one store–load race per run (§6.9): 2.76 DMIPS/MHz in RTL. The board's build doesn't show it: its IPC is rv64gc's. The race depends on layout.

**3. /init: the board's gain, and the simulation's.**
- **The board's /init time splits into the console and the CPU's work.**
  - The console is 0.34 s, the same on both bitstreams.
  - The CPU's work is 0.840 s on d2 and 0.588 s on d4s2 (the median of three boots): −30%, or 1.43 times as fast.
  - The CPU time falls 26–33% in every boot phase, measured between kernel log lines with each line's console time taken off:

| Phase (CPU time, board) | d2 | d4s2 | Change |
|---|---|---|---|
| Kernel start to `smp: Brought up` | 0.046 s | 0.034 s | −26% |
| … to `clocksource: Switched` | 0.121 s | 0.086 s | −29% |
| … to `clk: Disabling unused clocks` (the initcalls) | 0.454 s | 0.304 s | −33% |
| … to `Freeing unused kernel image` (the initramfs unpacked) | 0.838 s | 0.585 s | −30% |
| … to `Run /init` | 0.840 s | 0.586 s | −30% |

- **The boot profile cannot predict this by itself.** It is one configuration, and its 20M cycles cover OpenSBI and only the kernel's first ~0.035 s.
  - The RTL's recorded gains over that window (smt2) add up to about +15.5% retired from d2 to d4s2:
    - speculative wakeup +2.0% (DR-154);
    - DR-169's levers +0.5%;
    - the M6 set +12.7% (with 2K tables).
  - That is equivalent to about −13% time: half the board's −26% in the same early phase. The runs below show why.
- **The direct check: both trees to /init, run as the board runs it** (`scripts/rtlprof/brd_init.sh`):

| Milestone (CPU time) | Board d2 | Board d4s2 | Change | Simulation d2 | Simulation d4s2 | Change | Simulation against the board: d2 / d4s2 |
|---|---|---|---|---|---|---|---|
| `smp: Brought up` | 0.0463 s | 0.0342 s | −26.2% | 0.0455 s | 0.0340 s | −25.3% | −1.6% / −0.4% |
| `clocksource: Switched` | 0.1217 s | 0.0856 s | −29.6% | 0.1193 s | 0.0850 s | −28.7% | −2.0% / −0.7% |
| `NET: Registered PF_PACKET` | 0.3207 s | 0.2247 s | −29.9% | 0.3105 s | 0.2181 s | −29.8% | −3.2% / −3.0% |
| `clk: Disabling unused clocks` | 0.4537 s | 0.3133 s | −30.9% | 0.4467 s | 0.3025 s | −32.3% | −1.5% / −3.4% |
| `Freeing unused kernel image` | 0.8383 s | 0.5874 s | −29.9% | 0.9266 s | 0.6839 s | −26.2% | +10.5% / +16.4% |
| `Run /init` | 0.8401 s | 0.5884 s | **−30.0%** | 0.9284 s | 0.6848 s | **−26.2%** | +10.5% / +16.4% |

- **Yes: run as the board runs it, the RTL simulation predicts the board.**
  - **Through every initcall:** it is within 0.4–3.5% of the board on both bitstreams, and each phase's d2 → d4s2 change agrees (−25% to −32%, against −26% to −31%).
  - **The initramfs unpacking diverges:** the simulation takes 25% (d2) and 39% (d4s2) longer there. That phase copies about 9 MB into the page cache, so the gap is `tb_boot`'s DDR model, slower than the board's DDR for this traffic. *(Corrected in §6.14: the phase also holds `free_initmem`'s 11.2 MB memset, and the gap is a fixed ~95 ms on all three bitstreams, not DDR latency.)*
  - **So the simulated /init gain is −26.2%, against the board's −30.0%.**
- **Why the 20M-cycle windows read about half the gain:** they are OpenSBI and the kernel's setup before its clock starts, which the board's timestamps leave out.
  - **OpenSBI:** d2 needs 1.6 times d4s2's cycles.
  - **The page-structure setup for 1 GiB:** M6 barely speeds it up (31M against 29M cycles); it is bound by stores that miss.
- **With the serial console's fixed 0.34 s added,** the simulation's /init reads 1.03 s (d4s2) and 1.27 s (d2): a −19.2% gain, against the board's 0.93 s and 1.18 s (−21.3%).

**What it changes for DR-171's ranking.** The profile of the whole boot to /init, run as the board runs it (d4s2 with the binds, `scripts/rtlprof/brd_prof.sh`; the boot core's counters, 122M cycles), against §6.11's first 20M cycles:

| Piece | LUTs per chip | First 20M cycles, board memory: estimate | Whole boot to /init: estimate (bound) | Per 1K LUTs, whole boot |
|---|---|---|---|---|
| Ownership prefetch for stores (DR-171) | 400–600 | +4.2% | **+6.2%** (18.8%) | 12.5% |
| FENCE.I by generation (DR-171) | 100–600 | +1.7% | **+0.29%** | 0.8% |
| I$ next-line prefetch with a second refill | 1,000–1,500 | +2.7% | **+1.7%** (2.4%) | 1.4% |
| DTLB replay from the LQ | 400–1,200 | +1.6% | **+0.30%** (1.0%) | 0.4% |
| Micro-BTB 128 entries | 130–150 | +0.6% | +0.31% | 2.2% |
| Checkpoints (4) | 2,000–3,000 | +2.5% | +1.6% | 0.6% |
| 8 or 16 L1D misses | 1,800–6,000 | 0 | 0 | 0 |

- **The store ownership prefetch stays first, and by more.**
  - Over the whole boot, rename is held by a full SQ while a store's line misses on 18.8% of the boot core's cycles.
  - The core that unpacks the initramfs has 11.8M such cycles of its own.
  - The absolute estimate leans high: `tb_boot`'s DDR is slower than the board's for exactly this traffic. *(§6.14: it was low, by about three times.)*
- **FENCE.I by generation is worth about 0.3% of the whole boot, not 1.7%.**
  - The boot's 5.5K FENCE.Is (code patching) all come early.
  - It stays cheap (100–600 LUTs), but it now ranks below the micro-BTB at 128.
  - Its steady-state value, FENCE.I on executable page faults, is unmeasured.
- **The next pair: the I$ next-line prefetch leads the DTLB replay from the LQ by more than before** (1.7% against 0.3%). The DTLB retries cluster in early boot too: 28.9K in the whole boot against 25.6K in the first 20M cycles.
- **Recommendation:**
  - keep DR-171's store ownership prefetch first;
  - take the I$ next-line prefetch before the DTLB replay;
  - weigh FENCE.I by generation as a 0.3% item: worth its few hundred LUTs, but not ahead of the I$ prefetch;
  - before judging the store side further, give `tb_boot`'s DDR model the board's throughput (follow-up 14).

**Decisions:** none here; DR-171's ranking is the coordinator's. No model revision: revision 7 with the board's smt2 sizes matches the board's CoreMark exactly.

**Learned:**
- **Compare like with like before reading a board-against-simulation gap.** The 8.5% Dhrystone gap was a different build (13% more instructions) plus a configuration mix, smt2 against st. Per instruction, the board runs Dhrystone at the RTL's IPC within 0.6%.
- **The board's smt2 core is a bigger single-thread core until M7.** One thread gets the whole smt2 window, and the per-thread queue caps are not wired. With those sizes the model lands on the board's CoreMark exactly.
- **Run the simulation as the board runs it, or the gains differ.** The same bench images, device tree, two cores and board-like memory reproduce the board's boot within 0.4–3.5% through the initcalls. The 20M-cycle profiles under a different setup read half the board's gain.
- **A boot's first 20M cycles are not its average.** FENCE.I and DTLB retries cluster in early boot: 1.7% each there, 0.3% over the boot to /init.
- **The testbench's DDR model is the remaining gap:** it is 25–39% slow on the page-cache copy that unpacks the initramfs. *(Withdrawn in §6.14: a fixed ~95 ms, whose cause is open.)*

### 6.13 A blind prediction for d4r1 (written 2026-10-19 13:50, before the board runs it)

*d4r1 is the final D4 bitstream, built from main c072fff. Against d4s2 it adds two pieces from DR-171:*
- *FENCE.I by generation (core-2's 855922a; no switch);*
- *the store ownership prefetch (fpu-2's `STORE_PF`, on by default).*

*DR-141's Linux set runs on it tonight. The coordinator asked for the model's and the RTL's prediction in the board's shape first (smt2, one hart a core, two cores), so the comparison is blind.*

*Scored against the board in §6.14; the text below is as written before the run.*

**CoreMark and Dhrystone: no change from d4s2.**
- **The RTL:** make perf on c072fff (smt2) against main 118b796 (d4s2's core: the micro-BTB check, without the two new pieces) moves every program by −0.02% to +0.03%.
  - Its base reproduces d4s2's make perf cycle for cycle.
  - The two programs never miss a store's line and never run FENCE.I in their timed loops.
- **The model:** `rtl_m2` revision 7 with the board's smt2 sizes, with and without `rfo_pf`, gives the same IPC to the third decimal.
- **The prediction for the board** (its own builds, its instruction counts unchanged): d4s2's figures within the board's spread (0.3–0.5%):
  - CoreMark A **4.61** per MHz (216,938 cycles an iteration);
  - CoreMark B **4.36** (229,159);
  - Dhrystone **2.82** DMIPS/MHz (202 cycles a run).

**/init's CPU time** (added 15:10, still before the board's run). `tb_boot` ran d4r1 as the board runs it (`scripts/rtlprof/brd_init.sh d4r1`), against §6.12's run of d4s2:

| Milestone (CPU time) | Simulation d4s2 | Simulation d4r1 | Change | Board d4s2 (measured) | Board d4r1 (predicted) |
|---|---|---|---|---|---|
| `smp: Brought up` | 0.0340 s | 0.0306 s | −10.1% | 0.0342 s | 0.031 s |
| `clocksource: Switched` | 0.0850 s | 0.0803 s | −5.5% | 0.0856 s | 0.081 s |
| `NET: Registered PF_PACKET` | 0.2181 s | 0.2067 s | −5.2% | 0.2247 s | 0.213 s |
| `clk: Disabling unused clocks` (the initcalls) | 0.3025 s | 0.2874 s | −5.0% | 0.3133 s | **0.298 s** |
| `Freeing unused kernel image` (the initramfs unpacked) | 0.6839 s | 0.5852 s | −14.4% | 0.5874 s | 0.51–0.57 s |
| `Run /init` | 0.6848 s | 0.5860 s | **−14.4%** | 0.5884 s | **0.51–0.57 s, about 0.54 s** |

- **The initcalls: −5%, to 0.298 s.** The simulation tracks the board within 3.5% there (§6.12), so this part is firm. The store prefetch shortens the kernel's own page and structure clearing.
- **The initramfs unpacking is the uncertain part.**
  - **In the simulation** it shrinks by 22% (0.381 → 0.298 s): the prefetch overlaps the page-cache copy's store misses.
  - **On the board** the same phase already runs 39% faster than in the simulation (`tb_boot`'s DDR model, follow-up 14).
  - **The range:** if none of that extra time is store-miss waiting, the board gains the simulation's 22% (0.214 s). If all of it is, the prefetch gains almost nothing there (0.274 s).
  - **The prediction:** 0.21–0.27 s for the phase, about 0.24 s.
- **The prediction for the board's d4r1:**
  - **/init's CPU time:** 0.51–0.57 s against d4s2's 0.588 s; about 0.54 s (−8%).
  - **The timestamp:** with the fixed 0.34 s of console, 0.85–0.91 s (about 0.88 s) against d4s2's 0.929 s.
- **Not in /init's timestamp, but in the boot:** both pieces act mostly before the kernel's clock starts. There the simulation's d4r1 sets up the 1 GiB page structures 35% faster (13M against 20M cycles) and starts its clock 9M cycles (90 ms) earlier. Most of the boot's 5.5K FENCE.Is come before the clock too.
- **The Linux set's other tests are not predicted** (no simulation of them). The store prefetch should move those that store to lines not yet in the cache:
  - page fault (each page cleared);
  - memset and memcpy of 1 MiB;
  - tmpfs write;
  - fork+exec.

  CoreMark and Dhrystone should not move (above).

### 6.14 d4r1 on the board against the blind prediction (2026-10-19, after MR23)

*MR23 ran DR-141's set on d4r1 (main c072fff), three boots. This scores §6.13, written before the board ran, and says what its misses teach. The board's consoles are parsed as in §6.12 (`scripts/m6_board.py --init`, each line's console time taken off); the model's check is `--copy`.*

**The scorecard:**

| What | Predicted (§6.13) | Board d4r1 | Verdict |
|---|---|---|---|
| CoreMark A | 4.61 per MHz (216,938 cycles an iteration) | 4.60 (217,268: +0.2%, spread 0.5%) | Right |
| CoreMark B | 4.36 (229,159) | 4.36 (229,231: +0.0%) | Right |
| Dhrystone | 2.82 DMIPS/MHz (202 cycles a run) | 2.82 (202: −0.1%) | Right |
| CPU time to the initcalls' end (`clk: Disabling unused clocks`) | 0.298 s | 0.292 s | Right (−1.9%) |
| The tail after the initcalls (to `Freeing unused kernel image`) | 0.21–0.27 s, about 0.24 s | 0.198 s | Missed: 8% under the range |
| CPU time to /init | 0.51–0.57 s, about 0.54 s | 0.491 s | Missed: 4% under the range |
| /init's timestamp (with 0.34 s of console) | 0.85–0.91 s, about 0.88 s | 0.831 s | Missed: 2% under the range |
| Which Linux tests move | page fault, memset and memcpy of 1 MiB, tmpfs write, fork+exec; not CoreMark or Dhrystone | those five (−28.1%, −29.0%, −34.5%, −19.3%, −1.9%) and tmpfs read (−4.5%); CoreMark, Dhrystone, gzip, sha256sum, syscalls and the small copies within 0.2% | Right, one more than listed |

**The simulation was right; the range around it was not.**

| Milestone (CPU time) | Simulation d4s2 → d4r1 | Board d4s2 → d4r1 | The simulation's ratio applied to the board |
|---|---|---|---|
| `smp: Brought up` | 0.0340 → 0.0306 s (−10.1%) | 0.0342 → 0.0309 s (−9.6%) | 0.0307 s (−0.6%) |
| `clocksource: Switched` | 0.0850 → 0.0803 s (−5.5%) | 0.0856 → 0.0805 s (−6.0%) | 0.0809 s (+0.6%) |
| `NET: Registered PF_PACKET` | 0.2181 → 0.2067 s (−5.2%) | 0.2247 → 0.2110 s (−6.1%) | 0.2130 s (+1.0%) |
| `clk: Disabling unused clocks` | 0.3025 → 0.2874 s (−5.0%) | 0.3133 → 0.2922 s (−6.7%) | 0.2977 s (+1.9%) |
| `Freeing unused kernel image` | 0.6839 → 0.5852 s (−14.4%) | 0.5874 → 0.4898 s (−16.6%) | 0.5026 s (+2.6%) |
| `Run /init` | 0.6848 → 0.5860 s (−14.4%) | 0.5884 → 0.4908 s (−16.6%) | 0.5035 s (+2.6%) |

- **Scaled by its own ratio, the simulation gave 0.504 s:** 2.6% above the board.
- **In seconds it was closer still:** the simulation saved 98.8 ms to /init and the board 97.6 ms, within 1.2%. The board's d4s2 time less the simulated saving is 0.490 s, 0.2% from the board's 0.491 s.
- **My range discounted the tail's simulated gain** from 22% to somewhere between 22% and nothing. §6.12 had blamed the simulation's slower tail on `tb_boot`'s DDR: store misses waiting longer than on the board. If that were so, the board would have less waiting for the prefetch to hide. Instead the board gained more there: −27.9% against the simulation's −21.9%.
- **The console is unchanged:** 0.3405 s inside /init's timestamp on both bitstreams.

**What the tail holds, and what was wrong with §6.12's diagnosis.**
- **The tail is two pieces of work** (`tb_boot`'s PC samples, every 1M cycles on both cores):
  - **the end of the initramfs unpacking:** an async worker on one core while the other idles in `wfi`. About 22M cycles on d4s2 and 21M on d4r1 (31M on d2).
  - **`free_initmem`:** it poisons the 11.2 MB of freed init memory with `memset` (0xcc), a pure store stream. The kernel's `memset` loop (32 `sd` per 256 bytes) takes 12 of the last 15 samples on d4s2 and 8 of the last 9 on d4r1. This is where the store prefetch gains most: about 12–15M cycles fall to about 8–9M.
- **The simulation's tail runs a fixed time longer than the board's, whatever the core.**
  - At `Freeing unused kernel image` the simulation is 88 ms behind the board on d2, 97 ms on d4s2 and 95 ms on d4r1. At the initcalls' end it is 5–11 ms ahead.
  - A slower DDR makes store misses wait longer, and the prefetch hides exactly those waits, so the offset would have shrunk from d4s2 to d4r1. It did not.
  - No sample has both cores idle, so it is not a timed wait: it is work on the core running the tail.
  - verif-2 finds that DDR latency does not explain it (follow-up 14). The cause is still open.
- **So §6.12's diagnosis ("`tb_boot`'s DDR model, 25–39% slow") is withdrawn.** The gap is a fixed ~9.5M cycles, which reads as 25%, 39% and 51% of the board's tail as the core gets faster.
- **The tail by cause** (added after verif-2's question; d4s2's boot rerun with `prof_m6.sv`'s `+prof_snap=1000000`, cycle-identical, and `scripts/rtlprof/prof_window.py`). Shares of each window's cycles, on the core doing the work; the other core sits in `wfi` 86–88% of each tail window:

| Window (d4s2) | IPC | Head: a load waiting on a D$ miss | The store drain waits on a line | Rename held by a full SQ, the drain waiting | D$ miss entries busy: 1 / 2 / 3 |
|---|---|---|---|---|---|
| The initcalls, 61–83M (core 0; they match the board) | 0.696 | 13.4% | 20.2% | 10.6% | 20.6% / 8.7% / 0.3% |
| The unpacking's end, 84–106M (core 0) | 0.710 | 25.9% | 29.6% | 22.0% | 19.1% / 19.6% / 0.9% |
| `free_initmem`'s memset, 107–121M (core 1) | 0.252 | 2.0% | 73.6% | 70.2% | 77.0% / 0.2% / 0 |

  - **The memset fetches one line at a time:** exactly one miss entry is busy 77% of the window, and the drain waits on a line 74%. Over its 179,392 lines that is about 57 cycles of drain wait and 60 of one miss in flight per 64 B line: one ownership round trip each, in series. d4s2 has no store prefetch.
  - **The unpacking's end is a copy:** loads and stores both miss, with up to two lines in flight.
  - **What differs from the initcalls is streaming dirty lines.** Each line of the memset and of the page-cache copy is written and later evicted. A per-line cost that the core cannot overlap (a write-back holding up the next fetch, say) fits a fixed offset better than latency does: about 29 cycles a line over the tail's roughly 330K DDR lines. This is an inference. verif-2's `memcal` (memset, memcpy and a streaming read, in the TB and on the board) tests it.

**The rule for predicting the board from `tb_boot`: add the simulation's change in seconds to the board's time, milestone by milestone.** Do not scale by the simulation's ratio while `tb_boot` carries a fixed offset.

| Step | Board, measured | Board time + the simulated change | Board time × the simulated ratio |
|---|---|---|---|
| d2 → d4s2 (§6.12) | 0.588 s | 0.597 s (+1.4%) | 0.620 s (+5.3%) |
| d4s2 → d4r1 | 0.491 s | 0.490 s (−0.2%) | 0.504 s (+2.6%) |

- **Pros:**
  - both steps land within 1.4%;
  - the rule needs no knowledge of the offset's cause.
- **Cons:**
  - it rests on two steps;
  - it assumes the offset does not move with the change. That holds for these three cores, but not for a change that reaches the offset's cause.
- **Once follow-up 14 removes the offset,** the two rules agree.

**The store prefetch was worth about three times its estimate.**
- **The estimate (§6.11, §6.12):** +4.2% of the boot's first 20M cycles, +6.2% of the whole boot.
  - Its base: the cycles rename is held by a full SQ while a store's line misses. That is 18.8% of the boot core's cycles over the whole boot.
  - Its factor: 0.33, the share of such cycles the model's prefetch saved on `ws_copy` (st sizes).
- **Measured in the simulation:** the whole boot to /init, from reset, falls from 121.9M to 102.5M cycles (−15.9%). 9.5M of that comes before the kernel's clock starts, most of it in the 1 GiB page-structure setup (20M → 13M cycles, §6.13). FENCE.I by generation's estimate is +0.3% of the boot.
- **So the prefetch removed most of the stall, not a third.** It saved 19.4M cycles of wall time. The stall held 22.9M cycles on the boot core and 11.8M more on the core that unpacks (§6.12), so it removed between 0.56 and 0.85 of it.
  - The boot's store misses are page clears and poisoning: pure store streams.
  - On a copy, where loads miss too, the model's prefetch saves 0.36–0.50 of such cycles.
- **On the board:** CPU time to /init −16.6%, page faults −28.1%, memset 1 MiB −29.0%, memcpy 1 MiB −34.5%.
- **The model on the board's copy.** `rtl_m2` revision 7 in the board's shape (M6, smt2 sizes, the SoC's uncore at 100 MHz) runs `ws_copy_2048`, which copies 1 MiB from a 1 MiB source as the board's test does:

| Copy | Instructions a byte | d4s2: cycles a byte | d4r1: cycles a byte | Change | Rename held by a full SQ (model) |
|---|---|---|---|---|---|
| Model, `ws_copy_2048` (newlib's `memcpy`) | 0.306 | 0.778 | 0.538 | **−30.8%** | 61.6% → 31.0% of cycles |
| Board, memcpy 1 MiB (glibc's) | 0.465 | 1.178 | 0.772 | **−34.5%** | – |
| Model, `ws_copy_1024` (512 KiB, L2-resident) | 0.306 | 0.484 | 0.402 | −17.0% | 47.5% → 0.0% |

  - The model's gain is within 4 points of the board's. The programs differ, so the absolute cycles a byte do not compare.
  - In IPC, the model goes from 0.393 to 0.569 and the board from 0.395 to 0.598.
- **The ranking stands:** the prefetch was first, by more than estimated. Estimates built from a bound should take their factor from a kernel with the target's mix of misses.

**Decisions:**
- **This study predicts the board from `tb_boot` by adding the simulated change in seconds** (mine; pros and cons above). The cores' tracks measuring with `brd_init.sh` should read their gains the same way: core-2's I$ next-line prefetch is next.
- **No model revision:** revision 7's ownership prefetch is within 4 points of the board's memcpy gain.

**Learned:**
- **A hedge is a prediction too.** The simulation's own number was within 2.6% of the board. The range I built around an untested diagnosis missed by 4%.
- **Check a gap's shape across versions before naming its cause.** The tail's gap was a fixed ~95 ms on three cores, which rules out latency. Read as a ratio (25–39%), it looked like a slow DDR.
- **Name a phase by what runs in it.** "The initramfs unpacking" also held `free_initmem`'s 11.2 MB memset. PC samples showed it.
- **Take an estimate's factor from a kernel with the same miss mix.** A copy realizes 0.36–0.50 of the store-drain stall; the boot's page clears realize most of it.

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

This estimate costs second copies and leaves out the PMP descriptor select (+1.7K per core with DR-139's three checkers, measured). §7.7 and the M7 brief ([hart1_ram_form.md](hart1_ram_form.md)) give the corrected bases: ≈3.7K per core in RAM form, ≈5.9K as copies.

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
| **3. The reserve (AR-6)** | In order:<br>R9 0.5K, R10 1.0K;<br>FP queue 8 and LD queue 4, ≈0.7K with tags;<br>**last,** release builds without the commit trace (DR-121): 1,466 LUTs per core plus ≈2.9K for the uncore's trace stream, at no IPC cost. Development builds keep the trace.<br>**Not in AR-6:** the page walker sharing the STA's PMP checker (0.83K per core), which the user has since adopted (DR-139); and radix-4, out (DR-118). | **≈8.0K**: ≈2.2K before the trace, ≈5.8K from it |

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
- **103,040: the sum of v1's budgets** (S6's 88% at 200 MHz). Step 1 works to these per-unit lines.
- **The fill test by clock** (S6 method, v1 with tags, 2026-10-15; plan §8.5) measures the device's ceilings:
  - 200 MHz: 93.4% closes (109,407). At 95.3% (111,652) it misses by 0.037 ns, only on a harness filler register, so the real ceiling is about 94–95%.
  - 180 MHz: 98.3% (115,174).
  - 170 MHz: 98.3% (115,175).
  - 150 MHz: 99.3% (116,301), where the device's placement, not timing, is the limit.

  The 99% fills at 160 and 170 MHz are still running.
- **Which clock and fill to plan for is the user's decision** (DR-137), and lowering the clock needs their explicit approval. So every ceiling column, and any sum of a ceiling and the reserve, is a decision for the user, not a path the project takes.

These ceilings replace the plan's 90% line (105,408, DR-011) and the earlier 180 MHz line (111,633: 95.3%, area_synth.md §5), so every row is restated here. Older rows are restated from their rounded v1 figures.

**The settings.**
- From the third pass on, the budget flow builds the core with DR-113's settings: the hierarchy kept, plus `AreaOptimized_high` (814c4e7). The budgets assume them (R14), so those rows compare like with like.
- Earlier rows use the old settings, and so does every uncore figure before the last row.
- The core runs record no commit, so each row names its run.

**Step-1 saving** is what a row saved per SoC against the row before, by no-IPC, cycle-identical work. Since DR-123 that work is the FPGA-friendly program. The settings change has its own row.

```bash
python3 perfmodel/scripts/area_fit.py --core <core budget run>/latest.json --uncore <uncore budget run>/latest.json
```

| Date | Milestone | Settings | `st` core | `smt2` core | v1 dual-core | Step-1 saving (per SoC) | Over 103,040 (the budgets) / 109,407 (200 MHz, 93.4%: the user's decision) | Over 115,174 (180 MHz, 98.3%: the user's decision, DR-137) |
|---|---|---|---|---|---|---|---|---|
| 2026-10-13 | Planning projection (spikes §10) | — | — | — | 99–110K | — | −4K to +7K / −10K to +1K | −16K to −5K |
| 2026-10-14 01:30 | First real synthesis, d04ae26 (no FPU; P4 7,953 and hart 1 added) | old | 81,715 | 89,050 | ≈224.7K | — | ≈+121.6K / ≈+115.3K | ≈+109.5K |
| 2026-10-14 07:30 | AR-7: area pass, AR-1, F/D (c898f1e, cb8ff6c) | old | 56,461 | 62,501 | **155.7K** | ≈−69.0K | **+52.6K** / +46.3K | **+40.5K** |
| 2026-10-14 | Core track's second no-IPC pass, as reported first (a32d2aa, 8a5c651) | old | 50,768 | 54,506 | ≈141.3K (with the revert below) | — | ≈+38.3K / ≈+31.9K | ≈+26.1K |
| 2026-10-14 08:38 | Second pass at the core track's final head, 5c124f2: `out14_st`, `out14_smt2` | old | 51,707 | 55,436 | **141.5K** (120.8%) | −14.1K | **+38.5K** / +32.1K | **+26.3K** |
| 2026-10-14 10:07 | Third no-IPC pass with DR-120, before the FLW-boxing fix: `out20_st`, `out20_smt2` | old | 49,097 | 51,839 | 134.3K (114.7%) | −7.2K | +31.3K / +24.9K | +19.1K |
| 2026-10-14 11:25 | Third pass as merged (main 43a523e): `out23_st`, `out23_smt2` | cores DR-113; uncore old | 46,132 | 49,022 | 128.7K (109.9%) | −5.6K (the cores' settings) | +25.7K / +19.3K | +13.5K |
| 2026-10-14 13:02 | The uncore with DR-113's settings: the SoC track's MR at 4d5ca13 (`budget_mr3_dr113`), with the 11:25 cores | DR-113 (cores and uncore) | 46,132 | 49,022 | 127.0K (108.4%) | −1.7K (the uncore's settings) | +24.0K / +17.6K | +11.8K |
| 2026-10-14 15:13 | The core track's FPGA-friendly pass (DR-123, DR-125; MR pending at 2cf1cd9): `out29_st`, `out28_smt2`, with the 13:02 uncore | DR-113 | 43,342 | 45,992 | 120.9K (103.3%) | −6.1K | +17.9K / +11.5K | +5.7K |
| 2026-10-14 16:31 | Estimate with main's merges since: the FPU's DR-123 pass (4c60319), measured in the core at `st` (`out30_st` at 4eb7ce0, the core track's next branch: −337) and applied to `smt2`; the crossbar (89d8001: −249, measured with the old flow) | DR-113 (est.) | 43,005 | ≈45,655 | ≈120.0K (102.5%) | ≈−0.9K | ≈+17.0K / ≈+10.6K | ≈+4.8K |
| 2026-10-14 17:21 | Measured: the core track's next branch (4eb7ce0: the FPGA-friendly pass and main's merges; `out30_st`, `out30_smt2`) and the SoC track's uncore pass (e7227d4: the crossbar's constants and one-hot L2 MSHR state; `budget_onehot`) | DR-113 | 43,005 | 45,637 | 119.6K (102.1%) | −0.4K | +16.6K / +10.2K | +4.4K |
| 2026-10-14 17:46 | Measured, both merged: the core's second FPGA-friendly pass, fn2 (main 7d60948; `out33_st`, `out33_smt2` at e5c2b4f, the same RTL), with the 17:21 uncore (main 9be0707) | DR-113 | 42,607 | 45,055 | 118.4K (101.1%) | −1.2K | +15.4K / +9.0K | +3.2K |
| 2026-10-14 19:52 | Measured: the SoC's DR-136 pass, register slices in DSPs (main 78e40f5; `budget_dsp2` at 44767a1), with the fn2 cores | DR-113 | 42,607 | 45,055 | 117.1K (100.0%) | −1.3K | +14.1K / +7.7K | +1.9K |
| 2026-10-14 21:25 | Estimate at main's head (78e40f5): the FPU track's merge (3121edd) from its unit runs, P4 −123 / −122 and Execute −367 / −368 at `st` / `smt2` | DR-113 (est.) | ≈42,117 | ≈44,565 | ≈116.1K (99.2%) | ≈−1.0K | ≈+13.1K / ≈+6.7K | ≈+0.9K |
| 2026-10-15 04:39 | Measured: core-2's fn4 (main 6dd8d96; `out38_st`, `out38_smt2` at 028f45e: DR-139's PMP sharing, the core track's timing restructures, and the FPU track's merges through P4 step 6), with the SoC's L2 S2 restructure (main 951c235; `budget_s2h` at ca1aece) | **DR-113** | **42,045** | **44,720** | **116.7K** (99.7%) | +0.6K (−0.4K against 19:52) | **+13.7K** / +7.3K | **+1.6K** |
| 2026-10-15 05:55 | Estimate at main's head (6dd8d96): the FPU track's P4 steps 7 and 8 (63acc88) from their unit runs, −97 and −96 per core, an upper bound | DR-113 (est.) | ≈41,852 | ≈44,527 | ≈116.4K (99.3%) | ≈−0.4K | ≈+13.3K / ≈+7.0K | ≈+1.2K |

**The latest cores, per unit at `smt2` against the v1 budgets.** Measured at core-2's fn4 (`out38_smt2` at 028f45e: the RTL merged in main 6dd8d96, without the FPU's P4 steps 7 and 8), with DR-113's settings. Hart 1 is added on the budgets' basis, by `area_fit.py`.

| Unit | Measured | + hart 1 (budgets) | Budget | Over | At 7d60948 (fn2) | After the third pass | At 5c124f2 (old settings) |
|---|---|---|---|---|---|---|---|
| Front end | 4,856 | +1.0K | 6,480 | −624 | −742 | −742 | −476 |
| Decode | 1,893 | +0.15K | 1,640 | +403 | −53 | −53 | +187 |
| Rename | 3,086 | +1.3K | 1,830 | **+2,556** | +2,502 | +3,973 | +4,259 |
| Issue queues and wakeup | 5,261 | — | 8,350 | −3,089 | −3,089 | −3,082 | −2,920 |
| Execute | 7,482 | — | 7,610 | −128 | +212 | +408 | +1,021 |
| LSU and MMU | 10,994 | +0.1K | 8,560 | **+2,534** | +3,238 | +3,916 | +6,955 |
| ROB, commit, traps, CSRs, PMP | 3,966 | +1.65K | 4,840 | +776 | +609 | +2,095 | +3,173 |
| FPU (P4) | 7,010 | — | 6,800 | +210 | +296 | +425 | +1,153 |
| **Core** (with glue) | **44,720** | **+4.2K** | **46,120** | **+2,800** (+6%) | +3,135 | +7,102 | +13,516 |

**Reading it:**
- **Each `smt2` core is 335 LUTs smaller than at fn2:**
  - the FPU track's merges (execute's step 3, P4's steps 4 to 6): Execute −340 and P4 −86 in the core, where their unit runs had −368 and −241;
  - the LSU and MMU −704: DR-139's PMP sharing (−0.83K at `st`), with the LSU's timing changes in it, among them the ROB head's own DTLB port;
  - the core track's cycle-identical timing restructures (fn3 and fn4) added +795: decode +456 and the front end +118 (the three-input PC-relative adds and the carry-free redirect check), the ROB and CSRs +167, and rename +54 (the free counts as registers).

  Without hart 1 the core is 1,400 under its line.
- **What is left per core, +2.8K with hart 1 on the budgets' basis:**
  - rename +2.6K;
  - the LSU and MMU +2.5K;
  - the ROB and CSRs +0.8K;
  - decode +0.4K and P4 +0.2K.

  The issue queues (−3.1K), the front end (−0.6K) and Execute (−0.1K) are under budget.
- **Not in these core runs: the FPU track's P4 steps 7 and 8** (main 63acc88).
  - Their unit runs take P4 −97 and −96 (7,037 → 6,844 at `smt2`). Step 8 hands both FP banks to the core, whose trace multiplexer grows from 2:1 to 3:1; the LSU alone is unchanged.
  - The 05:55 row estimates main's head with −193 per core. Take it as an upper bound: since fn2, P4 saved 86 in the core for 241 in its unit runs. The next core run replaces it.
- **The uncore, measured: 18,903 at `smt2`** (the SoC's L2 S2 restructure, main 951c235; `budget_s2h` at ca1aece, the same RTL; DR-113's settings).
  - That is +300 since 78e40f5, for the restructure: the bank's S2 path went from −2.125 to −0.638 ns.
  - It is +8.1K over its 10,800 budget.
- **Watch: the SoC's per-site DSP check** (cd1f584, on its branch, not merged).
  - It keeps a register slice in DSPs only where it passed 200 MHz in every placement: 30 DSPs at `smt2` instead of 84.
  - Its uncore measures 19,664 (+761), which would raise every v1 figure below by ≈0.8K.
- **Open risk: the uncore still misses 200 MHz.**
  - All in fabric, its out-of-context check now fails by 0.74–0.91 ns (from 1.78), on the L2's S2 into the directory RAM and its AR handshake (budgets.md §4).
  - Its numbers also assume DR-113's settings. Keeping the old ones would add back ≈1.7K per SoC (7.7%, as measured at 4d5ca13).
- **DR-133 is out** (rejected at gate 3: the issue → URAM address path misses 200 MHz by about 5 ns, mostly wire to the device's single URAM column), so the bases below drop it.
- **`st`, for reference:** 42,045 against 38,220 (+3.8K): the LSU and MMU +2.2K, rename +1.7K, the ROB and CSRs +1.2K.

**Hart 1: three bases** (v1, per core). The M7 brief, [hart1_ram_form.md](hart1_ram_form.md), has the detail for each structure.
- **The budgets' basis** (4.2K, used in every row above) costs second copies. The SMT2 study (§8.3) priced flip-flop maps with 64-entry read selects, and second FTQ and RAS tables with their own ports. R1 and R2 were already off the CSRs.
- **The PMP descriptor select, measured.**
  - The 16 region descriptors (72 bits each) are read in parallel by every `tg_pmp` checker. So hart 1 needs its own 1,152 flip-flops, and every checker needs a select of the requesting hart's set.
  - Out of context with DR-113's settings, a checker grows from 891 to 1,467 LUTs (S = 1); fetch's (S = 2) grows from 958 to 1,534. That is +576 each, one LUT per two select bits.
  - Since DR-139 three checkers remain: fetch, LD, and STA, which the walker shares. That makes +1,728 per core (+2,304 with four).
  - Neither earlier estimate counted it, and it is the same in both forms.
- **RAM form** (conventions §7): the per-thread tables take `tid` as an address bit. The rest comes to ≈2.0K, plus the PMP select. fn2 built R2's cold-CSR table (xtvec, xscratch, xepc, xcause, xtval), so mepc and sepc no longer count as hot state.

**v1 against the budgets and the measured ceilings.** Cores at 028f45e (fn4), uncore at 951c235. Every ceiling column is the user's decision (DR-137):

| Basis | Hart 1 per core | v1 | Over the budgets' 103,040 | Over 200 MHz's 109,407 (93.4%) / 111,652 (95.3%, a harness-only miss) | Over 180 MHz's 115,174 (98.3%) | Over 170 MHz's 115,175 (98.3%) | Over 150 MHz's 116,301 (99.3%) |
|---|---|---|---|---|---|---|---|
| Budgets (second copies, no PMP select) | 4.2K | 116.7K (99.7%) | +13.7K | +7.3K / +5.1K | +1.6K | +1.6K | +0.4K |
| RAM form with the PMP select | ≈3.7K | **115.7K** (98.8%) | **+12.7K** | **+6.3K** / +4.1K | +0.5K | +0.5K | −0.6K |
| Second copies with the PMP select | ≈5.9K | 120.2K (102.6%) | +17.2K | +10.8K / +8.5K | +5.0K | +5.0K | +3.9K |

- **At main's head,** with P4's steps 7 and 8 estimated from their unit runs, each v1 figure is up to ≈0.4K lower: ≈116.4K, ≈115.3K and ≈119.8K. In RAM form that is ≈5.9K over 200 MHz's clean ceiling, ≈0.2K over 180 and 170 MHz's, and ≈1.0K under 150 MHz's.
- **Against 200 MHz's clean ceiling, the RAM form's 6.3K is within the reserve's size.**
  - The reserve is ≈8.0K in old-settings figures, ≈5.8K of it trace-free release builds (DR-121).
  - The user decides each of its levers (DR-135), as they decide the ceiling (DR-137), and D18 takes step 1 first.
  - Against the budgets, step 1's own lines, the RAM form is still 12.7K over.
- **The RAM forms save ≈2.2K per core** (≈4.5K per SoC) against copies.
- **The PMP select is still hart 1's largest item:** 1.7K of the RAM form's ≈3.7K. The brief lists ways to cut it further. Each costs cycles or function, so each would go on the reserve list for the user to decide (DR-135).
- **M7 replaces every estimate** with the first `smt2` synthesis that has hart 1's state (`area_fit.py --hart1 budgets|copies|ram` until then).

**Notes on the earlier rows.**
- **The second pass as reported first** measured the page walker sharing the STA's PMP checker. That sharing was reverted under D18 (DR-122), and the final head has its own checker back: +1.0K in lsu_mmu at `smt2`, against the 0.83K expected. The user has since adopted the sharing (DR-139), from the 04:39 row on.
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

### 7.8 Room for M6's set at 100 MHz: the area levers, ranked (desk study, 2026-10-18)

*The coordinator's question, after spikes.md §8.11: M6's set with the restructured F2 (1e4a503), the two-table TAGE and hart 1's area does not place at 100 MHz. Which levers make room, how much each gives, and at what cost? This is a desk study: the full chips' per-unit reports, the FPU track's out-of-context runs, and a unit synthesis wherever a lever looked worth 300 or more LUTs a chip and had no number. No full chip was run.*

**What is needed.**
- **To place:** at least ≈600 LUTs a chip. After `opt_design`, 1e4a503's synthesized chip has **117,786 LUTs, 666 over the device's 117,120** (this study, on spikes-2's `h100_m6f` checkpoint). The placer came up 73 CLBs short.
- **For timing margin:** 1.5–2K. Above 96% fill the slack falls about 0.8 ns per 1K LUTs (§8.9 of spikes.md). Tree (ii), which placed at 98.3%, failed by 1.63 ns once every front-end path was taken out.
- **For M6's later pieces and M7/M8:** about 5K.

**The basis.**
- **The full chip, per unit** (tree (ii), c149fce, placed at 115,185 LUTs: `fpga/spikes/results/h100_m6t/util_hier.rpt`):
  - each core is 45.9K: the LSU 12.3K, execute 6.9K, P4 6.3K, fetch 6.0K, the issue queues 5.1K, rename 3.0K, the ROB 2.6K, decode 2.0K, the CSRs 1.4K;
  - the uncore is 15.9K: the L2 9.2K, the crossbar 2.5K, the two latency injectors 1.3K, the host bridge 0.9K;
  - hart 1's filler is 3.7K a core.
- **Unit syntheses** (this study): DR-113's settings (hierarchy kept, `AreaOptimized_high`), counted after `opt_design`, on main 37f2658 with the change in a scratch copy:

  | Unit | As built | With the lever | Change |
  |---|---|---|---|
  | `tg_pmp`, one granule (the LD and STA checkers) | 891 | 450 (8 entries) | −441 |
  | `tg_pmp`, a fetch block (fetch's checker) | 958 | 485 (8 entries) | −473 |
  | `tg_fp_exec` (P4) | 6,813 LUTs, 4,001 FFs, 37 DSPs | 6,188, 2,812, 8 (`FDIV_RADIX4`) | −625 LUTs |
  | `tg_core` at `smt2` | 46,524 LUTs, 21,853 FFs | 46,125, 21,505 (FP queue 8, LD queue 4) | −399 LUTs |

- **`opt_design` directives** on 1e4a503's synthesized chip (`h100_m6f_synth_post_synth.dcp`), with no placement: the default 117,786 LUTs; `ExploreWithRemap` 117,467 (−319); **`ExploreArea` 116,511 (−1,275)**. Flip-flops are 62,403 in all three.

**The levers.** LUTs are per chip: two cores, or the uncore once. IPC is from the model (§3) unless marked. "Decides" follows DR-154: under 1% performance and under 1,200 LUTs a chip, the coordinator; otherwise the user.

| # | Lever | Unit (owner) | LUTs a chip | IPC or function cost | Effort | Risk | Decides |
|---|---|---|---|---|---|---|---|
| | **1. No IPC** | | | | | | |
| 1 | **`opt_design -directive ExploreArea`** in the full-chip flow, in place of the default | flow (spikes) | **1,275** (measured, above) | none: no RTL change | low: one option | timing: an area directive can lengthen paths, so one placement must check it | coordinator |
| 2 | **Release builds without the latency injectors** (a pass-through instead of `tg_axi_lat_inj` per L2 bank) | uncore (SoC) | **1,293** (measured in the chip), and 556 FFs and 4 BRAM36 | none at native latency: a miss is a few cycles faster without the injector's buffering (so not cycle-identical). Release builds lose latency emulation and its native-latency counts; development builds keep them, as with DR-121's trace | low: a build switch | low | user (function) |
| 3 | The D$ tags in block RAM (T3), read with the virtual index at AG | LSU (core-2) | ≈1,280 (640 LUTRAM a core) | none, with a bypass for a tag written between AG and M1 | high: three read ports, so copies, ≈15 BRAM36 a chip of the 23 free | medium | coordinator |
| 4 | Execute's operand ports in URAM (DR-133, revived) | execute (FPU track) | ≈1,190 (−597 a core, measured then), +24 URAM | none | medium: the switch is on `claude/track-fpu-395911-dr133-gate3` | **high:** at 200 MHz its issue → URAM path measured ≈9.8 ns, 7–8 ns of it wire to the single URAM column. At 100 MHz with the 1 ns over-constraint it would still miss | — (not proposed) |
| | **2. Function, or small IPC** | | | | | | |
| 5 | **PMP with 8 entries instead of 16:** entries 8–15 are read-only zero (every PMP CSR field is WARL and may be read-only zero; software probes the count), Spike runs with `--pmpregions=8` | fetch, LSU, CSRs (core-2) | **2,710 now** (3 checkers a core, measured), 1,152 FFs (the descriptor registers), **and ≈1.7K of hart 1's area at M7**: its per-hart descriptor select halves too (≈0.86K a core of [hart1_ram_form.md](hart1_ram_form.md)'s 1.7K) | IPC none. Function: 8 PMP regions. Our boot uses 6: OpenSBI's Domain0 has firmware RW, firmware RX, UART, ACLINT, PLIC and the all-memory region (`Region00`–`05`); Linux uses none | low: a parameter, the CSR's read-only-zero entries, the harness's Spike flag | low | user (function, > 1,200) |
| 6 | One checker for the LD and STA pipes (DR-139 gave STA's checker to the walker already). The DTLB's cached result (`ph`) covers translated pages, and M-mode with no locked entry needs no check, so on Linux the checker is almost never wanted twice in a cycle | LSU (core-2) | 1,780 (one 891 checker a core), or 900 after #5 | ≈0 on Linux: a wait only for untranslated S/U accesses, pages crossing a PMP boundary and M-mode with locked entries. Not cycle-identical | medium: an arbiter and the bypass | medium | user (> 1,200) or coordinator (after #5) |
| 7 | **FP queue 10 → 8 and LD queue 6 → 4** (AR-6) | issue (FPU track) | **798** (measured) and 696 FFs | model, v1 with tags: −0.21% throughput, −0.29% single thread. Not re-run with speculative wakeup; one `make perf` would | low: two configuration values | low | coordinator |
| 8 | Radix-4 divide and square root (`FDIV_RADIX4`, DR-118) | P4 (FPU track) | **1,250** (measured), 2,378 FFs, 58 DSPs | −0.4% throughput, −2.4% single thread, all FP divide and sqrt (nbody −47%, st −43%) | low: a switch | low | user (> 1,200, > 1% single thread) |
| 9 | R9: forwarding only from a same-address, same-size store | LSU (core-2) | ≈400–600 (AR's estimate; the LSU's forwarding has been reworked since and was not re-measured) | −0.03% throughput | medium | medium | coordinator |
| 10 | R10: checkpoints shared by the threads | rename | **0**: today's rename has no checkpoints (every recovery is at commit) | — | — | — | — |
| 11 | DR-121: release builds without the commit trace | core, uncore | **0 more**: every full chip already defines `TG_COMMIT_TRACE=0`, so the 120,787 excludes it | — | — | — | — |
| | **3. For comparison** | | | | | | |
| 12 | TAGE's second table (§6.5) | fetch (core-2) | 660 | make perf +3.7 points (−16.0% against −12.3% cycles), ≈5.6% per 1K LUTs | — | — | user |
| 13 | Hart 1's reserve (M7's SMT2) | core | 7,400 (3.7K a core, RAM form) | the second thread | — | — | user |

**Top three.**
1. **`opt_design -directive ExploreArea` (1,275, no RTL, no cycles).** It alone brings 1e4a503 under the device (116,511, 609 to spare after optimisation). It needs one placement to show it costs no clock, and spikes-2's next full chip can carry it.
2. **PMP with 8 entries (2,710 now, ≈1.7K more at M7, no IPC).** It is the largest lever, it costs no performance, and our software uses 6 regions. It is a function change, so the user decides.
3. **Release builds without the latency injectors (1,293 and 4 BRAM36, no IPC).** It is the same kind of lever as DR-121's trace: development builds keep the injectors.

Together they come to ≈5.3K a chip, at no IPC cost. The next ones are the queue trims (798, −0.2%, the coordinator's call) and the shared LD/STA checker (900 after #5). TAGE's second table buys more per LUT (≈5.6% of make perf per 1K) than any IPC-costing lever here gives up: radix-4 loses 1.9% of single-thread IPC per 1K LUTs.

**Where the earlier passes already harvested** (nothing above counts them again):
- **The commit trace** is off in every full chip (DR-121's ≈5.8K is already out of 120,787).
- **Built and inside the measured numbers:**
  - wakeup tags (AR-1); R1 (counters in DSPs), R2 (cold CSRs in LUTRAM) and R3 (LUTRAM maps); R14 (DR-113's settings, which the chip's synthesis uses);
  - DR-139 (the walker shares STA's PMP checker);
  - DR-136 (the uncore's register slices in DSPs);
  - the core track's FPGA-friendly passes, and the FPU, execute and uncore rows of fpga_friendly.md §4.
- **Shrunk since they were priced:** radix-4 saved 1,036 a core in DR-118, before the FPU's passes, and saves 625 now. AR-6's queue trims were model estimates (≈0.17K a queue a core with tags) and measure 399 a core for both.
- **Gone:** R10 (no checkpoints left to share).
- **Rejected and not revived:** DR-133's URAM ports (timing, above). PMP compares in DSPs (T6) were considered too: they need a register in front of each checker, so the PA from the TLB would arrive a cycle late. That is not cycle-identical, so it is not in the table.

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
7. ~~The model's backend gap (§6.7)~~: **done** (§6.8). Rename's steering was most of it; `rtl_m2` revision 6 has it.
8. ~~The steering fix~~: **approved** (DR-169, STEER_LA) with the store address on its base (STA_BASE); measured +2.25% and +5.03% over 17 programs, +7.84% together (§6.9).
9. **What §6.8 left open in the model:** partly done (§6.9). With the levers, CoreMark's ordering replays are gone in both simulators; the store-wait cancel and the drain's cycle are in revision 7. Still open: row clashes (1.5–3× under), ws_hash (+14%) and ws_copy (−13%), minver and edn.
10. ~~A memory-dependence predictor~~: **parked** (§6.10). Ordering replays cost 0.09% of the Linux boot's cycles, under the 0.5% bar.
11. **DTLB retries at the ROB head** (§6.10): 2.31% of the boot's first 20M cycles (as corrected by follow-up 13), about 16 cycles of commit stall per DTLB miss beyond the walk. Measure on the board's steady-state workloads before choosing between a retry from the LQ and a larger DTLB. Re-measured on main (§6.11): a retry from the LQ would save 1.62% (loads; stores 0.16%), and the walk at the head is another 2.3% of cycles.
12. **M6's remaining pieces, ranked on main** (§6.11): the ownership prefetch for stores (+4.2% of the boot), FENCE.I by generation (+1.7%) and the micro-BTB at 128 (+0.6%) lead per 1K LUTs; the DTLB retry from the LQ (+1.6%) and the I$ next-line prefetch with a second refill (+2.7%) also fit the room. Each wants a prototype with its measured LUTs before it merges. The L2 stream prefetcher, the model's best Linux-like buy, needs the board's steady state. DR-171 took the first two (fpu-2, core-2).
13. ~~"Commit held" in the boot~~: **done** (§6.11). The 4.3% was the bind's: it counted commits from the commit trace, a cycle late. Corrected, 0.5% of cycles have a complete head that retires nothing, all of it the registered cycle after a flush. There is no trace back-pressure (0 cycles) and no commit hold: no free gain.
14. **`tb_boot`'s tail after the initcalls against the board's** (§6.12, revised by §6.14; verif-2). Every initcall matches the board within 3.5%, but the tail runs a fixed ~95 ms (about 9.5M cycles) longer: 88 ms on d2, 97 on d4s2, 95 on d4r1.
    - **The tail holds:** the end of the initramfs unpacking (an async worker on one core), then `free_initmem`'s 11.2 MB memset.
    - **Not a timed wait:** no sample has both cores idle.
    - **Not DDR latency:** verif-2's finding. At latencies of 22, 18 and 14 cycles the tail stays 39%, 34% and 28% slower than the board, while the initcalls fall below it. The offset also did not shrink when the store prefetch hid the store misses' waits.
    - **By cause** (§6.14, `prof_m6.sv` with `+prof_snap`): the memset fetches one line at a time, about 60 cycles a line. The unpacking's end is a copy with up to two lines in flight. Both stream dirty lines, which the initcalls barely do.
    - **Next (verif-2):** `memcal`, bare-metal memset, memcpy and a streaming read, in the TB and on the board. It fits the DDR model's per-line costs to the board's, and one boot to /init confirms the fit.
    - **Until its cause is found,** predict the board from `tb_boot` by adding the simulated change in seconds (§6.14). That rule was within 1.4% on both steps so far; scaling by the simulated ratio was 2.6–5.3% high.
15. **d2's CoreMark under Linux on the board** (§6.12) runs 9–17% below its bare-metal RTL simulation. d4s2 runs 2–3% above its own, and d2's boot matches the board. The cause is unidentified: code placement and generation are ruled out. It matters only for reading the board's d2 → d4s2 CoreMark gain. **Open, parked** (the coordinator, 10-19): d2 is retired, and the gap does not touch M6's figures.
16. **The per-thread issue-queue caps and the static ROB, LQ and SQ halves are not wired** (§6.12). M7 must wire them, and decide what a lone thread gets: smt2_report.md §10's open items.

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

**2026-10-15: fn4, the L2's S2 restructure and the measured fill ceilings** (main 6dd8d96, DR-113's settings):
- **The cores:** `st` 42,045 and `smt2` 44,720 (fn4 at 028f45e), −335 per `smt2` core since fn2:
  - the LSU and MMU, −704 net: DR-139's PMP sharing, with the LSU's timing changes;
  - the FPU track's execute step 3 and P4 steps 4 to 6, −426;
  - the core track's other cycle-identical timing restructures (decode, the front end, the ROB and CSRs, rename), +795.
- **The uncore:** 18,903 at `smt2` (951c235), +300 for the S2 restructure. All in fabric it now misses 200 MHz by 0.74–0.91 ns, from 1.78.
- **v1 on each hart-1 basis:**
  - ≈116.7K on the budgets' basis;
  - ≈115.7K in RAM form with the PMP select (three checkers since DR-139: +1.7K per core);
  - ≈120.2K as copies.

  At main's head, the FPU's P4 steps 7 and 8 take up to ≈0.4K more (estimated).
- **The bars are now the fill test by clock** (plan §8.5), each the user's decision (DR-137). In RAM form v1 is 6.3K over 200 MHz's 109,407 (4.1K over 111,652, whose miss is on a harness path only), 0.5K over 180 and 170 MHz's ≈115.2K, and 0.6K under 150 MHz's 116,301. §7.7's history is restated against them.
- **DR-133's basis is gone** (rejected at gate 3).
- **Watch:** the SoC's per-site DSP check (cd1f584, not merged) puts the uncore at 19,664 (+761).

**2026-10-16: the DR-145 clocks, v1 as built** (§6.2; `scripts/clock_low.py`, run on the build host):
- **The model is calibrated to the RTL as built:** one L1D miss in flight, one I-cache refill at a time, and no prefetchers. Clocks: 94, 100, 125 and 150 MHz; NaxRiscv at 135 and 150 MHz; one thread, and four (two cores × SMT2).
- **As built, v1 loses to NaxRiscv on memory work at every clock.** It reaches 0.58–0.68× on memsuite, with NaxRiscv's two refill slots against its one. On the suite it is 0.86× at 100 MHz and 1.03× at 125 MHz, against NaxRiscv at 135 MHz.
- **Two or four L1D misses in flight are worth more than the clock.** With four, v1 is 1.13 / 1.04× NaxRiscv at 135 / 150 MHz on one thread's suite at 100 MHz, and 1.36 / 1.25× at 125 MHz. With four threads it is 1.51 / 1.40× and 1.82 / 1.68×.
- **The profiles move nothing measurable in the model.**
- **The model needed an anti-starvation rule for one MSHR with SMT2** (`drain_guard`). Without it, a sibling's misses starved a thread's store drain for good. How the RTL arbitrates its MSHR is a question for the core track.
- **New working-set kernels** (`bench/build_ws.sh`, DR-141's 0.5–4 MiB).
- **§6.1's bandwidth was optimistic** below 200 MHz.

**2026-10-17: tgsim calibrated to the RTL as built** (§6.3; `scripts/rtlcal.py`, `scripts/m6_steps.py`, run on the build host):
- **Why the hardware runs at half the model's IPC:** the model ran the plan's core. §6.2's "as built" changed only the memory side.
- **The new preset `rtl_m2`:**
  - M2's front end (the micro-BTB alone), recovery at commit, and wakeup on confirmed hits;
  - MUL-to-use 5, one L1D miss and one I$ refill;
  - calibrated on identical ELFs in tg_vsim and tgsim: the flush's extra cycle, wrong-path training at loop exits, a 13-cycle refill overhead, and the forwarding latencies.
- **Agreement:** 13 of 17 programs within 10% (CoreMark within 6%). The outliers are Dhrystone rv64gcb and statemate (the RTL's wrong-path training) and minver (FP; not found).
- **From the core as built, at 100 MHz (DR-152):**
  - TAGE-lite alone is worth +39% on the suite, the block BTB and FTQ +24%, checkpoints +15%, 4 misses in flight +24%;
  - stacked by gain per LUT the order is TAGE-lite, 4 misses in flight, the RAS, the block BTB and FTQ, 16 MSHRs, prefetchers, speculative wakeup, then checkpoints;
  - IPC per LUT runs out after the first three (1.5K LUTs, the suite +89%); the rest returns 16% per 1K LUTs or less;
  - the plan's whole M6 core is 2.5× the suite.
- **§6.2's lead over NaxRiscv at 100 MHz does not hold for the core as built:** 0.56× / 0.52× of NaxRiscv at 135 / 150 MHz with 4 misses in flight.

**2026-10-17: the first M6 stack checked against the RTL** (§6.4; `scripts/m6_rtlcheck.py`, `scripts/rtlprof/`, run on the build host):
- **The question:** core-2's stack (the RAS, TAGE-lite at F2, returns at F2) gained 25% on CoreMark and 49–64% on Dhrystone in RTL. The model said 42–58% and 101–104%.
- **Found in the RTL with measurement-only profile binds,** largest first:
  - a store's address issues only with its data, so younger loads to its address replay (Dhrystone twice per run);
  - the issue queues are banked by dispatch slot, and each row is held two cycles after its select (dispatch waited on a full bank in 26% of CoreMark's cycles);
  - TAGE-lite as built is per block, with branch-only history and the lookup a block behind, and mispredicts about twice as often as the model's.
- **With the three in the model,** the stack's scores are within 2–6% of the RTL, against 21–51% before.
- **`rtl_m2` revision 2** has them with four misses in flight (DR-156): main within 7.5% on average over 17 programs (8.6% before).
- **Two RTL questions for core-2,** in the model:
  - the store address issuing on its base alone, as core-lsu.md describes: the stack's Dhrystone +26–30% and CoreMark +3–6%;
  - rows freed at select while speculative wakeup is off: up to +5%.

**2026-10-18: what M6's remaining pieces buy per 1K LUTs** (§6.5; `scripts/m6_area.py`, run on the build host):
- **The base:** `rtl_m2` revision 3 adds main's speculative wakeup. With the RAS, it matches core-2's RAS head within 3% on CoreMark and 7.7% on average over 17 programs.
- **TAGE-lite's first table buys the most:** 1.9K LUTs per chip, −12.3% make perf cycles in RTL. The second table adds −3.6 points for 660 LUTs; the third and fourth add −0.8 points for 640.
  - The model's steps between sizes match the RTL.
  - Its first step is about 4.4 points optimistic on the bench.
- **The memory side:** 8 misses in flight and the L2 stream prefetcher come next, at +4.5% and +2.2% on the suite. Their LUTs are estimates.
- **Checkpoints:** +2% after TAGE-lite.
- **The I-side pieces:** nothing on the suite; Linux has to judge them.
- **Where IPC per LUT drops:** after about 2.7K LUTs per chip, every further 1K buys under 5%.

**2026-10-18: speculative wakeup's cancels, measured** (§6.6; fpu-2's RTL profile, `scripts/m6_swfit.py`, run on the build host):
- **What the RTL cancels on:** D$ row clashes (a store to the load's 16-byte block draining as it reads), wrong-path faults, and the store-data capture lagging. About 4 ops are killed per cancel.
- **`rtl_m2` revision 4** adds the row clash and fast forwards. The fit over 17 programs goes from 7.7% to 7.3%, and Dhrystone rv64im from −6.4% to −1.0%.
- **The TAGE-lite overshoot is not the cancels:** they are about 1% of CoreMark's cycles. The front end is next.
- **Dhrystone's two lengths have different code layouts,** so its steady state needs comparing binary by binary.

**2026-10-18: the front end of the TAGE-lite build, measured** (§6.7; `scripts/m6_fe.py`, `scripts/rtlprof/prof_f2cut.sv` on fpu-2's f2cut tree, run on the build host):
- **§6.4's extra F2 refetching was mostly the model's:** it fetched a straddling 32-bit instruction as a block of its own and trained it at slot 0 of the block before, and its micro-BTB wrote a block's second exit over its first. **`rtl_m2` revision 5** has the RTL's rules (`m2_strad`, `m2_ub_way`).
- **The F2 refetches cost little:** 1.6–1.8% of CoreMark's cycles, 3.7% of Dhrystone's and 2.9% of the Linux boot's. The instruction queue hides about three quarters of each 2-cycle bubble.
- **The boot's first 20M cycles lose 21% of cycles in the front end,** led by I$ misses (about 12%) and FENCE.I's 64-cycle I$ invalidate (1.7%).
- **No front-end change is worth making before M6 merges.** The store address waiting for its data (§6.4) is the backend lever this profile points at again.
- **The model's remaining optimism is in the backend:** rename holds decode in 17.7–22.2% of the RTL's cycles and 10.3–12.9% of the model's.

**2026-10-18: rename's stalls on the TAGE-lite build, measured** (§6.8; `scripts/m6_rs.py`, `scripts/rtlprof/prof_rs.sv` on fpu-2's f2cut tree, run on the build host):
- **Every held cycle is an issue queue's bank,** almost never the ROB, LQ, SQ or free lists.
- **The ALU queues: rename steers by flags a cycle old.** In 80–90% of the RTL's ALU-queue stalls on CoreMark the other ALU queue had a row for the op's slot: 10–12% of CoreMark's cycles. **`rtl_m2` revision 6** steers as the RTL does: CoreMark within 1.1%, and the 17 programs' mean error from 5.7% to 4.2%.
- **A fix for core-2:** rename counting the dispatch stage's group, about 15 LUTs per core. In the model: CoreMark +6%, Dhrystone +3%, +2.5% over 17 programs.
- **The store address on its base alone** (fpu-2's prototype), in the model: CoreMark +2–4%, Dhrystone +13–15%, matmult-int, minver and ud +12–29%, +5.7–6.2% over 17 programs. It explains little of the held-cycle gap: its gain is the ordering replays it removes.

**2026-10-18: DR-169's levers measured** (§6.9; fpu-2's `claude/track-fpu-395911-sta` at a857a07, `scripts/m6_lev.py`, `scripts/rtlprof/prof_sta.sv`, run on the build host):
- **fpu-2 measured +5.03% (STA_BASE), +2.25% (STEER_LA) and +7.84% (both) over 17 programs.** §6.8 had predicted +5.7%, +2.5% and +9.3%.
- **Dhrystone rv64im's +5% (against rv64gc's +18%) is one race per run:** Proc_4's first load overtakes Proc_5's store to the same byte, whose address op waits behind an older store that a speculative-wakeup cancel sent back.
- **`rtl_m2` revision 7:** the two levers, plus a cancel for a load waiting for a store's data and a cycle before a committed store drains. 17-program error 4.17%; the levers' means predicted within 0.15 points.

**2026-10-18: ordering replays in the Linux boot** (§6.10; `scripts/rtlprof/prof_rpl.sv` on a857a07, both levers, the boot's first 20M cycles):
- **The memory-dependence predictor is parked:** ordering replays cost 0.09% of the boot's cycles (1,158, from 35 load PCs, 97% repeats).
- **DTLB retries at the ROB head cost 2.45%** (29,608, about 17 cycles each): the larger Linux-side item, for the board to judge.

**2026-10-19: M6's remaining pieces re-ranked on main's M6 set** (§6.11; `scripts/m6_rank.py`, `scripts/rtlprof/prof_m6.sv` on main 31e65c6, the boot's first 20M cycles with the testbench's and the board's memory):
- **The boot's largest single stall is the store drain:** a store waits on its line 15.7–18.9% of cycles, and holds rename through a full SQ 9.6–12.7%. The D$'s four miss entries are almost never all busy.
- **By boot gain per 1K LUTs:** the ownership prefetch for stores (+4.2%, 400–600 LUTs a chip), FENCE.I by generation (+1.7%, 100–600) and the micro-BTB at 128 (+0.6%, 130–150). Then the DTLB retry from the LQ (+1.75%) and the I$ next-line prefetch with a second refill (+2.7%); all five fit the room.
- **Checkpoints** are the make perf pick (−1.7% cycles; +2.5% of the boot) at 2–3K LUTs. **More misses in flight** buy nothing in the boot.
- **Follow-up 13: the boot's 4.3% "commit held" was the bind's.** It read commits from the commit trace, which lags the ROB by a cycle. Corrected, 0.5% remain: the registered cycle after a flush. There is no trace back-pressure and no commit hold. §6.10's replay stalls shrink by a cycle each (DTLB retries 2.31%).

**2026-10-19: the model and the RTL against the board's first M6 Linux run** (§6.12; MR18's d4s2 against d2; `scripts/m6_board.py`; make perf on both trees in smt2 and st; `tb_boot` to /init as the board runs it, `scripts/rtlprof/brd_init.sh` and `brd_prof.sh`):
- **CoreMark:** `rtl_m2` revision 7, with the board's smt2 sizes (ROB 80, LQ 24, SQ 20), lands on the board's IPC exactly: 1.563 and 1.498. It is within 2.6% of the RTL.
- **Dhrystone's 8.5% gap is the program, not the core:**
  - the Linux set's static glibc build executes 13% more instructions per run (`strcpy` and `strcmp` through IFUNC stubs);
  - the comparison mixed the board's smt2 with st's simulation;
  - per instruction, the board runs at the RTL's IPC within 0.6%.
- **/init:** run as the board runs it, the RTL simulation tracks the board within 0.4–3.5% through every initcall. It runs the initramfs unpacking 25–39% slow (`tb_boot`'s DDR model): −26.2% against the board's −30.0% CPU time. The board's /init gain itself (−21.3%) includes 0.34 s of fixed serial console time.
- **DR-171's ranking:**
  - over the whole boot, the store ownership prefetch stays first (+6.2%, leaning high);
  - FENCE.I by generation falls to +0.3%: its FENCE.Is cluster in early boot;
  - the I$ next-line prefetch (+1.7%) leads the DTLB replay from the LQ (+0.3%) by more than before.

**2026-10-19: d4r1 predicted blind, then measured** (§6.13 before the board ran, §6.14 after MR23; `scripts/m6_board.py --init` and `--copy`, `scripts/rtlprof/brd_init.sh d4r1`):
- **Right:**
  - CoreMark A and B and Dhrystone unchanged (4.60, 4.36, 2.82 against 4.61, 4.36, 2.82 predicted);
  - the initcalls' CPU time within 1.9%;
  - the list of Linux tests the store prefetch moves.
- **Missed:** /init's CPU time, 0.491 s against a range of 0.51–0.57 s. The simulation itself was within 2.6%, and its saving in seconds within 1.2% (98.8 against 97.6 ms). The range discounted the tail's gain on §6.12's DDR diagnosis, and the board gained more there, not less.
- **The tail:** the end of the initramfs unpacking, then `free_initmem`'s 11.2 MB memset. `tb_boot` runs it a fixed ~95 ms longer than the board on all three bitstreams, so the DDR diagnosis is withdrawn (follow-up 14).
- **The store prefetch:** −15.9% of the simulated boot's cycles against an estimate of +6.2%. It removed most of the store-drain stall, where the estimate assumed a third. The model's `rfo_pf` on the board's 1 MiB copy gives −30.8% against the board's −34.5%.

**Lessons:**
- **A hedge is a prediction too.** The simulation's number was within 2.6% of the board; the range built around an untested diagnosis missed it by 4%.
- **Check a gap's shape across versions before naming its cause.** A fixed offset over three cores rules out latency; read as a ratio it looked like a slow DDR.
- **Take an estimate's factor from a kernel with the target's miss mix.** A copy realizes 0.36–0.50 of the store-drain stall in the model, and the boot's page clears most of it.
- **Time an event where the hardware decides it, not from a registered report of it.** The commit trace lags retirement by a cycle. A cycle-by-cycle stack built from it invented a 4.3% "commit held" class, and each replay's stall came out a cycle long.
- **Count the same window in both simulators.** The model charged a flush's refill from the commit, the RTL from its flush two cycles later: 4 slots per flush that looked like a slower front end.
- **Check each ISA's own cases.** The straddler gap showed only on rv64gc, where a 32-bit instruction can cross a 16-byte block; rv64im matched.
- **A fix can widen the whole-program error.** Revision 5's front end is the RTL's, and the TAGE-lite build's error went from −3.5% to −5.6% on CoreMark A, because the old front end had been hiding a backend that is too fast. Keep the rule that is right and find the next gap; do not keep an error that cancels another.
- **Ask "was there room elsewhere?" at every stall.** One counter, the other ALU queue's bank having a row while dispatch waited, found 10–12% of CoreMark's cycles lost to a steering decision.
- **Check when a decision is made, not only what it decides.** Rename's queue choice is right with the flags it has, but they are a cycle old.
- **When two binaries of one program disagree, trace the pair that differs.** Dhrystone rv64im's missing gain was one store–load race per run, visible only by following those two PCs through dispatch and issue.
- **A rule's cost can hide until another change makes it common.** The store-wait cancel cost nothing measurable until STA_BASE made loads find store addresses before their data.
- **Check that two binaries share a layout before differencing them.** Dhrystone's lengths do not, and the RAS head's speed moves 5% with the layout.
- **A front-end gain is only as large as the backend lets it be.** The base fit was within 6% on CoreMark, but the backend rules it missed only bind once the front end improves. Check a step's gain in RTL against the model before ranking the next steps on it.
- **Read the RTL's dependency rules, not only its spec.** The spec's STA is address-only; rename makes it wait for its data.
- **Profile both simulators over the same window.** A whole run of Dhrystone is half printf, where the model is slower; difference two run lengths so start-up and printf cancel.
- **Ask which consumers actually wait on a structure before sizing it.** The census turned a 4–5K "overrun" into an exact redesign. The same question asked of the window, the queues and the checkpoints only found IPC.
- **A fit is only as good as its per-unit inputs.** The first projections used planning estimates for every unit but the scheduler and the FPU. The first real synthesis was 88K at `st` against 38.2K, so the levers this study ranked were a small part of the real gap (§7).
- **Free in the model is not the same as free under D18.** R9 and R10 cost ≈0% IPC but share or reduce function, and the user puts those last.
- **The projection hid a 50K gap.** The planning fit put v1 at 92–104K, but the measured RTL is ≈155.7K. Lever studies rank the last few percent; the per-unit budget report, built from the real RTL, is what tells whether a design fits.
- **Check which commit a synthesis report comes from before using it.** A same-named run on another track's branch can predate a merge.
- **Re-cost an estimate once its form is chosen.** Hart 1's 4.2K assumed second copies and is now as large as the core's measured excess. With conventions §7's RAM forms the rest of it is ≈2.1K, but the PMP select adds 2.3K to either form.
- **Price the selects, not just the storage.** A per-thread table in RAM costs its storage. Per-thread state read in parallel costs a select at every reader. The PMP descriptors' four selects (+2.3K) outweigh every table in hart 1.
- **Mark the synthesis settings with every figure.** The third pass measured 51,839 at `smt2` with the old settings and 49,022 with DR-113's. Mixing the two misstates v1 by 5.6K.
- **A unit run's saving is an upper bound in the core.** P4's steps since fn2 saved 241 LUTs in their unit runs and 86 in the core.
- **Calibrate the model to the RTL as built before comparing designs.** With the plan's L1D (16 MSHRs, prefetchers) the model put v1 at 1.78× NaxRiscv at 150 MHz on the suite. As built, with one miss in flight, it is 1.18×, and it loses on memory work.
- **A one-sided clock skew in a model can starve a requester for good.** Loads booked the one MSHR three cycles ahead of the store drain. Any shared resource with requesters at different pipeline times needs a fairness rule in the model, and the same question goes to the RTL.
- **Run compute only on the build host.** The study's first runs used the laptop's WSL, because the checkout was there. The laptop only edits and commits.
- **"As built" means every structure, not the one under study.** §6.2 calibrated the memory side and inherited the plan's front end, so its comparison with NaxRiscv was 2× too kind. Calibrate against the RTL's own cycles on identical binaries before any comparison.
- **The commit trace says where a model is wrong.** Counting refill gaps per branch in tg_vsim's trace, against the model's mispredicts per PC, found the flush cycle, the wrong-path training and the always-taken branch the RTL mispredicts. A whole-program error alone could not.
