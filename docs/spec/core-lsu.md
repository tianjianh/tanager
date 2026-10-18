# Load/store unit and L1 data cache (`tg_lsu`, `tg_dcache`, M2)

Status: implemented for M2; atomics implemented for M3 (`EXT_A`, on) — core track — 2026-10-14

## Purpose
Executes loads and stores for the M2 core ([core-pipeline.md](core-pipeline.md)), keeps memory order for one hart, and is the TL-C client on the `l1d` port and the TL-UL client on `mmio` (interfaces.md §2.3, §2.4). Plan §4.9 and §4.11 are the targets; M2 builds the parts in the table and leaves the rest for M6.

| Plan | M2 |
|---|---|
| Load pipe AG → M1 → M2, 3-cycle load-to-use with speculative wakeup | same stages; 3-cycle load-to-use with `SPEC_WAKE` (the default: `tg_issue` wakes an integer load's dependants at AG and cancels the shadow when it does not complete in M2, core-pipeline §6); with `SPEC_WAKE=0` dependants wake on the confirmed result at the end of M2 (5-cycle load-to-use) |
| LQ: 16-entry CAM part + 8-entry retired-load completion buffer | the CAM part (`LQ_ENTRIES`); no completion buffer (nothing retires early) |
| SQ (`SQ_ENTRIES`) with store data captured through the shared read port | same |
| Forwarding: youngest older store that covers the load; partial overlaps wait | same |
| Ordering violations: store-address search of younger executed loads, flush at commit | same |
| 16 MSHRs, early ownership prefetch, stride prefetcher | 1 MSHR; no prefetch |
| 32 KiB, 8-way, VIPT, write-back, MESI | same geometry; PA = VA (no MMU yet) |

## Interface
Inside `tg_core` (packages: `tg_core_pkg`, `tg_tl_pkg`, `tg_map_pkg`):
- **From dispatch:** LQ/SQ entry allocation (valid, state); for stores also the data's physical register, its file, and the atomic flag.
- **At AG / STA:** the rest of the entry, from the port's payload, since nothing reads it before: a load's ROB index, SQ bound, destination, LLT, size and extension; a store's ROB index and size. One write per queue and cycle, so no entry multiplexes the dispatch slots.
- **From issue (RF stage):** the LD and STA ports' payloads; their base operands come bypassed from `tg_exec` in EX.
- **Register file:** the shared store-data read port (address from the SQ, data back in the same cycle); the load bank's write port (written at WB from the load result register).
- **To the ROB:** load and store completion, exceptions {ROB index, cause, `tval`}, replay marks (ordering violations), `mmio` marks.
- **From the ROB:** head index (MMIO loads), per-cycle commit of loads (LQ head) and stores (SQ commit mark), and the trace fields of committed stores (address, data, size).
- **To rename/ready table:** the load bank's write events; LLT releases. **To `tg_wake`:** the LLT of each confirmed load result (`wake_ld`). With `SPEC_WAKE`, `tg_issue` has already woken an IQ load's LLT at AG and takes a missing `wake_ld` four cycles after the load's issue (*s*+4) as the shadow cancel (core-pipeline §6).
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
- `MISS`: the MSHR is idle (with `DC_MSHRS` = 4: its entry installed, or for "any", see the L1D below).
- `STQ` without data: the blocking store has its data or has left the SQ; `STQ` partial overlap: the blocking store has left the SQ (the load records the store's index and wrap bit).
A ready entry re-enters at AG when the AG slot is empty. While one is ready, IQ-LD's select is blocked (`sel_block`), so the slot frees within two cycles. Oldest ready entry first.

**MMIO loads** issue on `mmio` only when the load is the ROB head and the SQ is empty (all older stores drained): `Get` of the access size, one outstanding. The response is aligned and extended, waits for a free load-pipe WB slot, and completes the load with `mmio = 1`. `denied`/`corrupt` → access fault. No interrupt is taken while the request is out or between the load's completion and its commit, so a device read is never repeated.

### Stores
- **STA pipe:** RF → AG: VA, misaligned (cause 6), access fault (cause 7: above `PA_W`, `PMA_NONE`, `PMA_ROM`), `PMA_DEVICE` → MMIO store. The address and byte mask go into the SQ entry.
- **Ordering check:** at AG, every younger load (allocated after this store) that has already obtained its value from the cache or from an older store, with a byte overlap in the same dword, is marked for replay in the ROB (the oldest such load is enough; the ROB flushes at it).
- **Data capture:** each cycle the oldest SQ entry without data whose register is written reads it through the shared read port. An entry knows its register is written from rename's ready bit at dispatch, or by snooping the register-file write ports (one compare per entry and bank), so the read sees the value; there is no lookup of the ready table per entry.
- **Cold storage (LUTRAM):** these live in `tg_ram_lut`s; the CAM flip-flops hold the physical address, masks, SQ bound, size and state.
  - The LQ's and SQ's virtual addresses: tval, the trace's `mem_vaddr`, the ROB head's walk.
  - The LQ's ROB index and result fields (destination, LLT, file, extension), next to the VA. They are written at AG and read at M2, at the MMIO load and at the LQ head; the oldest ordering violation's ROB index has a one-port copy. It is read a cycle after the search, from the violating load's registered LQ index (timing, DR-145: the read leaves the search), when the replay mark goes to the ROB (core-pipeline §8.1).
  - The SQ's data: the trace, forwarding, the drain, atomics.
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
- **The read-modify-write:** one port B read and, the next cycle, the write. With `DC_AMO_READ_REG` (DR-140 #5, on in the default profile, off in the fallback) a cycle between them registers the read data.
- **Faults** at AG (Spike's types):
  - LR: misaligned is cause 4; an address that is not `PMA_MEM` (device, ROM, none, above `PA_W`) is cause 5.
  - SC and AMO: misaligned is cause 6; not `PMA_MEM` is cause 7 (interfaces.md §2.4; the checker makes Spike refuse device AMOs).
  - A denied fill of the atomic's line is an access fault (5 or 7) at the head.
  - Page faults (13, 15) and PMP come with the MMU (core-mmu.md). A PMP denial found after the decision (S2, below) marks the SQ entry: the atomic faults as it starts (5 or 7), without an access, and an SC keeps its reservation, as when the fault came at AG.
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
- **Arrays:** per way a `tg_ram_tdp` of 256 × 128 bits with byte enables. Port A: load reads, enabled for every AG operation whether or not it goes on to M1. Only M1 of the operation that read uses the data, and M1 and M2 never hold, so a read for an operation that stops is never seen. This keeps the new load's TLB, PMP and fault decision off the block RAM's enable. Port B: refill writes, store writes, Release and ProbeAck data reads. Tags: one `tg_ram_lut` per way (64 × (`PA_W` − 12) bits) with read ports for the load pipe, the store drain and the controller. State per set in `tg_ram_lut`s (no flip-flop arrays, plan §8.3): the round-robin victim pointer and, per way, valid, T and dirty (M = T + dirty, E = T, S = valid without T). The valid bits have four read ports (load, store/atomic, controller, the set being written); the rest is a second RAM, written with them, without the load port (the load pipe reads only valid); one write per cycle, a read-modify-write of one set, in priority order: the reset sweep (`SETS` cycles, during which rename does not start and probes wait), a probe update, an MSHR install (waits a cycle behind a probe update), an allocation, a store or atomic setting dirty (a store write waits while an install or allocation has the port). The read for the write: the fourth read port reads the set of a probe update, an install or an atomic's write (registers); an allocation and a store take the state their own ports read, the same set in the same cycle (timing, DR-145: the late arbitration selects the write and no longer addresses a read before it; a simulation shadow of the state checks each write's source).
- **MSHR (one):** owns one line at a time, for a load miss (`AcquireBlock NtoB`) or a store (`NtoT`/`BtoT`). Victim: an invalid way, else round robin per set. A valid victim is released first: `Release` (clean, `TtoN`/`BtoN`) or `ReleaseData` (dirty, 4 beats read through port B); its state is cleared when the Release starts, and the Acquire waits for `ReleaseAck`. Grant data beats are written through port B; `GrantAck` follows the last beat; the tag and state are written last (`toT` → T clean, `toB` → valid). A `denied` Grant leaves the line invalid; loads waiting on it then take an access fault on replay.
- **Four misses in flight (`DC_MSHRS` = 4, DR-149; `TG_DC_MSHRS`, 4 in both profiles since DR-156, the user's decision of 10-17; `TG_DC_MSHRS=1` gives the one-MSHR L1D).** With 1, the L1D is the one-MSHR design above, unchanged (the miss side is a generate branch behind shared signals; cycle-identical).
  - **Entries:** each owns one line from its allocation to its install: a load's (`NtoB`), or a store's or an atomic's (`NtoT`, or `BtoT` for a line held in B, which stays valid in B meanwhile). No two entries hold one line.
  - **The victim search** skips the ways the set's entries hold: the first invalid way they left, else the first way from the round-robin pointer on that no entry holds (4 < 8 ways).
  - **One release engine** takes a valid victim at its allocation; the victim's state is cleared then, as before. It reads each beat through port B, takes it into its own register the next cycle and sends it from there, so Grants for other entries may write port B meanwhile and D never waits for C. The entry's Acquire goes out after the last beat. Only the engine waits for `ReleaseAck` (source 4); another allocation whose victim is valid waits for the engine.
  - **Allocation:**
    - The store port allocates in its own cycle, as before, when a free entry exists and no entry holds its line.
    - Loads' and the walker's misses go through a request register. The next cycle each one merges with the entry holding its line, finds the line present, allocates, or gets no answer. The answer is registered and reaches the LSU two cycles after `lm_req`.
    - No allocation shares a cycle with an install (the state port's one write).
  - **Sources:** Acquires carry their entry's index (0-3) and the Release carries 4. Grants come back in any order, matched by source; a Grant's beats are contiguous, so port B writes one Grant at a time. One install per cycle, the lowest entry first, after a probe update.
  - **Wakeups:** an `L_MISS` load records the entry it waits on, or "any" while it has no answer. It becomes ready the cycle after that entry installs, or on any install, ReleaseAck or idle miss side. The walker waits for "any".
  - **Denials:** kept one line per entry.
  - **Atomics:** an atomic's read waits until nothing is in flight. Loads' allocations stop while an atomic is requested, so the entries drain.
- **Probes:** answered without waiting for any A-channel progress (TL-C rule 4), at the line's current permission: not present → `ProbeAck NtoN`; T with cap toT → `TtoT`; T to B or N → `ProbeAckData` if dirty, else `ProbeAck`, with `TtoB`/`TtoN`; B to N → `BtoN`; B otherwise → `BtoB`. `ProbePerm` never carries data. A probe waits only for a C-channel message already in progress (beats are contiguous). The probe ready (`b_ready_o`) comes from state registers alone: an MSHR allocation already yields to a probe on offer, so it needs no term in the ready (timing: the store drain's and the load miss's tag lookups left the crossbar's B-slice enable).
- **Forward progress under probes** (two cores): probes wait, each time for a bounded number of cycles and never for A-channel progress (TL-C rule 4):
  - **A line installed for a store or an atomic** keeps its first access. From the install cycle until the store writes it or the atomic reads it, at most 8 cycles, probes wait and so do other allocations; the atomic's `am_busy` then covers its write. The atomic's read yields only to a probe that is taken in that cycle, not to one on offer.
  - **A load's line** holds probes for 4 cycles, its replay's time to M1.
  - **A young LR reservation** holds them until its SC ends it, or for at most 64 cycles (`pr_hold`, the LSU's).
  - The holds are registers, so `b_ready_o` stays one.
  - **Why:** without them, two cores whose atomics met on one line took it from each other forever. The probe for the other core's Acquire was taken in the install cycle, before the line's first access. The board's first two-core boot hung so at OpenSBI's boot lottery (`amoswap.w`, both harts in step).
- **Port B arbitration:** probe reads, then Grant writes, then Release reads, then store writes; an atomic's read and write take port B only when nothing else can (above). `d_ready` is held low while port B is busy with a probe; B and D are always eventually accepted.
- **The store port's decisions select last** (timing, DR-145: in G6 the ROB's flush and the atomic's PMP flag → the store port's tag reads → its compare → the way's T bit → the allocation → port B and the state RAMs, about 2,000 failing endpoints per core, −1.34 to −1.49 ns):
  - The store port's lookup address follows the atomic's state (`am_sel`, a register) instead of its request. No store drains while an atomic holds the port (asserted), and without a request the lookup is unused.
  - Its T hit is an AND-OR over the hit vector, which is one-hot (asserted).
  - The allocation and the store's write take the hit last. A store that hits allocates nothing, so only a load's allocation can take the state port from it.
  - Port B's address, byte enables and data default to the store port's: a disabled way neither reads nor writes, so only the ways' enables wait for its hit.
  - The late state writes (an allocation with a victim, a store setting dirty) select last, each from its own port's state, with its victim from that port.
  - The MSHR's request fields load in every idle cycle, as they are read only after it leaves `M_IDLE`; only its state waits for the allocation.
  - The earlier form stays as a simulation reference: every decision, port-B access, state write and MSHR field is asserted equal each cycle.
- **#11** (`DC_PORTB_WREG`, DR-148; on in the default, off in the fallback): port B's writes (Grant beats, stores, an atomic's write) reach the block RAMs a cycle later, from a register, so the RAMs' write inputs start at flip-flops. Port B's reads (probe, Release, atomic) wait a cycle while a write lands, and no write is decided while port B's output holds a read (asserted). A load whose AG read the row in the write's second cycle retries too: the row clash has a second stage. The state RAMs are written as before.
- **Ordering of a hart's own accesses** is kept by the LQ/SQ rules above. Snoop marking of executed loads (plan §4.9, same-address load-load ordering across harts) is M8.

## The address-stage split (`LSU_AG_SPLIT`, DR-140 #4: on in the default profile, off in the fallback)

- **The switch:** an elaboration parameter that selects generate branches, so each setting builds only its own logic. `TIMING_CUTS` sets it together with #5 (core-pipeline §13).
- **What the two forms share:** the translation, the checks, the reports and the queue writes. They read the deciding stage's operands through `ln_*` (a new load) and `sn_*` (a store address).
- **What each branch drives:** those operands (M1's registers with the split, AG's own signals without), AG's PA and go, M1's PA, go and row clash, and with the split the forwarding bypass.

**Why.** M3 translates in AG: the address add, the DTLB, PMP and every access decision share one cycle. That is the core's worst path family at 200 MHz in the whole-core run (about 11.7 ns, 25–32 levels, core-pipeline §16). Its endpoints are in the ROB and inside the LSU, so cutting only the reports to the ROB cannot fix it. DR-057's plan had the DTLB in M1.

**The pipes after the split** (load-to-use unchanged):

| Stage | Load | STA |
|---|---|---|
| AG | VA = base + imm; misaligned; D$ data read issued at row VA[11:4] (the page offset, VIPT); VA into the LQ; enter `L_PIPE` | VA; misaligned; byte mask |
| M1 | DTLB (LD port) on the registered VA → PA (its match read at AG, core-mmu); PMA, the DTLB's cached PMP result, page and access faults, TLB miss, MMIO; tag compare; forwarding search with the PA, **including the STA in M1 this cycle**; PA into the LQ | DTLB (STA port; its match read at AG) → PA; PMA, the DTLB's cached PMP result, faults, TLB miss, MMIO; PA and mask into the SQ; ordering search; completion |
| M2 | as before, and the PMP checker on the registered PA where the decision had no cached result (below) | the PMP checker on the registered PA where the decision had no cached result (S2, below) |

**Ordering stays exact.** Take a load at AG in cycle t_L and a store at AG in cycle t_S.
- Today, either the load's M1 search sees the store's address (t_S ≤ t_L), or the store's ordering search sees the load's PA in `L_PIPE` (t_S ≥ t_L + 1).
- After the split, both PAs reach their queues at the end of M1. Every case keeps its outcome except t_S = t_L, where both are in M1 together and neither queue holds the other.
- The bypass covers that case: the load's M1 forwarding search compares the store in M1 as if it were in the SQ. That is what it sees today, one stage earlier.

**Moved with the PA:**
- the AG row clash with a store write (registered and compared in M1; the M2 outcome is unchanged);
- the LQ's PA-valid bit;
- the walker's PTE reads and LQ replays, which need no translation and simply pass M1.

**What moves a cycle (the cost to measure):**
- page and access faults, TLB misses (the replay mark and the walk prefetch) and MMIO marks: the fault-reporting row;
- the STA's completion and its ordering replay mark: the completion → ROB row.
- Measured separately as cuts F1 and F2/F5 (§13), which this split subsumes: about 0, and +0.10% to +0.43% by suite.

**Timing risk.** The new M1 holds the DTLB, the tag compare and the forwarding search. If it still misses 5 ns, the forwarding search moves into M2 on the registered PA, with M2's data select after it.

**Measured** (27e069a against fn4's head 028f45e, `make cycle-identical`, change in cycles per suite):

| Config | isa | stress | bench | random |
|---|---|---|---|---|
| st | +0.696% | +0.282% | +0.160% | −0.151% |
| smt2 | +0.476% | +0.014% | +0.088% | +0.123% |
| st_w3 | +0.489% | −0.258% | +0.118% | +0.239% |
| smt2_w3 | +1.565% | +0.273% | +0.006% | +0.257% |

- No program fails: 800 per configuration, the base's harness and lockstep.
- The isa cost is the `-v` tests' page-table setup: their walks report a cycle later, about +95 cycles per test.
- The whole-core timing run is queued.

## Parameters
`LQ_ENTRIES`, `SQ_ENTRIES`, `L1D_KIB`, `L1_WAYS`, `PA_W` from `tg_pkg`. One load pipe and one store-address pipe in every configuration (plan §4.15: width-independent).

## Timing and area
- **Queues:** the fields the searches compare (physical address, byte masks, state, SQ bound, size) are flip-flops. Fields read only by index are in LUTRAM (cold storage, lever R7; FPGA-friendly T1): virtual addresses, store data, the LQ's ROB index and result fields, and the SQ's ROB index (`u_sqrob`: read at the captured store and the commit point) and size (`u_sqsz`: read by the trace and forwarding).
- **Age searches:** the replay pick, store-data capture, forwarding and the ordering check are each two priority encoders over a mask of slots, with no ID arithmetic.
  - A queue's entries lie in [head, tail). So the oldest of a set of slots is the first at or after the head's slot, else the first from slot 0.
  - The youngest store older than a load is the last match below the load's `lq_sq` slot, else the last match overall.
  - Window checks compare slot numbers with the head and the bound.
  - **The oldest of a set** (the replay pick and the ordering check's violator) is found on a carry chain (timing, DR-145: in G6 the ordering check's select took seven LUT levels after its address compares). The set is taken twice, the slots at or after the head's in the low half, so the lowest set bit of the 2N is the oldest (`u & -u`, whose chain carries "no set bit below"). The halves' one-hot bits merge and an OR encode follows. It equals the two-encoder form, which simulation keeps as a reference.
- **Store bytes:** forwarding, the drain and atomics use the store's bytes copied into every aligned slot of their size, instead of shifting them to the address. Stores are naturally aligned, so their own byte lanes hold the copy that a byte-masked write or a covered load reads.
- **Loaded elements** (M2, MMIO loads, an atomic's old value) are extracted for their alignment (`ext_al`). Misaligned accesses trap at AG, so result byte 0 selects among 8 offsets, byte 1 among 4, bytes 2–3 between 2, and the upper half has one source. A byte shifter would offer all 8 everywhere.
- **Reads by index of CAM fields** come from LUTRAM copies written with them: a replay's PA, and the MMIO load's (`u_lqa`), and the SQ head's PA, mask and size (`u_sqh`). The flip-flops stay for the searches.
  - **The SQ head's fields are also held in flip-flops** (timing, DR-145): loaded with the entry that is the head in the next cycle, which is the LUTRAM's read of the entry after the head when the drain pops, with the STA's write in that cycle bypassed. The drain's address into the D$ (tags, data and state RAMs), the MMIO store's and the atomic's then start at a register. Simulation checks them against the entry whenever the head is valid.
- **Atomics** read their SQ entry through the head's ports. An atomic runs only as the SQ head and commit point, and the drain has nothing to do meanwhile (asserted). Its address, size and operand are registered as it starts, so the read-modify-write starts at flip-flops.
- **A new load's PMP check comes after its decision.** A translated access to a PMP-homogeneous page decides with the DTLB's cached result (core-mmu). Bare mode, and a page that a region boundary splits, use the LD port's checker on the registered PA after the decision: in M2 with the split, M1 without it, the verdict taking effect in M2 either way.
  - A denial faults the load in M2. An MMIO load moves from `L_MMIO` to `L_EXC`, its issue held until the verdict.
  - **#10** (`LSU_MMIO_PMP_REG`, DR-148; on in the default, off in the fallback): the MMIO load's verdict is registered before its state takes it. The LQ head's MMIO issue waits while its load checks, and a cycle more if it is denied; the fault still reports in the check's cycle (timing: the checker leaves the LQ state's enables, through the issue). Only MMIO loads that check pay: bare and M mode, or a page that a region boundary splits. A translated device page decides with the DTLB's cached result.
  - With the split, the M2 check's 8-byte flag comes from a register loaded from M1's LQ size read; the load's AG wrote the size a cycle before (timing, DR-145: the LQ field multiplexer leaves the checker's paths; asserted).
  - The wakeups and the miss request do not wait for the checker. A denied load that misses may refill its line, a cacheable line whose data reaches no register.
  - Nor does the result register's arbitration: the MMIO and atomic results take it when no M2 load completes, the verdict aside (`m2_okw`). A load the checker denies leaves it empty that cycle, and they take it the next (timing, DR-145: in G6 the checker → the result take → the wakeup, −1.56 ns).
  - Cycles change only for loads the PMP denies (`tanager-p-pmp`: +1 cycle).
- **A store's PMP check leaves the DTLB's path.** The checker is never behind the DTLB at the store's decision:
  - **A translated store to a page with the DTLB's cached result** decides with it, as before.
  - **A bare-mode store** decides with the STA port's checker on its VA, a register with the split. Data are bare, so no walk runs and the walker never wants the shared checker then.
  - **A translated store to a page without a cached result** (a page that a PMP region boundary splits, which the walker's per-page check makes rare) decides as if PMP allowed it. The checker looks at its registered PA (and size, access, M mode) the next cycle, S2.
    - The store may have completed already (its data was in). A denial reaches the ROB as an exception alone, on a port of its own, a cycle after S2 (S3: `spx_valid`). The store completes as before, when its data comes.
    - The ROB retires nothing from the store on while it is in S2 (`sth_v[0]`, a registered hold, so the checker's verdict stays off the commit path) and, if it is denied, in S3 until the exception shows (`sth_v[1]`).
    - An atomic retires only after it runs: it is marked instead (`sq_pden_q`), starts only after its own S2 check, and faults as it starts (Atomics, above).
    - The walker keeps its grant (core-mmu: shared checker). An S2 check that the walker takes the checker from waits a cycle and holds the store meanwhile.
  - Cycles: identical on the suites in all four configurations and on the Linux boot (st, smt2) with the per-page PMP check. Only stores to split pages pay, a cycle when they would retire at once.
- **Forwarding** (M1, then M2):
  - The search runs over the SQ's stores alone. With the split, the store address in M1 is picked last, by an age compare against the SQ's result (a Shannon expansion), without waiting for its own access-fault checks: a store that faults traps at commit, and the younger load goes with the flush.
  - The youngest matching store is a one-hot vector, formed from flip-flops, that selects the per-entry cover and data-valid bits. It goes to M2 as that vector and is encoded there for the LUTRAM reads (the store's data and size) and the waiting load's store ID. The forwarded data is read in M2.
  - The wakeup's "M2 completes" term is a boolean of its own (forwarded with cover and data, or no older store, no clash and a hit), not a compare on the encoded outcome.
- **MMIO loads** are picked at the LQ head. A load at the ROB head is the oldest in the window, so it is the LQ head.
- **The LSU's privilege** (timing, DR-145): the LSU reads its own copy of the privilege, the data privilege, SUM, MXR and satp, registered a cycle behind `tg_csr`'s (as fetch does, core-pipeline §3.1). They change only at serialising commits, and the flush the next cycle squashes the LSU's new accesses of that cycle (the walker, S2, the head's check and the prefetch are flush-gated). Simulation checks the copies against the live values outside flushes.
- **D$ port B's byte write enables** are shared by the ways. Port B enables one way at most per cycle, and its enables are zero for reads, so the block RAM's port enable already keeps the other ways from writing.
- Per-unit LUT counts: core-pipeline.md §16.

## Verification
Spike lockstep on riscv-tests (`ld_st`, `st_ld`, misaligned and access-fault tests), CoreMark and Dhrystone, with `--lat`, `--bp`, `--d-gap`, `--grant-b` (S state and upgrades) and `--probe-rate` (random probes) stress; the harness's TL-C monitor checks the protocol rules.

## Provenance
- Store queue forwarding and ordering-violation replay: Hennessy and Patterson, ch. 3; Moshovos et al. (memory dependence speculation) as background; plan §4.9.
- TileLink TL-C client behaviour: TileLink Specification 1.8.1 (SiFive), as restricted by interfaces.md §2.3.
- No other core's RTL was read.
