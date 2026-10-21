# Threading: the second hart of each core (`TID_W = 1`)

Status: M7 in progress (DR-175) — core track — updated at each M7 step

The rules every unit follows for SMT2 (plan §6.2), what is per thread in each unit now, and how the per-thread logic
is tested before hart 1 runs. The plan for M7 itself, its steps and their order, is
[m7-smt2-plan.md](m7-smt2-plan.md).

## Rules (plan §6.2)
1. `NUM_THREADS` and `TID_W` are global parameters (`tg_pkg`). `TID_W = 0` builds no SMT hardware: `tid_t` keeps one
   bit, tied to 0.
2. Every flush, kill and redirect carries a tid. Nothing flushes both threads except reset.
3. Age compares stay inside a thread: per-thread ROB and LSQ pointers, the issue queues' allocation-order matrices.
   Nothing subtracts ROB indices across threads.
4. Forwarding and ordering checks match the thread. A sibling's committed stores clear the reservation as a remote
   probe does.
5. TLB entries are tagged by thread; satp writes and SFENCE.VMA are scoped to the hart.
6. Global history, the RAS and the FTQ are per thread; shared tables may hash in the tid.
7. Per-thread occupancy with caps: the issue queues at 75% (required); the LQ, SQ, completion buffer, MSHRs and LLTs
   counted.
8. Per-hart state: CSRs, interrupts, the timer compare, the LR reservation, debug state and counters.
9. Interfaces are queue-decoupled and tid-tagged.
10. SMT-off and a sleeping sibling: the partitions merge after a drain (m7-smt2-plan.md D2).
11. Early retirement is per thread.
12. Per-thread structures are sized from `TID_W` and the width parameters.

## Testing before hart 1 runs: `SOLO_TID` and `SPLIT`
`SOLO_TID` (`tg_core_pkg`, `TG_SOLO_TID=0|1`; smt2 configurations only; `make ... SOLO_TID=1`) runs each core's one
thread as tid 1 inside the core, while it stays hart 0 to software: `mhartid` and the trace's hart field do not change,
and the thread takes hart 0's interrupt lines.
The tests, lockstep and the riscv-tests' entry code, which parks every hart but 0, run as they are, and every tid = 1
path is exercised. A path that loses the tid fails: with the ROB's `flush_tid` held at 0, 41 of 64 riscv-tests fail.
Each M7 step's MR runs regress at `SOLO_TID=1` and `make cycle-identical BRANCH_SOLO_TID=1` (the same cycles).

`SPLIT` (`tg_core_pkg`, `TG_SPLIT=0|1`; smt2 configurations only; `make ... SPLIT=1`) is the split mode of step 3 (D1):
each thread owns half the ROB, LQ and SQ. Hart 1 turns it on (step 5). Before that, `SPLIT=1` runs the one thread in its
half (half 1 with `SOLO_TID=1`), so the halves' arithmetic is tested under lockstep. It is not cycle-identical: the
window is half. The registers are not split by it: the free lists' division and hart 1's homes (D3, D4) come with two
threads at step 5, after D3's revision (core-pipeline.md §5.4).

**With hart 1 (`HART1_ON`, `make ... HART1=1`, from step 5c)** both threads fetch from reset and lockstep checks both
harts' records (tg_vsim's Spike has a hart per thread). The tests' entry code parks hart 1: riscv-tests' `-p`
environment spins it in a `bnez` loop, their `-v` environment runs `coherence_torture` on it (random AMOs and loads
beside hart 0's test), verif-2's directed tests and benchmarks park it in WFI (`TG_PARK_HARTS`, the `crt0`s), and
`tg_rand` and `gen_coh` by `mhartid`. `tests/isa/directed/hart1_init.S` checks every integer home starts at zero on
both harts. A hart parked in WFI costs its sibling nothing measurable (core-pipeline.md §8.4, §5.4, §3.5).

## What is per thread, by unit

| Unit | Per thread now | M7 step that adds the rest |
|---|---|---|
| Fetch | with hart 1 (5b, 5c): a stream per thread (F1's next block, parks, stops, straddlers), the stage tids, redirects per stream, the instruction queue per thread, F1's translation, privilege and PMP by its hart, the walk's thread, the round-robin choice; both streams from reset; a thread waiting at rename behind a serial uop is not fetched and its blocks go; one line's two streams' misses refill it once (core-pipeline.md §3.5) | 7: ICOUNT |
| Predictors | with hart 1 (5b): the micro-BTB looked up by F1's thread and trained by the trained branch's; TAGE's histories and FTQ per stream, its hashes with the stream; a return-address stack per thread | — |
| Decode | with hart 1 (5b): its group's hart's state; one thread's group a cycle | — |
| Rename | maps (a tid address bit) and renamed-since-flush bits; free lists in RAM form (D3); the ROB, LQ and SQ tails and room checks; the serialisation block; the flush of the RN and DS stages; the tags' and LLTs' return; with hart 1 the lists' division, hart 1's homes and D3's transfers (5a), the FP banks of 96 (5a), each thread's share of the divide and FP counts, the homes zeroed at reset, a blocked thread's group dropped from RN (5c) (core-pipeline.md §5.4) | 7: the caps |
| Issue | each row's tid; the kill (`flush_tid`); the cap's room (`room_q`, not yet applied); the speculative wakeup's drop | 7: the caps at dispatch; with fpu-2: the tid in every payload |
| Exec | the stages' kill by thread (fpu-2); with hart 1 bank 1's port writes hart 1's homes' zeros at reset (5c, fpu-2's file) | — |
| P4 (FPU) | its stages, shadow pipelines, divide table and result queue | — |
| fcsr | frm, fflags and the early-retire counter (per hart); the flags go to the retiring op's thread | — |
| CSRs | every hart's architectural state: hot state, cold rows and `pmpaddr` (a tid address bit), PMP descriptors, interrupt lines, timer compare, pending write, counters; writes to the committing thread (`cm_tid[0]`); the flushed thread's pending write dropped; each hart's privilege, SUM, MXR, satp and PMP state out to the LSU and the walker (D6) and fetch and decode (5b); with hart 1 (5c) the CSR read by the executing thread, interrupts, WFI's wake and an xRET's xepc by the commit head's, both harts' reset sweep, each hart's counters loaded from its own write (core-pipeline.md §9.6) | — |
| LSU, MMU | the LQ's and SQ's pointers; the split mode's halves: the pointers', the drain's next head's and the head mask's wrap, a flush's drop; TLB entries tagged by thread, flushed per hart; each access's translation and PMP by its thread; the walk's thread; the searches inside a thread; the replays' and the drain's turns (D8); the head checks, the MMIO load, `sq_drained` and `mmio_busy` by the ROB's commit thread; an atomic slot per thread and a reservation per hart; each stage's flush by its operation's thread; fetch's walks and ITLB lookups by fetch's thread and the split mode on with hart 1 (5b); with hart 1 (5c) the MMIO request's source its hart and the store-data capture waiting for the other thread's atomic's write (core-lsu.md, core-mmu.md) | — |
| ROB | `flush_tid` (the flushing instruction's tid); the retiring slots' tids (`cm_tid`); the head, tail and xRET bits; the split mode's halves; the commit thread choice (one thread a cycle, D7), out to the LSU's head checks (`hd_tid_o`); each thread's exception, mispredict and WFI state; with hart 1 (5c) interrupts at either thread's head, a flush dropping only its thread's reports, commit held while a trap's CSR writes run, no turns for a thread waiting in WFI (core-pipeline.md §8.4) | 6: SMT-off's merge |
| Trace | the hart field from each record's tid (tid ^ `SOLO_TID`) | 2: the load address (`mem_ld`, after interfaces.md v1.5) |

## The thread choice (D7, refined 10-20)
- **Fetch** picks a thread a cycle: round robin first (5b), then ICOUNT (step 7). A thread waiting at rename behind a
  serial uop is not picked (5c).
- **Decode, rename and commit** take one thread's group a cycle: the first-served thread alternates, and an idle thread is
  skipped; so is a thread behind a serial uop at decode and rename, and one whose head is a WFI still waiting at
  commit (5c). Decode also passes over a thread whose window may not take one more group while the other thread's
  queue holds instructions, and serves a thread with room first (5d, core-pipeline.md §3.5, §5.4). Commit's choice is made a cycle ahead, so the head window is still read from flip-flops
  (core-pipeline.md §8.4).
- **Mixed groups** (a thread taking the slots its sibling leaves, D7 as first written) come only if the model shows them
  gaining 1% or more weighted throughput (DR-154's rule): they cost a second head window's reads (the payload and each
  flag table) at commit, and both threads' free-list pops and a tid in the dependency checks at rename. smt2-study prices
  them before step 5.

## Provenance
Plan §6 and the research notes it cites; m7-smt2-plan.md §8. No other core's RTL was read.
