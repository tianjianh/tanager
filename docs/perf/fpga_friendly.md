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
| P4 and execute (FPU agent) | +1.2K and +1.1K | Continuing; DSPs for wide add and compare (T6) |
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
- **Timing at 200 MHz** (48 bits, placed and routed, out of context): latency 1 **+3.039 ns** (fabric register → DSP A:B → ALU → P: 1.5 ns, 2 levels), latency 2 **+3.687 ns** (inside the DSP). The fabric form's run is pending. In a full design the operands travel to the DSP column, so expect less margin.
- **Decision (proposed): use it where a compare's operands are already registered and the result can be registered.** It saves 15–40 LUTs per compare, and the device has 1,141 DSPs free.
  - *Pros:* no LUTs or carry chain.
  - *Cons:* the DSP sits in a fixed column, so the operands travel; one compare per DSP (SIMD modes would give four 12-bit less-thans, not equalities).

## 4. Results

| Date | Unit | Change | LUTs | Flip-flops | LUTRAM / BRAM / DSP | Cycle-identical | Slack | Decision |
|---|---|---|---|---|---|---|---|---|
| 10-14 | Shared primitive T2 (`tg_ram_lut_mw`) | Multi-write LUTRAM, LVT in LUTRAM, against a flip-flop array (64 × 8, 4 writers × 8 readers) | 553 against 2,448 | 0 against 512 | 448 / 0 / 0 | A primitive: same behaviour as the array (tested against a reference) | +1.075 ns (128 × 32; the array +0.325) | Proposed for multi-write tables (§3.1) |
| 10-14 | Shared primitive T4 (`tg_fifo` `"srl"`) | Shift-register FIFO against the LUTRAM FIFO, placed (16 × 64; at 32 × 64: 82 against 59) | 41 against about 55 | 5 against 10 | 32 SRL LUTs against 40 LUTRAM | Same ports and timing as `"lutram"` | +3.053 ns | `"srl"` up to 16 deep and for delay lines; `"lutram"` from 32 deep |
| 10-14 | Shared primitive T5 (`tg_cam_lut` `"sw"`) | CAM with one-bit-write LUTRAM tables against a flip-flop CAM (64 × 40) | 893 against 1,128 | 160 against 2,624 | 496 / 0 / 0 | No: writes take 3 cycles (1 for flip-flops) | +0.725 ns (flip-flops +0.371) | Flip-flop savings, small LUT savings from 32 entries; TLBs keep flip-flop CAMs |
| 10-14 | Shared primitive T5 (`tg_cam_lut` `"m16"`) | CAM with read-modify-write LUTRAM tables (64 × 40) | 1,295 against 1,128 | 166 against 2,624 | 368 / 0 / 0 | No (as above) | +0.700 / +1.066 ns | Rejected as a LUT lever: more LUTs than flip-flops at every size |
| 10-14 | Shared primitive T6 (`tg_dsp_cmp`) | Equality and less-than in a DSP48E2 against fabric (48 bits) | 1 against 40 | 0 against 2 | 0 / 0 / 1 | Yes at latency 1 (the same register stage) | +3.039 ns (latency 1) | Use where the operands are registered |
| 10-14 | uncore: crossbar (SoC) | The caches' A-channel data, corrupt and mask as constants: interfaces.md §2.2–2.3 says l1i only sends Gets and l1d only Acquires. Their inputs leave the A arbiters' data multiplexers (T7). | −249 (uncore at st and at smt2) | 0 | 0 / 0 / 0 | yes: `make cycle-identical BOOT=20`, tb_xbar's 12 seeds, the OpenSBI signatures | tg_xbar +2.136 ns at 200 MHz | adopted (11bf523) |
| 10-14 | uncore: trace stream (SoC) | Record kinds decoded once with KEEP, so each shared 64-bit field select is a 3-input function (T7, LUT pairing) | +8: 130 per lane against 128; synthesis did not pair them | 0 | 0 / 0 / 0 | yes (20 seeds) | — | rejected: no gain |
| 10-14 | uncore: host bridge (SoC) | The read multiplexer decoded by range and word index instead of a 16-bit compare per register (T7) | +5 (1,260 against 1,255; Vivado already shared the compares) | 0 | 0 / 0 / 0 | yes (port signatures) | — | rejected: no gain |
| 10-14 | uncore: trace stream (SoC) | FIFOs in SRL (T4) | not built. At one write and one read port LUTRAM holds 1.75 bits per LUT at 32 deep against SRL's 1, and the FIFOs are already LUTRAM. | — | — | — | — | rejected: denser as it is |
| 10-14 | uncore: trace stream (SoC) | The W output as one flat F7/F8 select over core, lane and beat (T7) | not built. About 900 LUTs either way: the staged selects already cost what a flat 24-input select per bit does. | — | — | — | — | rejected: no gain expected |
| 10-14 | uncore: host bridge (SoC) | The CDC mirrors in block RAM (T3) | not built. Synthesized alone, tg_cdc_mirror at 581 bits is 4 LUTs and 2,334 flip-flops; the LUTs the uncore report puts inside it belong to the read multiplexer. | — | — | — | — | rejected: nothing to save |
| 10-14 | uncore: host bridge (SoC) | The read multiplexer (≈690 LUTs) as a block-RAM register file (T3) | an estimated −500 | — | +1 RAMB18, over the uncore's 18 | no: status words reach the block RAM a word at a time, so the host port sees them a few host cycles later | — | open: a coordinator decision (cycle-identity on the host port, the block-RAM budget) |

## 5. History and lessons

- **2026-10-14:** started after AR-7 showed v1 about 50K over. The planning estimates had assumed FPGA-native structures that the first RTL did not use.
- **2026-10-14, shared primitives (§3.1):** T2, T4, T5 and T6 built, verified and priced.
  - Multi-write LUTRAM is the large win: 4–7× fewer LUTs than flip-flop arrays.
  - The LUTRAM CAM's first form lost to flip-flops on LUTs; only the one-bit-write form (RAM64X8SW) wins, and only from 32 entries. Measure before adopting: the per-bit update path cost more than the comparators it replaced.
  - Vivado's hierarchical utilisation report hides instances of fewer than 50 cells unless asked (`-hierarchical_min_primitive_count 0`); the budget and spike flows now ask.
