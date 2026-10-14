# Tanager feature ledger

*Every feature and structure size in Tanager, with the evidence for its decision (plan draft 0.3, §2.5). The M1 freeze is the first set of entries; every later change is appended here.*

**Naming (plan draft 0.4, D16).**
- **The M1 freeze** below is the single-thread configuration, now called **ST**: the bring-up stage, not a release.
- **The first release, v1,** is ST plus the SMT2 section further down.
- **Older names:** entries that say "v1" for the single-thread design predate this renaming.

| | |
|---|---|
| Rule | A feature or size step is accepted if its suite-IPC gain at a 120-cycle DRAM round trip (%) is at least its LUT increase (%), measured against the ≈41K-LUT core (or the ≈94K-LUT SoC for shared features), with no loss worse than 0.25% at 30 or 250 cycles. Everything else is removed or kept as a written exception. |
| Evidence | `tgsim` model version 3, suite revision 2 (33 workloads, rv64gc); [dse_report.md](dse_report.md); generated detail in [ledger_table.md](ledger_table.md) and [dse_tables.md](dse_tables.md) |
| Latency points | Feature ablations at 30, 120 and 250 cycles; the frozen configuration at all five points (30, 60, 90, 120, 250) |
| Costs | LUT figures are estimates from the plan §8.2 budget until spikes S2–S6. BRAM, URAM and DSP are noted where they change. "Gain" is the suite-IPC contribution at 120 cycles. |
| Status | **kept** · **changed** · **removed** · **adopted** · **rejected** · *provisional* (an exception, or evidence that waits for Linux/SPEC-like workloads) |

## M1 freeze (2026-10-13, approved by the project owner; plan draft 0.4 §4.14; `tgsim --preset v1_freeze`)

### Front end

| Item | Draft 0.3 → v1 | Gain vs LUT share | Other costs | Status |
|---|---|---|---|---|
| Micro-BTB | 32 entries, fully associative flip-flops → **64, 2-way LUTRAM** | Feature: +7.5% vs 1.7%.<br>32 → 64: +2.0% vs 0.24%.<br>64 → 128: +0.06% vs 0.15%. | Puts a LUTRAM read in the 1-cycle next-PC loop (plan §8.1 fallback); spike S5 must confirm | **changed** |
| TAGE-lite | 4 tagged tables of 1K → **4 of 4K** | Feature vs 4 KB gshare: +5.8% vs 2.0%.<br>Each doubling: +0.45%, +0.22% vs 0.07%. | +6 BRAM36 | **changed** |
| Block BTB, RAS, FTQ | 1K × 4 / 32 / 32 | not swept | — | kept |
| Fetch-directed + next-line I$ prefetch | on | +0.03% vs 0.49% | — | kept as *exception E1* |
| L1I MSHRs | 2 → **4** | +0.01% vs 0.29% | — | **changed**, *exception E1* |
| L1I size | 32 KiB, 8-way | L1s 32 vs 16 KiB: +0.85% vs 0.49% | +12 BRAM36 vs 16 KiB | kept |

### Decode

| Item | Draft 0.3 → v1 | Gain vs LUT share | Other costs | Status |
|---|---|---|---|---|
| Macro-op fusion (plan's pair list) | on → **off** | +0.14% vs 0.98% | medium verification surface | **removed** (RTL option) |
| SFB predication | on → **off** | +0.17% vs 1.22% (78 conversions in 6.7M CoreMark instructions) | third operand on P0; medium verification | **removed** (RTL option) |
| Jump folding | on → **off** | +0.01% vs 0.24% | retire-count rules | **removed** |
| ALU + branch fusion | option | +0.04% vs 0.73% | — | **rejected** |
| Pair-decode fusion (a fused pair takes one decode slot) | option | +1.7% at 120 in the freeze context; CoreMark +2–3% | about 1K LUTs (est.); changes what "2-wide decode" means | **not adopted.** The CoreMark target (D11) doesn't need it; it stays an option. |

### Rename, ROB and commit

| Item | Draft 0.3 → v1 | Gain vs LUT share | Other costs | Status |
|---|---|---|---|---|
| Rename checkpoints | 8 → **4** | Feature: +0.90% vs 2.44%.<br>Greedy step 0 → 4: +0.63% vs 1.22%. | high verification surface (recovery) | **changed**, *exception E2* |
| ROB | 64 → **48** | Greedy step 48 → 64: +0.45% vs 1.17% | — | **changed** |
| Early retirement | hooks + go/no-go → **on** | +2.39% vs 2.20% (v1); +3.4% at ROB 48.<br>16-filler chase MLP: 7.88 with it, 3.79 without. | high verification surface (precise state, ordering); enable bit | **kept: GO** |
| Long-latency tags | 32 → **16** | Greedy step: +0.02% vs 0.49% | — | **changed** |

### Scheduling

| Item | Draft 0.3 → v1 | Gain vs LUT share | Other costs | Status |
|---|---|---|---|---|
| IQ-A0 / IQ-A1 | 12 / 12 → **10 / 10** | Greedy: 6 → 8 +1.50%, 8 → 10 +1.17% vs 0.78%; 10 → 12 +0.29% | wakeup-select loop gets shorter | **changed** |
| IQ-LD | 12 → **6** | Greedy step: +0.07% vs 0.39% | — | **changed** |
| IQ-STA | 8 → **4** | Greedy step: +0.09% vs 0.39% | — | **changed** |
| IQ-FP | 12 → **10** | Greedy step: +0.02% vs 0.39%.<br>6 → 10 in the freeze: +0.07%; blocked matmul +12.7%. | — | **changed**, *exception E5* |
| Branch-first select | on → **off** | −0.03% vs 0.12% | — | **removed** |
| Speculative load wakeup (hit predictor, 2-cycle shadow cancel) | on | +3.0% vs 1.22% | high verification (cancel and replay) | kept |
| Third ALU at 2-wide decode | option | +1.2% vs ~11% (est.) | 9 integer read ports force register-bank duplication | **rejected** |

### Load/store unit

| Item | Draft 0.3 → v1 | Gain vs LUT share | Other costs | Status |
|---|---|---|---|---|
| LQ CAM | 16 | Greedy step: +0.04% vs 0.78% | — | kept |
| Retired-load completion buffer | 16 → **8** | 0 → 8: +2.4% vs 0.16%; 8 → 16: +0.00% | — | **changed** |
| SQ | 16 → **12** | Greedy step: +0.21% vs 0.49% | — | **changed** (borderline) |
| Wait table (memory-dependence prediction) | 1K → **off** | +0.02% vs 0.24%; no ordering violations in the aliasing kernel | — | **removed** (RTL option) |
| Early ownership prefetch | on | +1.6% vs 0.24% (memcpy) | — | kept |
| L1D PC-stride prefetcher | on | +0.96% vs 0.73% (SpMV, gather index streams) | — | kept |
| L1D MSHRs | 12 → **16** | Greedy: 12 → 16 +1.26% vs 0.73%; 16 → 20 +0.00% | — | **changed** |
| L1D size | 32 KiB, 8-way | +0.85% vs 0.49% | +12 BRAM36 vs 16 KiB | kept |
| Second load pipe | option | +0.40% vs 3.66% | +8 BRAM36 | **rejected** |

### Shared L2 and memory

| Item | Draft 0.3 → v1 | Gain vs LUT share | Other costs | Status |
|---|---|---|---|---|
| L2 size | 1 MiB | +0.10% vs 0.21% (SoC) | 32 UltraRAM, otherwise unused | kept as *exception E3* |
| L2 stream prefetcher | on | +6.6% vs 0.43% (SoC); +8.6% at 250 | — | kept |
| L2 MSHRs; stream distance and degree (run-time defaults) | 32; 8, 2 → **48; 16, 4** | +0.0% at 120 | +0.8K LUTs (SoC) | **changed**, *exception E4* |

### FPU

| Item | Draft 0.3 → v1 | Gain vs LUT share | Other costs | Status |
|---|---|---|---|---|
| FMA pipe | 4–5 cycles → **5** | 5 → 4: +0.22% (+0.12% without nbody) | timing (cost not in LUTs) | **changed** (pinned); revisit at synthesis |
| Divide/sqrt | radix-4 digit recurrence → **Goldschmidt, 10-bit seed, pipelined** | M1: +2.23% (+1.31% without nbody) vs 0.49%. **As built (2026-10-13):** +2.4% suite IPC vs 3.7% (+1.4K LUTs measured; 26 DSPs, 1 BRAM18) | rounding needs the remainder step (TestFloat clean, level 2) | **adopted by user decision D17**, an exception to the rule at the measured cost; the radix-4 unit is the area fallback (`FDIV_RADIX4`) |
| Divide/sqrt, radix-16 | option | +1.67% (+1.09%) vs 2.93% | — | **rejected** |
| Goldschmidt, 14-bit seed | option | +0.12% (+0.04%) over the 10-bit seed vs 0.24% | +2–4 BRAM36 | **rejected** |
| Second FMA pipe | option | +0.08% vs 10.7% | +12 DSPs | **rejected** |

### Width (beyond the 2-wide requirement)

| Item | Status | Gain vs LUT share | Note |
|---|---|---|---|
| 3-wide decode/rename/commit with a third ALU | **committed for a later version** (D14); reserved in v1 | +13.2% vs ~24% (est.); CoreMark 6.08 on rv64gc | Every width-dependent structure is a parameter, and a 3-wide build is kept in CI, spikes and synthesis (plan §4.15, D13). Its sizes are re-frozen by the rule when that version is planned. |
| 3-wide with two ALUs | **rejected** | +5.0% vs ~11% | — |
| µop cache | **rejected** | ≤ +1.4% (upper bound) vs ~3–5% | Doesn't widen the 2-wide rename and commit |

**Net estimated change vs draft 0.3, per core:**
- **LUTs:** −4.1K removed, +0.8K added, so −3.3K.
- **Shared L2:** +0.8K LUTs.
- **DSPs:** +24.
- **BRAM:** about +6.5 BRAM36.

**Dual-core SoC estimate:** about 89K LUTs (76%), 103 of 144 BRAM36, 108 of 1,248 DSPs (plan draft 0.4, §8.2).

**Validated at all five latency points:**
- **Suite IPC:** 0.967 at 120 cycles, +4.6% over draft-0.3 v1.
- **Ratio to the control:** 1.615 / 1.669 / 1.678 / 1.683 / 1.691 at 30 / 60 / 90 / 120 / 250 cycles.

## SMT2 build (decided 2026-10-13; plan §6.5, D15)

Configuration `smt2` (`TID_W = 1`). Gains are weighted two-thread throughput against v1 running one program at a time, at 120 cycles ([smt2_report.md](smt2_report.md) §8).

| Item | v1 → SMT2 build | Gain vs LUT share | Status |
|---|---|---|---|
| SMT2 itself (second hart) | 1 → 2 harts | +33% on v1's sizes vs 15.6% (6.4K LUTs, est.) | **adopted** for the SMT2 build |
| SQ | 12 → **20** | greedy step +0.98% vs 0.49%, then part of the window step | **changed** |
| Long-latency tags | 16 → **24** | +0.67% vs 0.49% | **changed** |
| Window step (ROB +16, LQ +8, SQ +4) | — | +3.61% vs 2.44% (its parts alone: +1.15%, −0.01%, +0.40%) | **adopted** |
| ROB | 48 → **80** (2 × 40) | last step +1.56% vs 1.17%; single thread on this core +2.5% | **changed**, kept by the project owner over ROB 64 |
| Issue-queue caps | — → 75% per thread | required for any window sharing; neutral with static halves | **adopted** |
| Shared window with 75% caps | option | +2.7–3.7%; its ordering logic is not costed | option |
| L1D / L2 MSHRs | 16 / 48 | never binding (+0.0%) | kept |
| Second load pipe, second FMA pipe, third ALU at 2-wide | options | +0.26% / +0.02% / +0.38% under SMT2 | **rejected** |

**Net:** weighted throughput 1.36 / 1.43 / 1.45× at 30 / 120 / 250 cycles, for about +8.3K LUTs per core; the dual-core is ≈105K LUTs (90%).

## Area recovery (study 2026-10-14; plan §8.5, D18)

Levers judged by the area-recovery study ([area_recovery.md](area_recovery.md)). The statuses are the study's recommendations; plan §8.5 records the decisions.
- **Rule:** the reverse acceptance rule at 120 cycles. A lever qualifies if its LUT saving (%) is at least its IPC loss (%), where the loss is the larger of the two-thread throughput loss and the single-thread suite loss.
- **Base:** the core after the planned levers, 45.6K for v1 and 53.6K for v2.
- **Free:** both losses within 0.05%.
- **LUT savings:** estimates, except where a spike measured them.

| Item | Change | Saves per core | Throughput / single thread @120 | Status |
|---|---|---|---|---|
| Wakeup IDs | one dependency column per ROB entry → **16 wakeup tags** for multi-cycle fixed-latency producers; MX and the LLTs cover every other producer (census: no row waits on a ROB column for a 1-cycle producer) | v1 2.7–3.0K, v2 4.7–5.0K, ST ≈1.0–1.2K (S2 fit at 40 columns; one S2 build confirms) | 0.00% / 0.00% at all latencies, in v1, v2 and ST | **adopted** (no IPC cost) |
| Rename checkpoints (R10) | 4 per thread → **4 shared** by the two threads | 0.5K | −0.01% / 0.00% | **adopted** (no IPC cost) |
| Store-to-load forwarding (R9) | any covering store → **same address and size only** | 0.2–0.3K | −0.03% / −0.00% | **adopted** (no IPC cost) |
| Third decoder (R12, v2) | full → **ALU, branch, jump, multiply/divide and integer load/store only** | 0.15–0.25K | −0.03% / −0.06% | **adopted for v2** |
| Completion buffer (v2) | 16 → **8** | 0.06K | −0.06% / 0.00% | **adopted for v2** |
| Reserve, in rank order (D18 step 3) | v1: FP queue 10 → 8, LD queue 6 → 4, radix-4 divide/sqrt. v2: radix-4, ALU queues 10 → 8 | 0.17K, 0.17K (with tags), 1.41K; 1.41K, 0.95K (with tags) | each alone: v1 0.00% / −0.06%, −0.15% / −0.20%, −0.42% / −2.42%; v2 −0.66% / −2.61%, −1.93% / −0.95% | not adopted; used only if the fit needs them, after a lower clock |
| R11 (v2): ALU2's register reads through shared, arbitrated ports | — | 0.74K (S3) | −0.62% / −1.66%; timing −0.24 ns against replication (S3) | **rejected** |
| R13 (v2): simple third ALU | — | 0.3–0.5K | −0.09% / −1.53% | **rejected** |
| Readiness banked by thread (rows see one ROB half) | — | 1.7–2.8K (v1) | −2.61% / −8.21% | **rejected** |
| ALU queues 10 → 8 (v1); LQ, SQ, STA queue and LLT cuts; ROB 64 (v1) and ROB 80 (v2) | — | 0.2–1.7K | −0.7% to −4% | **rejected** (the ROB cuts pass only without wakeup tags) |

**Net, per core:**
- **v1:** −3.4 to −3.8K at −0.04% throughput. The dual-core is ≈92–104K LUTs, which fits at 200 MHz (area_recovery.md §7.1).
- **v2:** −5.6 to −6.1K at −0.10%. The dual-core is ≈105–121K, so v2 is re-planned around 180–190 MHz (§7.2).

## Exceptions

Each exception is re-judged once Linux/SPEC-like workloads exist (M5). Any of them can be removed then without other changes.

| # | Item | Why it is kept below the line | Evidence | Re-judge with |
|---|---|---|---|---|
| E1 | I-side prefetch + 4 L1I MSHRs | The suite has no code larger than the L1I; Linux kernel paths are | ~200 KiB-code kernel: prefetch +34%, 2 → 4 MSHRs +30% | Linux boot and syscall-heavy traces |
| E2 | 4 checkpoints | The suite under-represents branchy integer code with long dependency chains | L2-resident binary search (47 mispredicts per 1K instructions) +5.7%; nbody, qrduino, huffbench +3.5–8.5% | gcc compile, interpreters, sqlite |
| E3 | 1 MiB L2 | Its cost is UltraRAM, which has no other use; no suite workload sits between 0.5 and 1 MiB | — | Linux workloads with 0.5–4 MiB working sets |
| E4 | 48 L2 MSHRs, stream prefetch distance 16 / degree 4 | Required by §2.5 criterion 1: the 250-cycle ratio must not fall below native | memcpy at 250 cycles: 0.84 → 1.57 IPC; the freeze's 250-cycle ratio is 1.691 vs 1.615–1.669 at native | the second core's bandwidth share (dual-core model) |
| E5 | FP issue queue 10 | Dense FP code is absent from the suite apart from STREAM | blocked matmul −12.7% at 6 entries | SPECfp-like or numerical workloads |

## Re-evaluation triggers

- **Synthesis spikes S2–S6:** replace LUT estimates and re-judge every entry within 0.5 percentage points of the line:
  - early retirement;
  - SQ;
  - E2;
  - the micro-BTB organisation (timing);
  - Goldschmidt (DSP cascade timing).
- **Linux/SPEC-like suite (M5):** re-judge E1–E5 and the removed decode features (fusion, SFB, folding).
- **Dual-core and SMT2 models:** re-judge the window and miss-handling sizes (ROB, LQ/SQ partitions, MSHRs) for throughput.
- **RTL correlation (M6):** the model must match RTL counters within 10%, or the affected entries are re-run.
- **S2 build with wakeup tags** (16 + 24 wakeup columns): replaces the tag saving estimate.
- **Dense-FP workloads (with E5, M5):** re-judge the size of the wakeup-tag pool and the FP-queue reserve trims.

## Change log

| Date | Change |
|---|---|
| 2026-10-13 | M1 freeze: first entries (this document) |
| 2026-10-13 | Freeze approved by the project owner and adopted in plan draft 0.4. MLP criterion restated. |
| 2026-10-13 | CoreMark target set to ≥ 1.21× the NaxRiscv control per flag set (D11; met at 1.46× / 1.34×). 3-wide committed for a later version, with all width-dependent logic parameterized in v1 (D13, D14; plan §4.15). |
| 2026-10-13 | SMT2 build sized by the rule on two-thread throughput: ROB 80, LQ 24, SQ 20, 24 LLTs, 75% issue-queue caps (D15). The 3-wide cost estimate was refined to 6.0–7.7K LUTs per core (plan §4.15). |
| 2026-10-13 | Roadmap: v2 = SMT2, v3 = 3-wide on the SMT2 core, all on the XCK26 (D14). Area-recovery levers R1–R15 (plan §8.5) enter the ledger as they are measured. |
| 2026-10-13 | First release is SMT2 (D16). Renamed: the single-thread M1 freeze is the bring-up configuration ST; the first release v1 is the SMT2 build; 3-wide on SMT2 is v2. |
| 2026-10-14 | Area-recovery study (plan §8.5, D18): wakeup tags, R9 and R10 adopted at no IPC cost, and R12 and a completion buffer of 8 for v2. R11, R13 and thread-banked readiness rejected. The reserve order is in [area_recovery.md](area_recovery.md). |
