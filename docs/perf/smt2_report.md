# Tanager SMT2 study

*What two-thread SMT gives Tanager, what an SMT2 core needs to be sized at, and how SMT2 and the committed 3-wide decode should be ordered and combined (plan §6.4, D14).*

| | |
|---|---|
| Status | Study for review: input to plan §6.4 (the order and combination of SMT2 and 3-wide) and to the feature ledger |
| Date | 2026-10-13 |
| Model | `tgsim` model version 3 with SMT2 (`threads=2`, `SMT_VERSION` 1); suite revision 2; rv64gc binaries built with GCC 15.2. See [`perfmodel/README.md`](../../perfmodel/README.md). |
| Baseline | The approved v1 freeze ([feature_ledger.md](feature_ledger.md)), preset `v1_freeze` |
| Plan | [architecture_plan.md](../architecture_plan.md) draft 0.4: §6 (SMT), §4.15 (3-wide reserve), D11, D13, D14 |
| Generated data | [smt2_tables.md](smt2_tables.md), with per-pair results and every greedy round; `perfmodel/results/smt2_rv64gc.json` |

Every number here is a model result, not a measurement. LUT costs are estimates, as in M1, until synthesis replaces them.

**Naming (plan draft 0.4, D16).** This report predates the renaming:
- its "v1" and "v1 freeze" are the single-thread bring-up configuration **ST**;
- its "v2" (the 2-wide SMT2 core) is the **first release, v1**;
- its 3-wide SMT2 core is **v2**.

**Decisions taken on this study (2026-10-13; plan draft 0.4, D14, D15 and D16).**
- **Adopted:** the 2-wide column of §1.2 (ROB 80, LQ 24, SQ 20, 24 LLTs, 75% issue-queue caps) as the **first release**.
- **Then:** 3-wide added to the SMT2 core as the next release, all on the KV260.
- **What this overrides:** where this report says the combined core needs a larger device, the project owner decided otherwise. The plan's area-recovery plan (§8.5) is how v3 is to fit the XCK26.

---

## 1. Summary

### 1.1 Findings

1. **SMT2 adds a third to the v1 core's throughput, with no size change.**
   - **Measured:** two programs on the v1 freeze reach a weighted speedup of **1.30 / 1.33 / 1.34** at 30 / 120 / 250 cycles of DRAM latency. The plan's planning estimate was +20–40% (§6.1).
   - **Cost:** the SMT2 logic is estimated at **6.4K LUTs per core** (range 4.3–8.8K, i.e. 10–21%; §8.3), and 6.75K on a 3-wide core.
   - **Acceptance rule:** it passes by a factor of about 2, at +33% throughput for 15.6% of the LUTs.
2. **Who benefits.**
   - **Memory-bound threads gain the most.** Alone they use only 4–27% of the decode slots, and SMT2 fills the rest: memory + memory pairs reach 1.43, mixed pairs 1.44.
   - **Compute pairs barely gain on the 2-wide core.** The 2-wide decoder pins their combined IPC at 2.00, so they reach only 1.15.
   - So SMT2 helps most where Tanager is slow (memory-latency-bound work) and little for CoreMark or Dhrystone (CoreMark + CoreMark: +11%).
3. **SMT2 makes the window binding, and the acceptance rule grows it.**
   - **What binds:** each thread's half of the v1 window (ROB 24, LQ 8, SQ 6) and the 16 shared long-latency tags.
   - **The rule's answer:** applied to SMT2 throughput, with whole-window steps allowed (§8.2), it grows the ROB to 80, the LQ to 24, the SQ to 20 and the long-latency tags to 24. That is +1.9K LUTs per core.
   - **The result:** weighted speedup **1.36 / 1.43 / 1.45**, +7% over SMT2 at v1 sizes. One thread alone also gains 2.5%, because it gets the whole larger window.
   - **What stays at v1 sizes:** the issue queues, the completion buffer, the 16 L1D MSHRs and the 48 L2 MSHRs. Once the window has grown, no step of theirs passes the rule.
4. **Partitioning and fetch: the plan's SMT2 line holds, with one condition.**
   - **What works:** static ROB/LSQ halves, ICOUNT fetch (+0.5% over round robin), and alternating rename and commit with shared slots.
   - **The condition:** caps on the shared issue queues (75% per thread) are a precondition for any window sharing. Without them, a sharing thread clogs the queues.
   - **Shared window:** with the caps in place, a shared window with a 75% per-thread cap would add a further 2.7%. It needs age-ordered ROB and LSQ logic that static halves avoid; it is an option for later (§5).
5. **At 2-wide decode, SMT2 doesn't change M1's verdicts on execution width.** A second load pipe, a second FMA pipe or a third ALU each still add 0–2% (§7).
6. **SMT2 and 3-wide decode are complements, so their order is the question (§9).**
   - **Each makes the other worth more:**
     - 3-wide adds 11% throughput to a single-thread core, but 22% to the sized SMT2 core;
     - SMT2 adds 43% to the 2-wide core, but 57% to the 3-wide core;
     - at the same (v1) sizes, the combined core is 4.7% above the product of the two alone (1.552 against 1.335 × 1.111).
   - **The combined core, sized by the same rule (plan §6.2 rule 12):** ROB 96, LQ 32, SQ 20, completion buffer 16 and 24 long-latency tags.
     - Weighted speedup: **1.67 / 1.74 / 1.75**.
     - Single thread: +18% (CoreMark 6.11/MHz, DMIPS 4.99).
     - Cost: ≈19.5K LUTs per core.
   - **Throughput per LUT,** in points of throughput per percent of the core's LUTs:

     | Core | Throughput per LUT % |
     |---|---|
     | SMT2 on the 2-wide core | 2.1 |
     | 3-wide alone | 0.46 |
     | the combined core | 1.56 |
7. **The data favours SMT2 first.** All three orders end at the same combined core; they differ in what the next version delivers and whether it fits:

   | Order | Next version: share of the combined core's throughput gain | Share of its LUTs | Share of its single-thread gain | Dual-core LUTs (XCK26 share) |
   |---|---|---|---|---|
   | **SMT2 first** | **58%** | 42% | 14% | ≈106K (90%) |
   | 3-wide first | 15% | 51% | 74% (CoreMark 6.11, the 3-wide version's target) | ≈109K (93%) |
   | Both at once | 100% | 100% | 100% | ≈128K: needs a larger device |

   - **SMT2 first** gives the most throughput for the least logic, fits the XCK26, and makes the later 3-wide step worth more: +22% throughput and +15% single thread.
   - **3-wide first** is the choice only if single-thread speed must come first.
   - **Both at once** is the efficient end point if the next version moves to a larger device anyway.

### 1.2 Proposed SMT2 cores

| Structure | v1 freeze | **SMT2, 2-wide (next step)** | SMT2, 3-wide (plan rule 12; later, larger device) |
|---|---|---|---|
| Hardware threads | 1 (`TID_W` = 0) | **2** (`TID_W` = 1); 2 cores × 2 harts = 4 Linux CPUs | 2 |
| Decode / rename / commit; ALUs | 2-wide; 2 | 2-wide; 2 | 3-wide; 3 |
| ROB | 48 | **80**, static halves of 40 | 96, halves of 48 |
| LQ CAM / completion buffer | 16 / 8 | **24** / 8, halves of 12 / 4 | 32 / 16, halves of 16 / 8 |
| SQ | 12 | **20**, halves of 10 | 20, halves of 10 |
| Long-latency tags | 16 | **24**, shared | 24, shared |
| Issue queues A0 / A1 (/ A2) / LD / STA / FP | 10 / 10 / 6 / 4 / 10 | unchanged, shared; **each thread ≤ 75% of each queue** | unchanged (A2 10); ≤ 75% per thread |
| Checkpoints | 4 | 4 per thread | 4 per thread |
| L1D / L2 MSHRs; physical registers | 16 / 48; 3 × 64 integer, 2 × 64 FP | unchanged, shared; never binding | unchanged, shared; never binding |
| Fetch | — | **ICOUNT**, one thread per cycle | ICOUNT |
| Decode, rename, commit order | — | the thread served first alternates; a thread uses the slots its sibling leaves idle | same |
| Predictors | — | shared tables with the TID hashed in; history, RAS and FTQ per thread | same |
| **Estimated cost per core** | | **+8.3K LUTs** (+1.9K sizes, +6.4K SMT2 logic; range +6.2K to +10.7K) | +19.5K (+10K 3-wide, +6.75K SMT2, +2.7K sizes) |
| WS_ref at 30 / 120 / 250 | 1.00 | **1.36 / 1.43 / 1.45** | 1.67 / 1.74 / 1.75 |
| Single-thread suite IPC @120 | 0.967 | +2.5% | +18.0% |

### 1.3 Decisions for you

| # | Decision | Recommendation |
|---|---|---|
| V2-1 | Order of SMT2 and 3-wide (plan §6.4, D14) | **SMT2 first** while the KV260 is the platform. Then add 3-wide to the SMT2 core when moving to a larger device. If the next version moves to a larger device anyway, build both at once (the rule-12 core of §1.2). Choose 3-wide first only if single-thread speed must come first. |
| V2-2 | Sizes | **The 2-wide SMT2 column of §1.2** for the next step (ROB 80, LQ 24, SQ 20, 24 long-latency tags). The 3-wide column is the rule-12 sizing to carry into the 3-wide version's own freeze (§4.15). |
| V2-3 | Partitioning | **Static halves plus 75% issue-queue caps**, as plan §6.4 says. A shared ROB/LSQ with 75% caps (+2.7%) is an option for later, to be judged on RTL cost. |
| V2-4 | SoC fit: the dual-core 2-wide SMT2 is ≈106K LUTs (90%), against the plan's ≈80% goal; the combined core does not fit | Accept it as a risk of the SMT2 version. Replace the estimate with the `TID_W = 1` synthesis already planned at M6 (§6.3), and keep the trims of §10 ready. |
| V2-5 | Fold the results into plan §6.4 and the feature ledger | Proposed text in §10 |

---

## 2. Method

### 2.1 What the model adds

`tgsim` gains a `threads` parameter. With `threads=2`, two programs run at once, one per hardware thread, each on its own functional simulator. What is per thread and what is shared follows plan §6.2 (rules 1–11) and the v2 line of §6.4 ("static ROB/LSQ partitions, capped shared queues, ICOUNT-style fetch, shared tagged TLBs and caches").

| Per thread | Shared |
|---|---|
| Program, functional simulator and instruction stream | Fetch: one thread per cycle (one 16 B I$ access) |
| Fetch state, instruction queue (16), FTQ-directed prefetch | Decode, rename/dispatch and commit slots (2 each) |
| Global history and RAS | Issue queues, kept in dispatch order across threads, with a per-thread cap |
| Rename map; 4 checkpoints | Physical register banks; they hold both threads' committed registers |
| ROB, LQ, SQ and completion-buffer share | Long-latency tags; every execution unit, including the Goldschmidt divider and the FMA |
| Commit order; in-order store drain | L1I, L1D, L2, MSHRs, prefetchers, DRAM bandwidth |
| Flushes and redirects, which touch only the thread's own uops | Predictor tables (BTB, micro-BTB, TAGE, hit predictor), with the thread ID hashed into their index and tag |

**Front end.**
- **Fetch:** one thread fetches per cycle. A thread that is waiting for an I$ miss, a taken-branch bubble or a branch resolution leaves the slot to its sibling.
- **ICOUNT** (the default) gives the slot to the thread with fewer uops in the instruction queue, the decode-to-rename stages and the issue queues. Round robin is the alternative.
- **Decoupling:** each thread has its own instruction queue and its own 6-uop queue between decode and rename. A thread stalled at rename therefore does not block its sibling's decode (rule 9).

**Decode, rename and commit.**
- **Slots:** 2 per cycle, shared.
- **Order:** the thread served first alternates every cycle. Slots that thread cannot use go to the other thread in the same cycle (`smt_mix`).
- **Why ICOUNT stops at fetch:** applied at rename, ICOUNT starves the thread whose uops are waiting (§3.3).

**Window.**
- **Static halves** (the default): ROB, LQ, SQ and completion buffer. The alternative is a shared pool with a per-thread cap.
- **Single-thread mode:** a configuration run with `threads=1` gives its one thread every entry. This is the "alone" reference.

**Memory.**
- **Address spaces:** the programs run in separate address spaces. Thread 1's physical addresses are offset, so the threads never share a line, and two copies of one program do not alias set for set in the L2.
- **Store port:** one D$ store port drains both threads' committed stores. The thread tried first alternates.

**Recovery.**
- A flush touches only its own thread's uops. Early-retired operations are never cancelled (rule 11).
- The speculative-wakeup shadow cancel is not selective (plan §4.6 cancels whatever issued in the shadow, on all ports), so one thread's wrong hit guess also cancels its sibling's issues.

### 2.2 How a pair is measured

A thread's IPC is taken over the marked region of its program's **first run**, the same region the M1 single-thread results use. The two regions have different lengths, so:
- **Restarts:** a program that finishes while the other thread's first run is still going is restarted, with a fresh functional simulator; its caches, predictors and in-flight IDs carry on.
- **Coverage:** both threads are therefore loaded for the whole of both measured regions.
- **End:** the run ends when both first runs are complete.

Memory kernels start their regions at cycle 0 (fast-forwarded set-up). The other programs start theirs after their own start-up code.

Every pair run is checked for functional correctness on both threads, exactly as single-thread runs are:
- CoreMark CRCs;
- Dhrystone output;
- exit codes.

### 2.3 Thread pairs

The pairs cover all 13 required programs:
- **compute:** CoreMark (flag set A), Dhrystone, and four Embench programs:
  - nsichneu (large, branchy state machine);
  - huffbench (branchy, data-dependent);
  - minver (FP, divide-heavy);
  - matmult-int (multiply-heavy, IPC 2.0 alone).
- **memory:** gather, stride, spmv, hashprobe, chase8, stream and copy.

| Group | Pairs | Construction |
|---|---|---|
| memory + memory | 15 | each kernel with its next and second-next neighbour in the list (every kernel appears four times), plus chase8 + chase8 |
| compute + compute | 13 | the same construction over the six compute programs, plus CoreMark + CoreMark |
| mixed | 14 | each memory kernel with two compute programs (each compute program appears two or three times) |

The full list, with per-pair results, is in [smt2_tables.md](smt2_tables.md).

### 2.4 Metrics

For a pair on configuration C at one DRAM latency:

| Metric | Definition |
|---|---|
| Throughput | IPC₀ + IPC₁ (the two threads' IPC over their regions) |
| Per-thread speedup | IPCᵢ / IPCᵢ,alone(C), where alone(C) is the same program on C with `threads=1` |
| **WS** (weighted speedup) | the sum of the two per-thread speedups. WS = 1 means SMT2 is no better than running the two programs one after the other on the same core. |
| **WS_ref** | the same, with every IPC_alone taken on the **v1 freeze**: throughput normalised to the v1 core running one program at a time. It compares configurations, and it is the figure the v2 sizing pass uses. |
| Fairness | harmonic mean of the two per-thread speedups (Luo et al.): 1.0 for two unimpeded threads, 0.5 when both run at half speed |

- **Aggregation:** like M1's suite IPC, each figure is the geometric mean of the three group geometric means.
- **WS and WS_ref:** they coincide on the v1 freeze sizes. They differ where a configuration also changes single-thread performance.

### 2.5 Configurations and cost basis

**Starting point.**
- **Configuration:** the approved v1 freeze (preset `v1_freeze`), with `threads=2`.
- **Partitions:** each thread then has a 24-entry ROB, an 8-entry LQ, a 6-entry SQ and a 4-entry completion buffer.
- **Shared structures:** issue queues 10/10/6/4/10, 16 long-latency tags, 16 L1D MSHRs and 48 L2 MSHRs.

**LUT costs.**
- **Per-entry costs:** as `scripts/report.py` and the M1 greedy pass:

  | Structure | LUTs per entry |
  |---|---|
  | ROB | 30 |
  | issue queue | 80 |
  | LQ | 40 |
  | SQ | 50 |
  | completion buffer | 8 |
  | L1D MSHR | 75 |
  | long-latency tag | 25 |
  | L2 MSHR | 50 (SoC) |

- **M1 options:**

  | Option | LUTs |
  |---|---|
  | second load pipe | 1.5K |
  | second FMA pipe | 4.4K |
  | third ALU at 2-wide decode | 4.5K |
  | 3-wide decode/rename/commit with a third ALU | 10K |

- **Bases:** the core is ≈41K LUTs and the SoC ≈94K. The rule-of-thumb shares in this report use the same bases as M1.
- **Against plan draft 0.4's estimates** (core ≈37.7K, dual-core SoC ≈89K, §8.2), every LUT share here is 9% larger. Every step chosen for the 2-wide SMT2 core still passes. Of the 3-wide pass's steps, only the last (LQ 24 → 32: +0.81% against 0.85%) would not.
- **The SMT2 overhead itself** is estimated item by item in §8.3.

---

## 3. Validation

### 3.1 Single-thread results are unchanged

`threads=1` (the default) must reproduce M1 bit for bit. Three checks show it does, so `MODEL_VERSION` stays 3 and the M1 cache in `results/dse/` remains valid.

| Check | What it compares | Result |
|---|---|---|
| A/B against the M1 binary | Full JSON output, minus the parameter list (which gained the new keys), of 9 runs on `v1_freeze`, `tanager_v1` and `nax` at 30, 120 and 250 cycles | identical |
| `scripts/recheck.py rv64gc 4` | `tanager_v1` and `nax` at 120 and 30 cycles: every suite workload, every region statistic, against the cache | 132 runs, **0 differ** |
| `scripts/recheck.py --freeze` (new) | `--preset v1_freeze` at 30, 120 and 250 cycles: every suite workload against the cached M1 freeze runs | 99 runs, **0 differ** |

### 3.2 SMT2 consistency checks

(`scripts/smt.py --validate`, 120 cycles, base SMT2 configuration)

| Check | Expectation | Result |
|---|---|---|
| **Near-idle sibling.** A program paired with `tests/idle.c` (uncached MMIO loads, about 0.23 IPC; issue queues uncapped), against the same program alone with half the ROB, LQ, SQ and completion buffer | equal, apart from the slots the sibling uses | gather 0.995, stride 0.998, spmv 0.999, chase8 1.000. Front-end-bound programs lose the slots the sibling takes: copy 0.967, CoreMark 0.934, huffbench 0.922. |
| **Shared window capped at 50%** against static halves | identical limits through a different code path, so identical results | identical on every pair |
| **Thread order:** five pairs as (A, B) and as (B, A) | the same | WS_ref within 0.05% (gather + CoreMark 1.6062 / 1.6057; chase8 + stream 1.9404 / 1.9403) |
| **Overlap window:** IPC while both first-run regions are open, against IPC over each thread's own region | close | mean difference 0.36% over 84 threads. WS_ref 1.3416 by regions against 1.3372 by overlap windows (geometric mean over pairs). |
| **Functional correctness** of both threads in every pair run (CoreMark CRCs, Dhrystone output, exit codes) | all pass | all pass |

**One measurement effect: regions need not coincide.**
- **The restart method reads 0.3% higher** than the overlap window, because a thread's region can overlap its sibling's start-up code or restart gaps.
- **Largest single case:** huffbench in huffbench + minver (7.9%). minver restarts five times inside huffbench's region, and huffbench takes more slots while minver starts up.
- **The same effect** lets a pair's summed IPC exceed the decode width slightly (2.06 at most, the same pair). Every other pair stays at or below 2.013.
- It shifts absolute values by about 0.3%. Comparisons between configurations, which all use the same pairs and the same method, are affected less.

### 3.3 Model fixes made during the study

Two problems surfaced in the first SMT2 runs. Both are fixed, and neither affects single-thread runs.

1. **ICOUNT at rename starves a thread.**
   - **What happened:** the first version ordered rename by ICOUNT as well as fetch. A thread whose uops were waiting at rename (in gather + stream, gather's) always had the higher count, so its sibling took both rename slots every cycle. Waiting only raised its count further, and it never dispatched again.
   - **Fix:** ICOUNT now applies only to fetch, where it corrects itself (fetching raises the fetching thread's count). Decode, rename and commit alternate.
2. **A store whose line was evicted never drained.**
   - **What happened:** the store-drain model requests the line once, then waits for it to be present. With SMT, the sibling's misses can evict that line before the store drains, and the store then waited forever.
   - **Fix:** with `threads=2`, a store whose line is gone asks again.
   - **Single thread:** the case never occurs. Instrumented runs of the whole suite on `tanager_v1` and `v1_freeze` at 30, 120 and 250 cycles found no instance. Single-thread runs therefore keep M1's code path.
   - **For the LSU spec:** the RTL store drain must handle the same case. A line granted for a committed store can be evicted before the store writes it.

---

## 4. SMT2 on the v1 freeze

**Configuration.** The approved v1 freeze, run with `threads=2`:
- **Window per thread:** a 24-entry ROB, 8-entry LQ, 6-entry SQ and 4-entry completion buffer.
- **Policies:** ICOUNT fetch; each issue queue capped at 75% per thread.

On these sizes WS and WS_ref coincide.

| DRAM latency | WS, all pairs | memory + memory | compute + compute | mixed | Fairness | Summed IPC (mean over pairs) |
|---|---|---|---|---|---|---|
| 30 cycles | 1.297 | 1.377 | 1.148 | 1.380 | 0.632 | 1.697 |
| 120 | **1.335** | 1.433 | 1.149 | 1.444 | 0.647 | 1.550 |
| 250 | 1.343 | 1.446 | 1.150 | 1.456 | 0.650 | 1.503 |

**What the numbers say.**

1. **SMT2 adds 30–34% throughput with no size change.** That is inside the plan's +20–40% planning range (§6.1). The gain grows slightly with latency, because there are more stalled cycles for the sibling to fill.
2. **Compute pairs are pinned by the 2-wide decoder.**
   - The two threads' IPC sums to 2.00 in every compute pair.
   - A pair gains only what its programs leave unused of the decoder when they run alone. Single-thread decode-slot use at 120 cycles:

     | Program | Decode-slot use |
     |---|---|
     | Dhrystone | 100% |
     | matmult | 99% |
     | minver | 96% |
     | CoreMark | 90% |
     | huffbench | 86% |
     | nsichneu | 61% |

   - So matmult + Dhrystone gains 0.3%, CoreMark + CoreMark 11%, and the pairs with nsichneu up to 40%. Seven of the 13 compute pairs gain under 10%.
3. **Memory pairs range from 0.91 (copy + stride) to 1.94 (hashprobe + chase8, chase8 + stream).** Each thread's half of the window is the limit:

   | Thread | Stalls at dispatch on | Share of cycles |
   |---|---|---|
   | gather, stride, spmv | their 24-entry ROB half | 57–88% |
   | chase8 | its 8-entry LQ half (eight chains need eight loads in flight plus their successors) | 49–95%, depending on the sibling |
   | copy | its 6-entry SQ half | 52% |
   | chase8 + chase8 | the 16 shared long-latency tags | 83–89% |

   Copy + stride loses throughput outright (WS 0.91), because both programs need the whole window.
4. **Mixed pairs:** the memory thread keeps 63% of its single-thread speed and the compute thread 80% (geometric means, 120 cycles).
5. **Fairness is 0.63–0.65:** on average each thread runs at about two thirds of its speed alone.
6. **Memory-bound threads leave the decoder idle, which is where SMT2 earns its gain.** Alone at 120 cycles they use only a small share of the decode slots:

   | Kernel | Decode-slot use |
   |---|---|
   | gather | 15% |
   | stride | 27% |
   | spmv | 18% |
   | hashprobe | 9% |
   | chase8 | 4% |

   - **The memory+memory and mixed groups** carry SMT2's gain.
   - **Stream and copy** are not latency-bound here: they use 100% and 78% of the decode slots, because the prefetchers cover them. They behave like compute programs.

## 5. Partitioning, fetch policy and caps

**Change in WS_ref against the SMT2 base** (v1 sizes; every other setting as the base):

| Change | 30 cycles | 120 | 250 |
|---|---|---|---|
| Round-robin fetch instead of ICOUNT | −0.76% | −0.57% | −0.42% |
| One thread per decode, rename and commit cycle (no slot sharing) | −0.86% | −0.42% | −0.27% |
| Predictor entries shared by PC (no TID hashing) | −0.22% | −0.07% | −0.01% |
| Issue queues not capped | −0.18% | −0.05% | −0.02% |
| Issue queues capped at 50% | −1.68% | −1.82% | −1.93% |
| L1D MSHRs capped at 75% per thread | 0 | 0 | 0 |
| Long-latency tags capped at 75% per thread | 0 | 0 | 0 |
| Shared ROB/LQ/SQ/CB, 50% cap per thread | identical to static halves, pair for pair | | |
| **Shared ROB/LQ/SQ/CB, 75% cap per thread** | **+2.96%** | **+3.65%** | **+3.91%** |
| Shared ROB/LQ/SQ/CB, no cap | +3.05% | +1.55% | +1.17% |

**Fetch policy.**
- ICOUNT beats round robin at every latency, by 0.4–0.8%.
- The gain is in the compute and mixed groups: ICOUNT keeps feeding the thread that is draining its queues.
- ICOUNT cannot be applied at rename (§3.3).

**Caps.**
- A 75% issue-queue cap is neutral on its own. A 50% cap hurts, because a thread can then never use more than half of a 6-entry load queue.
- MSHR and long-latency-tag caps never bind at these sizes: each thread's LQ and completion-buffer halves already bound its misses.

**Static halves against a shared window.**
- **Plan §6.4** specifies static ROB/LSQ partitions. The model says a shared window with a 75% per-thread cap is worth +3–4% throughput: a memory thread borrows ROB, LQ and SQ entries that its compute sibling does not need.
- **It depends on the issue-queue cap.** WS_ref at 120 cycles, v1 sizes:

  | Window | Issue queues capped at 50% | 75% | not capped |
  |---|---|---|---|
  | Static halves | 1.310 | **1.335** | 1.334 |
  | Shared, 75% cap per thread | 1.363 | **1.383** | 1.311 |
  | Shared, no cap | 1.353 | 1.355 | 1.249 |

  - With uncapped queues, a shared window loses: −1.7% with the 75% cap and −6.4% with no cap.
  - The reason: a thread waiting on misses fills the shared ROB and the queues with its dependants, and its sibling starves.
- **It costs more than the model charges:**
  - a thread's entries are no longer contiguous, so the ROB needs per-thread linked order or age tracking;
  - the LQ and SQ need age matrices for forwarding and ordering instead of the per-thread pointer comparison of rule 3.
  - Neither cost is in the LUT estimates.
- **The same throughput is available more simply** by growing the static halves (§8).
- **Recommendation:**
  - keep static halves, as the plan says;
  - make the issue-queue caps (75%) mandatory;
  - treat a shared window as a v2.x option to revisit with RTL cost data. At the proposed v2 sizes it still adds +2.7% (§8.4).

**Slot sharing and TID hashing.**
- Letting a thread use the decode, rename and commit slots its sibling leaves idle is worth 0.3–0.9%.
- Hashing the TID into the predictor tables costs nothing here (−0.07% without it). It is required anyway for Spectre-v2-style isolation (rule 6).

## 6. Window and miss-handling sizes under SMT2

**Change in WS_ref against the SMT2 base**, with single-thread suite IPC (the same sizes, one program) for comparison:

| Change (total entries) | Est. LUTs | 30 | 120 | 250 | Single thread @120 |
|---|---|---|---|---|---|
| ROB 48 → 64 | 480 | +1.24% | +1.19% | +1.15% | +0.50% |
| ROB 48 → 96 | 1,440 | +1.96% | +2.97% | +3.43% | +0.56% |
| SQ 12 → 16 | 200 | +0.75% | +0.98% | +0.99% | +0.46% |
| SQ 12 → 24 | 600 | +0.96% | +1.30% | +1.38% | +0.46% |
| LQ 16 → 24, or → 32 | 320, 640 | −0.14% | −0.20% | −0.27% | +0.04% |
| Completion buffer 8 → 16 | 64 | −0.56% | −0.25% | −0.29% | 0.00% |
| Long-latency tags 16 → 24, or → 32 | 200, 400 | −0.03% | +0.59% | +0.62% | +0.02% |
| L1D MSHRs 16 → 24, or → 32 | 600, 1,200 | 0.00% | 0.00% | 0.00% | 0.00% |
| L2 MSHRs 48 → 64 | 800 (SoC) | 0.00% | 0.00% | 0.00% | 0.00% |
| Doubled window: ROB 96, LQ 32, SQ 24, CB 16 | 2,744 | +5.29% | +7.29% | +7.95% | +3.05% |
| … plus 32 L1D MSHRs and 32 long-latency tags | 4,344 | +5.96% | +9.36% | +9.61% | +3.25% |

**What SMT2 makes binding.**
- **The ROB and SQ halves.** One ROB step is worth 1.2% under SMT2, about 2.5 times its single-thread value. It still lands on the acceptance line (1.17% of the LUTs).
- **The shared long-latency tags.** Two threads keep more long operations in flight than one.

**What does not help on its own.**
- **A larger LQ or completion buffer slightly hurts.** More loads in flight hold more of the 16 shared long-latency tags, so the sibling stalls for tags. With 24 tags the same growth pays: the greedy pass takes the completion buffer right after the tags (§8.1).
- **MSHRs never bind.** 16 L1D and 48 L2 MSHRs suffice: each thread's LQ and completion-buffer halves cap its misses below them.
  - The ledger expected miss handling to grow for SMT2 (its re-evaluation triggers). That does not hold at these window sizes.
  - Even at the proposed v2 sizes, four more L1D MSHRs are worth +0.27% for 0.73% of the LUTs (§8.2, round 5).

**The window must still be sized as a whole.**
- Doubling every window structure is worth 7.3% at 120 cycles, against 6.7% of the LUTs, so it passes the rule as a bundle.
- Its single steps do not: ROB +16 sits at the line, and LQ +8 is negative.
- This is the same lesson as M1 (finding 4). It is why §8 runs the greedy pass twice.

## 7. The M1 options under SMT2

| Option | Est. LUTs | Single thread, suite IPC @120 | SMT2, v1 sizes: 30 | 120 | 250 | SMT2, proposed v2 sizes @120 |
|---|---|---|---|---|---|---|
| Second load pipe | 1.5K | +0.14% | +0.24% | +0.26% | +0.34% | +0.28% |
| Second FMA pipe | 4.4K | 0.00% | +0.01% | +0.02% | −0.02% | +0.01% |
| Third ALU (2-wide decode) | 4.5K | +1.17% | +0.15% | +0.38% | +0.41% | +2.29% |
| **3-wide decode/rename/commit + third ALU** | **10K** | **+13.3%** | **+17.4%** | **+16.3%** | **+15.9%** | **+19.1%** |

(Single-thread figures are against the v1 freeze. M1's §9 quoted the width options against the rule-only greedy freeze.)

- **SMT2 does not rescue the execution-width options.**
  - **At v1 sizes:** behind the 2-wide decoder, a second load pipe, a second FMA pipe or a third ALU each add under 0.5% throughput. Two threads share the same two decode slots, so the issue ports are, on average, no busier than with one thread.
  - **At v2 sizes:** the third ALU's own queue is worth 2.3%, because the larger window makes the issue queues the commonest stall (§8.4). That is still far below its 11% of the LUTs.
  - **The M1 rejections stand.**
- **3-wide decode gains more under SMT2 than for one thread:** +16–19% throughput, against +11% for a single-thread core running one program at a time. The compute pairs, pinned at a summed IPC of 2.00, rise to a WS of 1.52 (from 1.15). 3-wide is committed (D14), so the acceptance rule does not decide it; §9 treats the order and combination.

---

## 8. Sizing the 2-wide SMT2 core ("v2")

### 8.1 The acceptance rule, single steps

The rule is the one M1 used for the v1 freeze, applied to SMT2 throughput:
- **Start:** the v1 freeze with `threads=2`.
- **Each round:** add the size increment with the best WS_ref gain per LUT at 120 cycles. It qualifies only if:
  - its gain (%) is at least its LUT increase (%);
  - it loses no more than 0.25% at 30 or at 250 cycles.
- **Candidates:** the M1 increments plus L2 MSHRs:

  | Increment | Step |
  |---|---|
  | ROB | +16 |
  | ALU, LD, FP and STA issue queues | +2 |
  | LQ | +8 |
  | SQ | +4 |
  | completion buffer | +8 |
  | L1D MSHRs | +4 |
  | long-latency tags | +8 |
  | L2 MSHRs | +16 (SoC) |

| Round | WS_ref @120 | Chosen | Gain vs LUT share | Guards @30 / @250 |
|---|---|---|---|---|
| 1 | 1.3346 | SQ +4 | +0.98% vs 0.49% | +0.75% / +0.99% |
| 2 | 1.3476 | long-latency tags +8 | +0.67% vs 0.49% | +0.09% / +0.67% |
| 3 | 1.3567 | completion buffer +8 | +0.20% vs 0.16% | +0.12% / +0.19% |
| 4 | 1.3595 | stop; the best rejected step is ROB +16: +1.12% vs 1.17% | | |

The result, "v2 (single steps)" (SQ 16, completion buffer 16, 24 long-latency tags):
- **Throughput:** WS_ref 1.310 / 1.359 / 1.368, i.e. +1.9% at 120 cycles.
- **Cost:** 464 LUTs.

**The ROB sits on the line.** Each ROB step is worth just under its cost in every round, and the greedy stops. This is M1's lesson again (finding 4): a single step looks too expensive while the whole step does not.

### 8.2 The acceptance rule with whole-window steps

**Why bundle.** With static halves, the window grows per thread. A natural unit is therefore one more step of each window structure at once: ROB +16, LQ +8, SQ +4, which is +8 / +4 / +2 entries per thread and 1.0K LUTs (2.44%). A double ROB step (ROB +32) is offered as well.

| Round | WS_ref @120 | Chosen | Gain vs LUT share | Guards @30 / @250 |
|---|---|---|---|---|
| 1 | 1.3346 | SQ +4 | +0.98% vs 0.49% | +0.75% / +0.99% |
| 2 | 1.3476 | long-latency tags +8 | +0.67% vs 0.49% | +0.09% / +0.67% |
| 3 | 1.3567 | **window step** (ROB +16, LQ +8, SQ +4) | **+3.61% vs 2.44%** | +2.89% / +3.85% |
| 4 | 1.4057 | ROB +16 | +1.56% vs 1.17% | +0.95% / +2.00% |
| 5 | 1.4277 | stop: window step +1.84% vs 2.44%; ROB +16 +0.79% vs 1.17%; ALU queues +2 +0.47% vs 0.78% | | |

**The window step pays.** In the same round its parts alone are worth +1.15% (ROB), −0.01% (LQ) and +0.40% (SQ), but together +3.61%. With more long-latency tags (round 2), a larger LQ finally has something to feed: a larger ROB.

**The result is the proposed v2.**
- **Sizes:** ROB 80, LQ 24, SQ 20, 24 long-latency tags.
- **Throughput:** WS_ref 1.359 / 1.428 / 1.446.
- **Cost:** 1.88K LUTs.
- **Every step passed the rule on its own**, and each was the best step of its round.

**Robustness checks** ([smt2_tables.md](smt2_tables.md)):

- **Whole-window bundles on the single-step v2** (SQ 16, completion buffer 16, 24 long-latency tags). Each step adds ROB +16, LQ +8 and SQ +4 (1.0K LUTs, 2.44%) and is judged against the one before:

  | Configuration | WS_ref @30 | @120 | @250 | Step gain @120 | Step LUT share |
  |---|---|---|---|---|---|
  | v2 (single steps) | 1.310 | 1.359 | 1.368 | | |
  | + one window step (ROB 64, LQ 24, SQ 20) | 1.346 | 1.406 | 1.420 | **+3.45%** | 2.44% |
  | + two window steps (ROB 80, LQ 32, SQ 24) | 1.364 | 1.435 | 1.449 | +2.03% | 2.44% |
  | + three window steps (ROB 96, LQ 40, SQ 28) | 1.376 | 1.457 | 1.469 | +1.55% | 2.44% |
  | + three steps, 32 L1D MSHRs, 32 long-latency tags | 1.375 | 1.462 | 1.473 | +0.34% | 3.41% |

- **The two passes agree.** From either starting point, exactly one whole-window step pays. The proposed v2 then adds one more ROB step (+1.56% for 1.17%) and leaves the completion buffer at 8. It reaches 1.428 for 1.88K LUTs, against 1.406 for 1.46K with one window step on the single-step v2.
- **Further steps stay below the line,** and so do more MSHRs and tags.

### 8.3 SMT2 overhead estimate

The SMT2 logic itself, per core, beyond v1's thread hooks (plan §6.3 estimates those hooks at under 1%):

| Item | Low | Central | High | Basis |
|---|---|---|---|---|
| Second rename map and committed map | 500 | 800 | 1,100 | 2 × (32 × 8 + 32 × 7) flip-flops; every rename read port selects among 64 entries, not 32 |
| Second set of 4 rename checkpoints | 400 | 500 | 600 | ~125 LUTs per checkpoint, the M1 cost model |
| Second FTQ, global history, RAS and fetch PC | 500 | 700 | 950 | 32-entry FTQ and RAS in LUTRAM with their read ports, history repair, redirect muxing |
| Per-thread instruction queue and decode-to-rename queue | 150 | 300 | 450 | the 16-entry instruction queue already sits in 32-deep LUTRAM (pointers only); a 6-uop holding queue per thread |
| ICOUNT arbitration, per-thread occupancy counters and caps | 200 | 300 | 450 | pre-issue uop counters, comparators, cap checks |
| TID tags and partitions in ROB, LQ, SQ and completion buffer | 300 | 500 | 700 | per-partition pointers, TID match in the forwarding and ordering CAMs, TID-qualified kill |
| Sibling stores on the snoop path; per-hart LR reservation (rule 4) | 50 | 100 | 150 | reuses the existing snoop port |
| Second CSR file, trap, interrupt, timer and debug state | 1,500 | 2,000 | 2,800 | M/S CSRs, fcsr and 16 PMP entries per hart (PMP check logic shared) |
| Second set of performance counters | 600 | 1,000 | 1,300 | mcycle, minstret and 16 HPM counters per hart |
| MMU: TID in TLB and walk-cache tags, per-thread walk requests | 100 | 200 | 300 | tags already sized for the TID in v1 (plan §4.10) |
| **Total** | **4,300 (10.5%)** | **6,400 (15.6%)** | **8,800 (21.5%)** | of the ≈41K-LUT core |

- **Fit with the plan:** the central estimate falls inside the plan's +10–20% (§6.1).
- **On a 3-wide core:** +0.35K more (range +0.2–0.5K), 6.75K central. The rename read ports that select between the two maps grow 1.5 times, and each thread's decode-to-rename queue holds 9 uops.
- **Biggest items:** the second CSR file and the counters, which are architectural state, not performance logic.
- **Cheapest trims:**
  - share the 4 checkpoints between the threads (−0.5K);
  - give hart 1 fewer HPM counters (−0.5K);
  - their throughput cost is untested.

### 8.4 The proposed v2 at the three latency points

| | 30 cycles | 120 | 250 |
|---|---|---|---|
| WS_ref (against v1, one program at a time) | 1.359 | **1.428** | 1.446 |
| … memory + memory / compute + compute / mixed | 1.522 / 1.151 / 1.431 | 1.645 / 1.152 / 1.536 | 1.664 / 1.153 / 1.575 |
| WS (against v2 itself, one program at a time) | 1.299 | 1.365 | 1.403 |
| Fairness | 0.639 | 0.671 | 0.690 |
| Summed IPC (mean over pairs) | 1.773 | 1.616 | 1.563 |
| Single-thread suite IPC (against v1) | 1.257 (+2.4%) | 0.991 (+2.5%) | 0.828 (+1.8%) |

- **Limits that remain** at 120 cycles, averaged over the 84 threads:

  | Dispatch stalls on | Share of cycles |
  |---|---|
  | issue queues (the 75% caps or full queues) | 15% |
  | ROB | 4.4% |
  | LQ | 3.5% |
  | register banks, long-latency tags | never |

- **Compute pairs** stay pinned by the decoder: lowest WS matmult + Dhrystone and stream + matmult, both 1.003.
- **chase8 + chase8** now reaches 2.00: both threads run as fast as alone.
- **Policy checks on v2:**

  | Change | WS_ref at 120 |
  |---|---|
  | Round-robin fetch | −0.5% |
  | Shared window, 75% cap | +2.7% |
  | Shared window, no cap | +2.3% |

---

## 9. SMT2 and 3-wide: order and combination

**The question.**
- **Both are coming.** 3-wide decode is committed for a later version (plan D14), and SMT2 is planned (§6.4).
- **So this section asks:** in which order, and whether to combine them.
- **Rule 12** keeps a 2-thread, 3-wide core a valid configuration, with its per-thread structures sized for both. This study sizes it with the same acceptance-rule pass as the 2-wide SMT2 core (§8.2), starting from the v1 freeze with 3-wide decode/rename/commit, a third ALU and two threads.

![Weighted speedup against DRAM latency: SMT2, 3-wide and both](smt2_ws_vs_latency.svg)

### 9.1 The three cores

**How throughput is measured.** Throughput is WS_ref, against the v1 core running one program at a time. A single-thread core also runs each pair one program at a time, so its throughput is the mean of the two programs' speedups.

| Core | WS_ref @30 | @120 | @250 | Single-thread suite IPC @120 | Est. core LUTs vs v1 | Throughput gain per LUT % |
|---|---|---|---|---|---|---|
| v1 freeze (2-wide), one program at a time | 1.000 | 1.000 | 1.000 | 0.967 | — | — |
| A. SMT2 on the 2-wide core, v1 sizes | 1.297 | 1.335 | 1.343 | 0.967 (+0.0%) | +6.4K (15.6%) | 2.14 |
| B. 3-wide single thread, v1 sizes | 1.110 | 1.111 | 1.111 | 1.095 (+13.3%) | +10.0K (24.4%) | 0.46 |
| C. SMT2 on the 3-wide core, v1 sizes | 1.523 | 1.552 | 1.556 | 1.095 (+13.3%) | +16.8K (40.9%) | 1.35 |
| A′. SMT2, 2-wide, sized by the rule (the proposed next step) | 1.359 | 1.428 | 1.446 | 0.991 (+2.5%) | +8.3K (20.2%) | 2.12 |
| **C′. SMT2, 3-wide, sized by the rule (rule 12)** | **1.668** | **1.739** | **1.746** | **1.140 (+18.0%)** | **+19.5K (47.5%)** | **1.56** |
| B′. 3-wide single thread with C′'s sizes (reference) | 1.200 | 1.207 | 1.182 | 1.140 (+18.0%) | +12.7K (31.1%) | 0.67 |

**Costs.**

| Item | LUTs per core | Source |
|---|---|---|
| 3-wide decode/rename/commit + third ALU | ≈10K | M1, plan §4.15 |
| SMT2 logic, 2-wide | 6.4K | §8.3 |
| SMT2 logic, 3-wide | ≈6.75K | 1.5 times the rename read-port selects and deeper decode-to-rename queues add ≈0.35K |
| Window and queue sizes | per entry, as `scripts/report.py` | On a 3-ALU core, an "ALU queues +2" step grows three queues (480 LUTs). |

**Sizing the 3-wide SMT2 core (rule 12)** (every round in [smt2_tables.md](smt2_tables.md)):

| Round | Chosen | Gain vs LUT share @120 | Guards @30 / @250 |
|---|---|---|---|
| 1 | SQ +4 | +1.53% vs 0.49% | +1.37% / +1.48% |
| 2 | ROB +32 | +4.16% vs 2.34% | +3.91% / +5.04% |
| 3 | LQ +8 | +1.66% vs 0.78% | +1.36% / +1.41% |
| 4 | long-latency tags +8 | +0.97% vs 0.49% | +0.20% / +1.16% |
| 5 | completion buffer +8 | +0.35% vs 0.16% | +0.33% / +0.25% |
| 6 | SQ +4 | +0.66% vs 0.49% | +0.54% / +0.14% |
| 7 | ROB +16 | +1.36% vs 1.17% | +0.81% / +1.43% |
| 8 | LQ +8 | +0.81% vs 0.78% | +0.71% / +0.78% |
| 9 | stop: ALU queues +2 +1.06% vs 1.17%; LD queue +2 +0.30% vs 0.39%; window step +1.63% vs 2.44% | | |

- **The wider core needs a larger window** than the 2-wide SMT2 core:
  - ROB 96 against 80, LQ 32 against 24, completion buffer 16 against 8;
  - the reason: three decode slots fill the window faster.
- **What binds next.** Registers and long-latency tags still never bind. The issue queues are the commonest dispatch stall (19% of cycles), and the next step, ALU queues +2, sits just under the line.
- **The compute pairs are freed.** With the 3-wide decoder they rise from 1.15 to 1.47–1.61: the decoder no longer pins them.
- **B′ shows what C′'s window is worth for one thread** on the 3-wide core: +18.0% single thread, against +13.3% at v1 sizes. The 3-wide version's single-thread freeze is its own, later, pass (§4.15).

### 9.2 Order

Three paths lead to the combined core C′. Each step is judged against the core before it. LUT shares are of the ≈41K-LUT core, as in the greedy passes.

| Path | Step | Throughput @120 | Single-thread suite IPC @120 | LUTs | LUT share | Throughput gain per LUT % |
|---|---|---|---|---|---|---|
| **SMT2 first** | v1 → A′ | 1.000 → 1.428 (+42.8%) | 0.967 → 0.991 (+2.5%) | +8.3K | 20.2% | **2.12** |
| | A′ → C′ | 1.428 → 1.739 (+21.8%) | 0.991 → 1.140 (+15.1%) | +11.2K | 27.4% | 0.80 |
| 3-wide first | v1 → B | 1.000 → 1.111 (+11.1%) | 0.967 → 1.095 (+13.3%) | +10.0K | 24.4% | 0.46 |
| | B → C′ | 1.111 → 1.739 (+56.6%) | 1.095 → 1.140 (+4.2%) | +9.5K | 23.2% | 2.44 |
| Both at once | v1 → C′ | 1.000 → 1.739 (+73.9%) | 0.967 → 1.140 (+18.0%) | +19.5K | 47.5% | 1.56 |

**What the data says.**
1. **The two are complements.** Each makes the other worth more:
   - 3-wide adds 11% throughput to a single-thread core, but 22% to an SMT2 core: the second thread fills the third decode slot.
   - SMT2 adds 43% to the 2-wide core, but 57% to the 3-wide core: the wider decoder frees the compute pairs that two slots pin.
   - At the same (v1) sizes, the combined core is 4.7% above the product of the two alone.
2. **Every order ends at the same core; the order sets what the next version delivers.**

   | First step | Share of C′'s throughput gain | Share of C′'s LUTs | Share of C′'s single-thread gain |
   |---|---|---|---|
   | SMT2 first | 58% | 42% | 14% |
   | 3-wide first | 15% | 51% | 74% (CoreMark 6.11/MHz on rv64gc, which meets the 3-wide version's 6.0 target, D11) |

3. **SMT2 is the cheaper step in either position.**
   - SMT2 earns 2.1–2.4 points of throughput per LUT percent wherever it goes.
   - 3-wide earns 0.46–0.80 as throughput.
   - 3-wide's case is single-thread speed: 0.55 points of single-thread IPC per LUT percent in either position (+13.3% for 24.4%, or +15.1% for 27.4%).
4. **Fit decides how far each version gets on the KV260** (§9.3). A′ and B each fit the XCK26, above the 80% goal; C′ does not.

**The order the data favours:**
- **SMT2 first, on the XCK26.** It is the larger and cheaper throughput step, and it makes the later 3-wide step worth more (+22% throughput, +15% single thread).
- **Then 3-wide, combined with SMT2, on a larger device.**
- **If the next version moves to a larger device anyway,** build both at once (C′): the same end point, without an intermediate design.
- **3-wide first** fits only a goal of single-thread speed (CoreMark 6.0 on rv64gc) before throughput.

### 9.3 Fit

Dual-core SoC LUTs, from plan draft 0.4's ≈89K (76%) for v1 (§8.2), adding twice each core's estimated change:

| Configuration | SoC LUTs | Share of the XCK26 (117,120 LUTs) | Linux CPUs |
|---|---|---|---|
| v1 freeze | ≈89K | 76% | 2 |
| A′. SMT2, 2-wide, sized | ≈106K (range ≈101–110K) | **90%** (87–94%) | 4 |
| B. 3-wide single thread | ≈109K | 93% | 2 |
| B′. 3-wide single thread with C′'s sizes | ≈114K | 98% | 2 |
| C′. SMT2, 3-wide, sized | ≈128K | 109%: does not fit | 4 |

- **A′ and B both exceed the plan's ≈80% goal,** and neither leaves room for the other.
- **C′ needs about 11K more LUTs than the XCK26 has,** before any headroom for timing. Plan §4.15's leaner register-file organisation for the 3-wide version is the first place to look. On a larger device, C′ is the end point.

---

## 10. Recommendations and proposed plan changes

1. **Make SMT2 the next step after v1 (V2-1, V2-2)**, with the 2-wide column of §1.2.
   - **Expected:** +36–45% throughput over v1 at 30–250 cycles, +2.5% single thread, ≈8.3K LUTs per core.
   - **Then add 3-wide to the SMT2 core on a larger device,** with at least the rule-12 window of §1.2 (ROB 96, LQ 32, SQ 20, completion buffer 16, 24 long-latency tags). It adds +22% throughput and +15% single thread.
   - **If the next version moves to a larger device anyway,** build both at once.
   - **Hooks:** plan §6.2's hooks are exactly what the model needed. Keep the M6 `TID_W = 1` and 3-wide syntheses as the real cost measurements.
2. **Plan §6.1:** replace the planning estimate with the model result.
   - On the v1 freeze, SMT2 gives +30% / +33% / +34% weighted throughput at 30 / 120 / 250 cycles. Sized by the rule, +36% / +43% / +45%.
   - The gain comes from memory-bound threads. Compute pairs gain 15% on the 2-wide core and 47–61% on a 3-wide core.
   - Overhead estimate: 6.4K LUTs per core (4.3–8.8K), 6.75K on a 3-wide core.
3. **Plan §6.4, the later-versions line:**

   > "SMT2 first: static ROB/LQ/SQ/completion-buffer halves; shared issue queues with a 75% per-thread cap; ICOUNT fetch; decode, rename and commit alternate between threads and share idle slots; shared TID-hashed predictor tables and tagged TLBs and caches. Sizes: ROB 80, LQ 24, SQ 20, 24 long-latency tags; every other v1 size unchanged.
   >
   > Then 3-wide with SMT2, on a larger device. The rule-12 sizing is ROB 96, LQ 32, SQ 20, completion buffer 16, 24 long-latency tags.
   >
   > Both at once if the next version moves to a larger device."
4. **Plan §6.2, rules 7 and 12:**
   - **Rule 7, issue-queue caps:** required.
   - **Rule 7, MSHR and long-latency-tag caps:** they never bound in the model. Keep them as counters, but their default can be "no cap".
   - **Rule 12:** the 3-wide SMT2 sizing above is the reference for its per-thread structures: halves of ROB 96, LQ 32, SQ 20 and completion buffer 16.
5. **Plan §6.2, new design notes:**
   - **(a)** ICOUNT applies to fetch only. Rename and commit alternate, because ICOUNT at rename starves a waiting thread.
   - **(b)** The store drain must re-request a line evicted after its ownership grant (LSU spec).
   - **(c)** The speculative-wakeup shadow cancel is not selective, so it also cancels the sibling's issues. This is a measured cost inside the numbers above, not a hook to add.
6. **Feature ledger:**
   - **Add an SMT2 section:**
     - SMT2: +33% for 15.6%, adopted for the SMT2 version;
     - the size steps in §8.2;
     - shared window (+2.7%), option;
     - second load pipe, second FMA pipe and third ALU at 2-wide under SMT2: still rejected;
     - 3-wide (committed, D14): +22% throughput and +15% single thread on top of SMT2, with the combined core sized by rule 12 (§9.1).
   - **Update M1's re-evaluation trigger:** "Dual-core and SMT2 models: re-judge the window and miss-handling sizes". SMT2 is now done: the window grows, miss handling does not. The dual-core part stays open.
7. **SoC fit (V2-4).** The dual-core 2-wide SMT2 lands at ≈90% of the XCK26, above the 80% goal.
   - **Trims, cheapest first:**
     - share the 4 checkpoints between threads (−0.5K per core);
     - halve hart 1's HPM counters (−0.5K);
     - drop the window steps back to v2 (single steps), which costs 5% throughput (−1.4K).
   - **Which to apply** follows from the M6 syntheses.
8. **Re-run this study** when multiprogrammed Linux workloads exist (M5), and with a dual-core model for the shared L2 and DRAM bandwidth.


---

## 11. Limitations

**Model.**
- **Correct path only.** A thread waiting on a mispredicted branch fetches nothing. A real thread fetches down the wrong path and takes fetch and decode slots from its sibling until the branch resolves; ICOUNT limits this, because wrong-path uops raise the thread's count.
  - This favours SMT2 slightly, most in branchy compute pairs.
  - The suite's compute programs mispredict rarely (CoreMark: 0.8 per 1,000 instructions), so the effect is small. It is not zero.
- **No operating system.** The programs are bare-metal, in separate address spaces. Absent from the model:
  - context switches;
  - TLB misses (the model has no MMU);
  - memory shared between threads;
  - kernel code competing for the I$ and predictors.
- **One core.** The second core's share of the L2 and DRAM bandwidth is not modelled. With two SMT2 cores, four memory-bound harts would contend for DRAM bandwidth that this study gives to two.
- **Restarted programs.** A program that restarts runs with warm caches, which loads the core a little differently from a first run. Only first runs are measured. The overlap-window check (§3.2) bounds the effect.
- **Costs the model does not charge.** The shared-window option's extra ordering logic (§5) is not in the LUT estimates. Nor is any timing effect of the second thread on the protected loops (plan §8.1), such as the rename read-port select and the ICOUNT arbitration before fetch.

**3-wide single thread.** It is not re-sized by the rule here: its freeze is the 3-wide version's own pass (§4.15). B′ (§9.1) shows what a larger window adds.

**Workloads.** The pairs come from the M1 suite, so M1's gaps carry over: no SPEC-like or Linux workloads, no large code, few FP-heavy programs. Multiprogrammed Linux workloads (M5) should re-run this study.

**Costs.** Every LUT figure is an estimate. The SMT2 overhead in particular (§8.3) is built item by item. Plan §6.3 already schedules the measurement that replaces it: a `TID_W = 1` synthesis at M6.

## 12. Reproducing these results

From `perfmodel/` in WSL Ubuntu 24.04, after the M1 builds (`make`, `bench/build_all.sh`):

```bash
make -j8                                   # tgsim with threads=2
bash tests/build_idle.sh                   # the near-idle sibling for --validate
python3 scripts/recheck.py rv64gc 4        # threads=1 unchanged
python3 scripts/recheck.py --freeze
python3 scripts/smt.py --explore           # policy and cap exploration (§5)
python3 scripts/smt.py                     # the study and the single-step greedy pass
python3 scripts/smt.py --bundles           # the greedy pass with whole-window steps
python3 scripts/smt.py --width3            # the same pass on a 3-wide, 3-ALU SMT2 core (rule 12)
python3 scripts/smt.py --supplementary     # sharing x issue-queue caps; window bundles
python3 scripts/smt.py --validate          # SMT2 consistency checks
python3 scripts/smt_tables.py              # docs/perf/smt2_tables.md and smt2_ws_vs_latency.svg
```

**Where results live.**
- Pair runs are cached per configuration and pair in `perfmodel/results/smt/`, keyed by model version, suite revision and `SMT_VERSION`. Single-thread runs reuse the M1 cache in `results/dse/`.
- The summary is `results/smt2_rv64gc.json`.
- **Run time:** on 8 threads the study takes about 1.5 hours, each 2-wide greedy pass 20–30 minutes, and the 3-wide pass about 1.5 hours.
