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
1. **Zero IPC means cycle-identical.** A change must produce the same commit trace, cycle by cycle, as main on all riscv-tests, the benchmarks and a random set. This is the check the core track already uses. A change that moves any cycle goes on the reserve list (D18, DR-122), not into the RTL. **Only the user adopts a reserve lever, one at a time (DR-135):** list each with its LUT saving and its measured cycle cost per suite (`make cycle-identical` reports it).
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
- **What is free on the device** (v1 = two smt2 cores plus the uncore, from the latest unit builds, 2026-10-14: the core track's `core_smt2` budget run and the SoC track's `uncore_st`; no full-chip build with real cores yet):

  | Resource | Core (smt2) | Uncore | v1 | XCK26 | Free |
  |---|---|---|---|---|---|
  | Block RAM (RAMB36 equivalents) | 48.5 (48 + one RAMB18) | 18 (16 + four RAMB18) | 115 | 144 | **29** (20%) |
  | UltraRAM | 0 | 32 (the 1 MiB L2) | 32 | 64 | **32** (50%, 288 Kb each) |
  | DSP48E2 | 53 (MUL 16, P4 35, 2 more) | 1 | 107 | 1,248 | **1,141** (91%) |
  | Flip-flops | 22,514 | 18,021 | 63,049 | 234,240 | 171,191 (73%) |

  - v2's cores (`core_smt2_w3`) use the same block RAM and DSPs (48.5 and 53).
  - LUTRAM can only use SLICEM sites, about 57K of the 117K LUTs (plan §8.5); v1's LUTRAM takes about 16.8K of them today (7,016 per core, 2,816 in the uncore). Those sites also hold logic, so LUTRAM that replaces logic does not need room of its own, but a design with over about 57K LUTs of LUTRAM cannot place.

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
| P4 and execute (FPU agent) | measured 10-14: P4 +215 (st), execute −85 | P4: the FP bank select in the core's trace and store-data multiplexers (−96, proposed to the core track) or the trace ports (DR-121); the URAM operand ports failed gate 3 (DR-133); execute: none needed |
| Crossbar (SoC) | +4.4K | One-hot AND-OR selects with F7/F8 (T7); request payload in LUTRAM FIFOs (T1) |
| Trace (SoC and core) | +2.9K uncore, 1.5K per core | Trace FIFOs in block RAM or SRL (T3, T4); dropping it in release builds is the last reserve lever (DR-121) |
| Host bridge (SoC) | +1.7K | Buffers in block RAM (T3) |
| Shared primitives (spikes) | — | Build, verify and price `rtl/common/prim` blocks for T2, T5 and T6, and an SRL FIFO, at 200 MHz. Publish a cost table, so unit owners pick from measured numbers. |

### 3.1 Shared primitives: measured cost (spikes track)

Four building blocks in `rtl/common/prim`, for unit owners to pick from:
- **Verified** against reference models, on the behavioural model and on primitive models (`make -C tests/unit/prim test`). The DSP mapping also ran on the vendor's DSP48E2 simulation model under Icarus, and the RAM64X8SW model matches the vendor's. Each test catches deliberately broken versions of its module.
- **Priced** by one synthesis per family with DR-113's settings (hierarchy kept, `AreaOptimized_high`), every configuration side by side, so each instance's count is exact (`fpga/spikes/rtl/tg_prim_eval.sv`; `fpga/spikes/scripts/prim_price.py` prints the tables). Counts are after `opt_design`, before placement.
- **Timed** out of context at 200 MHz between input and output registers, at the largest size priced (the timing tops in the same file).
- The idea sources are in each module's header (published papers only, DR-001).

**T2: `tg_ram_lut_mw`, more write ports from LUTRAM.** LUTs (of which LUTRAM). The LUTRAM forms use no flip-flops; the flip-flop LVT uses depth × log2(writers) flip-flops, and the flip-flop array depth × width.

| Depth × width | Writers × readers | LVT in LUTRAM | XOR | LVT in flip-flops | Flip-flop array |
|---|---|---|---|---|---|
| 32 × 8 | 2 × 4 | 100 (64) | 99 (48) | 172 (48) | 481 |
| 32 × 8 | 2 × 8 | 180 (112) | 179 (96) | 256 (80) | 769 |
| 32 × 8 | 4 × 4 | 191 (128) | 207 (128) | 338 (96) | 910 |
| 32 × 8 | 4 × 8 | 327 (224) | 335 (224) | 506 (160) | 1,198 |
| 32 × 32 | 2 × 4 | 308 (176) | 387 (192) | 332 (160) | — |
| 32 × 32 | 2 × 8 | 596 (336) | 659 (336) | 576 (304) | — |
| 32 × 32 | 4 × 4 | 511 (352) | 783 (512) | 658 (320) | — |
| 32 × 32 | 4 × 8 | 967 (672) | 1,231 (832) | 1,146 (608) | — |
| 64 × 8 | 2 × 4 | 132 (96) | 147 (96) | 312 (80) | 900 |
| 64 × 8 | 2 × 8 | 260 (192) | 259 (176) | 476 (160) | 1,444 |
| 64 × 8 | 4 × 4 | 289 (224) | 337 (256) | 556 (160) | 1,904 |
| 64 × 8 | 4 × 8 | 553 (448) | 529 (416) | 884 (320) | 2,448 |
| 64 × 32 | 2 × 4 | 452 (320) | 563 (368) | 584 (304) | — |
| 64 × 32 | 2 × 8 | 884 (624) | 995 (672) | 1,004 (592) | — |
| 64 × 32 | 4 × 4 | 833 (672) | 1,297 (1,024) | 1,100 (608) | — |
| 64 × 32 | 4 × 8 | 1,609 (1,312) | 2,033 (1,632) | 1,940 (1,184) | 9,808 |
| 128 × 8 | 2 × 4 | 277 (192) | 287 (192) | 612 (160) | 2,146 |
| 128 × 8 | 2 × 8 | 541 (384) | 511 (352) | 956 (320) | 3,234 |
| 128 × 8 | 4 × 4 | 623 (448) | 715 (512) | 1,128 (320) | 4,224 |
| 128 × 8 | 4 × 8 | 1,191 (896) | 1,131 (832) | 1,816 (640) | 5,312 |
| 128 × 32 | 2 × 4 | 917 (640) | 1,095 (736) | 1,204 (608) | — |
| 128 × 32 | 2 × 8 | 1,789 (1,248) | 1,959 (1,344) | 2,108 (1,184) | — |
| 128 × 32 | 4 × 4 | 1,807 (1,344) | 2,779 (2,048) | 2,312 (1,216) | — |
| 128 × 32 | 4 × 8 | 3,495 (2,624) | 4,379 (3,264) | 4,120 (2,368) | — |

The flip-flop array at 64 × 32 with 4 writers and 8 readers is 9,808 LUTs and 2,048 flip-flops.

- **Behaviour:** asynchronous reads, like `tg_ram_lut` (old data until the clock edge). When writers hit the same address in one cycle, the highest-numbered one wins, so writers in program order behave like the youngest write.
- **The LVT held in XOR-coded LUTRAM is the cheapest form almost everywhere:** 4–7× fewer LUTs than a flip-flop array (64 × 8, 4 writers × 8 readers: 553 against 2,448; 64 × 32: 1,609 against 9,808), and no flip-flops.
- **XOR banking** ties with it at 8 bits wide and costs up to about 55% more at 32 bits: every bank is full width and needs writers − 1 extra read ports.
- **The flip-flop LVT** (the classic form) costs more than the LUTRAM one at 23 of the 24 shapes (the exception: 32 × 32 with 2 writers and 8 readers, by 20 LUTs). Its DEPTH:1 read multiplexers per port dominate.
- **Timing at 200 MHz** (128 × 32, 4 writers × 8 readers, placed and routed): the LVT in LUTRAM closes with **+1.075 ns** (3,487 LUTs), the flip-flop LVT +0.503, XOR +0.500, the flip-flop array +0.325 (17,634 LUTs). The worst path of the LUTRAM forms is a write address fanning out to its bank's primitives (0 levels, 3.7 ns of wire), not a read.
- **Decision (proposed): the LVT in LUTRAM for multi-write tables** (rename maps, free lists).
  - *Pros:* 77–85% fewer LUTs than flip-flops, no flip-flops, asynchronous reads like a flip-flop array, so a drop-in that keeps the cycle behaviour.
  - *Cons:* uses SLICEM sites; contents have no reset (valid bits stay in flip-flops); no single-cycle copy of all entries (a checkpoint needs its own copy or a version pointer); XOR coding needs two-state simulation (four-state simulators show X until every bank is written).

**T4: `tg_fifo` `STORAGE "srl"`, a FIFO in shift-register LUTs.** LUTs / flip-flops.

| Depth × width | `srl` | `lutram` | `reg` |
|---|---|---|---|
| 4 × 8 | 13 / 3 | 16 / 6 | 21 / 38 |
| 4 × 32 | 38 / 3 | 32 / 6 | 46 / 134 |
| 4 × 64 | 70 / 3 | 48 / 6 | 78 / 262 |
| 8 × 8 | 17 / 4 | 21 / 8 | 35 / 72 |
| 8 × 32 | 43 / 4 | 37 / 8 | 83 / 264 |
| 8 × 64 | 75 / 4 | 53 / 8 | 147 / 520 |
| 16 × 8 | 17 / 5 | 23 / 10 | 63 / 138 |
| 16 × 32 | 43 / 5 | 39 / 10 | 158 / 522 |
| 16 × 64 | 75 / 5 | 55 / 10 | 289 / 1,036 |
| 32 × 8 | 26 / 6 | 28 / 12 | 122 / 268 |
| 32 × 32 | 52 / 6 | 44 / 12 | 341 / 1,039 |
| 32 × 64 | 84 / 6 | 60 / 12 | 636 / 2,070 |

- **The counts above are before placement, where every shift register takes a LUT. Placement pairs two 16-deep ones in a LUT:** the 16 × 64 FIFO implements in **41 LUTs** (32 of them shift registers, half the 64 above), where a RAM32M16 FIFO stays at 0.625 LUTs per bit (16 × 64: 55). At 32 deep a shift register fills its LUT: 32 × 64 implements in 82 LUTs against **59** for `lutram`.
- So **`srl` is the cheapest storage up to 16 deep** (about 25% below `lutram`, with one count register instead of two pointers: 3–5 flip-flops against 6–10), and `lutram` from 32 deep, except for narrow FIFOs.
- **Flip-flop storage** costs 5–10× more from depth 8.
- **Timing at 200 MHz** (64 bits, placed and routed): `srl` 16 deep +3.053 ns, 32 deep +3.133; `lutram` 32 deep +3.158. All three have more than 3 ns to spare.
- **Decision (proposed): `srl` for FIFOs up to 16 deep and for delay lines; `lutram` stays the default from 32 deep.**
  - *Pros of `srl`:* half a LUT per bit up to 16 deep; no write pointer or address decode; fewer flip-flops.
  - *Cons:* a full LUT per bit at 32 deep; at most 32 deep; no reset of contents; the saving appears only after placement, so synthesis-only counts overstate it.

**T5: `tg_cam_lut`, a CAM in LUTRAM.** LUTs / flip-flops; `sw` = one-bit-write tables (RAM64X8SW, 6-bit slices), `m16` = read-modify-write tables (RAM32M16, 5-bit slices).

| Entries × key bits | `sw` | `m16`, shared port | `m16`, second read port | Flip-flop CAM |
|---|---|---|---|---|
| 16 × 20 | 201 / 70 | 257 / 69 | 270 / 69 | 170 / 336 |
| 16 × 30 | 243 / 90 | 362 / 89 | 381 / 89 | 218 / 496 |
| 16 × 40 | 292 / 110 | 452 / 109 | 477 / 109 | 282 / 656 |
| 32 × 20 | 322 / 87 | 368 / 86 | 413 / 86 | 338 / 672 |
| 32 × 30 | 375 / 107 | 493 / 108 | 559 / 108 | 435 / 992 |
| 32 × 40 | 487 / 127 | 594 / 129 | 683 / 129 | 563 / 1,312 |
| 64 × 20 | 593 / 120 | 754 / 123 | 890 / 123 | 680 / 1,344 |
| 64 × 30 | 678 / 140 | 1,059 / 144 | 1,268 / 144 | 872 / 1,984 |
| 64 × 40 | 893 / 160 | 1,295 / 166 | 1,574 / 166 | 1,128 / 2,624 |

- **The first form (`m16`) costs more LUTs than flip-flops at every size** (64 × 40: 1,295–1,574 against 1,128). About half of its logic is the per-bit read-modify-write of each table.
- **The one-bit-write form (`sw`) needs no read-modify-write.** It saves 13–22% of the LUTs from 32 entries (64 × 40: 893 against 1,128; 32 × 40: 487 against 563) and breaks even at 16 entries. Both forms save 90–94% of the flip-flops.
- **Writes take three cycles** (accept, clear the old key's bits, set the new key's), and the entry stops matching from the accept. In `sw` and in `m16` without the second read port, lookups are not served during the last two cycles (`lk_valid` low). After a reset, a sweep: ENTRIES cycles (`sw`) or 32 (`m16`).
- **No masked compares:** a TLB's superpages would need a per-entry mask or extra tables.
- **Timing at 200 MHz** (64 × 40, placed and routed): `sw` **+0.725 ns** (908 LUTs; its worst path is the reset sweep through the key store and a table into the hit output, 11 levels), `m16` +1.066 with the second read port and +0.700 without, the flip-flop CAM +0.371 (1,093 LUTs).
- **Decision (proposed): T5 is "flip-flop savings, and a modest LUT saving from 32 entries", not a LUT lever. The TLBs keep flip-flop CAMs:** the ITLB (16 entries) would gain nothing, the DTLB (32) about 76 LUTs, and either would trade single-cycle refills for three cycles with two lookup gaps, and lose superpage masking.
  - *Pros of `sw`:* fewer flip-flops and LUTs from 32 entries; single-cycle invalidate and flush.
  - *Cons:* three-cycle writes; lookup gaps during writes; exact match only.

**T6: `tg_dsp_cmp`, equality and less-than in one DSP48E2.**

| Width | DSP, latency 1 | DSP, latency 2 | Fabric (LUTs and carry chain), result registered |
|---|---|---|---|
| 16 | no LUTs, 1 DSP | no LUTs, 1 DSP | 15 LUTs, 2 flip-flops |
| 32 | no LUTs, 1 DSP | no LUTs, 1 DSP | 29 LUTs, 2 flip-flops |
| 48 | 1 LUT, 1 DSP | 1 LUT, 1 DSP | 40 LUTs, 2 flip-flops |

- **One DSP and no LUTs** against 15–40 LUTs for the same compare in fabric. Less-than is the sign of the 48-bit difference up to 47 bits; at 48 bits unsigned it is the inverted carry out (checked on the vendor's model).
- **Latency 1:** the operands come from fabric registers and the DSP's P register holds the result, the same timing as a fabric compare followed by a register. **Latency 2:** the DSP's own A, B and C registers hold the operands (the pipeline register moves into the DSP).
- **Timing at 200 MHz** (48 bits, placed and routed, out of context): latency 1 **+3.039 ns** (fabric register → DSP A:B → ALU → P: 1.5 ns, 2 levels), latency 2 **+3.687 ns** (inside the DSP); the fabric form +3.660 ns (40 LUTs, 4 levels, 3 of them CARRY8). So the DSP is no faster than fabric at this width: its gain is the LUTs. In a full design the operands travel to the DSP column, so expect less margin.
- **Decision (proposed): use it where a compare's operands are already registered and the result can be registered.** It saves 15–40 LUTs per compare, and the device has 1,141 DSPs free.
  - *Pros:* no LUTs or carry chain.
  - *Cons:* the DSP sits in a fixed column, so the operands travel; one compare per DSP (SIMD modes would give four 12-bit less-thans, not equalities).

## 4. Results

**The FPU track's rows** (P4 and Execute): the budget flow (DR-113 settings), each unit synthesised alone, st, LUT changes against bf914f1. Cycle-identical: `make cycle-identical CFG="st smt2"` against main (798 of 798 programs in each configuration), and `cyc_cmp.py` against bf914f1 (310 ELFs natively, 309 under memory stress, 895 ACT4). Slack is out of context at 200 MHz: P4 with its DR-119 floorplan, Execute with the load result at 1.0 ns. Details: [fpu.md](../spec/fpu.md), "DR-123, FPGA-native pass".

| Date | Unit | Change | LUTs | Flip-flops | LUTRAM / BRAM / DSP | Cycle-identical | Slack | Decision |
|---|---|---|---|---|---|---|---|---|
| 10-14 | Shared primitive T2 (`tg_ram_lut_mw`) | Multi-write LUTRAM, LVT in LUTRAM, against a flip-flop array (64 × 8, 4 writers × 8 readers) | 553 against 2,448 | 0 against 512 | 448 / 0 / 0 | A primitive: same behaviour as the array (tested against a reference) | +1.075 ns (128 × 32; the array +0.325) | Proposed for multi-write tables (§3.1) |
| 10-14 | Shared primitive T4 (`tg_fifo` `"srl"`) | Shift-register FIFO against the LUTRAM FIFO, placed (16 × 64; at 32 × 64: 82 against 59) | 41 against about 55 | 5 against 10 | 32 SRL LUTs against 40 LUTRAM | Same ports and timing as `"lutram"` | +3.053 ns | `"srl"` up to 16 deep and for delay lines; `"lutram"` from 32 deep |
| 10-14 | Shared primitive T5 (`tg_cam_lut` `"sw"`) | CAM with one-bit-write LUTRAM tables against a flip-flop CAM (64 × 40) | 893 against 1,128 | 160 against 2,624 | 496 / 0 / 0 | No: writes take 3 cycles (1 for flip-flops) | +0.725 ns (flip-flops +0.371) | Flip-flop savings, small LUT savings from 32 entries; TLBs keep flip-flop CAMs |
| 10-14 | Shared primitive T5 (`tg_cam_lut` `"m16"`) | CAM with read-modify-write LUTRAM tables (64 × 40) | 1,295 against 1,128 | 166 against 2,624 | 368 / 0 / 0 | No (as above) | +0.700 / +1.066 ns | Rejected as a LUT lever: more LUTs than flip-flops at every size |
| 10-14 | Shared primitive T6 (`tg_dsp_cmp`) | Equality and less-than in a DSP48E2 against fabric (48 bits) | 1 against 40 | 0 against 2 | 0 / 0 / 1 | Yes at latency 1 (the same register stage) | +3.039 ns (latency 1) | Use where the operands are registered |
| 10-14 | uncore: crossbar (SoC) | The caches' A-channel data, corrupt and mask as constants: interfaces.md §2.2–2.3 says l1i only sends Gets and l1d only Acquires. Their inputs leave the A arbiters' data multiplexers (T7). | −249 (uncore at st and at smt2) | 0 | 0 / 0 / 0 | yes: `make cycle-identical BOOT=20`, tb_xbar's 12 seeds, the OpenSBI signatures, and the whole one-core Linux boot (TANAGER-BOOT-OK at 335,964,000 cycles in both, trace signature 4eccd9796bd5ec80, every million-cycle signature equal) | tg_xbar +2.136 ns at 200 MHz | adopted (11bf523) |
| 10-14 | uncore: L2 S2 for 200 MHz, A (SoC, DR-137) | The set compares S2 needs (the write history's, each MSHR's, the C message's) made in S1 and registered: every operand is a register a cycle before S2. The MSHR the S2 in flight allocates takes that S2's line, whose compare is the history's | +28 per bank | +45 | 0 / 0 / 0 | yes: assertions against the direct compares; `make cycle-identical CFG="st smt2" BOOT=20` | bank −2.125 → −1.135 ns (200 MHz, DR-113's settings, placed and routed) | **Adopted** (81ab114). Pros: 1 ns for 28 LUTs, exact. Cons: 24 more flip-flops of set matches, and an allocate/free correction to reason about |
| 10-14 | uncore: L2 S2 for 200 MHz, B (SoC, DR-137) | The victim's entry selected late: the updates read the entry of the fast choice (the hit way, or the MCMD's way); a miss reads only the victim's held, tag and dirty bits and writes that entry unchanged or a new one made from the request alone | +155 per bank alone; +43 with A | −41 alone | 0 / 0 / 0 | yes (as A) | bank −1.299 ns alone, −0.605 with A | **Adopted** with A (a8eb6f8). Pros: the victim choice drives a select and the way enables, not the whole update. Cons: a second 8:1 entry select (the victim's) |
| 10-14 | uncore: L2 S2 for 200 MHz, C (SoC, DR-137) | Parallel per-way entries with a late select: every way's hit update (probe set, final entry, the C message's entry) made from its own entry, selected by the one-hot hit vector | +157 per bank over A + B | −33 | 0 / 0 / 0 | yes (L2 long suite) | bank −0.605 → −1.170 ns: 13–16 levels instead of 15–16, but longer wires | **Rejected** (reverted, 3f35962). Pros: fewer levels on the hit path. Cons: eight copies of the update spread the placement; the placed path got longer |
| 10-14 | uncore: L2 S2 for 200 MHz, D (SoC, DR-137) | The write history's per-way and PLRU selects registered in S1 (the history compare with the entry's way enables), and each way's hit compared on the RAM's and both history entries at once, then selected | 0 per bank (4,604) | −2 | 0 / 0 / 0 | yes (assertions; cycle-identical) | bank WNS −0.638 ns (A + B −0.605: noise), TNS −151 → −110 ns, failing endpoints 641 → 503 | **Adopted** (028a480). Pros: the tag compares start from registers; no fanout from one hit flag to every entry bit. Cons: 18 more flip-flops |
| 10-14 | uncore: register slices in DSPs (SoC, DR-136) | The main data register of every crossbar slice (A, C, D, B), of the memory paths' AR, AW, W and R slices and of the L2 banks' R slices sits in DSP48E2s (`tg_dsp_reg2`: per 48 bits one DSP, OPMODE picks the incoming data or the skid entry, CEP is the load). Per site behind `UNCORE_DSP` | uncore 19,439 → 18,047 at st (−1,392; the crossbar alone −837), 19,933 → 18,603 at smt2 (−1,330), DR-113's settings; placed and routed 19,796 → 18,465 | −2,815 at st (placed and routed −3,001) | 0 / 0 / 83 DSP | yes: `make cycle-identical CFG=st BOOT=20` (799 of 799), the SoC short suite; the mapping on the vendor's DSP48E2 model (`tests/unit/dsp_reg`, widths 1–193; a swapped OPMODE fails it) | 200 MHz out of context, unconstrained placement: WNS −1.779 (all fabric) → −2.004 ns, failing endpoints 7,044 → 10,601. Slices that fail: B −1.9, D −0.8 to −1.6, memory AR −1.3 to −1.5, A 0 and 1 −0.6 to −0.9; L2 R, memory AW and W within −0.3; the rest pass. The fabric uncore itself fails by 1–2 ns (L2, injectors, windows, crossbar) | **Adopted**, every site on by default; the full-chip fit can return any site to fabric. Pros: −1.4K LUTs and −2.8K FFs, cycle-identical. Cons: 83 DSPs; a DSP's input runs through its ALU, so a slice behind an arbiter loses about 1–2 ns at 200 MHz |
| 10-14 | prototype (SoC): DSP48E2 as a registered multiplexer | `q <= sel_a ? a : sel_c ? c : q`, 154 bits: per 48 bits one DSP with X = A:B or P (hold), Z = C or 0, a dynamic OPMODE as the select, P registered (T6, a new use) | 2 against 155 (−153, 38 per DSP) | −154 (q is the P register) | 0 / 0 / 4 DSP | yes, by construction | +2.947 ns at 200 MHz against fabric +3.382 (out of context, placed and routed, registered around) | **Candidate** for every wide registered select with hold: the uncore's skid buffers and the arbiters before them |
| 10-14 | prototype (SoC): two cascaded DSP48E2s as a 4:1 registered multiplexer | `q <=` one of a, b, c, d (one-hot) or hold, 154 bits: per 48 bits DSP0 without a P register selects a or b, PCOUT → PCIN into DSP1, which selects c, d, the cascade or P | 5 against 309 (−304, 38 per DSP) | −154 | 0 / 0 / 8 DSP | yes, by construction | +0.886 ns at 200 MHz against fabric +2.920: the combinational cascade costs about 2 ns | **Candidate**, at 100 MHz freely; at 200 MHz only where the select has slack |
| 10-14 | uncore: L2 (SoC) | The MSHR state one-hot (13 flip-flops per MSHR instead of 4 encoded): each per-MSHR state test is one bit, each transition clears one bit and sets one (T7). Vivado infers no FSM on an array of state registers, and `fsm_encoding` on the array changed nothing | −200 per bank out of context; uncore st 19,439 at e7227d4 under DR-113's settings (−627 from 4d5ca13 with the crossbar's −249) | +216 per bank | 0 / 0 / 0 | yes: by construction (every event stays qualified by its source state); `make cycle-identical BOOT=20` (799 of 799, two-core boot), the L2 long suite (36 runs) | bank −1.004 → −0.770 ns at 200 MHz | **Adopted** (54800a2). Pros: −400 LUTs for the uncore, a shorter bank path. Cons: +432 flip-flops; the encoded state is kept only for the assertions and the testbench's dump |
| 10-14 | uncore: trace stream (SoC) | Record kinds decoded once with KEEP, so each shared 64-bit field select is a 3-input function (T7, LUT pairing) | +8: 130 per lane against 128; synthesis did not pair them | 0 | 0 / 0 / 0 | yes (20 seeds) | — | rejected: no gain |
| 10-14 | uncore: host bridge (SoC) | The read multiplexer decoded by range and word index instead of a 16-bit compare per register (T7) | +5 (1,260 against 1,255; Vivado already shared the compares) | 0 | 0 / 0 / 0 | yes (port signatures) | — | rejected: no gain |
| 10-14 | uncore: trace stream (SoC) | FIFOs in SRL (T4) | not built. At one write and one read port LUTRAM holds 1.75 bits per LUT at 32 deep against SRL's 1, and the FIFOs are already LUTRAM. | — | — | — | — | rejected: denser as it is |
| 10-14 | uncore: trace stream (SoC) | The W output as one flat F7/F8 select over core, lane and beat (T7) | not built. About 900 LUTs either way: the staged selects already cost what a flat 24-input select per bit does. | — | — | — | — | rejected: no gain expected |
| 10-14 | uncore: host bridge (SoC) | The CDC mirrors in block RAM (T3) | not built. Synthesized alone, tg_cdc_mirror at 581 bits is 4 LUTs and 2,334 flip-flops; the LUTs the uncore report puts inside it belong to the read multiplexer. | — | — | — | — | rejected: nothing to save |
| 10-14 | uncore: host bridge (SoC) | The read multiplexer (≈690 LUTs) as a block-RAM register file (T3) | an estimated −500 | — | +1 RAMB18, over the uncore's 18 | no: status words reach the block RAM a word at a time, so the host port sees them a few host cycles later | — | open: a coordinator decision (cycle-identity on the host port, the block-RAM budget) |
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
| 2026-10-14 | P4 | the FLW NaN-boxing moves into the LSU's extract step (core track, 3f9a227); P4 drops its boxing multiplexer and ignores `fld_single` (T7) | −16 | 0 | — | yes | P4: +0.089 (smt2), +0.073 (st) | **Adopted.** Pros: −16 LUTs and one LUT level off the load bypass into the FMA, at no cost in the LSU (the extension multiplexer was there anyway). Cons: P4 now relies on the core to box FLW; the contract in fpu.md says so. |
| 2026-10-14 | P4 (register file) | the bank select folds into the RF-stage operand multiplexer: one encoded 4:1 per port (T7) | −28 | 0 | — | yes | +0.097 ns (smt2), +0.067 ns (st) | **Adopted.** Pros: −28 LUTs; `tg_fprf` keeps the select only for the store-data and trace ports. Cons: the read path's select now lives in `tg_fp_exec`. |
| 2026-10-14 | P4 (FMISC) | the result as one encoded select per bit over a, b, the FCVT.I.F sum, two sign-extension bits and a constant word (T7) | −31 | 0 | — | yes | as above | **Adopted.** Pros: −31 LUTs, one select level in place of three. Cons: the per-op choice sits in a table of sources rather than in the op's own expression. |
| 2026-10-14 | P4 (divide table, B1 queue) | LUTRAM or SRL for the 4-entry tables (T1, T4) | about −10 at best | — | — | — | — | **Not built.** The flip-flop logic is about 35 and 10 LUTs, and the B1 payload is LUTRAM already; an SRL FIFO counts more LUTs than LUTRAM before placement (§3.1). |
| 2026-10-14 | Execute (divider) | NM amount `nz ? 64 : ~(lzd − lza)` on the original shifter, in place of the form that kept r and q when n = 0 | −17 | −1 | — | yes | Execute: +0.116 (st), +0.033 (smt2) | **Adopted.** Pros: −17 LUTs, and FX goes back to its original select. Cons: none found. |
| 2026-10-14 | Execute (register file) | the 4 ALU operand ports in UltraRAM copies addressed in IS (T3, DR-133, behind `IRF_URAM`) | −597 | +150 | LUTRAM −888, URAM +12 | yes (switch on) | +0.019 ns (st), +0.002 ns (smt2), floorplanned into X2Y0–X2Y1 (12 URAM sites) | **Rejected at gate 3 (DR-133), and removed:** `IRF_URAM` stayed 0, then the switch and its RTL went (the test branch claude/track-fpu-395911-dr133-gate3 keeps them). In a v1 full chip (spikes-2, two smt2 cores and the L2's 32 URAM, 200 MHz, spikes.md §8.1) the issue grant → URAM read address fails by 4.833 ns (core 0) and 5.476 ns (core 1), 7.2 and 8.2 ns of it wire: all 64 URAM sites are in clock-region column X2, the L2 takes X2Y0–Y1 and the cores X2Y2–Y3, so each core's spread issue logic reaches a fixed column. The data side passes (+0.971 to +1.429 ns). A floorplan cannot shorten 5 ns of wire to a column the L2 shares, and an extra issue stage would move cycles (DR-135). Pros of the attempt: −597 LUTs per core measured, cycle-identical. Cons: the address path, which only the full chip shows (out of context it had +0.002 to +0.019 ns). |
| 2026-10-14 | P4 (register file) | the 3 operand ports in UltraRAM copies addressed in IS, as execute's (T3) | about −240 (estimate: −432 LUTRAM, +192 for the write-to-read bypass) | about +130 | LUTRAM −432, URAM +6 | — | — | **Rejected** with execute's (DR-133 gate 3): the same IS → URAM address path, to the same column. |
| 2026-10-14 | Execute (divider) | NM aligns the divisor, d = \|b\| << (n − 1), with one 64-bit shifter, in place of {r, q} = \|a\| << (64 − n), a 128-bit shift; x / 0's quotient (all ones) is set in NM, so FX has no override (T7) | −208 | +3 | — | yes | Execute: +0.163 (st), +0.204 (smt2) | **Adopted.** Pros: −208 LUTs, and NM is no longer the worst path. Cons: the iteration's registers change roles (r holds the dividend, d shifts right); the RTL header says so. |
| 2026-10-14 | Execute (Zbb unit) | clz and ctz on `tg_fpu_lzc`; cpop as a tree of 6-bit group counts | −23 | 0 | — | yes | as above | **Adopted.** Pros: −23 LUTs (A/B in context: −20 for the count, −3 for the tree). Cons: none found. AR-8 had measured +77 for a tree count, before the unit moved a cycle later onto registered operands. |
| 2026-10-14 | Execute (register file) | res_q[0] is zero through the reset sequence, so bank 0's zero writes take it as their data, with no multiplexer in front of the bank (T7) | −31 | 0 | — | yes | as above | **Adopted.** Pros: −31 LUTs. Cons: tg_exec now relies on nothing issuing during the sequence (as the core guarantees). |
| 2026-10-14 | Execute (branch) | the target select (JALR or the decoded target) in front of the JALR adder, which adds zero to the decoded target (T7) | −88 | 0 | — | yes | as above | **Adopted.** Pros: −88 LUTs and one LUT level less on the target. Cons: the decoded target goes through a carry chain. |
| 2026-10-14 | Execute (branch) | the misprediction test back to next PC ≠ predicted (dropping its timing form) | −23 | 0 | — | (equivalent) | +0.028 (st), +0.024 (smt2) | **Rejected.** Pros: −23. Cons: the slack falls from +0.16 to +0.03 ns. |
| 2026-10-14 | Execute (ALUs) | the W sign extension as the fourth source above bit 31, with the bit ops and the unary ops on one source; bit masks from the rotator; a funnel shifter | +3, +99, +58 per ALU alone | — | — | (bench) | — | **Rejected.** No gain. Variants of the ALU alone move by tens of LUTs. |
| 2026-10-14 | Execute (divider) | x / 0 as q = 1 negated, so q's other bits load by reset | +97 alone | — | — | (unit test) | — | **Rejected.** |
| 2026-10-14 | P4 (register file) | the reset sequence's zero writes take the F0 port: the zero folds into the F0 stream's multiplexer, and `tg_fprf` drops both banks' zero multiplexers (T7) | −64 (st), −63 (smt2) | 0 | — | yes | P4: +0.069 (st), +0.117 (smt2) | **Adopted.** Pros: −64 LUTs. Cons: `init_bank` must be 0 (asserted; the core ties it to 0). |
| 2026-10-14 | P4 (register file) | the F0 source as a 2-bit encoded select with the zero as its fourth state | −4 | — | — | — | — | **Not taken:** within run-to-run variation. |
| 2026-10-14 | P4 (divider) | the four multiplier operands as one encoded select each: a bit is one 4:1, where the round's control was decoded per bit; an unused product's operands take the select's default (T7) | −81 | 0 | — | yes | P4: +0.143 (st), +0.095 (smt2) | **Adopted.** Pros: −81 LUTs, one LUT level in front of the multipliers. Cons: idle multipliers multiply whatever the defaults select (their products are not used). |
| 2026-10-14 | P4 (FMA) | E0's zeros (an S significand's bits 28:0, b = 1.0, no addend) through the registers' synchronous resets, `direct_reset` (T7) | −23 | 0 | — | yes | P4: +0.114 (st), +0.091 (smt2), with the next row | **Adopted.** Pros: −23 LUTs. Cons: the zeros now depend on the reset mapping, which the attribute asks for. |
| 2026-10-14 | P4 (FMISC) | the FCVT.I.F range check from six shared reductions of the shifted value | −15 | 0 | — | yes | as above | **Adopted.** Pros: −15 LUTs. Cons: none found. |
| 2026-10-14 | P4 (FMA) | E2: X and X − 1 as one 3:2 layer and a compound adder, one propagate LUT per bit feeding two carry chains (explicit CARRY8, or behavioural) | +67, +80 alone | — | — | (bench) | — | **Rejected.** Synthesis's two ternary adders already cost one LUT per bit each, with the column counters folded in. |
| 2026-10-14 | P4 (FMA, FMISC) | E3's normalised value and FMISC's S significand zeroed through register resets | +8 | — | — | — | — | **Rejected:** within run-to-run variation. |
| 2026-10-14 | P4 (register file) | the bank select of the store-data and trace ports moves into the core's multiplexers (the LSU's store-data 3:1 and tg_core's trace 2:1), P4 hands out both banks | −96 in P4, about 0 in the core | 0 | — | (by construction) | — | **Proposed** to the core track: their two multiplexers must take the bank as a select (an encoded 2-bit select in the LSU). |

## 5. History and lessons

- **2026-10-14:** started after AR-7 showed v1 about 50K over. The planning estimates had assumed FPGA-native structures that the first RTL did not use.
- **2026-10-14, shared primitives (§3.1):** T2, T4, T5 and T6 built, verified and priced.
  - Multi-write LUTRAM is the large win: 4–7× fewer LUTs than flip-flop arrays.
  - The LUTRAM CAM's first form lost to flip-flops on LUTs; only the one-bit-write form (RAM64X8SW) wins, and only from 32 entries. Measure before adopting: the per-bit update path cost more than the comparators it replaced.
  - Vivado's hierarchical utilisation report hides instances of fewer than 50 cells unless asked (`-hierarchical_min_primitive_count 0`); the budget and spike flows now ask.
- **2026-10-14, FPU track (P4 and Execute):**
  - P4 7,386 → 7,273 and Execute 7,944 → 7,892 LUTs, both cycle-identical, with 4 more DSPs.
  - The DSP measurements set a rule of thumb for T6. An incrementer or a constant add costs almost nothing beyond its carry chain, so it is not worth a DSP. An adder whose operand bits come from LUT logic saves about a LUT per bit.
  - Inference needs `(* use_dsp = "yes" *)` on a module, with the operand register inside it under the kept hierarchy (`tg_fpu_dsp_add`).
  - A hand-mapped carry chain lost to synthesis (+129 LUTs).
- **2026-10-14, FPU track, third round:** Execute 7,875 → 7,525 LUTs (st) and 7,524 (smt2), 85 under its 7,610; P4 7,198 → 7,134 (st) and 7,219 → 7,156 (smt2), 334 and 356 over its 6,800. Every change is cycle-identical (`make cycle-identical`, 798 of 798 programs in st and smt2 against main f0a1207).
  - The divider's −208 came from changing which value is aligned (the divisor, with one shifter, not the dividend into two registers), not from mapping.
  - A small module synthesised alone varies by up to ±100 LUTs between equivalent forms (the x / 0 form measured +97 alone). Judge in the budget flow with an A/B.
- **2026-10-14, FPU track, P4 step 6:** P4 7,134 → 7,015 (st) and 7,156 → 7,037 (smt2), cycle-identical, 215 and 237 over its 6,800. The largest saving (−81) came from decoding the divider's round once per operand instead of in every bit of its multiplexers. A compound adder hand-built from CARRY8s lost to synthesis's two ternary adders (+67).
