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

| Spike | Verdict at 200 MHz | Width 2 | Width 3 | Fallback needed |
|---|---|---|---|---|
| S2 wakeup → select (§4) | **pass**, with options | st +0.110 ns, 5.3K LUTs; smt2 +0.112, 8.9K | smt2_w3 +0.057, 12.5K | MX (matrix wakeup) at smt2 and smt2_w3; 8-row ALU queues for margin at smt2_w3 |
| S3 register file, bypass, ALU loop (§5) | **pass with min/max on the 2-cycle path** | +0.342 ns (+0.014 with min/max), 5.1K | +0.052 (−0.086 with min/max), 8.6K | min/max to 2 cycles (trim 3); R8 rejected |
| S4 load path, 3-cycle load-to-use (§6) | **pass** | +0.678 ns, 2.4K (align in M2) | — | none |
| S5 next PC, I$, pre-decode, compaction (§7) | **pass** | st +0.582, smt2 +0.245; 2.5K | +0.357, 2.5K | none |
| S6 floorplan and fill test (§8) | v1 **200 MHz to 88% fill**; v2 191 MHz at 89% | smt2: +0.105 at 84%, +0.007 at 88% | smt2_w3: −0.238 at 89% | v2: the S2, S3 and DTLB levers above |
| S1 PL → PS DDR (§9) | bitstream built (+0.513 ns) | — | — | waiting for the board |

**What changes for the plan.**
- **The scheduler is the budget problem** (§10). It closes timing, but costs 1.9× the plan's estimate at st, 3.1× at smt2 and 4.3× at smt2_w3. With the FPU's 7.6K (D17), the projection puts v1 at 85–94% of the XCK26 (about 90%) after the identified levers, and v2 at 97–109%.
- **The utilisation limit** (§8): v1 holds 200 MHz to about 88% fill. Plan with 85%, and treat 88–90% as the ceiling if M6 agrees.
- **min/max leave the 1-cycle ALU** (§5.1). That gives the 2-ALU loop +0.47 ns and lets 3 ALUs close.
- **The register file is cheaper than planned.** Explicit RAM64M8 gives 7 read ports per 64 × 64 bank in 64 primitives. Replicated banks for 3 ALUs cost +1.25K, not +2.7K, so R11 (shared ports) saves only 0.74K.
- **R8 (EX-only bypass) does not close** and is rejected.
- **The front end has margin at both widths.** The 64-entry LUTRAM micro-BTB closes the next-PC loop with 1.8 ns to spare.
- **Memory primitives map deterministically** through `tg_ram_lut` (explicit RAM64M8/RAM32M16), and every synthesis run checks the primitive counts (§3).

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

**Tests.** Every spike structure has a random simulation test with a reference model. All are listed in §11.

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
| `s2_pb_smt2w3_opt` | smt2_w3 | + DUP_SEL, EARLY_W (no MX) | 10,547 | 11,541 | −0.781 | 10 | pblock |
| `s2_pb_smt2w3_mx_r8` | smt2_w3 | + DUP_SEL, EARLY_W, MX, ALU queues of 8 rows (§8.1 fallback) | 10,986 | 11,430 | **+0.069** | 10 | pblock |
| `s2_pb_st_opt` | st | + DUP_SEL, EARLY_W | 5,307 | 6,059 | **+0.110** | 10 | pblock |
| `s2_pb_st_mx` | st | + DUP_SEL, EARLY_W, MX | 6,425 | 6,855 | +0.145 | 6 | pblock |
| `s2_pb_smt2_base` | smt2 | plan structure | 7,858 | 10,108 | −0.249 | 8 | pblock |
| `s2_pb_smt2_mxr` | smt2 | + DUP_SEL, EARLY_W, MX, ISS_REG | 9,050 | 9,164 | +0.055 | 7 | pblock |
| `s2_pb_smt2w3_mxr` | smt2_w3 | + DUP_SEL, EARLY_W, MX, ISS_REG | 12,167 | 13,168 | +0.054 | 7 | pblock |

**What limits the loop.** Without MX, the loop is: W → readiness (3 LUT levels over 64–120 columns) → oldest-first select (2) → wakeup encode (2) → W update (1–2). That is 8–11 levels, and routing is 75–80% of the delay. The W bits fan out to every row of every queue, and the grants to the payload and the wakeup encode.

With MX the 1-cycle loop no longer passes through W. In `s2_pb_smt2_mx`:
- **The W path** (W → wakeup register) has +0.60 ns.
- **The worst path** is W → readiness → select → payload register: 7 levels, not a loop.

**Named paths at smt2_w3** (slack in ns):

| Path | MX, 10 rows | MX, 8-row ALU queues | no MX |
|---|---|---|---|
| Registered grant → wakeup encode → W | +0.396 | +0.592 | −0.781 (the loop itself) |
| W → readiness → select → issue state ("age") | +0.132 | +0.223 | −0.488 |
| Issued register → readiness (MX) → select → payload register | **+0.057** (worst) | above +0.069 | — |
| Flush → per-thread room counters (harness fan-out) | +0.139 | +0.069 (worst) | −0.567 |

**PRE_RDY does not help.** It computes each row's ID readiness from W's next state. With MX the grant is registered before the wakeup encode, so that path becomes registered grant → encode → W's next state → readiness → row register: 10 levels, −0.363 ns at smt2_w3, where MX alone has +0.057. It is dropped.

**S2 verdict: which §8.1 fallbacks are needed.**
- **st:** none. DUP_SEL and EARLY_W close the loop with the plan's 10-row queues (+0.180 unconstrained, +0.110 with the pblock). MX is not needed at st; it adds 1.1K LUTs for +0.035 ns.
- **smt2 (v1):** MX is required (+0.112 with it, −0.521 without). Queue sizes stay at 10 rows.
- **smt2_w3 (v2):** MX is required (−0.781 without). With it, 10-row queues close at +0.057, which is marginal.
  - **The 8-row ALU-queue fallback** gives the select path +0.22 ns and saves 1.5K LUTs per core. Its worst path is then the harness's flush fan-out, which a real dispatch stage registers locally.
  - **S6 shows** whether the 10-row version survives the full chip. If it does not, v2 takes the fallback.
- **Cost:** the scheduler is far above the plan's estimate at every width (§10), so its LUTs matter as much as its timing.
- **ISS_REG does not help.** That option takes each row's "issued" bit from its own register, replicated for fanout, instead of a LUT. It removes a logic level (7 instead of 8), but the slack does not improve: +0.054 against +0.057 at smt2_w3, and +0.055 against +0.112 at smt2. Run-to-run noise is about 0.05–0.1 ns. It stays off by default.


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

### 5.1 Pblock reruns, and min/max off the 1-cycle path

| Run | Config | Variant | CLB LUTs (LUTRAM) | FFs | WNS ns | Levels |
|---|---|---|---|---|---|---|
| `s3_pb_st_byp0` | st | 2 ALUs, EX+WB bypass (chosen) | 5,277 (1,536) | 1,802 | +0.014 | 17 |
| `s3_pb_st_byp1` | st | 2 ALUs, R8 | 5,226 (1,536) | 1,718 | +0.004 | 15 |
| `s3_pb_st_nomm` | st | 2 ALUs, EX+WB bypass, **min/max on the 2-cycle path** | 5,082 (1,536) | 1,794 | **+0.342** (ALU loop +0.470) | 0 / 11 |
| `s3_pb_w3_rf0` | st_w3 | 3 ALUs, replicated banks | 8,710 (2,656) | 2,306 | −0.086 | 15 |
| `s3_pb_w3_rf1` | st_w3 | 3 ALUs, shared ports (R11) | 8,001 (2,048) | 2,177 | −0.323 | 16 |
| `s3_pb_w3_byp1_rf0` | st_w3 | 3 ALUs, replicated banks, R8 | 8,405 (2,656) | 2,236 | −0.215 | 15 |
| `s3_pb_w3_rf0_nomm` | st_w3 | 3 ALUs, replicated banks, **min/max on the 2-cycle path** | 8,579 (2,656) | 2,294 | **+0.052** | 9 |

**What changes.**
- **The chosen 2-ALU design closes with only +0.014 ns** under the pblock (+0.228 unconstrained). Both runs show the same min/max path; the difference is placement.
- **Without min/max the 2-ALU loop has +0.47 ns.** The worst path is then the register-file write address (+0.342), with no logic levels.
- **3 ALUs fail with min/max in the 1-cycle ALU** (−0.086 ns) and pass without it (+0.052). R11 (shared ports) is worse in timing (−0.323) and saves 0.71K LUTs.
- **Recommendation:** min/max go to the 2-cycle path at both widths. The cost is one more cycle of latency on min/max/minu/maxu, which are rare in integer code. The 3-wide loop still has little margin: the 10:1 bypass mux and the carry chain.

**Findings.**
1. **The plan's structure closes 200 MHz.**
   - **Register file:** three banks of 64 × 64 with 7 read ports, from explicit RAM64M8, cost **2,020 LUTs**: 1,536 LUTRAM plus 484 for the bank read muxes. That matches the plan's 2.0K.
   - **Bypass:** the 8:1 operand mux uses binary selects computed in the RF stage. It maps to LUT6 + MUXF7, and is cheaper and faster than one-hot.
2. **The worst ALU path is min/max.** It runs: operand mux → the adder's carry chain → the compare → a 64-bit select of a or b → the result OR → the result register.
   - Add/sub (13 levels, 8 of them CARRY8) and the shifter have slack to spare.
   - **Recommendation (from §5.1): give min/max/minu/maxu a second cycle** on ALU1, next to clz/ctz/cpop (`tg_alu` MINMAX = 0; plan §8.4 trim 3). That buys +0.43 ns on the 2-ALU loop and is what lets 3 ALUs close.
3. **3 ALUs close only without min/max** (§5.1). With them, the pblock rerun fails by 0.086 ns, and S6's v2 floorplan by 0.159.
4. **Bank replication is cheap with RAM64M8.** 4 banks × 9 read ports cost 3,268 LUTs, against 2,020 for 3 banks × 7: **+1.25K, not the +2.7K** of plan §4.15.
   - **Lever R11** (shared, arbitrated ports) saves only 0.74K.
   - **What R11 costs:** IPC from port conflicts, and an arbitration term in the select loop. S2 shows that loop is the tighter one.
   - **Recommendation:** replication for v2. R11's estimate (~1.7K) in §8.5 should drop to ~0.7K.
5. **Lever R8 (EX-only bypass with write-through) brings nothing** (§5.1).
   - **Why:** it puts the register-file write data (64-bit, fanning out to 7–9 primitive copies) on the ALU's slowest path, and the operand mux it removes is small.
   - **Results with the pblock:**
     - with 2 ALUs, +0.004 ns against +0.014 for the WB bypass, and 51 fewer LUTs;
     - with 3 ALUs, −0.215 against −0.086, and 305 fewer LUTs.
     - The unconstrained run's −0.614 was a placement artifact.
   - **Recommendation:** keep the WB bypass level. R8's planned ~0.5K saving does not appear (51–305 LUTs measured).

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

| Run | Config | Align | CLB LUTs (LUTRAM) | FFs | RAMB36 | WNS ns | Levels | Verdict |
|---|---|---|---|---|---|---|---|---|
| `s4_st_alignm2` (pblock) | st | in M2 (plan) | **2,375** (448) | 3,665 | 8 | **+0.678** | 7 | pass |
| `s4_st_alignm1` (pblock) | st | in M1, per way | 2,803 (448) | 3,672 | 8 | +0.785 | 4 | pass |

Named paths, `s4_st_alignm2`:

| Path | Slack ns | Levels |
|---|---|---|
| AG: base mux + offset adder → data-way BRAM address pins | +1.350 | 4 |
| AG → M1 virtual-address register | +2.356 | 5 |
| M1: data-way BRAM → M2 register | +1.277 | 0 |
| M1: DTLB lookup (32 entries, fully associative) → physical page register | +0.924 | 7 |
| M1: DTLB hit | +1.487 | 6 |
| M1: tag LUTRAM read | +2.755 | 1 |
| M2: tag compare → way select → align and extend → result register | **+0.678** | 7 |
| M2: hit → shadow cancel | +2.034 | 6 |

**Findings.**
- **The 3-cycle load-to-use holds at 200 MHz with the plan's structure**, align in M2, with +0.68 ns. The §8.1 fallback (4 cycles) is not needed.
- **Aligning in M1 is not worth it.** It moves 3 levels out of M2, but costs 428 LUTs (8 aligners instead of 1) for +0.11 ns.
- **The path to watch is the DTLB lookup in M1.** It has +0.92 out of context, but it is the one S4 path that lost slack in the full chip: +0.17 in S6 at 88% fill (v1), −0.11 in the v2 floorplan (§8). A smaller DTLB (trim 4) or a registered page-match stage would recover it.
- **Cost:** 2,375 LUTs for AG, 8 data ways, tags, DTLB and M2. The rest of the LSU (queues, forwarding, MSHRs) is outside this spike.


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
| `s5_st_fa_wr4` (pblock; 32-entry flip-flop fallback) | st | 2 | 3,589 (384) | 4,532 | 16 | +0.286 | 8 | pass, worse |

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
- **Verdict: S5 passes at widths 2 and 3, and no §8.1 fallback is needed.**
- **The flip-flop fallback is worse on both counts:** the 32-entry fully associative micro-BTB costs 1.1K LUTs more (3,589 against 2,485), and its next-PC loop has +0.58 ns against +1.9.


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

| Run | Config | CLB LUTs (fill) | LUTRAM | FFs | BRAM36 / URAM / DSP | WNS ns | Fmax MHz | Worst path | Implementation time |
|---|---|---|---|---|---|---|---|---|---|
| `s6_smt2_85` | smt2 (v1) | 98,218 (83.9%) | 11,826 | 78,411 | 101 / 32 / 108 | **+0.105** | **204** | filler → S2 per-thread room counter | 25 min |
| `s6_smt2_90` | smt2 (v1) | 103,369 (88.3%) | 11,826 | 82,832 | 101 / 32 / 108 | **+0.007** | **200** | S2: W → readiness → select → payload, 7 levels | 40 min |
| `s6_smt2w3_88` | smt2_w3 (v2) | 104,598 (89.3%) | 14,468 | 80,195 | 101 / 32 / 108 | −0.238 | 191 | S2: MX issued → readiness → select → payload, 8 levels | 35 min |
| `s6_smt2_80` | smt2 (v1) | (rerun queued; the first attempt missed its LUT target) | | | | | | | |
| `s6_st_76` | st | (running) | | | | | | | |

Named paths, slack in ns (the worst over both cores):

| Path | smt2, 84% | smt2, 88% | smt2_w3, 89% |
|---|---|---|---|
| S2: registered grant → wakeup encode → W | +0.759 | +0.858 | +0.377 |
| S2: issue payload | +0.983 | +0.683 | +0.868 |
| S3: ALU → bypass → ALU (min/max in the 1-cycle ALU) | +0.159 | +0.062 | **−0.159** |
| S3: register-file read | +0.474 | +0.390 | +0.205 |
| S4: M2 compare, select, result | +0.314 | +0.265 | +0.373 |
| S4: DTLB lookup in M1 | +0.371 | +0.166 | **−0.112** |
| S5: next-PC loop | +0.871 | +1.152 | +0.294 |
| S5: next PC → I$ BRAM address | +0.301 | +0.466 | +0.013 |
| S5: IF3 compaction → instruction queue | +0.527 | +0.592 | +0.551 |
| L2: UltraRAM cascade input | +0.414 | +0.795 | +1.254 |
| Core → L2 bus (registered, crosses the chip) | +3.232 | +2.089 | +3.140 |
| Synthetic logic | +0.274 | +0.130 | +0.109 |

**Findings.**
- **v1 (smt2) holds 200 MHz up to about 88% fill.** It has +0.105 ns at 84% and +0.007 at 88%, so Fmax falls about 2% across that range.
  - **What limits it is the protected loops,** S2 and S3, which are already marginal out of context. Congestion is not the limit: it stays at level 5 (moderate) at 88%.
  - **The L2 is not a problem.** The 4-deep UltraRAM cascade and the core-to-L2 buses keep +0.4 ns or more.
- **v2 (smt2_w3) at 89% runs at 191 MHz.** Three paths fail:
  - **the S2 MX path** (−0.238). The 8-row ALU queues give it about +0.1–0.2 (§4.2);
  - **the 3-ALU bypass loop** (−0.159), with min/max still in the 1-cycle ALU. §5.1 takes them out;
  - **the DTLB lookup** (−0.112): a smaller DTLB or a registered page match.
  - Each fix has a measured or plausible lever, so v2 at 200 MHz is not ruled out. At 191 MHz, the 3-wide's +13% IPC would still be worth +8% over 2-wide at 200 MHz.
- **Placement.** The L2's 32 UltraRAM sit in the right-hand column (clock regions X2Y1–X2Y3), so the cores' buses cross the chip with room to spare.
- **For the §8.5 utilisation limit:**
  - the data support up to about 88% for v1 at 200 MHz;
  - the synthetic logic is mostly local wiring, so it places and routes more easily than real core logic would. The limit should therefore keep some margin: **85% as the planning figure, 88–90% as the ceiling if M6 timing agrees.**
- **Caveats.**
  - S6's cores were generated before the S3 and S4 verdicts: S3 still has min/max in the 1-cycle ALU, and S4 aligns in M1.
  - The filler adds no LUTRAM-heavy units beyond the 2,400 LUTs per core of plan §8.2.


---

## 9. S1: PL → PS DDR latency and bandwidth

**Status: the bitstream is built and meets 200 MHz (WNS +0.513 ns; 4,081 LUTs, 5,133 flip-flops, one block-RAM tile).** It is ready for the board. The design, the A53 program and the step-by-step instructions (SD image, boot firmware, network, files, commands) are in [`fpga/spikes/s1/README.md`](../../fpga/spikes/s1/README.md).

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

**Timing.** The first build missed 200 MHz by 0.425 ns: the PS port's response ID went through the slot mux, the latency subtract, the histogram shift and saturate, and into the histogram BRAM's address, 12 levels in one cycle. The engine now registers the responses as they leave the PS port, then the latency sample, then the histogram bin. The issue time is stored as the handshake cycle + 1, so the measured latency is unchanged.

**Simulation.** `fpga/spikes/s1/sim/tb_s1.sv` runs the PL logic against AXI memory models with random latency and out-of-order responses. It passes on four seeds:
- the chase follows the chain;
- the engine's count, sum, minimum, maximum and every histogram bin match a reference computed from the port handshakes. That check found a lost update in the first histogram design: the BRAM is read-first, so a read missed the write at its own clock edge. A fourth forwarding stage fixes it;
- two engines stream at about one beat per cycle together;
- writes carry the right `wlast`.

**Open items S1 settles** (plan §5.5):
- **The carve-out:** none is needed to measure; the program uses hugepages.
- **SMMU bypass:** a DECERR response means the SMMU blocks PL masters; the README says what to send back.
- **The native latency point:** it replaces `tgsim`'s 30/60-cycle bracket.

(Results will go here once the board run is done.)

---

## 10. Budget calibration (plan §8.2, §8.5)

**Measured, per core** (out of context, LUTs after routing):

| Structure | Plan §8.2 (ST) | st | smt2 | smt2_w3 |
|---|---|---|---|---|
| Scheduler: every issue queue, W, wakeup delay lines (S2) | 2.9K | **5.4K** | **8.9K** (MX) | **12.5K** (MX); 11.0K with 8-row ALU queues |
| Integer register file, bypass, ALUs (S3) | within RF + bypass 4.6K and integer execution 4.0K | 5.2K (RF 2.0K) | 5.2K | 8.7K (3 ALUs, replicated banks; RF 3.3K) |
| Micro-BTB, I$, ITLB, pre-decode, compaction, instruction queue (S5) | within front end 6.1K | 2.5K | 2.6K | 2.5K (`st_w3`) |
| Load path: AG, D$ ways and tags, DTLB, align (S4) | within LSU 6.4K | 2.4K | — | — |
| FPU with Goldschmidt divide/sqrt (FPU track; kept, D17) | 4.7K | 7.6K | 7.6K | 7.6K |

**The scheduler is the outlier, and the FPU the other overrun.** S3, S4 and S5 are within the plan's estimates; S3 at width 3 is under them (+3.5K for the third ALU, its bypass and the fourth bank, against 4.8K planned). The scheduler is 1.9× the plan at st, 3.1× at smt2 and 4.3× at smt2_w3:
- **Readiness** is an AND-OR over every column for every row: 40 rows × 104 columns at smt2, 46 × 120 at smt2_w3.
- **The guard's busy vector** ORs every row's dependency bits per column. The alternatives cost more (§4.1).
- **MX adds about 1.2K** (smt2) and is needed for timing at smt2 and smt2_w3. Its row-dependency bits are cleared per column but written per row, so the clear cannot use the flip-flops' reset and takes a LUT per bit.
- **The plan's 2.9K** was an estimate for st. §6.5's +8.3K per core for SMT2 does not itemise the queues. If its +1.9K for sizes was meant to cover the wider columns, the plan's smt2 scheduler would be at most about 4.7K (2.9K × 104 / 64).

**Overrun against the plan** (measured minus planned, per core):
- st +2.5K;
- smt2 +4.2K to +6.0K (the range is the question of what §6.5 covered);
- smt2_w3 +6.5K to +8.3K, offset by −1.3K in S3.

**Lever updates from the spikes:**
- **R8 (EX-only bypass) is rejected** (§5): −0.5K per core of planned savings is gone.
- **R11 (shared RF read ports) saves 0.74K**, not 1.7K (§5). R11 is v2-only.
- **Smaller ALU queues** (the plan's §8.1 fallback, 10 → 8 rows) save 1.5K per core at smt2_w3, with no timing change (§4.2). §8.1 puts their cost at 1.2–1.5% IPC per 2 entries.

**The FPU is the other overrun.** The FPU track measures 7.6K LUTs per core with the Goldschmidt divide/sqrt, which the user keeps (D17), against §8.2's 4.7K: +2.9K per core, +5.8K per SoC.

**Where v1 (smt2) lands.** These are projections: measured spikes and FPU, plan estimates for everything else. M6 synthesis replaces them.
- **Before area recovery:** ≈105K (§6.5) + 2 × (4.2 to 6.0K) for the scheduler + 5.8K for the FPU ≈ **119–123K LUTs (102–105%)**.
- **The identified levers save 12.7–20.1K per SoC for v1**, without R8:
  - per core, ×2: R1–R7 (free, first commit), R10 and R14;
  - R15 once.
  - R4 and R5 work on the FPU. R5 is measured at −0.33 to −0.43K per core (plan §4.12). If the 7.6K already includes R4 or R5, the range shrinks by up to 2K.
- **After them, v1 lands at ≈99–110K LUTs: 85–94%, about 90% at the midpoint.**
- **The fill test (§8) says v1 holds 200 MHz to about 88%** (≈103K). So v1 fits at 200 MHz only with the levers in the upper half of their range, or with more savings:

| Further saving (per SoC) | Saves | Cost | Source |
|---|---|---|---|
| ALU queues 10 → 8 rows (the §8.1 fallback) | ≈2K (1.5K per core measured at smt2_w3) | 1.2–1.5% IPC (§8.1) | S2 |
| min/max on the 2-cycle path | 0.4K | min/max latency +1 | S3 |
| R14 applied to the scheduler and FPU (area directives on non-critical queues, LUT6_2 packing) | not measured | none | plan |
| SMT2 window at ROB 64 (§8.5 contingency): 88 instead of 104 columns | ≈2.6K in the scheduler, plus ROB storage | −1.5% throughput | S2 scaling |
| The radix-4 divide/sqrt (`FDIV_RADIX4`, the D17 fallback) | 2.8K (1.4K per core, measured) | −2.4% suite IPC (plan §4.12) | FPU track |
| Accept 190–195 MHz above 88% fill | — | −2 to −5% clock | S6 |

**v2 (smt2_w3).**
- **Before area recovery:** the same arithmetic gives ≈136–144K, against the plan's 120–124K.
- **After the v2 levers** (16–23K per SoC, with R8 gone and R11 at 0.74K per core): ≈113–128K (97–109%), over any limit the fill test supports.
- **What v2 needs is a re-plan, not levers.** The scheduler alone is 12.5K per core. Options:
  - a smaller window, which means fewer wakeup columns;
  - queues whose readiness covers only the columns a queue can depend on;
  - fewer ALU-queue rows;
  - a 3-wide core without SMT2.

  S6 also shows v2 at 191 MHz at 89% fill (§8).

---

## 11. RTL and tests for the core track

Production-intent RTL from the spikes, written to the conventions and parameterized by `tg_pkg`. It is lint-clean with `-Wall` in all four configurations (`make -C fpga/spikes lint`). It lives in `fpga/spikes/rtl` until the core track moves it into `rtl/core`.

| Structure | RTL | Test (`make -C fpga/spikes/sim ...`) | Notes |
|---|---|---|---|
| Multi-port LUTRAM | `rtl/common/prim/tg_ram_lut.sv` | `make -C tests/unit/prim` | explicit RAM64M8/RAM32M16 under SYNTHESIS |
| Primitive-count check | `tools/tcl/tg_prim_check.tcl` | spike flow, every run | call after synth_design and opt_design |
| Issue queue | `tg_iq.sv` | `iq`: 30 variants (st, smt2, smt2_w3; guard and column clear; with and without MX); injected bugs caught | options: STALE, WAKE_ENC, DUP_SEL, EARLY_W, MX (PRE_RDY: measured, not recommended) |
| Woken vector | `tg_wake.sv` | with `tg_iq` | HIST must match the wakeup path's delay |
| Integer ALU | `tg_alu.sv`, `tg_alu_pkg.sv` | `alu`: 46 ops vs ISA reference | pre-decoded control word |
| Register file | `tg_irf.sv` | via `tg_ram_lut` tests | writer-sharded, generic read ports |
| Bypass network | `tg_s3_top.sv` (operand muxes) | — | binary selects from the RF stage |
| DTLB / ITLB | `tg_dtlb.sv` | `dtlb` | fully associative, Sv39 superpages, {TID, ASID} |
| Micro-BTB | `tg_ubtb.sv` | `ubtb`: both organisations | 64 × 2-way LUTRAM, or 32 FA flip-flops |
| Pre-decode (IF2) | `tg_predecode.sv` | `fetch`: 4 variants; 4 injected bugs caught | boundaries, straddles, branch marks |
| Compaction + instruction queue (IF3) | `tg_fetch_compact.sv` | `fetch` | writes straight into banked LUTRAM |
| DDR engine (S1) | `fpga/spikes/s1/rtl/tg_s1_engine.sv` | `s1` | measurement only |

Run every test with `source tools/env.sh` first: the Makefiles stop without the pinned Verilator, because the system's 5.020 runs `tb_iq` differently. The whole set: `make -C fpga/spikes/sim -j8 all` (41 tests) and `make -C tests/unit/prim`.
