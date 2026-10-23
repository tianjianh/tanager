# M7: SMT2, the second hart in each core — the plan

Status: approved by the coordinator 10-19 23:20; DR-175 — core track (core-2) — 2026-10-19

M7 turns on the second hardware thread of each core, so v1 runs 2 cores × 2 harts = 4 Linux CPUs (plan §6, §6.5, §11's
M7 row; DR-008, DR-009, DR-010). This page records what the `smt2` build has today, what M7 adds and in what order, what
it costs, how it is checked, and who does what.

The facts below are from `main` at 12e50658 (2026-10-19), read from the RTL itself. Where a document says otherwise, §2.3
lists the difference.

## 1. Scope and exit criteria

**In scope** (plan §11, M7 row): the second hart; per-thread partitions and issue-queue caps; ICOUNT fetch; a second
CSR file and counters; thread-scoped flush and memory ordering; SMT-off at run time; per-hart lockstep; random tests aimed
at sibling interactions.

**Exit criteria** (plan §11):
1. Linux runs on the 2 harts of one core.
2. Weighted throughput ≥ 1.3× ST at every latency point (30, 120 and 250 cycles).
3. SMT-off works.
4. Litmus tests with sibling harts run clean.

M8 (SMP Debian on 2 cores × 2 harts) follows; this plan takes the four-hart boot under lockstep as M7's last check
because it costs little more than the two-hart one.

## 2. What the `smt2` build has today

### 2.1 What exists
- **The configuration and the window's sizes:** `TID_W = 1` (`tg_cfg_smt2.sv`): ROB 80, LQ 24, SQ 20, 24 long-latency
  tags, 75% issue-queue caps (`IQ_CAP_PCT`). Every unit builds and lints at `TID_W = 1` (lint-all: 4 configurations).
- **Thread IDs in the payloads:** `tid_t` is carried in `fe_insn_t`, `uop_t`, `iq_pl_t` and `rob_pl_t`
  (`tg_core_pkg.sv`), but **every source of it is the constant 0**: fetch writes `tid = '0` on every instruction
  (`tg_fetch.sv:1576`).
- **Real per-thread logic, five places, never exercised with tid 1:**
  - `tg_iq`: each row stores its tid; a kill is tid-scoped; `room_q[t]` (the cap less thread t's rows) is computed;
  - `tg_issue`: the speculative wakeup drops a tracked load only for the flushed thread;
  - `tg_fp_exec`: P4's stages, shadow pipelines, divide table and bank-1 queue are tid-scoped;
  - `tg_fcsr`: frm, fflags and the early-retire counter are per-hart arrays;
  - `tg_ubtb`: entries store a tid and the hit compares it.
- **The uncore is per hart already:** the ACLINT has a `msip` and `mtimecmp` per hart (`tg_aclint`), the PLIC two
  contexts per hart (`tg_plic`, `N_CTX = 2 × NUM_HARTS`), and `tanager_soc` wires each hart's MEI, SEI, MTI and MSI to its
  core, indexed `core × NUM_THREADS + tid`. The L2 has one agent per core; harts share their core's ports (l2.md).
- **Hart IDs:** `mhartid = core × NUM_THREADS + tid` (interfaces.md §1), so core 1's thread 0 is hart 2.
- **Lockstep's checker** takes up to 4 harts: one Spike per hart, records applied in cycle order, windows for other
  harts' writes (verification.md §3.1–§3.7). Its self-test interleaves 2 and 4 harts.
- **How the board runs today:** two smt2 cores with one hart each (harts 0 and 2). The device tree lists `cpu@0` and
  `cpu@2` only (`sw/dts`, `RUN_THREADS=1`). The one thread gets the whole smt2 window, so the board's core is "a bigger
  single-thread core until M7" (area_recovery.md §6.12).

### 2.2 What is stubbed or missing

Hart 1 never fetches; it is not parked by software but absent from the RTL's thread sources and from the device tree.

| Unit | Today (single thread) | M7 needs |
|---|---|---|
| Fetch | one PC (`fpc_q`), one speculative and one committed global history, one FTQ, one RAS (`tg_ras` has no tid port), one instruction queue; no thread selection | a PC, history, FTQ, RAS and instruction queue per thread; a fetch thread select (ICOUNT); per-thread redirect and park |
| Predictors | TAGE and the BHT have no tid; the micro-BTB has one but sees 0 | real tids; TAGE and the BHT may hash the tid (plan §6.2 rule 6) |
| Decode | one set of CSR state read; its redirect carries no tid | per-hart CSR state; a tid on the redirect |
| Rename | one integer and one FP map (32 entries); shared circular free lists whose flush recovery returns the speculative head to the commit head; one ROB/LQ/SQ tail each, against the whole sizes; no checkpoints (every recovery is at commit) | maps per thread; a free-list recovery that works per thread; homes and reset values for hart 1's 32 + 32 architectural registers; per-thread window allocation; a thread choice at rename and dispatch |
| Issue | caps computed, then discarded (`tg_issue.sv:446`: `assign unused = ^{room, wn}`); the ALU, P0, P1 and STA payload formats drop the tid | the 75% caps applied at dispatch; the tid kept where a kill needs it |
| Exec | no tid; a flush clears every stage | a thread-scoped kill |
| LSU | one LQ and one SQ, no tid; forwarding and the ordering check match by address only; one LR reservation, which no store drain clears; atomics and MMIO at the single ROB head | per-thread halves; forwarding and ordering within a thread; a reservation per hart, cleared by the sibling's stores; fairness between the harts in the store drain and the load replays |
| MMU | TLBs without ASID or tid tags; SFENCE.VMA and any satp change flush everything; one `satp` at the walker; three PMP checkers reading one descriptor set | entries tagged by tid; a flush per hart; per-hart satp; per-hart PMP descriptors with a select at each checker |
| CSR | one hart (`tg_csr.sv:6`: "per-hart arrays arrive with M7"); `mhartid` constant; only bit 0 of each interrupt input used; one `stimecmp`, one `mcycle`/`minstret` | hot state per hart; the cold LUTRAM table and `pmpaddr` with a tid address bit; `mhartid + tid`; per-hart interrupts, timer compare and counters |
| ROB | one circular ROB; the payload's tid written but never read; one exception, mispredict, xRET and WFI state; `flush_tid = '0` | static halves with per-thread pointers; per-thread exception and serialisation state; a commit choice between threads; a real `flush_tid` |
| FPU | P4 and fcsr are per thread; tg_core drives fcsr's tids with 0 | the tids wired |
| Trace | `tr_rec_t.hart` is the constant hart 0 of the core | the committing thread's hart |
| Core-wide stalls | empty-window serialisation, the SQ drain for FENCE and SFENCE, `mmio_busy`, `trace_stall` | per thread where a sibling must not wait |

### 2.3 Documents that disagree with the RTL
These say M7's partitions or tags exist. M7's first commit corrects them:
- `docs/perf/hart1_ram_form.md` rules 3 and 4: the ROB, LQ, SQ and LLTs are "already partitioned … static halves", and
  the TLBs are {TID, ASID}-tagged. Neither is built, so that brief's 3.7K a core leaves out the partitions (§4.2).
- `core-mmu.md:72` (TLB entries tagged with the thread), `core-lsu.md:27` (the LSU flush "with tid"),
  `core-pipeline.md:29` ("tid ports … everywhere") and `:302` (`mhartid` "+ tid").
- The plan: §6.1 ("The L2 supports 4 agents: 2 cores × 2 harts"; l2.md has one agent per core) and the hart numbering of
  §3.1 and §7.2.
- **The merge message of 12e50658** says "the four-hart Linux boot under lockstep passes (both threads of both
  cores)". No four-hart shape exists (`boot_lockstep.py` has `st` and `board`), and hart 1 never fetches, so that boot ran
  harts 0 and 2.

## 3. What M7 adds, and in what order

### 3.1 Decisions to take first

| # | Question | Recommendation | Why |
|---|---|---|---|
| D1 | The window: static halves, or shared with 75% caps | **Static halves** (DR-009) for the ROB, LQ, SQ and completion buffer, with per-thread pointers | The shared window's +2.7% needs age-ordered ROB and LSQ logic across threads that nobody has costed (smt2_report §5); halves keep every age comparison inside a thread (plan §6.2 rule 3) |
| D2 | What a lone thread gets | **The whole window while its sibling sleeps:** the halves merge when the sibling has spent `N` cycles in WFI with an empty half, and split, after a drain, when it wakes. An M-mode control can also hold hart 1 off (SMT-off for security, plan §6.2 rule 10) | Static halves alone cost a lone thread −3.6% on the suite (smt2_report §10). Linux's idle loop and OpenSBI's stopped harts both sit in WFI, so this needs no software change. Intel's Hyper-Threading recombines partitioned resources the same way when a logical processor halts (Marr et al., 2002). WFI's 4,096-cycle timeout would wake a parked hart every 4K cycles, so its policy changes with this (§3.2, step 6) |
| D3 | Free-list recovery per thread | **A free list per thread in each bank,** in RAM form (`{tid, index}`), each with its own heads and tail; a register freed at commit returns to its thread's list. **Revised 10-20:** plus non-speculative transfers: a hart that cannot rename for want of a bank's register takes one committed-free register a cycle from the tail of its sibling's list (the donor keeps 1), so a sibling asleep in WFI gives up its spares; and FP banks of 96 entries in SMT2 builds | Today's recovery (speculative head back to the commit head) cannot undo one thread's allocations in a list both threads allocate from; a walk of the ROB at every flush costs cycles on every recovery (−0.5 to −2.6% in the model). A static division alone deadlocks: the banks are writer-sharded, so a hart can need all its architectural registers plus one in one bank, and an FP bank of 64 cannot hold both harts' 32 plus one. With transfers and FP banks of 96 the model finds no deadlock (87 pairs, two-hart FP restores among them, and 36 lone-hart programs) and the throughput of ideal shared lists (0.22–0.26 transfers per 1,000 instructions); 96 and 128 entries are identical (smt2_report §13.9). **Revised 10-21 (DR-179):** FP banks of 64 again, an FP op renaming into the other bank when its own has no register left for its hart (no deadlock in 90 pairs and 37 lone programs; the same cycles as 96 with a same-cycle crossed write; smt2_report §13.13, §13.17) |
| D4 | Homes for hart 1's architectural registers | Integer x1–x31 in bank 1 (indices 0–31) and FP f0–f31 in F1, zeroed by the reset sequence through those banks' write ports. Hart 1's x0 maps, as hart 0's does, to bank 0's register 0: zeroed at reset and never written, since rename gives rd = x0 no register | Each of banks 0 and 1 keeps 32 free registers at reset instead of one bank having none; Spike's lockstep starts registers at zero |
| D5 | Checkpoints | **None in M7,** as today: recovery stays at commit | The core has no checkpoints. The plan's M2 table put them at M6, and M6 has not built them. M7 adds no second set. If a later step adds checkpoints, sharing them between the threads is DR-076's R10 (−0.5K a core, −0.01% in the model) |
| D6 | PMP per hart | **A descriptor set per hart, selected by the requesting thread at each of the three checkers** (fetch, LD, STA, which the walker shares since DR-139) | The ISA makes PMP per hart. It is the largest item (§4.2). Caching M-mode results in the TLBs to need fewer checkers is a reserve lever (hart1_ram_form.md), the user's call (DR-135) |
| D7 | Fetch policy | **ICOUNT at fetch only;** decode, rename and commit alternate the thread served first and let a thread use slots its sibling leaves | The study's choice (§6.5): ICOUNT at rename starves a thread waiting on misses; round robin at fetch costs −0.5%. **Refined 10-20 (DR-175):** one thread per group at decode, rename and commit, the first-served thread alternating and an idle one skipped; mixed groups (a thread taking the slots its sibling leaves) only if the model shows them gaining 1% or more weighted throughput (DR-154's rule), since they cost a second head window's reads at commit and both threads' pops at rename (threading.md) |
| D8 | Store drain and load replays | **Per-hart fairness:** alternate the harts' SQ heads in the drain and the harts' replays | The model deadlocked five thread pairs without it (plan §8.5 note) |

### 3.2 The steps, in order

Hart 1 is behind a switch (`HART1_ON`, tg_core_pkg, `TG_HART1=0|1`), added at step 5 and off by default until step 8's
checks pass. Every step merges with it off, so the smt2 core runs one thread on the whole window as today, and `make
cycle-identical` against main must pass (merged mode is today's core). From step 5 the checks also run with it on.

| Step | What | Depends on | Owner |
|---|---|---|---|
| 1. **Threads through the pipe** | the tid in every payload that a kill needs (the ALU, P0, P1 and STA formats); a real `flush_tid` and thread-scoped kills in every unit (fetch, decode, rename, exec, LSU, ROB, the free lists, the LLT and wakeup-tag pools); per-thread serialisation (the empty-window wait becomes the thread's half); docs of §2.3 corrected | — | core-2; fpu-2 for issue and exec |
| 2. **Per-hart architectural state** | CSRs (hot state per hart in flip-flops; the cold table and `pmpaddr` with a tid address bit; `mhartid + tid`; per-hart interrupt inputs, `stimecmp`, trap entry and xRET for the committing thread; `mcycle`/`minstret` as DSP pairs per hart, R1); fcsr's tids wired; PMP descriptors per hart with the select (D6); the trace's hart field and load address (§5) | — | core-2; soc-2 checks the interrupt lines (already per hart) |
| 3. **The window per thread** | static halves of the ROB, LQ, SQ and completion buffer with per-thread pointers and a merged mode (D1, D2); per-thread rename maps (tid address bit, measured +0.43K) and free lists (D3); homes and reset values for hart 1's registers (D4); a rename, dispatch and commit thread choice (D7); per-thread exception, mispredict, xRET and WFI state | 1 | core-2 |
| 4. **Memory and translation per thread** | TLB entries tagged by tid; satp writes and SFENCE.VMA flush the hart's entries; the walker takes per-hart satp; forwarding and ordering stay inside a thread's half; a reservation per hart, cleared by the sibling's committed stores as by a probe (plan §6.2 rule 4); store-drain and replay fairness (D8); atomics and MMIO at the thread's ROB head | 1, 3 | core-2 |
| 5. **The front end per thread, and hart 1's switch** | a PC, global history, FTQ and RAS per thread (tid address bits; the history and PC in flip-flops), the instruction queue in RAM form, per-thread redirect and park; round robin first, then ICOUNT (D7); real tids into the micro-BTB, TAGE and the BHT hash; with `HART1_ON`, hart 1 fetches from reset (interfaces.md §1: both harts start, software parks hart 1 through OpenSBI's HSM) | 1–4 | core-2 |
| 6. **SMT-off** | the merge when the sibling sleeps in WFI, the split after a drain when it wakes (D2), with WFI's timeout raised for a parked hart; the M-mode control that holds hart 1 off. As built (core-pipeline.md §8.5): a WFI waiting 64 cycles beside an awake sibling retires and its thread sleeps; the runner's tails stop wrapping and the halves merge around its window; a wake waits until the runner's window fits its half or empties; a sleeper wakes on its interrupt, or after 2^24 cycles while it has one enabled (with none, a parked hart sleeps until reset); `mtgsmt` (0x7C0) bit 0 keeps hart 1 asleep | 3, 5 | core-2 |
| 7. **Caps and throughput** | wire `tg_iq`'s `room_q` out of `tg_issue` and into rename's dispatch check and steering (75%); measure weighted throughput against ST at 30, 120 and 250 cycles; tune ICOUNT and the caps | 5 | fpu-2 (`tg_issue`), core-2 (rename), smt2-study |
| 8. **Bring-up and checks** | §5's checks with `HART1_ON`; the device tree with `RUN_THREADS=2`; Linux on the two harts of one core, then on four harts; then `HART1_ON` on by default | 5 (and 6, 7 for the exit) | verif-2, soc-2, core-2 |

Steps 1 and 2 are independent and can go in parallel; 3 and 4 follow 1; 5 needs 1–4; 6 and 7 follow 5. Every step is
an MR of its own, cycle-identical to main with hart 1 off, with the traced Linux boot under lockstep (DR-173) for those
that reach fetch, rename, the LSU, the MMU or the CSRs.

## 4. Area

### 4.1 Today: smt2 against st (measured, main 60c9c28, budget flow, whole core)

| Unit | st | smt2 | smt2 − st | What it is |
|---|---|---|---|---|
| LSU | 10,316 | 11,859 | +1,543 | LQ 24 and SQ 20 against 16 and 12 |
| ROB | 2,217 | 2,924 | +707 | 80 entries against 48 |
| Issue | 4,811 | 5,136 | +325 | spread over every queue (+30 to +94 each): consistent with 8 more wakeup columns (24 long-latency tags against 16), wider ROB fields and the tid in each row (MX is in every configuration) |
| Rename | 2,871 | 3,130 | +259 | rename's own logic (+169: the larger tag pool, wider ROB, LQ and SQ indices); the maps and free lists are unchanged |
| CSR | 1,256 | 1,294 | +38 | |
| Fetch, decode, exec, FPU | | | ±40 | nothing per thread |
| **Core** | **44,448** | **47,303** | **+2,855** | flip-flops +1,431 |

The smt2 core is already 1,183 over its 46,120 budget (`fpga/budget/budgets.tsv`) without any hart 1 logic: the
window's sizes, and M6's features, which arrived after the budgets.

### 4.2 Hart 1's logic, estimated per step

RAM form throughout (conventions §7, DR-125): per-thread tables take the tid as an address bit; state read every cycle
stays in flip-flops, one copy per hart. Measured items are marked.

| Step | Piece | LUTs a core | Basis |
|---|---|---|---|
| 1 | tids in payloads, thread-scoped kills, per-thread serialisation | ≈0.25K | judged; mostly AND terms on existing kills |
| 2 | CSRs: hot state and its selects, interrupts, timer, trap and xRET | ≈0.55K | hart1_ram_form's 0.4K + 0.15K; the cold table and `pmpaddr` fit their RAM32M16 at 32 deep: 0 |
| 2 | PMP descriptors and the select at three checkers | **≈0.86K** | **measured** at 16 entries: +576 a checker, 1,728 (hart1_ram_form); halved at PMP-8 (DR-167) |
| 2 | counters | ≈0.03K and 4 DSPs | `tg_dsp_ctr` pairs (R1) |
| 3 | rename maps, integer and FP | **+0.43K** | **measured** (hart1_ram_form) |
| 3 | per-thread free lists (pointers, RAM form), renamed-since-flush bits, per-thread tails and counts | ≈0.35K | judged |
| 3 | ROB and LSQ halves with the merged mode; per-thread exception, mispredict, xRET and WFI state; the thread choices | ≈0.8K | the study's "TID tags and partitions" 0.5K, plus the merged mode and the per-thread ROB state (judged) |
| 4 | TLB tags and per-hart flush, the walker's satp | ≈0.15K | the study's MMU TID, 0.1–0.3K |
| 4 | forwarding and ordering per thread, reservation per hart, the sibling's stores, drain and replay fairness, per-thread head for atomics and MMIO | ≈0.4K | the study's 0.1K for the snoop and LR, plus fairness and the heads (judged) |
| 5 | PC, history, FTQ, RAS, instruction queue, redirect and park per thread | ≈0.45K | hart1_ram_form: FTQ 50, RAS 30, history and PC 0.2K, queue pointers; plus redirect and park |
| 5 | ICOUNT, occupancy counters | ≈0.3K | the study's central value |
| 5 | FP banks of 96 entries (D3 revised; replaced by DR-179's crossing, ≈0.3K) | ≈0.45K | the FP file's LUTRAM ×1.5 (a 64 + 32 composition a bank, new in `tg_ram_lut`); its lists and map index a bit wider |
| 5 | free-list transfers between the harts' lists (D3 revised) | ≈0.05K | judged: a read at the sibling's list tail and a write at the starved list's tail, a bank |
| 6 | SMT-off: the WFI-triggered merge and split | ≈0.1K | judged |
| 7 | the issue-queue caps at dispatch | ≈0.1K | judged; `room_q` exists |
| | **Total** | **≈5.3K (4.3–6.5K)** (≈4.8K before D3's revision, 10-20) | |

For comparison:
- the model's second-copies estimate was 6.4K (4.3–8.8K), with 2.0K of it for a second CSR file and 1.0K for
  counters that the RAM form and R1 make nearly free;
- hart1_ram_form's RAM form was 3.7K, without the partitions it took as built (§2.3) and with the 16-entry PMP select.

### 4.3 Against the filler, the budget and DR-174's reserve
- **The filler:** every full-chip fit since 10-15 carries hart 1 as filler, 3,714 LUTs placed a core
  (`g5_fill_patch.py`; spikes.md §8.6), 7.4K a chip (DR-167's reserve). §4.2 puts the real logic ≈1.6K a core above it,
  ≈3.2K a chip, with real wiring between units, which the filler does not have (spikes.md §8.9).
- **The chip:** tier B (spikes.md §8.16) placed 111,217 LUTs (95.0%) with URF off and the filler. Real hart 1 would put
  it near 114.4K (≈97.7%), above where §8.13's M6 set fitted at +0.348 ns (97.1%). With the URF on, 108,693 (92.8%)
  becomes about 111.9K (≈95.6%).
- **So DR-174's reserve is likely needed.** M7's measured area decides it, step by step: each step's MR reports its
  budget-flow LUTs against §4.2's line, and the full chip with real hart 1 (spikes-2, after step 5) replaces the filler.
  The user has decided this already (DR-174: "lets do variant A if only where is run out of LUTs"), so turning URF on
  when the chip runs out is within DR-174. **Running out** means the full chip with real hart 1 placing above ≈96%, or
  missing 100 MHz; the coordinator tells the user when that happens. URF gives −1,262 placed LUTs a core in tier B. Smaller reserve items come after it: the FP register file's LUTRAM pump
  (−275 a core, the coordinator's study of 10-19) and the PMP-select cut (D6).
- **The per-core budget** (46,120) is already exceeded by M6's set, and M7 adds ≈5.3K more. The area decisions so far
  (DR-162, DR-167) have gone by the full-chip fit, not the per-core line.

## 5. Checks

| Check | What it needs | Owner |
|---|---|---|
| **Per-hart lockstep** | the checker runs two threads of one core: `--harts` 4 with all four stepping, the records of both threads interleaved in commit order. The trace needs a load's address for shared data across harts (verification.md §9 item 1, interfaces.md §5), as below | verif-2 (checker, trace format), core-2 (the RTL's trace fields) |
| **Random tests aimed at siblings** | `tg_rand` with two harts in one core: independent programs (partitions, thread-scoped flushes, caps, ICOUNT) and shared-memory programs (AMOs, LR/SC across siblings, message passing, stores to one line, FENCE); `gen_coh` with harts 0,1 on one core and 0–3 on two | verif-2 |
| **Litmus with sibling harts** | litmus-tests-riscv (the RVWMO suite) on two harts of one core and on four, in simulation and on the board with the latency injector at 0, 120 and 250 cycles (plan §9) | verif-2; soc-2 for the board runs |
| **The boot-lockstep gate, four harts** | a `boot_lockstep.py` shape of 2 cores × 2 threads with Linux on all four, beside `st` and `board`; the device tree with `RUN_THREADS=2` | verif-2 (shape), soc-2 (device tree, OpenSBI) |
| **Linux on the 2 harts of one core** (exit 1) | `tb_boot` with one core and two threads; then the board | soc-2, core-2 |
| **Weighted throughput ≥ 1.3× ST** (exit 2) | a pair runner: two programs, one per hart, cycles to finish against each alone on ST; the study's pairs at 30, 120 and 250 cycles of latency | verif-2 (runner), smt2-study (pairs, the model's prediction first) |
| **SMT-off works** (exit 3) | a lone hart with its sibling in WFI gets today's cycles (`make perf` against the one-hart smt2 core within noise); the M-mode control holds hart 1 off | core-2, verif-2 |
| **Litmus clean** (exit 4) | above | verif-2 |
| **Every step** | lint-all; regress st and smt2; cycle-identical to main with `HART1_ON` off; DR-173's traced boot; from step 5, the same with `HART1_ON` on | each step's owner |

**The trace's load address** (interfaces.md §5, v1.5 with the package; the coordinator's):
- **`mem_ld`, one new bit in `tr_rec_t`**, after `mem_st`: the retired instruction read memory. It is set on TR_RETIRE
  records of loads (integer and FP), LR, AMOs (with `mem_st` as well) and device loads (with `mmio_ld`).
- **The address:** when `mem_ld`, the existing `mem_vaddr` (64 bits) holds the load's virtual address and `mem_size` its
  size, log2 bytes. An AMO's read and write share them.
- **Not carried:** TR_TRAP and TR_IRQ records (a faulting load reports `tval`), SC (it reads no memory; its outcome is
  `rd`), and `tr_wb_t` (a deferred load's address is in its retire record).
- **Compatibility:** consumers read `mem_vaddr` only with `mem_st` today, so they are unaffected until they look at
  `mem_ld`. The board's 64-byte record needs one header bit for it (uncore-trace, soc-2); the address word is already
  there. A physical address (verification.md §9 item 2) stays out until it is needed.

## 6. Who does what
- **core-2:** steps 1–6 in rtl/core (except issue, exec and the FPU); the trace's hart field and load address; specs
  `core-*.md` and a new `docs/spec/threading.md` (plan §6.3's checklist, written as each step lands).
- **fpu-2:** the tid in the issue and exec payloads, thread-scoped kills in `tg_exec`, the caps out of `tg_issue` (step 7),
  and P4 under two threads.
- **verif-2:** per-hart lockstep, sibling random tests, litmus, the four-hart gate shape, the pair-throughput runner.
- **smt2-study:** before the RTL: the model with D2's merge policy, D3's register split and D8's fairness; ICOUNT
  against round robin and the cap level on the RTL-calibrated model; the throughput prediction that exit 2 is checked
  against.
- **soc-2:** device trees with `RUN_THREADS=2`, OpenSBI with four harts (HSM start and stop), `tb_boot`'s 1 × 2 and 2 × 2
  shapes, the board's four-hart bring-up, and the SoC's per-hart error interrupts (`merr`).
- **spikes-2:** the full chip with real hart 1 in place of the filler, after step 5, and with URF on if §4.3 calls for it.

## 7. Risks
- **Area:** ≈4.8K a core against a 3.7K filler; the chip is near full (§4.3). Mitigation: measure each step, URF ready.
- **Timing:** new selects on paths that close today: the PMP descriptor select in front of three checkers, the
  per-thread PC and history at F1, the per-thread pointers in rename's allocation. Each step's MR includes a whole-core
  timing run.
- **The register split** (D3) could bind FP-heavy pairs at 32 FP renaming registers a thread. smt2-study checks it
  first; the fallback is a shared FP free list with a flush walk.
- **Lockstep with two harts sharing memory** reports legal load-value differences without the load address in the trace
  (DR-093's con). The address (`mem_ld` with `mem_vaddr`, §5) goes in with step 2.
- **Estimate:** the plan gives M7 1–2 weeks. Steps 1–5 are most of it; with verif-2, soc-2 and smt2-study in parallel,
  2 weeks is the realistic end.

## 8. Provenance
- D. M. Tullsen, S. J. Eggers, J. S. Emer, H. M. Levy, J. L. Lo and R. L. Stamm, "Exploiting choice: instruction fetch
  and issue on an implementable simultaneous multithreading processor", ISCA 1996 (ICOUNT; fetch policies).
- S. E. Raasch and S. K. Reinhardt, "The impact of resource partitioning on SMT processors", PACT 2003 (static
  partitioning of queues).
- D. T. Marr et al., "Hyper-Threading Technology Architecture and Microarchitecture", Intel Technology Journal 6(1), 2002
  (partitioned queues recombined when one logical processor halts: D2).
- The RISC-V Instruction Set Manual, Volume II (WFI; PMP per hart; `mhartid`); Volume I (RVWMO, the memory model the
  litmus tests check).
- The RISC-V Supervisor Binary Interface Specification (the HSM extension: hart start and stop).
- litmus-tests-riscv (the RVWMO litmus suite).
- This project's own: plan §6, §6.5, §11; smt2_report.md; area_recovery.md §6.12; hart1_ram_form.md; spikes.md §8.6–§8.16.
  No other core's RTL was read.
