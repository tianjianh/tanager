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
| Speculative load wakeup, shadow cancel | no: loads wake their dependants on a confirmed hit | M6 |
| Long-latency tags (LLTs), deferred-free hook | yes (loads and DIV/REM use LLTs; nothing retires early) | early retirement: M6 |
| Register file, bypass, 1-cycle ALU (S3 RTL) | yes | — |
| MUL 3 cycles pipelined; DIV iterative | yes (radix-2) | DIV on the Goldschmidt DSPs (R4): later |
| LSU: split LQ, SQ, store-data capture, forwarding, ordering checks | yes, without the completion buffer | completion buffer: M6 |
| L1D with 16 MSHRs | 1 MSHR | M6 |
| CSRs, traps, interrupts | M-mode set matching Spike (§9) | S/U, Sv39, PMP checks, A, C: M3 |
| SMT2 | `tid` ports and fields everywhere; the `smt2` builds compile and lint but run hart 0 only | M7 |

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
- **I$.** `L1I_KIB` (32 KiB), `L1_WAYS` (8) ways, 64-byte lines, 64 sets, index PC[11:6] (VIPT-ready). Data: one `tg_ram_sdp` per way, 256 rows × 128 bits, output register (read address = `fpc_d`). Tags: one `tg_ram_lut` per way. Valid bits: one `tg_ram_lut` row of 8 bits per set (plan §8.3), read by F1 and by the refill (victim choice, then a read-modify-write with the tag); after reset and FENCE.I a 64-cycle sweep clears them while F1 waits.
- **Physical address.** In M (and Bare), PA = PC[`PA_W`-1:0]; with `EXT_SU` in S and U under Sv39, F1 translates the PC through the ITLB (core-mmu.md: misses park fetch for a walk). A PA with nonzero bits above `PA_W`, or whose PMA is not `PMA_MEM`/`PMA_ROM`, faults without a refill; PMP is checked per 4-byte word.
- **Miss (F2).** The F1/F2 contents are dropped, fetch parks, and one `Get` (size 6) goes out on `l1i` (one outstanding request; the plan's 4 MSHRs and prefetch are M6). The four `AccessAckData` beats are written into the victim way (an invalid way, else a round-robin pointer shared by the sets); the victim's valid bit is cleared when the refill starts, because the refill rewrites its rows beat by beat and outlives redirects (its old line must miss meanwhile); the tag and valid bit are written with the last beat; then fetch restarts at the missed PC. `denied` or `corrupt` leaves the line invalid and records a fetch fault for the PC.
- **Fetch fault.** A faulting PC produces a one-instruction block whose metadata carries `fault`; decode turns it into an instruction access fault (cause 1) or page fault (cause 12), `tval` = PC, or PC + 2 when only the second half of a 32-bit instruction faults. Fetch then waits for a redirect.

### 3.2 Prediction
- **Micro-BTB** (`tg_ubtb`, S5): 64 entries, 2-way LUTRAM, keyed by the 16-byte block address; an entry holds the target and the slot (halfword) of the block's last parcel of the taken branch. A hit ends the block at that slot (`exit_slot`) and fetches the target next cycle. Its LUTRAM valid bits are cleared by the reset sequence (§10).
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
- **`pred_exit` on anything else, or a slot mismatch:** the prediction is bogus; redirect to the next sequential PC and invalidate the micro-BTB entry.

The redirecting instruction stays in the group; younger slots are dropped. Its `pred_npc` (the next PC the front end followed) is what execute compares against.

**Timing:**
- **No add waits for another.** An instruction's PC is its block's address plus its offset in the block (`pc[3:0]`, or −2 for a straddler). The PC-relative values (the targets, AUIPC, the link value, the next PC) are each one three-input add of block address, offset and operand: a carry-save step and one carry chain. Only a straddler's PC needs a decrement of the block address.
- **The redirect decision uses no add at all.** "The predicted target is the branch's" is checked carry-free, as `a + b + c == k` (Cortadella and Llabería, IEEE Trans. Computers, 1992). Every bit of the carry-save sum must match the carry that k needs there. The sums themselves feed only registers.

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
- **Recovery:** a bit per architectural register says it was renamed since the last flush; otherwise the CRAT answers (its producer has committed, so the source is ready and the producer fields are not read). A flush clears these bits: the committed map is current in the next cycle, with no copy. After reset a sweep writes the identity map into CRAT bank 0 and zeros into the other CRAT banks (32 cycles, alongside the free lists' initialisation).
- **Free lists** (`tg_freelist`): one per bank, a circular list in `FL_BANKS` interleaved LUTRAMs, with a speculative head (pops at RN), a committed head (advanced at commit by the destinations it retires) and a tail (pushes of freed registers at commit). A flush sets the speculative head to the committed head. Bank 0's list starts with indices 32–63, the others with 0–63.
  - **The free count is a register,** not tail − head: it is updated by the pushes and pops. A second register, tail − committed head, is the count a flush takes. Rename's steering and resource checks then start from flip-flops, not a subtraction (timing; the same values, asserted).
- **Steering:** BR/JAL/JALR → port 0; MUL, DIV, CSR → port 1; ALU ops in slot *k* prefer port *k* mod `N_ALU` and fall back to another ALU port whose queue bank and free list have room; LD → load port; ST → store-address queue. Destinations come from the steered port's bank.
- **Wakeup columns (plan §4.6, AR-1):** `IQ_TAGS` (16) wakeup tags, then the `LLT_ENTRIES` long-latency tags; no column per ROB entry, so the window size does not set the scheduler's width (st: 32 columns instead of 64; smt2: 40 instead of 120).
  - **LLT:** loads, atomics and DIV/REM with a destination.
  - **Tag:** MUL and the P1 bit counts (C_MUL) with a destination, from a pool of `IQ_TAGS`; RN waits when it runs short. A tag returns 2 cycles after its producer's register-file write (`tag_free` from `tg_exec`): by then no group in RN or DS can see the register as unwritten. Its column is then cleared in every queue row (`col_clr`), so a returned tag needs no guard. A flush returns every tag.
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
- **Serialising instructions** wait at RN until the ROB and `ds_q` are empty; after one is renamed, RN accepts nothing until the next flush (every serialising instruction ends in a flush, §8).

### 5.3 DS stage (also in `tg_rename`)
- Writes the ROB entries (§8.1), the issue-queue rows (`tg_iq` dispatch port *k* = group slot *k*) and the LQ/SQ entries.
- **The DS payload** (`ds_uop_q`, `ds_ren_q`) loads RN's group whenever DS is free (c02be92), not only when RN fires, so its enable does not wait for rn_fire, the end of rename's longest path. `ds_valid_q` says whether RN fired; every reader of the payload is gated by a valid slot or `ds_fire`.
- **MX row destinations** (`rowdst`, the destination of the op each ALU-queue row holds) are LUTRAM, one bank per DS slot. A row's value is the XOR of the banks: each slot writes only its own bank, at the row it takes (917189a).
- **Dependency vector** = one-hot of the pending sources' columns **AND NOT W**. A column is only reallocated after its producer has set its W bit and written the register file (a tag 2 cycles after the write, an LLT when released), so a W bit seen at DS still belongs to the producer RN saw; dropping it closes the window between RN and DS that the stale-dependency rule does not cover.
- **Allocation (AR-1):** RN gives out tags with the LLTs, from a free pool, and clears their W bits (`wid_alloc`).
- **IQ room:** dispatch waits until every uop of the group finds a free row in its queue's bank (`bank_free_q`).
- **Uops without a queue** (FENCE, FENCE.I, WFI, MRET, decode-time exceptions) are written complete.

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
- **Wakeup timing:** ALU ops through MX alone (a dependant selects the cycle after its producer); MUL its tag through a delay line, so dependants read the register file after the write (MUL-to-use 5 cycles; no MUL bypass); loads and DIV their LLT when their result is written (`wake_reg`); CSR results have no consumers in flight (serialised).

## 7. Register read, bypass, execute (`tg_exec`; spike S3 RTL)

### 7.1 Register file and bypass
- `tg_irf`: `INT_BANKS` banks, read ports per bank = 2·`N_ALU` (ALU operands) + LD base + STA base + the shared store-data port + `COMMIT_WIDTH` trace ports (simulation trace; see §11).
- S3 timing: IS (*s*) → RF (*s*+1) → EX (*s*+2, result in `res_q` during *s*+3) → WB (*s*+3, register file written at its end; `wb_q` during *s*+4).
- **Bypass sources** (binary selects computed in RF): register file, each ALU's `res_q` (EX level) and `wb_q` (WB level), the load result register and its WB copy, and the immediate. Because each bank has one writer, a source tag's bank names the only producer that can match; RF compares the index with that producer's EX-stage and WB-stage destinations.

### 7.2 Ports
- **ALU ports:** `tg_alu` (S3). P0 adds the branch unit: taken from the ALU's compare flags; target = precomputed PC + imm (branches, JAL) or (rs1 + imm) & ~1 (JALR); the link value is the precomputed immediate through the ALU's pass-b group. A taken target with bit 1 set raises a misaligned-fetch exception (cause 0, `tval` = target) on the branch (no C in M2). A mispredict is `actual_npc != pred_npc`.
- **P1 extras:** MUL (3 stages, 128-bit product, MULH/MULHSU/MULHU/MULW), DIV (radix-2 iterative with a `DIV_INFLIGHT`-deep input FIFO, the RISC-V divide-by-zero and overflow results), CSR (§9) executed in EX.
- **LD / STA:** address generation in EX; the rest is in [core-lsu.md](core-lsu.md).

### 7.3 Bank 1's write port
ALU1 writes at *s*+3, CSR at *s*+3 (it occupies an A1 select), MUL at *s*+5, DIV whenever it finishes. A reservation vector over the next 5 write slots resolves them: a MUL claims *s*+5 when it reaches RF; a finished DIV claims slot *c*+3 if free; A1's select is blocked in any cycle whose *s*+3 slot is claimed. Nothing else writes bank 1.

## 8. ROB, commit, recovery (`tg_rob`)

### 8.1 Entries
- `ROB_ENTRIES` (48), `ROB_BANKS`-way interleaved LUTRAM payload written at DS: PC, instruction bits and `rvc`, rd, new and old physical register, kind (load, store, branch, CSR, FENCE, FENCE.I, WFI, MRET), decode-time exception cause, LQ/SQ index.
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
    - **Candidates:** the register, the CSR port, the branch port and the LSU's four ports. Every pair is compared by ROB index.
    - **Why it is fast:** the indices arrive early, since the LSU sends each port's payload index whether or not it faults. The late valid bits only gate a one-hot select.
    - **Same result as the chain:** the oldest wins, the first candidate in the old order on a tie. `tval` is the best of the first three alone, as the chain left it.
    - **Checked:** in simulation the old chain runs beside it and must agree every cycle.
    - **Why:** the chain was the end of the whole core's worst paths at 100 MHz (§13), and the ROB's own worst path (−0.350 ns at 200 MHz out of context).
- **The trap target comes in two parts** (`tg_csr`):
  - **An exception's** is its vector's base, chosen by its cause's delegation.
  - **An interrupt's** adds 4 × its code in vectored mode. Its code and delegation are the CSR file's own and arrive early, so the 64-bit add stays off the exception's path.
  - The ROB picks one with `do_irq` in its redirect multiplexer, still one LUT6 per bit.
- **A replay at the head:** the refetch PC, the cause and `tval` are set before the head's TLB check (`hd_retry`, the LSU's DTLB lookup that cycle). They count only if the instruction flushes or traps.
- **Completion ports:** each ALU port, bank 1's write mux (MUL/DIV/CSR), the load pipe, the store queue (address and data both present), and dispatch.

### 8.2 Commit
Up to `COMMIT_WIDTH` complete entries in order per cycle. Per retirement: CRAT update; the old physical register goes to its bank's free list (through the deferred-free stage, a pass-through in M2); the free list's committed head advances for the new one; LQ head or SQ commit mark; `minstret`; a trace record (§11).
- **Head-only entries** (slot 0, nothing else that cycle): exceptions, serialising instructions, replays.
- **Mispredict:** the branch retires (in any slot); the group ends there; flush and redirect to the oldest-mispredict target.
- **Exception:** TR_TRAP, trap entry (§9.3), flush, redirect to `mtvec` base.
- **Replay** (ordering violation): nothing retires; flush and refetch at the entry's PC. A replay marked `tlb` waits for the LSU instead: refetch once the DTLB translates the entry, or trap if the deciding walk faults (core-mmu.md).
- **Serialising:** CSR (apply the CSR write, §9.2), MRET (§9.3), FENCE and FENCE.I (wait until the SQ has drained; FENCE.I also invalidates the I$), WFI (wait until `mip & mie` is nonzero, or 4096 cycles: the ISA lets WFI complete at any time) retire alone, then flush and refetch at the next PC (MRET: at `mepc`).
- **Interrupts** (§9.4) are checked before the head retires.

### 8.3 Flush
`flush_q` (with `flush_tid_q` and `redirect_pc_q`) is registered from commit and clears everything listed in §2. Committed stores stay in the SQ and keep draining.

## 9. CSRs and traps (`tg_csr`)

### 9.1 CSR set (M-mode, RV64IM, Zicsr, Zicntr, Zifencei, 16 PMP entries, no triggers), as Spike defines it
| CSR | Behaviour |
|---|---|
| `misa` | `0x8000_0000_0000_1100`; bit M writable (clearing it makes MUL/DIV illegal) |
| `mvendorid`, `marchid`, `mimpid`, `mconfigptr` | 0 (the checker adopts the ID reads); `mhartid` = `CORE_ID`·`NUM_THREADS` + tid |
| `mstatus` | MIE, MPIE writable; MPP reads 3 (M only); everything else 0 |
| `mtvec` | written value with bit 1 cleared (direct and vectored) |
| `mie` | MSIE, MTIE, MEIE writable |
| `mip` | MSIP, MTIP, MEIP from the inputs, read-only (writes ignored); reads are `nondet` |
| `mscratch`, `mcause`, `mtval` | 64-bit read/write |
| `mepc` | bit 0 cleared on write; reads mask bit 1 too (no C) |
| `mcountinhibit` | CY and IR writable |
| `mcycle`, `minstret` | read/write; a write to `minstret` replaces that instruction's increment |
| `cycle`, `time`, `instret` | read-only aliases; `time` = `mtime_i`; cycle and time reads are `nondet` |
| `mhpmcounter3–31`, `mhpmevent3–31` | read 0, writes ignored (counter reads `nondet`) |
| `tselect`, `tdata1–3`, `tinfo` | read 0, writes ignored |
| `mcontext` | 13 bits read/write |
| `pmpcfg0, 2, …, 14`, `pmpaddr0–63` | entries 0–15 implemented (Spike's WARL rules: lock, R=0/W=1 dropped, 54-bit addresses); entries 16–63 read 0. Reset: entry 0 = NAPOT RWX over the whole space, as Spike. Checked by `tg_pmp` (core-mmu.md) |

Everything else is illegal (cause 2, `tval` = the instruction bits), as is a write to a read-only CSR. `csrrs/csrrc` with rs1 = x0 and the immediate forms with uimm = 0 do not write.

### 9.2 CSR instructions
Serialising: dispatched when the ROB is empty, issued on A1, executed in P1's EX: read, legality, new value. The read value returns through bank 1's write mux; the write is held in a pending register and applied when the instruction retires.

### 9.3 Trap entry and MRET
Exception or interrupt: `mepc` ← PC, `mcause`, `mtval` (0 for interrupts), `mstatus.MPIE` ← MIE, MIE ← 0, MPP ← M; PC ← `mtvec` base, + 4·cause for an interrupt in vectored mode. MRET: MIE ← MPIE, MPIE ← 1; PC ← `mepc`.

### 9.4 Interrupts
Pending = `mip & mie`; taken when `mstatus.MIE` is set, priority MEI, MSI, MTI. Taken at commit before the head instruction (TR_IRQ with `pc` = its PC), except when the head is a WFI (it retires first, and the interrupt is taken at the next instruction) or an MMIO load whose request is out. Nothing is taken while the ROB is empty.

### 9.5 Storage: the cold CSRs in LUTRAM (FPGA-friendly T1)
- **What:** `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval` and their S counterparts live in one 16 × 64 `tg_ram_lut` (`u_cold`), addressed by {csr[9], csr[2:0]}. csr[9] is 1 for M and 0 for S; then scratch is 0, epc 1, cause 2, tval 3 and tvec 5.
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

## 10. Reset sequence
After `rst`, an init counter runs for 64 cycles before fetch starts: it fills the free lists, writes zero into bank 0 indices 0–31, and invalidates the micro-BTB.
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
Records leave through a register one cycle after commit. `rd_value` is read from the register file through `COMMIT_WIDTH` dedicated read ports. In simulation they cost nothing; for the FPGA trace (M4) they are a parameter to settle with the SoC track. `rd_deferred` is 0 in M2. `nondet` marks reads of `cycle/mcycle`, `time`, `mip`, the ID CSRs and `mhpmcounter*`; `mmio_ld` marks loads from device or ROM regions.

## 12. Parameters and builds
All widths come from `tg_pkg` (`DECODE_WIDTH`, `N_ALU`, `ROB_BANKS`, `FL_BANKS`, sizes). Core-local constants (`DIV_INFLIGHT` = 4, counter-table size) are in `tg_core_pkg`. Every per-slot structure is a generate loop. The `smt2` builds compile and lint with `tid` carried everywhere; in M2 only hart 0 runs (hart 1 never fetches).

## 13. Timing and area
The structures are the spikes' (S2, S3, S5), so their timing results apply where adopted. Area is held to the per-unit budgets (docs/perf/budgets.md) by the budget flow (`fpga/budget`: `tg_core` with its hierarchy kept, units read from its instances).

**Where the area levers land** (plan §8.5; no lever below costs IPC):

| Lever | Where | State |
|---|---|---|
| PMP results cached in the TLBs (plan §4.10) | `tg_ptw` (the fill checks the page), `tg_tlb` (cached bits), `tg_fetch`/`tg_lsu` (cached or checked), `tg_csr` (region descriptors, one entry per cycle after a PMP write; `pmpaddr` in LUTRAM) | done: four checkers (fetch block, LD, STA, walker) instead of seven |
| No flip-flop arrays (plan §8.3) | D$ state (valid bits apart from round robin/T/dirty), I$ valid bits, issue-queue payloads (per-queue formats, exact bits) | done |
| R1 counters in DSP48E2 (T6) | `tg_csr`: `mcycle`, `minstret` (the HPM counters read zero) as `tg_dsp_ctr` pairs: the low slice counts or loads q[47:0], the high slice q[63:48] adds this cycle's carry, known from the low half's pattern detector; the counters, adders and load multiplexers are all in the DSPs (4 slices) | done (2300494); the mapping is checked against the vendor's DSP48E2 model on Icarus (`tests/unit/csr_ctr`) |
| R2 cold CSRs in LUTRAM (T1) | `tg_csr` (§9.5): xtvec, xscratch, xepc, xcause, xtval of M and S in one 16 × 64 table with two read ports. Trap entry writes its three in the cycles after the trap, so one write port suffices. The CSR read port also serves the xRET's xepc. | done (50746f6, 43c2d0f): cycle-identical; CSR 1,615 → 1,368 at st, −500 flip-flops. At M7, hart 1's set is one more address bit |
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
| The walker's PMP checks on the STA port's checker (adopted by the user: DR-139, superseding DR-122) | `tg_ptw` (no checker of its own), `tg_lsu` (the STA checker's input multiplexer: the walker's address in a cycle without a store address) | done: −0.83K LUTs per core. Cycle cost from `make cycle-identical` against fn3's head, st / smt2: isa +0.052% / +0.228%, stress +0.098% / −0.098%, bench 0 / 0, random +0.003% / −0.018% |

**Reserve (DR-135: each one moves cycles, and only the user adopts it; not taken):**

Cycle costs are from `make cycle-identical`, as change in cycles per suite, st / smt2: F1 to F3 against fn3's head (1c0eaca), the rest against fn4's (028f45e). Each lever's RTL is kept on a local branch.

| Lever | Gain | isa | stress | bench | random | Branch |
|---|---|---|---|---|---|---|
| F1 cut: the LSU's fault reports reach the ROB a cycle later. It is the "fault reporting" row of smt2-study's ablation. | timing: the AG fault decision leaves the exception register's paths (whole core: see §16) | +0.000% / +0.000% | +0.000% / +0.000% | 0 / 0 | +0.032% / +0.024% | `tmp/core-cut-fault` |
| F2/F5 cut: the store reports (completions and the ordering replay mark) reach the ROB a cycle later, together. It is the "completion → ROB" row. | timing: the STA's TLB and PMP decision and the LQ ordering search leave the ROB's completion and replay tables | +0.428% / +0.369% | +0.217% / −0.053% | +0.100% / +0.188% | −0.150% / +0.018% | `tmp/core-cut-store` |
| F3 cut: the ROB head's DTLB retry reaches the ROB a cycle later | timing: the head's DTLB lookup leaves the commit redirect | +0.002% / +0.006% | +0.198% / −0.031% | 0 / 0 | −0.057% / +0.046% | `tmp/core-cut-head` |
| LSU address-stage split (core-lsu.md, "Design: the address-stage split"): a new load's and a store address's DTLB, PMP and access decisions move to M1; AG adds the address and reads the D$ at the page-offset row, so load-to-use is unchanged. It subsumes F1 and F2/F5. | timing: the address add leaves the LSU's AG family (TLB, PMP, decisions, reports to the ROB) | +0.696% / +0.476% | +0.282% / +0.014% | +0.160% / +0.088% | −0.151% / +0.123% | `claude/track-core-adb715-agsplit` |
| Atomic read-data register: an atomic's D$ read data is registered before the modify and write, one cycle more per atomic | timing: the D$ atomic family (block RAM → AMO ALU → block RAM) | +0.113% / +0.135% | −0.021% / −0.016% | 0 / 0 | −0.180% / +0.089% | `tmp/core-cut-amo` |
| Fetch PMP check a cycle later on translated pages that a PMP region boundary splits: F1 waits a cycle, and the block checker reads the address the ITLB gave. Bare mode checks the fetch PC itself; homogeneous pages keep the ITLB's cached result. | timing: F1's ITLB → PMP → F2 path | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | `tmp/core-cut-fpmp` |
| F2's actions on F1 registered: parking on an I$ or ITLB miss, the refetches (PMP cut, dropped prediction, install race) and the stop after a fault block take effect a cycle later and drop the blocks F1 and F2 took meanwhile. The refill and the walk still start as early. | timing: the F2 family (tag compare, pre-decode and the PMP cut into the fetch PC and F2's enables) | +0.003% / +0.006% | −0.015% / +0.011% | −0.003% / +0.032% | +0.005% / +0.014% | `tmp/core-cut-f2` |
| DE stage: decode takes a stage of its own. DE1 decodes the queue head into registers; DE2 forms the group and checks the predictions from them. Every redirect costs one more front-end cycle. | timing: the DE family (queue head → decode → group → take, the redirect and the next PC) | +0.885% / +0.799% | +0.394% / +0.284% | +2.505% / +2.308% | +0.159% / +0.535% | `tmp/core-cut-de` |

- **The split in the w3 configurations** (st_w3 / smt2_w3): isa +0.489% / +1.565%, stress −0.258% / +0.273%, bench +0.118% / +0.006%, random +0.239% / +0.257%. Its isa cost is the `-v` tests' page-table setup, whose walks report a cycle later (about +95 cycles per test). No program fails in any of the four configurations.
- **The fetch PMP check is identical in every suite:** no program fetches from a translated page that a PMP boundary splits. It is listed because such a page would cost a cycle per fetch block.
- **Timing, whole core (st, out of context at 200 MHz):** F1, F2/F5 and F3 together take fn3's head from −7.071 to −5.464 ns (6d0523e). The worst families are then level at about −5.4 ns: the D$ atomic path, the LQ head → the replay register, F2 → the fetch PC, the LSU's address stage and DE, each with a lever above.
  - Families that none of the three touch moved by up to 1.7 ns as well, so placement noise between runs is about 1 ns.
  - The split alone and every lever together (`tmp/core-cuts-all`) are queued.
- The commit trace off in production builds: −1,466 LUTs, −740 flip-flops and −888 LUTRAM at st, measured with `trace_o` unconnected. It removes a function, the M4 trace ring, and FPGA lockstep. This is the user's option (DR-121).

**Follow-ups (functional, with deadlines):**
- **LR/SC forward progress under read probes. Deadline: M8 (dual core).**
  - **The problem:** a probe that only takes away T (toB, from another core's read) also ends the reservation. The spec's eventual-success guarantee for a constrained LR/SC loop covers contention that is only reads, so two cores could starve an SC.
  - **The fix:** a reservation hold. Probes to the reserved line wait a bounded number of cycles after an LR, and nothing in that wait depends on A-channel progress.
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
