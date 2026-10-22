# Core pipeline: fetch to commit (`tg_core`, M2 core alpha)

Status: draft for M2 — core track — 2026-10-13

This spec covers the out-of-order integer pipeline of `tg_core` as built for **M2** (plan §11): RV64IM, Zicsr, Zicntr, Zifencei, M-mode only, single thread (`st`, `st_w3`). The load/store unit and the data cache have their own spec, [core-lsu.md](core-lsu.md). The port contract is [interfaces.md](interfaces.md) §1–§5.

## 1. Purpose and M2 scope

M2 is the plan's "conservative out-of-order" core. It must pass riscv-tests (`rv64ui-p`, `rv64um-p`, `rv64mi-p`) and CoreMark/Dhrystone in Spike lockstep, in the 2-wide (`st`) and 3-wide (`st_w3`) builds. What it has and what it postpones:

| Plan feature (§4) | M2 | Arrives |
|---|---|---|
| Decoupled front end, 16-byte blocks, pre-decode and compaction (S5 RTL) | yes | — |
| 64-entry micro-BTB (S5 RTL) as the only predictor, trained at execute with a 2-bit counter table; decode-time target repair for direct jumps and branches | yes | TAGE-lite, block BTB, RAS, FTQ: M6 |
| FTQ (PCs kept in the FTQ, ROB keeps an index) | no: PCs travel with each instruction and sit in the ROB | M6 (lever R7) |
| Rename with writer-sharded banks, free lists, producer table | yes | — |
| Checkpoints, recovery at execute | no: every recovery is at commit | M6 |
| Distributed issue queues with dependency vectors, woken vector, age matrix (S2 RTL) | yes | — |
| Speculative load wakeup, shadow cancel | yes (M6, `SPEC_WAKE`, on by default): an integer load wakes its dependants at AG, and one that does not complete in M2 cancels the shadow (§6); no per-PC hit predictor | — |
| Store address issued on its base alone | yes (M6, `STA_BASE`, on by default, DR-169): a store's IQ-STA row does not wait for its data register (§5.3; core-lsu.md, Stores) | — |
| ALU-queue steering a group ahead | yes (M6, `STEER_LA`, on by default, DR-169): rename counts the bank row the group in DS is taking (§5.2) | — |
| Ownership prefetch for stores | yes (M6, `STORE_PF`, on by default, DR-171): a store's line is requested with T when its address decides, up to `STORE_PF_MAX` (3) in flight (core-lsu.md, Stores) | — |
| Long-latency tags (LLTs), deferred-free hook | yes (loads and DIV/REM use LLTs; nothing retires early) | early retirement: M6 |
| Register file, bypass, 1-cycle ALU (S3 RTL) | yes | — |
| MUL 3 cycles pipelined; DIV iterative | yes (radix-2) | DIV on the Goldschmidt DSPs (R4): later |
| LSU: split LQ, SQ, store-data capture, forwarding, ordering checks | yes, without the completion buffer | completion buffer: M6 |
| L1D with 16 MSHRs | 1 MSHR | M6 |
| CSRs, traps, interrupts | M-mode set matching Spike (§9) | S/U, Sv39, PMP checks, A, C: M3 |
| SMT2 | `tid` fields in the fetch, rename, issue and ROB payloads, set by fetch to the one running thread; `flush_tid` from the ROB; per-thread logic in the issue queues, P4, fcsr and the micro-BTB. The `smt2` builds run hart 0 only | M7 (DR-175, m7-smt2-plan.md) |

## 2. Pipeline

```
 F1 ──► F2 ──► F3 ──► DE ──► RN ──► DS ──► IS ──► RF ──► EX ──► WB ··· CM
 PC,    tag    compact decode rename dispatch select read   ALU,   RF write,
 uBTB,  cmp,   into    (IBUF  alloc  ROB/IQ   (IQ)  +byp   BR, AG complete
 I$ rd  predec IBUF    head)                        sel
```

| Stage | Register at its end | Work |
|---|---|---|
| F1 | `if2_*` | `fpc_q` is the block address; micro-BTB lookup gives the next block; I$ tags read (LUTRAM); the I$ data array was addressed with the next PC one cycle earlier (BRAM with output register) |
| F2 | `if3_*` | way compare, way select, pre-decode (`tg_predecode`); a miss parks fetch and starts a refill |
| F3 | IBUF | compaction into the 16-entry instruction queue (`tg_fetch_compact`) |
| DE | `rn_q` | up to `DECODE_WIDTH` instructions leave the IBUF and are decoded; decode-time redirects |
| RN | `ds_q` | rename, steering, free-list pops, ROB/LQ/SQ/LLT allocation |
| DS | ROB, IQ rows, LQ/SQ entries | writes; dependency vectors filtered by W |
| IS | `iss_*` (inside `tg_iq`) | wakeup and oldest-ready select; 1-cycle ops set their W bit |
| RF | `ex_*` | register read, bypass select, payload from the queue |
| EX | `res_q` | ALU, branch resolution, address generation |
| WB | — | register-file write at the end of the cycle; ROB completion |
| CM | trace, CSR state | up to `COMMIT_WIDTH` retirements; traps, interrupts, redirects |

**Flush.** Every recovery happens at commit (§8). A flush clears the whole thread: front end, IBUF, `rn_q`, `ds_q`, issue queues, execution pipelines, ROB, uncommitted LQ/SQ entries and LLTs. The redirect and the flush are registered: they act in the cycle after the commit that caused them. A decode-time redirect (§3.4) flushes only F1–F3 and the IBUF.

## 3. Front end (`tg_fetch`)

### 3.1 Fetch loop and I$
- **Next PC (F1).** `fpc_d` = flush redirect, else decode redirect, else miss restart, else stall (`fpc_q`), else micro-BTB target on a hit, else the next 16-byte block. Spike S5's loop, with 64-bit PCs.
- **I$.** `L1I_KIB` (32 KiB), `L1_WAYS` (8) ways, 64-byte lines, 64 sets, index PC[11:6] (VIPT-ready). Data: one `tg_ram_sdp` per way, 256 rows × 128 bits, output register (read address = `fpc_d`). Tags: one `tg_ram_lut` per way. Valid bits: one `tg_ram_lut` row per set (plan §8.3) of 8 bits and the set's 2-bit generation, read by F1 and by the refill (victim choice, then a read-modify-write with the tag); after reset a 64-cycle sweep clears them while F1 waits.
- **FENCE.I by generation** (area_recovery.md §6.11): a set holds valid lines only while its generation is the current one. FENCE.I bumps the current generation, so every older line misses from the next cycle and fetch does not wait (the 64-cycle sweep it ran instead was 1.72% of the boot's first 20M cycles). A background pass then rewrites each stale set as current and empty, in cycles the refill leaves the second read port and the write port free, skipping a set the refill has made current since. A completed pass leaves no stale set, so the generation may wrap; a fourth FENCE.I before a pass completes falls back to the sweep (F1 waits). A refill that spans a FENCE.I does not install its line, as before. A simulation-only copy of the swept valid bits checks F1's lines and the victim's set every cycle.
- **Physical address.** In M (and Bare), PA = PC[`PA_W`-1:0]; with `EXT_SU` in S and U under Sv39, F1 translates the PC through the ITLB (core-mmu.md: misses park fetch for a walk). A PA with nonzero bits above `PA_W`, or whose PMA is not `PMA_MEM`/`PMA_ROM`, faults without a refill; PMP is checked per 4-byte word.
  - **On a translated page that a PMP region boundary splits, F1 waits a cycle for the check** (DR-140 #6). The block checker reads the address the ITLB gave then, so the ITLB and the checker are never in one cycle. The walker judges each page on its own (core-mmu, PMP), so under OpenSBI only a page holding a firmware-region boundary waits.
  - Bare mode checks the fetch PC itself, and homogeneous pages use the ITLB's cached result.
- **The tags are compared in F1** (timing, DR-165's restructure): the set's valid bits and tags against F1's PA, the hits registered, so F2's way select is a register.
- **Miss (F2).** The F1/F2 contents are dropped, fetch parks, and one `Get` (size 6, source 0) goes out on `l1i` (one demand request at a time; the next-line prefetch below has its own). The four `AccessAckData` beats are written into the victim way (an invalid way, else a round-robin pointer shared by the sets); the victim's valid bit is cleared when the refill starts, because the refill rewrites its rows beat by beat and outlives redirects (its old line must miss meanwhile); the tag and valid bit are written with the last beat; then fetch restarts at the missed PC. `denied` or `corrupt` leaves the line invalid and records a fetch fault for the PC.
- **Next-line prefetch** (`IPF_ON`, on; `TG_IPF=0` turns it off, cycle for cycle; area_recovery.md §6.11–6.12). Every demand miss of line L, a refill or a validation (below), also fetches L+1 when it lies in the same page, so its PMA and PMP region are L's:
  - **The fetch:** a second engine takes a victim way in L+1's set (its valid bit cleared, as a refill's victim) and sends its own `Get` (source 1). The demand's Get has the A channel first, but a prefetch Get once offered keeps it until it is taken. Its beats, told apart by their source, go into that way's rows on the refill's data bus. The line then waits there invalid.
  - **The validation:** the demand miss of exactly that line writes its tag and valid bit in one cycle, with no refill, and fetch restarts. That starts the next line's prefetch, so sequential code streams. A miss of the line still in flight waits for it.
  - **No second copy:** the line is never valid before its own miss, so no other valid copy can exist, and no tag check of L+1 is needed.
  - **Sharing:** neither engine's victim is the other's way in the same set. The valid RAM's second port and its write port go first to the sweep, then the demand refill, then the prefetch's victim, then FENCE.I's background pass.
  - **FENCE.I** drops a held line and poisons one in flight.
  - **The cost:** a useless prefetch costs the line its victim held. The sweep's simulation-only copy covers the new valid-bit writes.
- **F2's actions on F1 are registered** (DR-140 #7). They take effect a cycle later and drop the blocks F1 and F2 took meanwhile:
  - parking on an I$ or ITLB miss;
  - a refetch: at a PMP cut, after a dropped prediction, or of a line installed while F2 missed it;
  - the stop after a fault block.
  - The refill and the walk start from the registered decision, as early as before.
- **Fetch fault.** A faulting PC produces a one-instruction block whose metadata carries `fault`; decode turns it into an instruction access fault (cause 1) or page fault (cause 12), `tval` = PC, or PC + 2 when only the second half of a 32-bit instruction faults. Fetch then waits for a redirect.

- **Fetch's privilege** (timing, DR-145): F1 reads its own copy of the privilege and of whether it translates, registered a cycle behind `tg_csr`'s. They change only as a trap, an xRET or a serialising CSR write commits, and the flush follows in the next cycle, so fetch resumes after the copy has caught up (asserted: any difference falls in a flush cycle). The CSR's registers sit far from F1's PMP select in the full chip (fpu-2's 125 MHz study: −4.2 ns, mostly wire).

### 3.2 Prediction
- **Micro-BTB** (`tg_ubtb`, S5): 64 entries, 2-way LUTRAM, keyed by the 16-byte block address; an entry holds the target and the slot (halfword) of the block's last parcel of the taken branch. A hit ends the block at that slot (`exit_slot`) and fetches the target next cycle. Its LUTRAM valid bits are cleared by the reset sequence (§10).
- **Return-address stack** (`tg_ras`, M6; `RAS_ON`, on; `TG_RAS=0` turns it off, cycle for cycle): `RAS_ENTRIES` (32) entries. With TAGE (`RAS_FE`) fetch predicts returns and moves the stack at F2; without it (`RAS_DEC`) decode does (§3.4).
  - **Operations** (the RISC-V hints, x1 and x5 the links): a JAL or JALR that writes a link pushes its link (PC + 2 or 4); a JALR that reads a link pops, unless it writes the same register; with two different links it pops, then pushes.
  - **At F2** (`RAS_FE`): a return (pre-decode's pop mark) while the stack is not empty is an exit candidate, to the stack's top (TAGE's decision, below). As each block is delivered, its exit pushes its link (a call) or pops (a return), as commit will (`ras_op`). A straddling call or return is its next block's exit. The stack takes each operation, and decode's repair, a cycle later (timing); its outputs show the stack as it will be (a pending push's link, a pending pop's entry below, a pending repair's values).
  - **A flush's repair is exact.** Commit keeps a committed copy: a pointer, a count and a LUTRAM written by the committed pushes. The speculative entries are a LUTRAM with a valid bit each, and an entry without one reads the committed copy's. A flush clears the valid bits and takes the committed pointer and count. The speculative side is ahead of commit, so whatever commit writes after a flush, the speculative side wrote at that entry first: an entry without a valid bit is unchanged in the committed copy. So the stack is exact after every flush.
  - **Decode's redirect:** at decode (`RAS_DEC`) it needs no repair: only the groups rename takes move the stack. At F2 (`RAS_FE`) the dropped blocks moved it, so the redirect restores the pointer, the count and the top entry from the redirecting block's FTQ entry (the stack before the block), then applies the redirecting instruction's own operation, for a call or return no block's exit carried. A deeper entry the dropped path overwrote (after popping below that top) stays wrong until the next flush: the stack only predicts, and execute checks every return.
  - **Limits:** a decode group holds at most one stack operation (a later one waits for the next group), or at F2 a block makes one (its exit's); a commit group holds at most one push (§8.2). The stack is circular: a push past 32 overwrites the oldest entry, and the count saturates.
  - **Not yet:** one stack per core; per hart in M7.
- **TAGE-lite** (`tg_tage`, M6; `TAGE_ON`, on; `TG_TAGE=0` turns it off, cycle for cycle): the direction predictor, per fetch block. Design and measurements: reports/m6-tage-design.md in the core track's build tree.
  - **Tables** (block memory, 5 BRAM36): a base table of 2K blocks with a 2-bit counter per slot, and two tagged tables of 2K entries (DR-170, the user's choice from the size study: reports/m6-tage-size.md in the core track's build tree). A tagged entry holds two sub-entries {valid, slot, 9-bit tag, 3-bit counter, 2-bit useful}; a branch matches the sub-entry with its slot (its last parcel's, the micro-BTB's key) and the table's tag. History lengths 8 and 32 bits.
  - **Sizes are switches** (`tg_core_pkg`, each with a `TG_` define): `TAGE_NT` (1 to 4 tagged tables; their histories 12; 8, 32; 5, 14, 40; or 4, 9, 18, 40), `TAGE_LI` (index bits, 11), `TAGE_TW` (tag bits, 9), `TAGE_BI` (the base table's index bits, 11). Each tagged table costs about 150 LUTs; depth costs block RAM, not LUTs.
  - **Lookup:** F1 reads every table on the block address hashed with the speculative history (`gh_q`), as the block moves into F2 (the I$ data's timing); the history does not wait for the block in F2, so a lookup misses at most the previous block's branches.
  - **Decision (F2):** each conditional branch's direction comes from the longest-history match, else the base counter. The block's exit is its first JAL, JALR the micro-BTB predicts there, return the stack predicts (`RAS_FE`, above), or conditional branch predicted taken. A block holds at most two conditional branches: it ends before a third (a cut, refetched there). When the exit differs from what F1 followed (the micro-BTB; for a return, also when its target is not the stack's top), F2 refetches: at the exit's target (PC + imm, added in the action's cycle, or the stack's top) or at the next block. The micro-BTB's entry is invalidated only when its prediction is no branch's or jump's. A JAL or branch exit that F2 refetched at its own target carries no target in the queue (`pred_tsrc`): decode takes its own. At the micro-BTB's slot F2 keeps F1's path, so the queue carries the micro-BTB's target and decode checks it: the micro-BTB's partial tag aliases blocks 2 MiB apart (a straddler's slot 0 included, though the micro-BTB never trains on one), and a JAL patched since its entry trained has a new target.
  - **Straddlers:** a 32-bit instruction that straddles in from the previous block is its next block's first instruction, its last parcel at slot 0. F2 keeps its first half from the previous block and decodes it from both halves; it is a candidate like the others (a branch with TAGE's slot-0 direction, a JAL, a JALR the stack or the micro-BTB predicts), to the block's address − 2 + imm. As the exit, the block delivers only it. Its history bit, stack operation and FTQ slot follow from slot 0.
  - **History:** one bit per conditional branch, in program order. The speculative history takes each delivered block's branches as predicted; commit's takes each retiring branch's outcome (the same branches, on the right path). A flush copies commit's into it. Decode's redirect rebuilds it from the redirecting instruction's FTQ entry, with one shift of 0, 1 or 2 (a block holds at most two branches). A delivered block's bits go in a cycle later (timing): the lookup and the FTQ take the history with them applied, so they see what they saw before (asserted).
  - **FTQ** (`FTQ_ENTRIES`, 32, LUTRAM): one entry per delivered block, with the history before the block, its branches' slots and directions, and the indices and tags it read TAGE with; and (`RAS_FE`) the stack's pointer, count and top before the block. Each instruction carries its block's entry to the ROB. Decode's redirect drops the later entries; commit frees the earlier ones, but none the training queue still names; a flush drops every block but keeps those (its pointers go to the head's next entry). F2 holds while it is full.
  - **Training at commit:** each retiring conditional branch (a straddler at slot 0 of the block its last parcel is in) sends its outcome, its fetch-time direction and its block's FTQ entry to a queue in `tg_tage`; the head's indices and tags are read from the FTQ as it leaves the queue. Port B reads the entries and writes them back a cycle later (one update every two cycles; a full queue drops one). The provider's counter moves toward the outcome, its useful bits when it disagreed with the next match; without a provider, the base counter moves. A wrong fetch-time direction allocates a sub-entry in a longer table (the shortest with a candidate: an invalid way first, else one not useful), else ages the candidates.
  - **Not yet:** a periodic reset of the useful bits; per-hart histories (M7).
- **Direction:** a 2-bit counter table, 512 entries in LUTRAM, indexed by PC[10:2].
  - **It is not reset, by design:** LUTRAM is never reset (`tg_ram_lut`), and clearing 512 entries through one write port takes 512 cycles (§10).
  - **It starts at zero after configuration:** the primitives' INIT is zero, and so is the simulator's default. So the first run after configuration matches simulation.
  - **A core reset keeps the trained counters.**
  - **Its start value changes timing only.** A counter decides only whether a branch trains the micro-BTB, and execute checks every prediction.
  - **Under `--rand-reset`, programs take a few more mispredictions:** rv64ui-p-add takes 1,389, 1,468 or 1,561 cycles. Verilator 5.052 fills the whole array with one random value, so there are only three outcomes.
- **Training at execute (P0).** For each resolved branch or jump: the counter moves toward the outcome; the block should be predicted taken if the instruction is JAL/JALR or the new counter is ≥ 2. If it should and the micro-BTB did not predict this target at this slot, the entry is written (the way that hit, else a pseudo-random way); if it should not and the micro-BTB predicted it taken, the entry is invalidated. Wrong-path branches also train (accepted in M2).

### 3.3 Instruction queue
`tg_fetch_compact` (S5) with `WR = 4` writes per cycle and `IBUF_ENTRIES` (16) entries. Per-instruction metadata from F2: the block PC, `fault`, the micro-BTB hit, way, slot and target. The PC of an instruction is `block_pc + 2·slot`, minus `FETCH_BYTES` for an instruction that straddles from the previous block (a 32-bit instruction reported at slot `NP-1`).

### 3.4 Decode-time redirect (DE)
For each instruction, `pred_exit` = the block was predicted taken and the predicted slot lies within this instruction's parcels. Then:
- **JAL:** target = PC + imm. If it was not predicted taken here with that target, redirect to the target.
- **Conditional branch** predicted taken here with a wrong target: redirect to PC + imm.
- **A return** (a JALR that pops the return-address stack, §3.2) while the stack is not empty, without TAGE (`RAS_DEC`; with it F2 predicts returns; the operation comes from the raw encoding and the marks, not the decoder, asserted equal): its target is the stack's top. If the front end did not follow that target here, redirect to it. Execute then rewrites the micro-BTB entry, as for a JAL.
- **TAGE's exits** (`pred_tsrc`, §3.2): a JAL or branch F2 refetched at its own target needs no check; its predicted next PC is decode's target. One at the micro-BTB's slot carries the micro-BTB's target and is checked as above. A redirect also names its instruction's FTQ entry and slot, for the history's repair, and (`RAS_FE`) its own stack operation and link, for the stack's.
- **`pred_exit` on anything else, or a slot mismatch:** the prediction is bogus; redirect to the next sequential PC and invalidate the micro-BTB entry.

The redirecting instruction stays in the group; younger slots are dropped. Its `pred_npc` (the next PC the front end followed) is what execute compares against.

**Timing:**
- **No add waits for another.** An instruction's PC is its block's address plus its offset in the block (`pc[3:0]`, or −2 for a straddler). The PC-relative values (the targets, AUIPC, the link value, the next PC) are each one three-input add of block address, offset and operand: a carry-save step and one carry chain. Only a straddler's PC needs a decrement of the block address.
- **The redirect decision uses no add at all.** "The predicted target is the branch's" is checked carry-free, as `a + b + c == k` (Cortadella and Llabería, IEEE Trans. Computers, 1992). Every bit of the carry-save sum must match the carry that k needs there. The sums themselves feed only registers.
- **Nor does it wait for the decoder.**
  - **The class:** the instruction's pre-decode marks (conditional branch, JAL, JALR), which the queue carries from F2. For an instruction without a decode-time exception they are decode's class. Pre-decode reads the same opcode bits, and every encoding the two could disagree on is illegal: JALR with funct3 ≠ 0, a branch with funct3 2 or 3, a compressed instruction without C or reserved.
  - **The offset:** from the raw encoding (B, J, CB or CJ format), chosen by the JAL mark.
  - **The exception that gates it:** from the raw encoding too. A 32-bit instruction's comes from a second decoder of which only that output and "serialising" are kept. A compressed instruction's: illegal as such, C.EBREAK, or an FP load or store (C.FLD, C.FSD, C.FLDSP, C.FSDSP) with the FP unit off.
  - **The group** (who goes alone) uses the same bits, so the RVC expander feeds only the uop's fields.
  - **Checks:** simulation asserts every one of these against the decoder's own results.
- **One more stage, a switch** (DR-140 #8, `DE_STAGE`): off in both profiles, and lint-only on top of the default until the user turns it on.
  - DE1 decodes the queue head into registers. DE2 forms the group and checks the predictions from them.
  - The queue's take then counts a group as ending only at the instructions that go alone.
  - Every redirect costs one more front-end cycle: bench +2.5% / +2.3% (st / smt2).

### 3.5 Per thread (M7's step 5b, DR-175; docs/spec/threading.md)
With hart 1 (`HART1_ON`) the front end runs a **stream** per thread; without it every stream index is 0 and nothing
below changes a cycle.
- **F1, F2, the registered action and F3** each hold one block and its stream. Per stream: its next block when F1 holds
  the other's (a waiting PC), its park state (an I$ miss, an ITLB walk) with the parked block's PC and PA, its stop after
  a fault block, its faulting page, its straddler. **F1 picks** the other stream's waiting block when its own block moves
  on (round robin, D7; ICOUNT comes with step 7's caps), and an empty or stopped F1 takes a waiting block; the select is
  at fpc_q's input, the F1 loop that fix G (below) cleared. F1's ITLB lookup, privilege, Sv39 mode and PMP descriptors
  are its block's hart's; the micro-BTB is looked up with F1's thread and trained with the trained branch's
  (`upd_tid`); TAGE reads with F1's stream's history and takes the stream as the block address's top bit.
- **A full queue parks its stream at F2 (5e, smt2_report §13.16):** a block whose thread's queue cannot take it waited
  in F3, and F3, F2 and F1 with it, so the other thread's fetch waited for this one's decode. Now, while the other
  stream waits for the pipe (its block in F1, or its next one waiting), F2 passes a block on only if it fits its
  thread's queue beside that thread's block in F3, each counted at a bound from registers (the parcels from its entry
  and a straddler's completion; the queue's counts, `tg_fetch_compact`'s `occ_o`). A block that does not fit parks its
  stream as an I$ miss does, undelivered (no FTQ entry, its later blocks dropped), and the stream restarts at it once
  its queue has the room. It parks only when decode has not read that thread's queue for 2 cycles while the queue held
  instructions (`QP_WAIT`: its RN register holds a stalled group); a queue that drains is read every other cycle, and
  its block waits in F3 a cycle or two as before, which costs less than a refetch. At 30 cycles: 1.293 with no
  starving pair, against 5d's 1.248 with three (memory pairs 1.296 → 1.348, mixed 1.252 → 1.356, compute 1.198 →
  1.191). TG-FQPARK counts the parks.
- **Redirects per stream:** a flush and decode's redirect may come in one cycle for different threads and both apply;
  for one stream the flush wins. A redirect kills only its stream's blocks in F1, F2 and F3 and its pending action; F2's
  action likewise drops only its stream's later blocks (the other stream's block in F2 waits a cycle, and the I$ data
  and TAGE are read only when F2 takes F1's block, `f2_ld`).
- **Shared:** the I$, its refill and prefetch engines (one Get each), the valid sweep and generations, the micro-BTB,
  TAGE's tables, the ITLB. The refill engine serves a stream already parked before one parking now, and a refill's
  end restarts the streams parked on its line; one fetch walk at a time, a waiting stream's first.
- **The histories and the FTQ** per stream: the speculative and committed histories, the FTQ's pointers, its LUTRAMs
  with the stream as an address bit; each stream keeps every entry TAGE's training queue names for it. **A
  return-address stack per thread** (two `tg_ras`). **The instruction queue** per thread at `{tid, row}` (16 entries
  each), with its own straddler; decode reads one thread's queue a cycle, the other's after a take, an empty one
  skipped (D7). With hart 1 (5d) only a thread whose RN register takes a group next cycle (rename's `acc_o`, §5.4)
  is read, so decode never waits on a register holding a stalled group. **Decode** reads its group's hart's state
  (misa, FS, frm, the mode, TVM/TW/TSR).
- **Measured for step 7** (the coordinator): cycles an F2 hold stalls another stream's fetch, and cycles a group at
  rename holds the other thread's group in decode (`TG-STALL2` on stderr).
- **Timing fixes** (spikes.md §7.1, approved, exact): G, f1_fault out of the next-PC select (a faulting block's stream
  stops, so its next address is never used); A, `krt_q` the stack's top; B and E, the exit's target and `tsrc` selected
  after F3's register; C, the stack's late operations without the flush gate (asserted never together); D, the FTQ
  entry's branch bits written a cycle late (decode reads an entry three cycles after delivery at the earliest); F,
  TAGE's tagged tables without the depth cascade.
- **Hart 1 runs (5c):** both streams start at the boot PC. A thread that renamed a serial uop waits at rename for
  its flush, which drops whatever it fetches meanwhile (`blk_o`, §5.4): F1 treats its stream as stopped, F2 passes
  its blocks on without an FTQ entry (its FTQ may be full of the older instructions' blocks), and the queue empties
  and takes them without writing them (`drop_t`), so it holds none of the shared stages. In another stream's
  redirect cycle F2's block goes on to F3 with its FTQ entry (only its own stream's redirect stops it), so the
  stack's operation of that block and decode's repair of the other stream may come in one cycle: each goes to its
  thread's stack (`ras_tid`, `ras_rtid`). Two streams missing one line: the tags are compared in F1, a cycle and
  more before F2's action parks the stream, so a refill or a held line's validation ending in between left it
  parking on a line already valid; the last line made valid (three cycles) restarts it at once and no second
  refill fills another way. A simulation check: every instruction the queue hands decode names an FTQ entry its
  stream holds.
- **Checks:** `tests/unit/fetch` runs two harts' streams under random flushes and decode redirects (both at once too),
  FENCE.I, misses and memory delays, and checks every instruction decode takes against its thread's stream; it found
  the two bugs above (the reads, the engine's starvation) before hart 1 ran.

## 4. Decode (`tg_decode`)

`DECODE_WIDTH` copies of a combinational RV64IM + Zicsr + Zifencei + system decoder. Output: `dec_t` (`tg_core_pkg`): class (ALU, BR, MUL, DIV, LD, ST, CSR, SYS), sources and destination, ALU control (`alu_ctl_t`), 64-bit immediate (AUIPC, JAL and JALR link values are precomputed: PC + imm, PC + 4), branch fields, memory size and sign, MUL/DIV op, CSR op, and a decode-time exception (illegal 2 with `tval` = instruction bits, 16-bit for a compressed encoding; ECALL 11 with `tval` 0; EBREAK 3 with `tval` = PC; fetch fault 1 with `tval` = PC).
- **Compressed encodings** are illegal in M2 (misa has no C). They are expanded by `tg_rvc` before decode when `EXT_C` is on; decode then sees the 32-bit form plus its length (link value PC + 2).
- **ISA switches (M3):** `EXT_SU`, `EXT_A`, `EXT_C`, `EXT_B` (Zba, Zbb, Zbs), `EXT_ZICOND` and `EXT_FD` (F and D, core-fp.md) in `tg_core_pkg` are on, with the M3 Spike configuration (`rv64imafdc_zicsr_zicntr_zihpm_zifencei_zba_zbb_zbs_zicond_sstc_svinval_za64rs`, `MSU`, 16 PMP regions: the `sim/Makefile` default for `CORE=core`), because misa and the illegal encodings must match it. clz/ctz/cpop and min/max run on P1 in the MUL slot, misa.B and misa.C are writable as in Spike, and jump targets need only 2-byte alignment. Each switch can still be turned off (with the matching narrower ISA string).
- **misa.M** gates MUL/DIV (Spike lets software clear it); misa.B gates Zba/Zbb/Zbs.
- **Group rules (DE):** a serialising instruction (CSR, FENCE, FENCE.I, WFI, MRET) or an instruction with a decode-time exception is taken alone, in slot 0; the instructions before it go in the previous group. A decode-time redirect ends the group.

## 5. Rename and dispatch

### 5.1 Physical registers
- **Banks** (plan §4.7): `INT_BANKS` = `N_ALU` + 1 banks of `INT_PREGS_PER_BANK` (64). Bank *b* < `N_ALU` is written only by ALU port *b* (bank 1 also takes MUL, DIV and CSR results through a write mux, §7.3); bank `N_ALU` only by the load pipe. Tag = {bank, index}.
- **Preg 0** (bank 0, index 0) is the constant zero: x0 maps to it, it is never allocated, and the reset sequence writes it with 0.
- **Initial map:** x*i* → bank 0, index *i* (written with 0 by the reset sequence, as Spike resets every register to 0).

### 5.2 RN stage (`tg_rename`)
- **RAT** (speculative) and **CRAT** (committed) in LUTRAM (plan §8.5 R3). A RAT entry holds the mapping and, for sources, the producer: its wakeup column, or for a 1-cycle op its ROB index (MX naming, §5.3), and its rename slot. Each RAT bank belongs to one rename slot and each CRAT bank to one commit slot, so every write port is a LUTRAM write port.
  - **The banks are XOR-banked (FPGA-friendly T2; LaForest et al., FPGA 2012).** A register's entry is the XOR of its banks. A slot writes its own bank with the new value XOR the other banks' entries at that register, which costs one more read port per bank, at the other slots' write registers.
  - Of several slots writing one register in a cycle, only the last writes (a later slot wins).
  - No live-value table names the bank that holds the latest entry. The flip-flop LVTs, with a 32:1 read at every port, are gone (6f8c99e).
  - Reads: rs1, rs2 and rd (the old mapping) per slot.
- **Recovery:** a bit per architectural register (per thread, §5.4) says it was renamed since the last flush; otherwise the CRAT answers (its producer has committed, so the source is ready and the producer fields are not read). A flush clears these bits: the committed map is current in the next cycle, with no copy. After reset a sweep writes the identity map into CRAT bank 0 and zeros into the other CRAT banks (32 cycles, alongside the free lists' initialisation).
- **Free lists** (`tg_freelist`): one per bank (and per thread, §5.4), a circular list in `FL_BANKS` interleaved LUTRAMs, with a speculative head (pops at RN), a committed head (advanced at commit by the destinations it retires) and a tail (pushes of freed registers at commit). A flush sets the speculative head to the committed head. Bank 0's list starts with indices 32–63, the others with 0–63.
  - **The free count is a register,** not tail − head: it is updated by the pushes and pops. A second register, tail − committed head, is the count a flush takes. Rename's steering and resource checks then start from flip-flops, not a subtraction (timing; the same values, asserted).
- **Steering:** BR/JAL/JALR → port 0; MUL, DIV, CSR → port 1; ALU ops in slot *k* prefer port *k* mod `N_ALU` and fall back to another ALU port whose queue bank and free list have room; LD → load port; ST → store-address queue. Destinations come from the steered port's bank.
  - **A bank's room, a group ahead (`STEER_LA`, on by default, DR-169):** the banks' free flags are registered, so they count the rows after the last dispatch, not the row the group in DS is taking now. Each bank also registers "at least two rows free" (`bank_free2_q`), and the steering takes a bank as having room when it has two free rows, or one while the DS op in the same slot is not headed for that queue. Without it, two groups in a row could aim at a bank's last row, and the second waited in DS while the other ALU queue's bank had room (10–12% of CoreMark's cycles, area_recovery.md §6.8). When DS holds, RN holds too and steers again; DS still checks the one flag. `STEER_LA=0` steers on the one flag.
- **Wakeup columns (plan §4.6, AR-1):** `IQ_TAGS` (16) wakeup tags, then the `LLT_ENTRIES` long-latency tags; no column per ROB entry, so the window size does not set the scheduler's width (st: 32 columns instead of 64; smt2: 40 instead of 120).
  - **LLT:** loads, atomics and DIV/REM with a destination.
  - **Tag:** MUL and the P1 bit counts (C_MUL) with a destination, from a pool of `IQ_TAGS`; RN waits when it runs short. A tag returns 2 cycles after its producer's register-file write (`tag_free` from `tg_exec`): by then no group in RN or DS can see the register as unwritten. Its column is then cleared in every queue row (`col_clr`), so a returned tag needs no guard. A flush returns every tag of its thread (§5.4).
  - **No column:** 1-cycle ops, which consumers name by row (MX) while the row is held. Once it is freed (2 cycles after the select), the value is in the bypass or the register file before any later consumer can issue. Serialised ops end in a flush, so their consumers find the value written.
- **Ready table:** one bit per physical register, cleared when RN allocates it, set when the register file is written (each bank's write port).
  - **Form (`tg_rdytab`, LUTRAM, FPGA-friendly T2):** each register is two phase bits, and it is ready when they are equal (A == S).
    - S, the set phase, has one table per bank, written only by that bank's register-file port: S := A.
    - A, the allocation phase, is XOR-banked into W tables (A = A⁰ ⊕ A¹ …). A clear of p through Aᶜ writes Aᶜ := ¬S′ ⊕ (the other A), where S′ is S after this cycle's set. So a set and a clear of one register in the same cycle leave it not ready, exactly as the flip-flop vector did.
    - **The clears do not wait for rename (cc1f679).** Every cycle, each bank's next W free registers are cleared, candidate c through Aᶜ, whether or not rename takes them; the free list's head and count give their indices.
      - A free register's ready bit is never read: no map holds it, and every reader of its last value read it before it was freed. So the early clears are invisible.
      - A register is still cleared in the cycle it is allocated. No write waits for rn_fire.
    - A sweep zeroes the tables in 64 cycles after reset. Only rn_fire waits for it, and that sweep ends with the D$'s, so no earlier than `start`. rename's `ready` (decode may hand a group over) does not wait for it.
  - **Why not flip-flops:** a 192-bit (st) vector read through 3W 192:1 multiplexers, and 128 FP bits through 4W.
  - **Rejected:**
    - A live-value table needs a multi-write table of its own in flip-flops.
    - Toggle-only phases go wrong for a register that a flush frees before it is written.
  - **Source:** XOR-based multi-ported memories, LaForest et al., FPGA 2012.
- **Sources:** an earlier slot of the same group that writes the register (intra-group, generated for any width), else RAT; pending if produced in the group or its ready bit is clear; a pending source waits on its producer's column, or on its row (MX), or on nothing (a 1-cycle producer whose row is freed).
- **Allocation (all or nothing per group):** ROB entries (tail + slot order), LQ/SQ entries, LLTs, wakeup tags, free-list registers per bank, and a DIV slot (at most `DIV_INFLIGHT` divides between RN and the divider). If any is short, the group waits.
  - **The counts:** each counted resource's room for 0..W more (ROB, LQ, SQ, the divides, FP divides and FP→int ops) and each free list's count against 1..W are flags from registers; the group's needs pick one at the end (timing, DR-145: no carry-chain compare after the steering; the compares are a simulation reference, asserted).
  - **LLTs and wakeup tags:** the slot after *c* users takes the (*c*+1)-th free one from the bottom, all slots at once: the free vector with its lowest *c* bits cleared (x & (x − 1)), then its lowest bit (x & −x), both carry chains. The one-hot picks also set the wakeup allocation. Same columns as an in-order loop, where each slot waited for the one before (timing, DR-145); that loop is a simulation reference, asserted every cycle.
- **Serialising instructions** wait at RN until the ROB and `ds_q` are empty; after one is renamed, RN accepts nothing until the next flush (every serialising instruction ends in a flush, §8).

### 5.3 DS stage (also in `tg_rename`)
- Writes the ROB entries (§8.1), the issue-queue rows (`tg_iq` dispatch port *k* = group slot *k*) and the LQ/SQ entries.
- **The DS payload** (`ds_uop_q`, `ds_ren_q`) loads RN's group whenever DS is free (c02be92), not only when RN fires, so its enable does not wait for rn_fire, the end of rename's longest path. `ds_valid_q` says whether RN fired; every reader of the payload is gated by a valid slot or `ds_fire`.
- **MX row destinations** (`rowdst`, the destination of the op each ALU-queue row holds) are LUTRAM, one bank per DS slot. A row's value is the XOR of the banks: each slot writes only its own bank, at the row it takes (917189a).
- **Dependency vector** = one-hot of the pending sources' columns **AND NOT W**. A store's data register (its rs2) is not a source of its IQ-STA row (`STA_BASE`, on by default, DR-169): the address op reads rs1 alone, and the SQ entry captures the data when its register is written (core-lsu.md, Stores). `STA_BASE=0` makes the row wait for both. A column is only reallocated after its producer has set its W bit and written the register file (a tag 2 cycles after the write, an LLT when released), so a W bit seen at DS still belongs to the producer RN saw; dropping it closes the window between RN and DS that the stale-dependency rule does not cover.
- **Allocation (AR-1):** RN gives out tags with the LLTs, from a free pool, and clears their W bits (`wid_alloc`).
- **IQ room:** dispatch waits until every uop of the group finds a free row in its queue's bank (`bank_free_q`).
- **Uops without a queue** (FENCE, FENCE.I, WFI, MRET, decode-time exceptions) are written complete.

### 5.4 Per thread (M7's step 3, DR-175; docs/spec/threading.md)
- **A group is one thread's:** RN's group is the thread of its slot 0 (`t_rn`), and DS's likewise. Commit's pushes, commit counts and CRAT writes are the commit group's thread's (`cm_tid`).
- **Maps:** every RAT and CRAT bank holds a map per thread at {tid, register} (RAM form, 64 deep; plan §6.2 rule 12). Reads and RN writes use `t_rn`, CRAT writes the commit thread. The renamed-since-flush bits are per thread, and a flush clears its thread's. The reset sweep writes the running thread's map (`RUN_TID`).
- **Free lists (D3):** each bank's lists in RAM form, at {tid, row} in the same interleaved LUTRAMs. Each thread has a speculative head, a committed head, a tail and the two counts. Pops come from `t_rn`'s list; pushes and the commit count go to the commit thread's; a flush recovers its thread's list. A register goes back to the list of the thread that frees it, which is the one that allocated it, so each thread keeps its registers. In merged mode (the only mode until step 3b adds the split) the running thread's lists are the lists of §5.2 and the other thread's are empty. `tests/unit/freelist` checks the lists against a model of each thread's list, in both modes.
- **Window allocation:** the ROB, LQ and SQ tails, their room flags and the serialisation block are per thread. Each thread's room flags are computed from its registers and the group's thread picks them at the end, so the compares stay off the steering.
- **A flush** recovers its thread's tails, lists and map, returns the tags and LLTs that thread holds (each records its thread when given out), and clears the RN and DS stages only when they hold that thread's group. The divide count and the FP counts not yet issued are shared totals, so each room check reads one register; with hart 1 each thread's share is kept beside them (`div_done_tid`, the FP issue's tid) and a flush takes only its thread's share off (5c).
- **Split mode (`SPLIT`, D1):** the tails wrap in the thread's halves and the room checks count against the halves' sizes. The registers are not split: the running thread keeps the lists and homes above.
- **Hart 1 (step 5, `HART1_ON`):** the lists divide (`SPLIT_L`, `FIRST_S`) and thread 1 gets its homes (D4, refined under DR-154: x1–x16 at bank 1's indices 0–15, x17–x31 at the load bank's 0–14, f0–f31 at F1's 0–31, x0 staying bank 0's register 0; `tg_rmap`'s `HSPLIT`, a 64-cycle sweep; `tg_core_pkg` `H1_*`). Each bank's registers above the homes are divided, the lower half thread 0's: bank 0 16/16, bank 1 24/24, the load bank 24/25, F0 and F1 16/16. A static division alone deadlocks: the banks are writer-sharded, so a thread can need all its architectural registers plus one in one bank (B1 through MUL/DIV, B2 through loads, F1 through FP loads, F0 through FP ops). So (D3 revised) a starved thread takes its sibling's spare registers by **transfers**: when the rename group's thread needs more of a bank's registers than its list holds (registered, `want`), the bank's list moves its sibling's last entry (tail − 1, free both speculatively and after any flush) to the taker's tail as a committed push, one a cycle, in a cycle with no push to the bank and no flush; the sibling keeps 1 in the FP lists (but while it is blocked, below) and, from 5d, gives even its last in the integer lists (`give_last`): a two-wide group can need two registers in a bank that both harts' 62 architectural registers fill to two short of full (a trap return restores every register with loads, into the load bank), and keeping 1 there left each hart one short for good (soc-2's one-core two-thread Linux boot, stopped after both harts' OpenSBI mret); a second read port per sub-bank reads it. A sibling asleep in WFI gives up its spares this way. **FP renaming across the banks (DR-179, replacing 5a's FP banks of 96):** two harts' 32 f registers can fill a bank of 64, and so can one hart's beside its parked sibling's, so with hart 1 rename picks each FP destination's bank, in slot order: its own (P4's results F0, FP loads F1) while its thread's list there has one left after the group's earlier slots (the count flags `fcv`, registers), else the other. A crossed register frees to its bank's list (the name carries the bank); either bank's write port takes P4's result or a load's (`tg_fprf`), P4 first, and a load meeting P4's write in its bank waits in the LSU (core-lsu.md, FP loads). rn_ok's check is per bank as before, so a group fits when its FP destinations fit both lists together. A group short in both banks asks both for a transfer. While the sibling is blocked (parked in WFI, or behind a serial uop), a destination that crosses also asks its own bank for one, and the blocked sibling gives its last FP spare too (`give_last`): a lone hart then takes the sleeping sibling's spares rather than crossing into the bank P4 writes, where its loads wait for P4, and its FP restores run as with FP 96. Between two running harts a crossing takes nothing (taking would only move the shortage). Hart 1 off: no crossing (cycle-identical). With hart 1 on and hart 0 alone (5a), hart 0 takes about 20 registers on CoreMark (banks 1 and 2) and runs it 0.03% slower than the split window alone. `tests/unit/freelist` checks the transfers against its model every cycle. With hart 1 running (5c) regress transfers in every bank (about 2,800 in bank 0, 6,100 in bank 1, 5,800 in the load bank a run).
- **A thread behind a serial uop** (`block_q`, until its flush) with hart 1 (5c): its later group at RN can never fire before the flush that kills it, so RN drops it and takes decode's next group (the other thread's), and fetch and the queue drop its later instructions (`blk_o`, §3.5). Without this a hart parked in WFI held RN, F2 and the queue for the WFI's whole wait.
- **An RN register per thread** with hart 1 (5d, DR-178 as amended; smt2_report §13.14's option C): decode's group goes into its thread's register (`rn_v_q`, `rn_u_q`), and rename works on one register a cycle (`sel_q`), so a group that cannot rename waits in its own register and never holds the other thread's. The select is a register, chosen a cycle ahead from registered state: the other thread's register when its group looks able to rename (its ROB, LQ and SQ halves and the unit counts have room for it, its queues' banks have rows, a serial uop's window has drained; a group just taken from decode counts as able), else the current one while it holds a group; two able threads alternate. The free registers and the tags are left to the attempt itself (no pair run held a group for them). Its multiplexer sits after the RN registers, so decode's path into them is unchanged. With hart 1 a group also renames only when its queues' banks have rows for it (`st_free`, STEER_LA's flags a group ahead), so a group short of rows waits in its RN register instead of at DS, the one stage both threads pass. A thread behind a serial uop has its group dropped from its register. `acc_o` tells decode which registers take a group next cycle (§3.5). Without hart 1 one register, as before.

## 6. Issue (`tg_iq`, `tg_wake`; spike S2 RTL)

| Queue | Rows | Port | Ops |
|---|---|---|---|
| A0 .. A(`N_ALU`-1) | `IQ_A0`, `IQ_A1`, `IQ_A2` | P0 .. | ALU; P0 also BR/JAL/JALR; P1 also MUL, DIV, CSR |
| LD | `IQ_LD` | load pipe | loads |
| STA | `IQ_STA` | store-address pipe | store addresses |

- **Variant:** `STALE = 0`, the guard, with predecoded wakeup IDs (`WAKE_ENC = 1`), as spikes.md §4.1 recommends, for the LLT columns: `busy` (the OR of every row's dependency bits) names the LLTs a queued row still waits on, and rename does not reallocate them. Tag columns are cleared in every row when the tag returns (`col_clr`, honoured in the guard variant too). No queue wakes at select. The column-clear variant (`STALE = 2`) remains a `tg_issue` parameter.
- **Timing levers (spikes.md §4.2), set in `tg_core_pkg`:** `IQ_DUP_SEL = 1` (a second select copy drives only the wakeup broadcast); `IQ_EARLY_W` = the source tags (the payload's low bits; the rest sits in per-bank LUTRAM and is read in RF); `IQ_MX` = on when `TID_W > 0` (matrix wakeup, required for `smt2` timing), with the cancel history `HIST = 1`.
- **MX naming at dispatch.** A row names its in-queue 1-cycle producers (ALU ops and branches with a link) by ALU-queue row (`disp_mdep`, rows numbered across the ALU queues) and is ready when those rows have been selected; their W bit follows a cycle later. Dispatch finds the row through `rowof` (physical register → the row its producer was written into, recorded at DS) and confirms it with one compare: the row is still held (`mx_hold`: valid and not freed this cycle) and its destination (`rowdst`) equals the source. A producer in the same group is named by the row it is being written into (`mx_alloc`). Otherwise the source uses the producer's ID.
- **Payload formats.** Rename builds one `iq_pl_t`; each queue stores only the bits its port reads, so no LUTRAM bit is left for synthesis to trim, and the other fields leave the queue as zero. All ALU queues: class, the ALU control word without the min/max group and `cmp_max` (`tg_alu` `MINMAX = 0`: min/max ride P1's MUL slot), `b_imm`, the immediate, the destination's index (its bank is the port's) and both source tags. A0 adds the branch fields (PC, kind, funct3, target, JALR offset, predicted next PC, micro-BTB hit and way, `dfix`, RVC); A1 adds `cmp_max`, the MUL/DIV/CSR fields, the wakeup column (MUL: its tag; DIV: its LLT's) and the instruction (CSR tval); both keep the ROB ID with its wrap bit (exception and misprediction age), A2 only the index (completion). LD: ROB ID, the 12-bit offset (sign-extended at issue), LQ index, size, base tag, and the fields the LQ entry takes at AG (SQ bound, destination index and file, LLT, extension; core-lsu.md); STA: ROB ID, the 12-bit offset, SQ ID, size, base tag.
- **Changes to the spike module:** a `sel_block` input (registered) that suppresses the queue's grant for a cycle (A1 uses it to keep bank 1's write port free, §7.3; LD uses it to free the load pipe for LQ replays); and a row granted in the cycle it is killed does not issue.
- **Wakeup timing:** ALU ops through MX alone (a dependant selects the cycle after its producer); MUL its tag through a delay line, so dependants read the register file after the write (MUL-to-use 5 cycles; no MUL bypass); DIV its LLT when its result is written (`wake_reg`); CSR results have no consumers in flight (serialised).
- **Speculative load wakeup (`SPEC_WAKE`, on by default; `tg_issue`, `tg_exec`):** `tg_issue` sets the W bit of an integer load's LLT in its AG cycle (*s*+2, for a load IQ-LD issued at *s*), so its dependants issue from *s*+3, read it through the M2 bypass (`ld_m2_will`) in RF and take `ld_res_data` in EX. The load pipe never holds a load between IS and M2, and the LSU wakes the LLT at *s*+4 exactly when the load completes in M2 (`wake_ld`, core-lsu.md). Without that wakeup, a registered `spec_cancel` at *s*+5:
  - returns the rows the integer queues issued at *s*+3..*s*+5 to "not issued" (`tg_iq` holds rows two cycles after issue);
  - clears the LLT's W bit (`tg_wake`);
  - kills `tg_exec`'s RF and EX stages on every integer port (no write-back, branch, MUL, DIV, CSR or AG).

  The load then replays from the LQ and wakes its LLT when it completes.

  **Its filter (`SPEC_WAKE_FILT`, on by default):** a 2-bit count per PC hash (32 entries, `pc[15:1]` folded to 5 bits) goes up by one when a tracked load does not complete in M2 and down by one when it does. From 2, that PC's loads do not wake their dependants speculatively and so never cancel: their dependants wait for the result. They still pass through the tracker, which trains the count. With `SPEC_WAKE_FILT=2` a load that misses the D$ in M2 leaves its count alone (`tg_lsu`'s `ld_m2_miss`): a streaming loop's loads, which miss every time, keep their wakeups, and their cancels pace the loop's misses as before the filter. `SPEC_WAKE_FILT=0` lets every tracked load speculate, cycle for cycle as before the filter.

  Rename and IQ-FP see only confirmed W bits: rename drops a source's dependency when its bit is set, and P4 reads integer sources from the register file. With `SPEC_WAKE=0`, loads wake their LLT when their result is written, as DIV does.

## 7. Register read, bypass, execute (`tg_exec`; spike S3 RTL)

### 7.1 Register file and bypass
- `tg_irf`: `INT_BANKS` banks, read ports per bank = 2·`N_ALU` (ALU operands) + LD base + STA base + the shared store-data port + `COMMIT_WIDTH` trace ports (simulation trace; see §11).
- S3 timing: IS (*s*) → RF (*s*+1) → EX (*s*+2, result in `res_q` during *s*+3) → WB (*s*+3, register file written at its end; `wb_q` during *s*+4).
- **Bypass sources** (binary selects computed in RF): register file, each ALU's `res_q` (EX level) and `wb_q` (WB level), the load result register and its WB copy, and the immediate. Because each bank has one writer, a source tag's bank names the only producer that can match; RF compares the index with that producer's EX-stage and WB-stage destinations.
- **`URF` (DR-174, off by default): the area reserve, turned on only if the chip runs out of LUTs.** The six issue-time ports come from `tg_urf` (spikes.md §8.14, WMODE "edge"). Each bank is three UltraRAM copies on `clk2x`, 200 MHz from the core clock's MMCM with its rising edges aligned, and each copy takes every write of its bank. Per core cycle, each copy:
  - at the core edge, writes the bank's write on port A (the write the cycle ending there holds) and reads an early port on port B, after the write;
  - at mid-cycle, reads a late port on port A, while port B idles and holds its data to the next core edge.
  - **Early ports:** ALU1's second operand and the LD and STA bases, whose `rbs` select follows the read. Port B's data holds the whole cycle. Their address is the issue select's output (`tg_iq`'s `iss_early_n`, `tg_issue`'s `iss_src_n`): the UltraRAM's address register replaces the issue → RF register for the read.
  - **Late ports:** ALU0's two operands and ALU1's first, read at mid-cycle into `ex_a_q`/`ex_b_q` after the 3:1 bank select. `tg_irf` registers their index from the select's output, beside the UltraRAMs: the issue queue's register of the same value was too far for half a cycle.
  - The store-data and trace ports stay on a `tg_ram_lut` per bank: their tags are not ready by mid-cycle.
  - Every read returns the writes of earlier cycles, as `tg_ram_lut`'s: the late read precedes the cycle's write, and the early read follows the last cycle's at the same edge, since UltraRAM does port A's operation before port B's (UG573). So the cycles are the same (`make cycle-identical BRANCH_URF=1`).
  - Simulation runs `tg_urf`'s equivalent on `clk` alone, so no testbench drives `clk2x`. Its UltraRAM form (`SYNTHESIS`, or `TG_SIM_PRIMS` with a URAM288_BASE model) is tested against `tg_ram_lut` banks with spikes-2's `tb_urf` (`make -C tests/unit/urf`: the simulation body, spikes-2's UG573 model and the vendor's, and two negative tests that must fail). The timing exceptions are in `rtl/core/regfile/tg_urf.xdc`, read `-ref tg_urf`.

### 7.2 Ports
- **ALU ports:** `tg_alu` (S3). P0 adds the branch unit: taken from the ALU's compare flags; target = precomputed PC + imm (branches, JAL) or (rs1 + imm) & ~1 (JALR); the link value is the precomputed immediate through the ALU's pass-b group. A taken target with bit 1 set raises a misaligned-fetch exception (cause 0, `tval` = target) on the branch (no C in M2). A mispredict is `actual_npc != pred_npc`.
- **P1 extras:** MUL (3 stages, 128-bit product, MULH/MULHSU/MULHU/MULW), DIV (radix-2 iterative with a `DIV_INFLIGHT`-deep input FIFO, the RISC-V divide-by-zero and overflow results), CSR (§9) executed in EX.
- **LD / STA:** address generation in EX; the rest is in [core-lsu.md](core-lsu.md).

### 7.3 Bank 1's write port
ALU1 writes at *s*+3, CSR at *s*+3 (it occupies an A1 select), MUL at *s*+5, DIV whenever it finishes. A reservation vector over the next 5 write slots resolves them: a MUL claims *s*+5 when it reaches RF; a finished DIV claims slot *c*+3 if free; A1's select is blocked in any cycle whose *s*+3 slot is claimed. Nothing else writes bank 1.

## 8. ROB, commit, recovery (`tg_rob`)

### 8.1 Entries
- `ROB_ENTRIES` (48), `ROB_BANKS`-way interleaved LUTRAM payload written at DS: PC, instruction bits and `rvc`, rd, new and old physical register, kind (load, store, branch, CSR, FENCE, FENCE.I, WFI, MRET), decode-time exception cause, LQ/SQ index.
- **The commit slots' reads start at flip-flops** (timing, DR-145): the slots' entries (head + j), their payload banks and the banks' read rows are registered with the head, chosen by the commit count from the values for each count, and the head's own update takes the same choice. The payload, flag and FP-flag reads at the head need no adder or bank multiplexer before the LUTRAM (asserted equal to the head's window every cycle).
- **Flags per entry: `complete`, `exc`, `mispredict`, `mmio`** are toggle tables in LUTRAM (FPGA-friendly T2).
  - Each reporting port has a one-bit table of its own, indexed by ROB entry, and toggles it at the entry it reports. Every table therefore has one writer: 11 for `complete` at st, 6 for `exc`, and one each for `mispredict` and `mmio`.
  - A flag is the parity of its ports' tables XOR a bit the payload took at dispatch: that parity then, XOR the flag's initial value. Dispatch writes none of the tables, and they need no reset.
  - **The condition:** every live entry gets at most one report per flag per lap, and none as it is dispatched. Reports in a flush cycle are dropped, as the flip-flop flags dropped them. Later reports for squashed entries arrive before those entries are dispatched again (the flip-flop design relied on that too).
  - **Checked:** in simulation, a shadow copy of the old flip-flop flags checks the condition, and checks every cycle that the head's flags equal the old ones.
  - **Why:** the flags were 4 × `ROB_ENTRIES` flip-flops with up to 13 writers each (dispatch and every report port), each port through its own index decoder: about 900 LUT cells at st.
- **`replay` is XOR-banked LUTRAM (FPGA-friendly T2).** It can't be a toggle table: an entry can be marked more than once (two ordering violations).
  - **Writers:** dispatch clears it, one table per slot. The LSU's replay report and its two TLB-miss reports set it, a table each.
  - **Writing:** a writer stores its value XOR the other tables at its entry, read in the same cycle. The flag is the XOR of all the tables.
  - **Same-entry writes:** two writers at one entry in one cycle would cancel, and none occur (asserted). A setter's entry is live, so it is never one being dispatched. A TLB miss is a new access at AG, never a load the ordering search finds (that load already has its value). The LD and STA ports carry different instructions.
    - An earlier version guarded these cases with comparators. That put the LSU's late replay report on every dispatch table's write enable: the whole core's second-worst path (§13).
  - **Size:** at st, five 48 × 1 tables with six read ports each (the four other writers' entries and the two commit slots'), one RAM64M8 apiece. The tables need no reset, because dispatch clears an entry before anything reads it.
  - **Checked:** a shadow copy of the flip-flop flag, in simulation, must equal the tables' flag at every live commit slot.
- **One adder on the head's PC** serves both a serial instruction's next PC (+2 or +4) and the `tval` of a fetch fault on an instruction's second half (+2). The fault is a decode exception, which traps, so one instruction never needs both (asserted).
- **Whether a replay at the head is a DTLB miss:** the LSU says so (`hd_tlb`: the head is a load in `L_TLB` or a store with its `tlb` bit), so the ROB keeps no `tlb` bit. A missed load never gets an ordering replay, because it has no value.
- **FP exception flags (EXT_FD):** two LUTRAM tables by ROB entry, one per completion port. P4's F0 results write one and FP→int results (bank 1) the other; at commit, the op's result file picks the table.
- **Oldest-exception register** {ROB index, cause, `tval`} for exceptions found after dispatch (LSU, branch target, CSR); the oldest wins by ROB age (index plus wrap bit). **Oldest-mispredict register** {ROB index, target}, same rule. Both reset on a flush.
  - **The exception is chosen in parallel, not by a chain of compares.**
    - **Candidates:** the register, the CSR port, the branch port, the LSU's four ports and its store PMP port (below). Every pair is compared by ROB index.
    - **Why it is fast:** the indices arrive early, since the LSU sends each port's payload index whether or not it faults. The late valid bits only gate a one-hot select.
    - **Same result as the chain:** the oldest wins, the first candidate in the old order on a tie. `tval` is the best of the first three alone, as the chain left it.
    - **Checked:** in simulation the old chain runs beside it and must agree every cycle.
    - **Why:** the chain was the end of the whole core's worst paths at 100 MHz (§13), and the ROB's own worst path (−0.350 ns at 200 MHz out of context).
- **The trap target comes in two parts** (`tg_csr`):
  - **An exception's** is its vector's base, chosen by its cause's delegation.
  - **An interrupt's** adds 4 × its code in vectored mode. Its code and delegation are the CSR file's own and arrive early, so the 64-bit add stays off the exception's path.
  - The ROB picks one with `do_irq` in its redirect multiplexer, still one LUT6 per bit.
- **A replay at the head:** the refetch PC, the cause and `tval` are set before the head's TLB check (`hd_retry`, the LSU's DTLB lookup that cycle). They count only if the instruction flushes or traps.
- **Reports a cycle later** (DR-140, timing): the LSU's fault reports (#1) and the head's DTLB retry (#3).
  - With `ROB_STORE_REPORT_LATE` (#2, off in both profiles: lint-only, DR-140), the store completions and the ordering replay mark also arrive a cycle later, together, so a replayed load never commits first.
  - The ordering replay mark comes a cycle after the store's search in every profile: the LSU registers the violating load's LQ index and reads its ROB index then (timing, DR-145: the LQ's search and that read leave the ROB's replay tables). Without #2 the ROB holds commit at the replayed load for that cycle (`cmh_v`/`cmh_rob`), where the mark would have stopped it. Cycle-identical: the load cannot reach the head sooner, as the store that found it completes in the cycle of its search at the earliest.
- **Completion ports:** each ALU port, bank 1's write mux (MUL/DIV/CSR), the load pipe, the store queue (address and data both present), and dispatch.
- **A store's PMP denial after it completed** (core-lsu: the check a cycle after the store's decision, S2) arrives on an exception-only port: its own exception table, no completion, the cause `EXC_SACCESS`, the head's store VA as `tval`. Until it can show, the LSU holds commit at that store (`sth_v`/`sth_rob`, registered: the check's cycle, held for any store in it, and the report's). Commit stops before a held entry.

### 8.2 Commit
Up to `COMMIT_WIDTH` complete entries in order per cycle. Per retirement: CRAT update; the old physical register goes to its bank's free list (through the deferred-free stage, a pass-through in M2); the free list's committed head advances for the new one; LQ head or SQ commit mark; `minstret`; a trace record (§11).
- **Head-only entries** (slot 0, nothing else that cycle): exceptions, serialising instructions, replays.
- **Mispredict:** the branch retires (in any slot); the group ends there; flush and redirect to the oldest-mispredict target.
- **Exception:** TR_TRAP, trap entry (§9.3), flush, redirect to `mtvec` base.
- **Replay** (ordering violation): nothing retires; flush and refetch at the entry's PC. A replay marked `tlb` waits for the LSU instead: refetch once the DTLB translates the entry, or trap if the deciding walk faults (core-mmu.md).
- **Serialising:** CSR (apply the CSR write, §9.2), MRET (§9.3), FENCE and FENCE.I (wait until the SQ has drained; FENCE.I also invalidates the I$), WFI (wait until `mip & mie` is nonzero, or 4096 cycles: the ISA lets WFI complete at any time) retire alone, then flush and refetch at the next PC (MRET: at `mepc`).
- **Interrupts** (§9.4) are checked before the head retires.
- **Commit holds** (§8.1): the group stops before a store the LSU holds while its PMP denial may still come, and before a load whose ordering replay mark is on its way.
- **Return-address stack** (§3.2): each retiring instruction's stack operation goes to the committed copy. A second push in a group ends the group before it, so the copy has one write port.
- **TAGE** (§3.2): each retiring conditional branch moves commit's history and trains the tables; the youngest retiring instruction's FTQ entry frees the earlier ones. A conditional branch's mispredict is its direction (decode checks its taken target), so its outcome is its fetch-time direction XOR the mispredict.
- **The commit gate** is the flush and the trace's stall alone (timing, DR-145: in G6 the FP free list's init flag → rename's ready → commit → the free-list count and the CSR file, −1.40 ns). Rename's ready and the init flags are one-time flags after reset, and the ROB holds an entry only after rename fired, which needed them (asserted).

### 8.3 Flush
`flush_q` (with `flush_tid_q` and `redirect_pc_q`) is registered from commit and clears everything listed in §2. Committed stores stay in the SQ and keep draining.

### 8.4 Per thread (M7's step 3, DR-175; docs/spec/threading.md)
- Each thread has a head, a tail and the xRET-in-flight bits. A dispatch group is one thread's and advances its tail. A flush recovers the flushing instruction's thread (`flush_tid`, the head's tid): its tail goes back to its head. The heads go to rename per thread.
- Commit serves one thread a cycle: in merged mode the running thread. The oldest-exception and oldest-mispredict registers and the WFI counter are per thread; a report goes to its entry's thread (`rob_tid`).
- **Split mode (`SPLIT`, D1):** thread t owns entries [40t, 40t + 40) in smt2, and its pointers wrap there (`rob_add_t`, `rob_cnt_t`, `rob_start` in `tg_core_pkg`). The commit thread is chosen a cycle ahead (`ct_q`), so the head window is still read from flip-flops: the other thread whenever it has entries, so two busy threads alternate and an empty one is not served. With hart 1 (5d) a thread keeps the turn while it commits and the other thread's head is not actionable: the other thread's turn comes next cycle when its head is actionable (complete, marked for a replay or a TLB miss, or an MMIO load to issue: its flags read at its head through one more port on the flag tables, and its dispatch parities from a two-bit copy of the payload's), when this thread committed nothing, or after `RUN_K` = 4 turns in a row. `RUN_K` bounds the wait of the head operations the LSU runs only in their thread's turns (MMIO loads, atomics, walks at the head), asserted in simulation (a thread with entries, not parked in WFI, waits at most `RUN_K` cycles for a turn; `tests/isa/directed/turn_wait`). A thread that waited every other cycle beside a sibling whose head was not ready now commits every cycle; the turns' rule as built before 5d is in reports/commit-turns.md of the core track. The LSU's head checks, its MMIO load, `sq_drained` and `mmio_busy` follow the commit thread (`hd_tid_o`, step 4; core-lsu.md). Whether a commit group should also take the slots the served thread leaves (D7) is open: one thread per group is the cheap form, and the model is to price the other before step 5.
- The payload and the flag tables stay indexed by entry: in the split mode a thread's entries are a range of them, of whole bank rows.
- **Hart 1 runs (5c):** an interrupt is taken at either thread's head (tg_csr gives the head thread's, `hd_tid_o`). A report (completion, exception, mispredict, MMIO, replay) in a flush's cycle is dropped only when its entry is the flushed thread's (`rdrop`; every report while one thread runs), and the other thread's oldest-exception and oldest-mispredict registers take theirs: before, hart 0's flushes lost hart 1's completions and hart 1's head never completed. Commit waits while a trap's three cold-CSR writes run (tg_csr's `cold_busy`: one LUTRAM write port, and the other thread no longer waits behind the trap's flush). A thread whose head is a WFI still waiting at its last turn takes no commit turns until an interrupt is pending for it (registered) or its count ends; the count then runs every cycle, so a parked hart costs its sibling no commit bandwidth.

## 9. CSRs and traps (`tg_csr`)

### 9.1 CSR set (M-mode, RV64IM, Zicsr, Zicntr, Zifencei, 8 PMP entries, no triggers), as Spike defines it
| CSR | Behaviour |
|---|---|
| `misa` | `0x8000_0000_0000_1100`; bit M writable (clearing it makes MUL/DIV illegal) |
| `mvendorid`, `marchid`, `mimpid`, `mconfigptr` | 0 (the checker adopts the ID reads); `mhartid` = `CORE_ID`·`NUM_THREADS` + the thread (tid ^ `SOLO_TID`, §9.6) |
| `mstatus` | MIE, MPIE writable; MPP reads 3 (M only); everything else 0 |
| `mtvec` | written value with bit 1 cleared (direct and vectored) |
| `mie` | MSIE, MTIE, MEIE writable |
| `mip` | MSIP, MTIP, MEIP from the inputs, read-only (writes ignored); reads are `nondet` |
| `mscratch`, `mcause`, `mtval` | 64-bit read/write |
| `mepc` | bit 0 cleared on write; reads mask bit 1 too (no C) |
| `mcountinhibit` | CY and IR writable |
| `mcycle`, `minstret` | read/write; a write to `minstret` replaces that instruction's increment |
| `cycle`, `time`, `instret` | read-only aliases; `time` = the core's snapshot of the ACLINT's `mtime` (`mtime_q`, a cycle behind `mtime_i`; monotonic; DR-146); cycle and time reads are `nondet` |
| `mhpmcounter3–31`, `mhpmevent3–31` | read 0, writes ignored (counter reads `nondet`) |
| `tselect`, `tdata1–3`, `tinfo` | read 0, writes ignored |
| `mcontext` | 13 bits read/write |
| `pmpcfg0, 2, …, 14`, `pmpaddr0–63` | entries 0–7 implemented (`PMP_ENTRIES`, DR-167; 0–15 with `TG_PMP_ENTRIES=16`; Spike's WARL rules: lock, R=0/W=1 dropped, 54-bit addresses); the others read 0 and ignore writes (Spike with `--pmpregions` at the same count). Reset: entry 0 = NAPOT RWX over the whole space, as Spike. Checked by `tg_pmp` (core-mmu.md) |

Everything else is illegal (cause 2, `tval` = the instruction bits), as is a write to a read-only CSR. `csrrs/csrrc` with rs1 = x0 and the immediate forms with uimm = 0 do not write.

### 9.2 CSR instructions
Serialising: dispatched when the ROB is empty, issued on A1, executed in P1's EX: read, legality, new value. The read value returns through bank 1's write mux; the write is held in a pending register and applied when the instruction retires.

### 9.3 Trap entry and MRET
Exception or interrupt: `mepc` ← PC, `mcause`, `mtval` (0 for interrupts), `mstatus.MPIE` ← MIE, MIE ← 0, MPP ← M; PC ← `mtvec` base, + 4·cause for an interrupt in vectored mode. MRET: MIE ← MPIE, MPIE ← 1; PC ← `mepc`.

### 9.4 Interrupts
Pending = `mip & mie`; taken when `mstatus.MIE` is set, priority MEI, MSI, MTI. Taken at commit before the head instruction (TR_IRQ with `pc` = its PC), except when the head is a WFI (it retires first, and the interrupt is taken at the next instruction) or an MMIO load whose request is out. Nothing is taken while the ROB is empty.
- **The timer's pending bit is registered (DR-146).** The core keeps a snapshot of the ACLINT's `mtime` (`mtime_q`), so the ACLINT reaches the core register to register. The Sstc compare `mtime_q >= stimecmp` runs between registers into `stip_q`, which `mip.STIP` reads. The 64-bit compare thus leaves the interrupt selection and the commit decision: the full chip's "ACLINT timer → rename" path.
  - STIP shows two cycles after `mtime` crosses `stimecmp`, and a cycle after a write to `stimecmp`, `menvcfg` or `mip`. An interrupt is asynchronous, so the delay is legal.
  - Such a write retires alone and flushes, so no instruction reaches the ROB head before STIP has settled: no spurious interrupt after a write that clears it, none late after one that sets it. `tg_rob` asserts that no interrupt is taken within two cycles of a CSR instruction's retirement.
  - `time`, `mip` and `sip` reads are nondeterministic in lockstep, so the checker takes the RTL's values.

### 9.5 Storage: the cold CSRs in LUTRAM (FPGA-friendly T1)
- **What:** `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval` and their S counterparts live in one (16 · `NUM_THREADS`) × 64 `tg_ram_lut` (`u_cold`), addressed by {tid, csr[9], csr[2:0]} (§9.6). csr[9] is 1 for M and 0 for S; then scratch is 0, epc 1, cause 2, tval 3 and tvec 5.
  - They replace ten 64-bit registers with their write multiplexers, ten inputs of the CSR read multiplexer, and the trap vector's M/S multiplexer.
  - `stimecmp` and `satp` stay flip-flops: the timer compare and the MMU read them every cycle.
- **Two read ports:**
  - **Port 0** serves the CSR read in P1's EX. While an MRET or SRET is in flight, it serves that instruction's xepc (`xepc_o`) for the ROB's redirect.
    - The ROB registers which xRET is in flight when it dispatches it (`xret_v`, `xret_s`).
    - Both instructions are serial, so no CSR instruction executes meanwhile (asserted in `tg_csr`). The ROB asserts that each xRET it commits is the one named.
  - **Port 1** serves the trap vector, addressed by the delegation decision.
- **One write port,** taken by:
  - **the reset sweep:** PMP's 16-cycle counter (§10);
  - **trap entry:** xepc, xcause and xtval are written in the three cycles after the trap, from registers taken in the trap cycle. The privilege and status fields still change in the trap cycle.
  - **a CSR write** at commit.
- **Why the trap's writes may lag:** the trap's flush leaves the window empty longer than three cycles. In that time nothing commits, no trap or interrupt is taken (the ROB is empty), and no CSR instruction executes (asserted).
  - A CSR instruction can still be in EX in the flush cycle itself (`ex_v_q` clears at its end). It reads before the writes, but it is killed there: its result is never written back, and its pending write is dropped.

### 9.6 Per hart (M7's step 2, DR-175)
- **State:** each hart has its own hot state (`h_q`, one `csr_hart_t` a thread: privilege, the mstatus fields, misa, mie, the software pending bits, delegation, counter enables, envcfg, satp, the contexts and pmpcfg), its own rows of `u_cold` and `u_pmpaddr` (the tid is the top address bit; 32 deep fits the same RAM32M16 as 16), PMP descriptors, `stimecmp` and STIP, pending CSR write, and `mcycle`/`minstret` DSP pairs (R1).
- **Writes** go to the committing thread: slot 0's tid (`cm_tid[0]`), since CSR instructions, traps, MRET and SRET retire alone in slot 0. The retiring count goes to that thread's `minstret`. A flush drops the flushed thread's pending write (`flush_tid`).
- **Reads and outputs:** fetch and decode take each hart's privilege, status, satp and PMP state by their own thread (5b), the LSU and the walker by each access's (`*_h`, step 4, D6; core-lsu.md, core-mmu.md). With hart 1 (5c) the CSR read in EX is the executing thread's (`ex_pl.tid`: its state, counters, `mhartid`, cold rows and `pmpaddr`, and tg_fcsr's flags and mode), and the interrupt choice, `wfi_wake` and an xRET's xepc are the commit head's thread's (`hd_tid`, the ROB's registered choice). The xepc read moves to `u_cold`'s port 1, so port 0 serves either thread's CSR read: a legal xRET is serial and alone at its thread's head, so no exception there needs port 1's vector meanwhile. Each hart's counters load from its own pending write (the DSP load lands a cycle late, when the committing thread may be the other). The scalar outputs stay the running thread's, for the merged-mode checks.
- **Harts:** `mhartid` and the trace's hart field are `CORE_ID`·`NUM_THREADS` + (tid ^ `SOLO_TID`), and thread t takes the interrupt lines of that hart. So under `SOLO_TID` the one thread, tid 1 inside the core, is hart 0 to software and to the SoC.
- **Reset:** the 16-cycle sweep writes the running thread's rows, and only its descriptors are computed after it, so reset takes the cycles it did. With hart 1 the sweep writes both harts' rows (32 cycles) and both harts' descriptors are computed (5c).
- **Without SMT** (`TID_W` = 0) the commit and flush threads are the constant 0, so the st core has no selects.

## 10. Reset sequence
After `rst`, an init counter runs for 64 cycles before fetch starts: it fills the free lists, writes zero into bank 0 indices 0–31, and invalidates the micro-BTB. With hart 1 the same 32 cycles zero its homes (5c): x1–x16 in bank 1 through tg_exec's port 1 (`res_q[1]` held at zero), x17–x31 in the load bank and f0–f31 in F1 through the LSU's result register (zero from reset to the first load, so no multiplexer on the data).
- **Other tables have their own sweeps, run alongside:**
  - the I$ valid bits (§3.1);
  - the D$ state (core-lsu);
  - the maps' committed banks and the ready tables (§5.2);
  - the DTLB's CAM tables (core-mmu);
  - the cold CSRs (§9.5), on PMP's 16-cycle counter.
- **Everything else** resets through control state (valid bits, pointers), or holds data that is written before it is read.
- **The exception is the direction counters (§3.2),** which keep whatever they held.
- **Measured (2026-10-14, st, 9b14471):**
  - Under `--rand-reset` (every register without a reset random), 99 of the 176 riscv-tests `-p` programs take other cycle counts than from zero (seeds 1 and 2).
  - With only the counters started at zero, all 176 match, for seeds 1–3.
  - So no other state left out of the reset changes timing.

## 11. Commit trace
Records leave through a register one cycle after commit. `rd_value` is read from the register file through `COMMIT_WIDTH` dedicated read ports. In simulation they cost nothing; for the FPGA trace (M4) they are a parameter to settle with the SoC track. `rd_deferred` is 0 in M2. `nondet` marks reads of `cycle/mcycle`, `time`, `mip`, the ID CSRs and `mhpmcounter*`; `mmio_ld` marks loads from device or ROM regions. `mem_ld` (interfaces.md v1.5) marks a read of memory, with `mem_vaddr` and `mem_size` the read's: a load (integer, FP or device) takes its LQ entry's VA and size, read at commit by the slot's LQ index (a copy of the LQ's VA LUTRAM, trace builds only); LR and an AMO take their SQ entry's, which an AMO's write shares; SC never has it.

## 12. Parameters and builds
All widths come from `tg_pkg` (`DECODE_WIDTH`, `N_ALU`, `ROB_BANKS`, `FL_BANKS`, sizes). Core-local constants (`DIV_INFLIGHT` = 4, counter-table size) are in `tg_core_pkg`. Every per-slot structure is a generate loop. The `smt2` builds compile and lint with `tid` carried everywhere; in M2 only hart 0 runs (hart 1 never fetches).

**M6 feature switches** (`tg_core_pkg`; each `=0|1`, for bisection and ablation):
- `TG_RAS` (`RAS_ON`, on): the return-address stack (§3.2).
- `TG_TAGE` (`TAGE_ON`, on): TAGE-lite and the FTQ, with F2's prediction of straddlers and (with `TG_RAS`) returns (§3.2).
- `TG_TAGE_NT`, `TG_TAGE_LI`, `TG_TAGE_TW`, `TG_TAGE_BI`: TAGE-lite's sizes (§3.2; two tables of 2K, DR-170).
- `TG_SPEC_WAKE` (`SPEC_WAKE`, on, DR-154): speculative load wakeup with a shadow cancel (plan §4.6; §6; the FPU track's `tg_issue` and `tg_exec`, with `spec_cancel` from one to the other). `TG_SPEC_WAKE=0` wakes loads' dependants on the confirmed result, cycle for cycle as before.
- `TG_SPEC_WAKE_FILT` (`SPEC_WAKE_FILT`, 1): the speculative wakeup's filter (§6): a load whose PC's loads keep failing to complete in M2 does not wake its dependants speculatively. `TG_SPEC_WAKE_FILT=2`: D$ misses do not count as failures. `TG_SPEC_WAKE_FILT=0` lets every tracked load wake its dependants, cycle for cycle as before the filter.
- `TG_PMP_ENTRIES` (`PMP_ENTRIES`, 8; DR-167): PMP entries, 8 or 16 (core-mmu.md, PMP; §9.1).
- `TG_URF` (`URF`, off; DR-174): the issue-time integer register reads in double-pumped UltraRAM (§7.1). The core then takes `clk2x`; at 0 the port is unused.
- `TG_SOLO_TID` (`SOLO_TID`, off; DR-175): M7's test mode, smt2 builds only. The core's one thread runs as tid 1 inside the core while it stays hart 0 to software, so the tests exercise the per-thread paths (threading.md).
- `TG_SPLIT` (`SPLIT`, off; DR-175, D1): M7's split mode, smt2 builds only. Each thread owns half the ROB, LQ and SQ (§5.4, §8.4, core-lsu.md); hart 1 turns it on (step 5), and before that it runs the one thread in its half, so the halves are tested (threading.md). Not the same cycles: the thread's window is half.

## 13. Timing and area
The structures are the spikes' (S2, S3, S5), so their timing results apply where adopted. Area is held to the per-unit budgets (docs/perf/budgets.md) by the budget flow (`fpga/budget`: `tg_core` with its hierarchy kept, units read from its instances).

**Where the area levers land** (plan §8.5; no lever below costs IPC):

| Lever | Where | State |
|---|---|---|
| PMP results cached in the TLBs (plan §4.10) | `tg_ptw` (the fill checks the page base, and against every entry that no region boundary lies inside the page), `tg_tlb` (cached bits), `tg_fetch`/`tg_lsu` (cached or checked), `tg_csr` (region descriptors, one entry per cycle after a PMP write; `pmpaddr` in LUTRAM) | done: four checkers (fetch block, LD, STA, walker) instead of seven |
| No flip-flop arrays (plan §8.3) | D$ state (valid bits apart from round robin/T/dirty), I$ valid bits, issue-queue payloads (per-queue formats, exact bits) | done |
| R1 counters in DSP48E2 (T6) | `tg_csr`: `mcycle`, `minstret` (the HPM counters read zero) as `tg_dsp_ctr` pairs: the low slice counts or loads q[47:0], the high slice q[63:48] adds this cycle's carry, known from the low half's pattern detector; the counters, adders and load multiplexers are all in the DSPs (4 slices) | done (2300494); the mapping is checked against the vendor's DSP48E2 model on Icarus (`tests/unit/csr_ctr`) |
| R2 cold CSRs in LUTRAM (T1) | `tg_csr` (§9.5): xtvec, xscratch, xepc, xcause, xtval of M and S in one 16 × 64 table with two read ports. Trap entry writes its three in the cycles after the trap, so one write port suffices. The CSR read port also serves the xRET's xepc. | done (50746f6, 43c2d0f): cycle-identical; CSR 1,615 → 1,368 at st, −500 flip-flops. M7's step 2 gives each hart its rows: one more address bit (§9.6) |
| ROB replay flag XOR-banked (T2) | `tg_rob` (§8.1): a table per writer (dispatch clears, the LSU's three setters) | done (9646d13): cycle-identical, shadow-checked; ROB 2,083 → 1,891 at st |
| R3 rename maps in LUTRAM | `tg_rename` (§5.2) | done: a bank per write port, live-value tables, versioned recovery (no added recovery latency) |
| Ready tables in LUTRAM (FPGA-friendly T2) | `tg_rdytab`: per register, a set phase S in a table per bank (one writer: the bank's register-file port) and an allocation phase A XOR-banked into W tables; ready = (A == S). Each free list's next W registers are cleared every cycle | done: cycle-identical; measured in §16 |
| Rename maps XOR-banked (T2) | `tg_rmap`: no live-value tables; a register's entry is the XOR of its banks | done: cycle-identical |
| MX row destinations in LUTRAM (T2) | `tg_rename`: `rowdst` banked by DS slot, XORed | done: cycle-identical |
| TLB match as a LUTRAM CAM (T5) | `tg_tlb` (`CAM`): six slice tables, a key store, a three-cycle table update behind a one-cycle fill | DTLB: done, cycle-identical. ITLB: rejected (LUT-neutral), flip-flops kept (9b14471; core-mmu) |
| ROB flags as toggle tables (T2) | `tg_rob`: `complete`, `exc`, `mispredict`, `mmio` as one-writer LUTRAM tables per report port, XORed with a dispatch-time parity bit in the payload | done: cycle-identical (shadow-checked in simulation) |
| R6 set-associative TLBs | `tg_tlb` | not adopted (IPC); M6 decision |
| R7 cold storage | `tg_lsu`: LQ/SQ virtual addresses and SQ data in LUTRAM (the CAMs keep physical addresses); ROB payload in LUTRAM; FTQ PCs | done, FTQ with M6 |
| TLB entries | `tg_tlb`: no ASID tags (satp changes and SFENCE.VMA flush), a 22-bit PPN (`PA_W` = 34), the leaf in LUTRAM read at the encoded match (the match stays in flip-flops) | done |
| LSU searches and byte lanes | `tg_lsu`: age searches as two priority encoders each (core-lsu.md, Timing and area); store bytes replicated, not shifted; aligned extraction of loaded elements; the MMIO pick at the LQ head; LQ/SQ fields written at AG/STA instead of dispatch; LUTRAM copies of the queue addresses for reads by index; an atomic reads through the SQ head's ports | done |
| ROB tables | `tg_rob`: FP flags in two one-port LUTRAMs, no `tlb` bit (the LSU's `hd_tlb`) | done: ROB 3,308 → 2,920 at st |
| Region decode (DR-120) | `tg_map_pkg::pma_of`: naturally aligned power-of-two regions matched by prefix, with the range test kept for any other region | done: 136 → 10 LUTs per instance (fetch, load AG, STA, walker; the crossbar) |
| R14 implementation | the budget flow keeps the hierarchy (`-flatten none`) | datapath registers mostly reset-free; area directives not applied yet |
| Integer register file in UltraRAM (DR-174, the reserve: `URF`, off by default) | `tg_irf`, `tg_urf` (§7.1): the six issue-time read ports in 9 double-pumped UltraRAMs on `clk2x`; store data and the trace ports on LUTRAM | built, off: −1,290 LUTs per core (st and smt2: LUTRAM −1,320, +26 flip-flops), +9 UltraRAMs; the same cycles. Turned on only if the chip runs out of LUTs |
| The walker's PMP checks on the STA port's checker (adopted by the user: DR-139, superseding DR-122) | `tg_ptw` (no checker of its own), `tg_lsu` (the STA checker's input multiplexer: the walker's address in a cycle without a store address) | done: −0.83K LUTs per core. Cycle cost from `make cycle-identical` against fn3's head, st / smt2: isa +0.052% / +0.228%, stress +0.098% / −0.098%, bench 0 / 0, random +0.003% / −0.018% |

**Timing cuts that cost cycles (DR-140: the user decided each one, under DR-135).** Cycle costs are from `make cycle-identical`, as change in cycles per suite, st / smt2. Each is measured against the commit before it on fn5, whose base is fn4's head (028f45e).

*Hardwired:*

| # | Cut | Timing | isa | stress | bench | random |
|---|---|---|---|---|---|---|
| #1 | The LSU's fault reports reach the ROB a cycle later (§8.1) | the address stage's fault decision leaves the ROB's exception register | 0 / 0 | 0 / 0 | 0 / 0 | −0.005% / +0.074% |
| #3 | The ROB head's DTLB retry reaches the ROB a cycle later (§8.1) | the head's DTLB lookup leaves the commit redirect | +0.161% / −0.197% | +0.051% / +0.012% | 0 / 0 | +0.002% / +0.072% |
| #6 | The fetch PMP check a cycle later, on translated pages that a PMP region boundary splits (§3.1) | F1's ITLB → PMP path | identical | identical | identical | identical |

- **#6 under Linux:** identical on the suites, but with the walker's PMP check per page size (until fn7) the Linux boot was +2.218% slower in st and +1.648% in smt2 (`make cycle-identical BOOT=20`, records retired in 20.09M cycles), because every 2M kernel page counted as split. With the per-page check, #6 costs 0 on the boot: identical with and without it, in both profiles.
| #7 | F2's actions on F1 registered (§3.1) | the F2 family into the fetch PC and F2's enables | +0.001% / −0.002% | −0.010% / −0.035% | −0.003% / +0.032% | −0.006% / +0.006% |

- #3's cost differs from its first measurement, which was made on fn3. Since fn4 the head's check has its own DTLB lookup.

*Build switches* (`tg_core_pkg`): generate branches, chosen at elaboration, so each setting builds only its own logic. `TG_TIMING_CUTS=0|1` forces a profile. Each switch also has its own define over its profile value (`TG_ROB_STORE_REPORT_LATE`, `TG_LSU_AG_SPLIT`, `TG_DC_AMO_READ_REG`, `TG_DE_STAGE`, `TG_ROB_HEAD_TLB_LATE`, `TG_LSU_MMIO_PMP_REG`, `TG_DC_PORTB_WREG`, each `=0|1`).

| # | Switch | What | Timing |
|---|---|---|---|
| #2 | `ROB_STORE_REPORT_LATE` | the store completions and the ordering replay mark reach the ROB a cycle later, together (§8.1) | the store address's TLB and PMP decision and the LQ's ordering search leave the ROB's tables |
| #4 | `LSU_AG_SPLIT` | the address-stage split (core-lsu.md) | the address add leaves the address stage's decisions |
| #5 | `DC_AMO_READ_REG` | an atomic's D$ read data is registered (core-lsu.md) | the D$ atomic path, block RAM to block RAM |
| #8 | `DE_STAGE` | one more decode stage (§3.4) | the DE family |
| #9 | `ROB_HEAD_TLB_LATE` | the ROB head's DTLB check looks up the head's VA as registered a cycle earlier, from the head's second cycle (DR-144, B3). Off: a second lookup takes the committing store's VA beside the LQ head's, and the head's selection picks last (B2, cycle-exact; the DTLB has four ports) | the head's selection and its VA reads leave the walker's start |
| #10 | `LSU_MMIO_PMP_REG` | an MMIO load's PMP verdict is registered before its state takes it: the LQ head's MMIO issue waits while its load checks (bare and M mode, or a page that a region boundary splits); the fault reports in the check's cycle (DR-148; core-lsu.md) | the load PMP checker leaves the LQ state's enables, through the MMIO issue |
| #11 | `DC_PORTB_WREG` | the D$'s port-B block-RAM writes come from a register a cycle later; port B's reads wait a cycle while one lands, and a load that read the row in the write's second cycle retries (DR-148; core-lsu.md) | the store port's decision leaves port B's address, byte enables and data into the 32 data block RAMs |

*Profiles* (only these are supported; DR-140 as the user decided it after DR-141's board runs):
- **default** (the shipping profile): #4, #5, #9, #10 and #11 on, #2 and #8 off (#10 and #11 added under DR-148, the 115 MHz target).
- **fallback** (`TG_TIMING_CUTS=0`): all seven off. It is cycle-identical to the core without the switches (fn5's da48d96) in all four configurations, 800 of 800 programs each; with #9 off it was checked again against fn7's fallback (fcd9298), also 800 of 800 in all four.
- **#2 on** (`TG_ROB_STORE_REPORT_LATE=1`) and **#8 on** (`TG_DE_STAGE=1`) are lint-only, on top of the default. Each is verified again only if the user turns it on. #8 cost bench +2.5% / +2.3% when measured; #2's cost is below.

*Costs* (isa / stress / bench / random): the fallback against fn4's head, and the default against the fallback (6857589 against 3735313).

| Config | fallback | default |
|---|---|---|
| st | +0.163% / +0.041% / −0.003% / −0.009% | +0.636% / +0.353% / +0.123% / +0.065% |
| smt2 | −0.198% / −0.023% / +0.032% / +0.152% | +0.764% / +0.053% / +0.066% / −0.104% |
| st_w3 | +0.041% / +0.027% / 0.000% / +0.194% | +0.743% / +0.074% / +0.105% / +0.043% |
| smt2_w3 | +0.145% / +0.014% / 0.000% / +0.210% | +0.645% / +0.126% / +0.004% / +0.132% |

- **The fallback costs exactly what the hardwired cuts sum to** (st and smt2 to the 0.001%).
- **#9 (DR-144)**, the default against the default without it: st +0.008% / +0.085% / 0 / −0.019%, smt2 +0.022% / +0.065% / 0 / +0.132% (isa / stress / bench / random). Where the suites show 0, the Linux boot (`BOOT=20`, 20.09M cycles) shows the cost: one core retires 0.017% fewer records in st (13,991,941 against 13,994,292) and 0.007% fewer in smt2 (15,670,286 against 15,671,361); two cores 0.003% fewer in st (15,712,385 against 15,712,834) and the same in smt2. Its timing: the walker-start family from 19–20 logic levels to 14 (B2 in the fallback: 12–14). LSU LUTs (st, budget flow, synthesised alone, which varies by about ±100): about 0 in the default plus 29 flip-flops; the fallback's second lookup +194 to +342, of which +104 is LUTRAM.
- **The Linux boot** (instructions retired in the first 20.09M cycles, `make cycle-identical BOOT=20`): the default retires 0.084% fewer than the fallback in st (13,994,292 against 14,006,018) and 0.117% fewer in smt2 (15,671,361 against 15,689,643). With #2 on it was 0.153% and 0.172% fewer.
- **Why #2 is off.** On the board (DR-141), #2 alone cost syscall +3.4% and Dhrystone +0.7%; #4 and #5 together cost memcpy (1 MiB) +1.9%, tlbwalk +1.1% and Dhrystone +1.5%. In simulation, the default with #2 cost st +1.313% / +0.465% / +0.419% / −0.045% against fn4's head, its bench cost above the switches' separate costs, through Dhrystone:
  - Dhrystone in that default, st: rv64im +1.57%, rv64gcb +2.97% (native latency).
  - #2 alone: +0.87% / +0.59%. #4 alone: +0.74% / +0.34%. #5 alone: identical.
  - Together they are superlinear on rv64gcb.
- **The cause** (measured with commit and rename counters, st, rv64gcb): stores wait at the ROB head for their completion report, and #4 and #2 each delay that report by a cycle.
  - Cycles in which the head is a store not yet complete: 2,744 in the fallback, 7,129 with #4 and #5, 13,196 in the default.
  - A mispredict is recovered when its branch commits, so it waits behind those stores. The default also mispredicts 4% more often on rv64gcb (10,786 flushes against 10,347), which makes the pair superlinear there.
  - Not store-to-load forwarding: Dhrystone's loads that meet older stores are each fully covered by one store (1,499 forwards, none partial; `strcmp` stops at the first difference). A byte-wise forwarding prototype changed no bench program.
  - CoreMark moves by −0.3% to +0.45%.
  - The user's options were the default without #2, or a bypass at the commit slots that keeps #2's register and takes its cycle back. They chose the first (DR-140).

- The commit trace off in production builds: −1,466 LUTs, −740 flip-flops and −888 LUTRAM at st, measured with `trace_o` unconnected. It removes a function, the M4 trace ring, and FPGA lockstep. This is the user's option (DR-121).

**Follow-ups (functional, with deadlines):**
- **LR/SC forward progress under read probes. Deadline: M8 (dual core). Done, with the two-core forward-progress holds (core-lsu.md, the D$'s probes):** an LR's young reservation holds probes until its SC, at most 64 cycles.
  - **The problem:** a probe that only takes away T (toB, from another core's read) also ends the reservation. The spec's eventual-success guarantee for a constrained LR/SC loop covers contention that is only reads, so two cores could starve an SC.
  - **The fix:** a reservation hold. Probes wait while an LR's reservation is young, until its SC or for at most 64 cycles. All probes wait, not only the reserved line's: one register, bounded either way. Nothing in that wait depends on A-channel progress.
  - **Found by:** the directed `amo` test under `--probe-rate=150 --bp=20`. It needed up to about 30 tries, and its bound is now 1,024 (bae805e).

Remaining M2/M3 costs: 64-bit PCs in the ROB and queue payloads (FTQ, M6), the trace read ports (§11), D$ data rows of 128 bits (4 block RAMs per way at a quarter of their depth).

## 14. Verification
Spike lockstep on every test (verification.md): riscv-tests, the directed interrupt tests, CoreMark and Dhrystone, in `st` and `st_w3`, with latency, back-pressure and probe stress options. Assertions (`ifndef SYNTHESIS`) on queue occupancy, free-list over/underflow, ROB order and one-hot grants.

## 15. Provenance
- Out-of-order structure (rename with a free list and committed map, ROB, commit-time recovery): Smith and Pleszkun (1988), Hennessy and Patterson, *Computer Architecture*, 6th ed., ch. 3.
- Writer-sharded register banks: Seznec et al., MICRO 2002. Dependency-vector wakeup and age-matrix select: Wong's FPGA scheduler papers (cited in the plan, Appendix A). Long-latency tags and early retirement: plan §4.5 (A73 behaviour reported by Chips and Cheese).
- Micro-BTB, pre-decode and compaction: spike S5 (our RTL); block-based fetch: Reinman et al., ISCA 1999.
- RISC-V semantics: the unprivileged ISA (20240411) and privileged spec (1.13); CSR WARL behaviour as Spike implements it (Spike used as a reference model, as allowed by plan §2.3).
- No other core's RTL was read.

## 16. History and lessons (core track)

**Starting point (main d04ae26, 2026-10-13):**
- **Scope:** the M2 core with the M3 features behind their switches.
- **Size:** 82,549 LUTs at st, with the hierarchy kept (88K flattened), against the 38,220 budget.
- **Where they went (area_synth.md §4):**
  - LSU: 34.4K. The D$ took 13.2K, with its state and tags in flip-flops; each of the LD and STA PMP checkers took 3.1K.
  - Front end: 16.9K, four PMP checkers among it.
  - Rename: 11.9K.
  - Execute: 8.5K.
  - Issue: 5.1K.
  - ROB: 2.7K.
  - CSRs: 1.5K.
  - Decode: 1.4K.
- **PMP:** seven checkers at about 3.1K each made up a quarter of the core.

**The area pass (2026-10-14).** None of these steps changed IPC: CoreMark's cycle counts were identical before and after each one.

| Step | Commit | Measured |
|---|---|---|
| PMP results cached in the TLB entries (plan §4.10). Region descriptors are precomputed, and checks use a shared TOR compare. Four checkers remain (fetch block, LD, STA, walker), and the walker checks the page once at fill. | 8436f16, 7b19a3f | Each checker is about 0.87K instead of 3.1K: 3.5K for all four instead of 21.8K. Descriptors are computed one entry per cycle after a PMP write. |
| D$ state in LUTRAM. The valid bits are apart because the load port reads only them. | 8436f16, 0226254 | D$ 13.2K → 3.5K |
| Rename: producer info in the RAT instead of per-physical-register tables. The maps are in LUTRAM with live-value tables and versioned recovery (R3). | 621dd64, 69c9d7e | 11.9K → 3.1K, with no added recovery latency |
| TLBs: no ASID tags, a 22-bit PPN, AND-OR lookup | 7311595 | DTLB 2.7K with two lookups |
| LSU queues keep physical addresses; virtual addresses and store data live in LUTRAM (R7) | 362ace2 | — |
| Issue-queue payload formats per port | 0226254, 82591f5 | Exact LUTRAM primitive counts; LD/STA offsets of 12 bits |
| I$ valid bits in LUTRAM, cleared by a sweep | 5c9f6d0 | front end 6,137 → 5,254 |
| Wakeup tags (AR-1): 16 tags plus the LLTs instead of ROB-index columns | b2e38b1 | st: 32 columns instead of 64. Core 45,088 → 44,407 LUTs (issue 4,776 → 4,264, rename −94, ROB −90) and −1,286 FFs. The study estimated −1.0 to −1.2K at st: the small st window (64 columns) and the earlier payload trims left less to take |

- **Result:** 44,407 LUTs at st with AR-1 (b2e38b1), and 58,269 at st_w3 (525e875, before AR-1).
- **Still over budget:**
  - the LSU's own logic, about 7.8K;
  - the D$ data, 32 BRAM36 at a quarter of their depth;
  - rename, ROB and CSRs.
- **Timing:** not yet measured on the full core after these changes. The cached PMP bits take the checkers off the AG and F1 paths. The LUTRAM RAT adds a read level in RN.

**What the first cut did that cost area, and why:**
- The PMP checkers were written straight from the specification. Each derived the NAPOT mask from `pmpaddr` per entry and per access, and there were seven of them.
- Per-physical-register tables (producer ID, 1-cycle flag, MX row) with 2W read ports: they were the simplest way to name producers.
- Flip-flop arrays for the cache state, the TLB fields, and the LSU's 64-bit virtual addresses and store data: easy flash clears and simple reads.
- One ~400-bit payload for every issue queue.
- The spike's ROB-index wakeup columns, so the window size set the scheduler's width.

**What I'd write differently from the first commit:**
- Start from the per-unit budgets and plan §8.3 (storage in LUTRAM or block RAM).
- Compute anything derived from CSRs at write time.
- Give each storage structure exactly the bits its readers use.
- Measure each module with the hierarchy kept from the first synthesis.

**Bugs and incidents:**
- **I$ refill race (soc track, Linux on `tanager_soc`, fixed in b5e11f4).**
  - **What went wrong:** the refill rewrote a victim way that still looked valid under its old tag, so a fetch after a redirect executed another line's bytes.
  - **Why lockstep missed it:** the riscv-tests, CoreMark and the random programs fit in the 32 KiB I$, so they never evicted lines this way.
  - **What guards it now:** an assertion built from the soc track's probe.
  - **Lesson:** long boots exercise eviction paths that the suites do not.
- **Build-host stall (2026-10-14, 03:30–04:01).**
  - **What happened:** a whole-core budget synthesis from this branch ran the old `tools/vivado_run.sh`, with 3 slots and no memory declaration. Its 7 worker processes (about 10 GB) ran beside two full-device runs, and the host thrashed for 31 minutes.
  - **Fix:** merge main before heavy jobs, and declare `TANAGER_VIVADO_MEM_GB=10` for core syntheses.

**F and D (2026-10-14):**
- The FPU track built the FP back end (P4: `tg_fp_exec`, `tg_fprf`, `tg_fcsr`) to an interface agreed in advance. The core track built decode, FP rename, IQ-FP and the LSU, ROB and CSR hooks behind `EXT_FD` (core-fp.md).
- Wiring them together took one afternoon. On the first build, all 23 FP riscv-tests passed in lockstep.
- **Area at st (b53b0a5, hierarchy kept):** 56,469 LUTs with F/D, against 44,407 without (+12.1K).
  - P4 (`tg_fp_exec`): 7,861, of which the FPU units are 5,832 and the FP register file 1,108.
  - Rename: +1.6K (the FP map, free lists and ready table).
  - Issue: +1.1K (IQ-FP).
  - ROB and CSRs: +0.5K. LSU: +0.6K.
- ACT4's F/D configuration found two core bugs (P4's assertions caught the first):
  - an FP→int op with rd = x0 carried no LLT column;
  - misa.F/D were read-only, where Spike lets software clear them.

**Other bugs found with the full ACT4 plan lists (685 and 895 tests, against 355 in my earlier ELF set):**
- **satp:** a write with an unsupported MODE wrote ASID and PPN anyway.
- **Sm_csr_ro "fetch bug" (verification track):** this was the I$ refill race. Reproduced on the M2 core at 41be4a0, it fails 0/2 without the refill fix and passes 2/2 with it.
- **Lesson:** rebuild the ACT4 ELFs whenever the plan list grows. A stale ELF set hid these tests.

**Second area pass (2026-10-14, after F/D):**
- **Starting point:** main cb8ff6c. st 56,461 LUTs, smt2 62,501, with lsu_mmu the largest unit at 17.8K (st) and 22.3K (smt2).
- **Proof of no IPC:** lockstep proves only correctness. Each step was also run against its predecessor on the same ELFs (326 riscv-tests, CoreMark A/B, Dhrystone), natively and under memory stress, and the cycle and instret counts were compared.

| Step | Commit | Measured (st) |
|---|---|---|
| LSU age searches as two priority encoders each (the oldest from the head, or from slot 0; the youngest below a bound, or overall) | 2aa103d | the LSU's own logic, for the LSU steps together: 8,374 → 5,020 at st, 12,822 → 7,098 at smt2 |
| TLB leaves in LUTRAM, read at the OR-encoded match | 9bf465f | DTLB 2,741 → 1,496 (flip-flops 1,989 → 965); ITLB 745 → 492 |
| The walker's PMP checks on the STA port's checker | 4b85114 | `tg_ptw` 1,073 → 193; the STA checker 861 → 911 (its input mux). **Reverted** (5c124f2) under D18 and moved to the reserve (§13): walks and store addresses were not exclusive |
| MMIO pick at the LQ head; store bytes replicated instead of shifted | a16116f | (in the LSU line above); `tg_dcache` 3,468 → 3,357 (its store write data) |
| Divider: one 64-bit rotation and a mask instead of a 128-bit shifter | 8ed931c | 1,323 → 1,425: **worse**, reverted (a32d2aa) |
| LQ fields written at AG, SQ fields at STA (no dispatch-slot multiplexers) | 6b70b1d | (in the LSU line); IQ-LD 603 → 654 (its payload, LUTRAM 32 → 64) |
| LQ cold fields in LUTRAM with the VA | 8a5c651 | (in the LSU line); `u_lqc` 144 LUTRAM for the VA alone was 112 |
| One AG report per LSU port into the ROB (14 index decoders instead of 17) | 935dc2b | ROB +20, LSU −12: **no gain**, reverted (a926037) |

- **Result:**
  - st: 56,461 → 50,768 LUTs (a32d2aa), −5.7K (−10%); flip-flops 23,091 → 21,292. lsu_mmu 17,819 → 12,307, fe 5,257 → 5,004.
  - smt2: 62,501 → 54,506 (8a5c651, still with the divider rotation, +0.1K), −8.0K (−12.8%). lsu_mmu 22,281 → 14,405: the larger smt2 queues gained more from the searches.
  - a926037 drops the neutral AG-report merge from a32d2aa, and 5c124f2 gives the walker its checker back (+0.83K): about 51.6K at st.
- **Two steps measured worse or level and were reverted:**
  - The divider's rotation: the 128-bit shift of a half-zero value maps well already.
  - The merged AG reports: per-kind write qualifiers in every ROB entry cost what the decoders saved.
  - Lesson: measure even "obvious" savings before keeping them.
- **The walker's shared checker** was the one step that changed cycles. A walk step waited a cycle when it met an STA: +0.11% cycles in total on the 149 `-v` riscv-tests, which fault in every page, and +0.88% at worst. The coordinator's D18 check sent it back: sharing comes last unless the users are exclusive by construction. It is reverted, so the pass as merged is cycle-identical to main everywhere.

**What the first cut did that cost area, and why:**
- Each age search was written as "distance from the head" arithmetic and a running minimum. That is the obvious reading of "oldest", and it was the same shape in all four searches.
- The TLB leaves sat in flip-flops read through an AND-OR, as in spike S4. The spike's TLB was small, and LUTRAM did not look necessary there.
- LQ entries were filled at dispatch, the way the ROB is. Most of their fields are not needed until AG, and that is where a single write port is free.

**What I'd write differently:** for every queue field, ask where it is first read. A field read only by index belongs in LUTRAM, written at that point. A field read by a search belongs in flip-flops.

**Linux boots (2026-10-14).**
- **The run:** OpenSBI v1.9, then Linux (Buildroot, lp64d), then userspace (syslogd, klogd, sysctl, network, crond), then `TANAGER-BOOT-OK`, on `tanager_soc` in Verilator. The core was main cb8ff6c with F/D on: 335.4 M cycles and 137.7 M instructions retired (3.3 h at 4 threads), with no oops and no assertion. The soc track's images and snapshot (`make -C tests/unit/boot linux`).
- **Core bugs it needed:** only the I$ refill race (b5e11f4), found by the soc track's earlier kernel runs. With F/D, the userspace runs lp64d binaries.
- **The area-pass core:** it ran the same boot to the 60 M-cycle cap, at the same kernel point and instruction count as main's.

**Third area pass (2026-10-14, after the D18 check), from LUT attributions:**
- **Method:** each unit was synthesised out of context, and every LUT was grouped by the signal it drives (`get_cells -filter {PRIMITIVE_SUBGROUP == LUT}`). That shows where a unit's own logic goes. Each step was then measured in the core and compared cycle for cycle with main.
- **The walker's shared PMP checker was reverted (5c124f2).** It was not exclusive by construction (D18), so its −0.83K is a reserve lever (§13).

| Step | Commit | Measured (st) |
|---|---|---|
| LSU: aligned extraction (`ext_al`), the atomic through the SQ head's ports, LUTRAM copies of the queue addresses for reads by index | 45af062 | lsu_mmu 13,266 → 12,622 (with the ROB step) |
| ROB: FP flags in two one-port LUTRAMs; no `tlb` bit (the LSU's `hd_tlb`) | 625ef03 | ROB 3,308 → 2,920, flip-flops −292 |
| R1: counters with `use_dsp` | c86fd95 | CSR −30 (2 DSPs). Vivado maps the adders, not the counters |
| Rename: store-data readiness from RN | 46e3bba | rename +8: **reverted** (2196f12) |
| D$: one way multiplexer for port B's read data (probes, releases, atomics) | a166670 | `tg_dcache` 3,274 → 2,770 |
| LSU exceptions' tval read at the head (LQ head / SQ commit point VA) | 35e15db | LSU −130, ROB −133 |
| MX rows confirmed by the issue queue's ROB IDs (no `rowdst_q`) | a95a397 | −69 LUTs, but **not cycle-identical**: reverted (279fe46). The old `rowdst_q` check also accepts a row whose new occupant did not update `rowdst_q` (a branch with no rd, MUL/DIV/CSR on A1): a false MX dependency. The ROB-ID check rejects those, which moves wakeup timing (Dhrystone +0.36% cycles, CoreMark A −0.03%, B +0.05%). Fixing it is an IPC question, not an area one |
| D$: store and atomic data enter as 64 bits, duplicated inside (port B's write multiplexer sees equal halves) | 4606440 | lsu_mmu −52 |
| `pma_of` by prefix match (DR-120) | 583e41e | lsu_mmu −490, fe −37 |
| FLW NaN-boxed in the LSU, for the FPU track (P4 can drop `fld_single`): first in `ext_al`'s extension | 3f9a227 | lsu_mmu +140: a second extract path and a fill term in every upper bit |
| ... then at the result register's input instead: the word arrives zero-extended and ones are ORed into its upper half | 0e3f639 | the D-input multiplexer absorbs it |

- **Result at 583e41e** (with DR-120 and main's P4 pass):
  - st 49,097 LUTs and smt2 51,839, against 56,461 and 62,501 on main cb8ff6c: −7.4K and −10.7K, of which −0.13K is P4's.
  - st_w3 62,199, smt2_w3 66,773.
  - Cycle-identical to main 3711a41 on the riscv-tests and benchmarks. The Linux boot also matched main's per-million-cycle counts through 59 M cycles.
    - **Later finding:** that boot match is not evidence of cycle identity. The SoC boot test bench draws its AXI memory latencies and ready stalls from one shared `$urandom` stream (`tb_axi_mem`). Its cycle counts therefore depend on the order Verilator evaluates the memory models in, which changes from build to build.
    - Main's own core (41bc3f6) gave 1,063,470 instructions at 1 M cycles in one build and 1,062,353 in another; the only difference was a `$display` in the test bench.
    - Cycle identity is proved with `tg_vsim` (deterministic memory, `--x-assign unique`). The boot is a functional check: no oops, no assertion, userspace reached.
- **With DR-113's settings** (the budget flow from main fd54e65: hierarchy kept plus `AreaOptimized_high`), at cc5e962 (0e3f639's RTL):
  - st 46,132 against main cb8ff6c's 52,024 with the same settings (−5.9K, −11.3%): lsu_mmu 16,157 → 10,932, rob_csr 4,793 → 4,390, fe 4,966 → 4,738; rename 4,324 unchanged.
  - smt2 49,022.
- **The directed `amo` test** (bae805e): its LR/SC loop allowed 16 tries, and under `--probe-rate=150 --bp=20` it needs up to about 30, since a probe of the reserved line ends the reservation. It allows 1,024 now. Main failed the same way; the FPU track found it.
- **Lessons:**
  - A LUT attribution beats intuition. It found three way multiplexers on one port in the D$, 136-LUT range compares in `pma_of` (where a prefix compare takes 10), and tval buses that only a trap at the head reads.
  - Two of the seven steps were level when measured, and one moved cycles, which only the cycle comparison caught: lockstep and every test passed.

**Dead ends:**
- My per-module `units.tsv` lines were superseded by units read from `tg_core`'s hierarchy, which give exact per-instance counts in context.
- A single 4-port D$ state LUTRAM failed the primitive check, because the load port reads only the valid bits.
- The divider's normalisation as a 64-bit rotation plus a mask (8ed931c, reverted in a32d2aa): +102 LUTs.
- One AG report per LSU port into the ROB (935dc2b, reverted in a926037): level.
- The walker on the STA port's checker (4b85114, reverted in 5c124f2): −0.83K, but not exclusive (D18); it is in the reserve (§13).

**FPGA-friendly rewrite, first pass (2026-10-14, DR-123/125; branch `claude/track-core-adb715-fn`):**
- **Method:** a LUT attribution of the whole core (hierarchy kept, DR-113's settings, every LUT grouped by the signal it drives). Each structure found was rewritten in an FPGA form, and each step was checked with `make cycle-identical` against main: st, smt2, st_w3 and smt2_w3, 796 programs each.

| Step | Commit | Form | Measured (st, DR-113's settings) |
|---|---|---|---|
| Ready tables: a set phase per bank, an allocation phase XOR-banked; the free lists' next registers cleared every cycle | 9cbbc67, cc1f679 | T2 | rename 4,324 → 3,340; the 192:1 and 128:1 read multiplexers were 1.4K LUT cells |
| `rowdst` (MX) in LUTRAM, XOR-banked by DS slot | 917189a | T2 | rename, with the next step: 3,340 → 2,780 |
| The maps' banks XOR-banked, no live-value tables | 6f8c99e | T2 | (above) |
| The DS payload loads whenever DS is free | c02be92 | timing | — |
| The TLB match as a LUTRAM CAM: six level-aligned slice tables, a key store, a bypass comparator behind a three-cycle update | 7863a25 | T5 | DTLB 1,470 → 1,104 LUTs (−819 flip-flops); ITLB 486 → 480 (−392 flip-flops) |
| The ROB's `complete`, `exc`, `mispredict`, `mmio` as per-port toggle tables with a dispatch-time parity | cb67ebc | T2 | ROB 2,696 → 2,042 |
| The SQ's ROB index and size in LUTRAM | 8a18f6c | T1 | small |
| D$ port B's byte enables shared by the ways | 7ad53ea | — | small |
| `mcycle`/`minstret` in DSP48E2 pairs, OPMODE registered in the slices | 2300494, f18704e | T6 | CSR 1,694 → 1,615, DSPs +2 |

- **Result at f18704e (the final RTL):**
  - **st:** 46,132 → **43,342** (−2,790, −6.0%):
    - rename 4,324 → 2,816;
    - lsu_mmu 10,932 → 10,390, of which the D$ is 2,609 → 2,483, from the shared byte enables;
    - rob_csr 4,390 → 3,656, of which the ROB is 2,696 → 2,041.
    - Flip-flops −2.2K, LUTRAM +1.0K, DSPs 53 → 55.
  - **smt2 (7ad53ea, before the counters, −79):** 49,022 → **45,992**, under its 46,120 core budget. rob_csr 4,461 is under its 4,840.
- **Timing, out of context at 200 MHz (reg-to-reg):**
  - **Rename:** in one clock region, 41bc3f6 −2.233 ns and 7ad53ea −0.517 ns. Unconstrained the two vary run to run by about 0.3 ns around main's −0.154. The worst path is main's own: the free-list counts, steering and resource checks into rn_fire.
  - **ROB:** −0.954 → −0.372 ns; in one clock region, −0.660 → −0.278.
  - **LSU:** −4.751 → −4.163 ns. That is M3's AG stage (TLB, PMP and the access decision in one cycle), whose fix is M6's.
- **Lessons:**
  - The flip-flop structures had a reader cost, not a storage cost. The ready bits, ROB flags and MX row destinations were cheap to store but read through wide multiplexers or written through many index decoders.
  - XOR banking and per-port toggle tables give one writer per LUTRAM without a live-value table. They need either an exact old value at the write address, or a one-report-per-lap invariant; the ROB checks its invariant with a shadow copy of the old flags in simulation.
  - A LUTRAM CAM is a LUT lever for a TLB with two lookups and an overlap check (−366), but not with one lookup (−6). The spikes track's single-lookup pricing (76 LUTs at 32 entries) did not see the second port.
  - A change that is invisible in the core test bench can still show in the SoC boot's cycle counts: `tb_axi_mem`'s random draws move with the build at four Verilator threads (verification.md §4.5). Use `make cycle-identical`.
  - Clearing a free list's next registers early is invisible, because nobody reads a free register's ready bit. Rewriting a structure exactly is easier when it is clear who can observe what, and when.

**FPGA-friendly rewrite, second pass (2026-10-14; branch `claude/track-core-adb715-fn2`):**

| Step | Commit | Form | Measured (st, DR-113's settings) |
|---|---|---|---|
| The ITLB back on flip-flop comparators (`tg_tlb` `CAM = 0`) | 9b14471 | — | fe 4,732 → 4,738 LUTs, −160 LUTRAM, +392 flip-flops |
| The cold CSRs in one LUTRAM; trap entry's three writes in the cycles after the trap | 50746f6 | T1 | with the next step |
| The xRET's xepc through the CSR read port (the ROB names the xRET in flight) | 43c2d0f | T1 | CSR 1,615 → 1,368 (`u_cold` is 80 LUTRAM LUTs), −500 flip-flops |
| One adder on the head's PC | 2952dbd | T7 | ROB −68 out of context (`flush_pc` 260 → 194) |
| `replay` as XOR-banked LUTRAM | 9646d13 | T2 | ROB 2,083 → 1,891, −48 flip-flops |

- **Result at e5c2b4f, against 4eb7ce0** (the first pass with main 89d8001 merged):
  - **st:** 43,005 → **42,607** (−398); rob_csr 3,658 → 3,259.
  - **smt2:** 45,637 → **45,055** (−582); rob_csr 4,381 → 3,799.
  - Flip-flops: st −546, smt2 −578.
- **Lessons:**
  - The CSRs' cost was their write multiplexers and read-multiplexer inputs, not their storage. One write port suffices when writes that arrive together can be spread over cycles nobody observes: the trap's flush leaves the window empty.
  - Serial instructions free ports. Two users of a port that never overlap (a CSR read in EX, an xRET's xepc at commit) can share it through a registered steering bit.
  - On a 6-input LUT, taking one input out of a 3:1 multiplexer saves nothing, and the shared xepc saved nothing in the ROB. Taking out a whole adder does (−66).
  - The `--rand-reset` cycle difference was the BHT, LUTRAM by design (§3.2). Verilator fills a whole array with one random value, so a LUTRAM's random start covers only a few states.
