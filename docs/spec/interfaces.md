# Cross-track interfaces

**Status:** v1, 2026-10-13, M0. Owner: coordinator. Changes go through the coordinator (§7).

These are the contracts between the tracks: core, FPU, SoC, verification and spikes. The SystemVerilog packages are the source of truth for field names and widths:

| Package | Contents |
|---|---|
| `tg_pkg` | configuration and derived parameters |
| `tg_tl_pkg` | TileLink channels |
| `tg_fpu_pkg` | core ↔ FPU |
| `tg_trace_pkg` | commit trace |
| `tg_map_pkg` | memory map and physical-memory attributes (PMAs) |

This document gives the semantics. Stubs with the exact ports exist from day one: `rtl/core/tg_core.sv` and `rtl/core/fpu/tg_fpu.sv`.

## 1. The core (`tg_core`)

One `tg_core` instance is one core with `NUM_THREADS` harts.

| Port group | Contents |
|---|---|
| Clock and reset | `clk`; `rst` (active-high, synchronous) |
| Boot | `boot_addr_i`: reset PC of every hart, in M-mode. The SoC passes the boot ROM (`0x1000`); bare-metal simulation passes `0x8000_0000`. |
| Interrupts and time | per-hart `irq_{mei,sei,mti,msi,ssi}_i` (§3); `mtime_i`; `debug_req_i` (M9) |
| Machine error | `merr_o[tid]`: pulses when a refill for an early-retired load returns an error (plan §4.5). The SoC routes it to a PLIC source. |
| Memory | three TileLink ports: `l1i`, `l1d` and `mmio` (§2) |
| Trace | `COMMIT_WIDTH` retire records and `TRACE_WB_PORTS` deferred-writeback records per cycle (§5) |

- **Parameter `CORE_ID`:** `mhartid = CORE_ID * NUM_THREADS + tid`.
- **After reset:** every hart starts at `boot_addr_i` in M-mode with the reset state of the privileged spec. In SMT2 builds both harts start; software parks hart 1 (OpenSBI HSM).
- **Configuration-independence:** the port list is identical in all four configurations. Only the widths derived in `tg_pkg` change.

## 2. Memory ports: TileLink

- **Semantics:** opcodes, permission parameters and message rules are those of the public **TileLink spec 1.8.1**, with the subsets and widths below.
- **Fields:** a field TileLink defines but a channel never needs is left out of our structs (see `tg_tl_pkg`).

### 2.1 Common rules

| Item | Rule |
|---|---|
| Address | `PA_W` (34) bits, naturally aligned to the message size |
| Data | 128-bit beats; a 64-byte line is 4 beats in ascending address order. Beats of one message are contiguous on their channel. |
| Size | log2 of the bytes |
| Source | Unique among the port's outstanding transactions. The core drives `source[5:0]` and zero above; the interconnect owns `source[9:6]` for routing. |
| Sink | Chosen by the manager in Grant; echoed in GrantAck (E) |
| Handshake | `valid` and `ready` per channel, as in conventions §3 |
| Reset | All channels idle while `rst` is high |

- **Errors:** `denied` on D means an access fault for the requester.
  - On a load that has not retired, the fault is precise.
  - On an early-retired load it raises `merr_o`.
  - `corrupt` data is treated the same way.

### 2.2 `l1i`: instruction fetch (channels A, D)

- **Requests:** only `Get`, normally of a whole line (size 6), from DRAM or from the boot ROM.
- **Responses:** `AccessAckData` beats.
- **Coherence:** instruction lines are not tracked as owned copies. The L2 answers `Get` with current data (plan §5.2).
- **FENCE.I:** handled inside the core: drain the store queue, invalidate the I$ (plan §5.2).
- **Outstanding requests:** up to `L1I_MSHRS` (4).

### 2.3 `l1d`: cacheable data (channels A, B, C, D, E; TL-C)

- **Scope:** every access to `PMA_MEM` goes through this port: loads, stores, LR/SC, AMOs, page-table walks, prefetches and early ownership requests.
- **L1D states and TileLink permissions:** M and E are T (Tip) with a local dirty bit; S is B (Branch); I is N (Nothing).

| Message | Channel | Use |
|---|---|---|
| `AcquireBlock NtoB` | A | load miss; the manager may grant `toT` when no other agent holds the line (E) |
| `AcquireBlock NtoT` | A | store, AMO or LR miss; ownership prefetch |
| `AcquireBlock BtoT` / `AcquirePerm BtoT` | A | upgrade S → M |
| `AcquirePerm NtoT` | A | whole-line write without reading (Zicboz, later) |
| `GrantData` / `Grant` | D | 4 beats with data / permission only |
| `GrantAck` | E | sent after the whole Grant is received |
| `Release` / `ReleaseData` | C | eviction: `TtoN` or `BtoN`; dirty lines use `ReleaseData` |
| `ReleaseAck` | D | the Release is complete |
| `ProbeBlock` / `ProbePerm` | B | the manager asks the agent to drop to `toB` or `toN` |
| `ProbeAck` / `ProbeAckData` | C | reports the shrink; dirty data goes with `ProbeAckData` |

Concurrency rules (TileLink TL-C):
1. The agent has at most one outstanding Acquire per line.
2. It sends no Acquire for a line whose Release has not been acknowledged (`ReleaseAck`).
3. The manager sends no Probe for a line to an agent whose Grant for that line still awaits `GrantAck`.
4. The agent answers Probes without waiting for any of its own outstanding A-channel requests. A probe acts on the line's current permissions, including a line with a pending Acquire.
5. The agent always eventually accepts B and D. Its handling of B and D never depends on progress on A.
6. A line evicted after a Grant, before the core's store drained into it, is simply acquired again (plan §6.5, store drain).

**Phasing.**
- **M2–M4:** a single core with a simple single-agent L2 or a memory model. B traffic may never occur, but the port and the rules above are implemented from the start.
- **M8:** the coherent L2 exercises them.

### 2.4 `mmio`: uncached device access (channels A, D)

- **Scope:** every data access to `PMA_DEVICE`, and data loads from `PMA_ROM`.
- **Requests:** `Get`, `PutFullData` and `PutPartialData` of size ≤ 3 (up to 8 bytes), naturally aligned, single beat.
- **Responses:** `AccessAckData` / `AccessAck`.
- **Issue rules:**
  - Accesses are non-speculative: they issue at the ROB head (plan §4.9).
  - At most one is outstanding per hart, with a distinct source per hart.
  - Responses may return in any order across sources.
- **Atomics:** AMO and LR/SC to a device or ROM address are access faults, raised in the core from `tg_map_pkg::pma_of`.

## 3. Interrupts, time and boot

| Input | mip bit | Source |
|---|---|---|
| `irq_mei_i[t]` | MEIP | PLIC, machine context of hart t |
| `irq_sei_i[t]` | SEIP | PLIC, supervisor context. Software can also set mip.SEIP; the bit reads as the OR of the two. |
| `irq_mti_i[t]` | MTIP | ACLINT MTIMER compare for hart t |
| `irq_msi_i[t]` | MSIP | ACLINT MSWI |
| `irq_ssi_i[t]` | SSIP (OR with the software bit) | tied 0: no SSWI in the platform today |

- **Interrupt inputs:** level-sensitive and synchronous to `clk`.
- **`mtime_i`:** the ACLINT's free-running count at `TIMEBASE_HZ` (10 MHz). The core reads it for the `time` CSR and compares it with `stimecmp` (Sstc) to drive STIP.
- **Memory map, PMAs and the platform-facing boot flow:** in `tg_map_pkg` and plan §5.4 and §7.2.
- **PMA routing:**
  - `PMA_MEM` uses `l1d` (data) and `l1i` (fetch).
  - `PMA_ROM` uses `l1i` (fetch) and `mmio` (loads); stores fault.
  - `PMA_DEVICE` uses `mmio`, and fetch from it faults.
  - `PMA_NONE` faults.

**Bare-metal simulation conventions** (owned by the verification track):
- Programs are linked at `0x8000_0000`.
- The console is the 16550 transmit register at `UART_BASE`.
- Programs end with a riscv-tests-style write to `tohost`. The harness sees that write in the commit trace, because the line may stay in the L1D.

## 4. Core ↔ FPU (`tg_fpu`)

The FPU track builds the execution units. The core owns everything else: issue queue IQ-FP and port P4, the FP register file, renaming, writeback-port arbitration and `fcsr`.

| Unit | Ops (`fop_e`) | Timing | Flow control |
|---|---|---|---|
| FMA | FADD, FSUB, FMUL, FMADD, FMSUB, FNMSUB, FNMADD | exactly `FMA_LAT` (5) cycles, fully pipelined | none: the core reserves the writeback slot at issue |
| FMISC | sign injection, MIN/MAX, compares, FCLASS, FCVT (F↔F, F↔I), FMV | exactly `FMISC_LAT` (2) cycles, fully pipelined | none |
| FDIV/FSQRT | FDIV, FSQRT | `FDIV_LAT_S/D`, `FSQRT_LAT_S/D` (18/23, 20/26); a new operation every `FDIV_II` (4) cycles | `fdiv_ready_o` on requests; `fdiv_ready_i` on results (a result waits for a free writeback slot) |

- **P4 issue:** issues one FP operation per cycle to exactly one unit.
- **Operands:** `a`, `b` and `c` as held in the 64-bit FP registers.
  - For FCVT.F.I and FMV.F.X, `a` carries the integer source.
  - `rm` is already resolved: never DYN. The core substitutes `frm` and raises illegal-instruction for reserved values.
- **Results:**
  - FP results are NaN-boxed when `fmt = S`.
  - Integer results (`int_dest = 1`: compares, FCLASS, FCVT to integer, FMV.X) follow the RV64 sign-extension rules.
  - `fflags` are per operation. The core accumulates them into `fcsr` at completion (plan §4.5).
- **Semantics:** RISC-V F and D (unprivileged ISA 20240411):
  - canonical NaN;
  - an improperly NaN-boxed single input reads as the canonical NaN;
  - FMIN/FMAX per F 2.2;
  - saturating FCVT that sets NV;
  - FEQ quiet, FLT/FLE signalling.
- **Tags:** `tag` (`FPU_TAG_W` bits) is opaque to the FPU and returned unchanged.
  - The FPU has **no kill input**. The core drops results whose tag belongs to a squashed instruction, and frees resources itself.
  - Operations that retired early are never squashed (plan §4.5).
- **Reset:** clears every unit's valid state. The FPU holds no architectural state.
- **Future (Zfhmin):** `FMT_H` exists in the enum; the FPU may reject it until Zfhmin is scheduled.

## 5. Commit trace (`tr_rec_t`, `tr_wb_t`)

The core emits up to `COMMIT_WIDTH` `tr_rec_t` per cycle. The consumers are the Spike lockstep checker in simulation and the trace ring and streaming to the A53 on the FPGA (plan §7.4, §9).

**Ordering.**
- Per hart, records are in program order.
- Within a cycle, a lower slot is older.
- Records of different harts may interleave.

| Kind | Emitted when | Key fields |
|---|---|---|
| `TR_RETIRE` | an instruction retires | `pc`, `insn`, `rvc`, `priv`, the `rd_*` fields, the `mem_*` fields for stores, SC and AMOs |
| `TR_TRAP` | an instruction raises an exception instead of retiring | `pc`, `insn`, `priv` (before the trap), `cause`, `tval` |
| `TR_IRQ` | an interrupt is taken before the instruction at `pc` | `pc` (= the new `xepc`), `priv`, `cause` |

**Deferred writebacks (early retirement).**
- A record with `rd_deferred = 1` retired before its value existed.
- The value follows later in a `tr_wb_t` with the same `(hart, wb_tag)`, on one of the `TRACE_WB_PORTS` ports.
- A `wb_tag` is not reused for a hart until its `tr_wb_t` has been emitted.
- The checker holds the compare of that register until the value arrives. Later instructions that read the register are compared as usual, because Spike computes their results itself.

**Legal differences.** The checker adopts the RTL's value instead of comparing it:
- `mmio_ld = 1`: a load from a device or ROM region.
- `nondet = 1`: reads of `cycle`, `time`, `mip`, `sip`, the `hpmcounter*` registers, and any other CSR the checker lists as non-deterministic. `instret` is compared exactly.
- `TR_IRQ`: the checker makes Spike take the same interrupt (`cause`) at the same instruction boundary.
- `fflags` and `fcsr` are compared only where software reads them, never per instruction.

**Stores.** `mem_vaddr`, `mem_wdata` and `mem_size` are compared with Spike's commit log.

**Future fields.** With the fusion, SFB or jump-folding options enabled, a record may stand for more than one instruction. A count field will be added when one of those options is scheduled; none is in v1.

## 6. Reset and clocks between tracks
- **SoC clocks:** `clk_core` (200 MHz goal, 150 floor) and `clk_host` (100 MHz). Only the host bridge crosses between them (plan §7.1).
- **Resets:** synchronous `rst` per clock domain. The SoC holds the cores in reset until `tanager-host` releases them (plan §7.2).

## 7. Changing an interface
1. Message the coordinator with the change, the reason and the tracks it affects.
2. The coordinator updates this document and the package together, in one commit on `main`, so every track can merge it.
3. Additive changes (a new field at the end of a struct, a new opcode) are preferred to renames.
