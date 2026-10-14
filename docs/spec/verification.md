# Verification infrastructure: harness, lockstep, runners

**Status:** implemented for M2 (§1–§5) and the M3 items (§6), 2026-10-13. Owner: verification track (conventions §7). Implements plan §9.

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
| riscv-arch-test ACT4 flow with Sail: configurations for the test core, the M2 core and the M3 core | `tests/arch/` | M3, done |
| Constrained-random instruction generator | `tests/random/` | M3, done |
| Fork-based snapshots | `sim/` (`--snap-every`) | M3, done |

## 1. Quick start

```bash
source tools/env.sh
make -C sim CFG=st                     # builds tg_vsim for tg_core, configuration st
make -C sim CFG=st CORE=tcore          # the same harness around the test core
sim/run.sh CFG=st prog.elf             # build if needed, then run one ELF with lockstep (the default)
make -C tests/isa CFG=st SUITES="rv64ui-p rv64um-p"   # riscv-tests, pass/fail summary
make -C tests/bench CFG=st run         # CoreMark (flag sets A and B) and Dhrystone
make regress CFG=st                    # everything above for one configuration
make -C tests/arch CFG=st CORE=tcore   # riscv-arch-test (ACT4): self-checking tests from Sail, run with lockstep
```

- **Build trees:** `$TANAGER_BUILD/<worktree>/sim/<cfg>-<core>/tg_vsim`, `.../sim/replay/tg_replay`, `.../bench/<march>-i<iter>-r<runs>/`, `.../arch/<config>/`, logs under `.../regress/`, `.../isa-logs/` and `.../arch/logs/` (conventions §1). Nothing is written into the repository; passing tests leave no logs.
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
- **Architecture tests:** `make -C tests/arch CFG=st` runs the M2 configuration's ACT4 tests on `tg_core` (§6.1): 113 tests, plus 16 PMP tests excluded until PMP checks arrive in M3. `ACTCFG=core-m3-rv64imac` runs the M3 configuration once the core has the M3 ISA. Each test checks itself against Sail's results and runs in lockstep.
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
  | Interrupt generator | `0x0C00_0004` (in the PLIC's region) | The register of Sail's "simple interrupt generator", which ACT4's interrupt tests use (§6.1). A 32-bit write with bit 31 set raises the lines named by the other set bits; without bit 31 it lowers them. Bit 11 drives `irq_mei_i`, bit 9 `irq_sei_i`, bit 1 `irq_ssi_i`, for every hart. Reads return zero. |

  Other device regions read as zero and ignore writes. The PLIC itself is not modelled (the SoC's PLIC is the soc track's): `irq_mei_i` and `irq_sei_i` come from the interrupt generator and from the random interrupt source (`--irq-rand`, §2.7).

### 2.5 DRAM latency model

- **Latency points** (plan §2.5, D10): `--lat=native|90|120|250|<cycles>`. `native` is 30 cycles until spike S1 measures the KV260. Latency counts from the cycle a request fires to the cycle its first response beat can be offered.
- **Bandwidth:** each port returns one beat per cycle. `--bw=<beats per cycle x100>` (default 100) can throttle the l1d and l1i ports together to model a narrower memory.
- **Jitter:** `--lat-jitter=<cycles>` adds a uniform random 0..N cycles per request, which reorders responses across sources.
- **Scope:** the model stands in for the L2 and DRAM together until the SoC's L2 exists; then the same harness drives the SoC simulation top, and the latency model moves behind the L2 (the latency injector's position, plan §5.6).

### 2.6 Bare-metal conventions (interfaces.md §3)

- **Link address:** programs are linked at `0x8000_0000`; the core boots there (`boot_addr_i`, `--boot` to change).
- **Console:** the 16550 THR at `UART_BASE`. `tests/bench/bsp` has the start-up code and newlib stubs.
- **Exit:** a riscv-tests-style write to the 8-byte `tohost` symbol, seen in the commit trace as retired stores (`mem_st`) to `tohost` (or one of its aliases, below). The harness keeps a copy of the 8 bytes; a command is complete when a store reaches the top byte, so one 64-bit store and the two 32-bit stores of riscv-tests and ACT4 (`sw value, tohost; sw high, tohost+4`) both work:
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
| `--trace-stall=<permille>`, `--trace-fifo=N` | off | drive `trace_stall_i` from a model of the trace sink (§2.9) |
| `--rand-reset` | off | Verilator random initial values for un-reset state (`+verilator+rand+reset+2`) |
| `--quiet` | off | no banner or human-readable summary on stderr; the console and the `TG-RESULT` line still go to stdout |
| `+<plusarg>` | | passed to the Verilated model (for example `+tcore_defer=50`) |
| memory and devices | | `--lat`, `--lat-jitter`, `--bp`, `--d-gap`, `--grant-b`, `--probe-rate`, `--mmio-lat`, `--deny`, `--mem-mb`, `--rom`, `--boot`, `--tohost-va`, `--mtime-div` (§2.4–§2.6) |
| lockstep | | `--harts`, `--history`, `--pmp`, `--pmp-g`, `--pmp-reset` (§3.2) |

**Exit status:** 0 for a pass; 1 for a program failure (non-zero `tohost` code); 2 for a lockstep mismatch; 3 for a protocol-monitor error; 4 for a cycle or wall-clock timeout or a hang; 5 for a harness or usage error. The last line of every run is a one-line summary that runners parse:

```
TG-RESULT status=PASS code=0 cycles=123456 instret=98765 ipc=0.800 khz=21.3 region_cycles=... region_instret=...
```

### 2.8 Fork-based snapshots

`--snap-every=N [--snap-keep=K] [--snap-fst=FILE] [--snap-margin=M]` (implemented 2026-10-13):
- **Taking:** every N cycles the run forks. The child is a frozen copy of the whole simulation (model, harness memories and models, the checker's Spike, every random generator) blocked on a pipe. The newest K (default 2) are kept; older ones are discarded by closing their pipe, and they exit.
- **Using:** when the run fails (any non-pass status), the newest snapshot is woken with the failure cycle. It replays from its own cycle with the waveform on, writes `FILE` (default `snap.fst`) up to M cycles (default 16) past the failure, and logs its run to `FILE.log`; the replay is deterministic, so it fails at the same cycle with the same report. The parent waits for it and prints where the waveform is.
- **So** a long run (a Linux boot) needs no multi-gigabyte waveform: rerun it with `--snap-every` and get just the last window. Choose N so that a window of N cycles is a reasonable FST (about 20 KB per 1,000 cycles with the test core).
- **Cost:** a fork copies page tables only; pages are copied when written. A CoreMark run with 34 snapshots ran 1% slower and stayed at 10 MB resident.
- **Details:** the Verilated context runs with one thread (`threads(1)`): only the forking thread survives a fork, and a trace thread pool would hang the replay. Snapshots die with the run (`PR_SET_PDEATHSIG`). `--snap-every` and `--fst` are exclusive.

### 2.9 Trace back-pressure (`trace_stall_i`)

interfaces.md v1.3 §5: while `trace_stall_i` is high the core retires nothing, after one cycle of latency; deferred writebacks keep flowing; a sink stalls the core when its free space is below `TRACE_STALL_HEADROOM`.
- **The sink model** (`sim/src/trace_sink.h`): with `--trace-stall=<permille>` the harness drives the input the way the FPGA trace streamer will. Records and writebacks go into a FIFO of `--trace-fifo` entries (default: the threshold plus `COMMIT_WIDTH`). It drains 0 to `COMMIT_WIDTH + TRACE_WB_PORTS` entries per cycle at random and, with the given chance per cycle, stops draining for 1–64 cycles. The core is stalled while the free space is below `TRACE_STALL_HEADROOM + COMMIT_WIDTH` (the extra `COMMIT_WIDTH` is explained below). Without the option the input stays 0. The run summary gives the stalled cycles, the number of stalls and the FIFO's peak.
- **Checks**, on every run; a failure is a `PROTOCOL` error:
  1. no `TR_RETIRE`, `TR_TRAP` or `TR_IRQ` record in a cycle when the input has been high in that cycle and the two before it (the core may still retire in the cycle the input rises and in the next one);
  2. the deferred records whose writeback has not arrived never number more than `LLT_ENTRIES`.

  A record lost or reordered at a stall shows up in lockstep as a PC mismatch, because each record must be Spike's next instruction. Within 64 cycles of a stall, the mismatch line says so ("a record lost or reordered at a stall?"). While checks 1 and 2 hold, the FIFO cannot overflow; the summary still counts overflows.
- **Headroom and the sink's timing:** `TRACE_STALL_HEADROOM` = 2 × `COMMIT_WIDTH` + `LLT_ENTRIES` is exactly enough for a sink that computes the stall from its free space *after* the current cycle's records. That is a combinational path from `trace_valid_o` to `trace_stall_i`, which the core's input register makes safe. A sink that stalls from its occupancy register sees a cycle's records only at the next clock edge, so one more cycle of records can arrive: it needs 3 × `COMMIT_WIDTH` + `LLT_ENTRIES`. The harness's model is of that kind (its inputs are registers, §2.2) and uses the larger threshold (§9).
- **Which builds have the port:** builds that define `TG_TRACE_STALL` connect it. The test core always has it. `tg_core` gets it with `make -C sim TRACE_STALL=1` until its port is on main, and by default after that. `make -C sim print-trace-stall CORE=...` prints 1 for a build that has it; `--trace-stall` on a build without it is an error.
- **The test core:** the stall holds its trace queue, so commit stops once the queue is full, while deferred writebacks keep flowing. Two knobs prove that the checks work: `+tcore_stall_lat=0|1|2` adds reaction latency (default 1, the interface's allowance), and `+tcore_stall_bug=1` drops the head record when a stall starts. With latency 2 the run fails with check 1's error at the third stalled cycle; the dropped record fails lockstep with the hint.
- **Where it runs:** for cores with the port, `make regress` runs the riscv-tests and the directed interrupt tests a second time with `--trace-stall=50`. A third of the stressed random seeds also draw `--trace-stall` (10, 50 or 200).
- **Results on 2026-10-13 with the test core:** CoreMark with `--trace-stall=50 +tcore_spread=1 +tcore_defer=60` passes in lockstep through 82,759 stalls (2.2 M stalled cycles). `make regress` passes in `st` and `st_w3` with the back-pressure step.

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

**ISA strings** (defaults per core in `sim/Makefile`; `make -C sim ISA=... PRIV=... PMP=...` or `--isa`, `--priv`, `--pmp` per run):
- M2 (core alpha): `rv64im_zicsr_zicntr_zifencei`, privilege `M`, 16 PMP regions. The core track widens it as features land.
- M3 (plan §4.1, day one, until the FPU joins at M5): `rv64imac_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs`, privilege `MSU`, 16 PMP regions. This is the ACT4 configuration `core-m3-rv64imac` (§6.1).
- M5 and later: the same with `f` and `d` (`rv64imafdc_...`).
- `tg_tcore`: `rv64im_zicsr_zicntr_zifencei`, privilege `MU`, no PMP.

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

   **Platform:** the replaying Spike sees the devices of §2.4: the UART (its output is the console), a CLINT whose `mtime` advances once per `--mtime-div` retired instructions (Spike's `time` CSR follows it, and so does Sstc's `stimecmp` comparison), and the interrupt generator. `MTIP`, `MSIP` and `MEIP` follow the device levels; `SEIP` and `SSIP`, which software may also write, are set or cleared only when the generator's line changes, as Sail and Spike's own PLIC do. Interrupts the replaying Spike takes become `TR_IRQ` records. Loads from device regions are marked `mmio_ld` when the access is untranslated (M-mode without MPRV, or satp Bare). `--isa`, `--priv` and `--pmp` configure both Spikes. ACT4 uses this to check its configurations (§6.1).
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

`make regress CFG=<cfg> [CORE=core|tcore] [LAT=...] [SUITES=...] [MARCH=...] [SELFTEST=0]` (top-level target; `tools/ci/regress.sh` takes the same `KEY=value` arguments plus `SIMARGS="..."` for extra tg_vsim options, and `ARCH=1 [ACTCFG=...]` for ACT4):
1. builds `tg_vsim` for the configuration and `tg_replay`;
2. runs the riscv-tests suites with lockstep (default `rv64ui-p rv64um-p rv64mi-p`, the M2 set);
3. runs the directed tests with lockstep (§4.1);
4. runs CoreMark A and B and Dhrystone with lockstep (default `MARCH=rv64im`);
5. runs 100 constrained-random programs with memory stress (§6.2; `RANDN=N`, 0 skips them);
6. with `ARCH=1`, runs the core's ACT4 configuration (§6.1: `tcore-rv64im` or `core-m2-rv64im`, or `ACTCFG=`); off by default until the coordinator makes it part of the core's merge gate (§9);
7. runs the checker self-test (§3.8; `SELFTEST=0` skips it);
8. prints one summary and exits non-zero if anything failed; logs of failing steps stay in `$TANAGER_BUILD/<worktree>/regress/<cfg>-<core>/`.

The core track runs it for `st` and `st_w3` before each merge request (conventions §6), widening `SUITES` and `MARCH` as features land. It takes about as long as the slowest test, since tests run 8 at a time.

**Results on 2026-10-13 with the test core:** `REGRESS PASS` for `st`, `st_w3`, `smt2` and `smt2_w3` at native latency, and for `st_w3` at 120 and 250 cycles with deferral, multi-slot trace and random probes (about 15 s per configuration). With the stub `tg_core` every test reports `HANG`, as it should.

## 5. The test core (`tg_tcore`)

Simulation-only RTL in `sim/tcore/`, never in a product filelist. Its only job is to exercise the harness and the checker before `tg_core` exists, and to keep doing so as a reference afterwards.

- **ISA:** RV64IM, Zicsr, Zifencei, Zicntr; M and U modes; `mstatus`, `misa`, `mie`/`mip`, `mtvec` (direct and vectored), `mscratch`, `mepc`, `mcause`, `mtval`, `mhartid`, the counters, `mcounteren`, `menvcfg` and PMP registers as WARL zero, the ID registers as zero; ECALL, EBREAK, MRET, WFI; precise exceptions for illegal instructions, misaligned and faulting accesses; interrupts MEI, MSI, MTI.
- **Pipeline:** one instruction at a time (a multi-cycle state machine). Width-generic trace output: it uses slot 0 only, or spreads records over all `COMMIT_WIDTH` slots when `TRACE_SPREAD=1`.
- **Memory:** a one-line fetch buffer over `l1i` (`Get` of a line), and a small direct-mapped write-back data cache over `l1d` that acts as a real TL-C client: `AcquireBlock NtoB` / `NtoT`, `AcquirePerm BtoT` for upgrades, `GrantAck`, `Release` / `ReleaseData` on eviction, and `ProbeAck` / `ProbeAckData` to probes. Device accesses go to `mmio`.
- **Trace back-pressure:** `trace_stall_i` (when built with `TG_TRACE_STALL`, §2.9) holds the trace queue; `+tcore_stall_lat` and `+tcore_stall_bug` test the harness's checks.
- **Trace features**, so that every checker path runs end to end:
  - **deferred writebacks:** with `+tcore_defer=<percent>`, it reports cacheable loads and DIV/REM with `rd_deferred = 1` and sends the value on a `trace_wb` port 1–16 cycles after the record (a delay line; the core itself is not early-retiring);
  - **several records per cycle:** with `+tcore_spread=1`, records wait in a small queue and leave it 0 to `COMMIT_WIDTH` at a time;
  - `mmio_ld` on device and ROM loads, `nondet` on counter, `mip` and `marchid` reads, `TR_TRAP`, `TR_IRQ`.
- **CSRs:** exactly Spike's set for an M+U RV64IM hart without PMP or triggers (the checker found the differences).
- **Speed:** about 1.7–2.3 MHz of simulated cycles at an IPC of 0.1 (it is a multi-cycle machine), so CoreMark's two iterations take 3–12 s.
- **Results:** `rv64ui-p`, `rv64um-p` and `rv64mi-p` (82 tests), the directed interrupt tests (2,000+ interrupts per run) and CoreMark A/B and Dhrystone pass in lockstep at 30, 120 and 250 cycles, also with jitter, backpressure, D-channel gaps, `toB` grants, random probes (CoreMark: about 100 K Acquires, 5 K Releases with data, 280 K probes), deferral and multi-slot trace.

## 6. M3 items

### 6.1 riscv-arch-test (ACT4) with Sail

**Status (2026-10-13):** implemented. Three configurations; all their tests pass Spike against Spike, and the test core passes its configuration in `tg_vsim` with lockstep.

**How ACT4 works** (act4 branch, pinned in `tools/versions.sh`): the framework selects the tests that apply to a DUT from its UDB configuration, compiles them, runs them on Sail to compute the expected results, and compiles those results into self-checking ELFs. The DUT only runs each ELF: the test prints `RVCP-SUMMARY: TEST PASSED|FAILED` and halts through `RVMODEL_HALT_PASS|FAIL`. In the Sail runs the framework's own macros (`tests/env/sail_macros.h`) replace the DUT's, so the DUT's macros only need to have the same architectural effect.

**Commands** (after `source tools/env.sh`):

```bash
make -C tests/arch CFG=st CORE=tcore                     # ACTCFG=tcore-rv64im: build the ELFs, run them in tg_vsim
make -C tests/arch CFG=st                                # CORE=core, ACTCFG=core-m2-rv64im
make -C tests/arch CFG=st ACTCFG=core-m3-rv64imac        # once tg_core has the M3 ISA
make -C tests/arch replay ACTCFG=core-m3-rv64imac        # the same ELFs, Spike against Spike (tg_replay)
make -C tests/arch elfs ACTCFG=...                       # only generate and build the ELFs
make -C tests/arch clean
```

- **Steps:** `elfs` copies the framework's `tests/env` and committed privileged tests into the build tree, runs `testgen` for the suites on the `# testgen:` line of the configuration's `test_config.yaml` (the generated tests are not committed upstream), runs `act` (UDB validation, test selection, Sail, compilation; `--fast --clean-intermediates`) and deletes the sources again, keeping only the ELFs; `make -C tests/arch tests ACTCFG=...` regenerates the sources for debugging. `run` runs every ELF in `tg_vsim` with lockstep, 8 at a time (`tests/arch/run_arch.py`). The riscv-arch-test checkout is only read.
- **A pass** needs the test's own `RVCP-SUMMARY: TEST PASSED` and a passing run (lockstep and the `tohost` exit). The runner prints a table per suite; failing tests keep their logs in `$TANAGER_BUILD/<worktree>/arch/logs/<config>-<cfg>-<core>/`. `SIMARGS="..."` adds `tg_vsim` options (latency, stress); `exclude/<config>.txt` lists skipped tests with a reason each (all empty today).
- **`replay`** runs the same ELFs in `tg_replay` (§3.8) with the Spike options on the `# replay:` line. Spike configured like the core must reproduce Sail's expected values, and the lockstep checker must pass, so this checks the configuration files themselves: every WARL choice in `sail.json` equals Spike's, and the core has to match Spike anyway.
- **Rebuilds:** the ELFs are rebuilt when any file of the configuration, the link script or the shared macros change. Generation and Sail take about 25 s for the M3 configuration; the M3 replay takes 9 s.

**Configurations** (`tests/arch/config/`):

| Configuration | For | Spike ISA, modes, PMP | Tests |
|---|---|---|---|
| `tcore-rv64im` | `tg_tcore` (§5) | `rv64im_zicsr_zicntr_zifencei`, MU, none | 97: I, M, Zmmul, Zicntr, Zicsr, Zifencei, ExceptionsSm, InterruptsSm, ExceptionsU |
| `core-m2-rv64im` | `tg_core` at M2 | the same, M, 16 | 129: the same without U (7 InterruptsSm tests instead of 14), plus PMPSm (40), of which 16 need PMP checks and are excluded until M3 |
| `core-m3-rv64imac` | `tg_core` at M3 (no F/D until M5) | §3.2's M3 string, MSU, 16 | 355: the above plus Zaamo, Zalrsc, Zca, Zba, Zbb, Zbs, Zicond, Zihintpause, Zihpm; ExceptionsS, U, Zaamo, Zalrsc, Zc and the ExceptionsSv suites; InterruptsS (11) and InterruptsSm (21); PMPS, PMPU, PMPZaamo, PMPZalrsc, PMPZca; Sv, SvPMP, SvSm, Svade, Svbare, Svinval |

Each directory holds `test_config.yaml` (tools, the `# testgen:` and `# replay:` lines), the UDB file `<config>.yaml` (validated by `udb validate cfg`; it decides which tests apply), `sail.json`, and `rvmodel_macros.h`, which includes the shared `tanager_rvmodel.h`. The shared `link.ld` places RAM at `0x8000_0000` (256 MiB, the main-memory region of every `sail.json`).

**`sail.json`** is generated by `make_sail.py` (run it with the ACT venv's Python; never edit the output). It starts from the framework's `sail-RVA20S64` reference and overrides, per configuration:
- the memory map of `tg_map_pkg`: the device regions (ACLINT, PLIC, UART, host control, virtio, debug) as I/O without AMOs or reservations, and DRAM; Sail keeps its own boot ROM at `0x1000`, which the tests never touch;
- the extensions, and the misa bits software may clear (Spike's write mask: M, A, B, C within the ISA; the M2 core makes only M writable since it has no A, B or C);
- the WARL choices that must equal Spike's: `mcountinhibit`, `mcounteren`, `scounteren` writable bits (CY, IR, and the HPM bits with Zihpm), HPM counters reading zero; `medeleg` causes 1–9, 12, 13, 15 and 19 (0 only without C) and `mideleg` SSIP, STIP, SEIP; `menvcfg.FIOM` writable with S; `mstatus.FS` with four states whenever S exists (even without F); WFI in U-mode legal only without S; `mtvec` and `stvec` 4-byte aligned in both modes;
- misaligned loads, stores, AMOs and LR/SC trap with address-misaligned (no Zicclsm), and an LR reserves its 64-byte block (Za64rs, as Spike), which a store does not cancel;
- privileged spec 1.13, Spike's (Sail allows `medeleg` bit 19 only from 1.13).

**The DUT macros** (`tanager_rvmodel.h`): halt by writing 1 (pass) or 3 (fail) to `tohost` as two 32-bit stores (§2.6); the console on the 16550 at `UART_BASE`; the CLINT's `msip`, `mtimecmp` and `mtime`, with a "soon" timer delay of 2,000 ticks (the U-mode variants reach M-mode through ecalls, which takes the multi-cycle test core about 250 ticks); external and supervisor software interrupts through the interrupt generator (§2.4); access faults at address 0, below the boot ROM.

**The interrupt generator instead of a PLIC model.** The plan here was a small PLIC model with the 16550's interrupt as its source. The interrupt tests only need software to raise and lower MEI, SEI and SSI, and Sail, which computes the expected values, has no PLIC but a "simple interrupt generator" register for exactly this; the framework's Sail macros use it. Modelling the same register in `tg_vsim` and `tg_replay` (§2.4, §3.8) took a few lines in each, gives the DUT and the reference identical macros and semantics, and drives `irq_ssi_i` as well, which a PLIC would not. A PLIC model can still be added for software that needs the standard PLIC (§9).

**Results on 2026-10-13:**
- Spike against Spike: `tcore-rv64im` 97/97, `core-m2-rv64im` 129/129, `core-m3-rv64imac` 355/355. Getting there fixed two `tg_replay` issues (the generator's SEIP handling, device loads under MPRV) and settled the `sail.json` choices above.
- `tg_tcore` in `tg_vsim` with lockstep: 97/97 in `st` and in `st_w3`.
- `tg_core` is still the stub on this branch. The core track's M2 core (`claude/track-core-adb715` at `9154bae`, not yet merged), built with this branch's harness in a scratch copy: 113 of the 129 tests pass in `st` and `st_w3`, also with 250-cycle latency, jitter, back-pressure and D-channel gaps. The other 16 are PMPSm tests in which Spike raises a PMP access fault that the core does not, because its PMP checks come in M3 (core-pipeline.md §1); `exclude/core-m2-rv64im.txt` lists them.

**Known differences** that no test reaches today:
- A reserved `mtvec`/`stvec` mode (2 or 3): Spike and the core clear bit 1; Sail can only ignore the write or stop.
- Sail and Spike keep one `mip.SEIP` bit and one `mip.SSIP` bit that the generator and software both write; the core ORs `irq_sei_i` and `irq_ssi_i` with its software bits (interfaces.md §3), so while the generator's line is high, software cannot clear the bit. Measured in the replay over all 355 M3 tests: no test clears SEIP by software while the generator's line is high (ACT4's handler would, only with `MEIP` pending at the same time). 23 interrupt tests clear SSIP that way, but only after disabling `mie.SSIE`, and they lower the generator's line about 20 instructions later without reading `mip` in between, so a core with the OR behaves the same. §9 has the interface question.

**Disk:** Sail 0.15 (pinned in `tools/versions.sh`, `$TANAGER_OPT/sail-0.15`, 11 MB), the framework's Python packages (`$TANAGER_OPT/act-venv`, 43 MB), the UDB gems (`$TANAGER_OPT/act-gems`, 74 MB, `bundle clean`), and UDB's cache in `~/.local/share/udb` (24 MB). The build tree keeps only the ELFs (about 20 MB for the test core and M2 configurations, 60 MB for M3) and the logs of failing tests.

### 6.2 Constrained-random instruction generator

`tests/random/tg_rand.py` (implemented 2026-10-13; plan §9, §4.15) writes assembly programs that run bare-metal in M-mode and in lockstep. Spike checks every instruction, so the generator never predicts results.
- **Seeded:** a program is reproducible from its seed and options; failures print a one-line reproduction command (conventions §6).
- **Safe by construction:** x2–x4 (stack, data base, alias base) and x30/x31 (trap scratch) are never written; every address is masked into its region; branches go forward and loops have fixed counts (an LR/SC loop is bounded, so a core that keeps failing SC still ends).
- **Templates** (weighted), aimed at the plan's risk areas:
  - LSU: a store followed by loads of the same, contained or partially overlapping bytes, through the same or the other base; the same page offset on two pages (`gp`/`tp`, 16 KiB apart); a store whose address comes from a slow load (or a divide) while younger loads hit or miss it (ordering violations);
  - cache-miss streams over a 64 KiB region (larger than a 32 KiB L1), with stores in them, so lines are evicted dirty;
  - early retirement: a divide or a missing load, its consumers, then a data-dependent branch and sometimes a trap right behind it ("flush storms over pending retired loads");
  - traps the handler skips: misaligned loads and stores, `unimp`, `ecall`, `ebreak`, access faults (addresses below the boot ROM);
  - **width 3:** groups of three instructions in one 16-byte fetch block with RAW, WAW or WAR dependencies, two branches, or a load-use and a store (plan §4.15);
  - CSR reads (counters, `mstatus`, `mscratch`), fences, `fence.i`, calls and returns, and LR/SC and AMOs when A is in the ISA;
  - `--irq=<ticks>`: CLINT timer interrupts during all of it; the handler re-arms the timer.
- **ISAs:** `rv64i`, `rv64im` (M2 and the test core), `rv64ima`, `rv64imac`, `rv64gc` (no FP templates yet; they come with the FPU in M5).
- **Driver:** `make -C tests/random CFG=<cfg> [CORE=...] [N=100] [SEED=1] [ISA=rv64im] [IRQ=0] [STRESS=1]`. Each program is first run Spike against Spike, so a broken program is a generator failure, not an RTL bug. With `STRESS=1` (default) every seed also draws its memory-system settings (latency 30–250, jitter, backpressure, D gaps, `toB` grants, random probes). Passing programs leave nothing behind; failures keep `.S`, `.elf`, log and the reproduction command in `$TANAGER_BUILD/<worktree>/random/<cfg>-<core>/failures/`. `make regress` runs 100 seeds (`RANDN=N` to change).
- **Results on 2026-10-13 with the test core:** 1,000 seeds with memory stress, and 300 with timer interrupts, deferred writebacks and multi-slot trace, in both `st` and `st_w3`, all pass (about 60 programs per second).
- **Does it find bugs?** Two bugs planted in the test core: an SRAIW that ignores shift-amount bit 4 failed 199 of 200 programs (riscv-tests: one test); a dirty eviction that sends the wrong data in its last beat failed all 200 programs, and every riscv-test still passed.

### 6.3 Snapshots

§2.8.

## 7. Build-host notes

- **liblz4-dev** is needed for FST waveforms (Verilator 5.052's FST writer includes `lz4.h`); it is installed on the build host since 2026-10-13.
- **Spike** is used through its installed headers and `libriscv.so` (`$SPIKE_ROOT`); the build adds `-Wl,-rpath` so no `LD_LIBRARY_PATH` is needed.
- **ccache and precompiled headers:** Verilator's makefile lets ccache cache its precompiled header (about 100 MB for `tg_core`). On 2026-10-13 GCC 15 crashed (segmentation fault, `c_common_read_pch`) on every object compiled against such a header returned from the cache, reproducibly for an `st_w3` build of the core; with the header compiled fresh the same build passed. `sim/Makefile` therefore exports an empty `CCACHE_SLOPPINESS`: ccache then runs the compiles that use the header uncached (they rarely hit anyway, since the header changes with the RTL) and still caches Verilator's runtime and our C++. Other Verilator builds on the host (unit tests) may want the same.

## 8. Disk and machine sharing

- Builds use at most `-j8` (conventions §9). Test runners run at most 8 simulations at a time.
- The verification build tree has a 5 GB budget: one `tg_vsim` build is about 50–300 MB depending on the core, and the three ACT4 configurations about 100 MB together (§6.1). Runners delete the logs of passing tests; waveforms are only produced on request and are deleted once a bug is understood.

## 9. Open points for the coordinator

1. **Trace:** a load's address is not in `tr_rec_t`. It is needed for multi-hart lockstep (§3.7) at M7; requested then.
2. **Physical store address:** `tohost` detection under virtual memory uses aliases (§2.6). A `mem_paddr` field would remove the aliases; not needed now.
3. **PMP reset values:** Spike resets PMP entry 0 to "allow all"; the checker can patch it (§3.2) once the core track decides its reset values.
4. **SC failure adoption** (§3.4) is a legal difference that interfaces.md §5 does not list yet.
5. **ID CSRs:** `marchid`, `mimpid` and `mvendorid` reads are adopted (§3.4); the core track should still pick Tanager's values.
6. **Illegal-instruction `tval`:** Spike writes the instruction bits (16 bits for a compressed encoding without C), `ebreak` writes the PC; the core must do the same or the checker reports it.
7. **PLIC model:** ACT4's external-interrupt tests run with the interrupt generator (§2.4) instead of the small PLIC model planned in §6.1; the reasons are there. A PLIC model can still be added for software that needs the standard PLIC in the harness (OpenSBI does not). It would share the region with the generator's register (`0x0C00_0004` is source 1's priority in the PLIC layout); Sail's generator base is configurable and the framework passes it to the macros, so the generator would move.
8. **`irq_ssi_i` (interfaces.md §3):** the interface ORs the line into `mip.SSIP`, while the privileged spec says a platform controller may *set* SSIP to 1 (as the ACLINT SSWI does, and as Spike and Sail model it), after which software clears it. With a level, software cannot clear SSIP while the line is high. ACT4 is unaffected today (§6.1, known differences), and the platform ties the line to 0; defining `irq_ssi_i` as a one-cycle pulse that sets SSIP would match the spec before the SSWI arrives. `irq_sei_i` is fine as it is: SEIP is the OR by the spec.
9. **`TRACE_STALL_HEADROOM` (interfaces.md §5):** 2 × `COMMIT_WIDTH` + `LLT_ENTRIES` is enough only if the sink counts the current cycle's records when it decides to stall. A sink that stalls from its occupancy register needs `COMMIT_WIDTH` more (§2.9). The rule should say which, for the SoC track's trace streamer.

## 10. Provenance

- TileLink message rules: TileLink Specification 1.8.1 (SiFive, public).
- The `tohost`/`fromhost` convention and the riscv-tests environment: riscv-tests (public test suite, used as-is).
- Spike's library interface (`simif_t`, `processor_t`, commit log): Spike's public headers and sources, used as a tool, not as a design reference.
- Fork-based snapshots: a common simulation technique; described here from first principles.
- ACT4 (riscv-arch-test, act4 branch): the framework, its test environment and test plans, the UDB configuration schema, and its Sail reference configuration `config/sail/sail-RVA20S64` (`sail.json` and the UDB file), which `make_sail.py` and our UDB files start from. The interrupt generator's register follows the framework's Sail macros (`tests/env/sail_macros.h`) and Sail's configuration schema. The configurations of other cores in the framework (`config/cores`) were not used.
- WARL choices in the ACT4 configurations: Spike's sources (`csr_init.cc`, `csrs.cc`, `mmu.cc`), read as the specification of the lockstep reference.
- No other core's RTL or testbench was read for any of this.
