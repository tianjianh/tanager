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
| S2 wakeup → select (§4) | **pass**, with options | st +0.145 ns with MX, 6.4K LUTs; smt2 +0.112, 8.9K | smt2_w3 +0.057, 12.5K | MX (matrix wakeup) at every width (st needs it in the full chip); 8-row ALU queues for margin at smt2_w3 |
| S3 register file, bypass, ALU loop (§5) | **pass with min/max on the 2-cycle path** | +0.342 ns (+0.014 with min/max), 5.1K | +0.052 (−0.086 with min/max), 8.6K | min/max to 2 cycles (trim 3); R8 rejected |
| S4 load path, 3-cycle load-to-use (§6) | **pass** | +0.678 ns, 2.4K (align in M2) | — | none |
| S5 next PC, I$, pre-decode, compaction (§7) | **pass** | st +0.582, smt2 +0.245; 2.5K | +0.357, 2.5K | none |
| S6 floorplan and fill test (§8) | v1 **200 MHz to 88% fill**; v2 191 MHz at 89% | smt2: +0.043 at 79%, +0.105 at 84%, +0.007 at 88%; st: −0.041 at 76% (no MX) | smt2_w3: −0.238 at 89% | st: MX; v2: the S2, S3 and DTLB levers above |
| S1 PL → PS DDR (§9) | **done on the board**: idle 64 B read 36.8 cycles (184 ns); 3.2 GB/s per HP port, 6.35 GB/s for both; no DECERR | — | — | none |

**What changes for the plan.**
- **The scheduler is the budget problem** (§10). It closes timing, but costs 2.2× the plan's estimate at st, 3.1× at smt2 and 4.3× at smt2_w3. With the FPU's 7.6K (D17), the projection puts v1 at 85–94% of the XCK26 (about 90%) after the identified levers, and v2 at 97–109%.
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
- **What it checks:** every `tg_ram_lut`, `tg_ram_sdp`, `tg_ram_tdp` and `tg_rom` instance, against the primitive counts its port widths imply. The wrappers keep their hierarchy for this (`keep_hierarchy`).
- **Exact for LUTRAM and URAM.**
- **Block RAM:** checks the family, and warns if the count differs from the smallest mapping.
- **Strays:** lists inferred RAMs outside the wrappers.
- **Unread fields (2026-10-14).** A read bit with no load is trimmed by Vivado, and with it every primitive whose read slots all have no load. The expectation now counts only the primitives that hold a loaded bit:
  - a field nobody reads passes, and the line reports it ("14 of 20 read bits loaded"), so the designer can drop it;
  - a primitive missing for a loaded bit still fails. That is the "silently dropped read port" the plan warns about.
  - Before this, the core track's queues failed eight times on fields they never read.
  - **Not trimmed yet (2026-10-14):** `synth_design` can leave an unloaded primitive that `opt_design` removes (the FPU divider's output queue: 8 after synthesis, 7 after `opt_design`). So the count may lie anywhere between the primitives holding a loaded bit and the full mapping; the line shows the range ("expected {RAM32M16 1-2}").
- **Byte writes:** block RAMs with 8-bit byte enables expect the no-parity widths (64/32/16/8 bits).
- **ROMs:** [`tg_rom`](../../rtl/common/prim/tg_rom.sv) (block or distributed) is checked like a single-port block RAM, or as logic.
- **Tested in Vivado:** [`tests/unit/prim/synth/run.sh`](../../tests/unit/prim/synth/run.sh) synthesises one instance of each wrapper, with fields left unread, a byte-write RAM, two ROMs and one stray memory, and checks every report line.
- **Integration:** the spike flow calls it on every run (`prim_synth.txt`, `prim_opt.txt`). Other flows source the file and call `tg_prim_check -file <report>`; it raises an error on a mismatch.

**Tests.** [`tests/unit/prim`](../../tests/unit/prim):
- random reads and writes on six shapes against a reference array, for both the behavioural model and the primitive mapping;
- `tg_fifo` against a queue model;
- `tg_rom` on four shapes.

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
- **st:** MX as well. DUP_SEL and EARLY_W alone close the loop out of context (+0.180 unconstrained, +0.110 with the pblock), but miss by 0.041 ns in the full chip at 76% fill (S6, §8). MX takes the loop out of the 1-cycle path: +0.145 out of context, for 1.1K LUTs.
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

### 7.1 Fetch's timing in M7's chips, before step 5b (2026-10-20)

**Asked** (the coordinator, 10-20): before M7's step 5b adds the thread select to F1, collect fetch's worst paths from the recent routed runs. Find which are the same logical path, their levels, and how much is route against logic. Then propose fixes that are cycle-neutral, FPGA-native and cost no IPC, each with its slack gain and LUT cost. This is measurement only: tg_fetch is core-2's, and step 5b rewrites it.

**Method.**
- Four Vivado queries on routed checkpoints, with every clock's setup uncertainty taken back:
  - [`q_fetch_paths.tcl`](../../fpga/spikes/tcl/query/q_fetch_paths.tcl): per source, each endpoint family's worst path, with its chain.
  - [`q_fetch_fix.tcl`](../../fpga/spikes/tcl/query/q_fetch_fix.tcl): every F2 family, the fpc loop by route, and the queue head.
  - [`q_fetch_f1.tcl`](../../fpga/spikes/tcl/query/q_fetch_f1.tcl): F1's lookups, RAM address and enable pins, and F2's registers.
  - [`q_fetch_f1b.tcl`](../../fpga/spikes/tcl/query/q_fetch_f1b.tcl): F1's near paths in full.
  - [`q_opt_levels.tcl`](../../fpga/spikes/tcl/query/q_opt_levels.tcl): on h100_m7b0's synthesis, the levels with no opt_design, with Default and with ExploreArea, before placement.
- Each query takes 1–4 minutes and peaks at 4 GB.
- Timelines come from the path reports, via [`fetch_rpt.py`](../../fpga/spikes/scripts/fetch_rpt.py).
- Checkpoints:
  - §8.17's chips: h100_m7b0 (URF off) and h100_m7b1 (URF on).
  - core-2's out-of-context smt2 `tg_core` runs: m7s4 (a260dfa9 and 1fc36c72), and m7s5a (cf527d00, its h0 and h1 builds).
  - fpu-2's s1d and s5 core runs.
- Results are in `fpga/spikes/results/fetch_1020/`.

**Three logical paths make up fetch's near-critical set, the same in every run:**

| Path | m7b0 core 0 / 1 (URF off) | m7b1 core 0 / 1 (URF on) | Out of context, 6 runs | Levels | Wire |
|---|---|---|---|---|---|
| **F2's decision:** I$ data or TAGE table RAM → way select → pre-decode or TAGE's direction → the exit search → endpoint | **+0.022 / +0.022** | +0.988 / +1.000 | +0.153 to +1.061 | 15–20 | 48–65% |
| **F1's next PC:** fpc_q → ITLB (CAM, leaf LUTRAM) → PA → PMA → f1_fault → the prediction's select → fpc_q | +0.059 / +0.106 | +1.693 / +1.074 | +0.989 to +2.284 (s5: none below +2.0) | 15–21 | 65–77% |
| **The queue head:** u_cmp's head → bank read address → LUTRAM → RVC expansion → decode → rename's uop register | +0.127 / +0.172 | +1.106 / +1.137 | +0.521 to +1.482 | 16–20 | 66–74% |

- Out of context, F2's cone is +0.15 to +1.06, and its krt_q family takes 15–18 levels. In the chips the family takes 18–20 levels and 0.7–1.0 ns more, mostly wire.
- **The chips' depth is synthesis's.** h100_m7b0's synthesized netlist already maps F2's cone in 18–20 levels, and opt_design adds at most one more.
- **opt_design's ExploreArea (DR-166) deepens F1's loop.** It takes 16 levels to 21 and 19, about −1.3 and −0.9 ns of estimated slack before placement. Default leaves it at 16. The out-of-context runs use Default, and the chips ExploreArea.
- **The fetch fixes alone don't move m7b0's WNS.** The next paths there belong to other units, all in core 0:
  - the LSU's DTLB → m2_dword_q, +0.038;
  - the D$ metadata LUTRAM, +0.042;
  - the CSR's mie → fs, +0.045.
- **What the fixes buy is room for step 5b.**

**F2's decision is one cone with two sources.** The chip's worst path is m7b0 core 1's, I$ → krt_q: +0.022, 19 levels, 3.91 ns of logic and 6.01 ns of wire. Its timeline:

| Step | At (ns from the clock) |
|---|---|
| The I$ RAMB36's clock-to-out (1.19 ns), then 0.70 ns of wire to the way select (LUT6 + MUXF7) | 1.89 |
| The parcel, fanout 6–8 (a 0.59–0.72 ns net) | 2.73 |
| Pre-decode, 5 LUTs, to pd_* | 4.05–4.86 |
| TAGE, the other source: two cascaded RAMB36 (CASDOUT 1.565 + 0.027 + 0.136 = 1.73 ns, against 1.19 for the I$'s 72-bit read), then 6 LUTs of direction, to tdir | 4.68–4.73 |
| The flat exit search joins the two sources | 5.8–6.0 |
| The decision's fanout nets (fanout 12–24) | 7.5–9.1 |
| fx_tgt, after 1–3 LUTs per endpoint family | 9.9 |

The decision itself reaches a flip-flop with about +0.9 ns: f3_meta_q.hit (= tk) is at +0.998 and +0.874. Every family below that loses its slack in its own tail:

| Endpoint family (m7b0; endpoints) | Core 0 | Core 1 | Its tail after the decision |
|---|---|---|---|
| f3_meta_q.target (38) | **+0.022** | +0.107 | `fx_tgt = fe_ras ? rtgt : f2_tgt_q`: the select (fanout 35–48, 0.44–0.57 ns), then the 64-bit mux |
| krt_q (38) | +0.040 | **+0.022** | the same mux |
| The RAS's p_pop_q / p_push_q | +0.133 / +0.532 | +0.220 / +0.246 | fetch's ras_pop LUT, then tg_ras's `&& !flush` LUT (core 1's are merged) |
| u_fgh, the FTQ's history LUTRAM (14) | +0.145 | +0.275 | gh_cm/gh_pk, 2 LUTs, then the RAMD32's data setup (0.138) |
| kimm_q (20) | +0.182 | +0.447 | ovr_imm: 6 LUTs (the exit's immediate, then the no-exit default) |
| TAGE's own table write, g_tab → g_tab (144) | +0.267 | +1.345 | 8 levels from a cascaded table's output to the write port (67% wire) |
| gp_n_q / f3_meta_q.tsrc | +0.372 / +0.994 | +0.334 / +0.270 | the block's branch count; `tk && …` |
| kr_q, ka_q, k_ovr_q, carry_q, kt_q, f3_meta_q.hit | +0.60 to +1.04 | +0.47 to +0.87 | 0–2 LUTs: the decision itself |

**F1's next-PC loop.**
- The worst loop runs through the ITLB's PPN, 19 levels with 74% wire:
  - fpc_q (fanout 26, 0.90 ns) → the ITLB's CAM compare (3 LUTs);
  - → the leaf LUTRAM's address (fanout 36, 0.66 ns) → the PPN → the PA;
  - → PMA decode (5 LUTs) → f1_fault (fanout 60, 0.55 ns);
  - → the next-PC select (`(pred_hit && !f1_fault) ? pred_tgt : seq_pc`) → fpc_q.
- **The loop's other routes have much more slack** (m7b0 core 0 / core 1):
  - the micro-BTB: +1.714 / +3.035;
  - the ITLB's hit: +2.438 / +2.339;
  - the PTE's ph bit: +2.739 / +3.776.
- **fpc_q's next input is F2's hold chain:**
  - The chain runs u_cmp's room → blk_ready (10 LUTs in u_cmp) → f2_go.
  - f2_go is one LUT4 with fanout 76 (1.2–1.9 ns of wire).
  - It ends at fpc_q's enable at +1.436 / +1.604, at TAGE's RAM enables at +0.901 / +1.535, and at the I$'s at +1.736 / +2.311.
- **F1's lookups read fpc_q directly.** The I$ tag LUTRAMs' read-address bits have fanout 214–324; the rest of F1's lookups sit at +1.4 or more, except f2_pmpd_q:
  - In bare mode, the PMP checker takes fpc_q through the `xl_i ? pw_pa_q : fpc_q` mux.
  - In core 1 that path has +0.361 with 7.66 ns of wire: xl_f_q fanout 58 (1.28 ns), then the mux with fanout 20 (2.08 ns).
  - The same path in core 0 has +1.399.

**The queue head is decode's cone.**
- head_q (fanout 126–190) → each bank's row address (head plus the bank's offset; one LUT3, fanout 182, 0.66 ns) → the LUTRAM read → RVC expansion (5 LUTs) → decode (9 LUTs) → rename's uop register.
- G8's QUEUE_DECODE switch already cuts it from 19 to 12 levels. It is off and costs +324 LUTs a core.

**Fixes: cycle-neutral, with no IPC cost and exact unless noted.**

| # | Fix | Where | Gain (estimated from the reports) | Cost a core |
|---|---|---|---|---|
| **G** | **Drop f1_fault from the next-PC select:** `fpc_q <= pred_hit ? pred_tgt : seq_pc` (proof below) | tg_fetch | fpc_q's worst input: +0.059 / +0.106 → **+1.44 / +1.60** (the hold chain); the loop itself → +1.71 / +2.34 | 0 LUTs |
| **A** | **krt_q takes the stack's top (rtgt), not fx_tgt** (proof below) | tg_fetch | krt_q's 38 endpoints leave the cone (+0.040 / +0.022 → several ns) | 0 LUTs; krt_q can keep just ras_top's 38 bits |
| **B** | **Select f3_meta_q.target after F3's register:** the field takes f2_tgt_q; F3 also registers fe_ras and ras_top, and selects at u_cmp's meta input, the field's only reader | tg_fetch | the 38 target endpoints become one flip-flop like kr_q (+0.022 / +0.107 → about +0.6 / +0.7) | ~0 LUTs (the select moves from F2 to F3); +39 FFs |
| **F** | **TAGE's tagged tables without the depth cascade:** xpm `CASCADE_HEIGHT = 1`, so two RAMB36 at 2K × 18 sit side by side instead of 1K × 36 stacked | a parameter on tg_ram_tdp (spikes' prim, default unchanged), set on tg_tage's g_tab | **−0.40 ns on every TAGE-sourced path**, including TAGE's training write and the per-RAM enable LUT2. Measured by `tests/unit/prim/synth/casc.sh`: the slowest bit reads in 1.39–1.40 ns against 1.79–1.81. The first estimate, 0.53, compared the cascade with the I$'s 72-bit read (1.19), but a 2K × 18 port is slower | 0 LUTs, the same 4 RAMB36 |
| **C** | **tg_ras (LATE): drop `&& !flush` from p_push_q and p_pop_q.** d_push and d_pop already exclude a flush: tg_ras.sv's assertion checks it, and fetch's ft_we carries !redirect | tg_ras | up to +0.4 where opt_design didn't merge the gate (core 0's +0.133 path); 0 where it did (core 1's) | −2 LUTs |
| **D** | **Write u_fgh's gh_cm/gh_pk a cycle later from a register;** the entry's other fields stay on time. Decode's redirect reads a block's entry 2 cycles after delivery at the earliest (for core-2 to confirm) | tg_fetch | +0.2 (registering gh_cm/gh_pk) to +0.5 (registering their inputs: tk, feh, the block's branches, 17 bits) | +17–26 FFs; 0–8 LUTs (a split LUTRAM) |
| **E** | **kimm_q:** drop the no-exit default (`im[0]` when !fe_v), since kimm_q is read only under kt_q (= tk), when there is an exit. **tsrc:** register tk and its two other terms, and AND them after F3 | tg_fetch; the walk check's compare gains `!r_tk \|\|` | kimm_q about +0.3, tsrc about +0.6 | 0 LUTs; +2 FFs |

- **G is exact.**
  - Every F1 fault becomes an F2 fault block: f2_fault_q, and a fault block never misses.
  - F2 delivers the fault block, stops fetch (stop_q, k_stop_q) and drops the block behind it (ka_q). So the block F1 fetches after a faulting one is never delivered.
  - The block behind it in F2 has f2v = 0, so it starts no miss or walk. The prefetcher starts only on demand misses. So the change is cycle-identical too.
  - With step 5b the same holds per thread.
- **A is exact.** krt_q is read only under kr_q, and kr_q is registered fe_ras. In that cycle fx_tgt is rtgt.
- **Estimated result in the URF-off chip, with A–F together:** F2's worst goes from +0.022 to about +0.22 in core 1 (its RAS ops, whose gate is already merged) and about +0.4 in core 0. F1's worst into fpc_q goes from +0.059 to +1.44.
- **The next wall is the decision's own tails, at +0.22 to +0.6:** p_pop/p_push in core 1, gp_n_q, ka_q, k_ovr_q, carry_q. Tail fixes cannot pass the decision's own +0.9.

**Where step 5b's thread select lands.**
- **At fpc_q's D input** (the next-PC mux, with a registered choice), it lands only on the loop. G gives that loop +1.4 to +1.7.
- **After per-thread PC registers**, it adds a level to every F1 lookup that now reads fpc_q directly: the tag LUTRAMs (fanout 324), the I$ and TAGE addresses, the ITLB, and the PMP checker. The tightest of these is core 1's f2_pmpd_q at +0.361.

**Larger options, each needing a build:**
- **Pre-decode at refill:**
  - Store each parcel's class as if an instruction starts there, beside its data. Three bits are needed (none, branch, JAL, JAL call, JALR, JALR call, JALR pop), because the JALR-pop split feeds the candidate itself.
  - That removes 3–4 of pre-decode's 5 levels: about 1 ns on the I$ source, and about +0.5 on the whole cone with F.
  - It needs 24 more bits per way-row, so a third RAMB36 per way: +16 RAMB36 a chip (125 → 141 of 144).
- **Synthesis without `-flatten_hierarchy none` for the front end** (DR-113's setting): the cone crosses the tg_predecode, tg_tage and tg_ras boundaries, where synthesis merges no LUTs and only opt_design's remap merges some (core 1's RAS gate). One chip with g4_fit's `-flatten rebuilt` measures it.
- **A front-end pblock:** the wire share is the same out of context (48–65%), but the chip adds about 0.7 ns of wire to this cone. Measure it before adopting.
- **F1's near paths:**
  - replicate xl_f_q into fetch (+1 FF), and give the PMP checker its own copy of the address mux (core 1's +0.361);
  - replicate f2_go per RAM group (+2–3 LUTs; TAGE's enable at +0.901, about +0.6–1.0).
- **The queue head:**
  - QUEUE_DECODE (+324 LUTs a core);
  - or a max_fanout on the banks' row address (fanout 182 → about 4 × 46): about +0.35, +~36 LUTs a core.

**Learned.**
- **Below the decision, the cone is a wall of tails.** The two worst families end one 64-bit select after the decision. Each of the next five is only 0.1–0.2 ns better. Removing one family moves the worst path by that much, and the decision's own +0.9 at a flip-flop bounds what tail fixes can buy.
- **`-flatten_hierarchy none` keeps LUTs on both sides of a module boundary**, such as ras_pop in fetch and `&& !flush` in tg_ras. opt_design's remap merged that pair in core 1 but not in core 0, so the same RTL got different depths.
- **Vivado cascaded TAGE's 2K × 36 true-dual-port tables in depth on its own** (CASCADE_HEIGHT 0, its default), at 0.40 ns more clock-to-out than a width split of the same two RAMB36. A port's clock-to-out depends on its width: a 2K × 18 port reads in 1.39–1.40 ns, the I$'s 512 × 72 in 1.19.
- **TAGE's tagged tables are the chip's only block RAMs in a depth cascade** ([`q_bram_cascades.tcl`](../../fpga/spikes/tcl/query/q_bram_cascades.tcl) on h100_m7b0): 8 RAMB36, read slack +0.022 to +0.235. The D$ data (four ×36 RAMB36 a way), the I$ data (×72), TAGE's base and the FPU's ROM are single RAMs. The L2's data banks are UltraRAM cascades by design (+4.9 ns or more).
- **ExploreArea's remap traded depth for LUTs on F1's loop.** Before placement the loop went from 16 levels to 19–21. In the routed chip the loop's worst route is ITLB → PMA → f1_fault, which G takes out of the loop.


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
  - **Calibration**, from two smt2 runs of 542 and 610 tiles: a tile costs 36.3 LUTs, and the filler's fixed glue about 1.85K per core.
  - **The first sizing** used a per-tile cost measured before a DSP fix, so the first st and smt2 runs came out about 4K under target. The runner now retries a miss once, with the measured difference.
- **The spike structures measure the same inside S6 as out of context, within 2%** (smt2: S2 8,744 vs 8,895, S3 5,252 vs 5,277, S4 2,840 vs 2,803, S5 2,613 vs 2,566). So the out-of-context numbers in §10 hold in the full design.
- **Utilisation check:** each run stops after synthesis if CLB LUTs miss the target by more than 2.5%.

**The fill test** (plan §8.5): the smt2 design (the v1 release core) filled to 80%, 85% and 90% of the XCK26's 117,120 LUTs, timed at 5.0 ns. Fmax = 1 / (5.0 ns − WNS).

| Run | Config | CLB LUTs (fill) | LUTRAM | FFs | BRAM36 / URAM / DSP | WNS ns | Fmax MHz | Worst path | Implementation time |
|---|---|---|---|---|---|---|---|---|---|
| `s6_smt2_85` | smt2 (v1) | 98,218 (83.9%) | 11,826 | 78,411 | 101 / 32 / 108 | **+0.105** | **204** | filler → S2 per-thread room counter | 25 min |
| `s6_smt2_90` | smt2 (v1) | 103,369 (88.3%) | 11,826 | 82,832 | 101 / 32 / 108 | **+0.007** | **200** | S2: W → readiness → select → payload, 7 levels | 40 min |
| `s6_smt2w3_88` | smt2_w3 (v2) | 104,598 (89.3%) | 14,468 | 80,195 | 101 / 32 / 108 | −0.238 | 191 | S2: MX issued → readiness → select → payload, 8 levels | 35 min |
| `s6_smt2_80` | smt2 (v1) | 92,866 (79.3%) | 11,826 | 73,830 | 101 / 32 / 108 | **+0.043** | **201** | synthetic logic (the spikes have ≥ +0.087) | 26 min |
| `s6_st_76` | st (bring-up) | 88,495 (75.6%) | 11,818 | 70,066 | 101 / 32 / 108 | −0.041 | 199 | S2 without MX: W → readiness → select → wakeup → W, 10 levels | 35 min |

Named paths, slack in ns (the worst over both cores):

| Path | st, 76% | smt2, 79% | smt2, 84% | smt2, 88% | smt2_w3, 89% |
|---|---|---|---|---|---|
| S2: wakeup loop (st: W → select → W; MX builds: registered grant → encode → W) | **−0.041** | +0.310 | +0.759 | +0.858 | +0.377 |
| S2: issue payload | +1.440 | +0.862 | +0.983 | +0.683 | +0.868 |
| S3: ALU → bypass → ALU (min/max in the 1-cycle ALU) | +0.013 | +0.146 | +0.159 | +0.062 | **−0.159** |
| S3: register-file read | +0.204 | +0.187 | +0.474 | +0.390 | +0.205 |
| S4: M2 compare, select, result | +0.083 | +0.114 | +0.314 | +0.265 | +0.373 |
| S4: DTLB lookup in M1 | +0.144 | +0.087 | +0.371 | +0.166 | **−0.112** |
| S5: next-PC loop | +1.726 | +1.118 | +0.871 | +1.152 | +0.294 |
| S5: next PC → I$ BRAM address | +0.566 | +0.423 | +0.301 | +0.466 | +0.013 |
| S5: IF3 compaction → instruction queue | +0.351 | +0.495 | +0.527 | +0.592 | +0.551 |
| L2: UltraRAM cascade input | +1.035 | +0.866 | +0.414 | +0.795 | +1.254 |
| Core → L2 bus (registered, crosses the chip) | +2.285 | +2.456 | +3.232 | +2.089 | +3.140 |
| Synthetic logic | +0.268 | +0.043 | +0.274 | +0.130 | +0.109 |

**Findings.**
- **v1 (smt2) holds 200 MHz up to about 88% fill.** It has +0.043 ns at 79%, +0.105 at 84% and +0.007 at 88%.
  - Across that range Fmax shows no trend, only placement noise of about ±0.1 ns.
  - The per-path slacks move by up to 0.4 ns between runs, with no order by fill.
  - **What limits it is the protected loops,** S2 and S3, which are already marginal out of context. Congestion is not the limit: it stays at level 5 (moderate) at 88%.
  - **The L2 is not a problem.** The 4-deep UltraRAM cascade and the core-to-L2 buses keep +0.4 ns or more.
- **st at 76% misses by 0.041 ns, on its scheduler loop.** The st scheduler runs without MX, so its 1-cycle wakeup loop still passes through W: 10 levels. Out of context it closed at +0.110; inside the chip it does not.
  - With MX (+0.145 out of context) that loop leaves the 1-cycle path.
  - **So MX belongs in every configuration** (§4.2), for 1.1K LUTs at st.
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

### 8.1 DR-133 gate 3: the UltraRAM register file in a v1 full chip (2026-10-14)

**Question (the FPU track, DR-133):** with execute's register-file operand ports in UltraRAM (`IRF_URAM = 1`: 12 URAM288 per core, one per bank and ALU operand port), do both cores' UltraRAMs and the L2's 32 share the device's URAM sites with v1 still closing 200 MHz?

**Method:** [`tg_g3_top`](../../fpga/spikes/rtl/tg_g3_top.sv): two real smt2 cores from the test branch `claude/track-fpu-395911-dr133-gate3` (4d32933) and the S6 L2 stand-in (its 1 MiB L2 in 32 UltraRAMs), placed and routed out of context at **200 MHz** with DR-113's settings. The cores' inputs are random registers and their outputs feed the L2 stand-in (the S6 method), since real v1 (about 127K LUTs) does not fit the device. For this gate only, two known cross-unit core path families were cut (`g3_false_paths.tcl`): LSU `r_data_q` → ROB `exr_*` (matched 128 → 78 cells per core), and execute `wbq_q` → ROB `cmp_q` (matched no `cmp_q` cells, so it cut nothing). The core track owns those paths.

**Result** (92,542 LUTs, 79%; 56 of 64 URAM; 118 DSP; 114 block-RAM tiles):

| Path (slack in ns at 5.0 ns) | Core 0 | Core 1 |
|---|---|---|
| Issue (`u_is`, the wakeup/grant) → UltraRAM read address | **−4.833** (10 levels, 7.2 ns of wire) | **−5.476** (8 levels, 8.2 ns of wire) |
| Worst UltraRAM input of the core | −6.332 (from P4's `iq_rd_q`, 9.5 ns of wire) | −5.476 |
| UltraRAM data → `ex_a_q` | +0.971 (2 levels) | +1.163 |
| UltraRAM data → `ex_b_q` | +1.003 | +1.429 |
| Anything → `ex_a_q` | −0.547 (from the issue queue's `early_q`) | — |
| L2: into its UltraRAMs / its responses | +1.175 / +1.816 | |

- **Placement:** the XCK26's 64 UltraRAMs are all in clock-region column X2, 16 per region. The L2 took X2Y0 and X2Y1 (32), and the cores' 24 went to X2Y2 and X2Y3 (12 each). Each core's issue and execute logic is spread over the device, so its read address crosses up to a region to reach its UltraRAMs.
- **So the input side fails by about 5 ns, all of it wire;** the output side passes with about 1 ns.
- **The chip's WNS is −10.923 ns**, set by the cores' own deep paths (16–48 levels in the worst 2,000 endpoints, the worst `u_ex/ex_sa_q` → `u_rob/exr_rob_q` at 48 levels), not by the UltraRAMs. Those failures also steer the placer, so this run is pessimistic for the UltraRAM paths; but they fail on wire length, which a column the L2 shares does not shorten.
- **Verdict:** `IRF_URAM = 1` does not close 200 MHz in the v1 full chip as built: keep `IRF_URAM = 0`. A floorplan that puts each core's issue and execute logic against its UltraRAM region could recover part of the 5 ns, but the grant still has to reach a fixed column in one cycle, and tg_exec alone had only +0.002 to +0.019 ns out of context.
- Peak memory 11.1 GB (20 declared).

### 8.2 Floorplanning the real core (2026-10-15)

**Question (the core track's floorplan brief):** the whole st core misses 200 MHz out of context by 5–7 ns, with wire at 65–75% of every deep path. Do per-unit pblocks shorten that wire?

**Method:** [`fp_core.tcl`](../../fpga/spikes/tcl/fp_core.tcl) opens the core track's routed checkpoint of `tg_core` (st at 6d0523e, its unit timing flow: DR-113's settings, one clock from a BUFGCE in X1Y2; WNS −5.464 ns), clears placement and routing, applies a floorplan, then places, routes and reports the core track's path families. The floorplans use [`fp_lib.tcl`](../../fpga/spikes/tcl/fp_lib.tcl): pblocks by clock-region column and CLB row.
- **XCK26 regions (3 × 4), per region:** X0 has 11,040 LUTs and 144 DSPs and no block RAM; X1 has 8,640 LUTs, 12 RAMB36 and 144 DSPs; X2 has 9,600 LUTs, 24 RAMB36, 16 URAM and 24 DSPs.

| Floorplan | WNS ns | Failing endpoints | Cross-unit paths in the 2,000 worst | Median levels | Wire per hop (median) |
|---|---|---|---|---|---|
| none (re-placed: the control) | −5.353 | 31,750 of 110K | 707 | 25 | 0.233 ns |
| compact: the whole core in X1Y1:X2Y3 (78% full) | −5.235 | 31,650 | 409 | 26 | 0.216 ns |
| units: one pblock per unit after the brief's adjacency (62–78% full) | −5.536 | 30,826 | 379 | 26 | 0.228 ns |

- **The worst paths are deep, not long.** In every run the 2,000 worst have a median of 25–26 logic levels (p90 28–29), with 0.22–0.23 ns of wire per hop and 0.14 ns of logic per level. Wire is 63–64% of the delay because every level adds a hop. S6's paths that close at 200 MHz have 7 levels at 0.31–0.44 ns per hop, so their hops are longer.
- **So floorplanning moves WNS by ±0.2 ns** (the control itself is 0.1 ns from the core track's run). At about 0.36 ns per level a 5 ns cycle holds about 12 levels, so 200 MHz needs the deep families at about half their depth.
- **Per-unit pblocks halve the cross-unit paths among the worst** (707 → 379), but most of the worst endpoints are inside one unit: in the control, 756 are in fetch and 537 in the LSU, of 2,000.
- **The core track's conclusion (core-2):** restructure the deep families and choose pipeline cuts (DR-135, DR-137). No more floorplan variants for now; a placement check follows once a family's levels come down.
- Results: `fpga/spikes/results/fp_st_{none,compact,units}/` (summary, `paths.tsv`, family reports, per-pblock utilisation).

### 8.3 G4: the v1 full chip in the board's top (2026-10-15)

**Question (the SoC track, DR-136):** in the real placement, which of the uncore's register slices close 200 MHz with their main data register in DSPs, and what are the uncore's LUTs, DSPs and WNS? Also, how do the crossbar's paths from and to the cores look? Out-of-context uncore runs don't time those.

**Method:** [`g4_fit.tcl`](../../fpga/spikes/tcl/g4_fit.tcl) builds `kv260_top` as the board build does: the PS block design, the MMCM and both clocks, the PMOD console and the fan rule.
- **Design:** two real smt2 cores at 200 MHz, from main at 759ea6a.
- **Mask:** main's `UNCORE_DSP` default, 64'h84_0308_0000. That puts the device bus's A slice, the L2 banks' C slices and the memory W slices in DSPs.
- **Synthesis:** DR-113's settings, without which v1 doesn't fit.
- **Implementation:** the board build's place-and-route flow.
- **False paths:** the two known core families are cut, as in gate 3.

**Size** (107,536 LUTs, 91.8%; 115 block-RAM tiles; 32 URAM; 144 DSPs): each core has 44.6K LUTs and 59 DSPs. The uncore has 18,344 LUTs, 16,856 flip-flops, 26 DSPs (21 in the five DSP sites, 4 in the ACLINT's timers and 1 in the UART), 16 RAMB36, 4 RAMB18 and 32 URAM. Synthesis took 47 minutes, placement 26 and routing 2 h 25: the timing passes took WNS from −12.8 to −10.0 ns.

| Path group (slack in ns at 5.0 ns) | Worst | Its path |
|---|---|---|
| The chip | **−10.041** | core 1: the LSU's `r_data_q` → the ROB's `g_ft` write enable, 32 levels |
| Uncore, internal | **−7.145** | L2 bank 0: response tag RAM → MSHR state, 8 levels, 10.6 of 12.0 ns wire |
| Cores → uncore | −4.963 | core 0's LSU `sq_head_q` → the crossbar's B slice, 14 levels |
| Uncore → cores | −6.476 | an ACLINT timer → core 1's rename free-list count, 20 levels (in the core) |
| Uncore → PS | −4.045 | the trace stream → HP3 write data, 7 levels, 7.2 ns of wire |
| PS → uncore | −0.801 | |

**Per site** (in: into the main data register; out: from it):

| Site (bit) | Form | In | Out | Worst in from |
|---|---|---|---|---|
| A, device bus (19) | DSP | −3.603 | −0.443 | core 0's LSU `x_pa_q`, 7 levels |
| C, bank 0 (24) | DSP | −3.623 | +0.513 | core 0's D$ controller, 4 levels |
| C, bank 1 (25) | DSP | −4.651 | +0.132 | core 0's D$ controller, 6 levels |
| W, port 0 (34) | DSP | −0.868 | +2.452 | L2 bank 0's `ws_buf_q`, 4 levels |
| W, port 1 (39) | DSP | −0.141 | +2.996 | L2 bank 1's `ws_buf_q`, 4 levels |
| AW, ports 0 / 1 (33, 38) | fabric | +1.193 / +1.060 | +3.2 / +3.3 | the same `ws_buf_q` |
| D (l1d, l1i, mmio of both cores) | fabric | −2.45 to −3.90 | −0.80 to −2.50 | the L2's D queues; the cores' D$ |
| A, L2 banks / ROM / error | fabric | −3.66, −2.91 / −1.69 / −1.52 | +1.6 to +2.4 | the cores' LSUs, 7–9 levels |
| B, cores 0 / 1 | fabric | −5.140 / −4.962 | +3.2 / +2.8 | the L2's probe state, 14–15 levels |
| AR, ports 0 / 1 | fabric | −2.981 / −3.371 | +3.4 / +3.1 | the L2's MSHRs, 14–16 levels |
| L2 R, banks 0 / 1 | fabric | −4.710 / −5.342 | −4.3 / −2.5 | the L2's put-write state |
| R, B (memory), E | fabric | +1.97 to +2.60 | | |

**The crossbar and the cores:**
- cores → A slices: −3.954 (7 levels; 1.1 ns logic, 7.6 ns wire);
- cores → A arbiters: −2.580 (7 levels; 6.2 ns wire);
- cores → C slices: −4.651 (6 levels; 7.9 ns wire);
- cores → E slices: +1.778;
- D slices → cores: −3.173 (8 levels; 5.9 ns wire);
- B slices → cores: −3.052 (14 levels).

**Findings:**
- **No DSP site closes here, but neither do most fabric sites.** What fails is the logic and distance in front of the slices: the cores' LSUs and the L2. The DSP form itself isn't the cause.
  - Where the source is the same, the DSP form costs what it did out of context. The memory W slices in DSPs have 1.3–2.1 ns less than the AW slices in fabric, fed from the same L2 register: −0.87 and −0.14 against +1.19 and +1.06.
- **The crossbar's core-side paths are mostly wire.** For A and C they carry 6–8 ns of wire on 1.1–1.5 ns of logic over 6–7 levels.
  - An earlier A decode would remove levels. The time, though, is in the distance between the cores' LSUs and the crossbar. That points to a register on each side of the interface.
- **The L2 bank is split across the device.**
  - Its MSHR state sits in rows 0–3 at the bottom left; its response-tag RAM is in rows 89–106, near the cores.
  - Its worst path crosses that span twice: 4.7 and 1.4 ns of wire.
  - Out of context the same bank's worst path is −0.7 to −1.0 ns. L2 endpoints make up about 3,900 of the uncore's (at least) 5,000 failing ones. The rest are the injectors, the AR, B and C slices, the trace stream and the windows.
- **Caveat:** the cores miss 200 MHz by 10 ns in this chip, and the placer works on their paths first. The uncore's figures are therefore pessimistic: they are what it gets in today's full chip.
- **Results:** `fpga/spikes/results/g4_v1_dflt/` (`sites.txt`, `xbar_core.txt`, `uncore_failing.txt`, the summary and the path reports).

### 8.4 G4-FP: what floorplanning buys the uncore (2026-10-15)

**Question (the coordinator, DR-142):** how much of G4's uncore failure is placement, at zero cycle cost, and how much needs RTL or interface registers? The uncore failure means the −7.1 ns inside an L2 bank and the 6–8 ns of wire on the crossbar's core-side paths.

**Method:** G4's design and synthesis exactly (759ea6a, `UNCORE_DSP` 64'h84_0308_0000), with pblocks added after synthesis ([`fp/g4_uncore.tcl`](../../fpga/spikes/tcl/fp/g4_uncore.tcl)).
- **(a) Uncore only.** Each L2 bank gets its own pblock in the X2 column, which holds every URAM.
  - It holds the bank's 16 URAMs in 64 rows of the URAM column (17–18 sites), its logic in the 40 rows in the middle of those, and its 6.5 block-RAM tiles in 20 rows.
  - Bank 0 sits below bank 1, around the clock root's row. The crossbar sits in X1 beside both. The cores and the rest of the uncore are free.
  - Fill: the banks use 4.4K of 6,400 LUTs each, and the crossbar 2.5K of 4,032.
- **(b) Full.** (a) plus each core's LSU against the crossbar. One pblock per whole core doesn't fit: a core is 38% of the device. (b) runs from (a)'s post-synthesis checkpoint.

**(a), against G4** (slack in ns at 5.0 ns):

| | G4 | (a) |
|---|---|---|
| Chip | −10.041 | −9.382 (the cores' paths) |
| Uncore, internal | −7.145 | −6.803 |
| Its worst path | bank 0: response tag RAM → MSHR state, 8 levels, 10.6 ns wire (the bank split across the device) | bank 0: probe pending → probe sent, of both banks, 17–18 levels (3.0 ns logic, 8.3–8.5 ns wire) |
| Cores → crossbar A slices / C slices | −3.954 (7.6 ns wire) / −4.651 (7.9) | **−2.868** (5.9) / **−3.052** (4.6) |
| Cores → crossbar, worst | −4.963 (14 levels: LSU → B slice enable) | −4.991 (the same) |
| D / B slices → cores | −3.173 / −3.052 | −2.781 / −2.743 |
| L2 R slices | −4.710 / −5.342 | **−1.870 / −2.137** |
| Memory AR slices | −2.981 / −3.371 | **−4.671 / −4.132** (worse) |
| Memory W slices (DSP) / AW slices | −0.868, −0.141 / +1.193, +1.060 | **−2.252, −2.398 / −0.729, +0.128** (worse) |
| PS → uncore / uncore → PS | −0.801 / −4.045 | +0.561 / −4.231 |
| Uncore failing endpoints in the L2 banks | 3,927 | 3,113 |

**Findings (a):**
- **The split bank was placement.** With each bank compact, G4's worst path (response tag RAM → MSHR state) goes from −7.1 ns to −1.23 and −1.49 ns in banks 0 and 1. That is 9–10 levels with 4.7–4.9 ns of wire, measured on the routed checkpoint. The L2 R slices gain about 3 ns.
  - The SoC track's registered response shape (cycle-identical, about 72 flip-flops) would take the rest of that path.
  - Other paths into the MSHR state are deeper: −5.47 ns from bank 0's `p2_q` (14 levels) and −4.69 ns from MSHR state to MSHR state in bank 1 (19 levels).
- **The uncore's worst path is now logic depth.** Bank 0's probe-pending state reaches the probe-sent state of both banks through 17–18 levels. At about 0.36 ns per level, 200 MHz holds about 12, so it needs RTL. Placing the banks apart lengthens its wire.
- **Placement recovers 1–3 ns of the crossbar's core-side wire, but not enough:** cores → A slices go from 7.6 to 5.9 ns of wire, and cores → C from 7.9 to 4.6, so these paths still miss by 2.9–3.1 ns. The LSU → B-slice enable path (14 levels) doesn't move.
- **The memory path gets worse.** The injectors, windows and AXI slices end up in X0, near the PS's ports, two region columns from the banks in X2. The AR slices lose 1–2 ns and the W slices 1.4–2.3. With the banks fixed at the URAM column, the bank-to-PS path needs a register stage or a floorplan of its own.
- (a) ran in 51 minutes of synthesis, 25 of placement and 2 h 28 of routing, and peaked at 14.0 GB of 17 declared.
- **(b) did not finish.** Its LSU pblocks were 88–90% full (LUT cells against sites). After 4 hours of routing, its second timing pass had run for 2 hours at about 500 overlapping nodes. It was stopped to free memory for core-2's runs. Its only figure is the chip's −10.49 ns after the first routing pass, against (a)'s −10.99 at the same point. So the G4 refresh (§8.5) uses (a)'s floorplan.
- Results: `fpga/spikes/results/g4fp_uncore/`. The routed checkpoint is in the build tree (`fp/g4fp_uncore_routed.dcp`), for the SoC track's queries.

### 8.5 The G4 refresh: the full chip with today's timing work (2026-10-16)

**Caveat (2026-10-17):** this run's tree synthesizes rename wrong (an undriven free-list pop, in Vivado only; see the start of §8.6), so its timing and LUTs are likely optimistic around rename.

**Question (the coordinator, for the user's clock decision):** the v1 full chip at 200 MHz with all of the day's timing work, in the same tables as §8.3 and §8.4.

**Method:**
- **Tree:** a measurement snapshot, not for merging: main 4a0be01 merged with the FPU track's DR-144 branch at 50fee76. The merge was clean (tree a1b2c69).
- **What the snapshot brings:**
  - core-2's fn5–fn7 timing work;
  - the new default profile: #4, #5 and #9 (B3) on, #2 and #8 off (DR-140, DR-144);
  - the SoC track's DR-143 switches (`AR_SLICE` and one-hot MSHR ways on) and its S3 directory write.
- **Settings:** G4's synthesis and constraints, `UNCORE_DSP` at main's default, `B_SLICE` off (its default), and G4-FP (a)'s floorplan (the L2 banks and the crossbar).
- **Flow:** synthesis wrote a checkpoint first (`-impl 0`, 38 minutes, 14.6 GB). Placement and routing then ran from it (2 h 39, 5.2 GB).

**Size:** 108,564 LUTs (cores 44,786 and 44,986, uncore 18,748), 115 block-RAM tiles, 32 URAM and 144 DSPs: +1.0K against G4.

| Worst slack (ns at 5.0 ns) | G4 | G4-FP (a) | **Refresh** |
|---|---|---|---|
| **Chip (the cores)** | −10.041 | −9.382 | **−7.978** (core 0: DTLB valid → ROB write enable, 28 levels) |
| **Uncore, internal** | −7.145 | −6.803 | **−5.194** (L2 bank 0: directory RAM → MSHR state, 14 levels, 7.5 ns wire) |
| Cores → uncore | −4.963 | −4.991 | −4.732 (LSU `sq_head_q` → crossbar B slice enable, 14 levels) |
| Uncore → cores | −6.476 | −5.675 | −4.167 (ACLINT `mtime` → core 1's rename free-list count, 21 levels, in the core) |
| PS → uncore / uncore → PS | −0.801 / −4.045 | +0.561 / −4.231 | +0.783 / −3.215 |
| The 2,000 worst endpoints' levels | 22–31 mostly | | 15–23 mostly (17 the mode) |

**Per site** (in / out, slack in ns):

| Site | G4 | (a) | Refresh |
|---|---|---|---|
| A.dev (DSP) | −3.60 / −0.44 | −1.85 / −0.51 | −3.03 / −0.03 |
| C, banks 0 / 1 (DSP) | −3.62, −4.65 | −3.05, −3.02 | −3.63, −3.91 |
| W, ports 0 / 1 (DSP) | −0.87, −0.14 | −2.25, −2.40 | −2.31, −1.61 |
| B, cores 0 / 1 | −5.14, −4.96 | −5.15, −4.59 | −4.73, −4.16 |
| D (six) | −2.45 to −3.90 | −2.35 to −3.51 | −2.21 to −3.48 |
| A, L2 banks | −3.66, −2.91 | −2.32, −2.23 | −2.50, −2.58 |
| Memory AR (at the PS) | −2.98, −3.37 | −4.67, −4.13 | **+0.40, +0.72** |
| The new AR slices at the banks (`AR_SLICE`) | — | — | −3.87, −3.31 |
| L2 R | −4.71, −5.34 | −1.87, −2.14 | −2.51, −2.53 |

**The crossbar and the cores:**
- cores → A slices: −3.03 (5 levels, 6.2 ns wire);
- cores → A arbiters: −2.17;
- cores → C slices: −3.91 (6 levels, 5.5 ns wire);
- D slices → cores: −2.91;
- B slices → cores: −3.07.

**Findings:**
- **The chip gains 2.1 ns over G4,** from −10.04 to −7.98, and the uncore 2.0 ns, from −7.15 to −5.19. The worst 2,000 paths are 15–23 levels deep instead of 22–31.
  - At about 0.36 ns per level, 200 MHz holds about 12 levels.
  - At the refresh's −7.98 ns the chip would run at about 77 MHz. The cores' deep paths remain the limit.
- **`AR_SLICE` moves the memory AR problem from the PS side to the bank.** The AXI slices at the PS now pass (+0.40, +0.72). The new slices at the banks fail by 3.3–3.9 ns, on the bank → slice path across the device.
- **The B slices (−4.2 to −4.7) and the cores' LSU → B-slice enable path (14 levels) are unchanged.** `B_SLICE` (off here) is the SoC track's fix for the probe path.
- **The uncore's failing endpoints are still mostly the L2 banks':** 3,476 of at least 5,000. The worst runs from the directory RAM into the MSHR state, 14 levels.
- Results: `fpga/spikes/results/g4r_fpa/` (and `g4r_synth/`). The routed checkpoint is in the build tree (`fp/g4r_fpa_routed.dcp`).

### 8.6 G5, G5R and G6: the full chip at DR-145's targets, 125 and 100 MHz (2026-10-16)

**Caveat (2026-10-17): every tree in this section, and the G4 refresh's (§8.5), synthesizes rename wrong, so their timing and LUTs are likely optimistic around rename.**
- **The bug:** from fn6 (0c4b011, 10-15 04:31) to its fix (24ada50, 10-17), `tg_rename`'s free lists took `.pop(rn_fire)` inside their generate block, about 45 lines before `rn_fire` was declared.
  - Vivado made each use a new, undriven implicit net (INFO Synth 8-11241 "undeclared symbol 'rn_fire', assumed default net type 'wire'", then WARNING Synth 8-605). No free list ever popped, and synthesis removed part of their logic.
  - Verilator resolves the name to the later declaration, so lint and every simulation passed. The board's two-core hang traced to it (the core track).
- **Affected:** the G4 refresh, G5, G5R and G6, and G7's first runs (stopped before any result). G7 re-measures on main with the fix and fn11.
- **Not affected:** G3 (10-14), the §8.2 floorplans (6d0523e), G4 and G4-FP (759ea6a), and the S6 fill tests, whose cores are spike structures without rename.
- **What it changes:** rename's free-list paths were shorter, and its LUTs fewer, than in a correct build. Only a fixed run measures by how much, and whether a rename path then joins the worst ones.
- **The check:** the spike flows now fail on Synth 8-11241, 8-605, 8-3848 ("does not have driver") or 8-8895 ("already implicitly declared") in our sources ([`synth_check.tcl`](../../fpga/spikes/tcl/synth_check.tcl) after synthesis, and a scan of the finished log in the wrappers). Vivado files 8-11241 as an INFO, so the logs' ERROR and CRITICAL WARNING scans never saw it.

**Question (the coordinator, DR-145):** the user's new target is 125 MHz preferred, 100 MHz minimum, for v1 as scoped (2 cores × SMT2). How fast does the full chip run at those targets, with hart 1's area emulated at the final fill?

**Method:** G4's flow and constraints, with the clock changed and two measurement-only patches.
- **Clock:** `CORE_MHZ` sets the MMCM, the PS ports' clocks and the L2's URAM latency (2 stages below 150 MHz), so every clock is its own synthesis.
  - The board's `tg_clkgen` made only clocks that divide 1200 MHz, so G5's snapshot gives it a 1000 MHz VCO for 125 MHz ([`g5_clkgen_patch.py`](../../fpga/spikes/scripts/g5_clkgen_patch.py)). The SoC track has since made the same change on main (a301c14).
  - No timed path crosses between the core clock (125 MHz) and the host clock (100 MHz): the inter-clock table is empty, and the asynchronous clock group holds.
- **Hart 1's area:** until M7 builds it, the smt2 cores run hart 0 only. [`g5_fill_patch.py`](../../fpga/spikes/scripts/g5_fill_patch.py) adds two blocks of S6 filler to the snapshot's `kv260_top`, one per core.
  - Each block is 47 LUT tiles and 20 LUTRAM blocks, 3,714 LUTs placed: the RAM-form estimate of about 3.7K per core (area_recovery.md §7.7).
  - The filler is clocked by the core clock and fed from an LFSR. It is placed freely, and its own paths pass by about 3 ns.
- **Trees:**
  - **G5:** the G4 refresh's tree (main 4a0be01 + 50fee76).
  - **G5R:** core-2's fn10 head 63e51b4. It adds fn8–fn10, the timer registration, A1–A12 and the SoC track's uncore, and is built as the performance build (`TG_COMMIT_TRACE=0`: about −1.1K LUTs per core).
- **Floorplan:** G4-FP (a)'s L2 and crossbar pblocks, with the board flow's directives, unless noted.

| Run | Tree, clock, fill | Placed LUTs | WNS ns (clock reached) | Cores | Uncore | Core → / → core | Failing endpoints |
|---|---|---|---|---|---|---|---|
| `g5_125` | G5, 125 MHz, no filler | 108,123 (92.3%) | −4.135 (82 MHz) | −4.135 / −4.114 | −2.577 | −0.844 / −1.368 | 23,827 |
| `g5_125_fill` | G5, 125 MHz, filler | 117,851 after synthesis (100.6%) | **did not route** (congestion level 6, 14,655 nets) | | | | |
| `g5_125_fill_spread` | the same, free placement, `AltSpreadLogic_high` | 115,221 (98.4%) | −7.502 (64.5 MHz) | −7.502 / −7.187 | −2.971 | −3.952 / −2.966 | 40,475 |
| `g5_100_fill` | G5, 100 MHz, filler | | stopped after 3 h 10 of routing (stalled) | | | | |
| `g5_100_fill_spread` | the same, free placement, spread | | stopped after 2.5 h of routing: its first pass was still at about 3,000 overlaps | | | | |
| `g5r_100_fill` | G5R, 100 MHz, filler | 112,393 (96.0%) | −2.683 at 10 ns (79 MHz; see below) | −2.683 / −2.642 | **+0.474** | **+1.509 / +0.371** | 4,707 (all in the cores) |
| `g6_125_fill` | **G6** (main 7c99e84 + core-2 764e3ad + soc-2 b46e893), 125 MHz, filler | 110,516 (94.4%) | **−1.646 (104 MHz)** | −1.646 / −1.640 | −1.062 | **+0.245** / −0.658 | 11,644 |
| `g5r_125` | G5R, 125 MHz, no filler | 105,863 (90.4%) | **−2.198 (98 MHz)** | −2.198 / −2.191 | −0.666 | +0.223 / −1.609 | 12,534 |
| `g5r_125_fill` | G5R, 125 MHz, filler | 112,572 (96.1%) | **−2.607 (94 MHz)** | −2.607 / −2.535 | −1.320 | −0.342 / −0.848 | 16,650 |

The first filler attempt, with 25 LUTRAM blocks per core, came to 8.3K LUTs. v1 was then about 117K after `opt_design`, and placement failed on CLB packing: 10,040 CLBs needed, 9,929 free (`results/g5_100_fill_nram25/`).

**The worst paths** (G5R, 125 MHz):
- **Cores:** the LSU's DTLB → M2 forwarding family (`m2_fdat_q`, `m2_fcov_q`, `rp_ra_q`): 24–29 levels, 60–70% of the delay in wire, about 10.2–10.6 ns long.
- **Uncore:** the L2 bank: hit → victim-tag table (no filler), and directory RAM onward (filler), 13–14 levels.
- **Uncore → core:** the ACLINT's timer into rename's free list or a CSR enable, 15–18 levels, all inside the core.
- **Core → uncore:** fetch's line register into the crossbar's initiator counter, 11–12 levels.
- **PS:** passes both ways (+1.0 to +5.0 ns).
- **Failing endpoints:** almost all in the cores. With the filler, core 0 has 8,543, core 1 7,136 and the uncore 971.

**G6** is the day's last tree: fn10 plus A10b, A4 and two wire fixes from the FPU track's query of `g5r_125_fill`, and the SoC track's write-enable fix to the L2 data array.
- Its 20 worst paths are all in the LSU, within 0.06 ns of each other.
  - **Depth-dominated:** DTLB → M2 forwarding (`m2_foh_q`, `m2_fcov_q`): 28 levels in core 0, 24 in core 1, 59–60% wire.
  - **Wire-dominated:** M2's address (a replicated register) → the LQ's store-tag enable (`lq_st_q`), and DTLB → the replay registers (`rp_ra_q`, `rp_v_q`): 19–20 levels, 68–71% wire.
- Every crossbar path passes, as does the PS.

**At a 100 MHz constraint the placer under-works the cores.** `g5r_100_fill`'s pre-route estimate was +0.614 ns, so the placer saw no failing paths. The cores' LSU paths then routed with 8.5–8.7 ns of wire, against 6.4–7.3 ns at 125 MHz.
- So the 125 MHz runs measure each tree's speed: a design routed at 125 MHz with a 9.65 ns worst path (G6) also meets 10 ns.
- The 100 MHz figures to read are the uncore's and the interfaces': they pass (+0.37 to +1.51 ns).

**Findings:**
- **With today's RTL (G6) the chip reaches about 104 MHz with hart 1's area at 94% fill.** Its routed design meets 100 MHz with 0.35 ns to spare. 125 MHz needs 1.65 ns more on the cores' LSU paths and 1.06 ns on the uncore's L2 bank (S2 → MSHR state, 14 levels).
- **On G5R's tree the chip reaches about 98 MHz, and about 94 MHz with hart 1's area at 96% fill.** The cores are the limit.
  - 100 MHz needs about 0.2 ns more on the cores without hart 1 and 0.6 ns with it. 125 MHz needs about 2.2–2.6 ns.
  - The uncore needs 0.7–1.3 ns for 125 MHz. The interfaces are within 0.85 ns, and the PS passes.
- **fn8–fn10 and the trace switch took the chip from 82 to 98 MHz** (G5 → G5R, no filler): the cores' worst went from 12.1 to 10.2 ns.
- **Hart 1's area costs about 0.4 ns on G5R** (−2.198 → −2.607 ns, the same flow). On G5's tree at 98.4% fill it cost 3.4 ns, but that run needed free placement and spread logic to route, so its figure mixes fill with the flow.
- **The fill limit is about 97–98% for this design.**
  - At 100.6% after synthesis (G5 with the filler), the pblock flow does not route. Free placement with `AltSpreadLogic_high` does, in 2 h 19 of routing.
  - At 99.45% after synthesis (G5R with the filler: 96.1% placed), the pblock flow routes in 1 h 16.
  - The first filler, at about 117K after optimisation, did not pack.

### 8.7 G7: the full chip at 115 MHz on the fixed rename, with fn11 and an LSU placement (2026-10-17)

**Correction (2026-10-17, §8.8):** two placements of one netlist (G8) differ by 1.5 ns of WNS, by 15 times in TNS and by 6 times in failing endpoints. So the single-run differences below are within placement noise: fn11's halving of the failing endpoints, its 0.2 ns of WNS, and the LSU pblocks' 0.85 ns loss. The LSU pblocks still show no gain, and by LUT cells they were as full as G4-FP (b)'s, which did not route, so they stay dropped.

**Question (the coordinator, DR-148):** v1's target is 115 MHz. On a correctly synthesized rename (§8.6's caveat), how fast is the full chip, and what do the core track's fn11 timing work and an LSU-beside-D$ placement each buy?

**Method:** G6's flow (§8.6), with the clock at 115 MHz and one synthesis per tree.
- **Clock:** with `clk_host` at 100 MHz, `tg_clkgen` cannot make 115 MHz from a VCO at a multiple of 100 MHz. The snapshots build it as 1600 / 13.875 = **115.315 MHz** ([`g7_clkgen_patch.py`](../../fpga/spikes/scripts/g7_clkgen_patch.py)), so the target period is 8.672 ns. Measurement only.
- **The rest as G6:** hart 1's filler (47 LUT tiles and 20 LUTRAM blocks per core), the performance build (`TG_COMMIT_TRACE=0`), the default profile.
- **One synthesis per tree,** checked by [`synth_check.tcl`](../../fpga/spikes/tcl/synth_check.tcl) (no implicit or undriven net in either). Placement and routing start from its checkpoint, so the two fn11 runs share one netlist.
- **Trees:**
  - **G7m:** main 82463e2, with the rename fix (24ada50) and the core track's forward-reference fixes (d73a15d); no fn11.
  - **G7r:** the core track's fn11 MR head 2ea6a8d (main 0c95492 merged). Against 82463e2 its RTL adds fn11 (+474/−147, mostly the D$: `tg_dcache`, `tg_lsu`, `tg_core`, `tg_core_pkg`) and one declaration-order change in `tg_fpu_div`.
- **Floorplans:** G4-FP (a)'s L2 and crossbar pblocks. The LSU variant adds each core's LSU beside its D$ block RAMs and the crossbar ([`fp/g7_lsu.tcl`](../../fpga/spikes/tcl/fp/g7_lsu.tcl)).
- The first G7 pair (2da5b0f and 6605657, both with the rename bug) gave no result: the host crash of 10-16 20:17 lost the plain run while it was routing, and the bug stopped the retry.

| Run | Tree, floorplan | Placed LUTs | WNS ns at 8.672 (clock reached) | TNS ns | Failing endpoints (core 0 / core 1 / uncore) |
|---|---|---|---|---|---|
| `g7m_115_fill` | G7m, L2 + crossbar | 110,504 (94.4%) | **−0.622 (107.6 MHz)** | −428 | 2,296 (1,502 / 788 / 6) |
| `g7r_115_fill` | G7r (+ fn11), L2 + crossbar | 110,565 (94.4%) | **−0.817 (105.4 MHz)** | −262 | 1,175 (776 / 300 / 99) |
| `g7r_115_fill_lsu` | G7r, + the LSU pblocks | 110,418 (94.3%) | **−1.671 (96.7 MHz)** | −1,355 | 3,506 (1,476 / 1,627 / 403) |

| Run | Core 0 | Core 1 | Uncore | Core → uncore | Uncore → core |
|---|---|---|---|---|---|
| `g7m_115_fill` | −0.622 (17 levels, 66% wire) | −0.613 (14, 74%) | −0.314 (14, 75%) | +0.930 | +0.714 |
| `g7r_115_fill` | −0.817 (13, 80%) | −0.701 (17, 73%) | −0.684 (13, 79%) | −0.485 | −0.692 |
| `g7r_115_fill_lsu` | −1.671 (19, 73%) | −1.448 (22, 68%) | −0.887 (14, 73%) | −0.254 | +0.345 |

The PS paths pass by 5.5–6.2 ns and the filler's by 4.1–4.4 ns in all three. Placement took 17–19 minutes and routing 77 minutes (G7m), 2 h (G7r) and 2 h 25 (LSU).

**What fails:**
- **G7m:** the 20 worst paths are within 0.03 ns of each other, across both cores:
  - the D$ access-state register → the data RAMs' byte write enables;
  - DTLB → M2 forwarding (`m2_fcov_q`, `m2_foh_q`);
  - the LQ head → the reservation hold and the CSR's trap updates;
  - the SQ head → the store-data RAM;
  - CSR privilege → the ROB field table's write enables;
  - PMP → issue wakeup.
- **G7r:** the 20 worst are all in core 0's LSU, −0.72 to −0.82 ns:
  - the D$ state register → the data RAMs' byte write enables (13 levels, 80% wire);
  - DTLB → the replay address (`rp_ra_q`);
  - the split-access register (`g_split.sn_v_q`) → the ROB field table's write enables;
  - M2's address → the LQ's store-tag enables (`lq_st_q`);
  - `lose_line_q` → a data RAM's address.
- G6's families (§8.6) are still there, joined by the D$ write enables. The worst paths are wire-dominated: 66–80% of their delay is routing, at 13–17 levels.

**Findings:**
- **On the fixed rename the full chip reaches about 105–108 MHz at 94% fill; 115 MHz needs another 0.6–0.8 ns.**
  - G7m's 9.29 ns worst path is 0.35 ns shorter than G6's 9.65 ns at the same fill, but both the tree and the target (8.672 against 8 ns) differ.
- **The rename fix costs 54 LUTs per core.**
  - Rename (`u_rn`) is 3,031 / 3,027 LUTs against G6's bugged 2,977 / 2,972, with the same flip-flops and LUTRAM. Chip LUTs after synthesis moved by under 200.
  - No rename path is among the worst. The closest is ACLINT → core 1's free-list RAM write address (+0.714 ns in G7m).
- **fn11 halves the failing endpoints and cuts the TNS by 39%; its WNS change is within the noise.**
  - Failing endpoints 2,296 → 1,175 (in the cores 2,290 → 1,076), TNS −428 → −262 ns.
  - The worst path moved 0.2 ns the wrong way. But the uncore, the same RTL in both trees, moved 0.37 ns (−0.314 → −0.684), so a single run's WNS moves by up to about 0.4 ns with placement alone.
  - The core ↔ uncore paths moved 1.4 ns each way. fn11 changes the D$ at one of their ends, so that move is not noise alone.
  - fn11 adds 186 LUTs and 482 flip-flops after synthesis.
- **The LSU pblocks lose 0.85 ns** (−0.817 → −1.671 ns, three times the failing endpoints).
  - Their worst paths stay inside core 0's LSU at 19–22 levels: DTLB → LQ state and M2 forwarding, the split-access register → the ROB's write enables, DTLB → the PTW.
  - The pblocks hold about 11.5K LUTs per core in 17,888 LUT sites: about 65% by physical LUTs, as sized. That is 85% by LUT cells (a dual-output LUT counts twice), close to G4-FP (b)'s 88–90% by the same count, which did not route.
  - Placing the LSU beside its D$ is not worth a floorplan.
- **For 115 MHz, the core-side families to fix are:**
  - the D$ write-enable cone;
  - DTLB → replay, M2 forwarding and LQ enables;
  - the ROB field table's write enables from the LSU and the CSR.

  The L2 bank's internal paths need about 0.3–0.7 ns.

Results: `fpga/spikes/results/g7m_synth/`, `g7m_115_fill/`, `g7r_synth/`, `g7r_115_fill/` and `g7r_115_fill_lsu/`. Their `SNAPSHOT_SOURCE.txt` files name the trees. The routed checkpoints are in the build tree (`fp/<run>_routed.dcp`), and the post-synthesis ones are kept for more placements.

### 8.8 G8: main at 115 MHz in two placements, and how noisy one placement is (2026-10-17)

**Question (the coordinator, DR-148):** what do the FPU track's G8 fixes, and the SoC track's MR1 to MR3, buy on top of fn11, judged against placement noise with two placements of one synthesis? The 115 MHz series ends here (DR-152 sets the target at 100 MHz).

**Method:** G7's flow at 115.315 MHz, on main 5172c6a.
- **Tree:** fn11 plus the FPU track's G8 fixes in fetch, decode and the LSU, and the SoC track's MR1 (DR-151's memory map), MR2 and MR3.
  - MR2 and MR3's debug words, host DMA and virtio window are built only when switched on, and default to off. The block design's new HPM1 port is tied off.
  - QUEUE_DECODE is off by default.
  - Per unit, the logic is within 45 LUTs of G7r's. The synthesis check finds no implicit or undriven nets, and no forward references at all.
- **Two placements:** Vivado's placer has no seed, and `-place_directive Explore` gave a placement identical to Default's (every report line equal).
  - So the second sample placed and routed the same checkpoint with 0.05 ns of setup uncertainty on the core clock, taken back before the reports ([`seed_unc.tcl`](../../fpga/spikes/tcl/seed_unc.tcl), with `g4_fit.tcl -pre_report`).

| Run | WNS ns at 8.672 (clock reached) | TNS ns | Failing endpoints (core 0 / core 1 / uncore) | Routing |
|---|---|---|---|---|
| `g8_115_fill` (Default; Explore identical) | −2.012 (93.6 MHz) | −1,399 | 2,948 (989 / 1,877 / 82) | 3 h 09 |
| `g8_115_fill_unc` (the same netlist, seeded) | **−0.483 (109.2 MHz)** | −94 | 464 (86 / 337 / 41) | 2 h 20 |

- **The bad sample:** core 1's LSU holds 1,632 failing endpoints. Its paths are DTLB → the replay address (24 levels), the LQ head → the LQ's store-tag enables (13 levels, 8.6 ns of wire) and DTLB → M2 forwarding, with 7.2–8.6 ns of wire against 6–7 ns in G7.
- **The good sample:**
  - core 0's DTLB → the replay address: −0.414 ns (20 levels, 67% wire);
  - core 1's PTW → the ROB field table's write enables: −0.483 (17 levels, 75%);
  - the L2's MSHR state → `m_vtag`: −0.429 (12 levels, 81%);
  - the core ↔ uncore paths pass by 0.9–1.1 ns, the PS paths by 4.9 ns or more.

**Findings:**
- **One placement of this design is noisy by more than 1.5 ns.**
  - With only 0.05 ns of placement-time uncertainty changed, the same netlist moved from −2.012 to −0.483 ns of WNS, from −1,399 to −94 ns of TNS, and from 2,948 to 464 failing endpoints.
  - Single runs at 94% fill therefore rank trees only by differences well above 1 ns. That corrects §8.7.
- **G8 is not measurably different from G7.** Its two samples are the best (−0.483) and the worst (−2.012) of all the 115 MHz runs.
- **At 100 MHz, the samples would land on both sides of closure:** about +0.85 ns for the good one and about −0.68 ns for the bad one (DR-152). The headroom runs measure 100 MHz directly (§8.9).
- **QUEUE_DECODE's paths fail at 115 MHz and pass at 100 MHz.**
  - The path runs from the instruction queue's head (`u_fetch/u_cmp/head_q`) through decode to rename's uop register (`u_rn/rn_uop_q`): 16–19 levels, 65–69% wire.
  - Failing at 115 MHz: G7m 276 endpoints at −0.44 ns, G7r 130 at −0.53, G8's bad sample 89 at −0.65.
  - With 1.33 ns more at 10 ns they pass by about 0.7 ns, so under DR-152 the switch can stay off.
  - The other failing fetch paths are fetch's own pipeline, not the queue: I$ stage 2 → stage 3, and the next-PC loop.
- **Other families in G8's bad sample:**
  - a cross-core path, core 0's fetch refill line → core 1's LSU state enable (13 levels, −0.934), through the crossbar's arbitration;
  - the ROB head → rename's free-list count (−0.608);
  - core 1's LSU → the FPU's P4 (58 endpoints, −0.865).
- **The G3 false-path cut was empty.** `g3_false_paths.tcl`, applied in every G-run since G3, cut the LSU's `r_data_q` → the ROB's `exr_*`.
  - In today's cores no `exr_*` register is reachable from `r_data_q` (all_fanout), and the second cut matches no cell ([`q_cut_paths.tcl`](../../fpga/spikes/tcl/query/q_cut_paths.tcl)). So no G-run hid a path.
  - The 100 MHz runs drop the cut.
- **Counting failing endpoints by unit** ([`q_fail_units.tcl`](../../fpga/spikes/tcl/query/q_fail_units.tcl), about 3 minutes per checkpoint) finds families that a run's 20 worst paths miss: in G7r the 20 worst were all core 0's LSU, while fetch → rename failed at 130 endpoints.

Results: `fpga/spikes/results/g8_synth/`, `g8_115_fill/`, `g8_115_fill_unc/`, and `g8_115_fill_explore/` (its summary only: its reports equal `g8_115_fill`'s).

### 8.9 Area headroom at 100 MHz: how much more logic the chip takes (2026-10-17)

**Question (the coordinator, DR-152, DR-153):** M6 needs room on a device that is 94% full with two cores and hart 1's area. With today's main at 100 MHz, how much more logic can the chip take and still close?

**Method:**
- **Tree:** main 4bb4426 (the RTL of G8's 5172c6a) at 100 MHz, which the board's `tg_clkgen` makes directly. The performance build, the L2 and crossbar pblocks, and no G3 cut.
- **Extra logic:** hart 1's filler, grown per core from 47 tiles (hart 1's area, 3.7K LUTs a core) to 69, 91 and 114 tiles. That is +2K, +4K and +6K LUTs on the chip: a tile is about 45 LUTs and 39 flip-flops, and the 20 LUTRAM blocks stay.
- **One synthesis per point** (checked by `synth_check.tcl`) **and one placement from it.**
- **Over-constraint:** at a 100 MHz constraint the placer under-works the cores (§8.6). So placement and routing see 1.0 ns of setup uncertainty on the core clock, taken back before the reports ([`over_unc.tcl`](../../fpga/spikes/tcl/over_unc.tcl)): they aim at 9 ns and report at 10. The board build now does the same (the coordinator, DR-154).

| Point | Filler per core | Placed LUTs (fill) | WNS ns at 10 ns | Failing endpoints | Worst families (levels, wire share) | Routing |
|---|---|---|---|---|---|---|
| `h100_0` | 47 tiles (hart 1's area) | 110,414 (94.3%) | **+1.065** | 0 | The instruction queue's head → rename's uop (18, 66%). The privilege register → the ROB field table's write enables (18, 75%). | 1 h 21 |
| `h100_2` | 69 (+2K) | 112,201 (95.8%) | **+0.590** | 0 | D$ state → the data RAMs' write enables (14, 76%). DTLB → M2 forwarding (18, 75%) and → the replay address (23, 64%). M2's address → the LQ's store-tag enables (18, 73%). | 2 h 12 |
| `h100_4` | 91 (+4K) | 113,712 (97.1%) | **−0.636** | 28 (core 0 1, core 1 27) | The LSU's split access → the ROB field table's write enables (17, 74%). DTLB → the PTW (21, 72%). | 1 h 40 |
| `h100_6` | 114 (+6K) | 119,572 after synthesis (102.1%) | — | — | Stopped in its first routing pass before a WSL compaction. Not rerun, since +4K already misses (DR-155). | — |

**Findings:**
- **100 MHz closes at +2K LUTs (95.8% placed) and misses at +4K (97.1%).**
  - Interpolated, the boundary is about +3K: about 96.4%, or 112.9K LUTs placed.
  - With one placement per point and about ±0.75 ns of placement noise (§8.8), that boundary is good to about ±1K.
- **M6's budget: about 2K LUTs on the chip** (about 1K per core) above today's main with hart 1's area, for one placement to close at 100 MHz. Up to about 3K closes on average, but not reliably.
- **The budget is optimistic.** The filler is self-contained (an LFSR feeds it, and it connects to nothing). It adds area and congestion, but none of the wiring that real logic adds between units.
- **The slack falls about 0.3 ns per 1K LUTs up to 96%, and roughly 0.8 ns per 1K beyond.** One placement per point makes the slopes rough.
- **What fails first are the families seen at 115 MHz:** the ROB field table's write enables (from the LSU, the CSR and the privilege register), the DTLB's paths, and the D$ write enables. They are wire-dominated (64–76%) at 14–23 levels, so added logic costs these paths their wire first.
- Routing stays under 2.5 hours up to 97%. The +6K point's synthesis reached 102.1% of the device's LUTs and still placed.

Results: `fpga/spikes/results/h100_0/`, `h100_2/`, `h100_4/` (and their `_synth` runs), and `h100_6/stopped.txt` with its synthesis.

### 8.10 M6 guardrails at 100 MHz: the RAS, and the RAS with TAGE and F2 (2026-10-18)

**Question (the coordinator, DR-162):** the user chose to build M6's first set and accept a few MHz below 100 for now. TAGE measured at twice its estimate, so what do the real features do to the clock, against §8.9's filler estimate? These two numbers decide TAGE's size and the clock.

**Method:** §8.9's flow: 100 MHz, hart 1's filler (47 tiles a core), the 1.0 ns over-constraint taken back before the reports, and one synthesis and one placement per tree.
- **Trees** (the core track's):
  - (i) `claude/track-core-adb715-ras` at 58674a7: main c841a27 plus the RAS and fn12's two fixes.
  - (ii) `claude/track-core-adb715-m6b` at c149fce: (i) plus TAGE (two tagged tables, with its training-queue and history-rebuild area offsets) and F2 (returns and straddlers predicted at F2).
- Both have the four L1D misses and speculative wakeup on. They are the defaults, and the runs also pass them.
- Both pass the synthesis check (no implicit or undriven nets, no forward references).

| Run | LUTs after synthesis | Placed LUTs (fill) | WNS ns at 10 ns (clock reached) | TNS ns | Failing endpoints (core 0 / core 1 / uncore) |
|---|---|---|---|---|---|
| `h100_m6r` (i) | 117,402 | 113,302 (96.7%) | **−0.542 (94.9 MHz)** | −133 | 726 (289 / 437 / 0) |
| `h100_m6t` (ii) | 119,887 | 115,185 (98.3%) | **−5.079 (66.3 MHz)** | −5,519 | 3,521 (1,150 / 2,323 / 48) |

**What fails:**
- **(i):** all 20 worst paths start at the instruction queue's head (`u_fetch/u_cmp/head_q`), at 26–30 levels and 55–60% wire. They end in:
  - the RAS's speculative state (`g_ras.u_ras/s_cnt_q`, `sv_q` and its LUTRAM stack), −0.54 ns;
  - the queue's own head and occupancy loop.

  Without TAGE the RAS moves at decode (`RAS_DEC`), inside the queue's take path. These paths are mostly logic depth.
- **(ii):** all 20 worst paths are one family: the I$ stage 2 (`f2_pa_q`, `f2_tag_q`) → TAGE's global history register (`u_fetch/g_tage.gh_q`).
  - 40–44 levels, with 5.8 ns of logic and 9.1–9.3 ns of wire: a 15 ns data path in one cycle.
  - Its next worst, a reset replica in the host bridge → core 1's fetch PC enable, is 10.4 ns of wire at 98% fill (−1.32 ns).

**Findings:**
- **(i) misses by 0.54 ns (94.9 MHz at 96.7% fill), about what §8.9's filler curve predicts at that fill:** −0.3 ns, ±0.75 for one placement.
  - (i) is about 2.7K LUTs over §8.9's baseline. That counts main's four misses, speculative wakeup and fn12 as well as the RAS.
  - The RAS's family (the queue head → decode → its speculative update) is the worst, but the fill alone would leave the chip about 0.3 ns short.
- **TAGE with F2 makes the chip miss by 5.1 ns.** The cause is one structural path, not TAGE's size or the fill.
  - The F2 decision updates the global history in the same cycle as the I$ hit it depends on. That path needs a pipeline cut, which no placement can find.
  - At (ii)'s 98.3%, §8.9's slope (about 0.8 ns per 1K LUTs above 96%) predicts about −1.8 ns, about 85 MHz, once that path is cut. One placement makes this ±0.75 ns.
- **Against the filler estimate:** (i) follows the filler curve within noise. (ii) costs far more than its area, through one new structural path in fetch, where §8.9's filler has neither depth nor wiring.

**By register family** ([`q_fail_families.tcl`](../../fpga/spikes/tcl/query/q_fail_families.tcl): every failing endpoint grouped by its register or RAM, then again with cones taken out of timing):
- **(i):** 726 endpoints in 33 families. The queue head's take cone holds the worst of them, at 25–30 levels:
  - its own loop (`head_q`, `occ_q`, −0.54);
  - the RAS's speculative state (`s_cnt_q`, `sv_q`, `s_tos_q` and its LUTRAM stack: 463 endpoints, −0.54 to −0.21);
  - decode's redirect registers (`u_de/dred_pc`, 110 endpoints, −0.31).
- **(i) without any path inside the front end:** 153 endpoints remain, and the worst is the LSU's DTLB → replay address (−0.335, 23 levels). Then come the queue head into decode (−0.31), the store queue and the L1D's MSHR registers (−0.21 to −0.003), and rename's free-list counts from the CSR's privilege (−0.08).
- **(ii):** 3,521 endpoints in 207 families. The F2 stage's cone holds the worst 50 or so, at 26–44 levels:
  - TAGE's `gh_q`, its folded histories (`u_fgh`) and the RAS's speculative state, −5.08 to −2.1;
  - F3's registers (`f3_meta_q`, `f3_start_q`, `f3_carry_q`) and the predecode results (`krt_q`, `kimm_q`, `kr_q`, `ka_q`, `k_ovr_q` ...).

  The cone has three sources: F2's registers (`f2_pa_q`, `f2_tag_q`), the I$ data RAMs, and TAGE's table RAMs (`g_tage.u_tage/g_tab[]`, read in F1). With the first two cut, TAGE's tables still give −3.69 ns at 35 levels.
- **(ii) without any path inside the front end** (fetch, TAGE and the RAS, their RAMs included): 2,366 endpoints remain, the worst at −1.63 ns, all 69–82% wire at 11–21 levels:
  - core 1's issue-queue guard (`u_is/.../g_guard.dep_q`) → decode's redirect registers (`dred_rop`, `dred_rlink`, `dred_ftq`, `dred_slot`), −1.63;
  - the queue head → rename's uop register (`rn_uop_q.pred_npc`, 181 endpoints, −1.61) and → decode's `dred_pc` (−1.60);
  - the D$ write enables, −1.55;
  - the host bridge's core reset → core 1's fetch PC enable, −1.32;
  - the LSU's split access → the ROB, −1.25.

  That is about what §8.9's slope predicts at 98.3% fill (−1.8 ns).
- **Outside the front end, (ii) fails where (i) does not:** core 1's issue-queue guard → decode and rename; the D$ write enables at −1.5 (−0.07 in (i)); the LSU's split access → the ROB; and the L2's directory paths (48 endpoints, −0.60, none in (i)).
  - All of them are wire-dominated (75–82%): placement fallout of a fuller chip with a front end grown by about 2.5K LUTs a core, not new logic.
- **The core-reset replica is placement fallout.**
  - In (ii) its ten worst endpoints are in core 1's fetch, at −0.84 to −1.32 ns, with 2–4 levels and 10.0–10.5 ns of wire.
  - In (i) the same replica's worst endpoints pass by 1.7 ns with 7.5–7.7 ns of wire.
  - A local reset register in each core would take it off the table if it stays.

Results: `fpga/spikes/results/h100_m6r/`, `h100_m6t/` and their `_synth` runs; `h100_m6t/fail_families_m6r_m6t.txt` holds the family query for both.

### 8.11 F2 restructured: M6's set with TAGE no longer fits (2026-10-18)

**Question (the coordinator):** the FPU track's F2 prototype (`claude/track-fpu-395911-f2cut` at 1e4a503) is tree (ii) of §8.10 with F2 restructured. Out of context its whole core closes 100 MHz by 0.9–1.2 ns, with no front-end path among the worst, and it costs about 131 LUTs a core after optimisation. What does the full chip reach, and how much of the remaining gap is fill?

**Method:** §8.10's flow: 100 MHz, hart 1's filler (47 tiles a core), the 1.0 ns over-constraint, the four misses and speculative wakeup. The synthesis check is clean (no implicit or undriven nets, no forward references).

**Result: it does not place.**
- After synthesis it has 120,787 LUTs (103.1% of the device) and 63,657 flip-flops: 900 LUTs more than tree (ii) (119,887), which placed at 115,185 (98.3%).
- Placement fails on CLB packing (Place 30-487): the unplaced instances need 10,268 CLBs, and 10,195 are available, 73 short (0.7%). So there is no timing.

**Findings:**
- **M6's set with the two-table TAGE, the restructured F2 and hart 1's area does not fit the XCK26** in this flow: it needs about 0.7% more of the packable CLBs than there are.
- **So TAGE's size is now an area decision first.**
  - At least about 600 LUTs (73 CLBs at 8 LUTs each), and likely more at real packing density, must come out before this set can be placed.
  - Candidates are TAGE's second table, or part of hart 1's area: its filler stands for 3.7K LUTs a core.
- **Ways to get a timing number for this tree:**
  - the same checkpoint placed without the L2 and crossbar pblocks, which gives the packer more freedom but costs the L2's split-bank paths (§8.4);
  - or a filler about 7 tiles a core smaller (hart 1's area cut by about 10%), which needs a new synthesis.

Results: `fpga/spikes/results/h100_m6f/` (`place_failed.txt`, `util_synth.rpt`) and `h100_m6f_synth/`.

### 8.12 The M6 set fits at 100 MHz: F2 restructured, and opt_design's ExploreArea (2026-10-18)

**Question (the coordinator, DR-166):** §8.11's checkpoint placed once with `opt_design -directive ExploreArea`, which the FPU track measured at 1,275 fewer LUTs after optimisation with no RTL change (area_recovery §7.8). Does M6's set with the restructured F2 place, what does it reach, and does ExploreArea lengthen anything?

**Method:** §8.11's synthesis checkpoint (1e4a503), placed and routed with §8.10's flow and `g4_fit.tcl -opt_directive ExploreArea`. Then the family query at a 1 ns threshold on this run and on `h100_m6t`.

| | `h100_m6t` (tree (ii), the default optimisation) | `h100_m6fa` (F2 restructured, ExploreArea) |
|---|---|---|
| LUTs after optimisation | — | 116,511 (the default: 117,786) |
| Placed LUTs (fill) | 115,185 (98.3%) | 113,673 (97.1%) |
| WNS ns at 10 ns | −5.079 | **+0.725** |
| TNS ns | −5,519 | 0 |
| Endpoints below 0 / 0.3 / 0.5 / 1.0 ns | 3,521 / 4,889 / 6,054 / 10,662 | **0 / 0 / 0 / 174** |
| Levels of the worst 2,000 paths | up to 44 (about 1,050 at 34 or more) | 9–23, mostly 15–21 |
| Routing | 1 h 07 | 51 min |

**The worst paths in `h100_m6fa`:**
- **F2's cone**, now 19–21 levels: core 0's I$ data RAM → predecode's `krt_q`, +0.725 ns (21 levels, 55% wire), and `f3_meta_q`, `kimm_q`, the RAS's `p_push_q` and TAGE's history up to +1.0.
- **The LSU**, +0.78 to +0.99 (13–23 levels, 63–80% wire): `lose_line_q`, `sq_av_q`, `m2_dword_q`, `lq_st_q` (from the PMP), `rp_ra_q` (23 levels), `m2_foh_q` and the PTW.
- **Rename's uop register from the queue head**, +0.91 to +0.99 (17–20 levels). Decode's `dred_ftq`, +0.89. The ROB's `sp_v_q`, +0.88.
- **The uncore**, +1.154 (the L2's command pointer → its directory RAM). Core ↔ uncore passes by 1.5–1.9, the PS by 6.6, the filler by 4.6.

**Placed LUTs per core**, `h100_m6t` → `h100_m6fa` (the F2 change and ExploreArea together):
- **Smaller:** fetch 6,049 → 5,900 (−150), the LSU 12,317 → 12,149 (−170 and −210), the issue queue 5,103 → 4,772 (−330), execute 6,881 → 6,846 (−35).
- **Larger:** the RAS 255 → 287 (+32), the ROB 2,573 → 2,637 (+70), decode 2,000 → 2,026 (+26).
- **Within 25:** rename and the CSR.
- **Totals:** the uncore 15,851 → 15,770 (−81); the SoC 107,644 → 106,132 (−1,512).

**Findings:**
- **M6's set with the restructured F2 and hart 1's area fits, and meets 100 MHz with 0.73 ns to spare at 97.1% placed.** That is one placement, ±0.75 ns of noise (§8.8). No endpoint is within 0.5 ns.
- **ExploreArea made the room:** 1,275 fewer LUTs after optimisation, and 1,512 fewer placed than tree (ii) with the F2 change counted in. Without it the same checkpoint did not pack (§8.11).
- **ExploreArea did not lengthen paths systematically.**
  - Of 20 families outside the front end, 8 lost one or two levels, 5 stayed the same and 7 gained one to three.
  - The gains of two and three are paths from the queue head into decode and rename, which the F2 change touches too.
  - The worst 2,000 paths reach 23 levels at most.
- **F2's cone now leads at +0.73, with the LSU at +0.78.** The margin is spread across the core again, as before M6's features.

Results: `fpga/spikes/results/h100_m6fa/`, and `near_families_m6fa_m6t.txt` (the 1 ns family query of both runs).

### 8.13 The merged M6 meets 100 MHz with hart 1's area; the first full chip on w-x299 (2026-10-19)

**Question (the coordinator):** main 31e65c6 holds what `h100_m6fa` did not: TAGE's tables at 2K entries (DR-170), DR-169's rename levers and core-2's M6 merge. Does it still meet 100 MHz with hart 1's area under §8.12's flow? And how does the first full chip on the new build host, w-x299 (an i9-10980XE, 18 cores and 36 threads), compare in run time with the 5950X?

**Method:** §8.12's flow on main 31e65c6.
- Synthesis with hart 1's filler at 47 tiles, the four-miss L1D and speculative wakeup (both now main's defaults).
- Placement and routing from its checkpoint with `opt_design -directive ExploreArea`, and 1.0 ns of setup uncertainty on the core clock that is taken back before the reports. One placement.
- Then the family query at a 1 ns threshold.

Vivado keeps its caps of 8 threads for implementation and 2 for synthesis (`g4_fit.tcl`), as on the 5950X.

| | `h100_m6fa` (5950X; the F2 prototype, 1e4a503) | `h100_m6m` (w-x299; main 31e65c6) |
|---|---|---|
| LUTs after synthesis | 120,787 | 121,004 |
| LUTs after optimisation | 116,511 | 116,653 |
| Placed LUTs (fill) | 113,673 (97.1%) | 113,721 (97.1%) |
| Block-RAM tiles | 121 | 125 (TAGE's tables) |
| WNS ns at 10 ns | +0.725 | **+0.348** (WHS +0.011) |
| Endpoints below 0 / 0.3 / 0.5 / 1.0 ns | 0 / 0 / 0 / 174 | **0 / 0 / 82 / 1,239** |
| Levels of the worst 2,000 paths | 9–23 | 6–26, mostly 11–20 |

**The worst families in `h100_m6m`:**
- **TAGE's table RAM → F3 (core 0)**, new: at 2K entries the tables are block RAMs.
  - F3's predicted target (`f3_meta_q`) at +0.348 ns and predecode's `krt_q` at +0.353 (17 levels, 66% wire).
  - The RAS's `p_push_q`, TAGE's `gp_n_q` and its history RAM, +0.38 to +0.47.
  - Core 1's worst front-end paths start at the I$ data RAM, as in `h100_m6fa`: `f3_meta_q` +0.373, `krt_q` +0.404 (20 levels).
- **The LSU, tied with it:**
  - The DTLB → M2's `m2_dword_q`, +0.352 (14 levels, 76% wire).
  - The store queue's AMO and privilege registers → `sq_av_q`, `sq_exc_q` and `s2_v_q`, +0.359 to +0.414 (13–15 levels, 77–80% wire).
  - The PMP → `lq_st_q` +0.389 (17 levels); the L1D's data RAM from the AMO state +0.422.
  - `rp_ra_q` from the DTLB, +0.443 at 26 levels (23 in `h100_m6fa`).
- **Fetch's `fpc_q` loop** (core 1), +0.386 (17 levels, 76% wire).
- **Rename's uop register from the queue head**, +0.47 to +0.60 (17–20 levels). Decode's `dred_*` from the issue queue, +0.70 to +0.86 (19–20 levels).
- **The uncore:** the L2 bank's `m_grant_t`, `ms` and `d_credit_q`, +0.49 to +0.55 (12–14 levels, 75–80% wire). Its worst in `h100_m6fa` was +1.154.
- Without any path inside the front end, 967 endpoints remain below 1 ns, led by the LSU at +0.352.

**Run time:**

| Stage | `h100_m6fa`, 5950X | `h100_m6m`, w-x299 | Ratio |
|---|---|---|---|
| Synthesis job | 21.0 min (a quiet host; 28.4 for `h100_m6r`, loaded) | 27.0 min | 0.95–1.3× |
| Optimisation and placement | 11.4 min | 17.7 min | 1.55× |
| Routing | 50.9 min | 150.3 min | 2.95× |
| The placement and routing job | 64.8 min | 172.4 min | 2.66× |

- **Threads:** the router kept 2.5 of its 8 threads busy on average (22,220 CPU-seconds in 9,020 s); placement 2.4 and optimisation 2.6 (`times.txt`).
- **Load:** w-x299 was busy. The 1-minute load averaged 26.3 of 36 threads on 18 cores, with 3.1 Vivado jobs at once on average and 5 at most (`logs/h100_m6m.load`). The 5950X's load during `h100_m6fa` was not recorded.
- **The CPU** ran at about 4.2 GHz under load. Its package was at 95 °C at a load of 16 (high mark 100 °C), and it had throttled in 16,827 short bursts, 67 s in all, in the 5 h since boot.
- **Memory peaks:** synthesis 15.2 GB (18 declared); placement and routing 8.4 GB (10 declared). ExploreArea's placement and routing needs more than the default's 5.2–5.3 GB (`h100_m6fa`: 7.8).

**Findings:**
- **The merged M6 meets 100 MHz with hart 1's area, with 0.35 ns to spare at 97.1% placed.** That is one placement, ±0.75 ns of noise (§8.8). 82 endpoints are within 0.5 ns, against none in `h100_m6fa`.
- **The 2K TAGE tables moved the front end's worst path onto TAGE's block RAM**, at 17 levels. The LSU's DTLB → M2 path is tied with it, and the LSU's store-queue paths are 77–80% wire.
- **A full chip takes about 3.3 h on w-x299 under this load, against about 1.5 h on the 5950X.**
  - Placement is 1.55× slower, on nearly identical netlists (116,653 and 116,511 LUTs after optimisation).
  - Routing is 2.95× slower. Part of that is the design: with the over-constraint, its timing at the end of routing was −0.65 ns against `h100_m6fa`'s −0.28. Against the slowest 5950X route of M6's trees (`h100_m6r`, 70 min), it is 2.15×.
  - A job keeps only 2.4–2.6 threads busy, so per-thread speed and the host's load set a full chip's time, not the core count. The host's gain is in running more jobs at once: 8 slots and 50 GB, against 6 and 40.
- A controlled comparison of the hosts would rerun `h100_m6fa`'s tree on w-x299.

Results: `fpga/spikes/results/h100_m6m/` (with `times.txt`, Vivado's time and memory per command) and `h100_m6m_synth/`; `near_families_m6m.txt` (the 1 ns family query).

### 8.14 A double-pumped UltraRAM register file: tier A (2026-10-19)

**Question (the user, through the coordinator; measurement only):** can the integer register file move from LUTRAM into the idle UltraRAMs, clocked at 200 MHz so each URAM288 makes four accesses per core cycle?
- Today `tg_irf` is 3 banks of 64 × 64 bits, each with 1 write port and 7 read ports: 1,536 LUTRAM and a 448-LUT bank select per core. `h100_m6m` leaves 32 of the 64 UltraRAMs free.
- The two questions:
  1. Does double pumping work, functionally and in timing?
  2. Does a mid-cycle read close without a new pipeline stage?

**Where the register file sits.** In this core the bypass multiplexer is in EX, after the RF-stage registers (`ex_a_q`, `ex_b_q`).
- The RF stage puts only the 3:1 bank select after the read, plus one 4:1 select (`rbs`) on the LD and STA bases.
- Six read ports take their addresses from the issue → RF register.
- The seventh, the store-data port, takes its tag from the LSU within the cycle.

**Method:**
- **Design:** `tg_urf`, on the scratch branch `claude/spikes-2-uram-rf`. It has 3 banks, each of 3 `URAM288_BASE` copies that every write reaches, at 200 MHz from the board's MMCM: a third output, divide 6, phase-aligned with the core clock.
- **Retiming:** a read at the core edge takes the select's output straight into the UltraRAM's address register, replacing today's issue → RF register, so no stage is added.
- **Function:** `tb_urf`, 200K cycles against `tg_ram_lut` banks wired as `tg_irf`, with reads biased to collide with writes in the same cycle and the cycle before. It ran under Verilator, on a `URAM288_BASE` model written from UG573 and on the vendor's own model. This host's Vivado has no xsim libraries; the vendor model only loses its unconnected-pin defaults.
- **Timing:** a standalone harness, `urf_top`, implemented at 100 and 200 MHz. Its stand-ins are registers placed where their counterparts sit in `h100_m6m`'s core 0 (`q_urf_ctx.tcl`), and the nine copies sit at `URAM288_X0Y52`–`X0Y60`, level with core 0's RF stage. A probe UltraRAM with its output register gives that register's delay.
- **Context:** the real arrivals of each input, from `h100_m6m`'s routed checkpoint.

**Two slot plans per copy:**

| | Core edge | Mid-cycle |
|---|---|---|
| As briefed (`WMODE "mid"`) | A and B read (early ports) | A reads the store-data port (copy 0); B writes |
| Variant (`WMODE "edge"`) | A writes; B reads after it (an early port) | A reads an operand from a registered address; B idles |

**Function:**
- **Both plans return exactly what the LUTRAM file returns:** every read in a cycle sees the writes of earlier cycles. Both pass 200K cycles on both URAM models with no mismatch: 1,399,398 port reads ("mid") and 1,199,484 ("edge").
- **The testbench catches each assumption.** Broken copies fail:
  - port B before port A: 53,198 mismatches ("mid", exactly its mid-cycle reads of an address being written), and 154,877 ("edge", exactly its reads of the previous cycle's write);
  - a write that updates the port's output: 450,408;
  - no mid-cycle capture: 188,018.
- **So UltraRAM behaves as UG573 describes:** port A's operation goes first in a cycle, a write leaves the output unchanged (NO_CHANGE), and a disabled port holds its output.

**UltraRAM delays** (XCK26, −2LV):
- Clock-to-out without the output register: 1.63–1.70 ns on port A and **2.65 ns on port B**, which acts after A.
- With port B's output register: 0.81–0.96 ns.
- Setup: 0.68–0.75 ns on port A's address, 0.45 on port B's, 0.50 on port B's write data.
- Clock uncertainty between the 100 and 200 MHz clocks: 0.187 ns.

**Standalone timing** (core 0's distances):

| Path | "mid" | "edge" |
|---|---|---|
| Select → URAM address at the core edge (10 ns) | +7.161 | +6.972 (port B) |
| Registered address → URAM at mid-cycle (5 ns) | +2.455 (the LSU's tag) | +1.539 (issue → RF register) |
| Write → URAM | +2.107 (mid-cycle, 5 ns) | +6.308 (core edge, 10 ns) |
| Early data held to the core edge → RF stage (10 ns) | +4.995 | +4.097 |
| Port A's early data → mid-cycle capture → RF stage | +1.668, then +2.719 | — |
| Mid-cycle read → its capture (5 ns) | +1.728 (LSU, beside the column); +1.220 into the RF stage through the LD/STA select | +0.859 into the RF stage through the LD/STA select |
| WNS at 100 / 200 MHz; WHS | +1.728 / +1.668; +0.012 | +0.859 / +1.539; +0.011 |
| Glue in `tg_urf` | 612 LUTs, 206 FFs | 542 LUTs, 8 FFs |

- **A mid-cycle read leaves 1.68–1.94 ns** after its data reaches the first LUT. The UltraRAM's clock-to-out and the route out of the column take 2.2–2.6 ns of the half cycle. That is less than the 2.5 ns the brief set as the bar for tier B.

**In context** (`h100_m6m`; core 0, core 1 in brackets):
- **The select output** reaches today's issue → RF registers at 7.40 (7.45) ns, with +2.40 (+2.33) ns of slack. Those registers sit about 2.5 slice columns from the free UltraRAMs. Taken at the URAM's address instead, the slack drops by about 0.5 ns on port B (setup and uncertainty) and 0.8 ns on port A.
- **Bank 1's write data** (ALU 1, CSR, multiply, divide and P4's results) is ready about 4.5 ns into the cycle, at its multiplexer. That's after the ROB's flush and P4's arbitration. The worst path into today's LUTRAM write pins is 6.05 (6.85) ns, most of it the LUTRAM's fan-out wire. Banks 0 and 2 write straight from registers.
- **The store-data tag** is ready 5.19 ns into the cycle, after the LSU's selection of the oldest ready store: 17 levels including 4 carry chains. It reaches today's LUTRAM at 6.74 ns. The whole store-data path takes 8.65 (8.37) ns.

**Findings:**
- **Double pumping works.** UltraRAM at 200 MHz from the 100 MHz clock's MMCM is correct, and it closes standalone with 1.5–1.7 ns to spare at 200 MHz.
- **As briefed, it doesn't fit the routed chip:**
  - bank 1's write would have to reach the URAM about 4.3 ns into the cycle, and misses by about 2 ns;
  - the store-data tag would have to arrive by about 3.95 ns, and misses by more than 1.2 ns before even counting the route to the column.
- **With the write at the core edge it fits without a new stage:**
  - the write keeps its full cycle;
  - the store-data port (and, in trace builds, the trace ports) stays on a small LUTRAM copy: 3 × 10 RAM64M8 and a 64-LUT select;
  - every remaining input has a margin estimated at 1.5–2 ns in context, except the mid-cycle operand reads: +0.86–1.22 ns standalone, 1.7–1.9 ns after their data arrives.
- **Gain:**
  - for the integer files, about 1,140 LUTs a core (1,984 → about 846), 2.3K a chip, using 9 UltraRAMs a core;
  - the FP files, not built (2 banks × 2 copies and a store-data LUTRAM copy), might add about 0.5K a chip and 4 UltraRAMs a core, 26 of the 32 free UltraRAMs in all.
- **Tier B was not run:** the mid-cycle margin is below the brief's 2.5 ns bar.
- **Its risk, if run:**
  - the thinnest path (+0.86 ns standalone) sits inside one full-chip placement's ±0.75 ns of noise (§8.8);
  - the change reaches the issue → RF interface (the select's output for three ports), `tg_exec`'s read ports, the store-data and trace ports and the board's clocking (a 200 MHz output and its global buffer);
  - the payoff is about 2–2.4% of the device's LUTs.

Results: `fpga/spikes/results/urf/` (`SOURCE.txt` lists them). The harness and RTL are on `claude/spikes-2-uram-rf` (`fpga/spikes/uram/`), not on main.

### 8.15 The build hosts compared: w-arrowlake against w-x299 and the 5950X (2026-10-19)

**Question (the coordinator):** how fast is a full chip on the new build host? w-arrowlake is a Core Ultra 7 270K Plus: 8 P-cores at up to 5.4 GHz and 16 E-cores at 4.7 GHz. Compare it step by step with `h100_m6m` on w-x299 (§8.13, 172 min) and the 5950X's `h100_m6fa` (§8.12, 65 min).

**Method:**
- `h100_m6m`'s placement and routing again, as `h100_m6m_al`, from its post-synthesis checkpoint (main 31e65c6) with the same options and Vivado 2025.2.
- Vivado pinned to the P-cores (`taskset -c 0-7` on the launcher, which Vivado inherits), matching its 8 implementation threads.
- The soak was moved to the E-cores for the run. Other tracks' simulations and one to three other Vivado jobs still shared the P-cores (`load.txt`, every 5 min): P-cores 97–100% busy throughout, E-cores 61–100%, a 1-minute load of 19–47 on 24 CPUs.

**The same work.** The run reached exactly `h100_m6m`'s result: WNS +0.348 ns, WHS +0.011, 113,721 LUTs placed. The summaries match apart from their times, and so do the worst paths. Vivado's placement and routing at 8 threads repeats exactly across hosts, so these times compare the same work, with no placement noise to allow for.

| Step (`times.txt`) | w-x299: CPU / elapsed s | w-arrowlake: CPU / elapsed s | Less CPU | Faster |
|---|---|---|---|---|
| open_checkpoint | 57 / 47 | 19 / 18 | 3.00× | 2.61× |
| opt_design (ExploreArea) | 607 / 231 | 223 / 117 | 2.72× | 1.97× |
| place_design | 1,942 / 817 | 2,135 / 1,010 | 0.91× | 0.81× |
| phys_opt_design | 83 / 23 | 30 / 13 | 2.77× | 1.77× |
| route_design | 22,220 / 9,020 | 7,964 / 5,876 | 2.79× | 1.54× |
| The whole job | 172.4 min | **118.3 min** | | 1.46× |

The 5950X ran `h100_m6fa` (§8.12), a different netlist with easier timing for the router, in 64.8 min: 686 s to optimise and place, 3,055 s to route.

**Findings:**
- **Per thread, w-arrowlake does the same work in about 2.8× less CPU time than w-x299.** That holds for every step but placement. Placement's waiting threads spin, so under contention its CPU time doesn't measure work.
- **Under this load the job took 118 min,** 1.46× faster than w-x299 but slower than the 5950X's 65 min. Vivado shared the P-cores the whole time:
  - routing kept 1.4 threads busy, against 2.5 on w-x299;
  - placement kept 2.1, against 2.4, and was 6% slower than on w-x299 itself.
- **With the P-cores to itself, a full chip should take about an hour,** as fast as the 5950X:
  - routing's 7,964 CPU-seconds at w-x299's 2.5 threads is about 53 min;
  - the other steps add about 8 min.
- **So for the queue:** a full chip gets w-arrowlake's per-thread speed only on free P-cores. Simulations on the E-cores while one runs keep it near an hour. Every simulation on the P-cores costs it directly.

**The rerun with the host policy** (2026-10-19, 22:42; `h100_m6m_al2`):
- **Setup:** Vivado pinned to the P-cores by `tools/vivado_run.sh`, and simulations at nice 10 or on the E-cores. It launched once the host was quiet: no other Vivado job, and the P-cores under 25% busy on two checks 5 min apart.
- **Same result:** WNS +0.348 ns and 113,721 LUTs.
- **The quiet lasted about 8 min.** Two more Vivado jobs then started, pinned to the same eight P-cores by the same policy. For the rest of the run the P-cores were 80–100% busy, with 2–3 Vivado jobs at once.

| Step, elapsed s (busy threads) | w-x299 | w-arrowlake, loaded | w-arrowlake, rerun |
|---|---|---|---|
| opt_design | 231 (2.6) | 117 (1.9) | 98 (2.4) |
| place_design | 817 (2.4) | 1,010 (2.1) | **419** (2.0) |
| phys_opt_design | 23 | 13 | 18 |
| route_design | 9,020 (2.5) | 5,876 (1.4) | 4,779 (2.1) |
| The whole job | 172.4 min | 118.3 min | **90.4 min** |

- **Placement, mostly in the quiet part, was 1.95× faster than w-x299.**
- **Routing was 1.89× faster,** but it shared the P-cores, and its CPU time grew to 9,819 s: busy waiting under contention, for the same work that took 7,964 s in the loaded run.
- **So an hour is not yet confirmed.** 90 min is the time with 2–3 Vivado jobs on the P-cores.
- **The policy has a side effect.** Pinning every Vivado job to the same eight P-cores makes concurrent full chips share them, while the E-cores take the simulations. A full chip gets the P-cores only if fewer Vivado jobs run at once, or if small ones (queries, out-of-context runs) go elsewhere.

Results: `fpga/spikes/results/h100_m6m_al/` (with `times.txt` and `load.txt`), and the rerun `h100_m6m_al2/`.

### 8.16 The UltraRAM register file in the full chip: tier B (2026-10-19)

**Question (DR-174, the coordinator):** §8.14's core-edge variant is now the core's URF switch. core-2 wrote the core side from `tg_urf`; soc-2 wrote the 200 MHz clock (`tg_clkgen`'s CLKOUT2, `kv260_top`, `timing_urf.xdc`). Does the M6 full chip still meet 100 MHz with hart 1's area when `TG_URF=1`, at both clocks? What do the register file's paths show in context, and what does it save?

**Method:**
- **Tree:** core-2's `claude/track-core-adb715-urf-on` 06d73b5 merged with main (soc-2's board side, e146740), as the scratch branch `claude/spikes-2-urf-tierb` 31570d5. Its RTL is that of core-2's MR head 94ce462 (core-2).
- **Flow:** §8.12's at 100 MHz with hart 1's filler at 47 tiles. `g4_fit.tcl` reads `timing_urf.xdc` and the register file's scoped `tg_urf.xdc` after synthesis. `report_exceptions` shows all 12 of its multicycles applied, six per core, none ignored.
- **Over-constraint:** the core clock gets 1.0 ns during placement and routing, and `clk2x` the same share of its period, 0.5 ns. Both are taken back for every figure below.
- **Control:** the same tree with `TG_URF=0`, to isolate the URF's effect.
- **Host:** Vivado pinned to w-arrowlake's P-cores.

| | `TG_URF=1` (`h100_urf`) | `TG_URF=0` (`h100_urf0`) | Difference |
|---|---|---|---|
| LUTs after synthesis | 115,873 | 118,453 | **−2,580** (−1,290 a core) |
| LUT as memory / as logic (synthesis) | 19,332 / 96,541 | 21,972 / 96,481 | −2,640 / +60 |
| LUTs after optimisation | 111,706 | 114,202 | −2,496 |
| Placed LUTs (fill) | 108,693 (92.8%) | 111,217 (95.0%) | **−2,524** |
| Flip-flops placed | 61,599 | 61,548 | +51 |
| UltraRAMs | 50 | 32 | +18 (9 a core) |
| WNS / WHS ns, core clock | +0.769 / +0.010 | +0.801 / +0.010 | −0.03 |
| Endpoints below 0.5 / 1.0 ns | 0 / 199 | 0 / 50 | |

**Clock pairs with the URF**, WNS and WHS in ns:

| Pair | WNS | WHS |
|---|---|---|
| core clock → core clock | +0.769 | +0.010 |
| core clock → `clk2x` | +0.977 | +0.104 |
| `clk2x` → `clk2x` | +1.488 | +0.250 |
| `clk2x` → core clock | +1.188 | +0.067 |

**The register file's paths in context**, core 0 / core 1 (`q_urf_chip.tcl`):

| Path | Budget | Slack ns |
|---|---|---|
| Select → port B's address (early reads) | 10 ns | +2.256 / **+0.977** (core 1: 12 levels from the issue queue's age) |
| Half-cycle flag and late address → port A | 5 ns | +1.143 / +1.584 |
| Write → UltraRAMs (from the ROB's flush, P4's results) | 10 ns | +2.741 / +2.461 |
| Port B's held data → RF stage | 10 ns | +3.819 / +3.218 |
| Port A's mid-cycle data → RF stage | 5 ns | +1.205 / +1.188 |

- **Mid-cycle margin:** a mid-cycle read leaves 1.42 / 1.40 ns after its data reaches its first LUT.
- **Each core's `tg_irf`:** 718 LUTs, 240 LUTRAM (the store-data port's copy), 26 flip-flops and 9 UltraRAMs. Its UltraRAMs sit at `X0Y48`–`X0Y59` (core 0) and `X0Y4`–`X0Y14` (core 1).

**Findings:**
- **The merged URF meets 100 MHz with hart 1's area, at both clocks.** WNS +0.769 ns against the control's +0.801, with no endpoint within 0.5 ns, from one placement each (§8.8's ±0.75 ns).
- **It saves 2,524 placed LUTs on the chip for 18 UltraRAMs.** That is −1,290 a core after synthesis, exactly core-2's figure out of context, and 2.2% of the device. It takes the fill from 95.0% to 92.8%.
- **The worst paths stay in the front end:** core 1's I$ data RAM → `krt_q` (+0.769) and core 0's queue head → rename's uop register (+0.771). The URF adds near-critical endpoints, 199 within 1 ns against 50, mostly that rename register.
- **The URF's own tightest path** is core 1's select → port B's address (+0.977). Its mid-cycle reads close with 1.2 ns to spare in the routed chip, 0.3 ns better than tier A's standalone harness.
- **Main itself** places at 95.0% without the URF, against `h100_m6m`'s 97.1% (§8.13), and meets 100 MHz with +0.80 ns.

Results: `fpga/spikes/results/h100_urf/` (with `urf_chip.txt`, the register file's paths, and `near_families_urf.txt`), `h100_urf_synth/` (with `urf_exceptions.rpt`), and the control `h100_urf0/`, `h100_urf0_synth/`. The tree is the scratch branch `claude/spikes-2-urf-tierb`.


### 8.17 M7's steps 1–3b in the full chip, the URF off and on (2026-10-20)

**Question (the coordinator):** the core alone drifted from +0.876 ns before M7 to +0.565–0.717 ns over steps 2–3b. What does the full chip show before step 5 adds real hart 1? The answer puts DR-174's switch on a trend, not one point.

**Method:** main 271d4527 (M7 steps 1–3b, hart 1 off) at 100 MHz with hart 1's filler (47 tiles, 20 LUTRAM blocks). §8.12's flow, with 1.0 ns over-constraint on the core clock and 0.5 ns on `clk2x`, taken back for the figures. Two builds in parallel on w-arrowlake, URF off (`h100_m7b0`) and on (`h100_m7b1`), one placement each.

| | URF off (`h100_m7b0`) | URF on (`h100_m7b1`) | §8.15 `h100_m6m` (31e65c6) | §8.16 URF off / on (31570d5) |
|---|---|---|---|---|
| LUTs after synthesis | 119,501 | 116,911 | 121,004 | 118,453 / 115,873 |
| LUTs placed (fill) | 112,397 (96.0%) | 109,675 (93.6%) | 113,721 (97.1%) | 111,217 (95.0%) / 108,693 (92.8%) |
| UltraRAMs | 32 | 50 | 32 | 32 / 50 |
| WNS / WHS ns, core clock | **+0.022** / +0.001 | +0.988 / +0.006 | +0.348 / +0.011 | +0.801 / +0.769 |
| Endpoints below 0.5 / 1.0 ns | 825 / 4,458 | 0 / 7 | 82 / 1,239 | 0 / 50 and 0 / 199 |
| Routing | 65 min | 22 min | 150 min (w-x299) | 33 / 24 min |

**Worst paths:**
- **URF off, all at +0.022–0.100 ns:**
  - the front end: core 1's I$ data RAM → `krt_q` and core 0's TAGE table RAM → F3's target, both 19 levels;
  - the LSU: the DTLB → M2's data (+0.038), and 512 endpoints of the L1D tag RAM from `lose_line_q` (+0.042);
  - new with M7's per-hart state: core 0's CSR state `h_q[mie]` → `h_q[fs]` (+0.045), the PMP address RAM (+0.097) and rename's free-list count (+0.100).
- **URF on:** only 7 endpoints within 1 ns. Core 0's I$ data RAM → `krt_q` +0.988, the L1D data RAM from the store queue's head +0.989, and the two cores' F3 targets.
- **URF on, its clocks and paths:** `clk2x` at +1.412 ns. The register file's tightest path is core 1's select → port B's address, +1.586 ns, and its mid-cycle reads are +1.16–1.17 ns.

**Findings:**
- **Steps 1–3b add about 1,040 LUTs to the chip after synthesis** (+1,048 URF off, +1,038 on, against §8.16), about 1,180 placed.
- **They take the URF-off chip from +0.80 ns at 95.0% placed to +0.02 ns at 96.0%.** That is right at DR-175's trigger on both counts: about 96% placed, and the edge of 100 MHz. With 825 endpoints within 0.5 ns, one more placement could as easily miss.
- **The same tree with the URF on meets 100 MHz with +0.99 ns at 93.6%,** saving 2,722 placed LUTs and 0.97 ns.
- **Against §8.15's `h100_m6m`, the URF-off chip is 1,324 LUTs smaller but 0.33 ns slower.** Main shed about 2.5K LUTs between 31e65c6 and 31570d5 (§8.16), and M7's steps put about 1.2K back with paths of their own.
- **Before step 5 adds hart 1** (about +1.1K LUTs a core above the filler), the URF-off chip is already at the trigger.

Results: `fpga/spikes/results/h100_m7b0/`, `h100_m7b1/` (with `urf_chip.txt`), each with `near_families_*.txt`, and their `_synth/` folders.

### 8.18 M7 step 5's product chip with real hart 1, the URF off and on (2026-10-21)

**Outcome (10-23): the M8 release image of record is `rc3_u095r`.**
- It is coord/rc3, which is main's RTL with M7 complete, at 100 MHz: WNS +0.748 ns, TNS 0, WHS +0.006.
- The flow is the product form with `TG_ROUTE_DIRECTIVE=AlternateCLBRouting` at `TG_PR_UNC=0.95`.
- `tanager.bit.bin` sha256 2a47608a…; see "The release pair on coord/rc3" below.

**Asked** (the coordinator, 10-20 and 10-21):
- **What to build:** M7 step 5c's full chip with hart 1 running. It is the board's product configuration (DR-177: M8's exit is defined on it), built by d4r2's recipe plus `TG_HART1=1` and the release form (`LAT_INJ=0`).
- **The two chips:**
  - with the URF off: the formal DR-175 trigger measurement (the URF switches on above about 96% placed, or below 100 MHz);
  - with it on: the build soc-2 packages for the board if it closes.
- **Also asked:** the cost of the product windows, from a plain against product synthesis pair.

**Builds:**
- **Commit:** main 071de15c, M7 step 5c with 5b's fetch fixes; §7.1's F and A are in.
- **d4r2's recipe** (its `summary.txt`, profile `d4r2-smt2-notrace-pswin-fan`), in `g4_fit.tcl` terms:
  - smt2, two cores, 100 MHz;
  - no trace, the PMOD console and the fan's PL regulator;
  - the uncore DSP mask's default;
  - the windows `VIRTIO_WINDOW=1`, `HOST_DMA=1` and `TG_PS_WINDOW=1`;
  - `-flatten_hierarchy rebuilt`, AreaOptimized_high and ExploreArea;
  - no floorplan, as the board flow uses no pblocks;
  - 1.0 ns of uncertainty through placement and routing on the core clock and on `clk2x`.
- **This differs from §8.17's flow** (`-flatten_hierarchy none`, the `g4_uncore` pblocks, half the uncertainty on `clk2x`).
- **Launch:** the build tree's `tools/launch_hu.sh`, in two `h7_guard.sh` series side by side. Each synthesis declared 24 GB and each placement 12 GB.

| Point | What | Synthesis LUTs | After `opt_design` | Of 117,120 | Placement |
|---|---|---|---|---|---|
| hu0 | product, URF off | 126,994 | 121,893 | **104.1%** | **fails** (Place 30-487: 11,067 CLBs needed, 10,490 left) |
| hu1 | product, URF on | 124,414 | 119,295 | **101.9%** | **fails** (11,059 CLBs needed, 10,814 left) |
| hp0 | hu0 without the windows (synthesis only) | 123,861 | — | — | — |
| hn0 | hp0 with §8.17's `-flatten_hierarchy none` (synthesis only) | 124,193 | — | — | — |

All four synthesize cleanly: no forward references and no implicit nets, with 121 block-RAM tiles (the injectors' four are gone), 157 DSPs, 32 UltraRAMs with the URF off and 50 with it on. Synthesis takes 17.5–23.6 minutes and peaks at 8.2–9.1 GB in the main process. Both placements stop after 7–10 minutes of `place_design`. **So there is no routed checkpoint, no WNS on `clk` or `clk2x`, and no bitstream.**

**Findings:**
- **DR-175's trigger fires:** the URF-off chip needs 104% of the device's LUTs before placement.
- **The URF-on chip does not fit either.** 119,295 LUTs after `opt_design` is 2,175 over the device and about 6.9K over the 112.4K at which §8.17's URF-off chip still closed 100 MHz (96.0%). The placer is 245 CLBs short.
- **The windows cost 3,133 LUTs** (hu0 − hp0, synthesis), 344 of them LUTRAM, and 1,966 flip-flops:
  - the uncore +2,505: the host DMA port 796, the crossbar's own logic +802, the PLIC's extra sources +553 and the virtio window 272;
  - core 0 +468, core 1 +66, and the top level +94.
- **`-flatten_hierarchy rebuilt` saves 332 LUTs** (hp0 − hn0) and 385 flip-flops. Units trade LUTs with each other under the rebuilt hierarchy, so only the total counts.
- **The URF saves 2,598 LUTs after `opt_design`** (2,580 at synthesis), as tier B's did (§8.16), for 18 UltraRAMs.
- **Against §8.17, like for like** (hn0 against `h100_m7b0`'s synthesis: no windows, `-flatten_hierarchy none`, URF off), the chip grew by +4,692 LUTs:
  - −7,428 for the filler and −1,310 for the two injectors, both gone;
  - +6.7K in each core: fetch +1,741 (its own logic +1,536), rename +1,708, the LSU +1,250, FP's register-file banks of 96 +836, the CSR +525, the ROB +420, the two per-thread RAS +338 net, decode −281.
  - **Real hart 1 with steps 4–5c costs about 6.7K a core against the filler's 3.7K**, about 1.9K a core above the plan's +1.1K over the filler. The FP banks' excess (DR-179) is part of it.
- **The rest of M7 (the coordinator's figures) nets about −0.5 to −1.3K a chip:**
  - DR-179's 64-entry FP banks, about −2.6K;
  - DR-178's per-thread rename register, +1.1–1.7K, plus +0.1–0.2K for the commit-turn fix;
  - step 7's caps, +0.2–0.4K.
  That puts hu1 at about 118.0–118.8K after `opt_design`, still over the device.
- **So M7's product chip needs about 2–7K LUTs back before the URF-on build places:** about 2K just to place at the device's edge, about 7K to reach the 96% where this chip still closes 100 MHz. A lower clock comes only after every other method (DR-177).
- **The recorded levers left** (DR-167, area_recovery §7.8):
  - the shared LD/STA PMP checker: 0.9–1.8K, small IPC;
  - the FP and LD queue trims: 0.8K, −0.2%;
  - radix-4 divide: 1.25K, −2.4% single-thread.
- **PMP with 8 entries is already in these chips:** it has been the default since 10-19 (9db66da, `TG_PMP_ENTRIES`), and the netlists confirm it. The CSR's `pmpaddr` store is `DEPTH(NPMP * NT)` = 16 (8 entries × 2 harts; 16 entries would make it 32). The three checkers keep their 8-entry sizes in hn0 as in §8.17's m7b0: 446 (fetch), 427 (loads) and 442 (stores) LUTs.
  `opt_design`'s other directives on hu1's synthesis are below.
- **`opt_design`'s directive is not the lever** ([`q_opt_directives.tcl`](../../fpga/spikes/tcl/query/q_opt_directives.tcl) on hu1's synthesis):
  - ExploreArea, the flow's own, leaves 119,295 LUTs;
  - ExploreSequentialArea leaves 119,161: 134 fewer, and 59 fewer flip-flops;
  - AddRemap, Default and ExploreWithRemap leave 1,437–1,693 more.

Results: `fpga/spikes/results/h100_hu0/`, `h100_hu1/` (their `errors.txt` and summaries), `h100_hu0_synth/`, `h100_hu1_synth/`, `h100_hp0_synth/`, `h100_hn0_synth/`, and `h100_hu_util/`. The last holds the hierarchical utilization of hn0, hp0, hu0 and §8.17's m7b0 ([`q_util_hier.tcl`](../../fpga/spikes/tcl/query/q_util_hier.tcl)), and the unit diffs from [`util_diff.py`](../../fpga/spikes/scripts/util_diff.py).

#### Where hart 1's LUTs go (2026-10-21)

**Asked** (the coordinator): where inside fetch, rename, the LSU, the CSR file and the ROB hart 1's LUTs went, and which of them are flip-flop state behind wide muxes that LUTRAM with the thread as an address bit could hold. The aim is a ranked list of no-IPC rewrites, for core-2 and fpu-2 to take after M7's features (DR-155). Synthesis only.

**Method:**
- **hz0 = hn0 with `TG_HART1=0`**, on the same commit (071de15c) with the same flow. So hz0 → hn0 is hart 1 alone.
- **Per unit:** the hierarchical reports, in `diff_hz0_hn0.txt`.
- **Per signal:** every LUT and flip-flop cell, named for the signal it drives or holds ([`q_cell_groups.tcl`](../../fpga/spikes/tcl/query/q_cell_groups.tcl), [`cell_groups_diff.py`](../../fpga/spikes/scripts/cell_groups_diff.py), `diff_cells_hz0_hn0.txt`). Cell counts run 0.6–1.0× the report's LUTs, because synthesis packs pairs of small LUTs, such as 2:1 muxes sharing a select, into one.

**Hart 1 costs +13,319 LUTs a chip at synthesis** (110,874 → 124,193), 1,808 of them LUTRAM, and +4,909 flip-flops. Steps 4–5c add almost nothing with hart 1 off: hz0 is §8.17's m7b0 less its filler and injectors, within about 0.2K.

| Core 0 | LUTs added | Where (LUT cells, from the cell groups) | Form |
|---|---|---|---|
| Rename | +1,737 | the five free lists +1,112 (the two FP lists +700: 96 deep, so their pointers wrap by compare); the maps +216; `de_take` +124; FP ready bits +88 | per-thread pointers and counts (the lists are already LUTRAM at {tid, row}) |
| Fetch | +1,708 | the waiting-block PCs `spc_s_q` +793 (and 126 flip-flops); the PMP checker's descriptor select +561; the FTQ history's write data +170; miss state +110; the two histories +126; the faulting page +54 | per-stream registers with several writers, and select logic |
| LSU | +987 | the two PMP checkers' descriptor selects +1,147 cells (about 0.58K LUTs, dual-packed); forwarding's thread match +132; DTLB +111; the page walker +102 | select and compare logic |
| FP unit | +847 | the register file's banks of 96 (`u_rf` +836) | DR-179's |
| CSR file | +490 | the read mux `ex_rdata` +285, the timer compares +65; 994 flip-flops of per-hart state | per-hart registers, most read for both harts at once |
| ROB | +469 | the per-thread exception records and their capture, WFI counters +81 | per-thread capture logic |
| Second RAS | +313 | thread 1's stack and its pointers | per-thread stack |

**Findings:**
- **Hart 1's LUTs are mostly duplicated control and selection logic, not flip-flop arrays behind a mux.**
- **The largest single item crosses units: the PMP descriptor selects**, about 1.8K cells a core and about 1K LUTs. Every checker (fetch, loads, stores, the walker) selects its thread's eight descriptors (8 × about 70 bits) from the CSR file's two sets (`pmp_d_h`). That is logic in front of eight parallel compares, and neither alternative pays:
  - a LUTRAM descriptor store, one read port per checker, costs about the same LUTs and puts a LUTRAM read into fetch's PMP path (+0.36 ns in core 1, §7.1);
  - comparing against both harts' entries and selecting the eight results costs about what it saves (the compares are about 50 LUTs an entry).
- **Fetch's per-stream registers have several writers in one cycle** (a refetch or restart on one stream, a redirect on the other), and the next F1 PC reads the waiting PC's next value, not the register. So a one-write-port LUTRAM doesn't hold them as they stand.
- **The CSR file's per-hart registers are mostly read for both harts at once**: the interrupt logic (`mie`, `mideleg`, `stimecmp`), decode's view, the MMU (`satp`), the counters (`mcountinhibit`) and the PMP descriptors (`pmpcfg`). Its cold CSRs (the trap vectors, scratch, EPC, cause and tval) are LUTRAM already.
- **The biggest units overall in core 0 (hn0):** LSU 13.2K LUTs, fetch 7.8K, FP 7.6K, exec 7.5K, rename 5.4K, issue 5.3K, ROB 3.1K, decode 2.0K, CSR 1.8K.

**Ranked no-IPC rewrites** (LUTs a chip, estimated from the cell groups):

| # | Rewrite | Where | LUTs a chip | Status |
|---|---|---|---|---|
| 1 | FP banks of 64 with renaming across both (DR-179) | FP register file, FP free lists, ready bits, map | about −2.6K (the coordinator's figure). Hart 1's share measured here: the 96-entry banks +1.7K, the FP lists' 96-deep wrap about +0.7K, ready bits and map about +0.4K | planned |
| 2 | Each stream's next PC as one flat priority select (redirect, restart, refetch, F1's next, hold), with the shared sources computed once | fetch: `spc_s_q`, `fpc_q` | about −0.4 to −0.6K | for core-2: which same-cycle paths keep fetch zero-bubble |
| 3 | `mcounteren`, `scounteren`, `mcontext` and `scontext` into the cold-CSR LUTRAM (at {tid, csr}) | CSR file | about −0.2K | only CSR instructions read them |
| — | Not levers as they stand: rename's per-thread free-list pointers and counts, the second RAS (an operation and a repair can come for different threads in one cycle), the ROB's exception capture, the LSU's per-thread selects | | — | concurrent per-thread updates or parallel reads |

- **With a small IPC cost:** the shared LD/STA PMP checker. It is on record at 0.9–1.8K a chip before hart 1; it now also removes one descriptor select, about 0.6K a chip more.
- **The arithmetic does not close yet:**
  - hu1's 119,295 LUTs after `opt_design`, less the rest of M7 (−0.3 to −1.2K, DR-179 included), less rewrites 2 and 3 (−0.6 to −0.8K), leaves 117.3–118.4K. That is still at or over the device.
  - The shared checker brings it to about 114.9–116.9K (98–100%), still above the 96% (112.4K) at which this chip has closed 100 MHz.
- **The remaining room:**
  - the product windows' +3.1K (soc-2 is reviewing them);
  - the recorded levers with an IPC cost: the queue trims 0.8K and radix-4 divide 1.25K;
  - rewrites inside the largest units.

Results: `fpga/spikes/results/h100_hz0_synth/` and `h100_hu_util/` (`util_hz0.rpt`, `groups_hz0.tsv`, `groups_hn0.tsv`, `diff_hz0_hn0.txt`, `diff_cells_hz0_hn0.txt`).

#### hp1: the edge, placed (2026-10-21)

**Asked** (the coordinator): one placed point near the device's edge, to find where this design actually closes. The 96% figure is §8.17's chip, built with filler; M8's target could lie anywhere from "just fit" to 96%.

**Build:**
- **hp1** is hu1 without the three product windows: hp0 with the URF on, on main 7864d3bf.
- **Comparable with hu1:** the RTL since 071de15c only makes the speculative-wakeup filter switchable, with the default unchanged.
- **Settings as hu1's otherwise:** d4r2's synthesis, no floorplan, 1.0 ns on the core clock and on `clk2x`, `LAT_INJ=0`, `TG_HART1=1`. 24 GB declared per step; the routed checkpoint is `fp/h100_hp1_routed.dcp`.

| | LUTs | Of 117,120 |
|---|---|---|
| After synthesis | 121,295 | — |
| After `opt_design` | 116,223 | 99.2% |
| Placed | **113,636** (16,270 LUTRAM), 62,028 FFs, 121 BRAM tiles, 50 UltraRAMs | **97.0%** |

**Result: it places and routes, but misses 100 MHz by 2.1 ns.**
- **Run time:** placement 14 minutes, routing 2.5 hours (no routing errors).
- **Core clock `c0`:** WNS **−2.098 ns** (about 83 MHz), TNS −8,566 ns, WHS +0.001 ns. 14,020 of 299,396 endpoints fail: core 0 8,912, core 1 3,859, the uncore 1,249.
- **`clk2x` and the URF are not the limit:** +0.721 into `clk2x`, +1.329 within it, +0.604 back to the core clock.
- **Congestion:** the placer ends at level 5 (32 × 32 windows) in every direction over both cores and the uncore. The router starts at level 6 (64 × 64, short wires east and west) over core 0, whose windows have 97–99% of their LUTs used.
- **The worst paths are everywhere, and mostly wire.** 654 families fall below 1.0 ns, with 64–79% wire on the worst paths:
  - the LSU 205 families, rename 171, the CSR file 101, fetch 94, the two RAS 30, the L2 28, the ROB 12;
  - the worst: core 0's DTLB (−2.10, 16 levels, 9.5 ns of wire), rename's FP free-list counts (−2.09), the LSU's replay address (−2.09), F2's cone into the RAS (−2.07).

**Findings:**
- **"Just fit" does not close.** At 97.0% placed with the board's flow, wire dominates everywhere, not one path.
- **Between §8.17's 96.0% (+0.022 ns) and hp1's 97.0% (−2.098 ns) lies a cliff of 2.1 ns for 1.2K more placed LUTs.** Fill and flow both changed: §8.17's chips had the `g4_uncore` pblocks and `-flatten_hierarchy none`. One more placement of hp1's own synthesis with §8.17's floorplan would separate the two, at no new synthesis.
- **Until then, M8's target is the 96% end or lower:** about 7K LUTs a chip back from hu1, not 2K.

Results: `fpga/spikes/results/h100_hp1/` (with `near_families_hp1.txt`, `urf_chip.txt`, `congestion.rpt` and `worst_paths.txt`, from [`q_congestion.tcl`](../../fpga/spikes/tcl/query/q_congestion.tcl)) and `h100_hp1_synth/`.

#### hp1f: the same netlist with §8.17's floorplan (2026-10-21)

**Asked** (the coordinator): place hp1's own synthesis once more with §8.17's `g4_uncore` pblocks (the two L2 banks and the crossbar), with nothing else changed, to separate the fill from the flow.

**Build:**
- **No new synthesis:** the floorplan names only three uncore cells, and they exist under the same names in hp1's flatten-rebuilt netlist.
- **One pblock is overfull before placement:** the floorplan check shows bank 1's pblock at 101% (6,467 LUT cells for 6,400 sites, against §8.17's 95%); flatten rebuilt moved about 360 cells into bank 1. It placed anyway.
- **A first run was lost** to the afternoon's disk cleanup (my list had included its live run folder) and was rerun unchanged.

| | hp1 (no floorplan) | hp1f (§8.17's pblocks) |
|---|---|---|
| Placed LUTs | 113,636 (97.0%) | 113,893 (97.2%) |
| WNS on the core clock (ns) | −2.098 | **−0.096** |
| TNS (ns) | −8,566 | −1.131 |
| Failing endpoints | 14,020 (core 0 8,912, core 1 3,859, uncore 1,249) | **31** (core 0 14, core 1 17, uncore 0) |
| WNS on `clk2x` (into / within / back, ns) | +0.72 / +1.33 / +0.60 | +1.08 / +1.87 / +1.02 |
| WHS (ns) | +0.001 | +0.006 |
| Endpoints within 1 ns | 25,037, in 654 families | 7,215, in 369 families |
| Routing time | 2.5 h | 1.45 h |

**Findings:**
- **The cliff was the flow, not the fill.** The same netlist at 97.2% placed comes within 0.1 ns of 100 MHz once the L2 banks and the crossbar sit in their pblocks. The board flow (`build.tcl`, d4r2's recipe) has no floorplan, and at this fill that costs about 2.0 ns.
- **The families shrink, they don't move.** They are the same units as hp1's, about 2 ns better:
  - the LSU keeps the most (205 → 160 families below 1 ns), then rename (171 → 119);
  - fetch's F2 cone (94 → 52) now holds the worst endpoints: the I$ valid-bit RAM (26 levels, −0.096), TAGE's history count and the RAS target register;
  - the CSR file's paths, congestion detours in hp1, mostly drop out (101 → 20).
- **So with the floorplan, M8's target is "fit plus a little",** not 96%: hu1's product chip needs to come down to about hp1f's 113.9K placed. That is the windows' +3.1K less DR-180's −1.8K, plus a little margin, roughly 2K LUTs a chip rather than 7K. A second sample (1.05 ns of over-constraint) measures the placement noise around −0.1 ns.
- **Congestion has the same levels, spread more evenly.**
  - The placer ends at level 5 in every direction, as in hp1, with no global window (hp1 had one, west).
  - The router starts at level 5 north and south and level 6 east and west, as in hp1.
  - hp1's level-6 west window was 77% core 0. hp1f's level-6 windows each hold core 1 36–44%, core 0 28–32% and the uncore 26–29%, at 97–98% of their LUTs used (hp1: 97–99%).
  - So the floorplan didn't lower the congestion; it evened it out across the cores and the uncore.
- **The 31 failing endpoints are all in the cores,** none in the uncore:
  - fetch's I$ valid-bit RAM (26 levels) and its I$-data cones into TAGE and the RAS;
  - the D$'s `lose_line_q` enables;
  - the LSU's M1 → M2 and age paths.
- **The pblocks are soft.**
  - Vivado 2025.2 creates them with IS_SOFT 1, before `opt_design`; nothing in this flow sets it.
  - The placer kept each pblock's cells near it, but put 20% (bank 0), 15% (bank 1) and 28% (the crossbar) of their LUT cells just outside: the banks' own-level logic, register slice and LUTRAM buffers, and the crossbar's register slices and arbiters.
  - So `report_utilization -pblocks` counts a pblock's own cells wherever they sit: bank 0's own cells fill 968 slices against its 800.
  - hp1f's result is with soft pblocks. Hard ones are untested: bank 1's pblock, at 101% before `opt_design`, might not place hard.

**hp1fs: a second sample of hp1f** (2026-10-21). The same netlist and pblocks, with 1.05 ns of over-constraint instead of 1.0, which is the perturbation the placer responds to (Vivado has no seed).

| | hp1f (1.0 ns) | hp1fs (1.05 ns) |
|---|---|---|
| Placed LUTs | 113,893 | 113,789 |
| WNS / TNS on the core clock (ns) | −0.096 / −1.131 | **−0.426 / −72.318** |
| Failing endpoints | 31 (core 0 14, core 1 17) | 552 (core 0 343, core 1 205, the uncore 4) |
| `clk2x`: into / within / back (ns) | +1.08 / +1.87 / +1.02 | +0.73 / +1.71 / +1.02 |
| WHS (ns) | +0.006 | +0.001 |
| Families within 1 ns | 369 | 421 |
| Placement / routing time | 15 min / 1.45 h | 10 min / 1.41 h |

- **The noise is about 0.3 ns.** hp1f's −0.096 was the good end. At 97.2% placed with the floorplan, two placements land 0.1–0.4 ns short of 100 MHz.
- **The same units hold the near-critical families.** Below 1 ns:
  - rename has 155 (hp1f 119), the LSU 147 (160), fetch 70 (52) and the RAS 26 (14);
  - the worst are fetch's TAGE carry, the I$ valid-bit RAM and the RAS pop, rename's free-list counts, and the LSU's LQ state (187 endpoints).
- **New in hp1fs: 57 families start at the ACLINT.** hp1f had none.
  - The path runs from the uncore ACLINT's `rst_q`, through hart 3's timer compare (`g_mti[3]`), combinationally into core 1's CSR file (the interrupt decision and the trap code), then its ROB (the commit) and rename's free-list counts.
  - That is 21 levels and 7.0 ns of wire, at −0.42 ns. The ACLINT sits in the uncore at row 113–170 and core 1's CSR file at row 173 and above, so this placement made the wire long.
  - A register on each hart's timer-interrupt line, in the ACLINT or at the core's input, takes the path out for one cycle of interrupt latency.
- **For M8:** "fit plus a little" has to cover this noise, about 0.3–0.4 ns of margin rather than 0.1. That margin comes from timing fixes such as the ACLINT register and the I$ valid-bit path, or from a lower fill.

Results: `fpga/spikes/results/h100_hp1fs/` (with `near_families_hp1fs.txt`, `urf_chip.txt`, `floorplan.txt`, and `path_cells_aclint.txt` from [`q_path_cells.tcl`](../../fpga/spikes/tcl/query/q_path_cells.tcl)).

**DR-181: the floorplan in the board's flow.** The coordinator adopted `g4_uncore` for the board's product builds; soc-2 wires it into `build.tcl` and spikes-2 keeps it tuned. [`fp_lib.tcl`](../../fpga/spikes/tcl/fp_lib.tcl) adds two checks for every product build:
- `tg_fp_check`, after the floorplan and before `opt_design`: each pblock's LUT cells against its LUT sites. It warns above 105% and calls the pblock tight above 115%.
- `tg_fp_check_placed`, after `place_design`: each pblock's own LUTs against its sites. It warns above 85% and calls the pblock tight above 90%, which means resize it. It also logs IS_SOFT and the share of the pblock's own LUT cells placed outside it.

| Pblock | LUT sites | hp1f before `opt_design` | hp1f own after placement | hp1f outside | Main e6691d53 with the product windows, before `opt_design` | soc-2's d4r2 check: before `opt_design` | own after placement | outside |
|---|---|---|---|---|---|---|---|---|
| `l2b0` (L2 bank 0) | 6,400 | 95% | 73% | 20% | 94% | 98% | 73% | 13% |
| `l2b1` (L2 bank 1) | 6,400 | 101% | 77% | 15% | 102% | 102% | 76% | 16% |
| `xbar` (the crossbar) | 4,032 | 52% | 45% | 28% | 72% | 65% | 51% | 31% |

- **The two thresholds agree.** After `opt_design` and LUT packing, a pblock's own LUTs came to 76–87% of its estimate, so 105% before `opt_design` is about 80–90% own after placement.
- **The product windows** grow the crossbar's pblock from 52% to 72%; the banks barely change.
- **soc-2's DR-181 check** (10-21): `build.tcl` with d4r2's recipe and the floorplan, on main. That is hart 1 off, the URF off, the injectors in and the product windows on.
  - It placed 107,657 LUTs (91.9%) and closed at WNS +0.876 ns and WHS +0.001 ns. d4r2 without the floorplan, on ef44e5b7, had closed at +0.367 ns.
  - Every pblock graded OK. Its fill after placement is within a few points of hp1f's, so nothing needs resizing.
- **Resizing:** a bank's pblock grows by two SLICE rows (160 LUT sites a row in the X2 column). The crossbar has room in X1.

Results: `fpga/spikes/results/h100_hp1f/` (with `near_families_hp1f.txt`, `urf_chip.txt`, `floorplan.txt`, `congestion.rpt` and `worst_paths.txt`; `fp_checks.txt` from [`q_fp_checks.tcl`](../../fpga/spikes/tcl/query/q_fp_checks.tcl); `pb_spill.txt` and `pb_soft.txt`, the cells outside, from [`q_pb_spill.tcl`](../../fpga/spikes/tcl/query/q_pb_spill.tcl) and [`q_pb_soft.tcl`](../../fpga/spikes/tcl/query/q_pb_soft.tcl)); main's check in `h100_ex1_synth/fp_check_g4_uncore.txt`.

#### The product closure baseline: places, doesn't route (2026-10-21)

**Asked** (the coordinator, 21:40): the first measurement of where the product chip stands. It is a baseline, not a sign-off: step 6 (+~384 LUTs a core) and fpu-2's FPU levers (−290 a core, on main since 897bd3a3, not in this build) follow.
- **Basis:** main c0030303 (DR-180, M7 step 5f) merged with soc-2's DR-181 branch c183e3ad. Its `build.tcl` is the one that landed as 5332b771.
- **Flow:** the board's product flow, `build.tcl`: hart 1 real (`TG_DEFINES=TG_HART1=1`), `TG_RELEASE=1`, the URF on, the product windows (`TG_HOST_DMA=1`, `TG_PS_WINDOW=1`), the PMOD UART, the fan's PL regulator, smt2, two cores, 100 MHz.
- **build.tcl's defaults:** the floorplan, `TG_PR_UNC` 1.0, `ExploreArea` and `AreaOptimized_high`.
- **Measurement-only additions:** my snapshot added three read-only lines to `build.tcl`: utilization after `opt_design` and after placement, and a routed checkpoint, which the failed route never reached.

| | Product (c0030303 + DR-181) | hp1f, for reference (7864d3bf, no windows, before DR-180) |
|---|---|---|
| LUTs after synthesis | 120,579 | 121,295 |
| LUTs after `opt_design` | 116,190 (99.2%) | 116,223 |
| LUTs placed | 113,792 (97.2%), 15,376 of them LUTRAM | 113,893 (97.2%) |
| FFs placed | 63,912 | 62,016 |
| CLBs used | 14,637 of 14,640 | 14,640 of 14,640 |
| Control sets | 2,849 | 2,799 |
| WNS / TNS after `phys_opt_design` (estimated, with `TG_PR_UNC`'s 1.0 ns still on) | −1.704 / −3,793 ns | — |
| Routing | **failed:** 28,100 signals unrouted for congestion, 32,975 node overlaps, after 1 h 59 min | routed: −0.096 ns (hp1fs: −0.426) |
| The router's starting congestion | short level 6 (64 × 64) in all four directions, over 29–34% of the tiles; global level 6 north | short level 5 north and south, 6 east and west |

The floorplan checks all graded OK:

| Pblock | Before `opt_design` | Own after placement | Own LUT cells outside |
|---|---|---|---|
| L2 bank 0 | 97% | 74% | 22% |
| L2 bank 1 | 102% | 79% | 21% |
| Crossbar | 70% | 55% | 37% |

**Findings:**
- **At hp1's LUT fill the product chip doesn't route.** It has the same LUTs as hp1f but 1,896 more flip-flops and 50 more control sets. Since hp1's tree, step 5d's second rename register added 1,626 flip-flops a chip, DR-180 removed 3,170, and the windows, 5e, 5f and DR-179 account for the rest. Every CLB was already used in hp1f.
- **Its congestion is a level worse.** Short-wire congestion is level 6 in every direction instead of two, and the router gave up timing (an intermediate WNS of −7.3 ns) trying to route.
- **One run can't separate the flip-flops from placement noise.** hp1f and hp1fs spread 0.33 ns, but neither came near failing to route.
- **The chip is CLB-bound, so the area it needs back is LUTs and flip-flops both.**
  - Measured today: PMP checks at TLB fill (at most 3.4K LUTs a chip), and rename's payload beside rename (about 3.4K FFs and 1K LUT cells a chip). Both are designs for core-2.
  - fpu-2's −580 LUTs a chip are on main; step 6 adds about +770.
- **Flow levers cost no LUTs:** a congestion-directed placement (`place_design -directive AltSpreadLogic_high`), which `build.tcl` doesn't offer yet, is untested here.

**Where the flip-flops grew since hp1** (the coordinator, 10-22). Each step is the difference of two builds with the board's synthesis. Flip-flops keep their RTL names under `-flatten rebuilt`, so their units are reliable.

| Step | Builds compared | FFs after synthesis | FFs after `opt_design` | Where (after synthesis) |
|---|---|---|---|---|
| The product windows | hu0 − hp0 (both 071de15c, URF off); hu1 − hp1 | +1,966 | +2,179 | All in the uncore: the host bridge +1,074, the host DMA and the PS window about +640 together, the crossbar +275 |
| 5d, 5e and DR-179 | ex1 − hu1 | +1,867 | +1,867 | Each core: rename +790 (5d's second rename register), the LSU +90, fetch +61 |
| 5f, DR-180 and the board's flow | product − ex1 | −3,175 | −2,150 | The uncore: the host bridge −2,847, the PLIC −221, the host DMA −96; the cores unchanged |
| **Total** | product − hp1 | **+652** | **+1,896** | |

- **DR-180's −3,170 flip-flops are −2,150 after `opt_design`.** About 1,025 of those it trims at synthesis were flip-flops that `opt_design` swept anyway: it removes 1,487 from hp1, 1,268 from hu1 and ex1, and only 243 from the product.
- **After `opt_design` the uncore nets out near zero** (the windows' +2,179 against DR-180's −2,150). The placed flip-flop growth is, to first order, 5d's second rename register (+1,580 a chip), with the LSU's and fetch's +300.
- **Control sets didn't grow.** After synthesis the product has 2,595 against hp1's 2,621 ([`q_ctrl_sets.tcl`](../../fpga/spikes/tcl/query/q_ctrl_sets.tcl)).
  - By unit: rename −11 a core (5d added registers, not control sets), fetch +6 and the LSU +4 to +5 a core.
  - The uncore −27: DR-180's PLIC −55 and the host bridge −12, against the new host DMA +33 and the PS window +11.
  - So control-set merging is the weaker of the flow levers below.
- **So the design lever that matches the growth is rename's payload beside rename.**
  - It takes about 3.4K flip-flops and 1K LUT cells out of the same two registers and the DS register that 5d doubled.
  - The PMP at TLB fill (2.5–3K LUTs) answers the LUTs.

**Flow levers lined up** (no LUT cost), by what the AltSpreadLogic_high run (`product_asl_high`) shows:
- **If it still doesn't route:** the same with `route_design -directive AlternateCLBRouting`, the router's documented congestion directive, keeping the spread placement.
  - Next after that: `opt_design -control_set_merge -merge_equivalent_drivers`, which merges equivalent control and driver nets without adding LUTs.
  - Not `-control_set_opt_threshold`: it moves enables and resets into LUTs, and LUTs are this chip's binding resource.
- **If it routes but misses timing:** `AltSpreadLogic_medium`, which spreads less and so gives back less timing.
- **If it routes near closure:** a second sample at 1.05 ns, for the noise (hp1f's two differed by 0.33 ns).

Results: `fpga/spikes/results/product_c0030303/` (the utilization after synthesis, `opt_design` and placement; the floorplan's reports; `run_excerpt.txt`, the build's FLOORPLAN, timing and congestion lines).

#### AltSpreadLogic_high: the product chip routes, at −1.55 ns (2026-10-22)

The same snapshot as the baseline, with `place_design -directive AltSpreadLogic_high` in the measurement copy (approved by the coordinator; `product_asl_high`).

| | Baseline (default placement) | AltSpreadLogic_high |
|---|---|---|
| LUTs placed / routed | 113,792 / — | 113,719 / 113,723 (97.1%) |
| FFs, CLBs, control sets | 63,912, 14,637, 2,849 | 63,895, 14,640, 2,820 |
| Routes | no: 28,100 unrouted | **yes** (2.4 h in all) |
| WNS / TNS on the core clock (ns) | — | **−1.547 / −2,887**, 7,651 failing endpoints |
| `clk2x` / the host clock (ns) | — | +1.607 / +3.025 |
| Endpoints within 1 ns | — | 23,782 in 645 families |

- **Spreading buys routability and costs timing.** The worst paths are 64–78% wire.
- **The worst families sit in the cores.** Below 1 ns:
  - the LSU has 193 families (worst −1.55: the walker's `base_q` from the ROB's `ct_q`), rename 192 (−1.41: from fetch's `u_cmp/rt_q` through decode into the per-thread rename registers), the CSR files 98 (−1.43) and fetch 83 (−1.51);
  - the L2 has 27 (−0.90) and the crossbar, with its slices on, 13 (−0.15).
- **128 families (4,055 endpoints, worst −1.43 ns) start at the ACLINT.** That is `rst_q` and the timer wake hints, running combinationally into both cores' CSR files (80 families), rename, the ROB and fetch.
  - hp1fs showed the same path.
  - A register on each hart's timer-interrupt and wake lines, in the ACLINT or at the core's input, removes them all for one cycle of interrupt latency.

Results: `fpga/spikes/results/product_asl_high/` (summary, timing, utilization after `opt_design`, placement and routing, the floorplan's reports, `fail_families.txt` from [`q_fail_families.tcl`](../../fpga/spikes/tcl/query/q_fail_families.tcl)).

#### No slices + AltSpreadLogic_high, with the ACLINT registers: −1.74 ns (2026-10-22)

**Build 1 of the coordinator's combinations** (`product_wt_ns_aslh`):
- **Snapshot:** `snap/product_wt`, main dde95639 with soc-2's ACLINT registers (b856230a) merged as a preview, plus the measurement lines.
- **Settings:** no crossbar or memory-port slices (DR-186's new default), `TG_AR_SLICE=1`, `AltSpreadLogic_high`.

| | asl_high (c0030303, slices on, no ACLINT registers) | **No slices + AltSpreadLogic_high + ACLINT registers** |
|---|---|---|
| LUTs after `opt_design` / routed | 116,190 / 113,723 | 115,692 / 113,346 (96.8%) |
| FFs routed, DSPs | 63,895, 157 | 60,146, 140 |
| CLBs, control sets | 14,640, 2,820 | 14,629, 2,878 |
| The router's congestion | routed | level 5, never put routability ahead of timing |
| WNS / TNS on the core clock (ns) | −1.547 / −2,887 (7,651 failing) | **−1.740 / −5,766** (11,571 failing) |
| `clk2x` within / into it / back (ns) | +1.607 / — / — | +1.118 / **−0.298** / +0.269 |
| Endpoints within 1 ns | 23,782 in 645 families | 24,794 in 619 families |

- **The ACLINT registers worked.** No path from the ACLINT is left within 1 ns, where asl_high had 128 families and 4,055 endpoints (worst −1.43 ns).
- **The response path through the crossbar shrank but remains.** From the L2 banks into the cores: 24 families and 1,169 endpoints within 1 ns (856 of them into fetch), worst −1.459 ns, from the bank's D-queue read pointer into core 1's fetch PC (22 levels).
  - With default placement it had been 42 families and 2,441 endpoints at −3.168 ns.
  - Nothing from the cores into the crossbar, and nothing on the memory ports, is within 1 ns.
- **The worst paths are now decode into the per-thread rename registers.** Fetch's `u_cmp/rt_q` reaches `rn_u_q`'s `imm` (512 endpoints, −1.686 ns) and `br_target` (504, −1.666 ns) through 21 levels, 73% wire.
  - Those are the payload fields that rename's payload lever would carry beside rename. So that lever pays in timing as well as area.
  - Next come fetch's `rt_q` from rename's `ltail_q` (−1.740 ns, 26 levels), the ROB's `hw_q`, and the LSU's M2 from step 6's `md_q` (−1.47).
  - By unit within 1 ns: rename 228 families, the LSU 153, fetch 84, the CSR files 79, the RAS 29.
- **A new failure into `clk2x`:** core 0's issue-queue age (`age_q`) into the URF's UltraRAM read address, 14 levels, −0.298 ns. Build 3 (0.5 ns of uncertainty on `clk2x`) tests that side.
- **Against asl_high this is no gain in WNS.** The ACLINT registers took 4K endpoints out, but the response path put 1.2K in, and the netlist moved on: step 6 and fpu-2's levers.

Results: `fpga/spikes/results/product_wt_ns_aslh/`.

#### The DR-185 preview: rename's payload in a LUTRAM routes at −1.11 ns (2026-10-22)

**Asked** (the coordinator, "the most important build of the day"): core-2's DR-185 preview, `claude/track-core-adb715-dr185` at 3ed73e6f.
- **What DR-185 does:** rename's payload (imm, pc, pred_npc, br_target, insn) waits in a LUTRAM beside rename instead of riding through the per-thread rename registers and DS. It is built on M7 step 7's head 032caa15.
- **Snapshot:** merged into main a6ff993d (DR-186's slices off, the ACLINT registers in), plus the measurement lines.
- **Flow:** `AltSpreadLogic_high`, everything else `build.tcl`'s (`product_wt2_dr185_aslh`).

| | Build 1 (main dde95639 + ACLINT, no slices, high spread) | **DR-185 preview** (+ step 7, + DR-185) |
|---|---|---|
| LUTs after `opt_design` / routed | 115,692 / 113,346 | 116,663 / 114,067 (97.4%) |
| FFs routed | 60,146 | **55,850** (−4,296) |
| CLBs, control sets, DSPs | 14,629, 2,878, 140 | 14,639, 2,795, 140 |
| Routing | 2.5 h; congestion level 5 | **1.0 h**; congestion level 6, but the router never put routability ahead of timing |
| WNS / TNS on the core clock (ns) | −1.740 / −5,766 (11,571 failing) | **−1.108 / −595.5** (2,120 failing) |
| `clk2x`: within / into it / back (ns) | +1.118 / −0.298 / +0.269 | +1.721 / **+0.652** / +0.867 |
| Endpoints within 1 ns | 24,794 in 619 families | **12,886** in 439 families |

- **The flip-flops were the lever.** 4.3K fewer FFs, at about 1K more LUTs (step 7 and DR-185's +86 a core), halved the near-critical endpoints, cut TNS tenfold, routed in 1 hour instead of 2.5, and fixed the path into `clk2x`.
- **The decode → payload paths left the rename registers.**
  - No path into `rn_u_q`'s imm, br_target, pc, pred_npc or insn is within 1 ns (build 1: 512 + 504 endpoints at −1.69 ns).
  - The remaining `rn_u_q` families are its control fields: 45 families, 492 endpoints, worst −0.903 ns.
  - The payload's own LUTRAM (`u_rn/u_pay`) now takes the decode path's writes: one family of 1,258 endpoints at −1.048 ns from fetch's `u_cmp/rt_q`, 18 levels. That is 0.6 ns better than before, but still among the worst.
- **The worst families now** (−1.11 to −1.04 ns):
  - fetch's `u_cmp/rt_q` from the LSU's LQ head (31 levels) and from rename's DS (34);
  - fetch's TAGE from the I$ data;
  - the payload LUTRAM;
  - the LSU's LQ state from step 6/7's `md_l_q`;
  - core 1's walker from the ROB.
  - By unit within 1 ns: the LSU 146 families, rename 90, fetch 82, the CSR files 82.
- **The L2 → crossbar → core response path:** 17 families and 565 endpoints, worst −1.021 ns into core 1's I$ valid-bit RAM (build 1: 1,169 endpoints at −1.459). The ACLINT stays clear.
- **Not a pure A/B.** Step 7's changes ride along with DR-185, and placement noise at this fill is large. But this is the first routed product chip near −1 ns.
- **Path queries** (the coordinator, for core-2 and fpu-2; [`q_pin_classes.tcl`](../../fpga/spikes/tcl/query/q_pin_classes.tcl), `q_path_cells.tcl`):
  - **The payload LUTRAM fails on its write data, not its write address or enable.**
    - Core 1: 522 write-data endpoints within 1 ns, 373 failing, worst −1.048 ns, from fetch's `u_cmp/rt_q` through decode (18 levels, 7.66 ns of wire). Its 736 write-enable endpoints are all met (worst +0.706).
    - Core 0: 483 write-data endpoints, 56 failing, worst −0.373 ns. Its write enable is met at +0.172 ns.
    - No write-address endpoint is within 1 ns.
    - So the fix is a registered write-data port.
  - **TAGE:** the families from the I$ data are core 0's `gp_n_s_q` (4 endpoints, −1.077 ns, 21 levels) and `gp_b_s_q` (2, −0.852), core 1's (−0.581, −0.450), and `fb_wd_q` (15 and 14, about −0.4).
    - The worst path spends about 8 levels in fetch's F3 predecode (the parcel boundary marks), about 10 in `tg_tage` and 3 into `gp_n_s_q`.
    - That is 4.26 ns of logic and 6.52 ns of wire.

Results: `fpga/spikes/results/product_wt2_dr185_aslh/` (with `pin_classes_pay_core0.txt`, `pin_classes_pay_core1.txt` and `path_cells_tage_core0.txt`).

#### The near-final chip closes 100 MHz in one of two placements (2026-10-22)

**Asked** (the coordinator: "the near-final chip, and if it closes, that's 100 MHz"): a pair of placements of `snap/product_wt2` ca66235f564b, with `TG_PMP_FILL=1` and `AltSpreadLogic_high`, at 1.0 and 1.05 ns. The snapshot is main e88f2b98 (TAGE, the L2 bank's registered D output, lever 2, DR-185) plus the forms about to land:
- soc-2's LQ-head fix (mhreg 6da660ec), which carries DR-183 773ebd38;
- core-2's LSU branch (lsutid c06aa48a: the thread carried down the pipe and the walker's registered VPN), merged over DR-183's `tg_lsu` as before; core-2's side of that hunk is `t_lck` alone;
- core-2's `rt_q` with per-bank copies (rtq3c a74817fe, "B").

Step 7 is not in it. The two merge conflicts were resolved in the snapshot only: the known `tg_lsu` hunk, and `tools/ci/lint_all.sh` taken from main's side, which the build doesn't read.

| | **Placement 1** (`fin1_u100`, 1.0 ns) | Placement 2 (`fin1_u105`, 1.05 ns) |
|---|---|---|
| LUTs after `opt_design` / routed | 113,640 / 111,359 (95.1%) | 113,640 / 111,096 |
| FFs routed, CLBs, control sets, DSPs | 57,748, 14,621, 2,830, 140 | 57,757, 14,634, 2,845, 140 |
| WNS after `phys_opt_design` (estimated, with the uncertainty on) | −0.743 ns | −0.642 ns |
| Routing | level 5, no trade, 2.2 h | level 5, no trade, 3.2 h |
| **WNS / TNS on the core clock (ns)** | **+0.257 / 0.000** (0 failing endpoints) | −0.720 / −502.1 (2,112 failing) |
| WHS (ns) | +0.010 | +0.005 |
| `clk2x`: within / into / back (ns) | +1.736 / +1.002 / +0.914 | +1.630 / +1.104 / +0.852 |
| Endpoints within 1 ns | 4,880 in 250 families | 13,434 in 487 families |

- **The pair's verdict: it closes.** The better placement meets 100 MHz with +0.257 ns of slack and nothing failing. The other misses by 0.72 ns, the placement spread seen all day.
- **This is the first product chip that meets 100 MHz.** It is hart 1 real, the release form, the URF, the product windows and the floorplan, at 95.1% of the LUTs.
- **The LQ-head family is gone.** No path from `lq_head_q` is within 1 ns in either placement (the previous preview: 1,111 endpoints at −0.79 ns).
  - The LQ state's endpoints are still near-critical from other starts.
  - In placement 1 all are met: `lq_st_q` +0.274, `fh_data_q` +0.367, `lx_valid_q` +0.371.
  - In placement 2 they come from core 0's `priv_dl_q` (−0.698 ns, 187 endpoints, 23 levels) and core 1's `mh_lq_q` (−0.578).
- **Placement 1's worst endpoints (all met):** core 1's D$ miss entry `g_mn.rl_q` (+0.257), the L2's response into core 0's I$ valid bits (+0.261), and the LSU's `r_data_q`, `lq_sq_q` and `lq_size_q` (+0.27).
- **Placement 2's worst, beyond `priv_dl_q`'s:**
  - fetch's `rt_b_q` from `head_t_q` (−0.720);
  - the L2's response into the I$ valid bits (−0.704);
  - M2's data from the DTLB's CAM (−0.67);
  - the RAS pop from the I$ data and TAGE (−0.61);
  - the decode and rename families from the issue queues' `dep_q` and the ROB's head (about −0.53).
- **The floorplan is OK:** 99/103/37% before `opt_design` and 76/79/32% own after placement. L2 bank 1 is near its 105% warning before `opt_design`, so it is the pblock to watch as step 7 lands.

Results: `fpga/spikes/results/product_wt2_fin1_u100/` and `product_wt2_fin1_u105/`. Placement 1's routed checkpoint is `~/tanager-build/track-spikes-72f833/vivado/product_wt2_fin1_u100/routed.dcp`.

**The board image** (the coordinator, 10-22) was written from placement 1's routed checkpoint by `build.tcl`'s own stage: `write_bitstream`, then bootgen's `.bit.bin` ([`write_bit_from_dcp.tcl`](../../fpga/spikes/tcl/write_bit_from_dcp.tcl)).
- **Files:** `tanager.bit` (md5 d48edff4…) and `tanager.bit.bin` (md5 62ed4eab…), beside the checkpoint.
- **Timing as written:** +0.257 ns, nothing failing.
- **Source:** snapshot ca66235f564b, pinned by the local scratch branch `claude/spikes-2-board-fin1`. Its merges: cafba0e3 (soc-2's 6da660ec, `lint_all.sh` from main), 149de679 (core-2's c06aa48a, the `tg_lsu` hunk), a64c830d (a74817fe).
- **Status:** a preview image. The board build of record comes from main once those MRs land.

#### The release candidate: main builds the board image bit for bit (2026-10-23)

**Asked** (the coordinator, 10-22): a pair of placements of main c11e1bbd with core-2's LSU fix (932a5412) and fetch fix B (895ef1fc), with `TG_PMP_FILL=1` and `AltSpreadLogic_high`: "It becomes the release image once main matches." Snapshot: `snap/product_wt` b82e0e1744fb, pinned by `claude/spikes-2-board-rc1`.

- **Both placements are the near-final pair's, number for number.**
  - `rc1_u100`: +0.257 / 0.000 ns, 0 failing, WHS +0.010, 111,359 LUTs and 57,748 FFs.
  - `rc1_u105`: −0.720 / −502.146 ns, 2,112 failing, WHS +0.005, 111,096 LUTs and 57,757 FFs.
  - The failing-family listings match line for line.
- **Why:** the RTL that differs between the two snapshots is switch definitions whose defaults give the same netlist (7 files, among them `FP_XBANK` and `IQ_CC` in `tg_core_pkg`). Vivado is deterministic for a given netlist and settings.
- **The image.** It was written from `rc1_u100`'s checkpoint by `run_bit_if_pass.sh`:
  - `tanager.bit` md5 b4ac9aac…, `tanager.bit.bin` md5 62ed4eab…, the board image's `.bit.bin` byte for byte;
  - the two `.bit` files differ in 7 bytes, the header's date and time (offsets 111–123), with the same `SW_CRC` 66ac8b95.
  - So the board's u100 image (DR-188, board MR35: four-hart Linux at 100 MHz) is already the release candidate's.
- **Main matches.** The only RTL difference between this snapshot and main 51052152, the last main before step 7, is PMP_FILL's default (8d8bc8ad), which is the `TG_PMP_FILL=1` this pair passed. Main from 8d8bc8ad to 51052152 builds this chip without a define.

Results: `fpga/spikes/results/product_wt_rc1/` holds the two summaries and the images' md5s; the reports are `product_wt2_fin1_u100/` and `_u105/`'s. The image and checkpoint are in `~/tanager-build/track-spikes-72f833/vivado/product_wt_rc1_u100/`.

#### Step 7 on main: neither placement closes, −0.561 ns at best (2026-10-23)

**Asked** (the coordinator, 10-23): "Launch the board pair now", on main 002ea157. That is M7 step 7 (the bank rule on the sibling's need, `ROWS_AT_RN` 2, no per-thread cap), with PMP_FILL on by default. "Write the passing placement's bitstream right away for soc-2." Snapshot: `snap/product_wt3` 189e60d07f37 (main 002ea157 and the measurement commit 0a30d99d), pinned by `claude/spikes-2-board-s7`.

| | Placement 1 (`s7_u100`, 1.0 ns) | **Placement 2** (`s7_u105`, 1.05 ns) |
|---|---|---|
| LUTs after `opt_design` / routed | 114,386 / 111,918 (95.6%) | 114,386 / 112,071 (95.7%) |
| FFs routed, CLBs, control sets, DSPs | 57,822, 14,618, 2,854, 140 | 57,823, 14,632, 2,809, 140 |
| WNS after `phys_opt_design` (estimated, with the uncertainty on) | −0.964 ns | −0.287 ns |
| Routing | level 6, no trade, 1.3 h | level 5, no trade, 1.3 h |
| **WNS / TNS on the core clock (ns)** | −1.431 / −1,662.6 (3,302 failing) | **−0.561 / −296.2** (1,448 failing) |
| WHS (ns) | +0.006 | +0.005 |
| `clk2x`: within / into / back (ns) | +1.345 / +1.517 / +1.119 | +1.816 / +1.093 / +1.094 |
| Endpoints within 1 ns | 13,545 in 450 families | 11,233 in 441 families |

- **The pair's verdict: it doesn't close, so no bitstream was written.** The better placement misses 100 MHz by 0.561 ns. Against the near-final pair (+0.257 / −0.720), the better WNS is 0.82 ns worse. The second placement is better than the near-final pair's second (TNS −296 against −502).
- **Step 7's area in the chip.** The release candidate's netlist differs from this one by step 7 alone. Against it, step 7 adds:
  - +825 LUTs after synthesis, +746 after `opt_design` and +559 routed, for both cores;
  - about 373 a core after `opt_design`, against 161 out of context.
- **A new family, from step 7's logic: rename's DS register into decode's stall.** In core 0, `ds_ren_q`'s `q` and `has_q` reach:
  - the clock enables of decode's redirect registers (`dred_pc`, `dred_rlink`, `dred_ftq`, `dred_rop`, `dred_slot`, `dred_tid`);
  - fetch's `qs_q`.

  Its slack and its cause:
  - **Slack:** 31–32 levels, 56–57% wire, at −0.807 ns (u100) and −0.561 ns (u105's worst endpoint). In neither near-final placement is any path from `ds_ren_q` within 1 ns.
  - **Depth, not placement.** The worst path's 31 LUTs stay in one cluster (u105: SLICE_X13–18, Y53–62). It is 4.32 ns of logic and 5.79 ns of wire, about 0.19 ns a net. A third placement is unlikely to clear it alone.
    - Only its last net leaves the cluster: decode's clock-enable tree, fanout 113, 1.34 ns to the endpoint at SLICE_X32Y49.
    - Both placements route the same cells, level for level ([`path_table_ds.txt`](../../fpga/spikes/results/product_wt3_s7_u105/path_table_ds.txt), with `report_timing -input_pins` in `report_timing_ds.txt`, in both result folders).
    - The chain's other high-fanout nets: the first LUT's output (fanout 11), level 26 (201, likely `rn_fire`), `de_take` (25) and decode's tree (112).
  - **Where the logic is.** 29 of its 31 LUTs are under `u_rn`; their names are smeared by flatten rebuilt. The last two are decode's.
  - **The likely chain**, from the RTL (core-2 and fpu-2 own the check):
    - the DS group's rows in each queue: step 7's `dk`/`dn`, besides STEER_LA's `st_free`;
    - the caps: `cap_ok` indexed by `dn`, and `bank_ok`;
    - the greedy ALU queue choice with its per-queue counts;
    - `caps_ok`, then `rn_fire`, then decode's enable.
  - **The path's net names agree.** They are kept where the cells' are not. In order:
    - `ds_ren[0][has_q]`;
    - a net of `rwo_q[1]`'s input cone (step 7's `rwo`, from the caps);
    - the inputs of `ds_ren_q`'s `q` and `sq` (the steering);
    - the free lists' `head_q`, a map table's and `ltail_q`'s inputs (rename's fire);
    - decode's `de_take`, then two of decode's LUTs into `dred_pc`'s CE.
- **The other families are the near-final chip's, moved by the placement:**
  - **u100's worst:** core 1's fetch queue read, through decode, into rename's RN register (`rn_u_q`, `pay_wd_q`) from `head_t_q`. It is 18–19 levels at −1.43 ns with 73–75% wire. The near-final placement 1 has the same depth at +0.34 to +0.69. The path's cells are fetch's queue LUTRAM, decode and the RN register's input; none of step 7's logic is in it ([`path_rename.txt`](../../fpga/spikes/results/product_wt3_s7_u100/path_rename.txt)).
  - **Core 0's LSU state, from `sv39_l_q`:** through the walker and the shared PMP checker (`u_csr/g_pg`), 27 levels at −1.42 ns in u100 ([`path_lsu.txt`](../../fpga/spikes/results/product_wt3_s7_u100/path_lsu.txt)). In u105 the LSU state comes from `priv_dl_q` and `lq_pck_q`, at −0.53.
  - **u105's others:**
    - core 0's `pay_wd_q` from `head_t_q` (−0.559, as deep as the DS family's worst);
    - the decode family from the issue queues' `dep_q` (core 1's `dred_pc`, −0.558);
    - the L2's responses into the I$ valid bits and fetch's `fpc_q` (−0.55);
    - the free list's `count_q` from the ROB head (−0.54).
- **The floorplan is OK:** l2b0 100%/76%, **L2 bank 1 103%/80%**, xbar 33%/28% (before `opt_design` / its own LUTs after placement; warn above 105/85%). Against the near-final pair, L2 bank 1's own share after placement moves from 79% to 80%, and before `opt_design` it is unchanged.
- **The board image stays the near-final one.** That is the release candidate's, and so main's before step 7.
- **What would close step 7:**
  1. Take the DS family out of rename's fire. One direction: tg_issue counts the DS group's rows into the flags it registers, so the caps come from registers alone.
  2. Then one more pair: the rest is the near-final chip's spread, in which one of two placements closed. In u105, without the DS family, the worst is −0.559 ns, all from those families.

Results: `fpga/spikes/results/product_wt3_s7_u100/` and `product_wt3_s7_u105/`. The DS family's worst path is u105's [`path_ds.txt`](../../fpga/spikes/results/product_wt3_s7_u105/path_ds.txt). The routed checkpoints are in `~/tanager-build/track-spikes-72f833/vivado/product_wt3_s7_u100/` and `_u105/`.

#### fpu-2's cut of the DS family: the family is gone, −0.422 ns overall (2026-10-23)

**Asked** (the coordinator, 10-23): "run one placement now at 1.05 ns on fpu-2's cut", with soc-2's ckm (1cff68aa, the `priv_dl_q` fix) and without core-2's marg branches. "Report the ds_ren_q family first, then the families worse than −0.5 ns as usual."
- **The cut, as built:** fpu-2's newer head 6fb83dcf, at fpu-2's request; the b3c78865 job was stopped in the queue before Vivado started. It is b3c78865 plus core-2's suggestion:
  - `cap_ok` is constant with the cap at 100%;
  - DS's queues are a registered one-hot (`ds_qoh_q`);
  - the bank rule's sibling need reads a class-to-queue mask registered beside the RN group (`rn_need_q`).
- **Snapshot:** `snap/product_wt` 06830a4861a8, which is main 1fbc0685, 6fb83dcf, 1cff68aa and the measurement commit, pinned by `claude/spikes-2-board-s7d`. Against the step-7 build only `tg_rename` and `tg_lsu` differ.

| | `s7d_u105` (1.05 ns) | for comparison: `s7_u105` |
|---|---|---|
| LUTs after synthesis / `opt_design` / routed | 118,148 / 114,325 / 112,019 (95.6%) | 118,494 / 114,386 / 112,071 |
| FFs routed, CLBs, control sets, DSPs | 57,908, 14,640 (all), 2,929, 140 | 57,823, 14,632, 2,809, 140 |
| WNS / TNS after `phys_opt_design` (estimated, with the uncertainty on) | **+0.006 / 0.000** | −0.287 / −79.1 |
| Routing | level 6, no trade, 1.0 h | level 5, no trade, 1.3 h |
| **WNS / TNS on the core clock (ns)** | **−0.422 / −73.1** (490 failing) | −0.561 / −296.2 (1,448 failing) |
| WHS (ns) | +0.008 | +0.005 |
| `clk2x`: within / into / back (ns) | +2.035 / +1.167 / +1.131 | +1.816 / +1.093 / +1.094 |
| Endpoints within 1 ns | 6,651 in 281 families | 11,233 in 441 families |

- **The DS family is gone.** The worst path from `ds_ren_q` is now +1.732 ns at 17 levels, into decode's `dred_rlink` CE. Before the cut it was −0.561 at 31 levels and −0.807 at 32.
- **The cut's new registers are clear as starts.**
  - `ds_qoh_q`: +1.090 ns (23 levels, into core 1's `rt_b_q`), and +1.48 into decode's `dred_*`.
  - `rn_need_q`: +1.085 (the same endpoint), and +1.42 into `dred_*`.
  - So the next cut fpu-2 named, `sib_need` into `bank_ok`, isn't needed.
- **`rn_need_q`'s own input is near the top.** Its D input is −0.416 (core 1, from fetch's `rt_b_q`, 20 levels, 70 endpoints) and −0.408 (core 0, from `head_t_q`, 21). That is the fetch queue's path through decode into the RN register, beside `rn_u_q` (−0.367) and `pay_wd_q` (−0.266).
- **No family is worse than −0.5 ns.** The worst:
  - core 1's fetch `rt_b_q` and `rt_q` from rename's free list `count_q`: −0.422 and −0.413, 26 levels. It is the worst rename start into fetch; into decode's `dred_*` the worst rename start is +0.129;
  - the `rn_need_q` inputs above;
  - core 0's decode `dred_*` from the issue queues' `dep_q`: −0.40 to −0.36, 23 levels;
  - the LSU's `lq_st_q`: core 0 from `lq_pck_q` −0.361, core 1 from `priv_dl_q` −0.356.
- **soc-2's `priv_dl_q` family keeps its depth.** It is core 1's `priv_dl_q` into `lq_st_q`'s CE: 25 levels, 314 endpoints, against 25 levels at −0.535 in the step-7 build. Both builds trace the same chain ([`path_table_priv.txt`](../../fpga/spikes/results/product_wt_s7d_u105/path_table_priv.txt), and the step-7 build's in `product_wt3_s7_u105/`):
  1. `priv_dl_q`;
  2. the walker's `g_plk.plk_q` net;
  3. the checker's `pfc_x_q` match and the store checker `g_ckf.u_pmp_st`'s two CARRY8s;
  4. `pfc_ok_q`'s cone;
  5. `sa_chk[0]`, then a 128-fanout net, into `lq_st_q`'s CE.
- **The router lost the margin.** With the uncertainty on, the placement estimated +0.006 ns and TNS 0; routing at congestion level 6 ended 1.47 ns lower.
  - The step-7 pair lost 1.47 ns (u100, level 6) and 1.32 ns (u105, level 5).
  - The near-final pair lost 0 (u100, level 5) and 1.13 ns (u105).
  - At 95.6% of the LUTs and every CLB used, the router's detours are now most of the spread.
- **The floorplan is OK:** l2b0 100%/78%, **L2 bank 1 102%/79%**, xbar 36%/31%.

Results: `fpga/spikes/results/product_wt_s7d_u105/` holds the reports and the families. It also has `report_timing_*.txt` with their `path_table_*.txt`, from these starts:
- `ds` (`ds_ren_q`), `qoh` (`ds_qoh_q`) and `need` (`rn_need_q`) to anything;
- `toneed`, fetch into `rn_need_q`;
- `rnde`, rename into `dred_*`;
- `priv` (`priv_dl_q`).

The routed checkpoint is `~/tanager-build/track-spikes-72f833/vivado/product_wt_s7d_u105/routed.dcp`.

#### The near-final release with step 7 closes 100 MHz in both placements (2026-10-23)

**Asked** (the coordinator, 10-23): "Go for a pair now ... the near-final release with step 7, every fix and the memory-ordering fix". The product form, `AltSpreadLogic_high`, 1.0 and 1.05 ns, and a passing placement's bitstream. "Report: the usual, plus whether any family starts or ends in the CoRR marking logic, and LUT and FF totals against s7d."
- **Snapshot:** `snap/product_wt3` 9dbbad723e3f, pinned by `claude/spikes-2-board-rc2`. It is main 28d28d8a plus:
  - fpu-2's step-7 cut f1d79a86 (b3c78865, 6fb83dcf, and 2557cb00, which takes `rn_need_q` back out);
  - soc-2's ckm2 02da289b (the store's checker request from a register, and the head's MMIO request without `lq_pck_q`);
  - core-2's marg3 813b6743 (core-2 confirmed the head);
  - core-2's CoRR snoop marking b51bbbf6;
  - the measurement commit.
- **Checks before launch:** the four merges are clean, Verilator lint passes in the product's view (smt2, hart 1, release, URF, with and without SYNTH), and fwdref is clean.
- **Not in it:** core-2's FENCE.I sweep fix (icsweep 379ca1ef, `tg_fetch` only). It merges cleanly on the snapshot and goes through its own MR.
- **Run order:** at the 50 GB budget (`.locks/vivado.budget` since 04:31) two 26 GB builds don't fit together, so the 1.0 ns placement runs after the 1.05 ns one.

| | **`rc2_u100` (1.0 ns)** | `rc2_u105` (1.05 ns) | for comparison: `s7d_u105` |
|---|---|---|---|
| LUTs after synthesis / `opt_design` / routed | 119,066 / 114,885 / 112,360 (95.9%) | 119,066 / 114,885 / 112,315 (95.9%) | 118,148 / 114,325 / 112,019 |
| FFs routed, CLBs, control sets, DSPs | 57,976, 14,638, 2,836, 140 | 57,981, 14,639, 2,872, 140 | 57,908, 14,640, 2,929, 140 |
| WNS after placement (estimated, with the uncertainty on) | +0.412 ns | +0.464 ns | +0.006 (after `phys_opt_design`) |
| Routing | level 6, no trade, 1.3 h | level 5, no trade, 1.4 h | level 6, no trade, 1.0 h |
| **WNS / TNS on the core clock (ns)** | **+0.296 / 0.000** (0 failing) | **+0.188 / 0.000** (0 failing) | −0.422 / −73.1 (490 failing) |
| WHS (ns) | +0.010 | +0.011 | +0.008 |
| `clk2x`: within / into / back (ns) | +2.001 / +1.062 / +1.049 | +1.820 / +1.088 / +1.079 | +2.035 / +1.167 / +1.131 |
| Endpoints within 1 ns | 2,332 in 194 families | 2,552 in 164 families | 6,651 in 281 families |

- **Both placements close 100 MHz; the better WNS is +0.296 ns (1.0 ns), TNS 0 in both.**
  - It is the first product chip with step 7 to close, and the first with the memory-ordering fix.
  - It is also the first pair whose placements both pass: the near-final pair without step 7 closed in one of two.
  - Placement estimated +0.41 and +0.46 with the uncertainty on, so `phys_opt_design` had nothing to do. Routing cost 1.12 and 1.33 ns.
- **No CoRR family is near-critical** in either placement (u100 / u105). The worst paths that start or end in the marking logic:
  - into the event capture (`ev1_l_q`, `ev1_tm_q`): +0.699 / +0.718 ns, 13–15 levels, from the store queue head's `sqh_q.pa`;
  - from the report registers `snp_v_q` and `snp_lq_q`: +1.366 / +1.380, 15–16 levels;
  - into them, the oldest select from `lq_snp_q`: +1.534 / +2.203;
  - into `lq_snp_q` (the E+2 compare): +1.947 / +1.953;
  - from `ev1_*`/`ev2_*`: +2.691 / +3.894.
- **Area against s7d:** +918 LUTs after synthesis, +560 after `opt_design`, +296 routed, +73 FFs. This combines the CoRR marking (core-2: about 300 LUTs a core), marg3, ckm2 and fpu-2's revert of `rn_need_q`. One pair can't split it.
- **The worst families, all met.** In u100:
  - the LSU's `fh_data_q` and `fh_w_q` from the store's `sn_v_q` (+0.296);
  - `s2_v_q` and `sq_av_q` from `sn_t_q` (+0.30);
  - fetch's `rt_b_q` from `dep_q` (+0.307);
  - `lq_st_q` from the walker's `chk_req_q` (+0.322).

  In u105:
  - core 1's fetch `rt_b_q` from the issue queues' `dep_q` (+0.188, 21 levels);
  - core 1's `lq_st_q` from the checker's `pfc_rsp_v_q` (+0.218);
  - core 1's D$ valid and meta RAMs from `sqh_q` and the miss entry (+0.23, +0.25);
  - rename's RN register from `dep_q` (+0.25);
  - `m2_dword_q` from the DTLB's CAM (+0.25).
- **The floorplan is OK** in both: l2b0 99%/75%, **L2 bank 1 102%/79%**, xbar 30%/24%.
- **The board images** were written from both checkpoints by `build.tcl`'s bitstream stage (`run_bit_now.sh`, each as its placement ended). `timing_bit.rpt` says "All user specified timing constraints are met" in both.
  - **u100, the board image:** `tanager.bit` md5 069905fb…, `tanager.bit.bin` md5 1cb29cf7….
  - **u105, the fallback:** `tanager.bit` md5 db175ba8…, `tanager.bit.bin` md5 6bfcffca….
  - Both went to soc-2.
  - They are previews: of the four branches only f1d79a86 and 02da289b are on main so far (d9d700ec).

Results: `fpga/spikes/results/product_wt3_rc2_u100/` and `product_wt3_rc2_u105/`. The CoRR queries are in `report_timing_corr_*.txt`:
- `snpf`/`snpt`: from and into `lq_snp_q`;
- `srf`/`srt`: the report registers;
- `evf`/`evt`: the event registers.

The images and checkpoints are in `~/tanager-build/track-spikes-72f833/vivado/product_wt3_rc2_u100/` and `_u105/`.

#### The release pair on coord/rc3: neither placement closes; congestion and the router's trade (2026-10-23)

**Asked** (the coordinator, 10-23): "go for the release pair, on ref coord/rc3 = 234fc366": main 490a7e27 (no RTL since d9d700ec) with core-2's three MRs merged (marg3 763c5170, icsweep 679ceb2c, CoRR b095eca3), the tree main will have. The same product form and flow as rc2, in a new snapshot folder.
- **Snapshot:** `snap/product_wt4` 64fa49e9b982, pinned by `claude/spikes-2-board-rc3`; `coord/rc3` and the measurement commit. Lint in the product's view and fwdref are clean.
- **The RTL against rc2's:** two changes, the FENCE.I sweep's gate on fetch's refill start (`tg_fetch`, 8 lines) and CoRR's `lq_io_q` (b30b57b3: a device load is never marked, a register per LQ entry; `tg_lsu`, 5 lines).

| | `rc3_u100` (1.0 ns) | `rc3_u105` (1.05 ns) | for comparison: `rc2_u100` / `rc2_u105` |
|---|---|---|---|
| LUTs after synthesis / `opt_design` / routed | 119,477 / 115,333 / 112,762 (96.3%) | 119,477 / 115,333 / 112,773 (96.3%) | 119,066 / 114,885 / 112,360 and 112,315 |
| FFs routed, CLBs, control sets | 58,034, 14,638, 2,867 | 58,050, 14,639, 2,851 | 57,976 / 57,981 |
| WNS estimated in placement, at its start / after `phys_opt_design` (uncertainty on) | −1.631 / −0.270 | −1.201 / **0.000** | −0.482 / +0.412 and −1.055 / +0.464 |
| Routing | level 6, **the router trades timing for routability** (Route 35-447), 1.8 h | the same, 1.8 h | level 6 and 5, no trade |
| **WNS / TNS on the core clock (ns)** | −1.104 / −893.6 (2,608 failing) | −0.959 / −421.9 (1,502 failing) | +0.296 / 0 and +0.188 / 0 |
| WHS (ns) | +0.002 | +0.010 | +0.010 / +0.011 |
| `clk2x`: within / into / back (ns) | +1.630 / +0.572 / +0.943 | +2.297 / +1.096 / +0.923 | |
| Endpoints within 1 ns | 11,007 in 475 families | 11,305 in 457 families | 2,332 and 2,552 |

- **Both placements fail, and both hit the router's congestion trade.**
  - u105 left placement at 0.000 ns with the 1.05 ns uncertainty on, which would be +1.05 after the takeback.
  - At congestion level 6, the router then put "the successful completion of routing all nets over timing optimizations" and lost 2.0 ns (u100: 1.8 ns). rc2's routing traded nothing.
- **Why rc3 places worse: synthesis re-rolled the netlist.**
  - The two changes are about a dozen lines, but synthesis gives +411 LUTs and +47 FFs ([`hier_diff_synth_vs_rc2.txt`](../../fpga/spikes/results/product_wt4_rc3_u100/hier_diff_synth_vs_rc2.txt)), spread over the chip:
    - fetch +335 a core, the LSU +223 / +264 (the walker +97 / +157);
    - decode −137, ex −115, a RAS −70, the ROB −60;
    - the uncore +52 with no RTL change.
  - After routing, the L2 is +175, of which bank 0 is +130 ([`hier_diff_routed_vs_rc2.txt`](../../fpga/spikes/results/product_wt4_rc3_u100/hier_diff_routed_vs_rc2.txt)).
  - With `flatten_hierarchy rebuilt` and AreaOptimized_high, a small change moves logic everywhere. At 96.3% of the LUTs, with every CLB used, that is enough to tip the router into its trade.
  - L2 bank 1 is now 104% before `opt_design`, against the 105% warning.
- **Neither change is on a failing path (u100):**
  - into `lq_io_q` +1.302, from it +5.971;
  - from the sweep's `ivs_q` +1.890 and `gpend_q` +1.980; into them +6.91 / +3.64;
  - the I$ valid family runs through `refill_done` and the valid RAM's read-modify-write, with none of the gate's nets.
  - CoRR's event capture is the closest new logic, at +0.105 (into `ev1_tm_q`, mostly wire).
- **The failing families are the recurring ones, moved by the placement:** the LSU's state and data, the walker's `chk_pa_q`, the I$ valid RAM and TAGE (below), plus the D$ data RAM from `lq_st_q` (u105: −0.782, 8 levels, 86% wire).

**The recurring families** (the coordinator: "so closure stops being a lottery"). Their worst slack in the last six placements:

| Family | fin1 u100 | s7d u105 | rc2 u100 | rc2 u105 | rc3 u100 | rc3 u105 |
|---|---|---|---|---|---|---|
| (WNS) | +0.257 | −0.422 | +0.296 | +0.188 | −1.104 | −0.959 |
| the LSU state `lq_st_q` | +0.274 | −0.361 | +0.322 | +0.218 | −1.080 | −0.959 |
| `m2_foh_q` | +0.324 | +0.147 | +0.344 | +0.363 | −1.096 | −0.773 |
| the load data `r_data_q` | +0.267 | +0.188 | +0.529 | +0.925 | −1.066 | −0.954 |
| the walker's `chk_pa_q` | +0.585 | +0.223 | +0.801 | +0.411 | −1.104 | −0.696 |
| the I$ valid RAM | +0.261 | −0.248 | +0.349 | +0.420 | −1.086 | −0.746 |
| TAGE's tables | +0.761 | > +1.0 | > +1.0 | > +1.0 | −0.998 | +0.552 |

Each family runs 16–26 levels with 62–75% of its delay in wire, so the placement decides it. Their chains are in rc3_u100's [`path_table_family_*.txt`](../../fpga/spikes/results/product_wt4_rc3_u100/), traced with net names because the cells' are smeared.
1. **The LSU state and load data** (`lq_st_q`, `r_data_q`, `lx_valid_q`; 19–24 levels). The chain:
   - the split store pipe's valid (`sn_v_q`, `sn_pck_q`) and the AMO FSM;
   - the shared PMP checker's request select, with a 780-fanout operand-select net;
   - the operand muxes and the two CARRY8 compares (`g_ckf.u_pmp_st`), then `pfc_ok` and `sa_chk`;
   - `m2_rck_q`'s cone (fanout 89), into the LQ entries' state CE and the load result.

   **Fix:** register the checker's verdict and update the LQ state and the load result a cycle later for checked accesses. That cuts every family at `sa_chk`. Registering and replicating the select would also help. **Owner:** soc-2 (DR-183's checker), with core-2 for the LSU side. **Effort:** about a day with checks. It is not cycle-identical, so DR-183's boot-cost bar applies.
2. **`m2_foh_q`** (16–21 levels). The chain: the store's thread `sn_t_q`, the DTLB leaf LUTRAM's read address, the leaf data, the forward-hit compare (`m2_fhit`), then `m2_foh_q`.

   **Fix:** the leaf read address from registers, as core-2 did for the walker's DTLB port. **Owner:** core-2. **Effort:** half a day; cycle-identical by construction if the select is known a cycle ahead.
3. **The walker's `chk_pa_q`** (18–20 levels). The chain: the DTLB CAM's valid bits `v_q`, the match (`g_early.mq`), the hit's leaf LUTRAM read, then the walker's address mux into `chk_pa_q`.

   **Fix:** load `chk_pa_q` from a registered DTLB result. That costs a cycle on a PTE read's PMP check, which is rare. **Owner:** soc-2 (DR-183's walker check), with core-2. **Effort:** half a day.
4. **The I$ valid RAM** (20–26 levels). The chain: the L2's response (`d_idx`, `dh_out`), `refill_done`, the valid RAM's read address, the RAMD64E read, the way and valid merge (8–10 LUTs), into the valid RAM's write data: a read-modify-write in one cycle.

   **Fix:** register `refill_done`, or keep the set's valid bits from the refill's start so the write doesn't depend on a read in the same cycle. **Owner:** core-2. **Effort:** about a day; the sweep's new assert helps check it.
5. **TAGE's tables** (13–14 levels). The chain is the BRAM read, the update, then the BRAM write. It fails only in a congested placement.

   **Fix:** register the read data before the update. **Owner:** fpu-2. **Effort:** half a day; lowest priority.
- **The order:** 1 (the most endpoints, and within 0.4 ns in every placement), 4, 2 and 3, then 5. Fixing 1 to 4 would bring the bad placements' worst to about −0.1 ns, and the good ones' to about +1 ns.

**The trials,** each one placement at a time (the coordinator: two at once, the budget raised while they ran). They run from `snap/product_wt2` a1589f00712c (pinned by `claude/spikes-2-board-rc3t`) and `snap/product_wt` 9b620a0da139 (pinned by `claude/spikes-2-board-rc3t2`). Both are `coord/rc3` and the measurement commit, plus knobs for `phys_opt_design`'s and `route_design`'s directives and for incremental implementation; unset, the flow is main's.

| Trial | What | Result |
|---|---|---|
| `rc3i_u100` | incremental from rc2_u100's routed checkpoint, `TimingClosure`, 1.0 ns | stopped in `read_checkpoint`: reuse 86.1% of the cells (89.3% matched by name), 49.4% of the nets, 58.2% of the pins; then 2025.2's "Not able to open pb file" (Common 17-1999, an empty name) fails the command |
| `rc3j_u100` | the same, ignoring the uncertainty (`incr.ignoreUserClockUncertainty`) and going on past the pb error | the reuse data loads and the incremental placer starts, then "could not place more than 5 percent of the moveable instances" (Place 46-13): with 86% of the cells at rc2's sites there is no room at 96% for the rest |
| `rc3_u110` | a fresh placement at 1.10 ns | −0.237 / −21.2 (228 failing), WHS +0.010; no trade at level 6; the recurring families 0.1–0.24 ns short |
| `rc3pro_u110` | `rc3_u110` routed, then `phys_opt_design -directive AggressiveExplore` and `route_design` | −0.237 to −0.224 after phys_opt, then −1.677 / −641 after the reroute; stopped once `rc3_u095r` closed |
| **`rc3_u095r`** | **a fresh placement at 0.95 ns with `route_design -directive AlternateCLBRouting`** | **+0.748 / 0.000, 0 failing, WHS +0.006** |

**The M8 release image of record: `rc3_u095r`** (the coordinator, 10-23: coord/rc3's RTL, which is main's).

| | `rc3_u095r` |
|---|---|
| LUTs after synthesis / `opt_design` / routed | 119,477 / 115,333 / 112,806 (96.32%) |
| FFs routed, CLBs, control sets | 58,024, 14,640 (all), 2,887 |
| WNS estimated in placement, at its start / after placement (0.95 ns on) | −1.715 / +0.088 |
| Routing | **level 5** with `AlternateCLBRouting`, no trade, 1.6 h (the default router was at level 6 in all three other rc3 placements, and traded in two) |
| **WNS / TNS / WHS (ns)** | **+0.748 / 0.000 / +0.006**; `clk2x` within / into / back +1.725 / +0.995 / +0.794 |
| Endpoints within 1 ns | 668 in 73 families, the worst +0.748 (core 0's `lx_valid_q` from the store pipe's `sn_v_q`), then `m2_dword_q`, `sqh_q`, `lq_st_q`, `m2_foh_q`, `dred_pc` and the I$ valid RAM, all +0.75 to +0.78 |

- **The image:** `tanager.bit` sha256 baf853d9…, `tanager.bit.bin` sha256 2a47608a…, sent to soc-2 and the coordinator.
- **Reproducing it:** main's `build.tcl` now takes `TG_PHYS_DIRECTIVE` and `TG_ROUTE_DIRECTIVE`, plus `TG_INCR_DCP` / `TG_INCR_DIRECTIVE`, off unless set (`fpga/kv260/README.md`). With `TG_ROUTE_DIRECTIVE=AlternateCLBRouting TG_PR_UNC=0.95` and the product's other settings, main reproduces this flow; defaults are unchanged.
- **The lesson:** at 96% of the LUTs the router's congestion handling decides the chip.
  - `AlternateCLBRouting` turned the netlist that missed by 0.24–1.1 ns in three placements into +0.748.
  - Recovery after routing (incremental implementation, post-route `phys_opt_design`) has no room to work at this fill.
  - The recurring families above still decide the margin, so their fixes stay the way to stop the lottery.

Results: `fpga/spikes/results/product_wt4_rc3_u100/` (with the comparisons and the family chains) and `product_wt4_rc3_u105/`. The checkpoints are in `~/tanager-build/track-spikes-72f833/vivado/product_wt4_rc3_u100/` and `_u105/`.

#### The recurring families: the fixes, before M9's RTL (2026-10-23)

**Asked** (the coordinator, 10-23): the family-fix table across the last placements, with a structural fix, an owner and an effort for each recurring family. The reason: "closure took five tries for a dozen RTL lines, and M9 will change more"; each M9 change re-rolls closure, so the fixes come first where they can.

| Family | fin1 u100 | s7d u105 | rc2 u100 | rc2 u105 | rc3 u100 | rc3 u105 | rc3 u110 | **rc3 u095r** | levels, wire |
|---|---|---|---|---|---|---|---|---|---|
| (WNS) | +0.257 | −0.422 | +0.296 | +0.188 | −1.104 | −0.959 | −0.237 | **+0.748** | |
| the LSU state `lq_st_q` | +0.274 | −0.361 | +0.322 | +0.218 | −1.080 | −0.959 | −0.222 | +0.756 | 19–25, 64–74% |
| `m2_foh_q` | +0.324 | +0.147 | +0.344 | +0.363 | −1.096 | −0.773 | −0.208 | +0.757 | 16–22, 66–75% |
| the load data `r_data_q` | +0.267 | +0.188 | +0.529 | +0.925 | −1.066 | −0.954 | −0.016 | +1.000 | 18–24, 67–74% |
| the walker's `chk_pa_q` | +0.585 | +0.223 | +0.801 | +0.411 | −1.104 | −0.696 | −0.144 | +0.811 | 17–20, 68–76% |
| the I$ valid RAM | +0.261 | −0.248 | +0.349 | +0.420 | −1.086 | −0.746 | −0.237 | +0.773 | 20–26, 62–70% |
| TAGE's tables | +0.761 | > +1.0 | > +1.0 | > +1.0 | −0.998 | +0.552 | +0.540 | +0.893 | 12–14, 57–66% |

Every family sits 16–26 levels deep with two thirds of its delay in wire. At this fill a placement moves each by up to 2 ns, so a good placement passes them all and a congested one fails them all together. Cutting their depth is what stops the lottery.

The chains below are rc3_u100's, by net name, in `fpga/spikes/results/product_wt4_rc3_u100/path_table_family_*.txt` and `report_timing_new_ival.txt`.

| # | Family | Where the chain runs | Structural fix | Owner | Effort |
|---|---|---|---|---|---|
| 1 | the LSU state `lq_st_q`, the load data `r_data_q`, `lx_valid_q` (the store pipe into the shared PMP checker) | `sn_v_q` / `sn_pck_q` and the AMO FSM, 3–5 LUTs of request and select (a 780-fanout operand-select net), the operand mux, the compare (a LUT and two CARRY8s in `g_ckf.u_pmp_st`), `pfc_ok` (5 LUTs), **`sa_chk` at level 15–16 of 21**, then `m2_rck_q`'s cone (fanout 89) and 4–5 LUTs into the LQ entries' CE or the load result | a verdict register: `sa_chk` (each requester's result) registered, with the LQ state update and the load result a cycle later for checked accesses. That leaves about 15 levels ending at a register and 6 starting from one. Cheaper, cycle-identical but smaller: replicate the 780-fanout operand select | soc-2 (DR-183's checker), with core-2 for the LQ side | about a day with the checks; not cycle-identical, so DR-183's boot-cost bar applies |
| 2 | `m2_foh_q` (M2's forward hit) | the store pipe's `sn_t_q`, 5 LUTs into the DTLB leaf LUTRAM's read address (fanout 36), the RAMD32, 8 LUTs of the leaf's compare, `m2_fhit` (4 LUTs), then `m2_foh_q`: 21 levels | the leaf read address from registers: the port's owner decided a stage ahead, as for the walker's DTLB port. About 5 levels off | core-2 | half a day; cycle-identical if the owner is known a cycle ahead |
| 3 | the walker's `chk_pa_q` | the DTLB's valid bits `v_q`, the CAM match (a LUT6 and a MUXF7), 5 LUTs of hit encode, the leaf LUTRAM read (fanout 12), 8 LUTs, then the walker's VA/PA mux into `chk_pa_q`: 19 levels | the DTLB result registered before the walker's PMP check: a cycle more on a PTE read's check, cut at the LUTRAM's output (about 9 levels each side) | soc-2 (DR-183's walker check), with core-2 | half a day |
| 4 | the I$ valid RAM (the L2's response into fetch) | the L2's `d_idx` / `dh_out`, `refill_done`, 3 LUTs into the valid RAM's read address (fanout 10), the RAMD64E read, 10 LUTs of way and valid merge (`pway_q`), then the valid RAM's write data: a read-modify-write in one cycle, 24 levels | `refill_done` registered (the valid write a cycle later, the line invalid until then), or the set's valid bits read at the refill's start so the write needs no read in the same cycle. About 6–10 levels off | core-2 | about a day; the FENCE.I sweep's new assert checks the valid RAM's writes |
| 5 | TAGE's tables | the BRAM read, the update, then the BRAM write: 12–14 levels; it fails only in a congested placement | the read data registered before the update (the update a cycle later, with a bypass for back-to-back updates of an entry) | fpu-2 | half a day; lowest priority |

- **The order:** 1 (the most endpoints, and the worst or near it in every placement), 4, 2 and 3 (both in the LSU's DTLB, and they could share a review), then 5.
- **What it buys:** each fix takes 5–10 levels, 1.5–3 ns, off its family.
  - With 1–4 in, the families that failed rc3_u100 by 1.1 ns would sit at about +0.5 or better in a placement like it.
  - The next families down would be the margin's limit: decode's `dred_*` from the issue queues' `dep_q`, rename's RN register from `head_t_q`, the D$ RAMs and `sqh_q`, all 0.1–0.4 ns behind these in every placement.
- **The flow stays as the release image's:** `TG_ROUTE_DIRECTIVE=AlternateCLBRouting` at `TG_PR_UNC=0.95` for product builds. It lowered the congestion from level 6 to 5 on the same netlist.
- **Checking a fix:** a fix can be checked first on the release image's checkpoint, for the levels and slack of its own family, by a path query on a fresh build of the fix alone. A pair on main follows once several land.

#### DR-191's fixes, checked out of context one by one (2026-10-24)

**Asked** (the coordinator, 10-23): until the fixes land, per-fix out-of-context timing checks: each family's paths before and after, each fix against one baseline, as its branch is ready.

- **The flow.** `run_fix_ooc.sh`, with [`ooc_run.tcl`](../../fpga/spikes/tcl/ooc_run.tcl) and [`paths_dr191.tcl`](../../fpga/spikes/tcl/paths_dr191.tcl):
  - the product core alone: `tg_core`, smt2, `TG_HART1=1 TG_COMMIT_TRACE=0`, AreaOptimized_high, flatten rebuilt, the URF off;
  - synthesised, placed and routed at 100 MHz in clock regions X0Y1:X2Y3 (about 88K LUTs for a 52K-LUT core), with the release image's `AltSpreadLogic_high` and `AlternateCLBRouting`;
  - 14 GB and 25 minutes a run.
- **The baseline:** main b30594fe (`ooc/fix_base_b30594fe`), WNS +0.550, 51,904 LUTs. The families:
  - `lq_st_q` +0.550 (18 levels), and +0.859 from the store pipe's `sn_*`;
  - `lx_valid_q` +0.603 (18), `m2_foh_q` +0.729 (17), `r_data_q` +1.542 (15);
  - the walker's `chk_pa_q` +0.774 (16), and +0.901 through the DTLB (15);
  - the I$ valid RAM +1.176 (22), TAGE +2.203 (13).
  - A core alone has more room than in the chip, where the same families are 16–26 levels and 0.5–1.5 ns lower. So read the changes, not the values.
- **Each fix** is built on the baseline's commit:
  - fix 3 and fix 5 are their branches, which sit on b30594fe;
  - fix 4 is its own two commits cherry-picked there, because its branch's base carries M9's RTL.

| Fix | The family it targets: slack, levels, logic | Other effects | LUTs / FFs |
|---|---|---|---|
| **3**, core-2's `tlbreg2` 851dfc81 (the DTLB's EARLY ports register their masked match, leaf index and hit) | **`m2_foh_q` +0.729 → +1.703, 17 → 13 levels**; the worst now starts at the new `g_early.mi_q` | `chk_pa_q` through the DTLB +0.901 → +1.643 | −684 / −26 |
| **4**, soc-2's `ptwreg` (7862c586, b4e0029a: the head's deciding walk from a register, #12 `LSU_HDWALK_REG`) | **`chk_pa_q` +0.774 → +2.349, 16 → 14 levels**; no path from the DTLB reaches it any more (the start is now the ROB's `ct_q`) | | −278 / +29 |
| **5**, fpu-2's `tageflat` f6865c1e (TAGE's training update in one-hot terms) | **TAGE +2.203 → +3.415, logic 3.20 → 1.79 ns**; the worst now starts at fetch's `f3_start_q`, not the BRAM read | | −364 / 0 |

- **All three take their own family well clear,** by +0.97, +1.58 and +1.21 ns.
- **The noise is about ±0.5 ns:** the families a fix doesn't touch move by up to 0.5 ns and 4 levels between runs, because synthesis re-rolls the netlist. Fix 5 changes only TAGE, yet its run moved `lq_st_q` from +0.550 to +0.062 (18 to 22 levels) and the I$ valid RAM from +1.176 to +0.681. A target gain under about 0.5 ns needs two runs to read.

Results: [`fpga/spikes/results/ooc_dr191/`](../../fpga/spikes/results/ooc_dr191/) holds each run's summary, paths and per-family reports, and `compare.txt` (`fpga/spikes/scripts/ooc_compare.py`).

#### The pair of record with DR-191's fixes: both placements close (2026-10-24)

**Asked** (the coordinator, 10-24): "When all of the follow-up and fixes 2 and 3 are on main, start the full-chip pair of record on that main: product flow, 0.95 and 1.05 ns." It decides whether closure is still a lottery.
- **The source:** main f3311cdd, whose RTL is ca06e559's. That holds all five DR-191 fixes and fix 1's follow-up.
- **The start:** `wait_main_rec.sh` started the pair when the last of them landed, from snapshot `snap/product_wt` 576c5a22a617, pinned by `claude/spikes-2-board-rec`. Lint in the product's view and fwdref are clean.
- **The flow:** the product form, `AltSpreadLogic_high`, and main's `TG_ROUTE_DIRECTIVE=AlternateCLBRouting`.

| | `rec_u095` (0.95 ns) | **`rec_u105` (1.05 ns)** | for comparison: `rc3_u095r` (the M8 image) |
|---|---|---|---|
| LUTs after synthesis / `opt_design` / routed | 119,547 / 115,574 / 112,972 (96.5%) | 119,547 / 115,574 / 112,862 (96.4%) | 119,477 / 115,333 / 112,806 |
| FFs, control sets | 58,217, 2,841 | 58,210, 2,855 | 58,024, 2,887 |
| WNS after placement (estimated, uncertainty on) | +0.248 | +0.296 | +0.088 |
| Routing | level 6, **the router's trade**, 2.0 h | level 5, no trade, 0.7 h | level 5, no trade, 1.6 h |
| **WNS / TNS / WHS (ns)** | **+0.337 / 0 / +0.008** | **+1.066 / 0 / +0.010** | +0.748 / 0 / +0.006 |
| the core clock's WNS; `clk2x` within / into / back | +0.337; +1.130 / +1.043 / +0.736 | +1.157; +1.504 / +1.066 / +1.133 | +0.748 |
| Core-clock endpoints within 1 ns | 2,949 in 221 families | **none** | 668 in 73 families |

- **Both placements close 100 MHz, so closure is no longer a lottery.** rc3's netlist, with the same flow, missed in three placements out of four.
- **The congested placement still passes.** It took the router's trade at congestion level 6, which cost rc3 1.8–2.0 ns, and still ends at +0.337.
- **The clean placement has a full nanosecond spare:** +1.066 ns overall, +1.157 on the core clock, and no core-clock endpoint within 1 ns.
- **u095's worst families after its trade,** all met:
  - the DTLB's EARLY match register `g_early.mi_q` (fix 3's new register) from the CAM's `uf_q` and the walker's `va_q`: +0.337, 16–17 levels;
  - the RAS's push and pop, and `ka_q`, from the I$ data: +0.345, 21 levels;
  - the I$ valid RAM and `rv_q` from `miss_s_q`: +0.36;
  - the D$ valid RAM: +0.384;
  - `lq_st_q` from `sq_fp_q` and `fpc_q` from `f3_carry_q`: +0.388;
  - the ROB's `hw_q` from the CSR's `priv`: +0.399;
  - `rt_b_q` from the issue queues' `dep_q` and `m2_dword_q` from `mi_q`: +0.407.
- **None of DR-191's families sets the margin any more.** The next tier is the I$ data into F2's decision, the DTLB's CAM and the D$ RAMs.
- **The floorplan is OK:** L2 bank 1 102%/79% and 102%/78%.

**The images,** both written at once by `run_bit_runs.sh` (write_bit_from_dcp.tcl); `timing_bit.rpt` says "All user specified timing constraints are met" for both.

| | `tanager.bit.bin` sha256 | `tanager.bit` sha256 |
|---|---|---|
| **`rec_u105`, the next board image's candidate** | 2cad46c89b31e7f774954665457d55933ad49cb5cc38fcf7ab0ac505c2327a3a | bb91e30767589979cad539c2fa684d1f7af4503124852c9d05f3f16302f8656a |
| `rec_u095` | 91517e550f093d5dc2f1b9a72adf898946a70c28d7ce756f6fe52b9e07337142 | bbbd4cfbbaf428c5fb231668ec0ac1202b53c932050c61339c878bce14ddc648 |

Results: `fpga/spikes/results/product_wt_rec_u095/` and `_u105/`, with `images_sha256_md5.txt`. The images and checkpoints are in `~/tanager-build/track-spikes-72f833/vivado/product_wt_rec_u095/` and `_u105/`, both on `KEEP.txt`.

#### M9's area package doesn't place: 92 CLBs short (2026-10-24)

**Asked** (the coordinator, for M9's area decision): the full chip with the release features switched on together.
- **The features:** `TG_HPM=1`, `TG_LWT=1` and `TG_ITT=2`. `TG_DEBUG` is off, since it's for development builds only.
- **The source:** main 950b485d with fpu-2's table head ebf9f226 merged in. Against main, the table's RTL is identical to the placed T6 check's (bf29152f).
- **The flow:** the product flow at 0.95 and 1.05 ns.
- **The snapshot:** `snap/product_wt` e1eee3b02804, pinned `claude/spikes-2-board-m9a`. Forward references and lint with all three switches came back clean. Synthesis got `TG_HPM=1`, `TG_ITT=2` and `TG_LWT=1`.

| | **`m9a`** (both placements: one synthesis) | `rec_u105` (all three off) |
|---|---|---|
| LUTs after synthesis | **121,762 (104.0%)** | 119,547 (102.1%) |
| LUTs after `opt_design` | **117,539 (100.4%)** | 115,574 (98.7%) |
| FFs after synthesis | 59,543 | 58,414 |
| `place_design` (`AltSpreadLogic_high`) | **fails** after 6–8 min: 10,778 and 10,781 CLBs needed, 10,686 left | placed: 14,638 of the 14,640 CLBs in use, routed 112,862 LUTs (96.4%) |

- **The package is about 2,000 LUTs over the pair of record:** +2,215 after synthesis and +1,965 after `opt_design`. That matches the three features' own costs:
  - the counters, about 870 LUTs a chip ([area_switches.md](../spec/area_switches.md));
  - the table, about 860 (+431 a core out of context, bf29152f);
  - the load-wait table, 100–300 (50–150 a core, [area_recovery.md](area_recovery.md)).
- **Both placements fail in the packer** (Place 30-487), 92 and 95 CLBs short. `rec_u105` already used 14,638 of the device's 14,640 CLBs, so nothing was left for 2,000 more LUTs.
- **By unit, after synthesis, both cores together** (flatten rebuilt smears units, so this split is approximate):
  - fetch +725 LUTs (the table's `u_itt` 177 a core);
  - the CSR files +654 (the counters, about 85 LUTs each);
  - the LSUs +503;
  - the ROBs +441;
  - the walkers +251.
  - The uncore is unchanged (+8).
- **What would likely fit:**
  - Dropping one of the two larger features (the counters or the table, about 860–870 LUTs each) would bring the package within about 25 CLBs of the device, closer to the edge than the pair of record. It would likely place, and might not route.
  - One feature alone, or two features with about 1K LUTs recovered elsewhere, would sit where the pair of record does.
- **No timing:** neither placement reached routing.

Results: [`fpga/spikes/results/m9a_area/`](../../fpga/spikes/results/m9a_area/):
- the synthesis and `opt_design` utilization, the hierarchy, and `hier_diff_vs_rec_u105.txt`;
- `place_errors.txt`;
- the pair of record's paths with `paths_m9a.tcl`, the baseline for a fit that places.

#### M9's area package: no placement form packs it; each feature's price (2026-10-24)

**Asked** (the coordinator, after the pair's Place 30-487), in this order:
1. Can the package pack at about 98% with no RTL change? Placement forms that pack denser than `AltSpreadLogic_high` and/or the L2 pblocks loosened, at 1.05 ns.
2. Each feature's full-chip cost, synthesis plus `opt_design`.
3. If nothing packs, the LUT gap to a fill that packs.

**The method:**
- **One netlist for every trial:** the package taken to `opt_design` with its checkpoint and 1.05 ns of placement uncertainty (`m9o_all`).
- **The trials:** [`place_trial.tcl`](../../fpga/spikes/tcl/place_trial.tcl) runs one placement form from that checkpoint:
  - the placer's directive;
  - DR-181's pblocks kept or removed;
  - an optional second `opt_design` pass;
  - then `build.tcl`'s own steps.
- **The prices:** `build.tcl` stopped after `opt_design` (the snapshot's measurement knob `TG_STOP_AFTER_OPT`, f0701da682ca), with each switch alone on the same tree.

| Placement form (1.05 ns, the same netlist) | LUTs when placing | CLBs the packer needs (10,686 left) | |
|---|---|---|---|
| `AltSpreadLogic_high`, pblocks kept (the pair, `m9a`) | 117,539 | 10,778 / 10,781 | fails |
| `Default`, pblocks kept | 117,539 | 10,779 | fails |
| `Default`, pblocks removed | 117,539 | 10,770 | fails |
| a second `opt_design` pass, then `AltSpreadLogic_high`, pblocks kept | 116,959 | 10,732 | fails |
| a second `opt_design` pass, then `Default`, pblocks removed | 116,926 | 10,718 | fails |

The second pass is `opt_design -remap -aggressive_remap -resynth_seq_area -merge_equivalent_drivers -control_set_merge`, after the build's own `ExploreArea`.

| After `opt_design` | LUTs | against off | against `rec_u105` (115,574) | LUTRAM | FFs | DSPs | BRAM tiles |
|---|---|---|---|---|---|---|---|
| all three off (`m9o_off`) | 115,724 | | +150 | 16,656 | 58,169 | 140 | 120 |
| `TG_HPM=1` | 116,001 | **+277** | +427 | +0 | +312 | +32 | +0 |
| `TG_LWT=1` | 116,148 | **+424** | +574 | +48 | +128 | +0 | +0 |
| `TG_ITT=2` | 116,646 | **+922** | +1,072 | +240 | +685 | +0 | +4 |
| all three (`m9o_all`) | 117,539 | **+1,815** | +1,965 | +288 | +1,131 | +32 | +4 |

- **1: no.** No placement form packs the package, so none reached routing and there is no timing.
  - The placer's directive moves the packer's count by about 10 CLBs, and the pblocks by about 10.
  - The second `opt_design` pass cuts 580–613 LUTs and 46–52 CLBs, which still leaves the package 32–46 CLBs short.
- **2: the prices.**
  - The three alone add up to +1,623 LUTs; together they cost +1,815. The +192 is their interaction or synthesis noise (about ±300 a core).
  - The counters cost few LUTs because they count in DSPs.
  - The table's cost is in LUTs, LUTRAM (its keys) and 4 BRAM tiles (its targets).
- **3: the gap.** The packer's count falls about 12 CLBs per 100 LUTs at this fill.
  - **To place at all:** the package needs about 1,000–1,150 LUTs less with the build's `opt_design`, or 400–550 less with the second pass. The cliff is about 116,500 LUTs after `opt_design` (99.5%).
  - **That cliff is not a working fill:** a netlist there would route at about 99.6% of the LUT sites. The pair of record (115,574 after `opt_design`, 96.4% placed) closed both placements; the pacing image (115,755) closed its one.
  - **The fill that closes:** about 115,600–115,750 after `opt_design`. That is the package's whole cost, 1,800–1,950 LUTs, to recover elsewhere.
- **The lone features against the cliff:** the counters (116,001) and the load-wait table (116,148) sit 350–500 LUTs below it. The table (116,646) sits at it.

Results: [`fpga/spikes/results/m9a_area/`](../../fpga/spikes/results/m9a_area/):
- `m9o_*_opt_utilization.rpt`, each run's `opt_design` utilization;
- `m9t_*_trial.txt`, each placement form with the packer's count.

#### The write-pacing measurement image on main closes at +1.068 ns (2026-10-24)

**Asked** (the coordinator): soc-2's measurement image for the board's write-pacing sweep ([soc.md](../spec/soc.md) §8.5, `tests/bench/mem` `wsdp.bin`).
- **What's in it:** main 8a47f23b (all five DR-191 fixes) with `TG_L2_WB_PACE=1`. The batching is off at reset (`TG_L2_PACE_INIT=1025`, the default: a batch of 1, a wait of 64), so the sweep sets `L2_PACE` at run time.
- **The flow:** the pair of record's clean placement (`rec_u105`): the product form, `AltSpreadLogic_high`, `AlternateCLBRouting`, 1.05 ns. One placement, no fallbacks.
- **The snapshot:** `snap/product_wt2` 99fcb9376d8d (main plus the measurement commit), pinned `claude/spikes-2-board-wbpm`. Forward references and lint with `L2_WB_PACE=1` came back clean.

| | **`wbpm_u105`** | for comparison: `rec_u105` |
|---|---|---|
| LUTs after synthesis / `opt_design` / routed | 119,907 / 115,755 / 113,122 (96.6%) | 119,547 / 115,574 / 112,862 (96.4%) |
| FFs, control sets | 58,275, 2,847 | 58,210, 2,855 |
| WNS after placement (estimated, uncertainty on) | +0.202 | +0.296 |
| Routing | level 5, no trade; the whole build 1.5 h | level 5, no trade |
| **WNS / TNS / WHS (ns)** | **+1.068 / 0 / +0.009** | +1.066 / 0 / +0.010 |
| the core clock's WNS; `clk2x` within / into / back | +1.068; +1.292 / +1.083 / +1.150 | +1.157; +1.504 / +1.066 / +1.133 |
| Endpoints within 1 ns | **none** | none |

- **It closes with the pair of record's margin.** Against `rec_u105` it has +360 LUTs after synthesis, +260 routed and +65 FFs.
  - The batching is about 80 LUTs and 66 FFs a chip ([soc.md](../spec/soc.md) §8.5).
  - The rest is main's RTL since f3311cdd, with its switches off, and synthesis noise.
- **The floorplan:** L2 bank 0 100%/76%, bank 1 104%/79%.

**The image,** written by `run_bit_runs.sh` (write_bit_from_dcp.tcl); `timing_bit.rpt` says "All user specified timing constraints are met".

| | `tanager.bit.bin` sha256 | `tanager.bit` sha256 |
|---|---|---|
| **`wbpm_u105`, soc-2's write-pacing image** | f73771bbc1fde0e0277e3db22f0aaed19519f77ab11003cde9e03d29cb138c20 | fc951f18036794d469ed7699d71d596fab9c87ff77bc29dac940a991cd0b8eb9 |

Results: `fpga/spikes/results/product_wt2_wbpm_u105/`, with `images_sha256_md5.txt`. The image and checkpoint are in `~/tanager-build/track-spikes-72f833/vivado/product_wt2_wbpm_u105/`, on `KEEP.txt`.

#### The preview pair with DR-191's fixes 3–5 (2026-10-24)

**Asked** (the coordinator, 10-24): "a full-chip preview pair, product flow at 0.95 and 1.05 ns", on main d7c2d835 (fix 4 is 16b6d5d1) with fix 3 (core-2's tlbreg b3ab9dfe) and fix 5 (fpu-2's tageflat f6865c1e) merged. It is a preview: the pair of record waits for all five fixes on main.
- **Snapshot:** `snap/product_wt6` ffc9bb1fd548, pinned by `claude/spikes-2-board-pv3`.
- **Flow:** the product form with `AltSpreadLogic_high` and main's `TG_ROUTE_DIRECTIVE=AlternateCLBRouting`.

| | `pv3_u095` (0.95 ns) | `pv3_u105` (1.05 ns) |
|---|---|---|
| LUTs after `opt_design` / routed, FFs | 115,091 / 112,445 (96.0%), 57,795 | 115,091 / 112,535 (96.1%), 57,788 |
| WNS after `phys_opt_design` (estimated, uncertainty on) | −0.072 | +0.001 |
| Routing | level 6, **the router's trade** | level 5, no trade |
| **WNS / TNS / WHS (ns)** | −1.161 / −542.2 / +0.009 (1,745 failing) | **−0.806 / −458.8 / +0.010** (1,720 failing) |

- **Fixes 3–5 take their families out, even in the congested placement.** In u095, the same congestion and router trade as rc3_u100:

  | Family | rc3_u100 | pv3_u095 |
  |---|---|---|
  | `m2_foh_q` | −1.096, 21 levels | +0.025, 12 levels |
  | the walker's `chk_pa_q` | −1.104, 19 levels | +0.063, 12 levels |
  | TAGE | −0.998, 14 levels | +0.134, 7 levels |

  In u105 they are +0.60 or better.
- **What fails is fixes 1 and 2's families and the next tier.**
  - **Fix 1's** (on main since 6557e051, not in this preview): `lq_st_q` from the walker's `chk_req_q`, the checker's `pfc_wait_q` and the store FSM `xs_q` (−1.10 to −0.75, 22–24 levels); `fh_data_q`, `lx_valid_q`.
  - **Fix 2's:** the I$ valid RAM from the L2's response (−1.161 at 25 levels in u095, −0.68 in core 1).
  - **The next tier:**
    - fetch's queue state from the issue queues' `dep_q` (`qs_q` −0.806, `rt_b_q`, `rn_v_q`, 19–21 levels);
    - `occ_t_q` and rename's `pay_wd_q` from `head_t_q` (−0.74 / −0.66);
    - the RAS's `p_push_q` / `p_pop_q` from the I$ data BRAM (−1.09 to −0.55, 16–18 levels);
    - `m2_dword_q` from the DTLB CAM's `uf_q` (−1.151 in u095, 15 levels, 77% wire);
    - the D$ meta and valid RAMs and `sq_head_q` / `sqh_q` from the L2 bank's `ms` (−0.84 to −0.58);
    - CoRR's `ev1_v_q` (−0.786).
- **The floorplan is OK:** l2b0 99%/76%, L2 bank 1 102%/78%, xbar 30%/24%.

Results: `fpga/spikes/results/product_wt6_pv3_u095/` and `_u105/`.

#### M9's indirect-target table out of context, both forms (2026-10-24)

**Asked** (fpu-2, for the coordinator before the MR, DR-190): the indirect-target table (ITT, `claude/track-fpu-395911-itt` 1f5f9e18, main 6557e051 merged) out of context in both forms. `TG_ITT=1` is one 256-entry path table, `TG_ITT=2` the split, 128 by path and 128 by block.
- **The runs:** three runs of one snapshot (`snap/ooc_base` c1063c1aec09): the table off (`fix_slot_b`, the matched baseline, main's RTL), `TG_ITT=1` (`fix_slot_c`) and `TG_ITT=2` (`fix_slot_d`).
- **The flow:** `run_fix_ooc3.sh` with [`paths_itt.tcl`](../../fpga/spikes/tcl/paths_itt.tcl), which is DR-191's families plus the table's paths.

| A core, out of context | ITT off | `TG_ITT=1` | `TG_ITT=2` |
|---|---|---|---|
| LUTs / FFs | 51,518 / 23,657 | **+1,055 / +316** | **+632 / +316** |
| LUTRAM / RAMB36 | 8,784 / 53 | +40 / **+1** | +40 / **+2** |
| WNS (ns), the worst path | +0.649 (`am_st_q` → `s3_den_q`, 15 levels) | +0.336 (`rt_b_q` → decode's `dred_pc`, 21) | +0.491 (the DTLB CAM → `rp_ra_q`, 20) |
| from the table's read into anything | | +1.822, 16 levels (into `ka_q`) | +2.219, 17 levels (into `f3_rtop_q`) |
| into the table (commit's training) | | +5.001, 9 levels | +4.367, 13 levels |
| `krt_q` | +2.994, 7 levels | +1.301, **21** | +0.912, **18** |
| `f3_rtop_q` | +3.123, 6 levels | +1.293, **21** | +0.896, **18** |
| `kr_q` / `f3_ras_q` | +1.859, 15 / +1.699, 15 | +1.474, 21 / +1.891, 21 | +1.554, 18 / +1.556, 18 |
| fetch's `fpc_q` | +0.950, 21 levels | +0.907, 20 | +1.429, 17 |

- **The table's own paths are clear.** The read into fetch's state and the training write are +1.8 to +5 ns.
- **The table's target in the restart registers costs depth.** `kr_q`, `krt_q`, `f3_ras_q` and `f3_rtop_q` now start at the I$ data BRAM and run 18–21 levels deep, up from 6–15.
  - Out of context they are still +0.9 to +1.9 ns.
  - In the chip, fetch's other paths from the I$ data BRAM (the RAS's push and pop, `kimm_q`) were 16–18 levels at −1.1 to −0.5 ns in the preview pair. At 18–21 levels these four would likely join the worst.
- **The split form (2) is the cheaper and the shallower:** 3 levels fewer on these paths and 423 fewer LUTs than form 1, for one more RAMB36.
- **The WNS changes are within the noise.** The worst paths of both forms are not the table's, and runs move by up to 0.5 ns.

Results: [`fpga/spikes/results/ooc_itt/`](../../fpga/spikes/results/ooc_itt/) holds the three runs and `compare.txt`.

#### The indirect-target table's later heads: still 2–4 levels deeper than off from the I$ data (2026-10-24)

**Asked** (fpu-2, against the coordinator's bar): each new head of `claude/track-fpu-395911-itt` out of context in both forms, against the table off. The bar is F2's decision registers (`ka_q`, `k_ovr_q`, `kr_q`, `f3_ras_q`, the stack's push and pop) back at the table-off depth from the I$ data.
- **The heads:**
  - 7ba9b0a0, the trim;
  - 188328af;
  - a6f51752, the restructure: one predicted JALR slot in the exit search, as with the table off.
- **The runs:** the flow above. The table off is 7ba9b0a0's run (`fix_slot_b`), queried again with each head's path list. a6f51752's forms are `fix_slot_a` (`TG_ITT=1`) and `fix_slot_e` (`TG_ITT=2`), snapshot `snap/ooc_f1` f415b32a4adb.
- **The paths:** [`paths_itt4.tcl`](../../fpga/spikes/tcl/paths_itt4.tcl) times each decision register separately from the I$ data and from TAGE, and `fpc_q` from `f3_s_q`.

| A core, out of context | off | 188328af `TG_ITT=1` | 188328af `TG_ITT=2` | a6f51752 `TG_ITT=1` | **a6f51752 `TG_ITT=2`** |
|---|---|---|---|---|---|
| LUTs / FFs (the forms against off) | 51,746 / 23,654 | +482 / +312 | +251 / +335 | +445 / +309 | +248 / +334 |
| From the I$ data, levels: `ka_q` | 19 | 23 | 23 | 21 | 22 |
| `k_ovr_q` | 18 | 23 | 23 | 21 | 22 |
| `kr_q`, `f3_ras_q` | 18 | 23 | 23 | 20 | 21 |
| the stack's push | 19 | 25 | 24 | 20 | 21 |
| the stack's pop | 19 | 24 | 23 | 19 | 21 |
| `kimm_q` | 17 | | | 21 | 21 |
| the table's `ki_q`, `f3_itt_q`, `ipi_q`, `ipw_q` | | 23 | 23 | 20 | 21 |
| From TAGE, the same registers | 19–21 | 18–20 | 19–20 | 16–18 | 16–17 |
| `krt_q` / `f3_rtop_q` | 6 / 6 | 7 / 10 | 7 / 7 | 7 / 10 | 9 / 9 |
| `fpc_q`: the worst / from `f3_s_q` / from `f3_start_q` | 17 / 20 / 19 | 23 | 19 | 23 / 24 / 23 | 18 / 21 / 20 |
| WNS, the worst path (not the table's) | +0.075 (LSU) | +0.268 (fetch's `head_t_q`, 24) | +0.450 (LSU) | +0.333 (fetch's `head_t_q`, 21) | +0.715 (LSU) |

- **Not at the bar yet, but closer.** From the I$ data, a6f51752's decision registers are 2–4 levels deeper than off in mode 2 and 0–3 in mode 1. 188328af's were 4–6 deeper. From TAGE, both forms are 1–5 levels shallower than off.
- **Where the extra levels are.** In both forms, every one of these paths takes the predecode's return flag (`pd_pop`) into the table. One of the table's LUTs (`g_tage.g_itt.u_itt/…hr_xm_q[1]_i_7`) then drives TAGE's history logic.
  - So the I$ data reaches TAGE at level 10 (mode 1) or 11 (mode 2). With the table off it reaches TAGE at level 8, straight from the predecode's `pd_start`.
  - From TAGE on, the paths are as deep as off's, give or take one or two levels.
  - So the exit search still waits for the return check. Taking the JALR slot without that check, and choosing the stack or the table for the target after the exit, would likely bring these paths back to off's depth.
- **`fpc_q`:** mode 2 is within a level of off from every start.
  - Mode 1 is 4 levels deeper from `f3_start_q` (19 → 23), and so are `spc_s_q`, `ft_q` and `f1_valid_q`.
  - The extra levels are in fetch's own control after F3's valid. The first 9 levels are the same in all three, and no table cell is on the path.
  - Mode 1's worst path is also in fetch's control (`head_t_q` → `qs_q`).
- **Out of context the slacks don't show the cost.** The I$-data paths are +0.9 to +2.2 ns in both forms, against +1.05 to +1.93 off: within the ±0.5 ns noise. The levels are the measure.
- **The table's own paths are clear:**
  - its read into `ka_q`: +2.200 ns at 18 levels (mode 2), +1.121 at 17 (mode 1);
  - training: +3.4 / +4.2 ns;
  - `kit_q`: 3 levels;
  - `f3_itgt_q`: 3 levels (mode 2), 10 (mode 1).
- **In the chip:** the pair of record (no table) has the I$ data into the push, the pop and `ka_q` at +0.345 ns and 21 levels in its congested placement, `rec_u095`. That is its second-worst family. At 0.3–0.4 ns a level, mode 2's 2–3 more levels would put that family at about −0.3 to −0.9 ns there.
- **The trim (7ba9b0a0)** cut the area to +306 / +288 LUTs a core, against 1f5f9e18's +1,055 / +632. Its paths were not split by start. Results: `ooc_itt_trim/`.

Results: [`fpga/spikes/results/ooc_itt_t3/`](../../fpga/spikes/results/ooc_itt_t3/) (188328af) and [`ooc_itt_t5/`](../../fpga/spikes/results/ooc_itt_t5/) (a6f51752), each with `compare.txt`. In `ooc_itt_t5/`, each form's `levels_ic.txt` lists the I$-data paths level by level, and `fpc_q_from_f3_start.txt` holds the `fpc_q` query.

#### bf29152f: the table's keys in LUT RAM bring mode 2 back to off's depth (2026-10-24)

**Asked** (fpu-2): bf29152f, which is a6f51752 plus one commit.
- **The change:**
  - The table's key {valid, slot, tag, privilege} is in LUT RAM, read and checked at F1 with the same index.
  - Fetch registers the predicted JALR slot (`phit_q`, `pslot_q`) beside `f2_hit_q` and `f2_slot_q`. So the exit search takes it from registers, as with the table off.
  - The targets stay in block RAM.
- **The baseline:** the off design is unchanged (with the table off, `phit` and `pslot` are still `f2_hit_q` and `f2_slot_q`). So off is the same 7ba9b0a0 run, queried again with [`paths_itt5.tcl`](../../fpga/spikes/tcl/paths_itt5.tcl): `paths_itt4.tcl`'s paths plus `phit_q`, `pslot_q`, and `fpc_q` from the I$ data and from `f3_start_q`.

| A core, out of context | off | a6f51752 `TG_ITT=2` | **bf29152f `TG_ITT=2`** | bf29152f `TG_ITT=1` |
|---|---|---|---|---|
| LUTs / LUTRAM LUTs / FFs (the forms against off) | 51,746 / 8,784 / 23,654 | +248 / +56 / +334 | +431 / +120 / +343 | +562 / +112 / +316 |
| RAMB36 (against off) | | +2 | +2 | +1 |
| From the I$ data, levels: `ka_q` | 19 | 22 | 19 | 18 |
| `k_ovr_q` | 18 | 22 | 19 | 21 |
| `kr_q`, `f3_ras_q` | 18 | 21 | 18 | 20 |
| the stack's push | 19 | 21 | 20 | 21 |
| the stack's pop | 19 | 21 | 19 | 20 |
| `kimm_q` | 17 | 21 | 18 | 20 |
| the table's `ki_q`, `f3_itt_q`, `ipi_q`, `ipw_q` | | 21 | 18 | 20 |
| The level where the I$ data reaches TAGE | 8 | 11, after `pd_pop` and a table LUT | 9 | 7 |
| From TAGE, the same registers | 19–21 | 16–17 | 18–21 | 20–23 |
| `phit_q` / `pslot_q` | | | 9 / 9 levels | 6 / 6 levels |
| `fpc_q`: the worst / from `f3_s_q` / from `f3_start_q` | 17 / 20 / 19 | 18 / 21 / 20 | 20 / 24 / 22 | 17 / 22 / 21 |
| WNS, the worst path (not the table's) | +0.075 (LSU) | +0.715 (LSU) | +0.552 (the DTLB CAM → `rp_ra_q`, 22 levels) | +0.428 (LSU, 16) |

- **Mode 2 meets the bar.** From the I$ data its decision registers are within a level of off's depth.
  - No table cell and no `pd_pop` is on any of these paths.
  - The I$ data reaches TAGE at level 9, against off's 8: it goes through the jump decode `pd_jal` instead of `pd_start`. From TAGE on, the depth is off's.
- **Mode 1 doesn't:** it is 1–3 levels deeper than off from the I$ data (`ka_q` is one shallower), and 1–3 deeper from TAGE.
  - Its paths reach TAGE at level 7, through fetch's own return decode `pd_pop`, which fetch's stack terms use with the table off too. They then run 13–14 levels inside TAGE, against off's 10–12.
  - `k_ovr_q` also passes one table LUT two levels from its end: TAGE's `f3_nhs` into the table's `fx_nhs`.
- **The new registers are clear.** `phit_q` and `pslot_q`: 6–9 levels, +2.4 to +3.2 ns. The table's target read is now short: into `ka_q` at 7–8 levels, +3.8 to +3.9 ns.
- **`fpc_q` has no path from the I$ data in any of the three runs.** In mode 2 it is now 3–4 levels deeper than off from every start; in a6f51752 it was mode 1 that was 4 deeper. Both times, the extra levels are in fetch's control after F2's or F3's valid (the stall and redirect select into `fpc_q`'s enable), and no table cell is on the path.
- **The area:** the keys cost +64 LUTRAM LUTs a core over a6f51752 in both forms. Against off: +431 LUTs a core in mode 2 and +562 in mode 1, about +860 and +1,120 a chip.
- **In the chip:**
  - Mode 2's I$-data paths at off's depth should leave the pair of record's I$-data family where it is: +0.345 ns at 21 levels in its congested placement.
  - The one to watch is `fpc_q`. If its 3–4 extra levels carry into the chip, the pair of record's `fpc_q` family (+0.388 ns from `f3_carry_q` in the same placement) would be about 1 ns worse.

Results: [`fpga/spikes/results/ooc_itt_t6/`](../../fpga/spikes/results/ooc_itt_t6/): `compare.txt` and `itt_levels.txt`; each form's `levels_ic.txt` and `levels_fpc_q.txt` list the paths level by level.

#### core-2's A/B: the read thread with and without per-bank copies (2026-10-22)

The fixes preview's base with core-2's newer heads (`snap/product_wt` and `snap/product_wt3`): e5b304cd, TAGE 8cf8e262, DR-183 ecfcc8a5, and core-2's walker fix a6abdc5d. The walker fix registers the head lookup's VPN, so DTLB port 2 starts at one register. Then:
- **A** (`product_wt_abA_aslh`): `rt_q` and `occ_t_q` on decode's take, d5696350.
- **B** (`product_wt3_abB_aslh`): the same with per-bank copies of the read thread, 9e82b799.

Both use `AltSpreadLogic_high` and one placement each, at TG_PR_UNC 1.0.

| | A | B |
|---|---|---|
| LUTs after `opt_design` / routed | 113,779 / 111,481 | 113,718 / 111,228 |
| FFs routed, CLBs | 57,646, 14,635 | 57,650, 14,599 |
| WNS after `phys_opt_design` (estimated, with 1.0 ns on) | −0.415 ns | −0.923 ns |
| Routing | **congested:** the router put routability ahead of timing | no trade |
| WNS / TNS on the core clock (ns) | −1.721 / −3,787 (7,743 failing) | **−0.803 / −964.3** (3,351 failing) |
| `clk2x`: within / into / back (ns) | +0.333 / −0.778 (a one-level URF enable, a routing detour) / +0.759 | +1.617 / +0.770 / +0.825 |

| Family | Preview, placement 1 / 2 | A | B |
|---|---|---|---|
| `pay_wd_q` | −0.843 / −0.331 | −0.558 | −0.498 |
| fetch's `rt_q` | −0.854 / −0.659 | −1.292 | −0.545 |
| `occ_t_q` | −0.701 / −0.331 | −0.556 | −0.056 |
| `head_t_q` | −0.588 / −0.079 | −0.635 | +0.006 |
| The walker's `chk_pa_q` / `base_q` from `ct_q` | +0.479 / +0.426 | none within 1 ns | none within 1 ns |
| The LQ state (`lq_st_q`) | −0.849 / −0.789 | −1.702 | −0.802 |
| The L2 → crossbar → core response | −0.580 / −0.001 | −1.355 | −0.803 |

- **The walker fix works.** No path from `ct_q` into `chk_pa_q` or `base_q` is within 1 ns in either.
- **A's congested route spoiled its timing.** A's placement was the better one before routing, so A against B is undecided on one run each. B routed cleanly and has the best `occ_t_q` and `head_t_q` of any run.
- **B's worst families** (−0.80 ns):
  - the L2's response into core 1's I$ valid bits (from the bank's `d_idx`, 20 levels);
  - the LQ state from the LQ head (31);
  - decode's `dred_pc` from the issue queues' `dep_q`;
  - the LSU's `fh_data_q` from `ct_q`;
  - fetch's `kimm_q` from the I$ data.
- **To decide A against B,** a second placement of each (1.05 ns) would make two pairs.

Results: `fpga/spikes/results/product_wt_abA_aslh/` and `product_wt3_abB_aslh/`.

#### The fixes preview, a pair of placements: −0.79 ns at best (2026-10-22)

**Asked** (the coordinator): which families remain once the pending fixes are in, judged as a pair of placements. The snapshot (`snap/product_wt2` d1a72fbe) is main e5b304cd (the L2 bank's registered D output) plus:
- TAGE 8cf8e262 (fpu-2);
- DR-183 ecfcc8a5;
- DR-185 196cb8ed with core-2's `rt_q` fix 28ac2bbc and mode-family fix 2175432b (merged over DR-183's `tg_lsu` as core-2 confirmed);
- `AltSpreadLogic_high`, `TG_PMP_FILL=1`.

| | Placement 1 (`pv1_aslh`, 1.0 ns) | Placement 2 (`pv1_aslh_u105`, 1.05 ns) |
|---|---|---|
| LUTs after `opt_design` / routed | 114,041 / 111,784 (95.4%) | — / 111,609 |
| FFs routed, CLBs | 57,679, 14,634 | 57,585, 14,592 |
| WNS after `phys_opt_design` (estimated, with the uncertainty on) | −0.571 ns | −0.230 ns |
| WNS / TNS on the core clock (ns) | −0.854 / −495.4 (1,973 failing) | **−0.789 / −191.9** (822 failing) |
| Endpoints within 1 ns | 9,216 in 331 families | 8,063 in 332 families |
| `clk2x`: within / into / back (ns) | +1.624 / +0.334 / +0.569 | +1.755 / +0.928 / +0.974 |

The pair's verdict: the better WNS is −0.789 ns, and TNS is between −192 and −495 ns. The best routed chip so far.

| Family | Placement 1 | Placement 2 |
|---|---|---|
| The LSU's LQ state (`lq_st_q`) from the LQ head and the ROB's `ct_q` (29 levels) | −0.849 (364 endpoints) | −0.789 (355) |
| fetch's `u_cmp/rt_q` | −0.854 | −0.659 |
| The payload write register `pay_wd_q` | −0.843 (908) | −0.331 (722) |
| `occ_t_q` (from the issue queues' `dep_q`) | −0.701 | −0.331 |
| The walker (`u_ptw`) from `ct_q` | −0.396 | +0.426 |
| `md_l_q`'s families: `rp_ra_q`, `m2_dword_q`, `sq_av_q` | +0.070, −0.339, −0.270 | −0.407, −0.100, +0.039 |
| The L2 → crossbar → core response | −0.580 (720) | −0.001 (208) |
| TAGE | +0.890 (only `tg_tage`'s `q_q`) | +0.834 |
| DR-183's `g_pmpf`, the ACLINT | none within 1 ns | none |

- **Only the LQ-head family is bad in both placements:** `lq_st_q`, `fh_data_q` and `lx_valid_q` from the LQ head, 24–29 levels. soc-2 takes it after DR-183.
- **The rest move with the placement by 0.3–0.6 ns.** In placement 2 only 8 families are worse than −0.5 ns: the LQ-head ones, the RAS's `s_cnt_q`/`a_cnt_q` from the ROB's `hw_q`, and one `rt_q` endpoint.

Results: `fpga/spikes/results/product_wt2_pv1_aslh/` and `product_wt2_pv1_aslh_u105/`.

#### The area-pass forms together (0a30d99d): both clear, −2.86 ns in this placement (2026-10-22)

`product_wt_a1_aslh`, "the closest to the final area-pass chip so far" (the coordinator):
- **What's in it:** main dc2965be, DR-185 with the registered payload write (31a90443), and DR-183 at 87e74fb9 (fetch's request registers no longer read F1's late `f1_new`; `TG_PMP_FILL=1`).
- **Flow:** `AltSpreadLogic_high` (now `build.tcl`'s own `TG_PLACE_DIRECTIVE`, DR-187).

| | Registered write + DR-183 d07317a6 | **Registered write + DR-183 87e74fb9** |
|---|---|---|
| LUTs after `opt_design` / routed | 114,388 / 112,015 | 114,122 / 111,829 (95.5%) |
| FFs routed, CLBs, control sets | 57,561, 14,626, 2,833 | 57,541, 14,631, 2,858 |
| WNS after `phys_opt_design` (estimated, with 1.0 ns on) | −1.032 ns | −1.609 ns |
| Routing | congestion level 6, no trade | level 5, no trade, 1.6 h |
| WNS / TNS on the core clock (ns) | −2.440 / −3,544 (4,992 failing) | **−2.863 / −4,675** (6,523 failing) |
| `clk2x`: within / into / back (ns) | +1.490 / +1.419 / +1.142 | +1.573 / +0.275 / +0.694 |

- **Both area-pass forms left the near-critical set.**
  - DR-183's fetch request paths went from 28 families and 194 endpoints to one epoch register, `g_pmpf.f1_ep_q`: 1 endpoint at −1.236 ns from `f3_s_q`, 27 levels.
  - Nothing into the payload LUTRAM is within 1 ns. Its write register reads −1.200 ns in this placement.
- **The worst families are the ones with fixes in progress:**
  - the LSU's LQ state from the LQ head (192 endpoints a core, 25–27 levels, worst −2.863);
  - fetch's `u_cmp/rt_q` from the issue queues' `dep_q` (32–33 levels, −2.83);
  - the L2's response into the I$ valid-bit RAMs (13 families, 953 endpoints, −2.62; soc-2's registered D output);
  - the LSU's replay pick from step 6/7's `md_l_q` (−2.54);
  - TAGE (−2.23, fpu-2).
  - By unit within 1 ns: the LSU 238 families, fetch 106, rename 104, the CSR files 98.
- **Not the clock.** main's `tg_clkgen` change (DR-187's clk2x-aware VCO) leaves the core clock's uncertainty at 0.068 ns in both builds. The worse result is this placement: its estimate before routing was 0.58 ns worse.
- **From here, configurations are judged by two placements** (TG_PR_UNC 1.0 and 1.05, `tools/launch_pair.sh`), by the better WNS and by TNS.

Results: `fpga/spikes/results/product_wt_a1_aslh/`.

#### The registered payload write with DR-183 (d07317a6): −2.44 ns, the payload clear (2026-10-22)

`product_wt2_next_aslh`:
- **What's in it:** main 854ec2ce, core-2's DR-185 with the payload's write registered (31a90443, `PAY_WREG` = 1), and DR-183 at d07317a6 (`TG_PMP_FILL=1`).
- **Flow:** `AltSpreadLogic_high`.

| | Combined preview (payload written directly) | **Registered payload write** |
|---|---|---|
| LUTs after `opt_design` / routed | 114,587 / 112,118 | 114,388 / 112,015 (95.6%) |
| FFs routed | 56,054 | 57,561 (+1,507: the write register, about 750 a core) |
| CLBs, control sets | 14,632, 2,893 | 14,626, 2,833 |
| WNS after `phys_opt_design` (estimated, with 1.0 ns on) | −1.605 ns | −1.032 ns |
| WNS / TNS on the core clock (ns) | −1.620 / −3,900 (8,533 failing) | **−2.440 / −3,544** (4,992 failing) |
| Endpoints within 1 ns | 19,460 | 14,778 |

- **The payload write left the near-critical set.**
  - Nothing into `u_rn/u_pay` is within 1 ns (the direct write had 8,381 endpoints at −1.362).
  - The new write register `pay_wd_q` takes decode's path at −0.426 ns (938 endpoints, 19 levels).
- **DR-183 at d07317a6 still has its fetch request paths:** `g_pmpf.rq_pa_q` at −1.065 ns, 25 levels from `f3_s_q`, 28 families. soc-2's 87e74fb9 removes that clock-enable cone. The next build has it.
- **This placement's WNS is in the LSU.**
  - From the ROB's head into the walker's `ok_q` and `cause_q` and the LQ's state (−2.44 ns, 27–28 levels).
  - From step 6/7's `md_l_q` into the replay pick and M2.
  - Then core 1's TAGE (−2.15) and the L2's response into its I$ valid-bit RAM (−2.14, 27 levels).
- **Fewer failing endpoints, a worse worst one.** Placement noise at this fill moves WNS by more than a lever is worth. TNS and the endpoint counts follow the levers better than WNS does.

Results: `fpga/spikes/results/product_wt2_next_aslh/`.

#### The combined preview: DR-185 + DR-183 routes at −1.62 ns (2026-10-22)

**Asked** (the coordinator, through soc-2): whether DR-185 and DR-183 together route and close at 100 MHz.
- **What's in it:** the DR-185 preview (3ed73e6f, the payload written directly) plus soc-2's DR-183, PMP checks at TLB fill (5a885ab9 with `TG_PMP_FILL=1`). Merged into main a6ff993d with `AltSpreadLogic_high` (`product_wt_combo_aslh`).
- **A first attempt stopped in `build.tcl`'s synthesis check:** Synth 8-6901, a forward reference in DR-183's `tg_lsu`. The measurement copy moved the line, as soc-2's d07317a6 then did.

| | DR-185 preview | **DR-185 + DR-183** |
|---|---|---|
| LUTs after `opt_design` / routed | 116,663 / 114,067 | 114,587 / **112,118 (95.7%)** |
| FFs routed | 55,850 | 56,054 |
| CLBs | 14,639 | 14,632 |
| WNS after `phys_opt_design` (estimated, with 1.0 ns on) | −0.755 ns | −1.605 ns |
| Routing | 1.0 h; congestion 6, no trade | 1.2 h; congestion level 5, no trade |
| WNS / TNS on the core clock (ns) | −1.108 / −595.5 (2,120 failing) | **−1.620 / −3,900** (8,533 failing) |
| `clk2x`: within / into / back (ns) | +1.721 / +0.652 / +0.867 | +1.338 / +1.054 / +1.128 |

- **DR-183 takes about 1.95K LUTs off the routed chip and adds 204 FFs.** It routes, but it doesn't close.
- **This placement came out worse before routing** (−1.61 against −0.76), the same spread seen in builds 1–3. One run each can't rank them.
- **DR-183's new paths are fetch's PMP request registers.**
  - `g_pmpf.rq_pa_q` (32 endpoints), `rq_tid_q`, `rq_tag_q` and `cw_q` are reached from F3's `f3_s_q` through 27 levels (worst −1.067 ns).
  - `lp_pg_q` and `rq_pa_q` are reached from the L2's refill pointer through 24 (−0.94).
  - Nothing into M2's grant (`m2_ok`) is within 1 ns. No same-core fetch → LSU request path is near-critical.
- **The unregistered payload write** is much worse in this placement: 8,381 endpoints in `u_rn/u_pay`, worst −1.362 ns. The registered form (31a90443) is building next.
- **The worst paths:**
  - the L2's response into the cores' I$ valid-bit RAMs (−1.62, 24–28 levels);
  - the LSU's LQ state from the ROB and the LQ head (−1.62, 25);
  - fetch's `u_cmp/rt_q` from rename (40–41 levels);
  - TAGE (−1.58).
  - By unit within 1 ns: the LSU 201 families, fetch 116, rename 115, the CSR files 85.
- **New with the crossbar unsliced:** core 0's fetch `apf_q` reaches both cores' D$ miss entries (−0.249 ns, 14 levels, 81% wire).

Results: `fpga/spikes/results/product_wt_combo_aslh/`.

#### Build 2, with the banks' D slice (`TG_D_SLICE=1`): doesn't route (2026-10-22)

Build 1 plus `TG_D_SLICE=1`, which puts a skid buffer on each L2 bank's D channel before the crossbar (`product_wt_nsd_aslh`). It is a measurement: the D slice is off by the user's choice.

| | Build 1 (no D slice) | Build 2 (D slice) |
|---|---|---|
| LUTs after `opt_design` / placed | 115,692 / 113,343 | 115,868 / 113,359 |
| FFs placed | 60,133 | 60,729 (+596) |
| CLBs, control sets | 14,629, 2,878 | 14,640, 2,857 |
| WNS after `phys_opt_design` (estimated, with the 1.0 ns of uncertainty on) | −0.897 ns | −0.965 ns |
| Routing | routed at −1.740 ns, congestion level 5 | **failed:** 25,101 signals unrouted for congestion (level 6), 29,681 node overlaps |

- **Placed congestion:** every window is level 5. They center on core 1's LSU (39–58% of a window's cells) and its D$ (18–25%), beside the uncore (17–32%), in rows 83–139 next to the crossbar and L2 bank 0. One window over the uncore holds core 0's CSR file and LSU.
- **Routability itself is noisy at this fill.** The same netlist with and without 596 flip-flops lands on either side of the line. One run each can't separate the D slice from placement noise.
- **So the D slice's effect on the response path (−1.459 ns in build 1) is unmeasured here.** That path isn't the worst family anyway: decode into the rename registers (−1.69) and fetch (−1.74) are worse.

Results: `fpga/spikes/results/product_wt_nsd_aslh/` (utilization after `opt_design` and placement, the floorplan's reports, `congestion_placed.rpt` from the placed checkpoint, `run_excerpt.txt`).

#### Build 3, with 0.5 ns of uncertainty on `clk2x`: doesn't route (2026-10-22)

Build 1 with `TG_PR_UNC2X=0.5`: `clk2x` carries 0.5 ns of placement uncertainty and the core clock keeps 1.0 (`product_wt_ns2x_aslh`; the log confirms 0.5 ns on c2x).

| | Build 1 | Build 3 |
|---|---|---|
| LUTs placed, FFs, CLBs | 113,343, 60,133, 14,629 | 113,223, 60,124, 14,634 |
| WNS after `phys_opt_design` (estimated, with the core clock's 1.0 ns on) | −0.897 ns | −2.172 ns |
| Routing | routed at −1.740 ns | **failed:** 51,224 signals unrouted for congestion (level 6), 79,675 node overlaps |

- **The placement itself came out worse** (−2.17 against −0.90 before routing), and routing then failed.
- **Of the three ACLINT-snapshot builds with AltSpreadLogic_high, only build 1 routed.**
  - The three differ by a D slice (+596 FFs) or by a clock uncertainty, yet the outcomes span routed at −1.74 ns to 51K nets unrouted.
  - At 96.8% of the LUTs with every CLB used, whether this chip routes is a coin toss. Build 1 was the good toss.
- **So the chip needs area back before flow levers can be judged:** single runs can't rank them. The `clk2x` setting is unjudged here.

Results: `fpga/spikes/results/product_wt_ns2x_aslh/`.

#### AltSpreadLogic_medium: spreads too little at this fill (2026-10-22)

The slices-on product build on the new snapshot (`snap/product_wt2`, main e2570c7c) with `place_design -directive AltSpreadLogic_medium` (`product_wt2_aslm`).
- **Placement looked best of all the runs:** the estimate after `phys_opt_design` was −0.172 ns with the 1.0 ns of uncertainty on, and the router's first timing pass −0.010 ns.
- **Routing undid it.** The router's congestion then rose to level 6 (64 × 64), it reported that congestion kept it from routing every net, and it gave up timing.
- **Result:** 114,385 routed LUTs, 64,213 FFs, WNS **−3.028 ns**, TNS −19,275 ns, 18,969 failing endpoints; `clk2x` +0.946 ns.
- **So AltSpreadLogic_high is the spreading for this chip:** it routed the harder, older netlist at −1.547 ns. The next combinations use it.

Results: `fpga/spikes/results/product_wt2_aslm/`.

#### No crossbar or memory-port slices: routes, but congested (2026-10-22)

**Asked** (the coordinator): the product build with `TG_XBAR_SLICE=0` and `TG_MEM_SLICE=0`, keeping `TG_AR_SLICE=1` (the user's decision), with everything else as the baseline: default placement.
- **Why:** soc.md measures the slices at about 1,150 LUTs, 4,629 FFs and 21 DSPs. They were built for 200 MHz and cost cycles.
- **Basis:** the new snapshot `snap/product_wt2`, main e2570c7c (M7 step 6 and its fix, fpu-2's FPU levers, DR-181). So beside the baseline it also carries step 6's +768 and fpu-2's −580 LUTs a chip.
- **Run:** `product_wt2_noslice`.

| | Baseline (c0030303, slices on) | No slices (e2570c7c) |
|---|---|---|
| LUTs after `opt_design` | 116,190 | 115,674 |
| LUTs routed | — | 113,231 (96.7%) |
| FFs placed | 63,912 | **60,185** (−3,727) |
| DSPs | 157 | 140 |
| CLBs, control sets | 14,637, 2,849 | 14,640, 2,852 |
| WNS after `phys_opt_design` (estimated, with 1.0 ns of uncertainty on) | −1.704 ns | **−0.390 ns** |
| The router's starting short congestion | level 6 in four directions, 29–34% of tiles | level 6 east and west, 5 north and south, 22–29% |
| Routes | no | **yes**, after giving up timing for congestion |
| WNS / TNS on the core clock (ns) | — | −3.507 / −13,951, 16,470 failing endpoints |
| `clk2x` / the host clock (ns) | — | +1.810 / +4.367 |

- **The flip-flops and the placement improved; routing undid the timing.** The router's first timing pass read −0.29 ns, with the uncertainty still on. Then it reported that congestion kept it from routing every net, put routability ahead of timing, and finished at −3.5 ns.
- **The crossbar's response direction is where the slices mattered.** By path:

| Path | Families below 1 ns | Endpoints | Worst |
|---|---|---|---|
| The L2 banks through the crossbar into both cores' fetch (the bank's `u_rack` pointer into the I$ valid-bit RAM and the fetch PC) | 42 | 2,441 | −3.168 ns, 23 levels |
| The cores into the crossbar (fetch's `ps_q` into its error responder) | 6 | 16 | −1.283 ns |
| The host bridge into a core | 2 | 6 | −0.527 ns |
| Within the uncore | 15 | 523 | −0.520 ns |
| The memory ports: the PS's responses into an L2 bank (`m_vact`, 88% wire) | 2 | 2 | −0.204 ns |

- **The worst paths are still the cores'.** At −3.5 ns the LSU's LQ state and M2 registers are reached from rename's `md_q` (step 6's merged halves). Then come the walker, the ROB's `hw_q` and the DTLB.
- **So no-slice alone is the better netlist but not yet a placement.** It needs the spread placement that made the slices-on chip routable.
- **If the L2-to-core response is still long then:** the worst of it starts in the bank's ReleaseAck queue (`u_rack`), which feeds the bank's D channel.
  - `TG_D_SLICE=1` puts a skid buffer (`tg_skid`) on each bank's D channel before the crossbar, so it registers that response at the bank.
  - Its cost is two banks' D-channel registers, against about 4.6K FFs for the crossbar's own slices.

Results: `fpga/spikes/results/product_wt2_noslice/` (summary, timing, utilization, the floorplan's reports, `route_excerpt.txt`, `fail_families.txt`).

#### The area exploration: the LSU, rename and the PMP bound (2026-10-21)

**Asked** (the coordinator): three synthesis-only measurements on main e6691d53 (DR-179's FP banks of 64), with hu1's settings: smt2, TG_HART1=1, the release form's `LAT_INJ=0`, the product windows, the URF on. Measurement only; nothing goes to main.
1. Core 0's LSU, split by function.
2. Core 0's rename, split by function.
3. The upper bound of the PMP saving: the fetch and load checkers and their descriptor selects stubbed out.

**The basis matters.** The board's `-flatten_hierarchy rebuilt` (ex1, 122,482 LUTs) mixes the units:
- it dissolves the PMP checkers, putting their descriptor selects under the CSR file;
- it files about 1.1K of the issue queues' and the LSU's cells under rename.

So the breakdowns use ex1n, the same build with `-flatten_hierarchy none` (122,432 LUTs: the setting costs nothing here). On ex1n, core 0's units are:

| Unit | ex1n (none) | ex1 (rebuilt, as hu1 was reported) |
|---|---|---|
| LSU | 13,243 | 11,563 |
| Rename | 5,261 | 6,404 |
| CSR file | 1,792 | 3,371 |

The tables below count LUT cells. Synthesis packs about 1.24 of them into each reported LUT in the LSU and 1.36 in rename.

**1. The LSU** (core 0: 13,243 LUTs, of them 1,696 LUTRAM; 14,270 LUT cells, 5,314 FFs):

| Part | LUT cells | Share | FFs | What's in it |
|---|---|---|---|---|
| D$ control, miss entries and data selects | 3,573 | 25% | 888 | The D$'s own 2,892: data selects about 1.0K (the load's hit-way dword 468, the victim and probe data 384, port B's write data 128, the AMO read 64), the four miss entries about 0.6K, the tag, valid and state ports about 0.3K. The LSU's logic into the D$'s ports: 681. |
| The two PMP checkers and their descriptor selects | 2,320 | 16% | 54 | Load: checker 557, select and inputs 565. Store and walker: 574 and 619. |
| LQ state and control | 1,481 | 10% | 1,356 | The 24 entries' next state (`lq_st_q` 1,054, 44 an entry). |
| DTLB (32 entries) | 1,120 | 8% | 284 | Plus 1,120 LUTRAM cells. The CAM match about 380, the tables' ports about 410, the valid bits 148. |
| SQ state and control | 1,081 | 8% | 1,176 | The drain (`sq_dr_q` 412), the tags 198. |
| Atomics and MMIO | 870 | 6% | 507 | |
| Replay, with the ordering check's result | 855 | 6% | 7 | `rp_v_q` 681 (the ordering search with its window and state terms), the oldest select `rp_ra_q` 161. |
| Byte overlap and forwarding data | 760 | 5% | 175 | |
| The walker and the head's translation | 588 | 4% | 253 | `u_ptw` 451, of it the walk's PMP check of the page (`leaf_q[ph]`) 190. |
| Forwarding's youngest select | 489 | 3% | 19 | `m2_foh_q`: the forwarding search and its carry-chain youngest select. |
| The queues' LUTRAM fields | 246 | 2% | — | Plus 768 LUTRAM cells. |
| Store prefetch | 61 | 0.4% | 111 | |
| Other | 826 | 6% | — | Wakeups 100, exceptions 83, the M1 and M2 registers, the store's clash with the M1 load 60. |

The address comparisons. A compare's LUTs carry the name of the register they feed, so they sit inside the rows above. q_cam_cost counts the first-level LUTs that the address flip-flops feed:

| Search | Compared | Entries | Ports | First-level LUTs |
|---|---|---|---|---|
| Forwarding, in M1 | PA[33:3] (31 bits), plus one bit for the store's state, window and byte overlap | 20 (SQ) | 1: the M1 load | 234 (11.7 an entry) |
| Ordering, at STA | PA[33:3] (31 bits), then the byte overlap from PA[2:0] and the size | 24 (LQ) | 1: the store address | at most 457 (19.0 an entry, counting `lq_pa_q`'s other readers) |

- The reductions run on carry chains: the second level is only 14 and 1 LUTs. Every other comparison is scalar.
- **Per-thread selects** have no family of their own; they fold into their consumers.
  - The largest are the PMP descriptor selects, about 1.2K cells. Each picks its thread's 8 descriptors of about 70 bits.
  - Hart 1 cost the LSU +987 LUTs a core (hz0 → hn0, above).

**2. Rename** (core 0: 5,261 LUTs, of them 1,296 LUTRAM; 5,399 LUT cells, 3,284 FFs):

| Part | LUT cells | Share | FFs | LUTRAM cells | What's in it |
|---|---|---|---|---|---|
| The free lists: three integer banks, two FP banks | 1,369 | 25% | 345 | 160 | 267–284 each: the LUTRAM's write selects 102, each thread's pointers and counts 146 (two copies), the pop index 13, init 6 |
| The free lists' inputs and the transfers' wants | 126 | 2% | 6 | — | |
| The two rename registers' 2:1 select, into DS | 791 | 15% | 789 | — | 572 cells of it select payload that rename never reads: imm, pc, pred_npc, br_target, insn |
| The two rename registers | 10 | — | 1,614 | — | 1,144 of their FFs hold that payload |
| Their choice, decode's take and each thread's room | 324 | 6% | 11 | — | `acc_o` 249, `de_take` 64 |
| Wakeup tags and LLT allocation | 536 | 10% | 80 | — | `wid_alloc` 255, `llt_busy_q` 166, `llt_tid_q` 65 |
| Integer map | 442 | 8% | 71 | 384 | |
| FP map | 441 | 8% | 71 | 384 | |
| In-group bypass and the issue queues' dependency vectors | 402 | 7% | — | — | `iq_dep` 222, `iq_mdep` 180 |
| Rename's results into DS | 369 | 7% | 208 | — | dst, rob, wid, sq, lq, llt |
| Ready tables | 281 | 5% | 14 | 240 | |
| Per-thread tails, counters and blocks | 194 | 4% | 75 | — | |
| MX row tables | 102 | 2% | — | 208 | |
| Port and bank steering | 12 | — | — | — | Only the IQs' write enables. The choices land in DS's fields and in `acc_o`, and the room checks in the free lists' counts. |

**Duplicated per thread:**
- the two rename registers (1,614 FFs);
- their 2:1 select (791 cells), rename's widest multiplexer;
- the free lists' pointers and counts: two copies in each of five lists, about 730 cells;
- each thread's room for decode (249);
- the per-thread tails and counters (194);
- the tags' thread owners (83).

The transfers themselves are small.

**3. The PMP bound** (ex2: scratch branch `claude/spikes-2-explore-pmp` at c24edecf, never merged and never simulated). It stubs the fetch and load checkers and their descriptor selects. The store-address and walker checker stays.

| | ex1 (main e6691d53) | ex2 (stubbed) | Change a chip |
|---|---|---|---|
| LUTs after synthesis | 122,482 | 118,726 | **−3,756** |
| LUTs after `opt_design ExploreArea` | 117,956 | 114,513 | **−3,443** |
| FFs after synthesis | 67,258 | 67,150 | −108 |
| Estimated WNS on the core clock after synthesis (ns) | −0.927 | −0.927 | 0 |
| ... after `opt_design` (ns) | −0.927 | −1.235 | −0.308 |

- **Where it comes from:** ex1n's fetch checker (584) and its select (592), and the load checker (557) and its select (565). That is about 2.3K cells, or about 1.9K LUTs a core at the LSU's packing.
- **The WNS estimates can't see it.** Before placement, the worst path in both builds is the uncore PLIC's priority tree (37–38 levels), which DR-180's release PLIC removes. The −0.308 ns is opt_design remapping that tree.
- **Placed, the PMP doesn't limit timing.** In hp1f its nearest families had +0.41 ns (fetch's `f2_pmpd_q`, 18 levels) and +0.84 ns (the CSR file's `pmpcfg`). Its lever is area.
- **It is an upper bound by construction.** The stubs also fold the TLBs' cached-PMP paths and the access faults, which a check-at-fill design keeps.

**Where the real levers are (my read):**
- **The PMP is the largest no-IPC item found.**
  - A core has three checkers, each with its own select of its thread's descriptors. With the CSR file's descriptor precompute (about 310), that is about 3.8K cells, or 3.1K LUTs, about 6% of a core.
  - The walker already checks each page's PMP homogeneity, and the TLBs cache the result.
  - A design would check at TLB fill and keep one shared checker for untranslated accesses (M-mode, bare) and pages that aren't homogeneous. The store and walker checker already serves two paths.
  - It is bounded at 3.4K LUTs a chip after `opt_design`. A real design keeps a fallback path, so perhaps 2.5–3K.
  - IPC: only M-mode and bare accesses (OpenSBI's) would take the slower path; Linux's are translated. This is for core-2 to design and measure.
- **Rename's payload.** 286 bits a slot ride through both per-thread rename registers and DS: 1,144 + 572 FFs and 572 cells of the 2:1 select a core.
  - The fix: carry the payload beside rename (decode writes it into a per-thread LUTRAM queue that DS reads), or recompute br_target (pc + imm) where it's used.
  - It could save up to about 1.7K FFs and 0.5K LUT cells a core, less the queue's LUTRAM.
  - The FFs count, since the chip is CLB-bound (DR-180).
- **Worth a look, no lever yet:**
  - the D$'s two wide data selects (the load's hit-way dword 468, the victim and probe data 384);
  - the LQ entries' next state (1,054 cells, 44 an entry).
- **Not levers:**
  - the address CAMs (about 0.5–0.7K, already on carry chains);
  - the store prefetch (61);
  - the free lists' transfers.

Results: `fpga/spikes/results/h100_ex1_synth/`, `h100_ex1n_synth/` and `h100_ex2_synth/`; the queries' outputs in `explore/` there (cell groups, per-unit utilization, CAM cost, the A/B), from [`q_cell_groups.tcl`](../../fpga/spikes/tcl/query/q_cell_groups.tcl), [`q_util_hier.tcl`](../../fpga/spikes/tcl/query/q_util_hier.tcl), [`q_cam_cost.tcl`](../../fpga/spikes/tcl/query/q_cam_cost.tcl) and [`q_explore_ab.tcl`](../../fpga/spikes/tcl/query/q_explore_ab.tcl); categories by [`unit_categories.py`](../../fpga/spikes/scripts/unit_categories.py) with `lsu_categories.json` and `rn_categories.json`.

## 9. S1: PL → PS DDR latency and bandwidth

**Status: done on the board (2026-10-14).** The bitstream meets 200 MHz (WNS +0.809 ns with the fan rule of DR-129; +0.513 before it; 4,081 LUTs, 5,133 flip-flops, one block-RAM tile), and the board session ran it at 200 MHz. The design, the A53 program and the step-by-step instructions (SD image, boot firmware, network, files, commands) are in [`fpga/spikes/s1/README.md`](../../fpga/spikes/s1/README.md).

**What it measures.**
- **Latency**, in 5 ns core cycles at the PL port, from the read-address handshake to the first data beat: what the L2 sees on a miss.
  - Idle: dependent 64 B reads (a random pointer chase written by the A53), within one 2 MiB page and over 256 MiB; 16 B reads; both HP ports.
  - Under load: the chase while the other HP port streams reads or writes, and while four A53 threads copy memory.
- **Bandwidth:** sequential 64 B and 256 B bursts with 1–32 outstanding, random 64 B reads, writes, and both ports at once.

**PL design** ([`fpga/spikes/s1`](../../fpga/spikes/s1)).
- **Engines:** two `tg_s1_engine`s, AXI4 masters on S_AXI_HP1_FPD and S_AXI_HP2_FPD, 128-bit at 200 MHz (`pl_clk0` 100 MHz → MMCM).
- **Control:** AXI4-Lite registers on M_AXI_HPM0_FPD at `0xA000_0000`.
- **Fan:** the KV260 fan follows the PS timer's PWM (TTC0 channel 2 through EMIO, DR-129; `tools/tcl/tg_kv260_fan.tcl`), so Linux's fan control stays in charge.
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

**Results on the board** (the board session's run; the full output and the tables are in [`fpga/spikes/s1/README.md`](../../fpga/spikes/s1/README.md), "Results on the board", and `fpga/spikes/results/s1_board/`):
- **Idle latency:** a dependent 64 B read takes **36.8 cycles at 200 MHz (184 ns)** from the PL port. That is the native point that replaces `tgsim`'s 30/60-cycle bracket.
- **Bandwidth:** **3.2 GB/s per HP port, 6.35 GB/s for both ports** together.
- **No DECERR:** PL masters reach DDR through the HP ports with this image; no SMMU bypass is needed.
- **Two fixes came out of the run:**
  - The overlay asked for a 99,999,001 Hz `pl_clk0`. The board's IOPLL is 999,999,990 Hz, so ÷10 gives 99,999,999 Hz, and the clock driver rounded down to ÷11, 90.9 MHz: the engines ran at 181.8 MHz. The overlay now asks for 100,000,000 Hz, and `tg_s1` warns when its wall-clock estimate is more than 3% off 200 MHz and converts with the measured clock.
  - HP2's write stream in the loaded-latency test wrote into the hugepage holding the chase's pointers, so the chase read wild addresses (about two DECERRs per read). The streams now use the last hugepage, which the chase leaves out.

---

## 10. Budget calibration (plan §8.2, §8.5)

**Measured, per core** (out of context, LUTs after routing):

| Structure | Plan §8.2 (ST) | st | smt2 | smt2_w3 |
|---|---|---|---|---|
| Scheduler: every issue queue, W, wakeup delay lines (S2) | 2.9K | **6.4K** (MX; 5.3K without) | **8.9K** (MX) | **12.5K** (MX); 11.0K with 8-row ALU queues |
| Integer register file, bypass, ALUs (S3) | within RF + bypass 4.6K and integer execution 4.0K | 5.2K (RF 2.0K) | 5.2K | 8.7K (3 ALUs, replicated banks; RF 3.3K) |
| Micro-BTB, I$, ITLB, pre-decode, compaction, instruction queue (S5) | within front end 6.1K | 2.5K | 2.6K | 2.5K (`st_w3`) |
| Load path: AG, D$ ways and tags, DTLB, align (S4) | within LSU 6.4K | 2.4K | — | — |
| FPU with Goldschmidt divide/sqrt (FPU track; kept, D17) | 4.7K | 7.6K | 7.6K | 7.6K |

**The scheduler is the outlier, and the FPU the other overrun.** S3, S4 and S5 are within the plan's estimates; S3 at width 3 is under them (+3.5K for the third ALU, its bypass and the fourth bank, against 4.8K planned). The scheduler is 2.2× the plan at st (with MX, which st needs in the full chip, §8), 3.1× at smt2 and 4.3× at smt2_w3:
- **Readiness** is an AND-OR over every column for every row: 40 rows × 104 columns at smt2, 46 × 120 at smt2_w3.
- **The guard's busy vector** ORs every row's dependency bits per column. The alternatives cost more (§4.1).
- **MX adds about 1.2K** (smt2) and is needed for timing at smt2 and smt2_w3. Its row-dependency bits are cleared per column but written per row, so the clear cannot use the flip-flops' reset and takes a LUT per bit.
- **The plan's 2.9K** was an estimate for st. §6.5's +8.3K per core for SMT2 does not itemise the queues. If its +1.9K for sizes was meant to cover the wider columns, the plan's smt2 scheduler would be at most about 4.7K (2.9K × 104 / 64).

**Overrun against the plan** (measured minus planned, per core):
- st +3.5K (with MX);
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

---

## 12. History and lessons

*Kept short and updated with each merge (conventions §10); the coordinator rolls it up into [docs/devlog.md](../devlog.md).*

### 12.1 The scheduler's path (S2, whole scheduler)

Routed at 200 MHz with the pblock unless marked; slack in ns. Each step is a measured result.

| Step | st | smt2 (v1) | smt2_w3 (v2) | What it bought |
|---|---|---|---|---|
| Plan structure: guard, predecoded wakeup IDs, ROB + LLT columns | 6,081 / −0.063 (free placement) | 7,858 / −0.249 | 10,576 / −0.652 (free placement) | — |
| + DUP_SEL, EARLY_W = 24 | 5,307 / **+0.110** | 7,701 / −0.521 | 10,547 / −0.781 | closes st |
| + MX: matrix wakeup for in-queue 1-cycle producers, grant registered before the encode | 6,425 / +0.145 | 8,895 / **+0.112** | 12,515 / **+0.057** | closes smt2 and smt2_w3 for +1.1–1.2K. st needs it too in the full chip: S6 at 76% missed by 0.041 without it |
| + free synthesis settings (hierarchy kept, `AreaOptimized_high`) | — | 7,691 / +0.102 | 11,381 / −0.008 | −13%, no IPC |
| **+ wakeup tags (AR-1):** 16 tags + LLTs, 32–40 columns; no wakeup at select | **4,802 / +0.518** | **5,506 / +0.218** | **7,703 / +0.026** | −25% / −38% / −38%, and the W loop leaves the 1-cycle path |
| + free synthesis settings on tags | **4,228 / +0.226** | **4,750 / +0.392** | **6,669 / +0.094** | −13% again, slack gained: the worst path leaves the wakeup loop for a queue's room counter |
| (option) `EARLY_W` 24 → 8 on that | — | 4,603 / +0.162 | — | −147 LUTs and −720 flip-flops for 0.23 ns: for 180 MHz only (DR-112) |

- **Estimate against measurement:** the plan's §8.2 carried 2.9K for the issue queues. Measured with ROB columns, the scheduler was 1.9× / 3.1× / 4.3× that.
- **Where those LUTs went:** readiness over 104–120 columns per row, the guard's busy vector, and MX's per-column clears.
- **Why tags won:** they removed the columns themselves, which no implementation trick could.

### 12.2 Findings that changed the plan

- **LUTRAM is mapped explicitly.**
  - Behavioural inference of a 64 × 64, 7-read-port memory gave 63 RAM64M8 plus 7 RAM64X1D.
  - Explicit primitives with port-major slot packing give 64, and a 9-port bank 83, not 2 × 64. So bank replication for 3 ALUs costs +1.25K, not the planned +2.7K, and R11 saves only 0.74K.
- **Dropped read ports.**
  - `opt_design` silently removes a read port with no load (64 → 55 RAM64M8 in the first test). The primitive check exists for this.
  - In the real core, eight such "failures" were payload fields nobody reads. The check now counts only primitives holding a loaded bit: unread fields pass and are reported, and a primitive missing for a used bit still fails.
  - Trimming is not all done by `synth_design`: the FPU's divider queue still had its unloaded primitive after synthesis. The check accepts the range from the loaded primitives to the full mapping, so it gives the same verdict at both stages.
- **The pblock method.**
  - Out of context, Vivado placed some runs far from the clock source: clock insertion was 2.3–2.5 ns instead of 1.5–1.8, and up to 1.2 ns of slack was lost.
  - Every run since is constrained to clock regions X0Y2:X1Y3. Even so, results move by ±0.1–0.3 ns between runs, so margins under 0.3 ns are marginal.
  - R8's −0.614 ns "failure" was such a placement artifact; it reran at +0.004.
- **The fill test (S6).**
  - v1 holds 200 MHz from 79% to 88% fill with no trend: +0.043 / +0.105 / +0.007 ns.
  - The limits are the protected loops, not congestion (level 5 at 88%). v2 at 89% ran at 191 MHz.
  - The synthetic filler is local wiring, hence the planning limit of 85% with a ceiling of 88–90%.
  - **At 180 MHz with wakeup tags** ([area_synth.md](area_synth.md) §5; measurements only, since a 180 MHz target is the user's decision, DR-137): v1 closes at 93.4% and 95.3% fill, v2 at 90.0%, 94.2% and 96.0%, all with +0.05 to +0.14 ns and no trend with fill. The limits are S3's ALU loop, S5's IF2 → IF3 step and S4's M2 stage, not the scheduler and not congestion. So at 180 MHz v1 fits at least 111.6K LUTs (95.3%), against about 103K (88%) at 200 MHz.
  - **Without tags, v1 did not route at 93.4%** in over 2 hours; with tags the same fill routed in 15 minutes. Tags matter for routability as well as for LUTs.
  - **At five clocks** ([area_synth.md](area_synth.md) §5.1, 2026-10-15; measurements for the user's clock decision, DR-137): v1 with tags closes the whole device (99.3%, 116.3K LUTs) at 150, 160, 170 and 180 MHz, and about 94% at 200 MHz (93.4% closes by +0.037 ns; 95.3% misses by 0.037 on a harness path). A lower clock buys about 7K LUTs, all of it by 180 MHz.
- **Floorplanning the real core (§8.2, 2026-10-15).** Neither a compact block nor one pblock per unit closes the st core at 200 MHz (−5.235 and −5.536 ns against −5.353 re-placed without pblocks). Its worst paths are 25–26 levels deep at only 0.23 ns of wire per hop, so 200 MHz needs about half the depth, not shorter wires.
- **min/max off the 1-cycle ALU.** With them, 2 ALUs had +0.014 ns under the pblock and 3 ALUs failed (−0.086). Without them the 2-ALU loop has +0.47 and 3 ALUs close.
- **The real core's first synthesis (82.5K LUTs, st).** Seven PMP checkers take 21.8K of it, a quarter of the core. Keeping the hierarchy alone took 5.5K off the flattened 88K.

- **Shared primitives for the FPGA-friendly rewrite (2026-10-14; [fpga_friendly.md](fpga_friendly.md) §3.1).**
  - Multi-write LUTRAM (`tg_ram_lut_mw`) with the live-value table itself in XOR-coded LUTRAM: 4–7× fewer LUTs than flip-flop arrays, and cheaper than the classic flip-flop table at 23 of 24 shapes.
  - A LUTRAM CAM pays only with one-bit-write tables (RAM64X8SW): 13–22% fewer LUTs than flip-flops from 32 entries. With read-modify-write tables it costs more than flip-flops.
  - A DSP48E2 compares for no LUTs (15–40 in fabric). A shift-register FIFO up to 16 deep costs half a LUT per bit once placed (two 16-deep shift registers share a LUT), 25% below LUTRAM; from 32 deep LUTRAM is cheaper.

### 12.3 Dead ends

| Tried | Result | Why it failed |
|---|---|---|
| PRE_RDY (registered ID readiness) | −0.363 against +0.057 (smt2_w3) | It moves the readiness AND-OR into the cycle of the registered grant's wakeup encode: 10 levels |
| ISS_REG (issued bit from a replicated register) | +0.055 / +0.054, no gain | The level it removes is within run-to-run noise |
| Phase bit for stale dependencies | deadlocks; +780 LUTs per queue | Unsafe for pooled LLTs: a tag reused twice while a row waits wraps the phase (`tb_iq` found it) |
| Column clear instead of the guard | +425 LUTs per queue | One LUT per dependency bit; the flip-flops' resets cannot be shared |
| R8 (EX-only bypass) | saves 51–305 LUTs, no faster | The write-through puts the RF write data on the ALU's slowest path |
| R11 (shared RF read ports, 3 ALUs) | −0.71K, −0.323 ns | Arbitration lengthens the select loop, for little area |
| `AreaOptimized_high` without the kept hierarchy | −0.265 ns | It restructures the wakeup loop across module boundaries |
| No matrix in the STA and FP queues | −403 LUTs | Invalid once wakeup tags are adopted |
| Predecoded delay-line IDs | +20 LUTs | Nothing to gain at 4–10 sources |
| Fully associative flip-flop micro-BTB (S5 fallback) | +1.1K LUTs, slower | LUTRAM wins on both counts |
| Aligning loads in M1 (S4) | +0.43K for +0.11 ns | Not worth it; M2 alignment passes |
| CAM tables written by read-modify-write (`tg_cam_lut` `"m16"`) | +9 to +69% LUTs against a flip-flop CAM | The per-bit update logic of every table costs more than the comparators it replaces; the one-bit-write form (`"sw"`) has none and wins |

### 12.4 Bugs and method lessons

- **S1 histogram lost update.** The BRAM is read-first, so a read misses the write at its own clock edge, not only the one still in flight. A reference histogram in the testbench found it.
- **Testbenches.**
  - A static initializer inside a loop tested one ALU op instead of all of them.
  - The system Verilator (5.020) runs `tb_iq` differently from the pinned 5.052, so the Makefiles now refuse to run without `tools/env.sh`.
- **S6 sizing.**
  - An unsigned 27 × 18 multiply took two DSPs.
  - A per-tile LUT cost measured before that fix misled the first fill runs.
  - The spikes measure the same inside S6 as out of context, within 2%, which validates the out-of-context budget numbers.
- **Synthesis-only implicit nets (2026-10-17).** A name used inside a generate block before its declaration is a new, undriven net in Vivado (INFO Synth 8-11241, WARNING Synth 8-605 and 8-3848), while Verilator resolves it, so neither lint nor any simulation catches it.
  - It tied off rename's free-list pop from fn6 to 24ada50, which skews the G4 refresh through G6 (§8.6).
  - The flows now fail on it ([`synth_check.tcl`](../../fpga/spikes/tcl/synth_check.tcl)) and list the Synth 8-6901 forward references, which Vivado resolves.
  - A port connection to a name declared later makes the same undriven net even at module scope (the FPU track's `de_state` in 470e9f9: Synth 8-11241, then 8-8895).
  - The core track's `fwdref.sh` finds the generate-block case without Vivado, from Verilator's JSON view, in about 7 s, and the G7 rerun runs it before synthesizing. It lists the module-scope case only as a forward reference, so the synthesis check is what catches that one.
- **Placement noise (G7 and G8, 2026-10-17).** Between two runs of identical uncore RTL, the uncore's worst slack moved 0.37 ns (G7). Two placements of one whole netlist differed by 1.5 ns of WNS, 15 times in TNS and 6 times in failing endpoints (G8). So a single placement at 94% fill ranks two trees only by differences well over 1 ns. A second sample needs a perturbation the placer responds to, such as 0.05 ns of clock uncertainty: Vivado has no seed, and Explore converged to Default's placement.
- **Machine sharing.**
  - `vivado_run.sh` waiters lose slots to fresh launches. The track now runs fair-share workers that use one slot while others wait, launch the moment a slot is free, and run from snapshots of committed HEAD.
  - Never edit a running bash script: hand over to a new runner instead.
  - **Memory, not slots, is the limit (2026-10-14).** A synthesis with the hierarchy kept forks one Vivado process per thread, so a job's memory is the parent plus its children. Two full-device S6 runs (8–10 GB each) and a budget synthesis with 8 threads (14.5 GB) exhausted the host, and the kernel killed an S6 run (rc 137) after 19 minutes of thrashing. The spike flow now synthesises with 2 threads (`TANAGER_SYNTH_THREADS`), and the workers declare 15 GB per S6 run and 4 GB per out-of-context run to `vivado_run.sh`. The 15 is measured: sampled over the whole process tree, an S6 synthesis at 90–96% fill peaks at 12.9–14.3 GB, while Vivado's log, which shows only the parent, suggested 10 ([area_synth.md](area_synth.md) §6).
  - A worker that is killed leaves its Vivado job running: adopt it or kill the job by its own PIDs, never by a pattern your own shell's command line also matches.
  - A worker's job count must count jobs, not processes: a running `vivado_run.sh` forks subshells with the same command line, and counting those held the track to one job at a time (2026-10-15).
- **Disk.** Verilator objects reached 4.2 GB; tests now keep only their logs.
- **S1 on the board.** A clock request just below the reachable rate rounds down a whole divider step (100 MHz asked as 99,999,001 Hz gave 90.9 MHz); ask for the round number and check the measured clock. And a test's own write stream can corrupt the data its latency probe walks: keep them in disjoint pages.
- **Primitive models.** Hand-written models of vendor primitives can share the author's misreading. The DSP48E2 mapping ran on the vendor's own model under Icarus, which Verilator cannot compile, and found that the 48-bit carry out means "no borrow".
- **Reports.**
  - `report_utilization -hierarchical` hides instances under 50 cells by default, which silently dropped half the price run's instances.
  - `report_utilization -pblocks` takes one pblock: given seven, it failed a floorplan run after routing. The floorplan flow now writes the routed checkpoint before any report.
  - On UltraScale a LUT's `PRIMITIVE_GROUP` is `CLB`, so filters on `PRIMITIVE_GROUP == LUT` match nothing (S6's per-block region counts were empty); `PRIMITIVE_TYPE =~ CLB.LUT.*` and `CLB.LUTRAM.*` work.
- **Synthesis counts are not placed counts for shift registers.** Before placement each SRL16E takes a LUT; placement pairs them, so a 16-deep shift-register FIFO costs half of what the synthesis count says.
