# Tanager: area-recovery study, synthesis side

*Plan §8.5, the area-recovery study under D18: IPC first. Step 1 is implementation tricks that cost no IPC; step 2 a lower clock, down to about 180 MHz, rather than smaller structures; step 3 the IPC-costing levers. This page is the synthesis side: what the no-IPC tricks save on the over-budget units, and how full the XCK26 may get at 180 MHz.*

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
| … `EARLY_W` 24 → 8 (only part of the source tags in flip-flops) | 8,637 | 272 (+80 LUTRAM, −720 FFs) | none if the RF stage can wait for the LUTRAM tags; timing run needed | promising |
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
  | st | 4,802 | (queued) | | | |
  | smt2 (v1) | 5,506 | **4,750** | −756 (−13.7%) | +0.218 → **+0.392** | 7 → 11 |
  | smt2_w3 (v2) | 7,703 | **6,669** | −1,034 (−13.4%) | +0.026 → **+0.094** | 7 → 11 |

  - The same −13% as without tags (§3), and timing improves rather than degrades. Flip-flops and LUTRAM do not change (5,208 / 240 at smt2).
  - The directive alone fails (§3): with a flattened design it restructures the wakeup loop across module boundaries and misses by 0.265 ns. With each queue kept as a module it cannot, so the loop keeps its margin. Use the two together or not at all.
  - The worst path moves off the wakeup loop (W → readiness → select → payload, 7 LUT levels) to a queue's room counter (`room_q`, 11 levels of which 2 are CARRY8), at more slack.
  - **The scheduler from ROB columns to tags plus both settings: 8,895 → 4,750 at smt2 (−47%) and 12,515 → 6,669 at smt2_w3 (−47%)**, with slack gained at both.

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

## 5. Fill test at 180 MHz

**Method:** the S6 full-device design ([spikes.md](spikes.md) §8): two cores of spike structures plus the uncore, a synthetic filler sized to the target fill of the XCK26's 117,120 LUTs, implemented at 5.556 ns (180 MHz). D18 asks how full the device can get at about 180 MHz before IPC-costing levers are needed. The cores take the spike verdicts (min/max off the 1-cycle ALU, alignment in M2, MX everywhere), unlike the 200 MHz runs of spikes.md §8; "with tags" means the AR-1 scheduler (`S2_WTAGS = 16`).

| Run | Config | Target | CLB LUTs (fill) | WNS ns | Fmax MHz | Worst path | Route |
|---|---|---|---|---|---|---|---|
| `s6_smt2w3t_93_180` | smt2_w3 (v2), with tags | 93% | 110,280 (**94.2%**) | **+0.049** | **181.6** | harness: a filler register feeding S3's register file from across the die (1 level, 5.08 ns of wire) | 19 min |
| `s6_smt2_93_180` | smt2 (v1), ROB columns (no tags) | 93% | 109,422 (93.4%) after synthesis | — | — | **routing did not converge**: the router's first iteration took 2 h (114,671 overlapping nodes down to 21) and the second was under way when the run was stopped ([route_stuck.txt](../../fpga/spikes/results/s6_smt2_93_180/route_stuck.txt)) | > 2 h |
| `s6_smt2t_93_180` | smt2 (v1), with tags | 93% | (queued) | | | | |
| `s6_smt2w3t_96_180`, `s6_smt2t_95_180` | v2 / v1 with tags | 96% / 95% | (queued) | | | | |
| `s6_smt2w3t_90_180` | v2 with tags | 90% | (queued) | | | | |

Named paths, slack in ns at 5.556 ns (the worst over both cores):

| Path | v2 with tags, 94.2% |
|---|---|
| S2: wakeup loop | ≥ +2.551 (the group's worst is a filler-driven reset) |
| S2: issue payload | +1.100 |
| S3: ALU → bypass → ALU | **+0.178** (9 levels) |
| S3: register-file read | +0.049 (the harness route above) |
| S4: M2 compare, select, result | +0.379 |
| S4: DTLB lookup in M1 | +0.610 |
| S5: next-PC loop | +0.729 |
| S5: next PC → I$ BRAM address | +0.200 |
| S5: IF3 compaction → instruction queue | +0.186 |
| L2: UltraRAM cascade input | +0.344 |
| Core → L2 bus | +3.279 |
| Synthetic logic | +0.665 |

**Findings so far.**
- **v2 with tags closes 180 MHz at 94.2% fill** (110.3K LUTs). The worst real paths are S3's ALU loop and S5's fetch (+0.18 to +0.20 ns); the scheduler, the 200 MHz limiter before tags, has more than 1 ns.
- The router started from 112K overlapping nodes and cleared them in 19 minutes; the placer's worst congestion is level 5.
- **v1 with the ROB-column scheduler did not route at 93.4%** in over 2 hours, where v2 with tags, a larger core, routed at 94.2% in 19 minutes. The v1 runs continue with tags, the scheduler the core takes (AR-1); v1 without tags at 90% was stopped during placement, since no decision depends on it.

