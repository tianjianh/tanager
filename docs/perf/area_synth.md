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

Synthesis and `opt_design` LUTs, smt2 with MX, against 8,909. The timing runs (200 MHz, pblock) of the synthesis settings are queued, so the timing effect is still open.

| Trick | LUTs | Saved | IPC cost | Status |
|---|---|---|---|---|
| Keep the hierarchy (`-flatten_hierarchy none`) | 8,403 | 506 (5.7%) | none | timing run queued |
| `AreaOptimized_high` synthesis directive | 8,115 | 794 (8.9%) | none | timing run queued |
| Both | **7,712** | **1,197 (13.4%)** | none | timing runs queued (smt2, smt2_w3) |
| No row-dependency matrix in the STA and FP queues (`MX_CQ`: their rows take the ID path, one cycle later for ALU producers) | 8,506 | 403 | near zero (int→FP moves, store addresses); the model session to confirm | tested in simulation |
| Less payload in flip-flops (`EARLY_W` 24 → 16, the rest in LUTRAM) | 8,813 | 96 (+80 LUTRAM) | none | small |
| … `EARLY_W` 24 → 8 (only part of the source tags in flip-flops) | 8,637 | 272 (+80 LUTRAM, −720 FFs) | none if the RF stage can wait for the LUTRAM tags; timing run needed | promising |
| Harness only: delay lines on the queues that really have delayed wakeups (`DL_Q`) | 8,663 | 246 | — | a harness artifact, not a saving in the core |
| Delay lines with predecoded IDs (`DL_ENC`) | 8,683 | −20 | — | does not help |

## 4. Fill test at 180 MHz

(being measured)
