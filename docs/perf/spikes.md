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

**DR-181: the floorplan in the board's flow.** The coordinator adopted `g4_uncore` for the board's product builds; soc-2 wires it into `build.tcl` and spikes-2 keeps it tuned. [`fp_lib.tcl`](../../fpga/spikes/tcl/fp_lib.tcl) adds two checks for every product build:
- `tg_fp_check`, after the floorplan and before `opt_design`: each pblock's LUT cells against its LUT sites. It warns above 105% and calls the pblock tight above 115%.
- `tg_fp_check_placed`, after `place_design`: each pblock's own LUTs against its sites. It warns above 85% and calls the pblock tight above 90%, which means resize it. It also logs IS_SOFT and the share of the pblock's own LUT cells placed outside it.

| Pblock | LUT sites | hp1f before `opt_design` | hp1f own after placement | hp1f outside | Main e6691d53 with the product windows, before `opt_design` |
|---|---|---|---|---|---|
| `l2b0` (L2 bank 0) | 6,400 | 95% | 73% | 20% | 94% |
| `l2b1` (L2 bank 1) | 6,400 | 101% | 77% | 15% | 102% |
| `xbar` (the crossbar) | 4,032 | 52% | 45% | 28% | 72% |

- **The two thresholds agree.** After `opt_design` and LUT packing, a pblock's own LUTs came to 76–87% of its estimate, so 105% before `opt_design` is about 80–90% own after placement.
- **The product windows** grow the crossbar's pblock from 52% to 72%; the banks barely change.
- **Resizing:** a bank's pblock grows by two SLICE rows (160 LUT sites a row in the X2 column). The crossbar has room in X1.

Results: `fpga/spikes/results/h100_hp1f/` (with `near_families_hp1f.txt`, `urf_chip.txt`, `floorplan.txt`, `congestion.rpt` and `worst_paths.txt`; `fp_checks.txt` from [`q_fp_checks.tcl`](../../fpga/spikes/tcl/query/q_fp_checks.tcl); `pb_spill.txt` and `pb_soft.txt`, the cells outside, from [`q_pb_spill.tcl`](../../fpga/spikes/tcl/query/q_pb_spill.tcl) and [`q_pb_soft.tcl`](../../fpga/spikes/tcl/query/q_pb_soft.tcl)); main's check in `h100_ex1_synth/fp_check_g4_uncore.txt`.

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
