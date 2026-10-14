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
- **I$.** `L1I_KIB` (32 KiB), `L1_WAYS` (8) ways, 64-byte lines, 64 sets, index PC[11:6] (VIPT-ready). Data: one `tg_ram_sdp` per way, 256 rows × 128 bits, output register (read address = `fpc_d`). Tags: one `tg_ram_lut` per way; valid bits in flip-flops (reset and FENCE.I clear them in one cycle).
- **Physical address.** In M (and Bare), PA = PC[`PA_W`-1:0]; with `EXT_SU` in S and U under Sv39, F1 translates the PC through the ITLB (core-mmu.md: misses park fetch for a walk). A PA with nonzero bits above `PA_W`, or whose PMA is not `PMA_MEM`/`PMA_ROM`, faults without a refill; PMP is checked per 4-byte word.
- **Miss (F2).** The F1/F2 contents are dropped, fetch parks, and one `Get` (size 6) goes out on `l1i` (one outstanding request; the plan's 4 MSHRs and prefetch are M6). The four `AccessAckData` beats are written into the victim way (round robin per set); the tag and valid bit are written with the last beat; then fetch restarts at the missed PC. `denied` or `corrupt` leaves the line invalid and records a fetch fault for the PC.
- **Fetch fault.** A faulting PC produces a one-instruction block whose metadata carries `fault`; decode turns it into an instruction access fault (cause 1) or page fault (cause 12), `tval` = PC, or PC + 2 when only the second half of a 32-bit instruction faults. Fetch then waits for a redirect.

### 3.2 Prediction
- **Micro-BTB** (`tg_ubtb`, S5): 64 entries, 2-way LUTRAM, keyed by the 16-byte block address; an entry holds the target and the slot (halfword) of the block's last parcel of the taken branch. A hit ends the block at that slot (`exit_slot`) and fetches the target next cycle. Its LUTRAM valid bits are cleared by the reset sequence (§10).
- **Direction:** a 2-bit counter table, 512 entries in LUTRAM, indexed by PC[10:2].
- **Training at execute (P0).** For each resolved branch or jump: the counter moves toward the outcome; the block should be predicted taken if the instruction is JAL/JALR or the new counter is ≥ 2. If it should and the micro-BTB did not predict this target at this slot, the entry is written (the way that hit, else a pseudo-random way); if it should not and the micro-BTB predicted it taken, the entry is invalidated. Wrong-path branches also train (accepted in M2).

### 3.3 Instruction queue
`tg_fetch_compact` (S5) with `WR = 4` writes per cycle and `IBUF_ENTRIES` (16) entries. Per-instruction metadata from F2: the block PC, `fault`, the micro-BTB hit, way, slot and target. The PC of an instruction is `block_pc + 2·slot`, minus `FETCH_BYTES` for an instruction that straddles from the previous block (a 32-bit instruction reported at slot `NP-1`).

### 3.4 Decode-time redirect (DE)
For each instruction, `pred_exit` = the block was predicted taken and the predicted slot lies within this instruction's parcels. Then:
- **JAL:** target = PC + imm. If it was not predicted taken here with that target, redirect to the target.
- **Conditional branch** predicted taken here with a wrong target: redirect to PC + imm.
- **`pred_exit` on anything else, or a slot mismatch:** the prediction is bogus; redirect to the next sequential PC and invalidate the micro-BTB entry.

The redirecting instruction stays in the group; younger slots are dropped. Its `pred_npc` (the next PC the front end followed) is what execute compares against.

## 4. Decode (`tg_decode`)

`DECODE_WIDTH` copies of a combinational RV64IM + Zicsr + Zifencei + system decoder. Output: `dec_t` (`tg_core_pkg`): class (ALU, BR, MUL, DIV, LD, ST, CSR, SYS), sources and destination, ALU control (`alu_ctl_t`), 64-bit immediate (AUIPC, JAL and JALR link values are precomputed: PC + imm, PC + 4), branch fields, memory size and sign, MUL/DIV op, CSR op, and a decode-time exception (illegal 2 with `tval` = instruction bits, 16-bit for a compressed encoding; ECALL 11 with `tval` 0; EBREAK 3 with `tval` = PC; fetch fault 1 with `tval` = PC).
- **Compressed encodings** are illegal in M2 (misa has no C). They are expanded by `tg_rvc` before decode when `EXT_C` is on; decode then sees the 32-bit form plus its length (link value PC + 2).
- **ISA switches (M3):** `EXT_SU`, `EXT_A`, `EXT_C`, `EXT_B` (Zba, Zbb, Zbs) and `EXT_ZICOND` in `tg_core_pkg` are on, with the M3 Spike configuration (`rv64imac_zicsr_zicntr_zihpm_zifencei_zba_zbb_zbs_zicond_sstc_svinval_za64rs`, `MSU`, 16 PMP regions: the `sim/Makefile` default for `CORE=core`), because misa and the illegal encodings must match it. clz/ctz/cpop and min/max run on P1 in the MUL slot, misa.B and misa.C are writable as in Spike, and jump targets need only 2-byte alignment. Each switch can still be turned off (with the matching narrower ISA string).
- **misa.M** gates MUL/DIV (Spike lets software clear it); misa.B gates Zba/Zbb/Zbs.
- **Group rules (DE):** a serialising instruction (CSR, FENCE, FENCE.I, WFI, MRET) or an instruction with a decode-time exception is taken alone, in slot 0; the instructions before it go in the previous group. A decode-time redirect ends the group.

## 5. Rename and dispatch

### 5.1 Physical registers
- **Banks** (plan §4.7): `INT_BANKS` = `N_ALU` + 1 banks of `INT_PREGS_PER_BANK` (64). Bank *b* < `N_ALU` is written only by ALU port *b* (bank 1 also takes MUL, DIV and CSR results through a write mux, §7.3); bank `N_ALU` only by the load pipe. Tag = {bank, index}.
- **Preg 0** (bank 0, index 0) is the constant zero: x0 maps to it, it is never allocated, and the reset sequence writes it with 0.
- **Initial map:** x*i* → bank 0, index *i* (written with 0 by the reset sequence, as Spike resets every register to 0).

### 5.2 RN stage (`tg_rename`)
- **RAT** (speculative) and **CRAT** (committed) in LUTRAM (plan §8.5 R3). A RAT entry holds the mapping and, for sources, the producer's wakeup ID, whether it is a 1-cycle op and its rename slot (MX naming, §5.3). Each RAT bank belongs to one rename slot and each CRAT bank to one commit slot, so every write port is a LUTRAM write port; live-value tables (flip-flops, `log2` of the width per register) name the bank with each register's latest entry. Reads: rs1, rs2 and rd (the old mapping) per slot.
- **Recovery:** a bit per architectural register says it was renamed since the last flush; otherwise the CRAT answers (its producer has committed, so the source is ready and the producer fields are not read). A flush clears these bits: the committed map is current in the next cycle, with no copy. After reset a sweep writes the identity map into CRAT bank 0 (32 cycles, alongside the free lists' initialisation).
- **Free lists** (`tg_freelist`): one per bank, a circular list in `FL_BANKS` interleaved LUTRAMs, with a speculative head (pops at RN), a committed head (advanced at commit by the destinations it retires) and a tail (pushes of freed registers at commit). A flush sets the speculative head to the committed head. Bank 0's list starts with indices 32–63, the others with 0–63.
- **Steering:** BR/JAL/JALR → port 0; MUL, DIV, CSR → port 1; ALU ops in slot *k* prefer port *k* mod `N_ALU` and fall back to another ALU port whose queue bank and free list have room; LD → load port; ST → store-address queue. Destinations come from the steered port's bank.
- **Wakeup ID:** the ROB index for every producer except loads and DIV/REM, which take a long-latency tag (LLT). IDs are columns 0..`ROB_ENTRIES`-1 (ROB) and `ROB_ENTRIES`..+`LLT_ENTRIES`-1 (LLTs) of the dependency vectors.
- **Ready table:** one bit per physical register, cleared when RN allocates it, set when the register file is written (each bank's write port).
- **Sources:** an earlier slot of the same group that writes the register (intra-group, generated for any width), else RAT; pending if produced in the group or its ready bit is clear; a pending source contributes its producer's wakeup ID.
- **Allocation (all or nothing per group):** ROB entries (tail + slot order), LQ/SQ entries, LLTs, free-list registers per bank, and a DIV slot (at most `DIV_INFLIGHT` divides between RN and the divider). If any is short, the group waits.
- **Serialising instructions** wait at RN until the ROB and `ds_q` are empty; after one is renamed, RN accepts nothing until the next flush (every serialising instruction ends in a flush, §8).

### 5.3 DS stage (also in `tg_rename`)
- Writes the ROB entries (§8.1), the issue-queue rows (`tg_iq` dispatch port *k* = group slot *k*) and the LQ/SQ entries.
- **Dependency vector** = one-hot of the pending sources' IDs **AND NOT W**. An ID is only reallocated after its producer has set its W bit and written the register file (ROB entry retired, or LLT released), so a W bit seen at DS still belongs to the producer RN saw; dropping it closes the window between RN and DS that the stale-dependency rule does not cover.
- **Wake at select:** 1-cycle ALU ops (and branches with a destination) carry their own ROB index as `disp_wake_oh`.
- **IQ room:** dispatch waits until every uop of the group finds a free row in its queue's bank (`bank_free_q`).
- **Uops without a queue** (FENCE, FENCE.I, WFI, MRET, decode-time exceptions) are written complete.

## 6. Issue (`tg_iq`, `tg_wake`; spike S2 RTL)

| Queue | Rows | Port | Ops |
|---|---|---|---|
| A0 .. A(`N_ALU`-1) | `IQ_A0`, `IQ_A1`, `IQ_A2` | P0 .. | ALU; P0 also BR/JAL/JALR; P1 also MUL, DIV, CSR |
| LD | `IQ_LD` | load pipe | loads |
| STA | `IQ_STA` | store-address pipe | store addresses |

- **Variant:** `STALE = 0`, the guard, with predecoded wakeup IDs (`WAKE_ENC = 1`), as spikes.md §4.1 recommends: `busy` (the OR of every row's dependency bits) names the IDs a queued row still waits on, and rename allocates neither a ROB entry nor an LLT whose column is busy. The column-clear variant (`STALE = 2`) remains a `tg_issue` parameter.
- **Timing levers (spikes.md §4.2), set in `tg_core_pkg`:** `IQ_DUP_SEL = 1` (a second select copy drives only the wakeup broadcast); `IQ_EARLY_W` = the source tags (the payload's low bits; the rest sits in per-bank LUTRAM and is read in RF); `IQ_MX` = on when `TID_W > 0` (matrix wakeup, required for `smt2` timing), with the cancel history `HIST = 1`.
- **MX naming at dispatch.** A row names its in-queue 1-cycle producers (ALU ops and branches with a link) by ALU-queue row (`disp_mdep`, rows numbered across the ALU queues) and is ready when those rows have been selected; their W bit follows a cycle later. Dispatch finds the row through `rowof` (physical register → the row its producer was written into, recorded at DS) and confirms it with one compare: the row is still held (`mx_hold`: valid and not freed this cycle) and its destination (`rowdst`) equals the source. A producer in the same group is named by the row it is being written into (`mx_alloc`). Otherwise the source uses the producer's ID.
- **Payload formats.** Rename builds one `iq_pl_t`; each queue stores only the bits its port reads, so no LUTRAM bit is left for synthesis to trim, and the other fields leave the queue as zero. All ALU queues: class, the ALU control word without the min/max group and `cmp_max` (`tg_alu` `MINMAX = 0`: min/max ride P1's MUL slot), `b_imm`, the immediate, the destination's index (its bank is the port's) and both source tags. A0 adds the branch fields (PC, kind, funct3, target, JALR offset, predicted next PC, micro-BTB hit and way, `dfix`, RVC); A1 adds `cmp_max`, the MUL/DIV/CSR fields, the LLT, the wakeup ID and the instruction (CSR tval); both keep the ROB ID with its wrap bit (exception and misprediction age), A2 only the index (completion). LD: ROB ID, immediate, LQ index, size, base tag; STA: ROB ID, immediate, SQ ID, size, base tag.
- **Changes to the spike module:** a `sel_block` input (registered) that suppresses the queue's grant for a cycle (A1 uses it to keep bank 1's write port free, §7.3; LD uses it to free the load pipe for LQ replays); and a row granted in the cycle it is killed does not issue.
- **Wakeup timing:** ALU ops at select (`wake_now`); MUL through a delay line, so dependants read the register file after the write (MUL-to-use 5 cycles; no MUL bypass); loads and DIV on their LLT when their result is written (`wake_reg`); CSR results have no consumers in flight (serialised).

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
- Flip-flops per entry: `complete`, `exc`, `mispredict`, `replay`, `mmio`, `tlb` (M3: a DTLB miss).
- **Oldest-exception register** {ROB index, cause, `tval`} for exceptions found after dispatch (LSU, branch target, CSR); the oldest wins by ROB age (index plus wrap bit). **Oldest-mispredict register** {ROB index, target}, same rule. Both reset on a flush.
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

## 10. Reset sequence
After `rst`, an init counter runs for 64 cycles before fetch starts: it fills the free lists, writes zero into bank 0 indices 0–31, and invalidates the micro-BTB. Everything else resets through control state (valid bits, pointers).

## 11. Commit trace
Records leave through a register one cycle after commit. `rd_value` is read from the register file through `COMMIT_WIDTH` dedicated read ports. In simulation they cost nothing; for the FPGA trace (M4) they are a parameter to settle with the SoC track. `rd_deferred` is 0 in M2. `nondet` marks reads of `cycle/mcycle`, `time`, `mip`, the ID CSRs and `mhpmcounter*`; `mmio_ld` marks loads from device or ROM regions.

## 12. Parameters and builds
All widths come from `tg_pkg` (`DECODE_WIDTH`, `N_ALU`, `ROB_BANKS`, `FL_BANKS`, sizes). Core-local constants (`DIV_INFLIGHT` = 4, counter-table size) are in `tg_core_pkg`. Every per-slot structure is a generate loop. The `smt2` builds compile and lint with `tid` carried everywhere; in M2 only hart 0 runs (hart 1 never fetches).

## 13. Timing and area
M2 targets simulation; the structures are the spikes' (S2, S3, S5), so their timing results apply where adopted. Known M2-only costs to remove later: 64-bit PCs in the ROB and queue payloads (FTQ, M6), the trace read ports, flip-flop D$ state.

## 14. Verification
Spike lockstep on every test (verification.md): riscv-tests, the directed interrupt tests, CoreMark and Dhrystone, in `st` and `st_w3`, with latency, back-pressure and probe stress options. Assertions (`ifndef SYNTHESIS`) on queue occupancy, free-list over/underflow, ROB order and one-hot grants.

## 15. Provenance
- Out-of-order structure (rename with a free list and committed map, ROB, commit-time recovery): Smith and Pleszkun (1988), Hennessy and Patterson, *Computer Architecture*, 6th ed., ch. 3.
- Writer-sharded register banks: Seznec et al., MICRO 2002. Dependency-vector wakeup and age-matrix select: Wong's FPGA scheduler papers (cited in the plan, Appendix A). Long-latency tags and early retirement: plan §4.5 (A73 behaviour reported by Chips and Cheese).
- Micro-BTB, pre-decode and compaction: spike S5 (our RTL); block-based fetch: Reinman et al., ISCA 1999.
- RISC-V semantics: the unprivileged ISA (20240411) and privileged spec (1.13); CSR WARL behaviour as Spike implements it (Spike used as a reference model, as allowed by plan §2.3).
- No other core's RTL was read.
