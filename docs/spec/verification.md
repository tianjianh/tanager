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
| Constrained-random instruction generator, with F/D templates | `tests/random/` | M3, done |
| Trace back-pressure (`trace_stall_i`): sink model and contract checks | `sim/` (`--trace-stall`) | M3, done (test core; `tg_core` when its port lands) |
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
- **F/D (M3):** Spike's FP behaviour is the reference: NaN-boxing, canonical NaNs, and `mstatus.FS` set to Dirty whenever an instruction writes an FP register or an FP CSR or raises a flag (even one already set). `mstatus` reads are compared; `fflags` is not compared per instruction but its reads are (§3.4). ACT4 (`core-m3-rv64imafdc`), rv64uf/ud and the random F/D programs (§6.2) are ready and pass Spike against Spike.
- **Reset values** that Spike chooses and the core may not: PMP entry 0 (`--pmp-reset=off`), `mtvec` 0, `mstatus.MPP` = U (or M without U). A mismatch on the first read of such a CSR is this.
- **Debugging a mismatch:** the report (§3.6) gives both sides' last 32 instructions. `--log=<file>` writes every record with disassembly; `--fst=<file> --fst-from=<cycle>` dumps waves from shortly before the failing cycle; `--no-lockstep` runs without Spike.
- **Architecture tests:** `make -C tests/arch CFG=st` runs the M2 configuration's ACT4 tests on `tg_core` (§6.1): 113 tests, plus 16 PMP tests excluded until PMP checks arrive in M3. `ACTCFG=core-m3-rv64imac` runs the M3 configuration once the core has the M3 ISA. Each test checks itself against Sail's results and runs in lockstep.
- **The M3 gate, once the core has the M3 ISA with F/D** (plan §11), per configuration:

  ```bash
  tools/ci/regress.sh CFG=st ARCH=1 ACTCFG=core-m3-rv64imafdc MARCH=rv64gc SUITES="rv64ui-p rv64um-p rv64ua-p rv64uc-p rv64uf-p rv64ud-p rv64mi-p rv64si-p rv64uzba-p rv64uzbb-p rv64uzbs-p rv64uzicond-p rv64ui-v rv64um-v rv64ua-v rv64uc-v rv64uf-v rv64ud-v" SIMARGS="--isa=rv64imafdc_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs --priv=MSU --pmp=16"
  ```

  It runs those riscv-tests suites, the directed tests (S-mode interrupts, Sv39, PMP and atomics included), CoreMark and Dhrystone built for `rv64gc`, random `rv64gc` programs with the F/D templates, and ACT4's F/D configuration (895 tests), all in lockstep with the M3 Spike configuration. Every piece passes Spike against Spike today (§4.1, §6.1, §6.2).
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
| `--log=<file>` | off | text commit log: one line per trace record or writeback, with disassembly; `--log-from=<cycle>` starts it later, `--log-bus` adds the core's TileLink beats (§4.5) |
| `--sig=<file>` | off | cycle signature for the cycle-identical check (§4.5): per `--sig-window` cycles (1,024), hashes of the commit trace and of the core's TileLink outputs |
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
- **Which builds have the port:** all of them. The port list is the same in every build (interfaces.md §1): `tg_core`, the test core, and the SoC unit test's wrapper of the test core. The input stays 0 unless `tg_vsim` runs with `--trace-stall`.
- **The test core:** the stall holds its trace queue, so commit stops once the queue is full, while deferred writebacks keep flowing. Two knobs prove that the checks work: `+tcore_stall_lat=0|1|2` adds reaction latency (default 1, the interface's allowance), and `+tcore_stall_bug=1` drops the head record when a stall starts. With latency 2 the run fails with check 1's error at the third stalled cycle; the dropped record fails lockstep with the hint.
- **Where it runs:** `make regress` runs the riscv-tests and the directed interrupt tests a second time with `--trace-stall=50`. A third of the stressed random seeds also draw `--trace-stall` (10, 50 or 200).
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
- M3 (plan §4.1, day one; F/D integration moved into M3, plan §11): `rv64imafdc_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs`, privilege `MSU`, 16 PMP regions: the ACT4 configuration `core-m3-rv64imafdc` (§6.1). Before the FPU is integrated, the same without `f` and `d` (`rv64imac_…`, configuration `core-m3-rv64imac`).
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
| SC failure | The RTL may fail an SC that Spike would let succeed. If the record is an SC with no `mem_st` (a successful SC always stores; with rd = x0 the missing store is the only sign), the checker clears Spike's reservation before the step, so Spike fails it too. An SC that succeeds in the RTL but not in Spike is a mismatch. |
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

   - SCs the core fails (`--sc-fail=<percent>`: the replaying Spike drops its reservation before an SC), with any destination, `x0` included;

   It runs every riscv-tests binary of every suite, `-p` and `-v`, through the checker in seconds. A fault the program gives no chance to inject (for example a deferred writeback in a program without loads) is reported as not applicable.

   **Platform:** the replaying Spike sees the devices of §2.4: the UART (its output is the console), a CLINT whose `mtime` advances once per `--mtime-div` retired instructions (Spike's `time` CSR follows it, and so does Sstc's `stimecmp` comparison), and the interrupt generator. `MTIP`, `MSIP` and `MEIP` follow the device levels; `SEIP` and `SSIP`, which software may also write, are set or cleared only when the generator's line changes, as Sail and Spike's own PLIC do. Interrupts the replaying Spike takes become `TR_IRQ` records. Loads from device regions are marked `mmio_ld` when the access is untranslated (M-mode without MPRV, or satp Bare). An AMO outside main memory raises an access fault, as in the core (interfaces.md §2.4); Spike alone would perform it. Reads of `mvendorid`, `marchid` and `mimpid` return the core's values (0, core-pipeline.md §9; `--mvendorid=`, `--marchid=`, `--mimpid=`) instead of Spike's (`marchid` = 5), as the RTL's would; the checker adopts them either way. `--isa`, `--priv` and `--pmp` configure both Spikes. ACT4 uses this to check its configurations (§6.1).
2. **The test core** (§5) runs the riscv-tests suites it supports, CoreMark and Dhrystone through the whole harness (TileLink models, trace, lockstep).

**Results on 2026-10-13** (`tools/ci/checker_selftest.py`, 9 s):
- 326 riscv-tests (all `-p` and `-v` suites of ui, um, ua, uc, uf, ud, mi, si, zba, zbb, zbs, zicond; `ma_data` excluded, §4.1) pass Spike against Spike, plain and under four perturbation sets (deferral up to 90% of results, nondet values, 2 and 4 harts, 3- and 4-record cycles);
- 19 fault kinds × 7 programs × 2 seeds, plus a wrong interrupt cause on the interrupt test: every applicable injection is reported with the expected diagnosis (270 runs; a dropped writeback is reported either at the end or as the tag reuse it causes, whichever comes first);
- the directed tests (§4.1) pass with deferral, and `irq_timer` and `irq_ext`, which tolerate extra interrupts, also with random interrupts injected at enabled boundaries; `irq_s` counts its interrupts exactly, so it runs without injection.

The checker found its first real bug the same day: the test core lost deferred writebacks when two deferred records left its trace queue in one cycle.

### 3.9 FPGA lockstep on the board (`tanager-lockstep`)

M4's exit criterion (plan §7.4, §9): the commit trace the uncore streams into DDR (uncore-trace.md) is checked on the KV260's A53 against Spike, record by record, by the checker of §3.1–3.6.

**Two programs, one pipe.**
- **`tanager-host`** (sw/host, the SoC track) does every board access: the overlay guard, the ring, `TRS_RP`, the console and the injector. `--trace FILE` writes each 64-byte record to `FILE` in order. While `FILE` does not take them, the ring fills and the cores stall on `trace_stall_i`, so nothing is lost.
- **`tanager-lockstep`** (`sim/src/tanager_lockstep.cpp`) reads that stream from a file, a FIFO or stdin and feeds `lockstep_t`. It never opens `/dev/mem`.
  - **Spike's memory** starts as `tanager-host load` leaves the board's (soc.md §3): the boot ROM at `0x1000`, as `tg_bootrom_img_pkg.sv` holds it (`gen_bootrom_h.py` makes a header of it); `--fw` at `0x8000_0000`; `--kernel` at `+0x20_0000`; `--dtb` at `+0x220_0000`. Everything else is zero. The platform is `tg_vsim`'s: device loads are adopted (§3.4).
  - **Options:** `--isa`, `--priv`, `--harts` and `--pmp` default to the configuration's (§3.2). `--mem-mb` defaults to 768: the 1 GiB carve-out less the default ring of 2^22 records. `--stats=S` prints a progress line every S seconds. `--max=N` stops after N records. `--stale=C` flags a deferred writeback still pending after C cycles. `--plant=N` is a self-test: it flips bit 0 of the first value at or after record N that the checker compares. That is a register write or a deferred writeback, never a value it adopts (an MMIO load, a `nondet` CSR read). On the board, a plant had landed on the SoC test's poll of the UART, an adopted MMIO load, so it could never fire and the run passed. The checker's `compares_value` now decides, and the message names the register and instruction it corrupted.
  - **Decoding** (host.md, commit trace): kind 3 is a writeback (`tr_wb_t`). A retire's value, address and data words are `rd_value`, `mem_vaddr` and `mem_wdata`; a trap's or interrupt's are `cause` and `tval`. The record's cycle is 32 bits; the checker widens it for `--stale`.
  - **Exit:** 0 when the stream ends with nothing pending (PASS); 2 at the first mismatch, after the record number, its cycle, the raw record and §3.6's report on stderr.
- **A pipe or a FIFO:** since 6466df0, `tanager-host boot … --trace - | tanager-lockstep … -` works: with `--trace -`, stdout carries only records, and the messages and the stdio console go to stderr. A FIFO given to `--trace` works with any version, and keeps stdout for the console.
  - `tanager-host` copies at most 4,096 records a poll, so the console stays serviced while the checker lags.
  - `--trace` also zeroes the RISC-V window, so Spike's zeroed memory and the board's agree on memory no software wrote.
  - When the checker stops at a mismatch, `tanager-host` ends the run as for a power-off, with exit code 4. Before 6466df0 it died of SIGPIPE, which left the cores stalled and a stdio console raw.

**Building it: cross-compiled, measured against native.**
- `make -C sim lockstep-aarch64` cross-builds Spike at `SPIKE_SHA` with the aarch64 musl toolchain `tanager-host` uses (`sw/versions.sh`), then links the checker statically and strips it. The result is a 9.9 MB binary with no packages needed on the board. Spike's source comes through `sw/fetch.sh spike` (GitHub's archive of the commit, its SHA-256 recorded on first fetch); nothing is vendored.
- **Measured on the 5950X:** 2 min 43 s with `-j8` (17.2 CPU-minutes). What it keeps is the libraries and headers, 39 MB. Spike's own flags include `-g`: with it, `libriscv.a` alone was 973 MB and the object tree 2 GB. The rule passes `-g0` and deletes the tree.
- **Native on the board, estimated** (no build there: the board is the board session's): an A53 at 1.33 GHz compiles about 5–7 times slower per core than the 5950X, so 17 CPU-minutes become about 1.5–2 hours of CPU. With 4 cores and 4 GB, and Spike's larger files needing up to about 1 GB each, that is half an hour to an hour. It also needs a compiler and Spike's build dependencies installed on the board's Ubuntu.

**Speed.** Per record, the checker steps Spike once with commit logging on, and logging is costly in two ways.
- **Spike formats a log line at every step,** about ten `fprintf` calls, even into `/dev/null`. That was half the checker's time. The log file is now opened read-only: glibc's and musl's `fprintf` return at once, and nothing reads the log anyway.
- **With logging on, Spike caches no translations** (`refill_tlb`), so every fetch, load and store runs Spike's PMP check over all 16 entries. The checker's own fetch, which compares the instruction bits, was one of about 3.4 such accesses per record. It now goes through Spike's instruction cache, which Spike's own fetch refills at every step, and a difference is confirmed with a fresh fetch before it is reported. Spike's PTE cache keeps Sv39 walks cheap.
- **Result:** on the 5950X, the OpenSBI trace below went from 0.93 M to 1.92 M records/s (3.4 to 1.6 CPU-seconds). The PMP checks inside Spike's step, about half of what remains, cannot change without patching Spike, which we don't. **On the A53** (the board session, 2026-10-14): 141,504 records/s on that trace (21.8 s, 6.5 MB resident), 13.6 times slower than the 5950X. Live through the FIFO it checks 146 K records/s on the SoC test, and 97,854 records/s over a whole Linux boot.

**The proof in simulation** (deliverable 3). `tb_boot` with `+trace_out=FILE` streams `tanager_soc`'s trace into a 4,096-record ring in `tb_axi_mem`, as `tanager-host` does. Every 2,000 cycles it reads `TRS_WP` over the host's AXI-Lite port, copies the new records with `peek_beat`, and writes `TRS_RP`. With `+trace_out`, unwritten memory reads as zero (`tb_axi_mem`'s `+mem_zero`, which `tb_boot` turns on), as on the board, where `tanager-host` zeroes the window for `--trace`. Without the plusarg nothing changes: main's `tb_boot` and this one give the same signatures over the boot's first 3 M cycles. The trace port writes 16 bytes a cycle, a quarter of a record, so a traced run is slower than an untraced one: OpenSBI runs at IPC 0.15 instead of 1.06. One real `st` core:
- **`soc_test.bin`:** 230,255 records stream and PASS. With `--plant=100000`, the checker stops at record 100,000 with the full report (`x15` of a `mul`: RTL `…4d`, Spike `…4c`).
- **OpenSBI** (`fw_jump.bin`) to its banner: 20 M cycles, 3,087,220 records with 6 traps, PASS.
- **Linux**, its records streamed live into the checker through a FIFO. The first run stopped at record 5,713,424 (cycle 37.45 M) inside the kernel's `crc32_be` over the device tree (`early_init_dt_verify`).
  - **Where it read:** OpenSBI packs the tree and then appends 4 KiB of free space for the next stage (`CONFIG_PLATFORM_GENERIC_FDT_EMPTY_SPACE`), which nobody writes. Linux checksums `fdt_totalsize`, so it reads that space.
  - **Not a core bug:** every byte the RTL read there equals `tb_axi_mem`'s fill pattern at its address, while Spike's memory is zero.
  - **The fix:** the board's DDR holds stale data there, so every board boot would stop at the same place. A device tree zero-padded to its 64 KiB slot gives both sides zeros, and the board runs use it until `tanager-host load` zeroes the window (§9, 13). The simulated boot is running again with it.

**On the board** (the board session runs it; Linux's fan control stays on for every run):
1. **Offline, no PL:** `tanager-lockstep --fw soc_test.bin soc.trace` (PASS, 230,255 records), the same with `--plant=100000` (exit 2 at record 100,000), and the OpenSBI trace (PASS). These give the A53's records per second.
   - Result: all three as expected. The SoC trace checked at 149,648 records/s and the OpenSBI trace at 141,504 (21.8 s). The planted value stopped it at record 100,000 with the same report as on the 5950X.
2. **The trace path, no checker:** `tanager-host boot --fw soc_test.bin --kernel /dev/null --dtb /dev/null --lossless --trace /tmp/soc.trace`. The hardware writes a trace for the first time. Then check `/tmp/soc.trace` offline as in step 1.
   - Result: 4,435,137 records, no AXI error, PASS offline at 166 K records/s. The board's run is 19 times longer than simulation's because the test waits on real timers.
3. **Live, the SoC test:** make a FIFO in the user's home directory, start `tanager-lockstep --fw soc_test.bin --stats=5 FIFO` in the background, then run step 2's `boot` with `--trace-log2 16 --trace FIFO`.
   - Result: PASS after 334,491 records, at 146 K records/s.
   - **Not in `/tmp`:** Ubuntu's `fs.protected_fifos` stops root (`sudo tanager-host`) from opening another user's FIFO there with `O_CREAT`, which `fopen(…, "wb")` uses.
   - **A small ring:** `tanager-host` copies everything between `RP` and `WP` in one poll, at the checker's pace. With the default 2^22 records, one poll can last many seconds, with the console unserviced. 2^16 records keep polls short. Linux still uses only the 768 MiB its device tree gives it.
4. **Live, Linux to the root shell,** at native latency and at 250 injected cycles. Use the traced runs' 768 MiB device tree (`make -C sw/dts MEM=0x30000000`) and give the checker the same three files. `tanager-host` from 6466df0 zeroes the window for `--trace`; with an older one, zero it first or pad the device tree to 64 KiB (`truncate -s 65536`; see the Linux result above). `tg.sh linux` stops after `LINUX_S` seconds (default 1,200), so raise it. Report the wall time against the unchecked boot (TANAGER-BOOT-OK 8 s after the load; at 250 cycles, the login prompt after 14 s), records per second from `--stats`, and any mismatch with its report.
   - **Result at native latency** (M4 core 20435b1, 60 MHz, the window zeroed, `--trace-log2 16`): PASS. Linux booted to a root shell and powered off: 335,786,888 records (12,658 traps, 12,504 interrupts), no mismatch, in 3,431.5 s at 97,854 records/s.
     - **Slowdown:** TANAGER-BOOT-OK came 2,336 s after the load, against 8 s unchecked (292 times); init ran at 731 s of kernel time, against 2.1 s.
     - **Console:** the login prompt came at 2,396 s and the root shell at 2,493 s. One RCU stall report appeared (the timer keeps running while the cores wait for the checker).
     - **Without zeroing,** the first try stopped at record 8,204,496, on the device tree's unwritten space (RTL `0x40`, Spike `0`), as simulation had predicted.
   - **Result at 250 injected read cycles** (the same build, the padded device tree, the window zeroed): PASS. Linux booted to a root shell and powered off: 355,612,637 records (12,810 traps, 15,045 interrupts), no mismatch, in 3,642.8 s at 97,620 records/s.
     - **Slowdown:** the login prompt came 2,561 s after the load, against 14 s unchecked (183 times); TANAGER-BOOT-OK at 2,491 s; init at 776 s of kernel time. The injected latency costs a checked boot little (2,491 s against 2,336 s for TANAGER-BOOT-OK), because the checker sets the pace.
     - **Console:** one RCU stall report again; nothing else.
   - **All five steps pass, and with steps 4 and 5 M4's FPGA-lockstep criterion is met** at 0 and 250 injected cycles (2026-10-14). The board session's logs, the first try's mismatch report included, are in `fpga/kv260/board/lockstep/`, and its account in `fpga/kv260/README.md`, "FPGA lockstep".

## 4. Test suites and runners

### 4.1 riscv-tests

- **Binaries:** the pinned build in `$RISCV_TESTS/isa` (`tools/versions.sh`).
- **Suites and milestones:**

  | Milestone | Suites |
  |---|---|
  | M2 | `rv64ui-p`, `rv64um-p`, `rv64mi-p` |
  | M3 | + `rv64ua-p`, `rv64uc-p`, `rv64si-p`, `rv64uzba-p`, `rv64uzbb-p`, `rv64uzbs-p`, `rv64uzicond-p`, and with F/D (moved into M3, plan §11) `rv64uf-p`, `rv64ud-p`; and every `-v` variant |
  | `tg_tcore` | `rv64ui-p`, `rv64um-p`, the `rv64mi-p` tests it supports |

- **F/D readiness:** all 284 tests of the M3 suites, `rv64uf`/`rv64ud` included, pass in `tg_replay` with the M3 F/D Spike configuration (`--isa=rv64imafdc_… --priv=MSU --pmp=16`), and the 46 FP ones also with 80% of results deferred and 3 records per cycle (2026-10-13).
- **Known exclusions** go in `tests/isa/exclude/<cfg>.txt` with a reason per line (for example, `rv64mi-p-breakpoint` until Sdtrig exists).
- **Command:** `make -C tests/isa CFG=<cfg> [CORE=...] [SUITES=...] [LAT=...] [SIMARGS=...]` runs each test with lockstep, at most 8 at a time, and prints a table and `N passed, M failed`; logs of failing tests stay in the log directory and passing ones are deleted. `make -C tests/isa replay SUITES=all` runs the same suites Spike against Spike. Underneath is `tests/isa/run_isa.py`, which takes any tg_vsim or tg_replay binary and arguments.
- **`-v` tests:** the runner passes the kernel alias of `tohost` (§2.6).
- **Directed tests** (ours, `tests/isa/directed/*.S`, built to `tanager-p-*`): `irq_timer` (CLINT timer and software interrupts, WFI, `mip` reads) and `irq_ext` (external interrupts from `--irq-rand` pulses). `make -C tests/isa directed CFG=<cfg>` runs them with lockstep and random external-interrupt pulses; the checker self-test runs them Spike against Spike with injected interrupts. riscv-tests never enable interrupts, so these are what exercise `TR_IRQ`. The core track added `amo` (AMOs, LR/SC and their faults, including AMOs to device addresses), `cache_evict`, `irq_s` (supervisor interrupts, Sstc), `pmp` and `vm` (Sv39). `tlb_stress` (ours, for §4.5) maps 128 data pages and 64 code pages of 4 KiB in permuted order, plus a megapage, and sweeps working sets of 4 to 128 pages twice each, so TLB hits, misses and replacement all depend on the TLB's size and policy; it also flushes by SFENCE.VMA and satp and adds with AMOs under translation. `tag_short` (ours, the core track's recipe) runs rename out of its 16 wakeup tags: nine MULs and nine FMUL.Ds wait on a load that misses, in IQ_A1 and IQ_FP. It stalls rename in 35 of its 1,204 cycles in `st`, where random programs managed it twice in 200 programs. Each directed test passes at once on a core without the feature. The checker self-test replays them all (§3.8).
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

`make regress CFG=<cfg> [CORE=core|tcore] [LAT=...] [SUITES=...] [MARCH=...] [SELFTEST=0] [TIMING_CUTS=0|1]` (top-level target; `tools/ci/regress.sh` takes the same `KEY=value` arguments plus `SIMARGS="..."` for extra tg_vsim options, and `ARCH=1 [ACTCFG=...]` for ACT4).

`TIMING_CUTS` picks the core's timing-cut profile (DR-140; `sim/profile.mk`). The core's three switches (#2, #4 and #5) are on together or off together, and the core package's default is the shipping profile. `TIMING_CUTS=0` or `1` passes `+define+TG_TIMING_CUTS=0|1`. It builds in a directory of its own (`<cfg>-<core>-tc0`, `-tc1`) and logs to one (`regress/<cfg>-<core>-tc0`). The tests' Makefiles take it too. CI runs both of DR-140's profiles: "default" (unset: #2, #4 and #5 on) and "fallback" (`TIMING_CUTS=0`: all three off). #8 is off in both. With Spike lockstep, the profiles differ only in cycles.

The steps:
1. builds `tg_vsim` for the configuration and `tg_replay`;
2. runs the riscv-tests suites with lockstep (default `rv64ui-p rv64um-p rv64mi-p`, the M2 set);
3. runs the directed tests with lockstep (§4.1);
4. runs CoreMark A and B and Dhrystone with lockstep (default `MARCH=rv64im`);
5. runs 100 constrained-random programs with memory stress (§6.2; `RANDN=N`, 0 skips them);
6. runs the riscv-tests and directed tests again with `--trace-stall=50` (§2.9); with `ARCH=1`, the core's ACT4 configuration (§6.1: `tcore-rv64im` or `core-m2-rv64im`, or `ACTCFG=`); off by default until the coordinator makes it part of the core's merge gate (§9);
7. runs the checker self-test (§3.8; `SELFTEST=0` skips it) and 50 random F/D programs Spike against Spike (§6.2; `RANDFD=N`, 0 skips them);
8. prints one summary and exits non-zero if anything failed; logs of failing steps stay in `$TANAGER_BUILD/<worktree>/regress/<cfg>-<core>/`.

The core track runs it for `st` and `st_w3` before each merge request (conventions §6), widening `SUITES` and `MARCH` as features land. It takes about as long as the slowest test, since tests run 8 at a time.

**Results on 2026-10-13 with the test core:** `REGRESS PASS` for `st`, `st_w3`, `smt2` and `smt2_w3` at native latency, and for `st_w3` at 120 and 250 cycles with deferral, multi-slot trace and random probes (about 15 s per configuration). With the stub `tg_core` every test reports `HANG`, as it should.

### 4.4 Soak (`tools/ci/soak.sh`)

A continuous random campaign on main that uses the build host's idle threads (conventions §9). Its findings never gate a merge.
- **Each round** runs constrained-random programs (§6.2) on the real core in `st`, `st_w3`, `smt2` and `smt2_w3` at once:
  - every extension switch of `tg_core_pkg` (`EXT_*`) is on, as the core track tests them. Spike uses the M3 configuration (§3.2). Once the core has `EXT_FD`, Spike's ISA adds `f` and `d` and the programs are `rv64gc`, with the F/D templates; before that they are `rv64imac`;
  - every program draws its own memory stress (latency 30, 90, 120 or 250 cycles, jitter, back-pressure, D gaps, `toB` grants, probes, the two denied pages), and a third also stall the trace (§2.9);
  - a third run in S-mode under Sv39 (`tg_rand --vm 33`, §6.2), once main's generator has the option;
  - timer interrupts are on in every other round. Once main has the core's timing-cut switch (DR-140), both profiles are built: the profile alternates every round and the interrupts every second round, so four rounds cover all four pairs. Tallies and failures name the profile (`st-tc0`, `st-tc1`);
  - 48 programs per configuration per round, with new seeds each time.
- **Main only, no checkout:** when main moves, the script exports it with `git archive` (as `fpga/budget/nightly.sh` does), turns the M3 switches on in that copy and builds `tg_vsim` there, without ccache, so the tracks' cache entries stay.
- **Strictly in the background:**
  - `nice 19` and idle I/O priority, at most 8 simulations (Verilator builds at `-j4`), never Vivado;
  - memory first (conventions §9): no program starts while `MemAvailable` is under 12 GB, and no build under 16 GB (a `tg_core` model compile peaks at 0.63 GB, measured on `smt2_w3`, so `-j4` takes about 3 GB). A simulation takes about 12 MB. While a new main cannot be built for lack of memory, the soak keeps running the previous build. It runs with `oom_score_adj` 900, so the host's memory guard and the kernel stop it before anything else;
  - holds while the host drive C: has under 20 GB free, and before a round while more than 20 tasks are runnable (the tracks are busy).
- **Output:** `$TANAGER_BUILD/soak/summary.md` lists main's commit, the programs run per day and configuration, and the failures to triage.
  - Each failure keeps its program, the last 80 lines of its log and a one-line repro in `soak/fail/<time>-<cfg>-s<seed>/`; the newest 100 are kept.
  - The loop's own log rotates at 1 MB.
  - A finding becomes a core bug report only after the verification track confirms it; checker or harness problems are the verification track's to fix.
- **Control:**
  - `tools/ci/soak.sh start` runs it under `nohup` from a private copy, so editing the script does not disturb it. It also installs an `@reboot` crontab entry with main's copy of the script, so the soak starts again after a WSL restart (as `tools/memguard.sh` does).
  - `stop` stops it, with everything it started, until the next start or boot; `disable` also removes the `@reboot` entry; `status` shows its state.

### 4.5 Cycle-identical check (`make cycle-identical`)

The FPGA-friendly rewrites must not move a single cycle (DR-123, DR-125; perf/fpga_friendly.md rule 1). This check proves it for one tree against a base commit, in a few minutes:

```
make cycle-identical CFG=st [BASE=<commit>] [BRANCH=<ref>] [SUITES=isa,stress,bench,random] [RANDN=200] [BOOT=N] [JOBS=8]
                     [TIMING_CUTS=0|1] [BRANCH_TIMING_CUTS=0|1]
```

- **Profiles (DR-140).** `TIMING_CUTS` builds both sides' `tg_vsim` in that timing-cut profile, so a change is checked in each profile CI runs. `BRANCH_TIMING_CUTS` sets this side's only. `BRANCH_TIMING_CUTS=0` against a base without the switches is the switch MR's own proof: all off is cycle-identical to the core before them. A forced profile is part of the build's cache key. The boot suite builds the package's default.

- **What is compared.** Both sides run the same programs with the same options and seeds. For each run, `tg_vsim --sig` (`sim/src/sig.h`) writes one line per 1,024 cycles:
  - the commit records and writebacks of the window: their number and a hash of them, each with its cycle and its slot or port;
  - the core's TileLink outputs: the number of events and a hash of them. An event is a valid beat the core drives on A, C or E, with its payload, or its ready on B or D in a cycle when the model offers a beat there;
  - at the end, the cycle count, `instret` and the status.

  Fields without meaning are left out of the hashes: the data of a message that carries none, a store's bytes beyond its size, and `rd_value` without `rd_we`. So a rewrite that changes only don't-care bits passes. Two runs are identical when every line matches.
- **The two sides:**
  - **The branch** is the working tree as it is, uncommitted and untracked files in `rtl/`, `sim/` and `tests/unit/` included. It is read through a temporary git index, so the worktree and its index are not touched. `BRANCH=<ref>` takes the branch side's `rtl/` from a ref instead, so a track's branch can be checked from another checkout (main's, for a merge) without checking it out.
  - **The base** is BASE's `rtl/`, by default the merge base of HEAD and main.
  - **Harness:** both sides are built with the branch's harness (`sim/`), so only the RTL differs; `--harness own` builds the base side with BASE's.
  - **Programs** are built once and shared by both sides.
- **Suites** (the defaults are the first four):

  | Suite | Programs | Options |
  |---|---|---|
  | `isa` | the regression's riscv-tests suites (284 at M3) and our directed tests (§4.1), `tlb_stress` included | native latency; `--irq-rand=5` for the directed tests |
  | `stress` | the same programs | memory stress drawn per test (latency 30–250, jitter, back-pressure, D gaps, `toB` grants, probes) and `--trace-stall=50` |
  | `bench` | CoreMark A and B and Dhrystone, `rv64im` and `rv64gcb` | latency native and 120 |
  | `random` | `RANDN` (200) `tg_rand` programs: `rv64gc` with F/D, else `rv64imac`; a third in S-mode under Sv39 | the soak's stress (§4.4); timer interrupts on odd seeds |
  | `reset` | the riscv-tests | random initial values in every register without a reset (`--rand-reset`; see below) |

- **The Linux boot (`BOOT=N`)** runs the first N million cycles of the SoC track's Linux boot on the whole SoC: cores and uncore (crossbar, L2, memory path, devices, host bridge, trace streamer). `tg_vsim` holds only the core, so for an uncore rewrite this is the check.
  - **By default** a change that reaches the uncore boots 3 M cycles with two cores, on top of the programs. That is any changed file under `rtl/uncore`, `rtl/soc` or `rtl/common`, whose packages and primitives (`tg_fifo`, `tg_ram_lut`, `tg_map_pkg`) the uncore uses too (coordinator, 2026-10-14). Two cores, because the crossbar and the L2 see contention between cores and coherence probes only then. `BOOT=0` skips the boot; `BOOT=N` and `BOOT_CORES=1|2` set it.
  - **The testbench** is `tests/unit/boot`'s `tb_boot` (OpenSBI, then the `lp64d` kernel), unchanged. The check compiles `sim/tb/tg_soc_sig.sv` into it and binds it into `tanager_soc` with `tg_soc_sig_bind.sv`, which uses only the SoC's ports (soc.md §1).
  - **Its lines** add two columns to `tg_vsim`'s: every core's commit records and writebacks (hashed as in `sig.h`), then the SoC's memory side, then its host side.
    - Memory side: each beat the SoC drives to the DDR banks and the trace port (AR, AW, and W with only the bytes its strobes enable), its R and B ready while a beat is offered, and `status_o` changes.
    - Host side, on the host clock: the AXI4-Lite port's ready while a request is offered, its responses and `host_irq_o`.
  - **Determinism:**
    - The memory models draw their latencies from Verilator's random generator. So the seed is fixed (`+verilator+seed+1`, `--boot-seed`), and the boot builds with one Verilator thread: a threaded model maps processes to threads by its own partition, which a change anywhere in the design could move.
    - With one thread, the draws did not move with a core change (below), nor when the testbench's memory instances were declared in another order, nor with a `$display` added to `tb_boot`'s trace loop.
    - With four threads they do move. That same `$display` changed a 1 M-cycle run from 1,063,470 instructions to 1,062,353: the core track found it, and it is reproduced here.
    - The fix is one random stream per `tb_axi_mem` instance, offered to the SoC track (their file). With it, both testbench versions give the same run with one thread or four.
  - **Images:** OpenSBI's `fw_jump.bin` and Buildroot's `Image`, by default the newest under `$TANAGER_BUILD` (`--boot-fw`, `--boot-kernel`). The device tree comes from `sw/dts`, as the boot Makefile's `linux` target makes it (128 MiB, FPU). `BOOT_CORES=2` boots two cores; `CFG` picks `st` or `smt2` cores.
  - **Cost:** a `tb_boot` build takes 19–45 s with ccache. It runs at 16–24 kHz with one `st` core on a busy host, so 3 M cycles take 2–3 minutes and 20 M about 18, both sides at once. A run that both sides share (one build, the same options, as in a check of main against itself) runs once. The boot's change column is its cost in cycles: the boot runs a fixed number of cycles, so the change is measured from the instructions retired in them.
  - **A difference** is explained like the programs': both sides rerun up to the first differing window with `+sig_log=FILE +sig_log_from=C +sig_stop=C2`, which log every record and every memory-side and host-side event.
  - **`--boot-tree <ref>`** (the script's option) takes `tests/unit` and `sw/dts` from another ref. It was needed before `tb_boot` reached main with the SoC merge (cfaa9c9); the RTL on both sides must suit that `tb_boot`.
  - **Results (2026-10-14, SoC branch, `st`, one core, 3 M cycles):**
    - the SoC branch before and after it merged main's third area pass (a4df26d and 4d5ca13, eight core files) is identical;
    - a planted change, the L2 bank's D FIFO 8 → 4 entries, shows at cycle 50,477: a refill read issues earlier and a commit moves by two cycles.
    - with two `smt2` cores (four harts, the v1 SoC's shape) over 2 M cycles, the same pair is identical too. That build takes about 2 minutes, and the run goes at about 14 kHz;
    - from main's tree after the SoC merge (98562e1), `make cycle-identical SUITES=none BOOT=20` passes: 20.09 M cycles in 18.5 minutes;
    - by default (no `BOOT` given), a comment-only crossbar change gets the two-core boot and the programs: all 797 identical in 7.5 minutes;
    - the same planted L2 change with two cores shows in the first 1,024 cycles (core 1's store one cycle later, at cycle 505), against cycle 50,477 with one core. Two cores contend from their first instructions.
- **Output:**
  - **Per suite:** programs, identical, differing, cycles compared, and the cycle change summed over the suite. The change is the IPC cost of a change that is not identical, which the reserve list needs (DR-122).
  - **First differences:** for the first five differing runs, the check reruns the first differing window on both sides with `--log --log-from --log-bus` and prints the first differing line with its context, the two logs and a rerun command.
  - **The report:** every difference goes to `$TANAGER_BUILD/<worktree>/cycle-identical/<cfg>/report.txt`.
  - **Exit status:** 0 when every run is identical, 1 when some differ, 2 when the check could not run.
- **Cost:**
  - **Builds** are cached in `$TANAGER_BUILD/cycle-identical/`, shared by every worktree. The key is the RTL and harness tree hashes, the configuration and the toolchain. Only the binary is kept (3.5 MB), for the 12 most recently used builds, with a lock against two checks building the same tree. A running check holds a shared lock on each of its builds, so another check's pruning never removes one in use.
  - **Signatures** are cached by build, program and options. A check against a base that someone has already checked builds and runs only the branch side.
  - **Measured on `st`** (2026-10-14, host busy with the tracks' work):
    - the default suites are 796 programs, 32 M cycles per side;
    - with the base side cached, a check took 1–3 minutes: a build of 58–81 s with ccache, then 63–104 s of runs at `-j8`;
    - a first check against a new base builds and runs both sides, so it takes about twice as long.
- **Self-test.** Changes planted in `rtl/common/cfg/tg_cfg_st.sv` on main fd54e65 (`st`, default suites):

  | Planted change | Programs that differ: `isa` / `stress` / `bench` / `random` (of 292 / 292 / 12 / 200) | Cycles, `bench` |
  |---|---|---|
  | a comment in `tg_rob.sv` | none | 0 |
  | `RAS_ENTRIES` 32 → 16, `CHECKPOINTS` 4 → 2 (no RTL uses them yet: controls) | none | 0 |
  | `IBUF_ENTRIES` 16 → 8 | 292 / 292 / 12 / 200 | +0.10% |
  | `IQ_STA` 4 → 3 | 177 / 170 / 12 / 200 | +1.99% |
  | `LQ_ENTRIES` 16 → 8 | 151 / 152 / 12 / 134 | +0.14% |
  | `UBTB_ENTRIES` 64 → 32 | 152 / 148 / 12 / 89 | +2.12% |
  | `DTLB_ENTRIES` 32 → 16 | 1 / 1 / 0 / 0: `tlb_stress` only (+8.4% there) | 0 |
  | `ITLB_ENTRIES` 16 → 8 | 1 / 1 / 0 / 0: `tlb_stress` only (+1.8% there) | 0 |

  Some differing runs ended on the same cycle count as the base, with different timing on the way, or differed only in their TileLink events. A cycle count alone misses those.

  **On real RTL:** main's third no-IPC area pass (merged as 43a523e: eight RTL files, the LSU most) was checked against fd54e65 after its merge. It is identical in `st` and `smt2` on all 796 programs, in both the commit trace and the TileLink outputs. That confirms with this check what the core track had shown with CoreMark's cycle counts.

  The spikes track's shared primitives (merged as 2576359) restructured `tg_fifo`'s default path in `rtl/common/prim`, which both the core and the uncore use. Checked against 98562e1 after their merge, with the programs and the two-core boot that `rtl/common` now gets by default, all 797 runs are identical.

- **What the suites cannot see.** Identical on these programs does not mean identical everywhere: a structure that no program fills cannot show a difference.
  - Before `tlb_stress`, halving the data or instruction TLB moved no cycle in any of the 503 programs: the benchmarks and random programs run without translation, and the `-v` riscv-tests touch fewer pages than the TLBs hold.
  - A rewrite of a structure that the suites do not stress needs a program that does, first. `tlb_stress` is that program for the TLBs. The planted changes above show which sizes the suites see today.
  - The Linux boot's first N million cycles (`BOOT=N`) adds the long-run paths: evictions, page tables, interrupts and the uncore.
- **Reset (`SUITES=...,reset`).** Verilator 5.052 draws each register's random initial value from the seed and a hash of the register's scope name. So a register that keeps its name gets the same value on both sides.
  - **What a difference means:** the branch's timing depends on the initial content of state that the base does not have. Typically a structure has moved from flip-flops with a reset into LUTRAM or block RAM, which have none (fpga_friendly.md T1, T3).
  - **On the board,** that shows only after a warm reset. At power-up the content is the INIT value, zero, the same as in the default runs.
  - **The base already depends on such state:** `rv64ui-p-add` takes 1,389 cycles from zeros and 1,468 with most random seeds. A branch at its first loop exit is predicted differently, which points to a predictor table without a reset. Such results need reading, so `reset` is not a default suite.
- **Configurations:** `CFG="st smt2 st_w3 smt2_w3"` checks each in turn. A rewrite must be identical in every configuration it builds in.

## 5. The test core (`tg_tcore`)

Simulation-only RTL in `sim/tcore/`, never in a product filelist. Its only job is to exercise the harness and the checker before `tg_core` exists, and to keep doing so as a reference afterwards.

- **ISA:** RV64IM, Zicsr, Zifencei, Zicntr; M and U modes; `mstatus`, `misa`, `mie`/`mip`, `mtvec` (direct and vectored), `mscratch`, `mepc`, `mcause`, `mtval`, `mhartid`, the counters, `mcounteren`, `menvcfg` and PMP registers as WARL zero, the ID registers as zero; ECALL, EBREAK, MRET, WFI; precise exceptions for illegal instructions, misaligned and faulting accesses; interrupts MEI, MSI, MTI.
- **Pipeline:** one instruction at a time (a multi-cycle state machine). Width-generic trace output: it uses slot 0 only, or spreads records over all `COMMIT_WIDTH` slots when `TRACE_SPREAD=1`.
- **Memory:** a one-line fetch buffer over `l1i` (`Get` of a line), and a small direct-mapped write-back data cache over `l1d` that acts as a real TL-C client: `AcquireBlock NtoB` / `NtoT`, `AcquirePerm BtoT` for upgrades, `GrantAck`, `Release` / `ReleaseData` on eviction, and `ProbeAck` / `ProbeAckData` to probes. Device accesses go to `mmio`.
- **Trace back-pressure:** `trace_stall_i` (§2.9) holds the trace queue; `+tcore_stall_lat` and `+tcore_stall_bug` test the harness's checks.
- **Trace features**, so that every checker path runs end to end:
  - **deferred writebacks:** with `+tcore_defer=<percent>`, it reports cacheable loads and DIV/REM with `rd_deferred = 1` and sends the value on a `trace_wb` port 1–16 cycles after the record (a delay line; the core itself is not early-retiring);
  - **several records per cycle:** with `+tcore_spread=1`, records wait in a small queue and leave it 0 to `COMMIT_WIDTH` at a time;
  - `mmio_ld` on device and ROM loads, `nondet` on counter, `mip` and `marchid` reads, `TR_TRAP`, `TR_IRQ`.
- **CSRs:** exactly Spike's set for an M+U RV64IM hart without PMP or triggers (the checker found the differences). `misa.M` is writable, as in Spike, and clearing it makes MUL and DIV illegal (ACT4's `Sm_misa` found it read-only).
- **Speed:** about 1.7–2.3 MHz of simulated cycles at an IPC of 0.1 (it is a multi-cycle machine), so CoreMark's two iterations take 3–12 s.
- **Results:** `rv64ui-p`, `rv64um-p` and `rv64mi-p` (82 tests), the directed interrupt tests (2,000+ interrupts per run) and CoreMark A/B and Dhrystone pass in lockstep at 30, 120 and 250 cycles, also with jitter, backpressure, D-channel gaps, `toB` grants, random probes (CoreMark: about 100 K Acquires, 5 K Releases with data, 280 K probes), deferral and multi-slot trace.

## 6. M3 items

### 6.1 riscv-arch-test (ACT4) with Sail

**Status (2026-10-13):** implemented. Four configurations; all their tests pass Spike against Spike, the test core passes its configuration in `tg_vsim` with lockstep, and the core track's M2 core passes 241 of its 243 (two fail on a fetch bug, below).

**How ACT4 works** (act4 branch, pinned in `tools/versions.sh`): the framework selects the tests that apply to a DUT from its UDB configuration, compiles them, runs them on Sail to compute the expected results, and compiles those results into self-checking ELFs. The DUT only runs each ELF: the test prints `RVCP-SUMMARY: TEST PASSED|FAILED` and halts through `RVMODEL_HALT_PASS|FAIL`. In the Sail runs the framework's own macros (`tests/env/sail_macros.h`) replace the DUT's, so the DUT's macros only need to have the same architectural effect.

**Commands** (after `source tools/env.sh`):

```bash
make -C tests/arch CFG=st CORE=tcore                     # ACTCFG=tcore-rv64im: build the ELFs, run them in tg_vsim
make -C tests/arch CFG=st                                # CORE=core, ACTCFG=core-m2-rv64im
make -C tests/arch CFG=st ACTCFG=core-m3-rv64imac        # once tg_core has the M3 ISA (before F/D)
make -C tests/arch CFG=st ACTCFG=core-m3-rv64imafdc      # with F/D: the M3 exit configuration (plan §11)
make -C tests/arch replay ACTCFG=core-m3-rv64imac        # the same ELFs, Spike against Spike (tg_replay)
make -C tests/arch elfs ACTCFG=...                       # only generate and build the ELFs
make -C tests/arch clean
```

- **Steps:** `elfs` copies the framework's `tests/env` and committed privileged tests into the build tree, runs `testgen` for one list of test plans (the generated tests are not committed upstream), runs `act` (UDB validation, test selection, Sail, compilation; `--fast --clean-intermediates`) and deletes the sources again, keeping only the ELFs; `make -C tests/arch tests ACTCFG=...` regenerates the sources for debugging. `run` runs every ELF in `tg_vsim` with lockstep, 8 at a time (`tests/arch/run_arch.py`). The riscv-arch-test checkout is only read.
- **A pass** needs the test's own `RVCP-SUMMARY: TEST PASSED` and a passing run (lockstep and the `tohost` exit). The runner prints a table per suite; failing tests keep their logs in `$TANAGER_BUILD/<worktree>/arch/logs/<config>-<cfg>-<core>/`. `SIMARGS="..."` adds `tg_vsim` options (latency, stress); `exclude/<config>.txt` lists skipped tests with a reason each (all empty today).
- **Spike's configuration:** the `# spike:` line of `test_config.yaml` (ISA, privilege modes, PMP regions) configures the lockstep checker in `run` and the replaying Spike in `replay`; `SIMARGS` can override it.
- **`replay`** runs the same ELFs in `tg_replay` (§3.8) with those Spike options. Spike configured like the core must reproduce Sail's expected values, and the lockstep checker must pass, so this checks the configuration files themselves: every WARL choice in `sail.json` equals Spike's, and the core has to match Spike anyway.
- **Test plans:** `GEN_PLANS` in `tests/arch/Makefile` lists every plan a Tanager core could need through F/D (base and B, A, C, F, D, Zcd, Zicond and the other unprivileged extensions; Sm, S, U, the Exceptions, Interrupts and Ssstrict plans, Sstc, Sstvala, Sstvecd, Ssu64xl, Ssccptr, Sscounterenw, Za64rs, and the F privileged plans). `act` keeps the tests whose requirements the UDB file meets, so a configuration cannot miss a plan by omission. Not used: `Misalign` (needs hardware misaligned access) and `Sm1p13`, `Ss1p13`, `Endian*` (no generators yet). A configuration may add plans on a `# testgen:` line.
- **Rebuilds:** the ELFs are rebuilt when any file of the configuration, the link script, the shared macros or the Makefile change. Generation and Sail take about 90 s for the F/D configuration; its replay takes 7 s.

**Configurations** (`tests/arch/config/`):

| Configuration | For | Spike ISA, modes, PMP | Tests |
|---|---|---|---|
| `tcore-rv64im` | `tg_tcore` (§5) | `rv64im_zicsr_zicntr_zifencei`, MU, none | 315: I, M, Zmmul, Zicntr, Zicsr, Zifencei; Sm, U; ExceptionsSm, ExceptionsU, InterruptsSm; SsstrictSm, SsstrictU (1 excluded: a timing assumption the multi-cycle test core misses) |
| `core-m2-rv64im` | `tg_core` at M2 | the same, M, 16 | 259: the same without U, plus PMPSm (40), of which 16 need PMP checks and are excluded until M3 |
| `core-m3-rv64imac` | `tg_core` at M3 before its F/D integration | `rv64imac_…` (§3.2), MSU, 16 | 685: the above plus S, Zaamo, Zalrsc, Zca, Zba, Zbb, Zbs, Zicond, Zihintpause, Zihpm; the S, Zaamo, Zalrsc, Zc and Sv exception plans; InterruptsS; PMPS, PMPU, PMPZaamo, PMPZalrsc, PMPZca; Sv, SvPMP, SvSm, Svade, Svbare, Svinval; Sstc, SstcSm, Sstvala, Sstvecd, Ssu64xl, Ssccptr, Sscounterenw, Za64rs; SsstrictS |
| `core-m3-rv64imafdc` | `tg_core` at M3 with F/D (plan §11; the M3 exit criterion) | `rv64imafdc_…` (§3.2), MSU, 16 | 895: the above plus F (84), D (116), Zcd, ExceptionsF, SmF, UF, ZicsrF, PMPF |

Each directory holds `test_config.yaml` (tools, the `# spike:` line and an optional `# testgen:` line), the UDB file `<config>.yaml` (validated by `udb validate cfg`; it decides which tests apply), `sail.json`, and `rvmodel_macros.h`, which includes the shared `tanager_rvmodel.h`. The shared `link.ld` places RAM at `0x8000_0000` (256 MiB, the main-memory region of every `sail.json`).

**`sail.json`** is generated by `make_sail.py` (run it with the ACT venv's Python; never edit the output). It starts from the framework's `sail-RVA20S64` reference and overrides, per configuration:
- the memory map of `tg_map_pkg`: the device regions (ACLINT, PLIC, UART, host control, virtio, debug) as I/O without AMOs or reservations, and DRAM; Sail keeps its own boot ROM at `0x1000`, which the tests never touch;
- the extensions, and the misa bits software may clear (Spike's write mask: M, A, B, C, F, D within the ISA, so only M for the RV64IM configurations). Zmmul stays off in Sail, as in Spike's ISA strings, so clearing `misa.M` makes MUL illegal too. Ssstrict (unimplemented encodings and CSRs trap) is on in every UDB file; Sail accepts it only with S, and its defaults trap the same way without it;
- F/D: Sail's `Fflags_Dirty_Flag` policy, Spike's: `mstatus.FS` becomes Dirty whenever an instruction raises a flag (even one already set), writes an FP register or writes an FP CSR;
- the WARL choices that must equal Spike's: `mcountinhibit`, `mcounteren`, `scounteren` writable bits (CY, IR, and the HPM bits with Zihpm), HPM counters reading zero; `medeleg` causes 1–9, 12, 13, 15 and 19 (0 only without C) and `mideleg` SSIP, STIP, SEIP; `menvcfg.FIOM` writable with S; `mstatus.FS` with four states whenever S exists (even without F); WFI in U-mode legal only without S; `mtvec` and `stvec` 4-byte aligned in both modes;
- misaligned loads, stores, AMOs and LR/SC trap with address-misaligned (no Zicclsm), and an LR reserves its 64-byte block (Za64rs, as Spike), which a store does not cancel;
- privileged spec 1.13, Spike's (Sail allows `medeleg` bit 19 only from 1.13).

**The DUT macros** (`tanager_rvmodel.h`): halt by writing 1 (pass) or 3 (fail) to `tohost` as two 32-bit stores (§2.6); the console on the 16550 at `UART_BASE`; the CLINT's `msip`, `mtimecmp` and `mtime`, with a "soon" timer delay of 2,000 ticks (the U-mode variants reach M-mode through ecalls, which takes the multi-cycle test core about 250 ticks); external and supervisor software interrupts through the interrupt generator (§2.4); access faults at address 0, below the boot ROM.

**The interrupt generator instead of a PLIC model.** The plan here was a small PLIC model with the 16550's interrupt as its source. The interrupt tests only need software to raise and lower MEI, SEI and SSI, and Sail, which computes the expected values, has no PLIC but a "simple interrupt generator" register for exactly this; the framework's Sail macros use it. Modelling the same register in `tg_vsim` and `tg_replay` (§2.4, §3.8) took a few lines in each, gives the DUT and the reference identical macros and semantics, and drives `irq_ssi_i` as well, which a PLIC would not. A PLIC model can still be added for software that needs the standard PLIC (§9).

**Results on 2026-10-13:**
- Spike against Spike: `tcore-rv64im` 314/314 (1 excluded), `core-m2-rv64im` 243/243 (16 excluded), `core-m3-rv64imac` 685/685, `core-m3-rv64imafdc` 895/895. Getting there fixed `tg_replay` (the generator's SEIP handling, device loads under MPRV, the core's ID CSR values in place of Spike's `marchid` 5, §3.8) and settled the `sail.json` choices above.
- `tg_tcore` in `tg_vsim` with lockstep: 314/314 in `st` and in `st_w3`. The wider plan list found that the test core kept `misa.M` set where Spike lets software clear it (fixed, §5).
- `tg_core` is still the stub on this branch. The core track's M2 core (`claude/track-core-adb715`, not yet merged), built with this branch's harness in a scratch copy:
  - at `9154bae` with the first plan list: 113 of 129 in `st` and `st_w3`, also with 250-cycle latency, jitter, back-pressure and D-channel gaps. The other 16 are PMPSm tests in which Spike raises a PMP access fault that the core does not, because its PMP checks come in M3 (core-pipeline.md §1); `exclude/core-m2-rv64im.txt` lists them;
  - at `41be4a0` with the full list: 241 of 243 in `st` and `st_w3`, all 103 SsstrictSm tests included. `Sm_csr_ro-00` and `-01` fail in lockstep: at a trap-handler entry (`jal a5, 0x800061c4`), the core retires the instruction bits `0x00013203` (`ld tp,0(sp)`) at a PC whose memory holds `0x30e13823` (`sd a4,784(sp)`). That is a fetch bug for the core track; the test core passes the same tests.

**SC tests under memory stress:** with `--probe-rate`, a core may lose an LR's reservation and fail the SC, legally; lockstep adopts it (§3.4). ACT4's `Zalrsc-sc.*` tests retry a failed SC only when its destination is not `x0`: their retry loop tests the destination with `beqz`, which is always taken for `x0`. Their `rd = x0` cases then load memory that the failed SC did not write, and the self-check fails. Such a failure under probe stress is the test's limit, not the core's; without probe stress they pass. Shown in `tg_replay` with `--sc-fail=50`: lockstep passes, the self-checks of `Zalrsc-sc.w` and `Zalrsc-sc.d` fail.

**Known differences** that no test reaches today:
- A reserved `mtvec`/`stvec` mode (2 or 3): Spike and the core clear bit 1; Sail can only ignore the write or stop.
- Sail and Spike keep one `mip.SEIP` bit and one `mip.SSIP` bit that the generator and software both write; the core ORs `irq_sei_i` and `irq_ssi_i` with its software bits (interfaces.md §3), so while the generator's line is high, software cannot clear the bit. Measured in the replay over the M3 configuration's tests: no test clears SEIP by software while the generator's line is high (ACT4's handler would, only with `MEIP` pending at the same time). 23 interrupt tests clear SSIP that way, but only after disabling `mie.SSIE`, and they lower the generator's line about 20 instructions later without reading `mip` in between, so a core with the OR behaves the same. §9 has the interface question.

**Disk:** Sail 0.15 (pinned in `tools/versions.sh`, `$TANAGER_OPT/sail-0.15`, 11 MB), the framework's Python packages (`$TANAGER_OPT/act-venv`, 43 MB), the UDB gems (`$TANAGER_OPT/act-gems`, 74 MB, `bundle clean`), and UDB's cache in `~/.local/share/udb` (24 MB). The build tree keeps only the ELFs (about 25 MB for the test core and M2 configurations, 70 MB for M3 and 175 MB with F/D) and the logs of failing tests.

### 6.2 Constrained-random instruction generator

`tests/random/tg_rand.py` (implemented 2026-10-13; plan §9, §4.15) writes assembly programs that run bare-metal in M-mode, or in S-mode under Sv39 (`--vm`), and in lockstep. Spike checks every instruction, so the generator never predicts results.
- **Seeded:** a program is reproducible from its seed and options; failures print a one-line reproduction command (conventions §6).
- **Safe by construction:** x2–x4 (stack, data base, alias base) and x30/x31 (trap scratch) are never written; every address is masked into its region; branches go forward and loops have fixed counts (an LR/SC loop is bounded, so a core that keeps failing SC still ends).
- **Templates** (weighted), aimed at the plan's risk areas:
  - LSU: a store followed by loads of the same, contained or partially overlapping bytes, through the same or the other base; the same page offset on two pages (`gp`/`tp`, 16 KiB apart); a store whose address comes from a slow load (or a divide) while younger loads hit or miss it (ordering violations);
  - cache-miss streams over a 64 KiB region (larger than a 32 KiB L1), with stores in them, so lines are evicted dirty;
  - early retirement: a divide or a missing load, its consumers, then a data-dependent branch and sometimes a trap right behind it ("flush storms over pending retired loads");
  - traps the handler skips: misaligned loads and stores, `unimp`, `ecall`, `ebreak`, access faults (addresses below the boot ROM);
  - **width 3:** groups of three instructions in one 16-byte fetch block with RAW, WAW or WAR dependencies, two branches, or a load-use and a store (plan §4.15);
  - CSR reads (counters, `mstatus`, `mscratch`), fences, `fence.i`, calls and returns, and LR/SC and AMOs when A is in the ISA (bounded retry loops, and single LR/SC pairs whose SC writes `x0`);
  - **F and D** (ISAs with both, such as `rv64gc`): `mstatus.FS` starts at Initial, `frm` at a random mode, and every FP register at a special or random value: signed zeros, infinities, quiet and signalling NaNs with payloads, subnormals, extremes, NaN-boxed singles and a few unboxed ones. Templates: arithmetic and FMA in every static and dynamic rounding mode; conversions both ways, `fcvt` between widths, moves, compares and classify; FP loads and stores with FP/integer forwarding through memory, `flw` NaN-boxing and misaligned (trapping) accesses; `fflags`, `frm` (reserved modes 5–7 included, after which dynamic-rounding instructions trap) and `fcsr`, and windows with FS off; a divide or square root (a deferred writeback in the core) with dependents and a branch on an FP compare of its result; FP operations inside width-3 groups;
  - **the structures the FPGA-friendly rewrites touch** (2026-10-14, measured in §6.4):
    - register pressure: bursts that write two to four integer or FP registers over and over, so one rename group writes a register twice and reads it, with late completions, branches and exceptions in between (the rename maps);
    - store bursts: 8 to 24 stores in a 64-byte window, more than the store queue holds, with overlapping sizes, late data, loads that forward from deep entries, FP stores and a branch that may squash the youngest (the queue's LUTRAM payload);
    - every completion port at once: independent ALU, multiply, load, store, branch and FP operations, a few groups in a row (the ROB's per-port flag tables);
    - CLINT loads (MMIO, performed at the ROB head) with dependents and a branch on the value;
    - long-latency bursts: 12 to 28 independent divides, FP divides and square roots, and missing loads;
    - WFI in programs with `--irq`;
    - more traps: writes to read-only CSRs, a fetch from no memory (the handler returns through `x1`), misaligned LR, SC and AMOs, and loads, LR, SC and AMOs to two pages the stressed runs deny (`--deny`: a DRAM page and an unused device page). Stores do not go there: a denied fill for a committed store cannot be precise (core-lsu.md);
  - **`--vm PCT`:** that share of the programs runs its body in S-mode under Sv39. M-mode builds an identity map: the 2 MiB image in 4 KiB pages, the CLINT and the denied DRAM page in 2 MiB pages, every leaf with A and D set. So every template runs translated, with TLB misses and page walks; the stream region grows to 256 KiB (64 pages, twice the DTLB). A VM template adds page faults (an unmapped and a non-canonical address, a fetch from an unmapped page), `SFENCE.VMA` and loads one page apart. CLINT and device-page loads stay out of VM programs: `tg_replay`'s pre-check adopts device loads only untranslated (§9). M-level interrupts stay enabled in S-mode, so the trap handler's scratch registers (x30/x31) are not used for anything an interrupt could disturb;
  - `--irq=<ticks>`: CLINT timer interrupts during all of it; the handler re-arms the timer.
- **ISAs:** `rv64i`, `rv64im` (M2 and the test core), `rv64ima`, `rv64imac`, `rv64gc` (with the F/D templates). Programs for the integer ISAs are the same as before the F/D templates, seed for seed.
- **Spike against Spike only:** `make -C tests/random replay ISA=rv64gc [N=...]` runs each program in `tg_replay` twice: plain, then with checker perturbations drawn from the seed (deferral of loads, FP loads, divides and FP divides and square roots, up to 4 records per cycle, perturbed `nondet` values, SCs the core fails). That is how the F/D templates are checked until a core runs them; `make regress` runs 50 seeds (`RANDFD=N`). On 2026-10-13, 500 seeds passed (about 250 FP instructions retired per program, 26 of them deferred in a typical one).
- **Driver:** `make -C tests/random CFG=<cfg> [CORE=...] [N=100] [SEED=1] [ISA=rv64im] [IRQ=0] [STRESS=1]`; `run_random.py --vm PCT` for programs under Sv39 (the pre-check then runs Spike with S-mode), `--cov DIR` for coverage (§6.4). Each program is first run Spike against Spike, so a broken program is a generator failure, not an RTL bug. With `STRESS=1` (default) every seed also draws its memory-system settings (latency 30–250, jitter, backpressure, D gaps, `toB` grants, random probes), and the two denied pages are denied. Passing programs leave nothing behind; failures keep `.S`, `.elf`, log and the reproduction command in `$TANAGER_BUILD/<worktree>/random/<cfg>-<core>/failures/`. `make regress` runs 100 seeds (`RANDN=N` to change).
- **Results on 2026-10-13 with the test core:** 1,000 seeds with memory stress, and 300 with timer interrupts, deferred writebacks and multi-slot trace, in both `st` and `st_w3`, all pass (about 60 programs per second).
- **Does it find bugs?** Two bugs planted in the test core: an SRAIW that ignores shift-amount bit 4 failed 199 of 200 programs (riscv-tests: one test); a dirty eviction that sends the wrong data in its last beat failed all 200 programs, and every riscv-test still passed.
- **2026-10-14, the extended generator on the real core:** 1,300 programs in `st` and 100 in `smt2` (a third to half under Sv39, half with timer interrupts, all with memory stress, trace back-pressure and the denied pages) pass. On the way they found two harness bugs and no core bug: the bus model gave the agent the permissions of a denied Grant, and the Spike environment made denied DRAM non-reservable, so an SC without a reservation faulted there while the core (rightly) only fails it.

### 6.4 RTL coverage of random programs

`make -C sim CFG=st COV=1 [COV_UNITS="rename rob lsu"]` builds a separate `tg_vsim` with Verilator's line and expression coverage of those `rtl/core` units only. Verilator's `coverage_on` does not undo a `coverage_off`, so the build's configuration turns everything else off; a narrow scope keeps the build at about 80 s and the runs fast. `tg_vsim --cov=FILE` writes the counts, `run_random.py --cov DIR` one file per program, and `tools/ci/cov_report.py DIR [--save F] [--compare G]` merges them and reports, per file, the lines and expression term combinations reached (for example, two rename slots writing one register in a cycle), the ones never reached with their source lines, and what a campaign newly reached. Points no program can reach are counted apart: combinations of constants (`EXT_FD==0`, elaboration-time comparisons) and the failing side of assertions. So are points Verilator cannot measure, listed separately. These are an `if` that was taken although none of its condition's "=> 1" combinations was ever counted. It happens when the block reassigns one of the condition's terms inside the branch: Verilator samples the terms afterwards (`tg_rob`'s `ex_v` and `ex_r`, `tg_rename`'s `got` and `found`). **Event points** (`sim/cov/tg_core_events.sv`, bound into `tg_rob` in coverage builds of the product core) count conditions that none of the core's own expressions shows, as branches of their own; `+tg_events` prints them at the end of a run.

- **The measurement (2026-10-14):** core-2's branch with the FPGA-friendly rewrites (the XOR-banked rename map, the ROB's per-port flag tables in LUTRAM, the SQ's ROB index and size in LUTRAM), `st`, 300 programs with the soak's settings, the same seeds before and after the extension (reachable points only):

  | File | Lines before → after | Expressions before → after |
  |---|---|---|
  | `rename/tg_rmap.sv` (the XOR-banked map) | 100% → 100% | 100% → 100% |
  | `rename/tg_rename.sv` | 97.2% → 97.6% | 94.5% → 94.5% |
  | `rename/tg_rdytab.sv` | 100% → 100% | 91.1% → 92.4% |
  | `rob/tg_rob.sv` | 90.3% → 97.9% | 87.4% → 92.3% |
  | `lsu/tg_lsu.sv` | 82.6% → 91.6% | 88.4% → 98.3% |
  | `lsu/tg_dcache.sv` | 94.6% → 97.3% | 90.2% → 94.9% |

- **What it showed:**
  - The rename map was already fully reached, same-cycle writes to one register included.
  - The biggest gap was address translation: random programs ran in M-mode only, so none of the LSU's DTLB, page-walk and page-fault logic, nor the ROB's handling of a DTLB miss at its head, ever ran. `--vm` closes most of it.
  - Still unreached, for the core track to judge (§9): exceptions on the ROB's "other" completion port (illegal CSR writes are caught before it), a completion for a squashed entry, an `mret` path in the next-PC selection, rename running out of long-latency tags (probably unreachable in `st`, where the issue queues and the divider throttle first), branch exceptions (impossible with C), and a fetch fault on the second half of an instruction.
- **The core track's answers, re-measured on main with fn2** (2026-10-14; rename, ROB and CSR; 200 programs as the soak runs them):
  - **Two of the four were my errors.** The "other" port's exception is reached 1,169 times, and `mret`'s next-PC path 14,445 times. The ROB's exception capture reassigns `ex_v` and `ex_r` inside its branch, so Verilator never counted the combinations. `cov_report.py` now lists such points as not measurable.
  - **A completion for a squashed entry** is unreachable by design in M3: every recovery is a full flush, and reports in the flush cycle are dropped. The branch guards M6's partial flushes.
  - **Rename's wakeup tags** run out with MULs and FP-to-FP operations waiting on a missing load, not with divides or loads (those take long-latency tags). Random programs reached it twice; `t_tag_burst` takes it to 53,192 cycles, and `tag_short.S` is the directed test.
  - **SRET** (fn2 gives it MRET's next-PC path) was never retired. `t_sret`, in S-mode programs, retires it 340 times.
  - **The event points:**
    - the replay flag's XOR-banked tables saw no two valid setters at one entry, and no dispatch clear meeting a set, the two cases the core track expects never;
    - their guard's condition met an invalid second setter 257 times, which it handles;
    - an interrupt was taken with a CSR instruction at the head 12 times, 10 of them while it was in EX: the case the CSR unit's cold registers (xepc, xcause and xtval, written over three cycles) must handle.
  - **Steered (the core track asked):** `t_csr_burst` gives programs with timer interrupts runs of CSR accesses. These execute one at a time at the head, so interrupts meet them there: 80 per 200 programs (67 in EX), against 12.
  - **Confirmed on fn3** (the core track's 1c0eaca, which replaces the replay flag's guards with an assertion over valid writers): the two events stay at 0, and the 200 programs pass.

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
4. **SC failure adoption** (§3.4): interfaces.md §5 says the checker adopts the RTL's outcome "(the `rd` value)". For an SC with rd = x0 the outcome is the missing store, which the checker now uses for every SC; the interface could say "the `rd` value, or the missing store when rd is x0".
5. **ID CSRs:** `marchid`, `mimpid` and `mvendorid` reads are adopted (§3.4); the core track should still pick Tanager's values. ACT4 checks the values against Sail's configuration (0 today, as the core spec says); a nonzero choice must also go into `make_sail.py` (`platform.vendorid`, `archid`, `impid`) and `tg_replay` (`--marchid` and the others).
6. **Illegal-instruction `tval`:** Spike writes the instruction bits (16 bits for a compressed encoding without C), `ebreak` writes the PC; the core must do the same or the checker reports it.
7. **PLIC model:** ACT4's external-interrupt tests run with the interrupt generator (§2.4) instead of the small PLIC model planned in §6.1; the reasons are there. A PLIC model can still be added for software that needs the standard PLIC in the harness (OpenSBI does not). It would share the region with the generator's register (`0x0C00_0004` is source 1's priority in the PLIC layout); Sail's generator base is configurable and the framework passes it to the macros, so the generator would move.
8. **`irq_ssi_i` (interfaces.md §3):** the interface ORs the line into `mip.SSIP`, while the privileged spec says a platform controller may *set* SSIP to 1 (as the ACLINT SSWI does, and as Spike and Sail model it), after which software clears it. With a level, software cannot clear SSIP while the line is high. ACT4 is unaffected today (§6.1, known differences), and the platform ties the line to 0; defining `irq_ssi_i` as a one-cycle pulse that sets SSIP would match the spec before the SSWI arrives. `irq_sei_i` is fine as it is: SEIP is the OR by the spec.
9. **`TRACE_STALL_HEADROOM` (interfaces.md §5):** 2 × `COMMIT_WIDTH` + `LLT_ENTRIES` is enough only if the sink counts the current cycle's records when it decides to stall. A sink that stalls from its occupancy register needs `COMMIT_WIDTH` more (§2.9). The rule should say which, for the SoC track's trace streamer.
10. **The Linux boot in the cycle-identical check (§4.5):** built (`BOOT=N`). `sim/tb/tg_soc_sig.sv` is bound into `tanager_soc`, so `tb_boot` does not change. It can run from main once the SoC track merges `tb_boot`; until then `--boot-tree` takes it from the SoC branch. The bind names the SoC's ports, the trace AXI port the SoC branch added included, so a port rename in `tanager_soc` needs the same rename in `tg_soc_sig_bind.sv` (the build fails otherwise, and says so).
11. **`tg_replay` and translated device loads:** the replay marks a device load `mmio` only when it is untranslated, so under Sv39 a CLINT load reads different values in its two Spikes, and the pre-check of a random program would fail. The generator keeps device loads out of `--vm` programs (lockstep against the RTL is not affected: the RTL marks the load itself). Checking the translated physical address in the replay would lift it.
12. **Coverage gaps for the core track (§6.4):** answered by the core track on 2026-10-14. Two were measurement errors, now flagged by `cov_report.py`. One is unreachable by design until M6. Wakeup-tag exhaustion has a directed test and a generator template, and SRET a template. The fn2 replay-flag cases the core track expects never are counted by event points: none seen so far.
13. **FPGA lockstep and the SoC track's files (§3.9):** done. `tanager-host` 6466df0 zeroes the RISC-V window for `--trace`, keeps stdout for records with `--trace -`, caps a poll at 4,096 records and ends with exit 4 when the checker stops. With the SoC track's OK, `tb_boot`'s `+trace_out` and `tb_axi_mem`'s `+mem_zero` are on this branch. The `spike` item in `sw/fetch.sh` is on this branch as its own commit, offered to them.

## 10. Provenance

- TileLink message rules: TileLink Specification 1.8.1 (SiFive, public).
- The `tohost`/`fromhost` convention and the riscv-tests environment: riscv-tests (public test suite, used as-is).
- Spike's library interface (`simif_t`, `processor_t`, commit log): Spike's public headers and sources, used as a tool, not as a design reference.
- Fork-based snapshots: a common simulation technique; described here from first principles.
- ACT4 (riscv-arch-test, act4 branch): the framework, its test environment and test plans, the UDB configuration schema, and its Sail reference configuration `config/sail/sail-RVA20S64` (`sail.json` and the UDB file), which `make_sail.py` and our UDB files start from. The interrupt generator's register follows the framework's Sail macros (`tests/env/sail_macros.h`) and Sail's configuration schema. The configurations of other cores in the framework (`config/cores`) were not used.
- WARL choices in the ACT4 configurations: Spike's sources (`csr_init.cc`, `csrs.cc`, `mmu.cc`), read as the specification of the lockstep reference.
- No other core's RTL or testbench was read for any of this.

## 11. History and lessons

**Timeline.**
- **2026-10-13, M2:** `tg_vsim`, the TileLink models, Spike as a library, the lockstep checker, `tg_replay`, the test core, the runners and `make regress`, all merged before any core existed.
- **2026-10-13, M3 items:** fork snapshots; the random generator with width-3 groups; ACT4 with Sail, with configurations for the test core, M2 and M3, then F/D.
- **2026-10-13 and 14:** trace back-pressure (interfaces v1.3); F/D readiness; the first merges with the real core; the soak.

**What each piece bought.**
- **The checker, proven before the core.** Spike was replayed against itself over 326 riscv-tests, under deferral, perturbed `nondet` values, several harts and wide cycles. 270 injected faults of 19 kinds were all reported. Its first real catch was the test core dropping deferred writebacks when two deferred records left its queue in one cycle.
- **Random programs against riscv-tests**, on bugs planted in the test core:
  - an SRAIW that ignored shift bit 4 failed 199 of 200 programs and one riscv-test;
  - a dirty eviction that sent the wrong data in its last beat failed all 200 programs, while every riscv-test passed.
- **ACT4.**
  - Hand-picked plan lists covered only part of it: 97 tests for the test core, against 315 when every plan is generated and `act` selects (§6.1). The added tests found the test core's read-only `misa.M`, and a fetch bug in the core (`Sm_csr_ro`, still open).
  - Replaying every configuration Spike against Spike found three `tg_replay` bugs, and every place where Sail's choices had to be made to match Spike's: `medeleg` bit 19 needs privileged spec 1.13, Za64rs means 64-byte reservations, misaligned AMOs raise address-misaligned, Zmmul stays off, and Spike's `marchid` is 5.
- **On the real core:**
  - the core track's M2 core passed 113 of 129 ACT4 tests before its merge, then 241 of 243 with the full plan list;
  - `make regress` passes in all four configurations.
- **The soak, from 2026-10-14:** 40,960 programs on four successive main commits, in four configurations with every M3 switch on: no failures. By 11:30 the same day, 193,760 programs and still none; the last 100,000 or so were `rv64gc` with F/D, and the soak came back by itself after a WSL restart. Its failure path was checked with a simulator that drops records at stalls: 6 of 6 programs caught, each kept with its repro. After the build host ran out of memory (Vivado, at about 03:20) it gained a memory gate, an 8-simulation cap and a raised `oom_score_adj`.

- **The cycle-identical check (2026-10-14, §4.5),** for the FPGA-friendly rewrites:
  - **Planted changes showed its strength:** a store-address queue one entry smaller moved cycles in 559 of 796 programs. Some runs ended on the same cycle count with different timing on the way, which comparing cycle counts alone would miss.
  - **And its limit:** halving either TLB moved no cycle in any of 503 programs, because none filled a TLB. `tlb_stress` fills them now, and both changes show.
  - **Lesson:** a check is only as strong as its programs, and a structure that no program fills cannot show a difference. Stress a structure before rewriting it.

- **The boot in the cycle-identical check (2026-10-14, §4.5):** a signature module bound into `tanager_soc` runs the SoC track's `tb_boot` unchanged.
  - The SoC branch's merge of main's core area pass was identical over 3 M boot cycles with one `st` core, and over 2 M with two `smt2` cores.
  - A planted L2 change (the D FIFO from 8 entries to 4) showed at cycle 50,477.
  - **A worry checked rather than assumed:** the memory models draw their latencies from Verilator's shared random generator, so the order of the draws could move between two builds. With one Verilator thread, it moved neither with a core change nor with the instances declared in another order.
  - **After the SoC merge** (cfaa9c9), `make cycle-identical SUITES=none BOOT=20` ran from main's tree in 18.5 minutes.
  - **The worry came true with threads:** the core track saw two builds of the same RTL disagree in `tb_boot`. That happened only with `VTHREADS=4`, which the boot suite never uses; a stream per memory-model instance removes it.
  - **The shared cache raced (2026-10-14, found by the SoC track):** another worktree's check pruned a build between this check's look and its use, and the check died on `os.utime`. A check now holds a shared lock on each of its builds for its whole run. Pruning takes the lock exclusively without waiting, and re-checks the age once it holds it. Lock files are never deleted, since two checks could otherwise lock different files of one name. Lesson: "recently used" is a timestamp, not a lock.
  - **The boot became a default:** a change under `rtl/uncore`, `rtl/soc` or `rtl/common` now boots 3 M cycles with two cores. The coordinator's rule named the first two; `rtl/common` holds primitives and packages the uncore uses too. A comment-only crossbar change took 7.5 minutes for all 797 runs, the cache shared with another worktree's check of main.

- **Coverage-driven random programs (2026-10-14, §6.2, §6.4):** for the FPGA-friendly rewrites, a coverage build measured what 300 soak programs reach in core-2's rewritten rename, ROB and LSU.
  - The XOR-banked rename map was already fully covered. The real hole was address translation: no random program ever ran under Sv39, so the LSU's DTLB, page walks and page faults and the ROB's DTLB-miss handling went untested by random programs. `--vm`, store bursts, port collisions, MMIO, denied pages and fetch faults took the LSU from 88.4% to 98.3% of its reachable expression points and the ROB from 87.4% to 92.3%.
  - The new programs found two harness bugs, both in how denied memory is modelled (a denied Grant's permissions; denied DRAM as non-reservable), and no core bug.
  - **Lesson:** measure before writing tests. The intuition (stress the rename map) was wrong about where the gap was.
  - **The follow-up (the same day):** two of the four gaps I sent the core track were the tool's, not the programs'. An `if` reassigns its own condition's terms, so Verilator counts the combinations after the branch has changed them. A riscv-test that certainly reaches the point showed it in seconds. `cov_report.py` now flags such points. The other two were real: `tag_short.S` and two generator templates reach them now.
  - **Lesson:** "never reached" is a claim about the instrument as well. Before asking another track whether something can happen, run a program that surely makes it happen.

- **FPGA lockstep, the checker on the A53 (2026-10-14, §3.9):**
  - **Built and proven in simulation:** cross-built as a static musl binary (9.9 MB, under 3 minutes). In simulation it checked the SoC test, stopped exactly on a planted wrong value, and checked OpenSBI to its banner (3.09 M records).
  - **Profiled before the port,** since the A53 is several times slower than the build host. Half the checker's time went into Spike formatting a commit log for `/dev/null`. One in three of Spike's PMP-checked accesses was the checker's own compare fetch. Both fixes together made it 2.1× faster.
  - **The cross build first came out at 3 GB:** Spike's own flags carry `-g`.
  - **Lesson:** profile before porting to a slower machine. The time went where nobody looked: into a log file opened for writing that no one reads.
  - **On the board (the board session, the same evening):** the A53 checks 141–166 K records/s, 13.6 times slower than the 5950X. The first hardware trace (4.4 M records) had no AXI error, and the SoC test passed live. Linux stopped in the device tree's checksum, at the byte simulation had named (offset 0x90a: OpenSBI's unwritten free space). With the window zeroed, it booted to a root shell and powered off under lockstep: 335.8 M records, no mismatch, 57 minutes, about 290 times slower than unchecked. At 250 injected read cycles it did again: 355.6 M records, no mismatch, 61 minutes. That met M4's lockstep criterion.
  - **The board also tested the test:** `--plant` had landed on an MMIO load, whose value the checker adopts, so nothing could show and the run passed. It now plants only where the checker compares. On the board, `--plant=1000` then stopped live at record 1002, the `andi` after the UART poll. The checker exited 2, and `tanager-host` reported "trace consumer stopped" and exited 4.
  - **Lesson:** a self-test must aim where the checker looks, and say where it aimed.
  - **Lesson:** a simulated boot of the same images is worth running before the board, even at 4 K records/s. It named the board's first stop, and its cause, before the board reached it.

**Breaks at merges, and their fixes.**
- **`trace_stall_i`:**
  - the core track tied the port off for `tg_core` while the harness connected it under a define, so one build connected it twice;
  - then the test core's port, which existed only under a define, broke the SoC test's `.*` wrapper (PINNOTFOUND).
  - The fix puts the port in every build and connects it once. Lesson: never make a port conditional; other tracks instantiate the module.
- **`irq_s`:** a directed test that counts its interrupts exactly failed the self-test's random interrupt injection. Injection now goes only into the tests written for it.
- **`amo`:** the replay performed AMOs to devices, which the core faults (interfaces.md §2.4). The replay now models the core's rule.
- **SC with `rd = x0`:** adoption keyed on the `rd` value; the missing store is the real sign.
- **Builds:**
  - ccache served Verilator's precompiled header from another build, and GCC 15 crashed on it (`st_w3`);
  - a stale binary, plus an `ISA` variable leaking through the environment, rebuilt `tg_vsim` with the wrong Spike ISA, so every counter read failed lockstep.

**What was hard.**
- **Sail and ACT4:**
  - the dependencies: Ruby and the UDB gems, a Python venv, a pinned Sail;
  - test plans that must be generated, because they are not committed upstream;
  - Sail's macros replacing the DUT's in the reference runs;
  - making every WARL choice of Sail match Spike, which was only practical because `replay` checks the configuration files themselves.
- **SC adoption:** a core may fail any SC legally. ACT4's `rd = x0` SC cases cannot retry, so under probe stress they fail their own self-check even with lockstep passing.
- **Interrupts:**
  - Spike and Sail keep one SEIP bit and one SSIP bit that software and the interrupt generator share, while the core ORs a level line into each (§9);
  - the multi-cycle test core missed ACT4's timer windows until the "soon" delay grew from 100 to 2,000 ticks;
  - injected interrupts have to respect what each test expects.

**Dead ends.**
- The small PLIC model planned for ACT4: Sail's interrupt generator did the job with the same macros on both sides.
- ccache for precompiled headers.
- A conditional `trace_stall_i` port.
- Hand-picked ACT4 plan lists.
