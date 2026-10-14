# Tanager M0: FPGA spikes S1–S6

*Milestone M0 (plan §11): the protected 1-cycle loops (§8.1), the resource budget (§8.2), the memory-primitive policy (§8.3) and the utilisation limit (§8.5), measured on the XCK26 before the core's RTL settles.*

| | |
|---|---|
| Status | DRAFT, being filled in as runs finish |
| Date | 2026-10-13 |
| Track | spikes (branch `claude/track-spikes-72f833`) |
| Device | `xck26-sfvc784-2LV-c` (KV260 SOM), Vivado 2025.2 |
| Plan | [architecture_plan.md](../architecture_plan.md) draft 0.4 |
| RTL | [`fpga/spikes/rtl`](../../fpga/spikes/rtl) (spike structures), [`rtl/common/prim`](../../rtl/common/prim) (memory wrappers) |
| Raw results | [`fpga/spikes/results`](../../fpga/spikes/results): one directory per run (summary, named paths, utilisation by hierarchy, worst path, primitive check) |

Every number here is a Vivado result for this device, at a 5.0 ns (200 MHz) clock, unless the table says otherwise.

---

## 1. Summary

(to be completed)

---

## 2. Method

**Out-of-context runs** ([`fpga/spikes/tcl/ooc_run.tcl`](../../fpga/spikes/tcl/ooc_run.tcl), through [`run_ooc.sh`](../../fpga/spikes/scripts/run_ooc.sh) and `tools/vivado_run.sh`):
- Synthesis, `opt_design`, `place_design`, `phys_opt_design`, `route_design`, all with default directives. A second `phys_opt_design` runs after routing if timing fails.
- **Clock:** one 5.0 ns clock. Its source is a global buffer in the middle of the device (`HD.CLK_SRC` = BUFGCE_X0Y48, clock region X1Y2), so the clock tree is routed as in a full design and the skew is real (0.1–0.3 ns on the paths below).
- **Inputs and outputs:** every spike top registers all of its inputs and outputs, so only register-to-register paths inside the structure are timed.
- **Reports kept:**
  - CLB LUTs as `report_utilization` counts them (logic + LUTRAM + SRL);
  - worst slack (WNS) and the Fmax estimate 1 / (5.0 ns − WNS);
  - logic levels of the worst path, as Vivado counts them: every LUT, MUXF7/F8 and CARRY8 is a level;
  - **named paths:** the worst path into each structure's key registers, so a loop is reported even when another path is worse.
- **Disk:** no checkpoints are kept (conventions §9).

**Caveats.**
- **Out of context is optimistic.** A structure placed alone is compact. In the full chip it competes for area and routing, and S6 measures that.
- **Placement scatter, and the pblock.** Out of context, Vivado may place a block anywhere on the die. Several early runs landed in clock-region row 0, far from the clock source in row 2.
  - **Cost:** the clock insertion delay was 2.3–2.5 ns instead of 1.5–1.8 ns, and nets were longer. One S2 run lost 1.2 ns this way.
  - **Fix:** every run from then on is constrained to clock regions X0Y2:X1Y3 next to the clock source (`-pblock`). That region holds about 39K LUTs and has room to spare for any one spike. The tables mark which runs used it.
  - **Margins:** even with the pblock, results move by up to a few hundred picoseconds with small RTL changes, so **margins under about 0.3 ns are marginal.**
- **The -2LV part** runs at 0.72 V, which behaves like a -1 speed grade (plan §2.1).

**Reproducing a run:**
```bash
source tools/env.sh
fpga/spikes/scripts/run_ooc.sh <name> <cfg> <top> -g NAME=VALUE ... -paths fpga/spikes/tcl/paths_sN.tcl
python3 -I fpga/spikes/scripts/results_table.py '<name>'
```
The exact command of every run is in its `summary.txt` (`top`, `cfg`, `generics`).

**Tests.** Every spike structure has a random simulation test with a reference model. All are listed in §10.

---

## 3. LUTRAM mapping and the primitive check (plan §8.3)

**The problem.** Behavioural inference of a 64 × 64 memory with 7 read ports gave 63 RAM64M8 plus 7 RAM64X1D: not deterministic, and not the intended structure.

**The fix: explicit primitives.** [`tg_ram_lut`](../../rtl/common/prim/tg_ram_lut.sv) now instantiates explicit primitives under `SYNTHESIS`. Its ports are unchanged.
- **Primitive per depth:** RAM32M16 up to 32 entries; RAM64M8 up to 64; banks of RAM64M8 above 64.
- **Read slots:** one read port's view of 1 bit (2 bits for RAM32M16). Slots are packed **port-major**, 7 per primitive, so one read port's bits sit in few primitives. Port H is the write port.
- **Count:** RAM64M8 per bank = ⌈NR × WIDTH / 7⌉.
- **Simulation:** keeps the behavioural model. `TG_SIM_PRIMS` selects the mapping, with primitive models, for the unit test.

| Shape | Primitives (formula = Vivado) | LUTs |
|---|---|---|
| 64 × 64, 7 read ports (a register-file bank) | 64 RAM64M8 | 512 |
| 64 × 64, 9 read ports (a 3-ALU bank) | 83 RAM64M8 | 664 |
| 32 × 64, 3 read ports | 14 RAM32M16 | 112 |
| 128 × 64, 2 read ports | 38 RAM64M8 (2 banks) | 304 + mux |
| 10 × 13, 1 read port | 1 RAM32M16 | 8 |

**Why this matters for 3-wide.** Read ports beyond 7 cost primitives, not whole bank copies. A 9-port bank is 83 primitives, not 2 × 64.

**The primitive check.** [`tools/tcl/tg_prim_check.tcl`](../../tools/tcl/tg_prim_check.tcl) (a new file in the coordinator's area; please review) runs after `synth_design` and again after `opt_design`.
- **What it checks:** every `tg_ram_lut`, `tg_ram_sdp` and `tg_ram_tdp` instance, against the primitive counts its port widths imply. The wrappers keep their hierarchy for this (`keep_hierarchy`).
- **Exact for LUTRAM and URAM.**
- **Block RAM:** checks the family, and warns if the count differs from the smallest mapping.
- **Strays:** lists inferred RAMs outside the wrappers.
- **Demonstrated:** a test top with one unused read port passes after synthesis (the hierarchy is kept) but fails after `opt_design`: 64 → 55 RAM64M8. That is the "silently dropped read port" the plan warns about.
- **Integration:** the spike flow calls it on every run (`prim_synth.txt`, `prim_opt.txt`). Other flows source the file and call `tg_prim_check -file <report>`; it raises an error on a mismatch.

**Tests.** [`tests/unit/prim`](../../tests/unit/prim): random reads and writes on six shapes, against a reference array, for both the behavioural model and the primitive mapping.

---

## 4. S2: wakeup → select

**Structure** ([`tg_iq`](../../fpga/spikes/rtl/tg_iq.sv) + [`tg_wake`](../../fpga/spikes/rtl/tg_wake.sv); harnesses [`tg_s2_iq_top`](../../fpga/spikes/rtl/tg_s2_iq_top.sv) for one queue and [`tg_s2_sched_top`](../../fpga/spikes/rtl/tg_s2_sched_top.sv) for the whole scheduler).
- **Rows:** 10 per ALU queue; plan §4.6 sizes for the others. Rows are interleaved across the dispatch ports, so every port has rows even in the 4-row STA queue at width 3.
- **Readiness:** an AND-OR of a dependency vector against the woken vector W. W has one column per wakeup ID: ROB entries plus LLTs, so 48 + 16 for st, 80 + 24 for smt2 and 96 + 24 for smt2_w3.
- **Select:** oldest first, through an allocation-order age matrix (upper triangle).
- **Wakeup at select:** 1-cycle ops set their ID's W bit as they are selected; others through delay lines and LLT completions.
- **Shadow cancel:** a 2-cycle issue hold. A cancel returns the rows and undoes their W bits.
- **SMT2:** per-thread caps at 75% of each queue.
- **Flush:** per thread, by ROB age.

The whole-scheduler harness has every queue of §4.6: A0..A(N_ALU−1), LD, STA and FP. They share one W, and the ALU queues wake across queues. That is the loop that matters.

### 4.1 One queue, and the stale-dependency variants (smt2, 104 columns)

| Stale-dependency handling | Wakeup encoding | CLB LUTs | FFs | WNS ns | Levels |
|---|---|---|---|---|---|
| Guard: an ID is not reused while a row still depends on it (busy vector) | one-hot ID per row | 2,097 | 4,382 | +0.124 | 9 |
| Guard | predecoded {ID/8, ID%8} | **1,874** | 3,552 | +0.156 | 9 |
| Phase bit (the plan's alternative) | one-hot | 2,822 | 5,735 | +0.248 | 10 |
| Phase bit | predecoded | 2,651 | 4,905 | +0.384 | 10 |
| Column clear when the producer is freed | one-hot | 2,517 | 4,382 | +0.152 | 9 |
| Column clear | predecoded | 2,299 | 3,553 | +0.278 | 9 |

One queue closes 200 MHz in every variant. The guard with predecoded wakeup IDs is the cheapest.

**The phase bit is unsafe for LLTs.** The random test found the failure, and the cause is general:
- LLTs come from a pool, so one LLT can be freed and reallocated twice while a row still waits on its first instance (for example, on a second, long-latency source).
- The phase then wraps and the row waits forever.
- The phase bit is only safe for IDs reused in allocation order (ROB entries). It also costs about 780 LUTs per queue more than the guard, and its scheduler was the slowest (§4.2).
- **Recommendation:** the guard.
- **The guard's cost:**
  - a busy vector, which is an OR of all rows' dependency bits per column;
  - a stall of ROB allocation, but only when a waiting row's producer ID comes round again. That needs a nearly full window behind a stalled instruction.
- **The cheaper alternative** clears column c when c's producer is freed. It needs no busy vector, but costs LUT logic per dependency bit (Vivado will not use the flip-flops' set/reset pins for it). It came out +425 LUTs per queue against the guard.

### 4.2 The whole scheduler

Options measured (all in `tg_iq`):
- **DUP_SEL:** a second copy of the select drives only the wakeup broadcast, so the grant net on the loop has a small fanout.
- **EARLY_W = 24:** only the source tags sit in flip-flops behind the grant mux; the rest of the payload is in per-bank LUTRAM, read in the RF stage.
- **MX:** matrix wakeup for in-queue 1-cycle producers. A row names them by ALU-queue row and is ready when those rows are selected. The protected loop becomes grant → issued register → readiness → select, with no wakeup-ID encode or decode. W follows a cycle later.
- **PRE_RDY**, with MX: each row's ID readiness is computed a cycle early from W's next state.
- **ALU_ROWS:** the plan's fallback, smaller ALU queues.

| Run | Config | Options | CLB LUTs | FFs | WNS ns | Levels | Placement |
|---|---|---|---|---|---|---|---|
| `s2_sched_st_guard` | st | plan structure (guard, predecoded IDs) | 6,081 | 7,819 | −0.063 | 8 | free |
| `s2_sched_st_opt` | st | + DUP_SEL, EARLY_W | 5,416 | 6,059 | **+0.180** | 10 | free |
| `s2_sched_smt2_guard` | smt2 | plan structure | 7,846 | 10,108 | −0.101 | 9 | free |
| `s2_sched_smt2_clear` | smt2 | column clear instead of the guard | 9,116 | 10,115 | −0.530 | 9 | free |
| `s2_sched_smt2_phase` | smt2 | phase bit instead of the guard | 10,363 | 14,582 | −0.705 | 10 | free |
| `s2_sched_smt2_opt` | smt2 | + DUP_SEL, EARLY_W | 7,790 | 8,358 | −1.296 | 11 | free, scattered (2.4 ns clock insertion) |
| `s2_pb_smt2_opt` | smt2 | + DUP_SEL, EARLY_W | 7,701 | 8,350 | −0.521 | 11 | pblock |
| `s2_sched_smt2_mx` | smt2 | + DUP_SEL, EARLY_W, MX | 9,165 | 9,292 | +0.065 | 9 | free |
| `s2_pb_smt2_mx` | smt2 | + MX, grant registered before the wakeup encode | 8,895 | 9,104 | **+0.112** | 7 | pblock |
| `s2_sched_smt2w3_guard` | smt2_w3 | plan structure | 10,576 | 13,741 | −0.652 | 9 | free |
| `s2_sched_smt2w3_opt` | smt2_w3 | + DUP_SEL, EARLY_W | 10,516 | 11,546 | −0.457 | 9 | free |
| `s2_pb_smt2w3_mx` | smt2_w3 | + DUP_SEL, EARLY_W, MX | 12,515 | 13,042 | **+0.057** | 8 | pblock |
| `s2_pb_smt2w3_mxpre` | smt2_w3 | + DUP_SEL, EARLY_W, MX, PRE_RDY | 12,404 | 13,110 | −0.363 | 10 | pblock |
| (queued) | smt2_w3 | 8-row ALU queues; without MX (pblock) | | | | | pblock |

**What limits the loop.** Without MX, the loop is: W → readiness (3 LUT levels over 64–120 columns) → oldest-first select (2) → wakeup encode (2) → W update (1–2). That is 8–11 levels, and routing is 75–80% of the delay. The W bits fan out to every row of every queue, and the grants to the payload and the wakeup encode.

With MX the 1-cycle loop no longer passes through W. In `s2_pb_smt2_mx`:
- **The W path** (W → wakeup register) has +0.60 ns.
- **The worst path** is W → readiness → select → payload register: 7 levels, not a loop.

**PRE_RDY does not help.** It computes each row's ID readiness from W's next state. With MX the grant is registered before the wakeup encode, so that path becomes registered grant → encode → W's next state → readiness → row register: 10 levels, −0.363 ns at smt2_w3, where MX alone has +0.057. It is dropped.


---

## 5. S3: register file, bypass and the ALU loop

**Structure** ([`tg_s3_top`](../../fpga/spikes/rtl/tg_s3_top.sv)):
- **Register file:** the writer-sharded file ([`tg_irf`](../../fpga/spikes/rtl/tg_irf.sv)). It has N_ALU + 1 banks of 64 × 64 bits, one write port each; B1's write port also takes the MUL/DIV/CSR/FP-to-int results through a mux.
- **Read ports:** 2 per ALU, plus LD, STA and the shared store-data port.
- **Bypass:** an operand mux per ALU operand and per address base.
- **ALUs:** N_ALU 1-cycle ALUs ([`tg_alu`](../../fpga/spikes/rtl/tg_alu.sv)): add/sub and W forms, Zba, shifts and rotates, slt, min/max, logic, Zbs, simple Zbb, Zicond.
- **Pipeline:** RF → EX → WB.

| Variant (generics) | Config | CLB LUTs (LUTRAM) | FFs | WNS ns | Levels | Verdict |
|---|---|---|---|---|---|---|
| 2 ALUs, EX+WB bypass, binary 8:1 selects | st | 5,210 (1,536) | 1,802 | **+0.228** | 13 | **pass** |
| 2 ALUs, EX+WB bypass, one-hot selects | st | 5,752 (1,536) | 1,858 | +0.002 | 13 | marginal |
| 2 ALUs, R8: EX-only bypass with write-through | st | 5,243 (1,536) | 1,749 | −0.614 | 16 | fail |
| 2 ALUs, R8, one-hot | st | 5,491 (1,536) | 1,828 | −0.054 | 8 | fail |
| 3 ALUs, banks with 9 read ports ("replication"), 10:1 selects | st_w3 | 8,713 (2,656) | 2,306 | +0.040 | 17 | pass, marginal |
| 3 ALUs, read ports shared, 7 per bank (R11) | st_w3 | 7,977 (2,048) | 2,171 | +0.036 | 16 | pass, marginal |
| 3 ALUs, replication, R8 | st_w3 | 8,427 (2,656) | 2,198 | +0.026 | 15 | marginal |
| 3 ALUs, sharing, R8 | st_w3 | 7,716 (2,048) | 2,121 | −0.374 | 17 | fail |

Named paths of the chosen 2-ALU variant (`s3_st_byp0_oh0`):

| Path | Slack ns | Levels | Logic ns | Net ns |
|---|---|---|---|---|
| ALU → bypass → ALU loop | +0.228 | 13 | 1.67 | 2.99 |
| Branch flags | +0.943 | 9 | 1.43 | 2.49 |
| RF read: tag → LUTRAM → bank mux → operand register | +0.655 | 2 | 0.49 | 3.73 |
| RF write (load result → LUTRAM data input) | +0.296 | 0 | 0.12 | 4.35 |
| LD/STA base operand mux | +1.893 | 2 | 0.37 | 2.63 |

(The table above is from runs without the pblock. Four of them were placed far from the clock source, including the R8 failure. Pblock reruns of the key variants are in §5.1 and supersede these where they differ.)

**Findings.**
1. **The plan's structure closes 200 MHz.**
   - **Register file:** three banks of 64 × 64 with 7 read ports, from explicit RAM64M8, cost **2,020 LUTs**: 1,536 LUTRAM plus 484 for the bank read muxes. That matches the plan's 2.0K.
   - **Bypass:** the 8:1 operand mux uses binary selects computed in the RF stage. It maps to LUT6 + MUXF7, and is cheaper and faster than one-hot.
2. **The worst ALU path is min/max.** It runs: operand mux → the adder's carry chain → the compare → a 64-bit select of a or b → the result OR → the result register.
   - Add/sub (13 levels, 8 of them CARRY8) and the shifter have slack to spare.
   - If the core needs margin, give min/max (and minu/maxu) a second cycle, on ALU1 next to clz/ctz/cpop.
3. **3 ALUs close too, but only marginally.** The 10:1 bypass passes at +0.04 ns. S6 shows whether that survives the full chip.
4. **Bank replication is cheap with RAM64M8.** 4 banks × 9 read ports cost 3,268 LUTs, against 2,020 for 3 banks × 7: **+1.25K, not the +2.7K** of plan §4.15.
   - **Lever R11** (shared, arbitrated ports) saves only 0.74K.
   - **What R11 costs:** IPC from port conflicts, and an arbitration term in the select loop. S2 shows that loop is the tighter one.
   - **Recommendation:** replication for v2. R11's estimate (~1.7K) in §8.5 should drop to ~0.7K.
5. **Lever R8 (EX-only bypass with write-through) does not close reliably.**
   - **Why:** it puts the register-file write data (64-bit, fanning out to 7–9 primitive copies) on the ALU's slowest path.
   - **Results:** it missed by 0.61 ns with 2 ALUs; it closed by 0.03 ns with 3 ALUs and replication, but failed with sharing. That is placement noise around a path with no margin.
   - **Recommendation:** keep the WB bypass level. R8's ~0.5K saving is not available at 200 MHz.

**Adopt** (production intent, with tests):
- [`tg_alu.sv`](../../fpga/spikes/rtl/tg_alu.sv) and [`tg_alu_pkg.sv`](../../fpga/spikes/rtl/tg_alu_pkg.sv): the control word is pre-decoded before EX.
- [`tg_irf.sv`](../../fpga/spikes/rtl/tg_irf.sv).
- The bypass network as written in [`tg_s3_top.sv`](../../fpga/spikes/rtl/tg_s3_top.sv).
- Test: [`fpga/spikes/sim/tb_alu.sv`](../../fpga/spikes/sim/tb_alu.sv) runs 46 ops against an ISA reference; four injected bugs are caught.

---

## 6. S4: load path

**Structure** ([`tg_s4_top`](../../fpga/spikes/rtl/tg_s4_top.sv), DTLB [`tg_dtlb`](../../fpga/spikes/rtl/tg_dtlb.sv)): AG → M1 → M2, 3-cycle load-to-use (plan §4.9, §4.11).
- **AG:** the base operand through a bypass mux, plus the sign-extended offset. The adder's VA[11:3] drives the address pins of the eight data-way BRAMs directly (VIPT: the index lies inside the page).
- **M1:**
  - the eight ways read: one RAMB36 each, 512 × 64 simple dual port. Port A reads for loads; port B writes refills and stores, with byte enables.
  - the LUTRAM tags read at VA[11:6]: per way, 64 sets × 24 bits, with 2 read ports (loads, and probes/refills);
  - the DTLB lookup: 32 entries, fully associative, Sv39 with 2 MiB/1 GiB pages and {TID, ASID} tags.
- **M2:** tag compare against the DTLB's physical page, way select, and the result register. A miss raises the shadow cancel.
- **Where the align goes:**
  - `ALIGN_M1 = 0`, the plan's structure: align and sign-extend in M2, after the way select.
  - `ALIGN_M1 = 1`: align every way's word in M1 from the raw BRAM outputs, so M2 is only compare and select.

**Why the data ways are simple dual port.** An SDP RAMB36 gives a 64-bit read port and a 64-bit write port with byte enables. Loads and dirty reads only read, and refills and stores only write, so that is exactly the D$'s port use. As true dual port, a RAMB36 port is at most 36 bits wide, and every way would need two BRAMs.

(results: queued)


---

## 7. S5: next PC, I$, pre-decode, compaction

**Structure** ([`tg_s5_top`](../../fpga/spikes/rtl/tg_s5_top.sv)):
- **BP0/IF1:** the fetch PC register and the micro-BTB ([`tg_ubtb`](../../fpga/spikes/rtl/tg_ubtb.sv)), 64 entries, 2-way, LUTRAM, with a partial tag plus the thread ID. They close a 1-cycle loop: hit → target, else PC + 16; redirects (registered) override.
  - The next PC also drives the I$ data address directly: the BRAMs' own address register is the I$ address register. So the loop ends at 16 BRAM address pins, which gives zero-bubble fetch after a redirect.
  - SMT2: the other thread's next PC waits aside, and the registered ICOUNT choice switches threads.
- **IF1:** I$ data, 8 ways × 16 B in 16 RAMB36 with output registers; tags in LUTRAM (8 × 64 × 23 bits); ITLB with 16 fully associative entries.
- **IF2:** tag compare, way select, pre-decode ([`tg_predecode`](../../fpga/spikes/rtl/tg_predecode.sv)): boundaries over 8 parcels with the straddle carry, entry and exit slots, and branch, jump, call and return marks.
- **IF3:** compaction straight into a 16-entry instruction queue of WR LUTRAM banks ([`tg_fetch_compact`](../../fpga/spikes/rtl/tg_fetch_compact.sv)); DECODE_WIDTH instructions leave per cycle.

| Run | Config | Decode | CLB LUTs (LUTRAM) | FFs | RAMB36 | WNS ns | Levels | Verdict |
|---|---|---|---|---|---|---|---|---|
| `s5_st_lut_wr4` | st | 2 | 2,485 (448) | 2,014 | 16 | **+0.582** | 8 | pass |
| `s5_smt2_lut_wr4` (pblock) | smt2 | 2 | 2,566 (448) | 2,090 | 16 | **+0.245** | 8 | pass |
| `s5_w3_lut_wr4` (pblock) | st_w3 | 3 | 2,516 (448) | 2,062 | 16 | **+0.357** | 8 | pass |
| `s5_st_fa_wr4` (32-entry flip-flop fallback) | st | 2 | (queued) | | | | | |

Named paths, `s5_st_lut_wr4`:

| Path | Slack ns | Levels | Logic ns | Net ns |
|---|---|---|---|---|
| Next-PC loop: PC → micro-BTB LUTRAM → tag compare → next-PC mux → PC | **+1.914** | 6 | 0.72 | 2.29 |
| Next PC → I$ BRAM address pins | +0.923 | 6 | 0.72 | 2.71 |
| IF2: tags, ITLB page → compare → way select → pre-decode → IF3 registers | +0.582 | 8 | 1.14 | 2.92 |
| IF3: compaction → instruction-queue LUTRAM write | +1.127 | 8 | 1.16 | 2.47 |
| Instruction queue read → decode registers | +1.721 | 3 | 0.64 | 2.51 |

Named paths, `s5_w3_lut_wr4` (decode width 3):

| Path | Slack ns | Levels | Logic ns | Net ns |
|---|---|---|---|---|
| Next-PC loop | **+1.824** | 6 | 1.02 | 2.05 |
| Next PC → I$ BRAM address pins | +0.638 | 6 | 1.03 | 2.69 |
| IF2 → IF3 registers (the straddle carry is the worst endpoint) | +0.357 | 8 | 1.35 | 2.92 |
| IF3: compaction → instruction-queue LUTRAM write | +1.100 | 7 | 0.99 | 2.54 |
| IF3: compaction state (half-instruction register) | +1.563 | 7 | 1.06 | 2.14 |
| Instruction queue read → decode registers | +1.392 | 3 | 0.74 | 2.75 |

**Findings (width 2).**
- **The 64-entry LUTRAM micro-BTB closes the next-PC loop with 1.9 ns to spare.** It costs 154 LUTs, 64 of them LUTRAM.
  - The flip-flop fallback is not needed at width 2; its run reports the comparison.
  - Even with the BRAM address pins in the loop there is +0.9 ns, so the zero-bubble redirect path holds.
- **Pre-decode in IF2 and compaction in IF3 both fit**, with +0.58 and +1.13 ns. The plan's 9-cycle mispredict path (§3.2) stands at width 2.
- **IF3 cost:** compaction plus the queue is 981 LUTs, 128 of them LUTRAM.
  - The queue is 4 banks of RAM32M16. Compaction selects straight into the banks, so no rotation stage follows it.
  - **Instruction-queue capacity:** 4 entries deep per bank use 4 of the RAM32M16's 32 rows. Flip-flops would cost more LUTs in write muxes, so LUTRAM stays.

**Findings (width 3).**
- **Decode width 3 closes too, at +0.357 ns**, with the same structure: 4 instruction-queue banks written per cycle, 3 read.
  - The worst path is IF2 again, now ending at the straddle-carry register. The next-PC loop keeps 1.8 ns.
  - The cost does not grow with width: 2,516 LUTs against 2,485 at width 2. The fetch block is 16 B either way; only the queue's read side widens.
- **Verdict: S5 passes at widths 2 and 3, and no §8.1 fallback is needed.** The 32-entry flip-flop micro-BTB is not needed; its run is kept for the comparison.


---

## 8. S6: dual-core floorplan dry run and fill test

**What the design is** ([`tg_s6_top`](../../fpga/spikes/rtl/tg_s6_top.sv)): two cores and the uncore, run on the whole device. Out of context, the clock source is as in §2.
- **Each core** ([`tg_s6_core`](../../fpga/spikes/rtl/tg_s6_core.sv), generated by [`gen_s6_core.py`](../../fpga/spikes/scripts/gen_s6_core.py)):
  - **Real structures:** the four spikes with their chosen options: S2 (the whole scheduler), S3 (register file, bypass, ALUs), S4 (load path, 8 data BRAMs) and S5 (front end, 16 I$ BRAMs).
  - **Synthetic logic** ([`tg_s6_fill`](../../fpga/spikes/rtl/tg_s6_fill.sv)) supplies the rest of the core's budget:
    - tiles of 32 LUT6 in four levels between registers, wired mostly to neighbouring tiles with some long taps;
    - LUTRAM blocks, for the FP register file, ROB, FTQ, free lists and LSQ data;
    - 18 RAMB36 (TAGE, BTB, L2 TLB);
    - 54 DSP48E2 (MUL, FMA, Goldschmidt).
  - **Wiring:** every spike input is a synthetic register, and every spike output feeds the synthetic logic, so nothing is trimmed.
- **The uncore** ([`tg_s6_l2`](../../fpga/spikes/rtl/tg_s6_l2.sv)):
  - **L2 data:** the real 1 MiB, 32 UltraRAM, in 2 banks of 4 wide × 4 deep, with a pipelined cascade (read latency 4).
  - **L2 tags and directory:** 2 × 1K × 224 bits in block RAM.
  - **Injector buffers:** 2 × 512 × 128 in block RAM.
  - **Synthetic logic** for the rest of §8.2's 13.3K uncore LUTs.
- **Buses:** the cores reach the L2 over 256-bit registered buses that cross the chip.
- **Sizing:** [`s6_size.py`](../../fpga/spikes/scripts/s6_size.py) splits a total LUT target. The uncore gets 13.3K; each core gets the rest, as the measured spike LUTs plus synthetic logic.
- **Utilisation check:** each run stops after synthesis if CLB LUTs miss the target by more than 2.5%.

**The fill test** (plan §8.5): the smt2 design (the v1 release core) filled to 80%, 85% and 90% of the XCK26's 117,120 LUTs, timed at 5.0 ns. Fmax = 1 / (5.0 ns − WNS).

(being measured)


---

## 9. S1: PL → PS DDR latency and bandwidth

**Status: ready for the board.** The design, the A53 program and the steps for you are in [`fpga/spikes/s1/README.md`](../../fpga/spikes/s1/README.md).

**What it measures.**
- **Latency**, in 5 ns core cycles at the PL port, from the read-address handshake to the first data beat: what the L2 sees on a miss.
  - Idle: dependent 64 B reads (a random pointer chase written by the A53), within one 2 MiB page and over 256 MiB; 16 B reads; both HP ports.
  - Under load: the chase while the other HP port streams reads or writes, and while four A53 threads copy memory.
- **Bandwidth:** sequential 64 B and 256 B bursts with 1–32 outstanding, random 64 B reads, writes, and both ports at once.

**PL design** ([`fpga/spikes/s1`](../../fpga/spikes/s1)).
- **Engines:** two `tg_s1_engine`s, AXI4 masters on S_AXI_HP1_FPD and S_AXI_HP2_FPD, 128-bit at 200 MHz (`pl_clk0` 100 MHz → MMCM).
- **Control:** AXI4-Lite registers on M_AXI_HPM0_FPD at `0xA000_0000`.
- **Fan:** the KV260 fan is held on.
- **Device-tree overlay:** sets the AFI port widths. If they are not set, the PS and PL disagree on the bus width.

**Simulation.** `fpga/spikes/s1/sim/tb_s1.sv` runs the PL logic against AXI memory models with random latency and out-of-order responses. It passes, on three seeds:
- the chase follows the chain;
- latencies match the model;
- the histogram sums to the count;
- two engines stream at about one beat per cycle together;
- writes carry the right `wlast`.

**Open items S1 settles** (plan §5.5):
- **The carve-out:** none is needed to measure; the program uses hugepages.
- **SMMU bypass:** a DECERR response means the SMMU blocks PL masters; the README says what to send back.
- **The native latency point:** it replaces `tgsim`'s 30/60-cycle bracket.

(Results will go here once the board run is done.)

---

## 10. RTL and tests for the core track

Production-intent RTL from the spikes, written to the conventions and parameterized by `tg_pkg`. It is lint-clean with `-Wall` in all four configurations (`make -C fpga/spikes lint`). It lives in `fpga/spikes/rtl` until the core track moves it into `rtl/core`.

| Structure | RTL | Test (`make -C fpga/spikes/sim ...`) | Notes |
|---|---|---|---|
| Multi-port LUTRAM | `rtl/common/prim/tg_ram_lut.sv` | `make -C tests/unit/prim` | explicit RAM64M8/RAM32M16 under SYNTHESIS |
| Primitive-count check | `tools/tcl/tg_prim_check.tcl` | spike flow, every run | call after synth_design and opt_design |
| Issue queue | `tg_iq.sv` | `iq`: 24 variants; 8 + 2 injected bugs caught | options: STALE, WAKE_ENC, DUP_SEL, EARLY_W, MX |
| Woken vector | `tg_wake.sv` | with `tg_iq` | HIST must match the wakeup path's delay |
| Integer ALU | `tg_alu.sv`, `tg_alu_pkg.sv` | `alu`: 46 ops vs ISA reference | pre-decoded control word |
| Register file | `tg_irf.sv` | via `tg_ram_lut` tests | writer-sharded, generic read ports |
| Bypass network | `tg_s3_top.sv` (operand muxes) | — | binary selects from the RF stage |
| DTLB / ITLB | `tg_dtlb.sv` | — | fully associative, Sv39 superpages, {TID, ASID} |
| Micro-BTB | `tg_ubtb.sv` | — | 64 × 2-way LUTRAM, or 32 FA flip-flops |
| Pre-decode (IF2) | `tg_predecode.sv` | `fetch`: 4 variants; 4 injected bugs caught | boundaries, straddles, branch marks |
| Compaction + instruction queue (IF3) | `tg_fetch_compact.sv` | `fetch` | writes straight into banked LUTRAM |
| DDR engine (S1) | `fpga/spikes/s1/rtl/tg_s1_engine.sv` | `fpga/spikes/s1/sim/tb_s1.sv` | measurement only |
