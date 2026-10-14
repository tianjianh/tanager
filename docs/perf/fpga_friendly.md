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

Budget flow (DR-113 settings), each unit synthesised alone, st; LUT changes against HEAD bf914f1 (FPU track). Cycle-identical means `cyc_cmp.py` against simulators built from bf914f1: 310 ELFs natively, 309 under memory stress, 895 ACT4, st and smt2. Slack is out of context at 200 MHz: P4 with its DR-119 floorplan, Execute with the load result at 1.0 ns. Details: [fpu.md](../spec/fpu.md), "DR-123, FPGA-native pass".

| Date | Unit | Change | LUTs | Flip-flops | LUTRAM / BRAM / DSP | Cycle-identical | Slack | Decision |
|---|---|---|---|---|---|---|---|---|
| 2026-10-14 | P4 (FMA) | hi + 1 above bit 112 in DSPs fed by their own copy of E1's addend register (T6) | −54 | +54 | DSP +2 | yes | P4: +0.130 (smt2), +0.089 (st) | **Adopted.** Pros: −54 LUTs, off E2's critical path; the XOR shares the addend's OR LUT. Cons: 2 DSPs; a second copy of 54 register bits. |
| 2026-10-14 | P4 (divider) | 2^44 − x·y0² in the SMa low tile's own ALU (T6, existing DSP) | −38 | 0 | — | yes | as above | **Adopted.** Pros: −38 LUTs, no new DSP, a shorter path. Cons: the tile's arithmetic is less obvious; the spec now says it. |
| 2026-10-14 | P4 (divider) | the remainder's sign and zero test from a 38-bit subtraction with the low part's borrow, not 96 bits (T7) | −22 | 0 | — | yes | as above | **Adopted.** Pros: −22 LUTs, a shorter F0 path. Cons: it depends on the remainder being small (it is, by construction); the first version got the modular wrap wrong, and the back-end bench caught it. |
| 2026-10-14 | P4 (divider) | F2 pack adders in DSPs (T6) | −4 | — | DSP +3 | — | — | **Rejected.** Pros: −4. Cons: 3 DSPs; incrementers already cost almost nothing beyond their carry chain. |
| 2026-10-14 | P4 (divider) | c − grid in DSPs (T6) | −14 | — | DSP +2 | — | — | **Rejected.** Same reason as the pack adders. |
| 2026-10-14 | Execute (branch) | pc + 2 or 4 in DSPs with their own copy of the RF → EX register (T6) | −50 | +66 | DSP +2 | yes | Execute: +0.025 (st), +0.006 (smt2) | **Adopted.** Pros: −50 LUTs. Cons: 2 DSPs; the PC copy. |
| 2026-10-14 | Execute (ALUs) | logic ops and lui through the adder; an encoded 4:1 result select (T7) | −61 | 0 | — | yes | as above | **Adopted.** Pros: −61 LUTs over two ALUs. Cons: about 0.07 ns more through the ALU alone (+1.39 against +1.46 ns). |
| 2026-10-14 | Execute (ALUs) | a hand-instantiated CARRY8 chain for add, sub and logic | +129 per ALU alone, 0 in context | — | — | (bench) | — | **Rejected.** Synthesis already packs these functions; the explicit chain needs a LUT per bit for generate. |
| 2026-10-14 | Execute (MUL) | M3's select folded into the bank-1 write multiplexer (T7) | −64 | +64 | — | yes | as above | **Adopted.** Pros: −64 LUTs. Cons: M3 holds the 128-bit product; the select now lives in `tg_exec`. |
| 2026-10-14 | Execute (Zbb unit) | computed a cycle later (the result waits two cycles anyway) | 0 | +64 | — | yes | as above | **Adopted for timing.** Pros: takes the load bypass, the counts and ALU1's flag out of one cycle. Cons: 64 flip-flops. |
| 2026-10-14 | Execute (divider) | NM shift amount ~(lzd − lza) with no adder in front; no-quotient case in FX | +75 | +1 | — | yes | as above | **Adopted for timing.** Pros: the divider's NM step leaves the failing paths. Cons: +75 LUTs (every faster form measured +58 to +75). |
| 2026-10-14 | Execute (branch) | misprediction test as taken ? target ≠ pred : seq ≠ pred | +52 | 0 | — | yes | as above | **Adopted for timing.** Pros: the taken flag skips the next-PC multiplexer and a compare. Cons: a second 64-bit compare. |

## 5. History and lessons

- **2026-10-14:** started after AR-7 showed v1 about 50K over. The planning estimates had assumed FPGA-native structures that the first RTL did not use.
- **2026-10-14, FPU track (P4 and Execute):**
  - P4 7,386 → 7,273 and Execute 7,944 → 7,892 LUTs, both cycle-identical, with 4 more DSPs.
  - The DSP measurements set a rule of thumb for T6. An incrementer or a constant add costs almost nothing beyond its carry chain, so it is not worth a DSP. An adder whose operand bits come from LUT logic saves about a LUT per bit.
  - Inference needs `(* use_dsp = "yes" *)` on a module, with the operand register inside it under the kept hierarchy (`tg_fpu_dsp_add`).
  - A hand-mapped carry chain lost to synthesis (+129 LUTs).
