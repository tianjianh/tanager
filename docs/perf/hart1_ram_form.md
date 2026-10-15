# Hart 1 in RAM form: a brief for M7

*For the core track, from the area-recovery study (area_recovery.md §7.7), 2026-10-14; updated 2026-10-15 for DR-139's three checkers.*
- **The rule:** conventions §7 (DR-125) builds new RTL with per-thread state as a RAM address bit, not a second copy in flip-flops.
- **This page:** what M7 adds for hart 1, the form each structure should take, and what each should cost. SMT2 is then built once, and the budget run can check it.
- **Status:** estimates, except where marked as measured. M7's first `smt2` synthesis with hart 1 replaces them.

## Rules

1. **A table read by index takes `tid` as an address bit** (fpga_friendly.md T1).
   - A table at most 16 deep takes it free, because RAM32M16 is 32 deep.
   - A 32- or 64-deep table doubles its primitives, because RAM64M8 holds half the bits per LUT of RAM32M16. But it needs no select logic and no second write port.
2. **State read in parallel, or by logic every cycle, stays in flip-flops,** one copy per hart.
   - Its cost is the select at every reader, not the flip-flops, which don't bind.
   - Keep the number of readers that need both harts small (see the PMP below).
3. **The window is already partitioned:** the ROB, LQ, SQ and LLTs are in static halves (D15). Nothing to add there; with hart 1 offline the halves merge (plan §6.2 rule 10).
4. **Shared structures stay shared:**
   - the predictors, which may hash in `tid` (rule 6);
   - the free lists, the ready tables and the physical registers;
   - the issue queues, with their 75% caps;
   - the caches;
   - the TLBs, whose entries are tagged {TID, ASID} (rule 5).
5. **Every flush, kill and redirect carries a `tid`** (rule 2). Per-thread flush state is cleared per thread.

## What hart 1 adds, per core (v1, `smt2`)

| Unit | Structure | Form | Hart 1's cost | Basis |
|---|---|---|---|---|
| Front end | FTQ (32 entries, arrives at M6) | LUTRAM, address {tid, index} | ≈50 LUTs | doubles at 32 deep; one set of read ports |
| | RAS (32, M6) | LUTRAM, {tid, index}; the top pointer per hart in flip-flops | ≈30 | as the FTQ |
| | Global history (M6), fetch PC | flip-flops per hart; the select at F1 | ≈0.2K | read every cycle (judged) |
| | Instruction queue (16 entries, 4 per bank) | the existing LUTRAM, {tid, index} | its pointers only | 4 → 8 deep still fits RAM32M16 |
| | ICOUNT, per-thread occupancy and caps | logic | ≈0.3K | the SMT2 study's central value |
| Decode | Decode-to-rename queue, 6 uops per thread | one LUTRAM, {tid, index} | ≈0.1K (pointers, valid bits) | 12 entries fit 32 deep |
| Rename | RAT and CRAT, integer and FP, every bank | LUTRAM, {tid, register}: 32 → 64 deep | **+0.43K** | **measured:** 432 LUTs of 32-deep RAM32M16 at `smt2` (2cf1cd9), doubled |
| | Renamed-since-flush bits, live-value tables | flip-flops per hart | ≈0.05K | 32 bits per hart each |
| | Checkpoints (M6) | LUTRAM versions behind a version pointer, {tid, version, register}; or shared (R10, reserve) | ≈0.1K, or 0 with R10 | a restore must stay one cycle (fpga_friendly.md §3) |
| CSRs (`tg_csr`) | Cold CSRs: xtvec, xscratch, xepc, xcause, xtval of M and S (built in fn2: one 16 × 64 LUTRAM, two read ports) | the same table, {tid, CSR}: 16 → 32 deep | 0 | fits RAM32M16; "at M7, hart 1's set is one more address bit" (core-pipeline §13). menvcfg, senvcfg, mcounteren, scounteren and mcontext can join it |
| | `pmpaddr0–15` | the existing LUTRAM, {tid, entry} | 0 | 16 → 32 deep fits RAM32M16 |
| | Hot CSRs: `priv`, mstatus, mie, mip's software bits, medeleg, mideleg, satp, stimecmp, fcsr, mcountinhibit | flip-flops per hart (about 200 bits); selects into the CSR read path and their users | ≈0.4K | read every cycle: status, satp, interrupts (judged) |
| | Interrupt pending per hart; trap entry and xRET for the committing thread | logic; Sstc's compare per hart (a DSP candidate, T6) | ≈0.15K | judged |
| | Counters: mcycle, minstret | DSP48E2 pairs per hart (R1, `tg_dsp_ctr`); the HPM counters read zero | 4 DSPs, ≈0.03K | R1 done |
| | **PMP region descriptors** (16 × 72 bits) | flip-flops per hart; each of the three `tg_pmp` checkers selects the requesting hart's set | **+1.7K** | **measured**, below |
| LSU | LR reservation; sibling stores on the snoop path | per hart, flip-flops | ≈0.1K | |

## The PMP descriptors: the largest item

**What they are.**
- `tg_csr` precomputes 16 region descriptors of 72 bits (`pmp_d_t`: the mode and permission bits, then `mask` and `a`, 32 bits each).
- All three `tg_pmp` checkers read them in parallel: fetch, LD, and STA, which the walker shares since DR-139 (core-mmu.md).
- LUTRAM can't serve state that is read all at once, so hart 1 needs its own 1,152 flip-flops.

**The cost is the select (measured).** Out-of-context synthesis with DR-113's settings, one descriptor set against two selected by the requesting hart (2026-10-14):

| Checker | One set | Two sets, selected by `tid` | Added |
|---|---|---|---|
| LD, STA, walker (S = 1) | 891 | 1,467 | +576 |
| Fetch block (S = 2) | 958 | 1,534 | +576 |

- **Three checkers: +1,728 LUTs per core** (+2,304 with four, before DR-139). That is exactly one LUT per two select bits: synthesis merges none of it into the compares.
- **Inside the checker is worse.** Flattened into it, the select cost more (1,878 at S = 1), so keep it a plain multiplexer in front.
- **Neither earlier estimate itemised it.** It is the same in both forms.

**Ways to cut it.** Each changes cycles or function, so each goes on the reserve list with its LUT saving and measured cycle cost, and only the user can adopt it (DR-135):
- **Cache PMP results for bare and M-mode accesses too,** tagged by hart, as the TLBs already cache them for S and U. One shared checker then serves misses, at a cost in cycles on misses.
- **Fewer checkers that see both harts.** The walker now shares STA's checker (the user, DR-139), which took the select from four checkers to three.

## Expected total

| | RAM form | Second copies |
|---|---|---|
| Everything but the PMP select | ≈2.0K (1.5–2.5K) | 4.2K (the budgets' SMT2 additions) |
| PMP descriptor select (measured) | +1.7K | +1.7K |
| **Hart 1, per core** | **≈3.7K** | **≈5.9K** |
| v1 with today's cores and uncore (§7.7) | ≈115.7K | ≈120.2K |

- **The RAM forms save ≈2.2K per core,** ≈4.5K per SoC, against copies.
- **The PMP select is where a better form would pay most.**
- `area_fit.py --hart1 ram` and `--hart1 copies` reproduce the two columns.

## How M7 checks it

- **The budget run:** the `smt2` core should grow by about the total above, and each unit by its rows. A unit that grows more names the structure to look at.
- **The primitive check:** each table above shows its new depth. For example, the maps become {2^6 × 8, 7 read} in RAM64M8. A table that doubles its primitive count where the brief says free, or stays in flip-flops where the brief says LUTRAM, is the first thing to check.
- **The unit spec** says which form each per-thread structure uses, and why when one stays in flip-flops (conventions §7).
