# FPGA-friendly re-implementation (D18 step 1)

**Status:** started 2026-10-14 at the user's request (DR-123). Owner: the coordinator, with the core, FPU, SoC and spikes tracks.

**Goal.** Close v1's area gap by rebuilding units in the forms the FPGA provides natively, at zero IPC cost:
- LUTRAM;
- block RAM and UltraRAM;
- shift-register LUTs;
- DSP slices;
- carry chains.

Much of the core still holds state in flip-flops and builds lookups, searches and selects from LUT logic.

**The rules.**
1. **Zero IPC means cycle-identical.** A change must produce the same commit trace, cycle by cycle, as main on all riscv-tests, the benchmarks and a random set. This is the check the core track already uses. A change that moves any cycle goes on the reserve list (D18, DR-122), not into the RTL.
2. **Timing holds.** The unit closes 200 MHz out of context, and the next full-chip run confirms it.
3. **Measured, not estimated.** Every change reports LUT, LUTRAM, flip-flop, BRAM and DSP counts before and after, from the budget flow (DR-113's settings), per unit.
4. **Clean room (DR-001).** Ideas may come from published papers and talks; RSD's FPGA papers are a good source. Never read another core's RTL. Record the source of each idea in the unit's spec.
5. **Pros and cons are written down** for every technique adopted or rejected, in the unit's spec and as a register entry (DR-124).

## 1. Where we stand

| | LUTs | Share of the XCK26 (117,120) |
|---|---|---|
| 85% | 99,552 | |
| **88%: the 200 MHz ceiling (S6)** | **103,066** | |
| 90% | 105,408 | |
| Closed at 180 MHz (AR-5): v1 93.4% and 95.3%; v2 up to 96.0% | 109,364–111,616 (v1) | |
| **v1 today** (two SMT2 cores plus the uncore) | **about 132–141K** | 113–121% |

- **The range:** 141.3K is the fit after the core's second no-IPC pass (area_recovery.md §7.7). About 132K applies DR-113's settings (−7.9% at st) to the cores, if that run didn't already use them. The next measured fit settles it.
- **The gap:** about 27–38K to the 88–90% bar at 200 MHz.
- **What is free on the device:**
  - about 1,160 of 1,248 DSP48E2;
  - UltraRAM beyond the L2;
  - block RAM, to be confirmed from the utilisation report;
  - flip-flops, which aren't binding (234,240).
- **LUTRAM is limited to SLICEM sites:** about 57K LUTs of them (plan §8.5).

## 2. Techniques, with pros and cons

| # | Technique | Pros | Cons | Fits |
|---|---|---|---|---|
| T1 | **State into LUTRAM.** RAM64M8 (1 write, 7 reads, 64 deep), RAM32M16, RAM64X1D, through `tg_ram_lut`. | One LUT holds 64 bits in place of 64 flip-flops, and the read multiplexer comes free. It frees flip-flops and their control sets. | One write port per primitive. The read adds about 0.5 ns of LUT delay. The array can't be reset, so valid bits stay in flip-flops. Entries can't all be read at once (no parallel search or restore). Uses SLICEM sites. | Payload tables read by index: ROB fields, queue payloads, CSRs that are rarely written, map tables. |
| T2 | **More write ports from LUTRAM:** banking by writer, replication plus a live-value table (LVT), or XOR banking. | Keeps exact multi-port behaviour. | Area grows with writers × readers. The LVT or XOR adds logic and a little delay. | Rename map, physical register file (already LUTRAM), free lists. |
| T3 | **Block RAM or UltraRAM** for large tables (36 Kb, two ports, registered read). | Removes LUTs and flip-flops entirely, and the device has spare. | The registered read costs a cycle: only where the address is known a cycle early, so behaviour stays cycle-identical. Two ports per block. Small tables waste most of a block. | ROB payload read at commit, trace buffers, deep FIFOs, predictor tables. |
| T4 | **Shift-register LUTs** (SRL16/SRL32). | A 32-stage delay line fits in one LUT. | No reset; only one tap is readable; fixed or addressed depth. | Delay lines, pipeline payload that only travels, simple FIFOs. |
| T5 | **CAM in LUTRAM or block RAM.** The key is split into 5–6-bit slices, and each slice indexes a table of match vectors; the AND of the slices gives the hit. | Replaces N comparators of K bits each with a few RAM reads. | A write takes several cycles, to update every slice table: fine for refills, not for queues written every cycle. Masked or partial compares need extra tables. | TLBs (filled by the walker), PMP and PMA tables, other rarely written lookups. |
| T6 | **DSP48E2 as logic:** 48-bit pattern detect (equality), wide add, subtract and compare, counters, wide XOR. | Uses idle DSPs, and frees carry chains and LUTs. | DSPs sit in fixed columns, so routing is longer. The fast mode needs input or output registers, so this works only where the pipeline already has a register there. Adds DSP-column floorplanning. | Address comparisons whose operands are already registered, counters, wide adders (R1). |
| T7 | **Logic shaping:** priority encoders instead of arithmetic, F7/F8 muxes, one-hot selects, LUT6_2 pairs, fewer control sets, no reset on datapath registers. | Pure implementation; no behaviour change when done right. | Each saving is small. Needs per-module attribution to find. A changed reset can hide X-propagation bugs, so the lockstep must cover reset. | Everywhere; the core's passes already use it. |
| T8 | **Synthesis settings (DR-113):** a kept hierarchy plus `AreaOptimized_high`. | Free: −7.9% on the st core. | It can cost slack in critical units, and the directive alone failed timing by 0.265 ns. | The budget flow and the full chip. |

## 3. Where to look first (estimates, to be replaced by measurements)

| Unit (owner) | Over budget | Candidates |
|---|---|---|
| LSU/MMU (core) | +6.8K after the second pass | TLB entries as LUTRAM CAMs (T5); PMP and PMA tables in LUTRAM; the remaining queue payload in LUTRAM (T1); address compares in DSPs where their operands are registered (T6) |
| Rename (core) | +4.3K | Map table and free list in LUTRAM with LVT or replication (T1, T2). Checkpoints as LUTRAM copies selected by a version pointer, not flip-flop snapshots: a restore must stay one cycle. |
| ROB and CSRs (core) | +3.2K | ROB payload (PC, destination, exception and trace fields) in LUTRAM or block RAM, read ahead of commit (T1, T3); rarely written CSRs in LUTRAM behind the serialized CSR port (T1) |
| P4 and execute (FPU agent) | +1.2K and +1.1K | Continuing; DSPs for wide add and compare (T6) |
| Crossbar (SoC) | +4.4K | One-hot AND-OR selects with F7/F8 (T7); request payload in LUTRAM FIFOs (T1) |
| Trace (SoC and core) | +2.9K uncore, 1.5K per core | Trace FIFOs in block RAM or SRL (T3, T4); dropping it in release builds is the last reserve lever (DR-121) |
| Host bridge (SoC) | +1.7K | Buffers in block RAM (T3) |
| Shared primitives (spikes) | — | Build, verify and price `rtl/common/prim` blocks for T2, T5 and T6, and an SRL FIFO, at 200 MHz. Publish a cost table, so unit owners pick from measured numbers. |

## 4. Results

| Date | Unit | Change | LUTs | Flip-flops | LUTRAM / BRAM / DSP | Cycle-identical | Slack | Decision |
|---|---|---|---|---|---|---|---|---|
| | | | | | | | | |

## 5. History and lessons

- **2026-10-14:** started after AR-7 showed v1 about 50K over. The planning estimates had assumed FPGA-native structures that the first RTL did not use.
