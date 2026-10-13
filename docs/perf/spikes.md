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
- **Placement noise.** Small RTL changes move results by up to a few hundred picoseconds. S3's lever R8 is an example: it failed by 0.61 ns with 2 ALUs but passed with 3. **Margins under about 0.3 ns are marginal.**
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

(to be completed)

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

(to be completed)

---

## 7. S5: next PC, I$, pre-decode, compaction

(to be completed)

---

## 8. S6: dual-core floorplan dry run and fill test

(to be completed)

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
