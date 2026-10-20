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

## Testing before hart 1 runs: `SOLO_TID`
`SOLO_TID` (`tg_core_pkg`, `TG_SOLO_TID=0|1`; smt2 configurations only; `make ... SOLO_TID=1`) runs each core's one
thread as tid 1 inside the core, while it stays hart 0 to software: `mhartid` and the trace's hart field do not change,
and the thread takes hart 0's interrupt lines.
The tests, lockstep and the riscv-tests' entry code, which parks every hart but 0, run as they are, and every tid = 1
path is exercised. A path that loses the tid fails: with the ROB's `flush_tid` held at 0, 41 of 64 riscv-tests fail.
Each M7 step's MR runs regress at `SOLO_TID=1` and `make cycle-identical BRANCH_SOLO_TID=1` (the same cycles).

## What is per thread, by unit

| Unit | Per thread now | M7 step that adds the rest |
|---|---|---|
| Fetch | the tid it writes on each instruction (`RUN_TID`, the one running thread) | 5: PC, history, FTQ, RAS, instruction queue, thread select |
| Predictors | the micro-BTB's entry tag (looked up and trained with tid 0) | 5 |
| Decode | — (passes the tid through) | 5 |
| Rename | maps (a tid address bit) and renamed-since-flush bits; free lists in RAM form (D3); the ROB, LQ and SQ tails and room checks; the serialisation block; the flush of the RN and DS stages; the tags' and LLTs' return (core-pipeline.md §5.4) | 3: the split mode's lists and homes (D4); 5: the divide and FP counts |
| Issue | each row's tid; the kill (`flush_tid`); the cap's room (`room_q`, not yet applied); the speculative wakeup's drop | 7: the caps at dispatch; with fpu-2: the tid in every payload |
| Exec | — | with fpu-2: the stages' kill |
| P4 (FPU) | its stages, shadow pipelines, divide table and result queue | — |
| fcsr | frm, fflags and the early-retire counter (per hart); the flags go to the retiring op's thread | — |
| CSRs | every hart's architectural state: hot state, cold rows and `pmpaddr` (a tid address bit), PMP descriptors, interrupt lines, timer compare, pending write, counters; writes to the committing thread (`cm_tid[0]`); the flushed thread's pending write dropped; reads and outputs the running thread's (`RUN_TID`) (core-pipeline.md §9.6) | 4: the PMP select at the checkers and each hart's satp at the walker (D6); 5: reads by each consumer's thread |
| LSU, MMU | the LQ's and SQ's pointers (core-lsu.md) | 3b: halves; 4: the rest |
| ROB | `flush_tid` (the flushing instruction's tid); the retiring slots' tids (`cm_tid`); the head, tail and xRET bits (core-pipeline.md §8.4) | 3b: halves, the commit thread choice, the exception, mispredict and WFI state |
| Trace | the hart field from each record's tid (tid ^ `SOLO_TID`) | 2: the load address (`mem_ld`, after interfaces.md v1.5) |

## Provenance
Plan §6 and the research notes it cites; m7-smt2-plan.md §8. No other core's RTL was read.
