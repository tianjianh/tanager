# Verification infrastructure: harness, lockstep, runners

**Status:** implemented for M2 (§1–§5), 2026-10-13; M3 items (§6) to come. Owner: verification track (conventions §7). Implements plan §9.

What the verification track gives the other tracks:

| Piece | Where | Milestone |
|---|---|---|
| `tg_vsim`: Verilator harness around `tg_core`, with TileLink memory models, a DRAM latency model, UART and CLINT, ELF loading, run control | `sim/` | M2 |
| Spike lockstep checker for the commit trace (interfaces.md §5) | `sim/src/lockstep.*` | M2 |
| `tg_replay`: Spike replayed against Spike, to validate the checker | `sim/src/replay.cpp` | M2 |
| `tg_tcore`: a tiny in-order RV64IM test core with the `tg_core` ports, to prove the harness end to end. Not product RTL. | `sim/tcore/` | M2 |
| riscv-tests runner | `tests/isa/` | M2 |
| CoreMark and Dhrystone for the simulation platform | `tests/bench/` | M2 |
| `make regress CFG=...` | `tools/ci/` | M2 |
| riscv-arch-test ACT4 flow with Sail | `tests/arch/` | M3 |
| Constrained-random instruction generator | `tests/random/` | M3 |
| Fork-based snapshots | `sim/` | M3 |

## 1. Quick start

```bash
source tools/env.sh
make -C sim CFG=st                     # builds tg_vsim for tg_core, configuration st
make -C sim CFG=st CORE=tcore          # the same harness around the test core
sim/run.sh CFG=st prog.elf             # build if needed, then run one ELF with lockstep (the default)
make -C tests/isa CFG=st SUITES="rv64ui-p rv64um-p"   # riscv-tests, pass/fail summary
make -C tests/bench CFG=st run         # CoreMark (flag sets A and B) and Dhrystone
make regress CFG=st                    # everything above for one configuration
```

- **Build trees:** `$TANAGER_BUILD/<worktree>/sim/<cfg>-<core>/tg_vsim`, `.../sim/replay/tg_replay`, `.../bench/<march>-i<iter>-r<runs>/`, logs under `.../regress/` and `.../isa-logs/` (conventions §1). Nothing is written into the repository; passing tests leave no logs.
- **A first build** takes about a minute (Verilator, ccache); rebuilds after a C++ or SystemVerilog change take seconds for the test core.
- **When something fails,** the last lines of the run say why (`TG-RESULT status=...` and the `tg_vsim:` line above it). A lockstep mismatch prints the report of §3.6. Rerun the same command with `--fst=wave.fst --fst-from=<cycle>` for a waveform, or `--log=trace.txt` for every commit record with disassembly.

### 1.1 For the core track

- **Plugging in:** `make -C sim CFG=<cfg>` compiles `rtl/rtl.f`, so files added to `rtl/core/core.f` are picked up. `tg_core` needs nothing else: the harness drives every port of interfaces.md §1–§3 and boots at `0x8000_0000`.
- **What the checker expects** is interfaces.md §5 to the letter. The points that bite first:
  - `insn` holds the raw encoding (16 bits, upper half zero, for a compressed one) and `rvc` matches it; for a fetch fault, the checker ignores `insn`;
  - `tval` follows Spike: the instruction bits for an illegal instruction (16 bits for a compressed encoding without C), the PC for `ebreak`, the address for misaligned and faulting accesses, 0 for `ecall` and interrupts;
  - `TR_IRQ.pc` is the PC of the instruction the interrupt preempts, which becomes `mepc`;
  - stores report `mem_wdata` right-aligned and `mem_size` as log2 bytes; an SC that fails reports no store;
  - `nondet` only on reads of the CSRs in §3.4; `mmio_ld` only on device and ROM loads.
- **ISA and privilege modes:** the default Spike configuration for `CORE=core` is `rv64im_zicsr_zicntr_zifencei`, privilege `M`, 16 PMP regions (M2). Widen it per build (`make -C sim CFG=st ISA=... PRIV=MSU PMP=16`) or per run (`--isa`, `--priv`, `--pmp`) as features land, and tell the verification track so the regression defaults follow.
- **Reset values** that Spike chooses and the core may not: PMP entry 0 (`--pmp-reset=off`), `mtvec` 0, `mstatus.MPP` = U (or M without U). A mismatch on the first read of such a CSR is this.
- **Debugging a mismatch:** the report (§3.6) gives both sides' last 32 instructions. `--log=<file>` writes every record with disassembly; `--fst=<file> --fst-from=<cycle>` dumps waves from shortly before the failing cycle; `--no-lockstep` runs without Spike.
- **Before a merge request:** `make regress CFG=st` and `make regress CFG=st_w3` (conventions §6).

## 2. The harness (`tg_vsim`)

### 2.1 Structure

```
            tg_vsim (C++ main loop: clock, reset, run control)
   ┌──────────────────────────────────────────────────────────────┐
   │ tg_tb_top (SystemVerilog, sim only)                          │
   │   tg_core (or tg_tcore) ── l1i  ── DPI ──► l1i model (TL-UL) │
   │                         ── l1d  ── DPI ──► l1d model (TL-C)  │──► memory image (sparse)
   │                         ── mmio ── DPI ──► mmio model ──► UART, CLINT
   │                         ── trace ─ DPI ──► trace collector ──► lockstep (Spike), tohost, log
   │   irq_*, mtime_i ◄────────────── DPI ◄── CLINT, random IRQs  │
   └──────────────────────────────────────────────────────────────┘
```

- **`tg_tb_top`** (`sim/tb/tg_tb_top.sv`) instantiates the core and turns each port into DPI calls. It never interprets TileLink itself.
- **The models are C++.** They see whole messages and beats, never struct bit layouts: the testbench passes each struct field as its own DPI argument, so a field change in `tg_tl_pkg` or `tg_trace_pkg` is a compile error, not a silent misdecode.
- **Which core:** `CORE=core` (default) compiles `rtl/rtl.f` and `tg_core`; `CORE=tcore` compiles `sim/tcore/tcore.f` and `tg_tcore` (§5) in its place. Both have the same port list.

### 2.2 Cycle protocol

Every input the harness drives into the core is a register in `tg_tb_top`, updated at the rising edge. So the models never form a combinational path into the core, and TileLink's rule that `valid` must not depend on `ready` holds by construction.

At each rising edge, after reset, `tg_tb_top` makes one DPI call per port, in a fixed order (mmio, l1i, l1d, interrupts, trace):
1. It passes what the core presented in the cycle that is ending: each channel's `valid`, payload and `ready`.
2. The model decides which beats fired: a beat fires when `valid` and `ready` were both high in that cycle; the model knows the `ready` and `valid` it drove itself.
3. The model returns its outputs for the next cycle, which `tg_tb_top` registers with non-blocking assignments.

Trace records and deferred writebacks of the cycle are collected by DPI calls in slot order, then processed by the main loop after the edge (§3.3).

### 2.3 Memory image and ELF loading

- **Backing store:** sparse, in 64 KiB chunks allocated on first write; reads of untouched memory return zero.
- **Regions** (from `tg_map_pkg`): DRAM at `0x8000_0000` (size `--mem-mb`, default 2048), the boot ROM at `0x1000` (4 KiB, filled from `--rom=<bin>` or from ELF segments in its range). Fetch, loads and stores outside these regions reach the core's `mmio` port or fault in the core; the models answer a stray access with `denied`.
- **ELF:** ELF64 little-endian RISC-V executables. `PT_LOAD` segments are copied (file bytes, then zero fill to `p_memsz`). Symbols are read for `tohost`, `fromhost`, `tg_marker` and the divergence report.
- **The same image** initialises the lockstep checker's own Spike memory. The two stay separate: the harness memory is what the L2 side of the core sees, Spike's is architectural memory.

### 2.4 TileLink models

All three follow TileLink 1.8.1 as restricted by interfaces.md §2: 128-bit beats, 64-byte lines in 4 ascending beats, beats of a message contiguous, `size` in log2 bytes.

**Common features.**
- **Latency:** a response's first beat is offered no earlier than `lat` cycles after its request fired (§2.5). Responses of different sources may come back in any order once `--lat-jitter` is non-zero.
- **Backpressure:** `--bp=<percent>` drops `a_ready` (and `c_ready`, `e_ready` on l1d) at random; `--d-gap=<percent>` inserts idle cycles between D messages and between their beats. Both are seeded (`--seed`) and default to 0.
- **Protocol monitor:** every port checks the rules it can see and stops the run with a message (`TL-MON <port>: ...`) on the first violation: payload stable while `valid && !ready`; legal opcode, `param` and `size` for the port; natural alignment; mask matching address and size; source not already in flight; beats contiguous; `d_ready` eventually high (`--d-stall-max` cycles, default 10000).
- **Errors on purpose:** `--deny=<addr>[:<len>]` answers accesses to a range with `denied` (and `corrupt` for data), to test precise access faults and `merr_o`. The checker's Spike faults on the same ranges, so precise faults compare in lockstep; an early-retired load that hits one raises `merr_o` instead, which lockstep reports (plan §4.5: that error is imprecise by design).

**`l1i`** (channels A, D).
- `Get` of size 2–6 from DRAM or ROM, answered with `AccessAckData`: one beat up to 16 bytes, four beats for a line. Anything else on A is a monitor error.
- Up to `L1I_MSHRS` requests in flight is legal; more is reported as a warning (the port does not enforce it).

**`l1d`** (channels A–E): a TL-C manager for a single agent, which is what the M2–M4 single core needs (interfaces.md §2.3).
- **Acquire:** `AcquireBlock` (`NtoB`, `NtoT`, `BtoT`) is answered with `GrantData` (4 beats); `AcquirePerm` (`NtoT`, `BtoT`) with `Grant`. `NtoB` is granted `toT` (E state), or `toB` with probability `--grant-b=<percent>` (default 0) so the core's upgrade path gets exercised.
- **Sink:** each Grant gets a free sink ID; it is busy until the matching `GrantAck` on E.
- **Release:** `Release` gets `ReleaseAck`; `ReleaseData` updates memory and gets `ReleaseAck` after its last beat.
- **TL-UL on l1d:** `Get`, `PutFullData` and `PutPartialData` are also served, so page-table walks or uncached paths can use them if the core chooses to.
- **Probes:** the manager can issue `ProbeBlock` / `ProbePerm` with `toN`, `toB` or `toT` on B, and takes `ProbeAck` / `ProbeAckData` on C (dirty data updates memory). They are used from M2 on:
  - **coherent instruction fetch:** an `l1i` `Get` of a line the agent holds with T is held back while the manager probes that line to `toB`, so the fetch sees dirty data (self-modifying code, `rv64ui-p-fence_i`; the L2 does the same later, plan §5.2). The core needs no write-back on FENCE.I;
  - `--probe-rate=<permille>` sends random `ProbeBlock`s to lines the agent holds (stress mode, default off). `ProbePerm` is never sent at random: it lets the agent drop dirty data;
  - a Grant for a line with a probe outstanding waits for the ProbeAck, as a real L2 would;
  - the API `l1d.probe(addr, cap)` is for later uses, for example the end-of-test flush for ACT4 signatures (§6.1).
- **Coherence monitor:** the model tracks the agent's permission per line (N, B or T) and checks the TL-C rules of interfaces.md §2.3:
  1. at most one outstanding Acquire per line;
  2. no Acquire for a line whose Release is not yet acknowledged;
  3. no Probe to a line whose Grant still awaits GrantAck (the manager's own rule, so the model obeys it);
  4. the shrink in a Release or ProbeAck matches the permission the agent holds (`TtoN` only from T, `BtoN` only from B, `ReleaseData` only from T);
  5. B and D are always eventually accepted.

**`mmio`** (channels A, D).
- `Get`, `PutFullData`, `PutPartialData` of size ≤ 3, one beat. The monitor flags a second request from the same hart while one is in flight (interfaces.md §2.4).
- **Devices** (addresses from `tg_map_pkg`):

  | Device | Base | Model |
  |---|---|---|
  | UART | `UART_BASE` | 16550 subset, byte registers: THR (0) prints to the console; LSR (5) reads `0x60` (transmitter empty); the other registers read back what was written; DLAB is honoured for DLL/DLM |
  | CLINT | `ACLINT_BASE` | CLINT layout: `msip[h]` at `+0x0000 + 4h`, `mtimecmp[h]` at `+0x4000 + 8h`, `mtime` at `+0xBFF8`. Drives `irq_msi_i`, `irq_mti_i` and `mtime_i`. `mtime` advances by one every `--mtime-div` cycles (default 20, which is 10 MHz at a 200 MHz core clock). |

  Other device regions read as zero and ignore writes. The PLIC is not modelled: `irq_mei_i` and `irq_sei_i` come from the random interrupt source (`--irq-rand`, §2.7) and are otherwise zero.

### 2.5 DRAM latency model

- **Latency points** (plan §2.5, D10): `--lat=native|90|120|250|<cycles>`. `native` is 30 cycles until spike S1 measures the KV260. Latency counts from the cycle a request fires to the cycle its first response beat can be offered.
- **Bandwidth:** each port returns one beat per cycle. `--bw=<beats per cycle x100>` (default 100) can throttle the l1d and l1i ports together to model a narrower memory.
- **Jitter:** `--lat-jitter=<cycles>` adds a uniform random 0..N cycles per request, which reorders responses across sources.
- **Scope:** the model stands in for the L2 and DRAM together until the SoC's L2 exists; then the same harness drives the SoC simulation top, and the latency model moves behind the L2 (the latency injector's position, plan §5.6).

### 2.6 Bare-metal conventions (interfaces.md §3)

- **Link address:** programs are linked at `0x8000_0000`; the core boots there (`boot_addr_i`, `--boot` to change).
- **Console:** the 16550 THR at `UART_BASE`. `tests/bench/bsp` has the start-up code and newlib stubs.
- **Exit:** a riscv-tests-style write to the 8-byte `tohost` symbol, seen in the commit trace as a retired store (`mem_st`) whose `mem_vaddr` is `tohost` (or one of its aliases, below):
  - value bit 0 set: the program exits with code `value >> 1`; 0 is a pass;
  - value with device 1, command 1 (`0x0101 << 48 | c`): character `c` for the console; the harness prints it. It cannot clear `tohost` behind a cached line, so a program that waits for that is stopped as a failure with the text printed so far;
  - any other value is a failure (`unexpected tohost value`).
- **Aliases:** under virtual memory `tohost` may be stored through another virtual address. `--tohost-va=<addr>` adds an alias; the riscv-tests runner adds the `-v` environment's kernel alias (`tohost - 0x8000_0000 - 2 MiB`, sign-extended).
- **Markers:** a retired store to the `tg_marker` symbol records the cycle and retired-instruction count: value 1 starts the region of interest, 2 ends it. The run summary prints the region's cycles, instructions and IPC; the benchmark runners compute CoreMark/MHz and DMIPS/MHz from them.

### 2.7 Run control

| Option | Default | Meaning |
|---|---|---|
| `--cycles=N` | 50 M | cycle limit; reaching it is a failure (`TIMEOUT cycles`) |
| `--timeout=S` | 3600 | wall-clock limit in seconds; also a failure |
| `--hang=N` | 100 000 | no trace record on any hart for N cycles is a failure (`HANG`) |
| `--wb-timeout=N` | 100 000 | a deferred writeback pending for N cycles after its retirement is a mismatch |
| `--wb-drain=N` | 2 000 | after the exit store, how long to wait for pending deferred writebacks |
| `--fst=<file>` | off | FST waveform; `--fst-from=<cycle>` / `--fst-to=<cycle>` bound it |
| `--log=<file>` | off | text commit log: one line per trace record or writeback, with disassembly |
| `--lockstep` / `--no-lockstep` | on | Spike lockstep (§3) |
| `--isa=<str>`, `--priv=<str>` | per configuration (§3.2) | Spike's ISA and privilege modes |
| `--seed=N` | 1 | seeds every random choice in the models; printed at start |
| `--irq-rand=<permille>` | 0 | random level pulses on `irq_mei_i` / `irq_sei_i` (tests interrupt entry in lockstep) |
| `--rand-reset` | off | Verilator random initial values for un-reset state (`+verilator+rand+reset+2`) |
| `--quiet` | off | no banner or human-readable summary on stderr; the console and the `TG-RESULT` line still go to stdout |
| `+<plusarg>` | | passed to the Verilated model (for example `+tcore_defer=50`) |
| memory and devices | | `--lat`, `--lat-jitter`, `--bp`, `--d-gap`, `--grant-b`, `--probe-rate`, `--mmio-lat`, `--deny`, `--mem-mb`, `--rom`, `--boot`, `--tohost-va`, `--mtime-div` (§2.4–§2.6) |
| lockstep | | `--harts`, `--history`, `--pmp`, `--pmp-g`, `--pmp-reset` (§3.2) |

**Exit status:** 0 for a pass; 1 for a program failure (non-zero `tohost` code); 2 for a lockstep mismatch; 3 for a protocol-monitor error; 4 for a cycle or wall-clock timeout or a hang; 5 for a harness or usage error. The last line of every run is a one-line summary that runners parse:

```
TG-RESULT status=PASS code=0 cycles=123456 instret=98765 ipc=0.800 khz=21.3 region_cycles=... region_instret=...
```

### 2.8 Fork-based snapshots (M3)

- `--snap-every=N` forks the process every N cycles. The child is a frozen copy of the whole simulation (model, memories, Spike) and waits on a pipe; the parent keeps the newest `--snap-keep` (default 2) and kills older ones.
- On a failure, the parent wakes the newest snapshot taken before the failure cycle. It re-runs from there with `--fst` enabled up to the failure cycle and writes `<run>/snap_<cycle>.fst`. The waveform covers only the window that matters, so a multi-hour run does not need a multi-gigabyte FST.
- **Limits:** fork copies are copy-on-write, so memory grows only with what changes; the snapshot count is bounded for that reason. Open files (logs) are reopened by the child.

## 3. Lockstep checker

### 3.1 Spike as a library

- **Spike** is linked as a library (`libriscv`, pinned in `tools/versions.sh`), one `processor_t` per hart, with commit logging on (`enable_log_commits`). Commit logging turns off Spike's TLB caching, so every register write and memory access of a step is visible in `log_reg_write` and `log_mem_write`.
- **Our own `simif_t`** (`spike_env`), not Spike's `sim_t`: no HTIF, no Spike devices, no device tree. It provides:
  - DRAM as one host mapping (`mmap`, `MAP_NORESERVE`), so Spike's memory accesses stay fast;
  - the boot ROM as read- and fetch-only memory (stores fault);
  - device regions of `tg_map_pkg`: loads return zero (the value is adopted from the RTL, §3.4) and stores are discarded; fetch from them faults;
  - unmapped addresses (`PMA_NONE`): access faults;
  - LR, SC and AMOs to anything but DRAM: access faults, as in interfaces.md §2.4. Spike would perform an AMO on an MMIO address as a read and a write, so the checker marks the step as an AMO step and the environment refuses the access.

### 3.2 Configuration

| Setting | Default | Note |
|---|---|---|
| ISA | `--isa`, default per configuration and milestone, see below | The string must describe the core exactly: `misa` is compared |
| Privilege modes | `MSU` (`MU` for `tg_tcore`) | |
| Harts | the core's `NUM_THREADS`, hart IDs `CORE_ID * NUM_THREADS + tid` | `--harts` overrides |
| PMP | 16 regions, granularity 4 bytes (`tg_tcore`: none) | `--pmp=N`, `--pmp-g=N`. With 0 regions the PMP CSRs do not exist in Spike: accessing them is an illegal instruction. |
| MMU | Sv39 when the privilege modes include S | Spike normally takes it from a device tree; the checker sets it and resets the hart, because `mstatus.SUM`/`MXR` writability depends on it. |
| PMP reset | Spike's (entry 0 = NAPOT, RWX, whole space) | `--pmp-reset=off` zeroes `pmpcfg0` and `pmpaddr0` after reset to match a core that resets them; to be settled with the core track |
| Triggers | 0 (no Sdtrig until the debug module, M9) | |
| Misaligned accesses | trap (no `Zicclsm`) | plan §4.1: emulated by OpenSBI at first |
| WFI | a no-op in Spike | the RTL decides what follows: the next record, or a `TR_IRQ` |
| Reset PC | `--boot` (default `0x8000_0000`) | |

**ISA strings** (`sim/cfg/<cfg>.mk`, overridable):
- M2 (core alpha): `rv64im_zicsr_zifencei`, privilege `M`. The core track widens it as features land.
- M3 and later (plan §4.1, day one): `rv64imafdc_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs`, privilege `MSU`.
- `tg_tcore`: `rv64im_zicsr_zifencei_zicntr`, privilege `MU`.

### 3.3 Per-record algorithm

Records are processed in the order interfaces.md §5 guarantees: per hart in program order; within a cycle by slot. Each record steps only its own hart's Spike.

**Before every step** the checker clears Spike's commit log, then checks:
- the hart index is known;
- Spike's `pc` equals `pc`;
- Spike's privilege mode equals `priv`;
- for `TR_RETIRE` and `TR_TRAP`: the instruction bits Spike fetches at `pc` equal `insn` (16 bits when `rvc`); `rvc` agrees with the encoding.

**`TR_RETIRE`:** `step(1)`; then
- Spike must not have trapped. A trap is recognised by the cause and EPC CSR writes it logs (`mcause`+`mepc`, or `scause`+`sepc`); no single instruction writes both.
- **Destination:** Spike's logged integer or FP register write (x0 excluded) must match `rd_we`, `rd_fp` and `rd`. If `rd_deferred` is 0, `rd_value` must equal Spike's value (FP: the 64-bit register, NaN-boxed for single precision). If it is 1, see §3.5.
- **Stores:** Spike's logged memory writes must match `mem_st`, `mem_vaddr`, `mem_size` and `mem_wdata` (masked to the size). A store, SC or AMO logs exactly one write; a failed SC logs none.
- CSR writes in Spike's log are not compared: they are not in the trace, and their effects are checked when software reads them.

**`TR_TRAP`:** `step(1)`; Spike must have trapped, with the same cause (`mcause` or `scause`, whichever the trap wrote) and the same `tval` (`mtval` or `stval`). The privilege mode and PC after the trap are checked by the next record.

**`TR_IRQ`:** interfaces.md §5: the interrupt `cause` is taken before the instruction at `pc`.
- Spike never takes an external interrupt by itself: the checker owns `MEIP`, `MTIP`, `MSIP` and the external part of `SEIP` (and `STIP` while Sstc drives it in the RTL), which stay 0 in Spike.
- For a `TR_IRQ`, the checker sets the cause's `mip` bit, `step(1)`s (Spike takes the highest-priority pending and enabled interrupt and executes no instruction), then restores the bit to its previous value.
- Spike must have taken an interrupt with exactly `cause`, with EPC = `pc`. If Spike's interrupt is not enabled (`mie`, `mstatus.MIE`, `mideleg`), Spike executes the instruction instead and the mismatch is reported.
- **The other direction:** if Spike would take a software-pending interrupt (`SSIP`, `STIP` without Sstc, a software `SEIP`) at a boundary where the RTL retired an instruction, the step shows a trap with the interrupt bit set and the mismatch is reported.

### 3.4 Legal differences (adopted, not compared)

| Case | Rule |
|---|---|
| `mmio_ld = 1` | After the step, Spike's destination register is overwritten with `rd_value`. |
| `nondet = 1` | Same, but only for reads of a CSR on the checker's list: `cycle`, `mcycle`, `time`, `hpmcounter3–31`, `mhpmcounter3–31`, `mip`, `sip`, `mvendorid`, `marchid`, `mimpid`. `nondet` on any other instruction is a mismatch (`nondet not allowed`). The checker also adopts reads of listed CSRs whose record has `nondet = 0`. `instret` and `minstret` are compared. |
| SC failure | The RTL may fail an SC that Spike would let succeed. If the record is an SC with `rd_value != 0` and no `mem_st`, the checker clears Spike's reservation before the step, so Spike fails it too. An SC that succeeds in the RTL but not in Spike is a mismatch. |
| `fflags`, `fcsr` | Never compared per instruction; reads compare normally. |
| `TR_IRQ` | §3.3. |
| WFI | §3.2. |

Not adopted and so reported, by design: a load value from main memory that differs from Spike's (single hart); a page-table or code modification that Spike sees before an `SFENCE.VMA` or `FENCE.I` (Spike, with commit logging, has no TLB or I-cache; software that relies on stale translations or stale code is outside lockstep).

`mmio_ld` or `nondet` together with `rd_deferred` is a protocol error: the checker must adopt the value before younger instructions read it.

### 3.5 Deferred writebacks

- At a `TR_RETIRE` with `rd_deferred = 1`, the checker records Spike's value under `(hart, wb_tag)`, together with `rd`, `rd_fp`, `pc` and `insn`. Spike's register already holds the value, so younger instructions compute with it (interfaces.md §5).
- A `tr_wb_t` must match a pending `(hart, wb_tag)`, with the same `rd`, `rd_fp` and value; the entry is then freed.
- **Errors:** reusing a pending tag; a writeback with no pending tag; `rd_deferred` on a record with no destination; an entry pending longer than `--wb-timeout` cycles; entries still pending at the end of the run (`--wb-drain` cycles after the exit store).
- **Same-cycle order:** writebacks for tags pending before the cycle are applied first, then the cycle's records, then writebacks for tags those records created. A tag freed and reused in one cycle therefore works.

### 3.6 Divergence report

On the first mismatch the checker stops the run and prints:
- the mismatch: field, RTL value, Spike value;
- the last `--history` (default 32) records of the RTL for that hart, each with its cycle, and with Spike's disassembly of `insn`;
- Spike's last `--history` steps for that hart: PC, instruction, register writes, memory writes, traps;
- the pending deferred writebacks;
- the nearest ELF symbol for each PC.

### 3.7 Several harts

- **Stepping:** one Spike per hart, stepped only by that hart's records, all on one Spike memory. Records of different harts in one cycle are applied in slot order.
- **Limit (M7, M8):** a store of one hart becomes visible to the others in Spike when it retires, while in the RTL it may become visible later (store queue) and loads may be satisfied earlier. Lockstep will then report legal load-value differences on data shared between harts. The plan for M7: a per-address history of recent store values, with a load accepted (and adopted) if its value was current at some point between the load's issue and retirement, and memory-model correctness left to litmus tests and axe (plan §9). That needs the load's address in the trace; it will be requested from the coordinator then (interfaces.md §7).

### 3.8 Validating the checker

Two independent ways, both in `make regress`:

1. **Spike against Spike** (`tg_replay`): a second Spike runs the program and produces `tr_rec_t`/`tr_wb_t` records, which feed the checker exactly as the RTL's would. Options perturb the stream the way a real core legitimately would:
   - deferred writebacks for loads, DIV/REM and long FP operations, delivered 1–200 records later, out of order across tags;
   - random interrupts (`TR_IRQ`) at enabled boundaries;
   - perturbed `nondet` CSR values (written into both the record and the replaying Spike, so later results stay consistent);
   - several harts, interleaved at random;
   - and **fault injection**: one wrong field (PC, rd, value, store data, cause, a missing writeback, a reused tag) at a random record. The run passes only if the checker reports that exact fault.

   It runs every riscv-tests binary of every suite, `-p` and `-v`, through the checker in seconds. A fault the program gives no chance to inject (for example a deferred writeback in a program without loads) is reported as not applicable.
2. **The test core** (§5) runs the riscv-tests suites it supports, CoreMark and Dhrystone through the whole harness (TileLink models, trace, lockstep).

**Results on 2026-10-13** (`tools/ci/checker_selftest.py`, 9 s):
- 326 riscv-tests (all `-p` and `-v` suites of ui, um, ua, uc, uf, ud, mi, si, zba, zbb, zbs, zicond; `ma_data` excluded, §4.1) pass Spike against Spike, plain and under four perturbation sets (deferral up to 90% of results, nondet values, 2 and 4 harts, 3- and 4-record cycles);
- 19 fault kinds × 7 programs × 2 seeds, plus a wrong interrupt cause on the interrupt test: every applicable injection is reported with the expected diagnosis (270 runs; a dropped writeback is reported either at the end or as the tag reuse it causes, whichever comes first);
- the directed interrupt tests pass with random interrupts injected at enabled boundaries.

The checker found its first real bug the same day: the test core lost deferred writebacks when two deferred records left its trace queue in one cycle.

## 4. Test suites and runners

### 4.1 riscv-tests

- **Binaries:** the pinned build in `$RISCV_TESTS/isa` (`tools/versions.sh`).
- **Suites and milestones:**

  | Milestone | Suites |
  |---|---|
  | M2 | `rv64ui-p`, `rv64um-p`, `rv64mi-p` |
  | M3 | + `rv64ua-p`, `rv64uc-p`, `rv64si-p`, and every `-v` variant of those |
  | M5 | + `rv64uf-p`, `rv64ud-p` and their `-v` variants |
  | `tg_tcore` | `rv64ui-p`, `rv64um-p`, the `rv64mi-p` tests it supports |

- **Known exclusions** go in `tests/isa/exclude/<cfg>.txt` with a reason per line (for example, `rv64mi-p-breakpoint` until Sdtrig exists).
- **Command:** `make -C tests/isa CFG=<cfg> [CORE=...] [SUITES=...] [LAT=...] [SIMARGS=...]` runs each test with lockstep, at most 8 at a time, and prints a table and `N passed, M failed`; logs of failing tests stay in the log directory and passing ones are deleted. `make -C tests/isa replay SUITES=all` runs the same suites Spike against Spike. Underneath is `tests/isa/run_isa.py`, which takes any tg_vsim or tg_replay binary and arguments.
- **`-v` tests:** the runner passes the kernel alias of `tohost` (§2.6).
- **Directed tests** (ours, `tests/isa/directed/*.S`, built to `tanager-p-*`): `irq_timer` (CLINT timer and software interrupts, WFI, `mip` reads) and `irq_ext` (external interrupts from `--irq-rand` pulses). `make -C tests/isa directed CFG=<cfg>` runs them with lockstep and random external-interrupt pulses; the checker self-test runs them Spike against Spike with injected interrupts. riscv-tests never enable interrupts, so these are what exercise `TR_IRQ`.
- **Exclusions:** `exclude/tanager.txt` for every configuration (`rv64ui-*-ma_data`: needs hardware misaligned access, which Tanager traps); `exclude/tcore.txt` for the test core (`rv64mi-p-pmpaddr`: needs PMP); `exclude/<cfg>.txt` if a configuration needs one.

### 4.2 Benchmarks

- **Sources:** CoreMark and Dhrystone sources come from `perfmodel/third_party` (pinned in `perfmodel/third_party/VERSIONS.txt`; `perfmodel/scripts/fetch_deps.sh` fetches them). The ports are ours, in `tests/bench/`, following perfmodel's: CoreMark core files unmodified, flag sets A (`-O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las`) and B (`-O3 -funroll-loops`), Dhrystone with `-O3 -fno-inline` (plan §10.2).
- **Platform:** `tests/bench/bsp`: start-up code, newlib stubs (console on the UART, exit through `tohost`), link script at `0x8000_0000`, and `tg_marker` around the timed region.
- **Builds:** `MARCH=rv64im` (default: the M2 core and `tg_tcore`), `rv64gc` (the product core from M3/M5), `rv64gcb` (the extension build of plan §10.2).
- **Iterations:** small by default (CoreMark 2 iterations, Dhrystone 500 runs), because RTL simulation runs at 5–30 kHz. CoreMark still validates its CRCs. `ITER=` and `RUNS=` raise them for performance runs.
- **Determinism:** CoreMark's ticks are retired instructions and Dhrystone's `time()` counts its calls, so the console text is the same in the RTL and in Spike. Cycles come from the `tg_marker` region.
- **Results:** a run passes when lockstep passes, the program exits with code 0, its console output matches a Spike reference run of the same ELF (`tg_replay`), and CoreMark prints `Correct operation validated`. The runner prints CoreMark/MHz = iterations × 10⁶ / region cycles and DMIPS/MHz = runs × 10⁶ / (region cycles × 1757). These are not EEMBC-valid scores (run length), only correlation points for the model (plan §10.1).
- **Unexpected traps** in a benchmark end it with exit code `0x1000 + mcause` (`bsp/crt0.S`).

### 4.3 `make regress`

`make regress CFG=<cfg> [CORE=core|tcore] [LAT=...] [SUITES=...] [MARCH=...] [SELFTEST=0]` (top-level target; `tools/ci/regress.sh` takes the same `KEY=value` arguments plus `SIMARGS="..."` for extra tg_vsim options):
1. builds `tg_vsim` for the configuration and `tg_replay`;
2. runs the riscv-tests suites with lockstep (default `rv64ui-p rv64um-p rv64mi-p`, the M2 set);
3. runs the directed tests with lockstep (§4.1);
4. runs CoreMark A and B and Dhrystone with lockstep (default `MARCH=rv64im`);
5. runs the checker self-test (§3.8; `SELFTEST=0` skips it);
6. prints one summary and exits non-zero if anything failed; logs of failing steps stay in `$TANAGER_BUILD/<worktree>/regress/<cfg>-<core>/`.

The core track runs it for `st` and `st_w3` before each merge request (conventions §6), widening `SUITES` and `MARCH` as features land. It takes about as long as the slowest test, since tests run 8 at a time.

**Results on 2026-10-13 with the test core:** `REGRESS PASS` for `st`, `st_w3`, `smt2` and `smt2_w3` at native latency, and for `st_w3` at 120 and 250 cycles with deferral, multi-slot trace and random probes (about 15 s per configuration). With the stub `tg_core` every test reports `HANG`, as it should.

## 5. The test core (`tg_tcore`)

Simulation-only RTL in `sim/tcore/`, never in a product filelist. Its only job is to exercise the harness and the checker before `tg_core` exists, and to keep doing so as a reference afterwards.

- **ISA:** RV64IM, Zicsr, Zifencei, Zicntr; M and U modes; `mstatus`, `misa`, `mie`/`mip`, `mtvec` (direct and vectored), `mscratch`, `mepc`, `mcause`, `mtval`, `mhartid`, the counters, `mcounteren`, `menvcfg` and PMP registers as WARL zero, the ID registers as zero; ECALL, EBREAK, MRET, WFI; precise exceptions for illegal instructions, misaligned and faulting accesses; interrupts MEI, MSI, MTI.
- **Pipeline:** one instruction at a time (a multi-cycle state machine). Width-generic trace output: it uses slot 0 only, or spreads records over all `COMMIT_WIDTH` slots when `TRACE_SPREAD=1`.
- **Memory:** a one-line fetch buffer over `l1i` (`Get` of a line), and a small direct-mapped write-back data cache over `l1d` that acts as a real TL-C client: `AcquireBlock NtoB` / `NtoT`, `AcquirePerm BtoT` for upgrades, `GrantAck`, `Release` / `ReleaseData` on eviction, and `ProbeAck` / `ProbeAckData` to probes. Device accesses go to `mmio`.
- **Trace features**, so that every checker path runs end to end:
  - **deferred writebacks:** with `+tcore_defer=<percent>`, it reports cacheable loads and DIV/REM with `rd_deferred = 1` and sends the value on a `trace_wb` port 1–16 cycles after the record (a delay line; the core itself is not early-retiring);
  - **several records per cycle:** with `+tcore_spread=1`, records wait in a small queue and leave it 0 to `COMMIT_WIDTH` at a time;
  - `mmio_ld` on device and ROM loads, `nondet` on counter, `mip` and `marchid` reads, `TR_TRAP`, `TR_IRQ`.
- **CSRs:** exactly Spike's set for an M+U RV64IM hart without PMP or triggers (the checker found the differences).
- **Speed:** about 1.7–2.3 MHz of simulated cycles at an IPC of 0.1 (it is a multi-cycle machine), so CoreMark's two iterations take 3–12 s.
- **Results:** `rv64ui-p`, `rv64um-p` and `rv64mi-p` (82 tests), the directed interrupt tests (2,000+ interrupts per run) and CoreMark A/B and Dhrystone pass in lockstep at 30, 120 and 250 cycles, also with jitter, backpressure, D-channel gaps, `toB` grants, random probes (CoreMark: about 100 K Acquires, 5 K Releases with data, 280 K probes), deferral and multi-slot trace.

## 6. M3 items

### 6.1 riscv-arch-test (ACT4) with Sail

- **Flow:** `tests/arch/` builds the ACT4 tests from `~/src/tanager/riscv-arch-test` (act4 branch, pinned) for a Tanager DUT configuration, with Sail as the reference model. Each test runs in `tg_vsim` with lockstep. The signature region is then dumped from the harness's view of memory, after the run's final cache flush (a probe sweep of the l1d), and compared with Sail's signature.
- **Sail:** the prebuilt release of the RISC-V Sail model (`sail_riscv_sim`), installed under `$TANAGER_OPT/sail` with its version recorded in `tools/versions.sh` (reported to the coordinator when downloaded).

### 6.2 Constrained-random instruction generator

`tests/random/` (plan §9, §4.15). A Python generator writes assembly programs that run in the bare-metal environment and in lockstep:
- **Seeded:** every program prints its seed and is reproducible from it (conventions §6).
- **Templates:** weighted streams of instruction classes, aimed at the plan's risk areas:
  - LSU: same-line and same-address load and store mixes; partial overlaps for forwarding; aliasing across pages; misaligned accesses that must trap;
  - ordering: loads that pass older stores to the same address; FENCE variants; LR/SC loops; AMOs;
  - early retirement: long-latency loads (cache-missing strides) and DIV/REM followed by branch mispredictions, traps and interrupts while they are pending ("flush storms over pending retired loads");
  - width 3: groups of 3 instructions with intra-group dependencies (RAW, WAW, WAR) and two branches per group, aligned to 16-byte fetch blocks so they decode in one cycle.
- **Shape:** a memory region of a few pages per program, so misses and evictions happen at small size; traps return through a handler that skips the faulting instruction.
- **Driver:** `make -C tests/random CFG=... N=100 SEED=...` generates, builds and runs N programs, keeping only the failures.

### 6.3 Snapshots

§2.8.

## 7. Build-host notes

- **liblz4-dev** is not installed on the build host, and Verilator 5.052's FST writer includes `lz4.h`. `sim/src/compat/lz4.h` declares the two functions it uses and the build links the installed runtime (`liblz4.so.1`) through a symlink in the build tree. Installing `liblz4-dev` makes the shim unused (the Makefile checks for `/usr/include/lz4.h`).
- **Spike** is used through its installed headers and `libriscv.so` (`$SPIKE_ROOT`); the build adds `-Wl,-rpath` so no `LD_LIBRARY_PATH` is needed.

## 8. Disk and machine sharing

- Builds use at most `-j8` (conventions §9). Test runners run at most 8 simulations at a time.
- The verification build tree has a 5 GB budget: one `tg_vsim` build is about 50–300 MB depending on the core. Runners delete the logs of passing tests; waveforms are only produced on request and are deleted once a bug is understood.

## 9. Open points for the coordinator

1. **Trace:** a load's address is not in `tr_rec_t`. It is needed for multi-hart lockstep (§3.7) at M7; requested then.
2. **Physical store address:** `tohost` detection under virtual memory uses aliases (§2.6). A `mem_paddr` field would remove the aliases; not needed now.
3. **PMP reset values:** Spike resets PMP entry 0 to "allow all"; the checker can patch it (§3.2) once the core track decides its reset values.
4. **SC failure adoption** (§3.4) is a legal difference that interfaces.md §5 does not list yet.
5. **ID CSRs:** `marchid`, `mimpid` and `mvendorid` reads are adopted (§3.4); the core track should still pick Tanager's values.
6. **Illegal-instruction `tval`:** Spike writes the instruction bits (16 bits for a compressed encoding without C), `ebreak` writes the PC; the core must do the same or the checker reports it.

## 10. Provenance

- TileLink message rules: TileLink Specification 1.8.1 (SiFive, public).
- The `tohost`/`fromhost` convention and the riscv-tests environment: riscv-tests (public test suite, used as-is).
- Spike's library interface (`simif_t`, `processor_t`, commit log): Spike's public headers and sources, used as a tool, not as a design reference.
- Fork-based snapshots: a common simulation technique; described here from first principles.
- No other core's RTL or testbench was read for any of this.
