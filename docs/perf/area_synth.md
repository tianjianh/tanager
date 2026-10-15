# Tanager: area-recovery study, synthesis side

*Plan §8.5, the area-recovery study under D18: IPC first. Step 1 is implementation tricks that cost no IPC; step 2 a lower clock, down to about 180 MHz, rather than smaller structures, which only the user can approve (DR-137); step 3 the IPC-costing levers. This page is the synthesis side: what the no-IPC tricks save on the over-budget units, and how full the XCK26 may get at 180 MHz (measurements: the target stays 200 MHz unless the user approves a lower clock, DR-137).*

| | |
|---|---|
| Status | In progress, 2026-10-13 (spikes track) |
| Units | the scheduler first (spike S2, `tg_iq` + `tg_wake` in `tg_s2_sched_top`); the FPU track does its own pass |
| Method | out-of-context synthesis and `opt_design` for LUT counts ([`fpga/budget/tcl/unit_synth.tcl`](../../fpga/budget/tcl/unit_synth.tcl)); full implementation at 200 MHz with the pblock for timing ([`fpga/spikes/tcl/ooc_run.tcl`](../../fpga/spikes/tcl/ooc_run.tcl)); S6 for the fill test |

## 1. Where the scheduler's LUTs go

**Configuration:** smt2 with MX, DUP_SEL, EARLY_W = 24, the guard. That is 8,909 LUTs after `opt_design`, out of context, which matches the 8,895 after routing.

**Method.** [`s2_ablate.py`](../../fpga/spikes/scripts/s2_ablate.py) synthesises a temporary copy of the RTL with one function removed; the function's cost is the difference. The copies are not working designs, only counts.

| Function removed | Its cost (LUTs) | Note |
|---|---|---|
| Readiness over the wakeup-ID columns, with everything that only feeds it | 3,119 | Includes W (313), the wakeup encode and the delay-line decode, which are trimmed with it. The AND-OR itself is ≈1.4K, about 35 LUTs per row over 104 columns: already near the 3-pairs-per-LUT6 minimum |
| Guard's busy vector (an OR of every row's dependency bits per column) | 1,145 | 11 LUTs per column: 2 per queue, then the OR of the five queues |
| MX: the row-dependency matrix, its per-column clear and its readiness term | 1,269 | |
| … of which the per-column clear alone | 761 | about 1 LUT per matrix bit (40 rows × 20 ALU rows) |
| Wakeup-ID encode at select (ALU queues) into W | 739 | About 200 of it is the harness's one-hot dispatch interface; a real rename stage hands over a 7-bit ID |
| Harness: delay-line wakeup IDs decoded into W | 657 | Ten sources (every queue, two taps); a real core has about four |
| Flush by ROB age | 660 | The compare is about 6 LUTs per row; the rest is downstream logic the ablation also removes |
| Per-thread caps (row counts, room counters) | 629 | |

**Per queue** (hierarchy kept, `-flatten_hierarchy none`, 8,403 LUTs in all):

| Instance | LUTs |
|---|---|
| ALU queue 0 / 1 (10 rows each, wake at select) | 1,910 / 1,874 |
| FP queue (10 rows) | 1,772 |
| LD queue (6 rows) | 1,016 |
| STA queue (4 rows) | 737 |
| W (`tg_wake`, 104 columns) | 313 |
| Harness (dispatch steering, delay lines, busy OR, registers) | 781 |

So a row costs about 180 LUTs at 104 columns: readiness about 35, busy about 29, MX about 32, and the rest is select, payload, caps and flush.

## 2. Readiness only over the columns a queue can depend on

The wakeup IDs are ROB entries and long-latency tags, so the dependency columns are shared by every kind of producer. An integer op and an FP op can sit in neighbouring ROB entries, and any queue's row can depend on any of its thread's ROB entries and on any tag. **No queue has an exact subset of columns, except by thread:**
- A row of thread *t* depends only on thread *t*'s 40 ROB columns and the 24 tags: 64 of 104.
- But rows are shared between threads (75% caps, plan §6.5), so a row would have to select its thread's half of W. That is 4 inputs per dependency bit instead of 2, about 57 LUTs per row against today's 35–42.
- A static half per thread would make it exact, but that is the IPC-costing partition the SMT2 study rejected.

The exact partition therefore saves nothing with ROB-entry wakeup IDs.

## 3. No-IPC tricks measured

Synthesis and `opt_design` LUTs, smt2 with MX, against 8,909 (8,895 after routing, WNS +0.112 ns with the pblock).

| Trick | LUTs | Saved | IPC cost | Timing at 200 MHz (routed, pblock) |
|---|---|---|---|---|
| Keep the hierarchy (`-flatten_hierarchy none`) | 8,403 (routed 8,368) | 506 (5.7%) | none | **+0.132 ns**, no loss |
| `AreaOptimized_high` synthesis directive | 8,115 (routed 8,113) | 794 (8.9%) | none | **−0.265 ns**: loses 200 MHz on its own (flattened) |
| Both | **7,712 (routed 7,691)** | **1,197 (13.4%)** | none | **+0.102 ns**, no loss; smt2_w3 below |
| No row-dependency matrix in the STA and FP queues (`MX_CQ`: their rows take the ID path, one cycle later for ALU producers) | 8,506 | 403 | near zero (int→FP moves, store addresses); the model session to confirm | tested in simulation |
| Less payload in flip-flops (`EARLY_W` 24 → 16, the rest in LUTRAM) | 8,813 | 96 (+80 LUTRAM) | none | small |
| … `EARLY_W` 24 → 8 (only part of the source tags in flip-flops) | 8,637 | 272 (+80 LUTRAM, −720 FFs) | none if the RF stage can wait for the LUTRAM tags | with tags and both settings: 4,603 against 4,750 (−147, −3.1%; −720 FFs), **+0.162 ns** against +0.392: the worst path returns to the wakeup loop. A small saving: `EARLY_W` stays 24 for 200 MHz, and 8 is an option at 180 MHz only (DR-112) |
| Harness only: delay lines on the queues that really have delayed wakeups (`DL_Q`) | 8,663 | 246 | — | a harness artifact, not a saving in the core |
| Delay lines with predecoded IDs (`DL_ENC`) | 8,683 | −20 | — | does not help |

**At smt2_w3 (120 columns)** the two settings together give 11,381 LUTs (−1,134) at −0.008 ns: a hair short of 200 MHz, with about 0.5 ns to spare at v2's 180–190 MHz.

### 3.1 Wakeup tags (AR-1, plan §4.6)

**The structure.** 16 tags plus the LLTs replace the ROB-index columns: 32 columns at st, 40 at smt2 and smt2_w3. 1-cycle producers take no column:
- while they hold a row, consumers name them by row (MX);
- once the row is freed they are complete.

So no queue wakes at select. Multi-cycle ops wake their tag through the delay lines. The S2 harness has it as `WTAGS = 16`; `tb_iq`'s tags mode tests it.

**Results** (whole scheduler, routed at 200 MHz with the pblock, default synthesis):

| Configuration | ROB columns + MX | Wakeup tags + MX | Saved | Study's estimate | WNS ns: before → after | Levels |
|---|---|---|---|---|---|---|
| st | 6,425 | **4,802** | **−1,623 (−25%)** | −1.0 to −1.2K | +0.145 → **+0.518** | 6 → 7 |
| smt2 (v1) | 8,895 | **5,506** | **−3,389 (−38%)** | −2.7 to −3.0K | +0.112 → **+0.218** | 7 → 7 |
| smt2_w3 (v2) | 12,515 | **7,703** | **−4,812 (−38%)** | −4.7 to −5.0K | +0.057 → +0.026 | 8 → 7 |

- **The saving meets or beats the study everywhere.** Each row loses 64–80 readiness columns and their busy-vector share. The wakeup encode at select and the matrix W loop disappear.
- **Timing:**
  - W's own update is no longer a 1-cycle loop through select: one level, +1.8 ns.
  - The worst path is now W → readiness → select → payload register, 7 levels.
  - st and smt2 gain margin. smt2_w3 stays at the edge of 200 MHz but has about 0.5 ns at v2's 180–190 MHz.
- **One earlier trick no longer applies:** STA and FP queues without the matrix (−403). With tags, those queues have no other way to wait on a 1-cycle producer.
- **The free synthesis settings stack on tags** (hierarchy kept plus `AreaOptimized_high`, routed at 200 MHz with the pblock):

  | Configuration | Tags, default | Tags, both settings | Saved | WNS ns | Levels |
  |---|---|---|---|---|---|
  | st | 4,802 | **4,228** | −574 (−12.0%) | +0.518 → **+0.226** | 7 → 11 |
  | smt2 (v1) | 5,506 | **4,750** | −756 (−13.7%) | +0.218 → **+0.392** | 7 → 11 |
  | smt2_w3 (v2) | 7,703 | **6,669** | −1,034 (−13.4%) | +0.026 → **+0.094** | 7 → 11 |

  - The same −13% as without tags (§3), and timing improves rather than degrades. Flip-flops and LUTRAM do not change (5,208 / 240 at smt2).
  - The directive alone fails (§3): with a flattened design it restructures the wakeup loop across module boundaries and misses by 0.265 ns. With each queue kept as a module it cannot, so the loop keeps its margin. Use the two together or not at all.
  - At smt2 and smt2_w3 the worst path moves off the wakeup loop (W → readiness → select → payload, 7 LUT levels) to a queue's room counter (`room_q`, 11 levels of which 2 are CARRY8), at more slack. At st it stays on the wakeup loop, now 11 levels, and gives up 0.29 ns of its large margin.
  - **The scheduler from ROB columns to tags plus both settings: 6,425 → 4,228 at st (−34%), 8,895 → 4,750 at smt2 (−47%) and 12,515 → 6,669 at smt2_w3 (−47%)**, all closing 200 MHz.

## 4. The real core, module by module (st, first synthesis)

**Build:** `tg_core` from main d04ae26 (M2 plus M3 features, no FPU), configuration st, synthesis and `opt_design` with the hierarchy kept (`-flatten_hierarchy none`, so every module's count is exact). The command is `fpga/budget/hier_top.py` on the budget run's report.

**Total: 82,549 LUTs.** The same design flattened is 88K, so keeping the hierarchy alone saves about 5.5K here, as it did on the scheduler (§3) at no timing cost.

| Instance | LUTs | Share | Notes |
|---|---|---|---|
| `u_lsu` (whole LSU) | 34,430 | 41.7% | |
| … `u_lsu/u_dc` (D-cache) | 13,231 | 16.0% | state and tags in flip-flops (the core track's suspect) |
| … `u_lsu/u_pmp_ld`, `u_pmp_st` | 3,121 each | 7.6% | PMP checkers |
| … `u_lsu/u_ptw` (with its PMP checker, 3,110) | 3,198 | 3.9% | |
| … `u_lsu/u_dtlb` | 1,276 | 1.5% | |
| … the rest (LQ/SQ, forwarding, MSHRs) | about 10.5K | 13% | |
| `u_fetch` (whole front end) | 16,911 | 20.5% | |
| … `u_fetch/g_pmp[0..3]` | 3,117 each | 15.1% | **four** PMP checkers |
| … `u_fetch/u_cmp` (compaction, IQ) | 1,700 | 2.1% | |
| `u_rn` (rename) | 11,903 | 14.4% | maps in flip-flops (lever R3 puts them in LUTRAM) |
| `u_ex` (RF, ALUs, MUL, DIV, bypass) | 8,479 | 10.3% | `tg_irf` 2,568, two ALUs 1.2K each, DIV 1.3K |
| `u_is` (scheduler, no FP queue yet) | 5,121 | 6.2% | |
| `u_rob` | 2,736 | 3.3% | |
| `u_csr` | 1,532 | 1.9% | the flattened build charged the PMP checkers here |
| `u_de` | 1,399 | 1.7% | |

**The PMP checkers are a quarter of the core.** There are seven copies at about 3.1K LUTs each: 16 entries, each compared against the address. Two no-IPC options, both legal under the privileged spec:
- **One check per fetch block** with a PMP granularity of at least 16 bytes (G ≥ 2). A 16-byte aligned fetch block then never straddles a PMP boundary, and three of the four fetch checkers go: **−9.3K**.
- **PMP results cached in the TLBs** with a 4 KiB granularity (G ≥ 10):
  - Each TLB fill checks the page once, with the PTW's checker, and stores the permissions in the entry. Software executes `SFENCE.VMA x0, x0` after writing PMP CSRs, as the spec allows implementations that cache PMP results to require.
  - Bare-mode accesses go through identity TLB entries, or keep one shared checker.
  - That leaves one or two checkers instead of seven: **−15.6K to −18.7K**.
  - OpenSBI's regions are already 4 KiB-aligned or coarser.

### 4.1 The free synthesis settings on the whole core (DR-113)

**Build:** `tg_core` at st from main cb8ff6c (F and D in, P4 included, the core's first no-IPC pass with wakeup tags), synthesis and `opt_design` with the hierarchy kept, without and with `AreaOptimized_high`. Both runs come from one snapshot.

| Instance | Hierarchy kept | + `AreaOptimized_high` | Saved |
|---|---|---|---|
| `u_lsu` | 17,819 | 16,157 | −1,662 (−9.3%) |
| `u_ex` | 8,636 | 7,984 | −652 (−7.5%) |
| `g_p4.u_p4` (FP back end) | 7,853 | 7,333 | −520 (−6.6%) |
| `u_is` | 5,357 | 4,874 | −483 (−9.0%) |
| `u_fetch` | 5,257 | 4,966 | −291 (−5.5%) |
| `u_rn` | 4,541 | 4,324 | −217 (−4.8%) |
| `u_rob` | 3,308 | 3,078 | −230 (−7.0%) |
| `u_csr` | 1,855 | 1,715 | −140 (−7.5%) |
| `u_de` | 1,677 | 1,437 | −240 (−14.3%) |
| **Core** | **56,461** | **52,024** | **−4,437 (−7.9%)** |

- Every unit saves 5–14%; flip-flops (23,091 / 23,074) and LUTRAM (6,624) do not change.
- **Timing is measured only on the scheduler** (§3, §3.1), where the pair closes 200 MHz with margin. The core's own implementation runs are the check for the rest.
- **Memory:** this synthesis peaks at 9.4 GB with its helper processes (2 threads), against 6.8 GB without the directive (§6).

## 5. Fill test at 180 MHz

**These are measurements only:** the target clock stays 200 MHz unless the user approves a lower one (DR-137), and gate 3 and every v1 full-chip check run at 200 MHz.

**Method:** the S6 full-device design ([spikes.md](spikes.md) §8): two cores of spike structures plus the uncore, a synthetic filler sized to the target fill of the XCK26's 117,120 LUTs, implemented at 5.556 ns (180 MHz). D18 asks how full the device can get at about 180 MHz before IPC-costing levers are needed. The cores take the spike verdicts (min/max off the 1-cycle ALU, alignment in M2, MX everywhere), unlike the 200 MHz runs of spikes.md §8; "with tags" means the AR-1 scheduler (`S2_WTAGS = 16`).

| Run | Config | Target | CLB LUTs (fill) | WNS ns | Fmax MHz | Worst path | Route |
|---|---|---|---|---|---|---|---|
| `s6_smt2w3t_93_180` | smt2_w3 (v2), with tags | 93% | 110,280 (**94.2%**) | **+0.049** | **181.6** | harness: a filler register feeding S3's register file from across the die (1 level, 5.08 ns of wire) | 19 min |
| `s6_smt2_93_180` | smt2 (v1), ROB columns (no tags) | 93% | 109,422 (93.4%) after synthesis | — | — | **routing did not converge**: the router's first iteration took 2 h (114,671 overlapping nodes down to 21) and the second was under way when the run was stopped ([route_stuck.txt](../../fpga/spikes/results/s6_smt2_93_180/route_stuck.txt)) | > 2 h |
| `s6_smt2t_93_180` | smt2 (v1), with tags | 93% | 109,364 (**93.4%**) | **+0.137** | **184.5** | harness: a filler register driving S5's reset fan-out (0 levels, 4.84 ns of wire); worst real path S3's ALU loop, +0.276 | 15 min |
| `s6_smt2t_95_180` | smt2 (v1), with tags | 95% | 111,633 (**95.3%**) | **+0.126** | **184.2** | S5: IF2's page number → IF3's instruction marks, 8 levels | 16 min |
| `s6_smt2w3t_96_180` | smt2_w3 (v2), with tags | 96% | 112,441 (**96.0%**) | **+0.071** | **182.3** | S3: ALU → bypass → ALU, 9 levels | 24 min |
| `s6_smt2w3t_90_180` | smt2_w3 (v2), with tags | 90% | 105,403 (**90.0%**) | **+0.054** | **181.8** | S5: IF2 → IF3 marks, 8 levels | 15 min |

Named paths, slack in ns at 5.556 ns (the worst over both cores):

| Path | v2 with tags, 94.2% | v1 with tags, 93.4% | v1 with tags, 95.3% | v2 with tags, 96.0% | v2 with tags, 90.0% |
|---|---|---|---|---|---|
| S2: wakeup loop | ≥ +2.551 (the group's worst is a filler-driven reset) | ≥ +2.693 (the same) | ≥ +0.926 | ≥ +1.001 | ≥ +1.351 |
| S2: issue payload | +1.100 | +1.911 | +1.392 | +1.323 | +1.323 |
| S3: ALU → bypass → ALU | **+0.178** (9 levels) | **+0.276** (10 levels) | **+0.334** | **+0.129** (12 levels; the run's worst, +0.071, is in the same loop) | +0.304 |
| S3: register-file read | +0.049 (the harness route above) | +0.474 | +0.723 | +0.728 | +0.320 |
| S4: M2 compare, select, result | +0.379 | +0.310 | +0.707 | **+0.142** | **+0.129** |
| S4: DTLB lookup in M1 | +0.610 | +0.899 | +0.628 | +0.256 | +0.459 |
| S5: next-PC loop | +0.729 | ≥ +0.214 (a filler-driven reset) | +0.958 | +1.501 | ≥ +1.546 |
| S5: next PC → I$ BRAM address | +0.200 | +0.876 | +0.510 | +0.480 | +0.386 |
| S5: IF3 compaction → instruction queue | +0.186 | +1.067 | +0.689 | +0.573 | +0.976 |
| S5: IF2 page number → IF3 marks (not a named group) | — | — | **+0.126** (the run's worst) | — | **+0.054** (the run's worst) |
| L2: UltraRAM cascade input | +0.344 | +1.965 | +1.627 | +1.020 | +0.946 |
| Core → L2 bus | +3.279 | +2.932 | +3.677 | +4.015 | +3.383 |
| Synthetic logic | +0.665 | +0.518 | +0.710 | +0.697 | +0.740 |

**Findings.**
- **v1 with tags closes 180 MHz at 93.4% and 95.3% fill** (109.4K and 111.6K LUTs; +0.137 and +0.126 ns). **v2 with tags closes it at 90.0%, 94.2% and 96.0%** (+0.054, +0.049, +0.071 ns).
- **Slack does not trend with fill** between 90% and 96%. The limits are logic loops (S3's ALU loop, S5's IF2 → IF3 step, S4's M2 stage), not congestion, as at 200 MHz (spikes.md §8). Routing takes 15–24 minutes, and the placer's worst congestion is at most level 5.
- **The ceiling is above the highest fill tested:** at 180 MHz v1 fits at least 111.6K LUTs (95.3%) and v2 at least 112.4K (96.0%), against about 103K (88%) for v1 at 200 MHz. §5.1 later measured v1 at 99.3% (116.3K) at 180 MHz.
- **The scheduler is no longer near the limit.** Its wakeup loop has at least 0.9 ns at every fill (the groups' worst paths start at the harness's filler registers), where before tags it set the 200 MHz limit.
- **v1 with the ROB-column scheduler did not route at the same fill (93.4%)** in over 2 hours. With tags (40 readiness columns per row instead of 104) the same core at the same fill routes in 15 minutes. v1 without tags at 90% was stopped during placement, since no decision depends on it.

### 5.1 Fill test at 150, 160, 170, 180 and 200 MHz

**These are measurements only:** they are for the user's clock decision (DR-137), and the target stays 200 MHz until the user approves a lower one.

**Question (the coordinator):** at each of 150, 160, 170, 180 and 200 MHz, the highest fill at which v1 closes, the LUTs that fill allows, and the worst path, with AR-5's method, so the bars compare across the five clocks.

**Method:** §5's, unchanged. The S6 design with v1 (`smt2`) cores with tags, implemented with only the clock changed. Each fill uses the same generics at every clock (`CORE_TILES` 768, 800, 832, 849 and 865 for the 93, 95, 97, 98 and 99% targets), the flow is deterministic (Vivado's default seed), and a run passes when its routed WNS is ≥ 0. The 180 MHz runs of §5 (a540d99, 91b5191) and these (1d9391d to e0ff7b8) read the same S6 sources: what changed in between are primitives the S6 build does not use and report-only script changes. The 93% fill gives 109,364 LUTs at 180 MHz and 109,407 at 200.

| Clock | Highest fill that closes | CLB LUTs | WNS ns (Fmax) | Its worst path | The next fill up |
|---|---|---|---|---|---|
| 150 MHz | **99.3%** (the device: 819 LUTs left) | **116,301** | +0.459 (161.1 MHz) | S5: IF2 page number → IF3 instruction marks, 8 levels (5.2 of 6.1 ns is wire) | none: the device is full |
| 160 MHz | **99.3%** (the device) | **116,295** | +0.262 (167.0 MHz) | S4: M2 page number → load data, 7 levels (4.2 of 5.5 ns wire) | none: the device is full |
| 170 MHz | **99.3%** (the device) | **116,306** | +0.250 (177.6 MHz) | harness: a filler register into S4's probe tags (1 level, 5.0 ns of wire); the worst real path is S4's M2 stage, +0.272 | none: the device is full |
| 180 MHz | **99.3%** (the device) | **116,318** | +0.179 (186.0 MHz) | harness: a filler register into S2's queue-room counter, 11 levels; the worst real path is S4's DTLB lookup, +0.230 | none: the device is full |
| 200 MHz | **93.4%** | **109,407** | +0.037 (201.5 MHz) | S5: IF2 page number → IF3 instruction marks, 7 levels (3.4 of 4.8 ns wire) | 95.3% misses by 0.037 ns, on the harness's filler → S2 room-counter path (11 levels); its worst real path has +0.077 |

All the runs (v1 with tags):

| Run | Clock | CLB LUTs (fill) | WNS ns | Worst path | Place / route |
|---|---|---|---|---|---|
| `s6_smt2t_98_150` | 150 MHz | 115,162 (98.3%) | +0.492 | S3: the load write-back valid → a register-file write enable (0 levels, 5.8 ns of fan-out wire) | 12 / 24 min |
| `s6_smt2t_99_150` | 150 MHz | 116,301 (99.3%) | +0.459 | S5: IF2 → IF3 marks, 8 levels | 15 / 25 min |
| `s6_smt2t_99_160` | 160 MHz | 116,295 (99.3%) | +0.262 | S4: M2 page number → load data, 7 levels | 12 / 35 min |
| `s6_smt2t_98_170` | 170 MHz | 115,175 (98.3%) | +0.183 | S4: M2 tag compare → load data, 7 levels | 17 / 31 min |
| `s6_smt2t_99_170` | 170 MHz | 116,306 (99.3%) | +0.250 | harness: filler → S4's probe tags, 1 level | 11 / 25 min |
| `s6_smt2t_93_180` (§5) | 180 MHz | 109,364 (93.4%) | +0.137 | harness: a filler register driving S5's reset fan-out | 12 / 15 min |
| `s6_smt2t_95_180` (§5) | 180 MHz | 111,633 (95.3%) | +0.126 | S5: IF2 → IF3 marks, 8 levels | 13 / 16 min |
| `s6_smt2t_97_180` | 180 MHz | 113,952 (97.3%) | +0.071 | S4: M2 page number → load data, 7 levels | 12 / 27 min |
| `s6_smt2t_98_180` | 180 MHz | 115,174 (98.3%) | +0.057 | harness: filler → S2's queue-room counter, 11 levels | 14 / 25 min |
| `s6_smt2t_99_180` | 180 MHz | 116,318 (99.3%) | +0.179 | harness: filler → S2's queue-room counter, 11 levels | 14 / 33 min |
| `s6_smt2t_93_200` | 200 MHz | 109,407 (93.4%) | +0.037 | S5: IF2 → IF3 marks, 7 levels | 16 / 15 min |
| `s6_smt2t_95_200` | 200 MHz | 111,652 (95.3%) | **−0.037** | harness: filler → S2's queue-room counter, 11 levels | 15 / 23 min |

**Findings.**
- **From 150 to 180 MHz the device is the limit:** 99.3% (116.3K of 117,120 LUTs, about 800 left) closes at every one of the four clocks, with +0.459, +0.262, +0.250 and +0.179 ns at 150, 160, 170 and 180 MHz. No higher fill can be tested.
- **At 200 MHz the ceiling is about 94%.** 93.4% closes by +0.037 ns and 95.3% misses by 0.037, on a path that starts in the harness's filler; that run's worst real path has +0.077. Both are within a few tens of picoseconds of zero, and runs move by ±0.1–0.3 ns (spikes.md §12.2), so the ceiling lies between them.
- **So a lower clock buys about 7K LUTs, and 180 MHz buys all of it:** the bar is 109.4K (93.4%) at 200 MHz and the whole device (116.3K, 99.3%) at 180 MHz and below. Where between 180 and 200 MHz the step lies was not measured.
- **Margin does not trend with fill at a given clock** (180 MHz: +0.137, +0.126, +0.071, +0.057 and +0.179 ns from 93.4% to 99.3%), as §5 found from 90% to 96%.
- **The same few paths limit every clock,** all inside the spike structures and mostly wire: S5's IF2 page number → IF3 instruction marks (7–8 levels), S4's M2 compare and select → load data (7 levels), S3's ALU loop (8–10 levels), and, from the harness, S2's queue-room counter. Wire is 70–86% of each worst path. Placement takes 11–17 minutes and routing 15–35 at every fill.
- **What this measures.** S6's cores are the spike structures with their verdicts (§5); the real core's own deep paths miss 200 MHz by 5–7 ns today (the core track's whole-core runs), and that work is separate. These bars are what the device allows once the core's paths are as short as the spikes'.

## 6. Memory of the Vivado runs

Measured by sampling every 20 s the proportional set size (PSS) of each job's Vivado process and all its descendants, so shared pages count once and synthesis helpers count. Synthesis uses 2 threads (`TANAGER_SYNTH_THREADS`).

| Job | Peak PSS | Processes at the peak | Declared |
|---|---|---|---|
| S6 full device, 90–96% fill (synthesis is the peak) | **12.9–14.3 GB** | 10 | 10 GB |
| S6 full device, implementation (place and route) | 9.7–9.8 GB | 1 | 10 GB |
| `tg_core` st, hierarchy kept | 6.75 GB | 10 | 6 GB |
| `tg_core` st, hierarchy kept + `AreaOptimized_high` | 9.38 GB | 10 | 6 GB |

- **A full-device synthesis with 2 threads needs about 14 GB, not 10.** Vivado's log reports only the parent process; summed with its synthesis helpers, the job peaks during synthesis at 13–14 GB. Place and route run in one process at about 10 GB.
- The whole core at st needs 7 GB as built until now and 9.4 GB with `AreaOptimized_high` (DR-113). The larger configurations need more.
- **What changed:** the spike workers declare 15 GB for S6 runs, and the budget flow declares 12 GB for the core (`fpga/budget/units.tsv`), which it now builds with DR-113's settings.
