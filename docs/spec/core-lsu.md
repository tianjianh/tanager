# Load/store unit and L1 data cache (`tg_lsu`, `tg_dcache`, M2)

Status: implemented for M2; atomics implemented for M3 (`EXT_A`, on) — core track — 2026-10-14

## Purpose
Executes loads and stores for the M2 core ([core-pipeline.md](core-pipeline.md)), keeps memory order for one hart, and is the TL-C client on the `l1d` port and the TL-UL client on `mmio` (interfaces.md §2.3, §2.4). Plan §4.9 and §4.11 are the targets; M2 builds the parts in the table and leaves the rest for M6.

| Plan | M2 |
|---|---|
| Load pipe AG → M1 → M2, 3-cycle load-to-use with speculative wakeup | same stages; dependants wake on the confirmed result at the end of M2 (5-cycle load-to-use) |
| LQ: 16-entry CAM part + 8-entry retired-load completion buffer | the CAM part (`LQ_ENTRIES`); no completion buffer (nothing retires early) |
| SQ (`SQ_ENTRIES`) with store data captured through the shared read port | same |
| Forwarding: youngest older store that covers the load; partial overlaps wait | same |
| Ordering violations: store-address search of younger executed loads, flush at commit | same |
| 16 MSHRs, early ownership prefetch, stride prefetcher | 1 MSHR; no prefetch |
| 32 KiB, 8-way, VIPT, write-back, MESI | same geometry; PA = VA (no MMU yet) |

## Interface
Inside `tg_core` (packages: `tg_core_pkg`, `tg_tl_pkg`, `tg_map_pkg`):
- **From dispatch:** LQ/SQ entry writes (ROB index, size, sign, destination, LLT; for stores the data's physical register).
- **From issue (RF stage):** the LD and STA ports' payloads; their base operands come bypassed from `tg_exec` in EX.
- **Register file:** the shared store-data read port (address from the SQ, data back in the same cycle); the load bank's write port (written at WB from the load result register).
- **To the ROB:** load and store completion, exceptions {ROB index, cause, `tval`}, replay marks (ordering violations), `mmio` marks.
- **From the ROB:** head index (MMIO loads), per-cycle commit of loads (LQ head) and stores (SQ commit mark), and the trace fields of committed stores (address, data, size).
- **To rename/ready table:** the load bank's write events; LLT releases. **To `tg_wake`:** the LLT of each confirmed load result.
- **Flush:** from commit, with `tid`.

## Behaviour

### Load pipe
| Cycle | Stage | Work |
|---|---|---|
| *s* | IS | IQ-LD select |
| *s*+1 | RF | base read, bypass select |
| *s*+2 | AG | VA = base + imm; misaligned (cause 4) before access fault (cause 5: VA above `PA_W`, `PMA_NONE`); `PMA_DEVICE`/`PMA_ROM` → MMIO; D$ data read issued on port A (row = VA[11:4]); address written into the LQ |
| *s*+3 | M1 | 8 ways of 16 bytes; tag read and compare; hit-way dword; SQ search (older stores, same dword, byte overlap) |
| *s*+4 | M2 | forward or cache data, align, extend → result register; on success the LLT's W bit is set this cycle; else the LQ entry waits (below) |
| *s*+5 | WB | load bank written; ROB complete; ready bit; LLT released the cycle after |

**LQ replays.** An LQ entry that did not finish waits in one of: `MISS` (the MSHR was busy or took the miss), `STQ` (blocked by a store), `MMIO`. It becomes ready when its condition clears (level-sensitive, re-checked every cycle):
- `MISS`: the MSHR is idle.
- `STQ` without data: the blocking store has its data or has left the SQ; `STQ` partial overlap: the blocking store has left the SQ (the load records the store's index and wrap bit).
A ready entry re-enters at AG when the AG slot is empty. While one is ready, IQ-LD's select is blocked (`sel_block`), so the slot frees within two cycles. Oldest ready entry first.

**MMIO loads** issue on `mmio` only when the load is the ROB head and the SQ is empty (all older stores drained): `Get` of the access size, one outstanding. The response is aligned and extended, waits for a free load-pipe WB slot, and completes the load with `mmio = 1`. `denied`/`corrupt` → access fault. No interrupt is taken while the request is out or between the load's completion and its commit, so a device read is never repeated.

### Stores
- **STA pipe:** RF → AG: VA, misaligned (cause 6), access fault (cause 7: above `PA_W`, `PMA_NONE`, `PMA_ROM`), `PMA_DEVICE` → MMIO store. The address and byte mask go into the SQ entry.
- **Ordering check:** at AG, every younger load (allocated after this store) that has already obtained its value from the cache or from an older store, with a byte overlap in the same dword, is marked for replay in the ROB (the oldest such load is enough; the ROB flushes at it).
- **Data capture:** each cycle the oldest SQ entry without data whose register is written reads it through the shared read port. An entry knows its register is written from rename's ready bit at dispatch, or by snooping the register-file write ports (one compare per entry and bank), so the read sees the value; there is no lookup of the ready table per entry.
- **Cold storage (LUTRAM):** the LQ's and SQ's virtual addresses (tval, the trace's `mem_vaddr`, the ROB head's walk) and the SQ's data (the trace, forwarding, the drain, atomics) live in `tg_ram_lut`s; the CAM flip-flops hold the physical address, masks and state.
- **Completion:** the ROB entry completes when the SQ entry has its address and its data (or an exception).
- **Commit** marks the entry committed; **drain** takes the SQ head once committed: cacheable stores write the D$ when the line is held with T (setting dirty), otherwise they request the MSHR (`AcquireBlock NtoT`, or `BtoT` from B) and retry; MMIO stores send `PutFullData` and pop on `AccessAck`.
- **Flush:** uncommitted entries are dropped (tail ← commit pointer); committed ones keep draining. `sq_empty` gates FENCE, FENCE.I and MMIO loads.
- **Known M2 limit:** a `denied` Grant for a committed store cannot be precise; it is dropped and counted.

### Forwarding (M1/M2)
The SQ entries older than the load (allocated before it, from the head up to the SQ tail the load saw at rename, compared with index plus wrap bit) are searched for the same dword with a byte overlap. The youngest match decides: it forwards if it covers every byte the load reads and has its data; otherwise the load waits (`STQ`). No match: the cache decides.

### Atomics (A extension, M3)
LR.W/D, SC.W/D and the AMOs (SWAP, ADD, XOR, AND, OR, MIN, MAX, MINU, MAXU) are serialising: each is dispatched into an empty window and performed at the ROB head, after every older store has drained (plan §5.3: atomics with .aq or .rl are fully ordering in v1, and serialising them makes every atomic so). Built behind `EXT_A` (with `misa.A`).
- **Issue:** one `C_ST` uop with `amo` set, on the store-address port (address = rs1, no offset) and with an SQ entry whose data is rs2 (x0 for LR). The destination is in the load bank with an LLT, like a load's (plan §4.7: B2 takes SC/AMO results).
- **The SQ entry** never forwards to a load, does not complete the ROB entry at STA or data capture, and leaves the SQ without a write once committed (the atomic wrote the D$ before it committed). It holds the value written, for the trace.
- **Faults** at AG (Spike's types):
  - LR: misaligned is cause 4; an address that is not `PMA_MEM` (device, ROM, none, above `PA_W`) is cause 5.
  - SC and AMO: misaligned is cause 6; not `PMA_MEM` is cause 7 (interfaces.md §2.4; the checker makes Spike refuse device AMOs).
  - A denied fill of the atomic's line is an access fault (5 or 7) at the head.
  - Page faults (13, 15) and PMP come with the MMU (core-mmu.md).
- **Performing it** (an FSM in the LSU): it starts when the uop is the ROB head, its SQ entry has the address and the data, and the SQ head is that entry (every older store drained).
  1. The D$ holds the line with T: the MSHR acquires it (`AcquireBlock NtoT`, or `BtoT` in place) if needed, as for a store.
  2. With T held, the MSHR idle and no probe active or waiting, the D$ reads the row through port B; the next cycle the LSU computes the new value (AMO ALU; .W forms on the addressed word, results sign-extended) and the D$ writes it with the byte mask (`am_ack`). Across these two cycles nothing else uses port B, the MSHR does not start and no probe is accepted, so no probe can see the line between the read and the write.
  3. The old value (LR, AMO) or the SC outcome goes to rd through the load result register; the ROB entry completes there.
- **Interrupts** are not taken from the dispatch of an atomic to its commit, so a performed atomic always retires. (The same rule now holds for an MMIO load between its completion and its commit: it has side effects.)
- **Reservation** (one per hart): LR sets it to its 64-byte line. SC succeeds when the reservation is valid for the SC's line at the write cycle; an SC whose line has no reservation when it starts fails without touching memory. Every SC ends it.
  - It is also ended by a trap or xRET, and by the D$ reporting that the line left the cache or lost T (`lose_v`: a probe to B or N, an eviction).
  - It is **not** ended by the flush that follows every serialising instruction: that flush follows LR itself.
  - An RTL failure where Spike succeeds is adopted by the checker (interfaces.md §5 v1.1). The RTL never succeeds where Spike fails, because its reservation is never wider than Spike's **provided Spike's ISA string has `za64rs`** (without it Spike reserves the exact address).
- **Trace:** rd = the old value (LR, AMO) or 0/1 (SC). `mem_st` and its fields carry the value written (AMO, successful SC); LR and a failed SC report no store.
- **Verification:** `rv64ua-p` (19 tests), `tests/isa/directed/amo.S` (ordering against the SQ, rd = x0/rs1/rs2, reservation rules, every fault cause), and `tests/random` with `--isa rv64ima`, each with `--probe-rate`, `--grant-b`, `--bp` and long latencies.

### L1 data cache (`tg_dcache`)
- **Arrays:** per way a `tg_ram_tdp` of 256 × 128 bits with byte enables. Port A: load reads. Port B: refill writes, store writes, Release and ProbeAck data reads. Tags: one `tg_ram_lut` per way (64 × (`PA_W` − 12) bits) with read ports for the load pipe, the store drain and the controller. State per set in `tg_ram_lut`s (no flip-flop arrays, plan §8.3): the round-robin victim pointer and, per way, valid, T and dirty (M = T + dirty, E = T, S = valid without T). The valid bits have four read ports (load, store/atomic, controller, the set being written); the rest is a second RAM, written with them, without the load port (the load pipe reads only valid); one write per cycle, a read-modify-write of one set, in priority order: the reset sweep (`SETS` cycles, during which rename does not start and probes wait), a probe update, an MSHR install (waits a cycle behind a probe update), an allocation, a store or atomic setting dirty (a store write waits while an install or allocation has the port).
- **MSHR (one):** owns one line at a time, for a load miss (`AcquireBlock NtoB`) or a store (`NtoT`/`BtoT`). Victim: an invalid way, else round robin per set. A valid victim is released first: `Release` (clean, `TtoN`/`BtoN`) or `ReleaseData` (dirty, 4 beats read through port B); its state is cleared when the Release starts, and the Acquire waits for `ReleaseAck`. Grant data beats are written through port B; `GrantAck` follows the last beat; the tag and state are written last (`toT` → T clean, `toB` → valid). A `denied` Grant leaves the line invalid; loads waiting on it then take an access fault on replay.
- **Probes:** answered without waiting for any A-channel progress (TL-C rule 4), at the line's current permission: not present → `ProbeAck NtoN`; T with cap toT → `TtoT`; T to B or N → `ProbeAckData` if dirty, else `ProbeAck`, with `TtoB`/`TtoN`; B to N → `BtoN`; B otherwise → `BtoB`. `ProbePerm` never carries data. A probe waits only for a C-channel message already in progress (beats are contiguous).
- **Port B arbitration:** probe reads, then Grant writes, then Release reads, then store writes; an atomic's read and write take port B only when nothing else can (above). `d_ready` is held low while port B is busy with a probe; B and D are always eventually accepted.
- **Ordering of a hart's own accesses** is kept by the LQ/SQ rules above. Snoop marking of executed loads (plan §4.9, same-address load-load ordering across harts) is M8.

## Parameters
`LQ_ENTRIES`, `SQ_ENTRIES`, `L1D_KIB`, `L1_WAYS`, `PA_W` from `tg_pkg`. One load pipe and one store-address pipe in every configuration (plan §4.15: width-independent).

## Timing and area
- **Queues:** the fields the searches compare (physical address, byte masks, state, IDs) are flip-flops. Virtual addresses and store data are in LUTRAM (cold storage, lever R7).
- **Age searches:** the replay pick, store-data capture, forwarding and the ordering check are each two priority encoders over a mask of slots, with no ID arithmetic.
  - A queue's entries lie in [head, tail). So the oldest of a set of slots is the first at or after the head's slot, else the first from slot 0.
  - The youngest store older than a load is the last match below the load's `lq_sq` slot, else the last match overall.
  - Window checks compare slot numbers with the head and the bound.
- **Store bytes:** forwarding, the drain and atomics use the store's bytes copied into every aligned slot of their size, instead of shifting them to the address. Stores are naturally aligned, so their own byte lanes hold the copy that a byte-masked write or a covered load reads.
- **MMIO loads** are picked at the LQ head. A load at the ROB head is the oldest in the window, so it is the LQ head.
- Per-unit LUT counts: core-pipeline.md §16.

## Verification
Spike lockstep on riscv-tests (`ld_st`, `st_ld`, misaligned and access-fault tests), CoreMark and Dhrystone, with `--lat`, `--bp`, `--d-gap`, `--grant-b` (S state and upgrades) and `--probe-rate` (random probes) stress; the harness's TL-C monitor checks the protocol rules.

## Provenance
- Store queue forwarding and ordering-violation replay: Hennessy and Patterson, ch. 3; Moshovos et al. (memory dependence speculation) as background; plan §4.9.
- TileLink TL-C client behaviour: TileLink Specification 1.8.1 (SiFive), as restricted by interfaces.md §2.3.
- No other core's RTL was read.
