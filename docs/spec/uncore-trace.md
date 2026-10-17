# Commit-trace streaming (`tg_trace_stream`)

Status: implemented — soc track — 2026-10-14

## Purpose

Writes the commit trace of every core (interfaces.md §5) into a ring buffer in DDR, without losing a record, for the lockstep checker on the A53 (plan §7.4, §9: "FPGA lockstep"). The same stream, wrapping, is the post-mortem trace.

It replaces the block-RAM trace ring (`tg_trace_ring`, [host.md](host.md) §Trace ring):
- **Lossless:** the ring dropped records beyond `COMMIT_WIDTH` per cycle and cannot feed a checker. The stream stalls the cores instead (`trace_stall_i`, interfaces.md v1.3 §5).
- **Block RAM:** the ring takes 9 RAMB36 at 2-wide; the uncore's whole block-RAM budget is 18 ([docs/perf/budgets.md](../perf/budgets.md)), of which the L2 directories take 13 and the latency injectors 4. The stream's buffers are LUTRAM.
- **Depth:** the DDR ring holds millions of records instead of 1,024.

**A build switch** (DR-146): `+define+TG_COMMIT_TRACE=0` (`tg_trace_pkg` `COMMIT_TRACE`; FPGA builds through `build.tcl`'s `TG_DEFINES`) builds the SoC without the trace, for timing, fit and performance builds; unset or 1 builds it, as lockstep, the cycle-identical tool and the board's lockstep need. Without it, `tg_uncore` (`TRACE`) has no `tg_trace_stream`: the trace inputs are ignored, `trace_stall_o` is 0, the trace master stays idle (`AWVALID` and `WVALID` 0, `BREADY` 1), so the path to `S_AXI_HP3_FPD` is constants and the port, still in the block design, never sees a write; the host bridge's `CAPS[3]` reads 0 and its `TRS_*` registers read 0 and ignore writes. Commit behaviour is the same: a core retires the same instructions in the same cycles, unless the stream was slowing it (`trace_stall_i`), which it can only while the host has it enabled (`TRS_CTRL[0]`). The cores' side (no trace records, no extra register-file read ports) is the core track's.

The price is speed while tracing: the stream writes one 64-byte record per four beats of a 128-bit port, about 25 million records per second at 100 MHz, so a core that retires faster is slowed to that rate. The A53 checker is slower still. Capture can therefore start at a trigger, so a run reaches the point of interest at full speed (§Behaviour).

## Interface

| Port | Dir | Meaning |
|---|---|---|
| `trace_i`, `trace_valid_i` | in | per core, `COMMIT_WIDTH` `tr_rec_t` slots (interfaces.md §5) |
| `trace_wb_i`, `trace_wb_valid_i` | in | per core, `TRACE_WB_PORTS` `tr_wb_t` slots |
| `trace_stall_o` | out | per core, to the core's `trace_stall_i`; a function of registered state only |
| AXI4 write master | out | AW, W, B (no reads); 128-bit data, 40-bit address, one ID; bursts of 4 beats, INCR, one burst per record |
| configuration | in | from the host bridge (quasi-static except `rp`): enable, wrap, triggers, ring base and size, read pointer |
| status | out | write pointer, capture state, stall-cycle count |

All in `clk` (the core clock). The AXI master reaches the PS through its own port (`S_AXI_HP3_FPD`, [soc.md](soc.md)), so tracing does not share bandwidth with the L2 banks or distort the latency injector.

## Behaviour

### Capture path, per core

```
trace slot 0 ──► bank R0 (LUTRAM FIFO, 32) ─┐
trace slot 1 ──► bank R1                    │
wb port 0    ──► bank W0                    ├─► drain ─► format (64 B) ─► arbiter (cores) ─► AXI writer
wb port 1    ──► bank W1                    │
valid masks  ──► order FIFO (64) ───────────┘
```

- **Banks, one per trace port.** Each `COMMIT_WIDTH` retire slot and each `TRACE_WB_PORTS` writeback port writes its own single-write FIFO, so no record is ever moved between lanes: there are no compaction or rotation multiplexers on 320-bit records.
  - Retire banks hold the 320-bit record format of [host.md](host.md) §Trace ring (value and cause share a field, as do address and tval).
  - Writeback banks hold the `tr_wb_t` fields (77 bits at `smt2`), widened to the 320-bit format on the way out.
- **Order FIFO.** Every cycle with at least one valid record pushes its valid mask (`COMMIT_WIDTH + TRACE_WB_PORTS` bits). The drain pops a mask and takes one record per step from the banks it names: retire slots in slot order (interfaces.md §5: a lower slot is older), then writeback ports. A writeback therefore always follows the retire record that deferred it, which came in an earlier cycle.
- **Stall rule** (`trace_stall_o[c]`), while capture runs. It is a compare of the registered occupancies, and it is asserted when any of these holds:
  - a retire bank has fewer than 3 free entries. A slot adds at most one record per cycle. The cycle in which the stall rises still brings records, which the bank counts only at the next edge, and the core may retire in the cycle after (interfaces.md §5). That is three cycles of records;
  - a writeback bank has fewer than `LLT_ENTRIES + 3 × COMMIT_WIDTH` free entries. Writebacks are not stalled; after the stall takes effect at most the outstanding long-latency tags, plus those of the three cycles that still retire, can report;
  - the order FIFO has fewer than `LLT_ENTRIES + 3 × COMMIT_WIDTH + 3` free entries.

  This is the interface's rule for a sink that stalls from its occupancy register: 3 × `COMMIT_WIDTH` + `LLT_ENTRIES`, verification.md §2.9. `TRACE_STALL_HEADROOM` (2 × `COMMIT_WIDTH` + `LLT_ENTRIES`) is enough only for a sink that counts the current cycle's records combinationally. It is applied to each lane, with the writeback bound counted conservatively. While capture is off, `trace_stall_o` is 0.

### Records in DDR

- **Record:** 64 bytes, written as one 4-beat burst.
  - Bytes 0–39: the 320-bit record of [host.md](host.md) §Trace ring (header, insn, pc, value, address, store data); writebacks use kind 3.
  - Bytes 40–43: the low 32 bits of the `clk` cycle count when the record was captured.
  - **Order across harts:** each core's records keep their order, but the arbiter takes one record from each core in turn, so the stream is not in cycle order across cores. One hart's records can arrive a few hundred cycles behind another's. A consumer that needs the global order sorts by the capture cycle; `tanager-lockstep` merges the harts' records by cycle (`--reorder`).
  - Bytes 44–63: zero (reserved).
- **Ring:** `2^SIZE_LOG2` records from `BASE` (PS physical address, 64-byte aligned, inside the carve-out). Record n goes to `BASE + (n mod 2^SIZE_LOG2) × 64`.
- **Pointers:** 64-bit record counters.
  - `WP` (hardware): records whose write response has returned, so the host may read every record below it.
  - `RP` (host): records the consumer is done with.
- **Flow control.** Without wrap, a record is written only while `issued − RP < 2^SIZE_LOG2`; otherwise the drain waits, the banks fill and the stall rule holds the cores. With wrap, `RP` is ignored and the ring overwrites the oldest records.
- **Cores share one ring.** Each record carries its hart in the header. Records of different cores interleave in arrival order; per hart they are in program order.

### Capture control

- **Enable:** 0 → 1 clears the counters and pointers and starts. 1 → 0 stops taking records. The banks still drain, and `WP` keeps counting until they are empty.
- **Start trigger** (optional): capture begins with the first record whose pc equals `START_PC`. Until then the cores run unstalled and nothing is written.
- **Stop trigger** (optional): capture stops `POST` records after the first record whose pc equals `TRIG_PC`. With wrap, the ring then holds the records leading up to the trigger, as the old block-RAM ring did.
- **Modes in practice:**
  - lockstep: no wrap, with the checker advancing `RP`;
  - post-mortem: wrap and a stop trigger;
  - a window: a start trigger, no wrap, and the host reading the result.

### AXI writer

- One AW per record, then its four W beats. Address and data come from the drain's record register.
- Up to 16 records may be outstanding. B responses are counted, and `WP` advances by the number of records whose B returned.
- An error response sets a sticky error bit; the record counts as written.
- Only one ID is used, so responses return in order.

### Host registers

The registers replace `TRACE_*` at `0x1000`–`0x1064` in the host window ([host.md](host.md)). The host reads records directly from DDR (`/dev/mem` mapping of the carve-out).

| Offset | Name | Access | Reset | Meaning |
|---|---|---|---|---|
| `0x1000` | `TRS_CTRL` | RW | 0 | `[0]` enable, `[1]` wrap, `[8]` stop trigger armed, `[9]` start trigger armed |
| `0x1008`/`0x100C` | `TRS_TRIG_PC` lo/hi | RW | 0 | stop-trigger pc |
| `0x1010` | `TRS_POST` | RW | 0 | records kept after the stop-trigger record |
| `0x1018`/`0x101C` | `TRS_START_PC` lo/hi | RW | 0 | start-trigger pc |
| `0x1020`/`0x1024` | `TRS_BASE` lo/hi | RW | 0 | ring base, PS physical address, 64-byte aligned |
| `0x1028` | `TRS_SIZE_LOG2` | RW | 0 | ring size, log2 of records (at most 26) |
| `0x1030`/`0x1034` | `TRS_RP` lo/hi | RW | 0 | records consumed (written by the checker) |
| `0x1038`/`0x103C` | `TRS_WP` lo/hi | RO | | records written and complete |
| `0x1040` | `TRS_STATUS` | RO | | `[0]` capturing, `[1]` started, `[2]` stopped by the trigger, `[3]` waiting for `RP`, `[4]` AXI error, `[31:16]` records in the banks |
| `0x1044` | `TRS_STALLS` | RO | | cycles in which any core was stalled by the stream (low 32 bits) |
| `0x1048` | `TRS_INFO` | RO | | `[7:0]` record bytes (64), `[15:8]` cores |

## Parameters

- `N_CORES`, `COMMIT_WIDTH`, `TRACE_WB_PORTS`, `LLT_ENTRIES` size the banks and the stall thresholds.
- The lane depth is 32 entries. A RAM32M16 costs the same at 8 as at 32. The writeback lanes need it: their threshold is 30 at `smt2` 2-wide.
- At `smt2_w3` the writeback threshold (24 + 9 = 33) needs 64 entries (RAM64M8); the depth follows from the thresholds.

## Timing and area

- **Area per core** (estimate, 2-wide `smt2`):
  - banks: 2 × 23 + 2 × 6 RAM32M16 = 464 LUTs of LUTRAM;
  - the drain multiplexer over four heads: about 320 LUTs;
  - order FIFO and control: about 150.

  So about 0.95K per core, plus about 0.3K for the formatter and the AXI writer: about 2.2K for two cores. The block-RAM ring cost about 1.3K LUTs and 9 RAMB36 for one selected core.
- **Timing:** bank writes come straight from the trace ports (one bank per port, no multiplexers). `trace_stall_o` is a compare of registered pointers. The drain's head multiplexer and the 4:1 beat select are registered before the AXI ports.
- **Release builds:** the stream is debug infrastructure. A parameter (`TRACE_STREAM`) leaves it out, with `trace_stall_o` tied to 0, if the release budget needs the LUTs (a coordinator decision).

## Verification

`tests/unit/trace_stream`:
- A core model honours `trace_stall_i` exactly as interfaces.md §5 says: registered, retiring in the cycle after the input rises, writebacks never stalled, at most `LLT_ENTRIES` outstanding.
- It emits random retire, trap, interrupt and deferred-writeback records at full width.
- The AXI slave model has random back-pressure and latency.
- **Checks:**
  - every record reaches DDR exactly once, in per-hart program order, with each writeback after its retire record;
  - no bank overflows (assertion);
  - without wrap, nothing unread is overwritten;
  - with wrap and a stop trigger, the ring holds exactly the expected tail;
  - the start trigger skips everything before the pc;
  - `WP` only counts completed writes.

`tests/unit/soc`: the `tcore` run streams the bare-metal program's trace into the memory model, and the testbench checks the records against the program.

## History and lessons

- **Before:** a block-RAM trace ring in the host bridge (`tg_trace_ring`).
  - It traced one selected core and kept the last 1,024 records.
  - It dropped records beyond `COMMIT_WIDTH` per cycle.
  - It cost 449 LUTs and 9 RAMB36 equivalents (8 RAMB36, 2 RAMB18) at smt2, plus about 2.7K FFs of record readback in the host bridge.
- **This unit** (fca6fe8):
  - lossless through `trace_stall_i`, every core, records into DDR;
  - 2,853 LUTs for two cores and no block RAM. The host bridge fell by 1,668 LUTs, so the uncore's net change is +732 LUTs and −9 RAMB36.
  - The estimate was 2.2K for the stream; it measured 2.85K, with no breakdown by block yet.
- **Stall headroom:** the thresholds first used interfaces.md's `TRACE_STALL_HEADROOM` (2 × `COMMIT_WIDTH` + `LLT_ENTRIES`).
  - The SoC run with the test core overflowed a retire lane. The stall is computed from registered occupancy, so the records of the cycle in which it rises are counted only at the next edge, and the core retires once more after that.
  - The thresholds are now 3 × `COMMIT_WIDTH` (+ `LLT_ENTRIES` for writebacks), as verification.md §2.9 states for this kind of sink.
  - The unit test's core model now delays the stall by two stages, the test core's default, so it catches the smaller margin.
- **Lesson:** a core model in a testbench should take the latency the real core actually has (here the test core's `+tcore_stall_lat`), not the minimum the interface allows. The minimum hid the margin bug.

## Provenance

- Requirements: plan §7.4 and §9 (FPGA lockstep), interfaces.md §5 (records, `trace_stall_i` rule).
- Per-lane FIFOs with an order queue: a standard multi-producer FIFO arrangement (each producer writes its own queue; a sequence of per-cycle masks restores the global order).
- AXI4 bursts follow the AMBA AXI protocol specification (IHI 0022).
- No other core's RTL was read for this unit.
