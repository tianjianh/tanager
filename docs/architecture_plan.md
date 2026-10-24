# Tanager: Architecture and Project Plan (draft 0.4)

*A clean-room, 2-wide-decode, out-of-order RV64GC dual-core for the AMD Kria KV260. It is designed to beat NaxRiscv's IPC, to tolerate memory latency well beyond the KV260's, and to grow into SMT or CMT later.*

| | |
|---|---|
| Status | Draft for review. Drafts 0.2 and 0.3 add the design-discussion outcomes of 2026-10-12 (Appendix B). Draft 0.4 adopts the M1 parameter freeze, approved 2026-10-13. |
| Date | 2026-10-13 |
| Companion | [Literature review](../reports/RISCV%20OoO%20soft%20cores%20for%20KV260.md); research notes in `research_notes/` |
| M1 results | [DSE report](perf/dse_report.md); [feature ledger](perf/feature_ledger.md); model in `perfmodel/` (`tgsim`, preset `v1_freeze`) |
| Name | "Tanager" is a working name; rename freely |
| Assumption | "NavRiscV" in the brief means **NaxRiscv** (SpinalHDL) |

Unless a source is cited, every number in this plan is our own estimate, a model result, or a starting point for design-space exploration (DSE). None is a measurement.

**Version names in this plan (from 0.4)**

| Name | What it is | Configuration |
|---|---|---|
| **ST** | Single-thread bring-up stage: 2-wide, 1 hart per core, with the M1 freeze sizes. Not a release. | `st` (`TID_W = 0`) |
| **v1** | **First release:** the SMT2, 2-wide dual-core, 2 cores × 2 harts = 4 Linux CPUs | `smt2` (§6.5) |
| **v2** | 3-wide decode added to the SMT2 core | `smt2_w3` (§4.15) |

**What changed in 0.4 (M1 freeze, 2026-10-13)**
- **First release is SMT2 (D16).** v1 ships 2 cores × 2 harts. Single-thread (`TID_W = 0`) is the bring-up stage for M2–M6, the CI reference and the run-time SMT-off mode; it is not released.
- **Sizes and features come from the M1 freeze.** The acceptance rule was applied to the combined design with `tgsim` (§10.1); §4.14 has the frozen values. The result is +4.6% suite IPC over draft 0.3 for about 3.3K fewer LUTs per core (§8.2). The release adds the SMT2 window of §6.5.
- **Removed from the core:**
  - SFB predication, macro-op fusion, jump folding, the memory-dependence wait table and branch-first select. With TAGE-lite and GCC 15 binaries, none paid for its LUTs.
  - They remain RTL options (§4.3, §4.9).
- **Resized:**
  - ROB 64 → 48;
  - issue queues 12/12/12/8/12 → 10/10/6/4/10;
  - checkpoints 8 → 4;
  - long-latency tags 32 → 16;
  - completion buffer 16 → 8;
  - SQ 16 → 12;
  - L1D MSHRs 12 → 16;
  - L1I MSHRs 2 → 4;
  - micro-BTB 32 → 64 (2-way LUTRAM);
  - TAGE tagged tables 1K → 4K entries;
  - L2 MSHRs 32 → 48.
- **New FP divide/sqrt.** Pipelined Goldschmidt divide/sqrt on DSPs replaces the radix-4 unit (§4.12).
- **Early retirement: GO** (§4.5).
- **3-wide reserve (§4.15, D13).** v1 is finished at 2-wide, and 3-wide decode is planned for v2.
  - Everything that depends on the machine width is a parameter: fetch, decode, rename, dispatch and commit widths, the number of ALU ports, ROB banking, the register-file generator and the bypass network.
  - A 3-wide, 3-ALU build stays in CI, spikes and synthesis checks.
- **MLP criterion restated.** It is now measured on a 16-chain test (§2.5); the 8-chain version could not reach 8 by construction.
- **Roadmap (D14, D15, D16).**
  - **v1:** SMT2, 2-wide (ROB 80, §6.5).
  - **v2:** 3-wide added to the SMT2 core.
  - All on the KV260, with an area-recovery plan (§8.5).
- **CoreMark target restated (D11, decided 2026-10-13).** The target is now **≥ 1.21× the NaxRiscv control on identical binaries**, the ratio that 6.0 vs NaxRiscv's 4.94 implied. 6.0 on standard rv64gc binaries is out of reach at 2-wide decode (§10.2) and moves to the 3-wide version.
- **FPGA spikes S2–S6 measured (2026-10-13; §4.6, §4.8, §8.1, §8.2, §8.5).**
  - **Timing:** every protected loop closes 200 MHz. The SMT2 builds need the MX wakeup, and min/max moves to the 2-cycle path.
  - **Fit:** the scheduler and the FPU are over budget, so v1 measures 99–110K LUTs after area recovery, against a fill ceiling of about 88% at 200 MHz. v2 does not fit as planned, which triggers the area-recovery study.
  - **FPU:** Goldschmidt is kept by user decision D17, with radix-4 as the fallback.
- **Schedule re-estimated for an agent-built project (§11, D8).** The years-long estimate assumed people writing the RTL. With agents writing it, tool runtime, the board and fixed-length tests set the pace: Linux on the board in about 4–6 weeks, v1 in about 3 months.

**What changed in 0.3**
- The latency rule is reframed as **efficient latency tolerance** (§2.5): the 120-cycle target must not justify blind widening or ROB growth.
- **Four latency points:** native KV260, 90, 120 and 250 cycles.
- An **acceptance rule** and a **feature ledger**: every feature or size increase must show IPC gains in proportion to its area, timing and complexity cost.
- Testable definitions of "effective latency hiding" and of the eight-concurrent-miss target.

**What changed in 0.2**
- CoreMark target raised to **6.0/MHz**, with benchmark rules.
- **Short-forward-branch predication and jump folding** move into v1.
- The minimum mispredict penalty target drops to **9 cycles**.
- **Early retirement** (inspired by the Cortex-A73) gets its v1 hooks and a model-driven go/no-go.
- Latency-hiding structures are judged at a 120-cycle DRAM round trip, not the KV260's ~30–60.
- New hardware **latency injector**, so the board can emulate longer latency.
- L2 defaults to 1 MiB.
- Fetch-directed I$ prefetch and an L1D stride prefetcher move into v1.

---

## 0. Summary

**What we build.** Two out-of-order RV64GC cores with Sv39 share a coherent 1 MiB L2 in UltraRAM. They sit in the KV260's programmable logic and use the processing system's DDR4. The A53 cluster acts as host: it loads images, bridges the console, serves virtio back-ends and runs a lockstep checker.
- **First release (v1):** each core runs **two hardware threads (SMT2)**, so the release has 2 cores × 2 harts = **4 Linux CPUs**.
- **Bring-up:** goes through a single-thread stage (ST, thread-ID width zero) first.
- **Next release (v2):** adds 3-wide decode to the SMT2 core.

**Design stance.**
- **Win on slot efficiency, not width.** Keep the 2 decode slots full with a strong front end and few, cheap mispredicts. M1 showed that a zero-bubble micro-BTB and TAGE-lite carry this; fusion, predication and jump folding did not pay with this predictor and compiler (§4.3).
- **Win on latency tolerance.** Keep working under cache misses: early retirement, many outstanding misses, prefetching.
- **Tolerate latency efficiently.** The same RTL must keep its advantage on a faster FPGA (or an ASIC port), where DRAM is several times more cycles away. But nothing grows just because memory is far: every feature must pay for its area, timing and complexity (§2.5).
- **Finish 2-wide, reserve 3-wide.** v1 is 2-wide. Every width-dependent structure is a parameter and a 3-wide build is kept working, so the planned 3-wide version is a configuration change plus timing closure and verification, not a redesign (§4.15).

**Why it should beat NaxRiscv.** NaxRiscv's documented economies, and the Tanager answer to each:

| NaxRiscv economy | Tanager v1 (M1 freeze) |
|---|---|
| 4 KB gshare, 512-entry direct-mapped BTB | Zero-bubble 64-entry micro-BTB, block BTB, TAGE-lite of about 29 KB (BRAM), repaired RAS, fetch target queue (FTQ) |
| Branch recovery at commit; 10-cycle penalty is the best case | 4 rename checkpoints; recovery at execute; 9-cycle minimum penalty |
| One unified 32-slot issue queue that never compacts | Five distributed, age-ordered issue queues (10/10/6/4/10) |
| One pipe shared by load, store, mul/div and CSR | Separate load, store-address and mul/div ports; store data captured in the store queue |
| A predicted hit that misses flushes the whole pipeline | Speculative wakeup; only the 2-cycle load shadow is cancelled |
| Every instruction holds its ROB entry until it completes | Early retirement of loads and long operations once they cannot fault |
| 2 refill slots, 16 KB L1s, no prefetcher documented | 16 L1D MSHRs, 32 KiB L1s, fetch-directed I$ prefetch with 4 I$ MSHRs, stride and stream prefetchers, 1 MiB L2 with 48 MSHRs |
| (FPU divide/sqrt not documented) | Pipelined Goldschmidt divide/sqrt on dedicated DSPs |

The M1 model puts the gain at 1.62–1.69× the suite IPC of a NaxRiscv-like control at every DRAM latency point, on identical binaries and the same memory system ([DSE report](perf/dse_report.md)).

**Headline targets.** All comparisons use identical binaries and the same memory system as a NaxRiscv control run.

| Metric | NaxRiscv | Tanager target | M1 model (v1 freeze) |
|---|---|---|---|
| CoreMark/MHz vs the NaxRiscv control on identical binaries (EEMBC-valid runs, both flag sets, rules in §10.2) | 1.00 | **≥ 1.21×** (D11; = 6.0 / 4.94) | 1.46× / 1.34× (rv64gc, flag sets A / B), met |
| CoreMark/MHz, absolute (reported, not a target) | 4.94 (modified CoreMark) | 6.0 is the 3-wide version's target | 2-wide: 5.31 / 5.16 (rv64gc), 5.86 / 5.70 (rv64gcb)<br>3-wide build: 6.08 / 5.92 (rv64gc) |
| DMIPS/MHz (-O3 -fno-inline) | 2.94 | ≥ 3.2 | 3.98 |
| Embench-IoT score | 1.84 | ≥ 2.0 | 2.49 (soft float, comparable build) |
| IPC ratio vs the NaxRiscv control, Linux/SPEC-like suite geomean, at KV260 DRAM latency | 1.00 | ≥ 1.15, no benchmark below 1.0 | 1.62–1.67 (30–60 cycles); worst benchmark 1.00 |
| The same ratio at 90, 120 and 250 cycles of DRAM latency | — | ≥ 1.15 at each, and not below the native-latency ratio | 1.68 / 1.68 / 1.69 |
| Concurrent demand L1D misses at 120 cycles (§2.5) | 2 refill slots | ≥ 8 on the 16-chain test; ≥ 95% of 8 on the 8-chain test | 15.65; 7.88 (98.5%) |
| SMT2 throughput (weighted speedup vs the same core running one program at a time) | — (1 hart per core) | ≥ 1.3× at every latency point until DR-184 (10-21); now step 7's measured result (about 1.2×), with no pair hang and no loss for one thread alone | 1.36 / 1.43 / 1.45 at 30 / 120 / 250 cycles |
| LUTs per core (FPU, MMU, L1s included) | 17.9K (RV64, no FPU) | ≈ 38K single-thread; ≈ 46K for the SMT2 release before area recovery (§8.2, §8.5) | — |
| Dual-core SoC Fmax on XCK26 | — | **100 MHz** since DR-152 (10-17), with a lower board clock only as the very last resort (DR-177). The first goal was 200 MHz with a 150 MHz floor. | — |
| SMP | Dual-core Debian at 100 MHz | Debian 13 on 4 harts (2 cores × 2 threads); 72-hour stress clean | — |

The IPC rows are single-thread results, from the ST configuration; the release core runs one program with SMT off about 2.5% faster than ST.

**About the M1 model column.**
- The model suite (CoreMark, Dhrystone, Embench, memory kernels) stands in for the Linux/SPEC-like suite until that exists (§10.2).
- These are model results to be checked against RTL counters (M2–M6).

---

## 1. Goals, non-goals, success criteria

**Goals**
- **G1 IPC:** higher IPC than NaxRiscv on identical RV64GC binaries, by the margins in §0, including CoreMark/MHz ≥ 1.21× the NaxRiscv control (D11).
- **G2 Linux:** SMP Linux on the KV260 with a Debian-class userland (RV64GC, lp64d), on 4 harts (2 cores × 2 threads).
- **G3 Fit:** the dual-core SoC fits the XCK26 at about 80% LUT utilisation or less, and closes timing at ≥ 150 MHz (goal 200).
  - **v1 (SMT2):** this holds for the release. §8.5 is how it gets there.
  - **v2 (SMT2 + 3-wide):** it stays on the KV260 too. Its limit is 85% as the working assumption, up to 90% if the S6 fill test shows timing still closes (§8.5).
- **G4 Threading:** SMT2 ships in v1. Thread-scoped flush, age, memory ordering and translation are designed in from the first commit. CMT stays possible through the queue-decoupled interfaces (§6).
- **G5 Clean room:** every line of RTL is ours.
- **G6 Verifiability:** commit-level lockstep against a reference model, at every stage, in simulation and on the FPGA.
- **G7 Efficient latency tolerance and portability:**
  - Effective latency hiding at a **120-cycle DRAM round trip**, evaluated at native, 90, 120 and 250 cycles (§2.5).
  - Every feature or size increase passes the acceptance rule (§2.5). No blind widening, and no ROB growth for its own sake.
  - The KV260's shorter latency is a deployment condition, never a sizing argument.
  - Nothing specific to the KV260 or its processing system leaks into the core or the L2.
- **G8 Width readiness:** 3-wide decode can be added without redesign. All width-dependent logic is parameterized, and a 3-wide build compiles, passes the ISA tests and lockstep, and is synthesised for cost (§4.15).

**Non-goals for v1**
- 3-wide decode: v1 ships 2-wide. 3-wide is reserved by G8 and planned for v2.
- RVA23 (V and H), so no Ubuntu 25.10+. Debian 13 and Ubuntu 24.04 are in.
- Svadu and Sv48/Sv57.
- Coherence with the A53 caches.
- More than 2 harts per core (4 in total).
- An ASIC port. Portability to faster FPGAs, however, is a goal (G7).

**v1 exit:** every target in §0 is met, plus the full test ladder in §9.

---

## 2. Constraints and assumptions

### 2.1 Platform facts (from the literature review)
- **XCK26 resources:** 117,120 LUTs, 234,240 FFs, 144 BRAM36, 64 UltraRAM (4K × 72 each), 1,248 DSP48E2, and about 3.5 Mb of distributed RAM (we estimate about 57K LUTs usable as RAM).
- **Speed grade:** -2LV with the fabric at 0.72 V, which behaves like a -1 part. BRAM reaches 585/510 MHz, UltraRAM 500 MHz when registered, DSPs 644 MHz.
- **No DRAM on the programmable logic.** The 4 GB of DDR4-2400 x64 is reached through PS ports: HP0–3, HPC, ACE and ACP. Each is 128 bits wide, runs at up to 333 MHz, and supports 8 IDs and 16 outstanding transactions.
- **Measured (spike S1, 2026-10-14):** an idle 64-byte read from the PL takes 36.8 cycles (184 ns) at 200 MHz, from the read-address handshake to the first data beat. Each HP port sustains 3.2 GB/s, and two together 6.35 GB/s. It informs the KV260 build, not the sizing (§2.5).
- **I/O:** the programmable logic reaches only one Pmod, the fan pin and the MIPI connectors. Console, Ethernet, SD and USB belong to the PS. Clocks come from the PS `pl_clk` outputs through an MMCM.
- **Tools:** Vivado 2025.2 supports the XCK26 for free. Vivado 2026.1 uses tiered licences; a one-year CORE voucher ships with Kria kits.

### 2.2 Linux facts
- **Kernel + Buildroot need:**
  - RV64IMA + Zicsr + Zifencei, M/S/U modes, Sv39;
  - ACLINT, PLIC and a UART;
  - SBI TIME, IPI, RFENCE and HSM, through the OpenSBI generic platform.
- **Debian 13 needs** RV64GC with lp64d.
- **PMP and ASIDs:** 16 PMP CSRs with at least 8 working entries; 16 ASID bits.
- **Pitfalls to design against:**
  - never cache invalid PTEs;
  - WFI wake rules;
  - mtval vs stval under delegation;
  - misaligned LR/SC;
  - MPRV clearing on return;
  - satp must ignore writes of unsupported modes.

### 2.3 Clean-room policy
1. All RTL is written by us from our own unit specifications in `docs/spec/`.
2. Each spec records the source of every borrowed idea (paper, documentation or public spec).
3. Nobody reads another core's RTL for the unit they are designing. Parameter values already extracted into the notes are facts and may be used.
4. Public interface specs are implemented as written: the RISC-V ISA and privileged spec, Debug, PLIC, ACLINT, SBI, TileLink semantics, AXI4, virtio-mmio, and the 16550 register map.
5. Third-party tools and software are used as-is: Spike, Sail, Verilator, GCC/LLVM, OpenSBI, Linux, TestFloat, OpenOCD.
6. NaxRiscv runs unmodified, and only as a benchmark control.
7. Vendor primitives and XPM memory macros are allowed.

### 2.4 Working assumptions (decisions in §13)
- **HDL:** SystemVerilog-2017, the subset that both Verilator 5 and Vivado accept.
- **Host:** the A53 cluster runs stock Ubuntu or PetaLinux and acts as host and debug helper.
- **Team:** Claude agents write the RTL, tests, scripts and host software, in parallel sessions where the work splits cleanly. You review and decide, and handle the AMD account, the Vivado install and the board setup.

### 2.5 Design principle: efficient latency tolerance

**Motivation.** At 100–200 MHz, FPGA CPUs see relatively low DRAM latency in CPU cycles, which makes small out-of-order windows look sufficient. That can hide architectural limitations that would show up at higher frequencies, where a DRAM access may take hundreds of CPU cycles. It also cuts the other way: at low latency, latency-tolerance features look worthless in a design sweep and get cut for the wrong reason.

**Goal.** A Linux-capable out-of-order RISC-V core targeting 6.0 CoreMark/MHz, with effective latency hiding at 120 cycles of DRAM latency. Performance is evaluated at native KV260 latency and at 90, 120 and 250 cycles, and must show a sustained IPC advantage over NaxRiscv and at least eight concurrent cache misses.

**Design constraint.** The 120-cycle target must not justify blindly widening the pipeline or enlarging the ROB and other structures. Optimizations must show meaningful IPC gains relative to their area, timing and complexity costs. The goal is efficient latency tolerance, not complete latency hiding at any cost.

| Latency point | DRAM round trip (core cycles) | Represents | Role |
|---|---|---|---|
| Native | **36.8 cycles idle (S1, 2026-10-14)**; expected 30–60 | KV260 at 150–200 MHz | Deployment numbers; no regression allowed |
| 90 | 90 | A faster-FPGA build (about 300–400 MHz) | Shape of the curve |
| **120** | 120 | Design margin | **Decision point** for features and sizes |
| 250 | 250 | ASIC-class stress | No cliffs |

Latency is the full round trip of an L2 miss to DRAM, seen from the L2, in core cycles. On the board, the injector (§5.6) adds the difference between the target and the measured native latency. `tgsim` models all four points, and NaxRiscv's control runs at all four.

**Effective latency hiding: pass/fail criteria**
1. **Sustained advantage:** the IPC ratio to NaxRiscv (suite geomean, identical binaries, same memory system and injector setting) is at least 1.15 at every point, and no lower at 90, 120 or 250 than at native.
2. **Eight concurrent misses:** at 120 cycles, at least 8 demand L1D misses in flight on the pointer-chase test with **16 independent chains** and no work between hops. Also, at least 95% of 8 on the 8-chain test.
   - **What is measured:** time-averaged in steady state, prefetches excluded. Both tests exercise the memory pipeline: MSHRs, LQ and long-latency tags.
   - **Why the 8-chain test was restated in 0.4:** each chain spends about 2 cycles between a fill and its next miss, so its time average can approach 8 but never reach it (7.87 at 120 cycles).

**Reported, not pass/fail**
- The 8-chain test with 16 independent instructions between hops.
  - Keeping 8 misses in flight there needs an effective window of roughly 130 instructions, which the ROB alone can't provide.
  - This is where early retirement had to beat simply enlarging the ROB (it did; §4.5).
- Two kernels whose misses have dependent work waiting in the window: a strided column walk and a gather with a dependent hash. They show what the issue queues and ROB, not the MSHRs, allow.
- IPC retention (IPC at each point ÷ IPC at native) for every benchmark. Some loss at 120 is expected and accepted.

**Acceptance rule (the design constraint, made testable).** A feature or size increase is accepted only if all of these hold:
- Its suite-geomean IPC gain at 120 cycles, in percent, is at least its LUT increase, in percent, so performance per LUT does not fall. The LUT increase is measured against the core for per-core features and against the SoC for shared ones, such as the L2.
- It causes no IPC regression at native latency and no new cliff at 250 cycles.
- It lengthens no protected timing loop (§8.1) and keeps BRAM and UltraRAM within budget.
- If it touches recovery, memory ordering or precise state, it ships behind an enable bit and counts only once it passes the verification gates (§9).

Anything below the line needs a written exception, such as Linux compatibility, correctness, or being the cheapest route to the 6.0 CoreMark target. Since performance tends to grow only with about the square root of added complexity (Pollack's rule), big window enlargements will usually fail this test and cheap, BRAM-backed features will usually pass. That is the intended effect.

**How the rule is applied (from M1).**
- **Features** are judged by removing each one from the design (ablation).
- **Sizes** are frozen *on the combined design*, not one parameter at a time. This is the greedy procedure:
  1. Start every structure at the bottom of its range.
  2. Each round, add the increment with the best IPC gain per LUT, provided its gain (%) is at least its LUT cost (%) and it passes the guards.
  3. Stop when none qualifies.
- **Why combined:** M1 showed why this matters. Issue queues and the ROB each looked cheap to trim alone, but trimming both cost 3.2%.
- **Exceptions** need evidence beyond the suite (a targeted kernel) and stay *provisional* until Linux/SPEC-like workloads re-judge them.

**Feature ledger.** [`docs/perf/feature_ledger.md`](perf/feature_ledger.md) records every feature and size choice: IPC at the latency points, LUT/BRAM/UltraRAM/DSP cost, Fmax impact, verification surface, the decision, and any exception. The M1 freeze (2026-10-13) is its first set of entries, and every later change goes through it.

---

## 3. Architecture overview

### 3.1 SoC

```
                Zynq UltraScale+ PS: 4x A53 running Linux                  PS DDR4 (4 GB)
      ┌───────────────────────────────────────────────────────────┐        ┌───────────────┐
      │ tanager-host: loader · console pty · virtio back-ends ·   │        │ A53 Linux     │
      │ lockstep checker · OpenOCD (remote bitbang) · latency cfg │        │ RISC-V carve- │
      └───────┬───────────────────────────────▲───────────────────┘        │ out (1–2 GB)  │
   M_AXI_HPM0 │ control/mailbox (100 MHz)     │ pl_ps_irq                  └───────▲───────┘
 ═════════════╪═══════════════════════════════╪═══════════════════════ PL ═════════╪══════════
              ▼                               │                 S_AXI_HP1/HP2 128b │
  ┌───────────────────────┐   ┌───────────────┴─────────────┐   ┌──────────────────┴────┐
  │ Host bridge: reset,   │   │ MMIO peripherals: boot ROM, │   │ Latency injector      │
  │ mailbox, UART FIFOs,  │   │ ACLINT, PLIC, UART16550,    │   │ (0–1023 cyc, BW cap)  │
  │ virtio windows, trace,│   │ virtio-mmio ×4, debug       │   ├───────────────────────┤
  │ JTAG bitbang          │   │ module, perf/trace          │   │ Shared L2: 1 MiB,     │
  └───────────┬───────────┘   └───────────────▲─────────────┘   │ 8-way, inclusive,     │
              │ coherent DMA into L2          │ uncached        │ 2 banks (UltraRAM),   │
              └───────────────────────────────┼────────────────►│ MESI presence dir,    │
                                              │                 │ 24 MSHR/bank, prefetch│
                                              │                 └───────────▲───────────┘
                                              │                             │ TL-C-style A/B/C/D/E
              ┌───────────────────────────────┴─────────────────────────────┴───────────┐
              │                      core ↔ L2 / MMIO interconnect                      │
              └──────────┬─────────────────────────────────┬─────────────────────────┬──┘
          ┌──────────────┴─────────────┐    ┌──────────────┴─────────────┐  ┌────────┴─────────┐
          │ Core 0 (hart 0)            │    │ Core 1 (hart 1)            │  │ room for 2 more  │
          │ L1I 32K · L1D 32K · MMU    │    │ L1I 32K · L1D 32K · MMU    │  │ agents           │
          └────────────────────────────┘    └────────────────────────────┘  └──────────────────┘
```

### 3.2 Core pipeline

```
 BP0 ─► BP1 ─► BP2 ─┐ (overrides BP0 on disagreement: 2-cycle bubble)
  │uBTB  BTB/TAGE   └─► FTQ (32 blocks; also stores the PCs of in-flight instructions; drives I$ prefetch)
  ▼
 IF1 ─► IF2 ─► IF3 ─► DE ─► RN ─► DS ─► IS ─► RF ─► EX ─► WB … CM
 I$+    way+   compact decode rename dispatch issue read ALU/BR 1    commit / early retire
 ITLB   predec into IQ RVC    +ckpt  ROB/LSQ  select +byp MUL 3      2 uops/cy
               +target expand +LLT   IQ ins.            LD 3 (AG,M1,M2)
                check                                   FMA 5; FDIV/FSQRT pipelined
```

| Stage | Work | Timing note |
|---|---|---|
| BP0 | Next fetch block: redirect, override, micro-BTB hit, or sequential +16 B | **Protected 1-cycle loop** |
| BP1 | Read block BTB, TAGE-lite and RAS tables | BRAM clock-to-out is kept inside its own stage |
| BP2 | Final prediction; override BP0 on disagreement; push the FTQ | 2-cycle override bubble |
| IF1 | ITLB lookup; I$ read (8 ways × 16 B) | A redirect writes the I$ address register directly, skipping BP0 |
| IF2 | Tag compare, way mux, pre-decode (compressed-instruction boundaries, branch and jump marks) | |
| IF3 | Compact whole instructions into the instruction queue; check direct-branch and jump targets early | Early redirect costs about 4 cycles |
| DE | Take `DECODE_WIDTH` (2) instructions from the queue head; expand RVC; decode. Fusion, SFB conversion and jump folding are RTL options, off in v1. | |
| RN | Rename, take checkpoints (4), pop free lists, allocate long-latency tags | |
| DS | Allocate ROB/LQ/SQ entries; insert into issue queues with dependency vectors | |
| IS | Wakeup readiness and oldest-ready select | **Protected 1-cycle loop** |
| RF | LUTRAM register read plus bypass | |
| EX | Execute; resolve branches | **Minimum mispredict penalty: 9 cycles** (EX to the next EX on the correct path) |
| CM | Retire up to 2 micro-ops per cycle; early-retire eligible long operations | |

Merging the old align stage into IF2/IF3 is what saves the cycle against 0.1. Spike S5 must confirm that pre-decode fits in IF2 and compaction in IF3 at 200 MHz. If not, fall back to 10 cycles.

---

## 4. Core microarchitecture

Every size is a parameter. DSE (§10) freezes the values through the acceptance rule (§2.5): decided at 120 cycles, with guards at native latency and at 250.
- **Values:** the values below are the **M1 freeze** (approved 2026-10-13), which is the single-thread configuration (ST). The evidence for each is in the [feature ledger](perf/feature_ledger.md).
- **The release:** v1 (SMT2) uses the same core with the SMT2 window and policies of §6.5: ROB 80 in per-thread halves, LQ 24, SQ 20, 24 long-latency tags, issue-queue caps, ICOUNT fetch. §4.14 lists both.
- **Width parameters:** every width is a parameter too: fetch, decode, rename, dispatch and commit widths, ALU ports, and the banking and port counts that follow from them (§4.15). v1 ships 2-wide with 2 ALUs, and a 3-wide, 3-ALU build is kept working for v2.

### 4.1 ISA and privilege
- **Base:** RV64IMAFDC, Zicsr, Zifencei, Zicntr, Zihpm; M/S/U modes (privileged spec 1.13); Sv39; ASIDLEN 16; 16 PMP entries; physical-address width a parameter (default 34 bits).
- **Day-one extensions:** Zba, Zbb, Zbs, Zicond, Zihintpause, Sstc, Svinval, Zkt, Za64rs.
- **After first boot:**
  - Sscofpmf (perf sampling, our IPC tuning tool under Linux);
  - Svpbmt, Zicbom, Zicboz (fast block zeroing), Zicbop (prefetch hints);
  - Zfhmin (completes RVA22).
- **Misaligned accesses:** trapped and emulated by OpenSBI at first; hardware split within a line in v1.x.
- **A/D bits:** Svade semantics; never cache invalid PTEs.

### 4.2 Front end (decoupled)
- **Fetch:** 16 B aligned blocks, one per cycle. That is about 5 instructions per cycle with RVC, against a decode rate of 2.
- **Micro-BTB:** **64 entries, 2-way, LUTRAM**, partial tags. It predicts the next block in 1 cycle, so taken branches cost no bubble. (The Cortex-A73 manages only one taken branch every second cycle.)
  - **M1:** the micro-BTB is worth +7.5% suite IPC. 64 entries beat 32 by +2.0% for about 100 LUTs.
  - **Timing risk:** its LUTRAM read sits in the next-PC loop, so spike S5 must confirm 1 cycle at 200 MHz. The fallback is 32 fully associative flip-flop entries.
- **Block BTB:** 1K entries, 4-way, BRAM. Each entry describes a 16 B block with up to 2 branch slots (Reinman et al., ISCA 1999).
- **TAGE-lite:** a 4K-entry bimodal table plus **4 tagged tables of 4K entries**, with per-slot counters and history lengths of about 8–64. That is about 29 KB, or 8 BRAM36.
  - **M1:** TAGE-lite is worth +5.8% over a 4 KB gshare.
  - Each doubling of the tagged tables from 1K paid for itself (+0.45%, +0.22%).
  - Global history is checkpointed per FTQ entry and repaired on redirect.
  - **No predictor state may be trained offline on benchmarks** (see Appendix B on SSRV).
- **Return stack:** 32 entries, with top-of-stack repair from FTQ snapshots.
- **Indirect predictor (v1.x):** 256-entry, path-hashed target table.
- **FTQ:** 32 entries in LUTRAM. It holds predicted blocks plus metadata and the PCs of in-flight instructions (the ROB keeps only an FTQ index plus offset). Predictors train at commit from it.
  - **Fetch-directed I$ prefetch (v1):** while the I$ misses, the FTQ keeps running ahead and issues prefetches for the upcoming blocks. This matters more as DRAM latency grows and as kernel code footprints grow.
    - **Evidence:** M1's suite has no large code, so the gain there is nil. On a ~200 KiB-code kernel, I-side prefetch is worth +34%, and 4 instead of 2 I$ MSHRs another +30%.
    - **Status:** kept as exception E1, provisional until Linux traces.
- **I$:** 32 KiB, 8-way, VIPT, 64 B lines.
  - Data in 16 BRAM36, so all 8 ways deliver 16 B in parallel. A way-predicted layout in 8 BRAM36 is the fallback.
  - Tags in LUTRAM.
  - **4 MSHRs**, shared by demand and prefetch. A prefetch may take the last free MSHR only while a demand miss is outstanding.
  - Refills are coherent reads at the L2.
- **Instruction queue:** 16 instructions in LUTRAM, written compacted by IF3. Instructions that straddle a block or page boundary are joined in IF3.

### 4.3 Decode (fusion, predication and jump folding are options)
- **Width:** `DECODE_WIDTH` decoders with RVC expansion; v1 ships 2. Serialising instructions are marked: CSR, FENCE, FENCE.I, SFENCE.VMA, WFI, xRET, ECALL/EBREAK.
- **Width-generic RTL:** decode, rename, dispatch and commit are written width-generic (generate loops, no hand-unrolled 2-wide logic), so a 3-wide build is a parameter change plus timing work (§4).
- **M1 verdict on the slot-efficiency features below.** With TAGE-lite and GCC 15 binaries, none paid for its LUTs. They are **RTL options, off in v1**; keep their hooks cheap, and re-judge them with Linux/SPEC-like workloads.

  | Feature | Suite IPC gain | LUT share |
  |---|---|---|
  | Fusion | 0.14% | 0.98% |
  | SFB predication | 0.17% | 1.2% |
  | Jump folding | 0.01% | 0.24% |

  - **SFB predication:** mispredicting short forward branches are rare. CoreMark saw 78 conversions in 6.7M instructions, and all direction mispredicts together cost it only about 1.5%.
  - **Fusion:** the pairs below hardly occur in hot loops. The frequent pattern is ALU-immediate + dependent branch, which saves no decode slot.
- **Pair-decode option.** A fused pair takes one decode slot. It is worth +1.7% suite IPC and is part of the only 2-wide route to CoreMark 6.0 found (rv64gcb binaries; D11).
- **Macro-op fusion (option),** pairs inside one decode group. A fused pair retires as 2 instructions. If its second half faults, the pair is re-executed unfused.

  | Pair | Fused into |
  |---|---|
  | `lui + addi[w]` | 32-bit constant |
  | `auipc + addi` | PC-relative address |
  | `auipc + ld/lw` | PC-relative load |
  | `auipc + jalr` | Far call |
  | `slli 32 + srli 32` | Zero-extend word |
  | `slli k + add` | Shift-add |
  | `add + ld rd,0(rd)` | Indexed load |
  | `lui + ld` | Absolute load |

- **Short-forward-branch (SFB) predication (option).** CoreMark's CRC and state-machine code is full of data-dependent branches over a single instruction. Predication alone took SonicBOOM from 4.9 to 6.15 CoreMark/MHz, but against a weaker predictor than TAGE-lite.
  - **When it applies:** a conditional forward branch over exactly one shadowed instruction, both in the same decode group.
  - **What the shadowed instruction may be:** a non-faulting ALU op with at most one register source besides its old destination value: `op rd, rs1, imm`, `op rd, rd, rs2`, `li`, `lui`, `mv`, `auipc`.
  - **What it becomes:** a compare micro-op that writes a 0/1 predicate into an integer register, then a conditional-select micro-op: `rd = predicate ? old_rd : op(...)`.
  - **Third operand:** the select needs 3 operands. It issues on P0 and reads the third through the shared store-data read port, where P0 has priority (§4.7).
  - **Which branches are converted:** only those a 64-entry table has seen mispredict often. Well-predicted branches stay speculative, which is faster.
  - **Retire count:** the pair retires as 1 or 2 instructions depending on the predicate, which keeps `minstret` exact.
  - **Debug:** disabled in debug mode and while triggers are armed.
- **Jump folding (option).** An unconditional `jal x0` or `c.j` has no architectural effect besides the PC, and the front end has already predicted and verified it.
  - The decode selector skips it, so it takes no micro-op, decode slot or ROB entry.
  - It is credited to the retire count of the preceding micro-op in its decode group. A jump with no preceding micro-op in its group is not folded, which keeps `minstret` exact.
  - Disabled in debug mode and while triggers are armed.

### 4.4 Rename and recovery
- **Rename tables:** integer (32 × 8-bit physical tags) and FP (32 × 7-bit), in flip-flops, 2 instructions per cycle, plus committed copies.
- **Free lists:** one LUTRAM FIFO per register bank (5 banks), with even/odd storage so 2 pushes can land per cycle.
- **4 checkpoints** in LUTRAM, each holding both rename tables, the free-list heads and the LQ/SQ tails.
  - Taken for conditional branches and JALR. If none is free, the branch recovers at commit; rename never stalls for lack of checkpoints.
  - **M1 evidence:**
    - On the suite, 0 → 4 checkpoints gain +0.6% against a 1.2% LUT share; early retirement makes commit-time recovery cheap.
    - 4 checkpoints capture almost all of 8's benefit.
    - On branchy, L2-resident code (47 mispredicts per 1,000 instructions) they are worth +5.7%, and on several Embench programs +3.5–8.5%.
  - **Status:** kept as exception E2, provisional until Linux/SPEC-like workloads.
- **Kill rule:** squash by ROB-age comparison (index plus wrap bit), qualified by thread ID.
- **What recovers at commit:** exceptions, interrupts, ordering violations and branches without a checkpoint.
- **Deferred free (hook for early retirement):** a physical register is returned to its free list only after its producer has written it. A small deferred-free queue holds registers whose producer retired early and is still pending.
- **Producer table:** maps each pending physical register to its wakeup ID (§4.6). Dispatch reads it for source operands.
- **Move elimination:** a DSE option only, not v1. It needs reference counts on physical registers, which complicate checkpoint recovery. The A73 has a form of it.

### 4.5 ROB, commit and early retirement
- **ROB:** **48 entries** (M1: the step to 64 gains +0.45% against a 1.17% LUT share), in two LUTRAM banks (even/odd).
  - Completion bits are flip-flops written by up to 6 ports.
  - A single "oldest exception" register replaces per-entry exception storage.
- **Early retirement (A73-inspired).** Chips and Cheese found that the A73 retires a load as soon as it is guaranteed to complete, and completed instructions stop holding resources.

  | What retires early | Condition |
  |---|---|
  | Load | At the ROB head, with translation, PMP and PMA checks passed. It must be cacheable main memory, not MMIO and not LR/AMO; older stores are all already retired. |
  | DIV/REM, FDIV/FSQRT and other long FP operations | Once issued. On RISC-V these cannot trap; FP sets flags only. |

  - **What happens next:** the operation leaves the ROB while its destination register is still pending. Its consumers wait in the issue queues on its long-latency tag (§4.6).
  - **Retired loads** move from the LQ's CAM into a non-CAM retired-load completion buffer (§4.9). The number of overlapped misses is then bounded by that cheap buffer and the MSHRs, not by the ROB or the CAM.
  - **Retired operations are architecturally done:** pipeline flushes (mispredicts, traps, interrupts) never cancel them. Their writebacks always happen.
  - **fflags:** fflags from early-retired FP operations accumulate when they complete. A CSR access to fflags/fcsr waits until no early-retired FP operation is pending.
  - **Bus errors:** a refill bus error on a retired load can no longer be precise. It is reported as a platform machine-error interrupt. A DRAM bus error is fatal anyway.
  - **Plan:** the hooks (long-latency tags, deferred free, the split LQ) are in v1 from M2. The feature has an enable bit and switches on in M6 once it passes the verification gates (§9).
  - **M1 go/no-go: GO.**
    - **On the 16-filler pointer chase:** it sustains 7.88 misses in flight. Without it, a 64-entry ROB sustains 3.79, and matching it takes ROB 160 + LQ 32 + 96 registers per bank, about 5K LUTs against ≈0.9K.
    - **On the suite:** it contributes +2.4% at 120 cycles (cost 2.2%), and +3.4% at ROB 48, where it substitutes for ROB entries.
    - **Caveat:** it does not help when the instructions after a miss depend on it. There, window size matters ([DSE report §7](perf/dse_report.md)).
- **Steering:** dispatch picks each micro-op's port from free IQ entries and free registers in that port's bank.

### 4.6 Scheduling (the core of FPGA timing)
- **Queues and ports:**

  | Queue | Entries (M1 freeze) | Port | Executes |
  |---|---|---|---|
  | IQ-A0 | 10 | P0 | ALU, branches, JAL/JALR, LUI/AUIPC |
  | IQ-A1 | 10 | P1 | ALU, complex Zbb, MUL (pipelined, 3 cycles), DIV/REM (iterative) |
  | IQ-LD | 6 | P2 | Loads (integer and FP) |
  | IQ-STA | 4 | P3 | Store, AMO, LR/SC and CBO addresses |
  | IQ-FP | 10 | P4 | FP operations |

  - **Store data** waits inside its SQ entry and claims the shared read port when its value is ready.
  - **CSR and serialising operations** execute at the ROB head.
  - **M1:** the queue sizes come from the greedy freeze.
    - The ALU queues grew 6 → 8 → 10 because they hold the dependents of cache misses (+1.5% and +1.2% per step).
    - The load and store-address queues stayed small.
    - IQ-FP is 10 rather than 6 for dense FP code (exception E5: blocked matrix multiply −12.7% at 6).
    - The A73 runs two 6-entry ALU queues; at 6 entries ours lose memory-level parallelism on gather-type code.
- **Wakeup:** a global "woken" vector W over wakeup IDs. Readiness is NOR(dependency bits AND NOT W): an AND-OR, with no tag CAM.
  - **Wakeup IDs:** a ROB index for short-latency producers. A **long-latency tag** (LLT) is used for loads, divides and long FP operations, because these may retire before completing. The pool has 16 tags; M1 found no gain above 16.
  - **Dependency vectors** have 48 + 16 columns and are written once at dispatch.
  - **Stale dependencies:** a guard prevents reallocating an ID while a row still waits on it. Spike S2 compares it with a wrap-phase bit.
- **Select:** oldest ready first, using an age matrix per queue set at allocation. Branch-first priority in IQ-A0 was measured in M1 and removed: −0.03%.
- **Measured (spike S2, 2026-10-13; all five queues share one woken vector).** The whole scheduler closes 200 MHz at every width, with these structures (`fpga/spikes/rtl/tg_iq.sv`):
  - **ST:** two levers, at +0.11 ns and 5.3K LUTs.
    - **DUP_SEL:** a second select copy drives only the wakeup broadcast.
    - **EARLY_W:** only the source tags sit in flip-flops behind the grant mux; the rest of the payload is in LUTRAM, read in the RF stage.
  - **SMT2 (v1) and SMT2 + 3-wide (v2): MX is required.** A row names its in-queue 1-cycle producers by ALU-queue row and is ready when those rows are selected; W follows a cycle later.
    - **Dispatch** supplies the row names: one compare of the source's physical register with the row's destination.
    - **The cancel history** is 1 cycle (`HIST = 1`).
    - **Results:** +0.11 ns at 8.9K LUTs (v1) and +0.06 ns at 12.5K (v2).
  - **Stale dependencies:** the guard. The phase-bit variant deadlocked in random tests, because a pooled LLT was reused while a row still waited on its first instance.
- **Wakeup tags (AR-1, adopted 2026-10-14 under D18 step 1; [area study](perf/area_recovery.md) §5).** The readiness vectors drop their ROB-index columns (80 at v1, 96 at v2).
  - **What replaces them:** a pool of 16 wakeup tags, for the producers that need one: multi-cycle fixed-latency ops (MUL, complex Zbb, the FMA, FP misc and move ops) and serialised ops.
  - **The other producers are already covered:** MX covers every 1-cycle producer, and LLTs cover loads, divides and long FP ops.
  - **Exact in the model:** 0.00% IPC at 30, 120 and 250 cycles, on every pair, the single-thread suite, and in v1, v2 and ST. There were 0 tag stalls.
  - **Saving, measured (spike S2, 2026-10-14, whole scheduler at 200 MHz).** It beats the study's estimate (v1 2.7–3.0K, v2 4.7–5.0K, ST 1.0–1.2K):

    | Configuration | ROB columns with MX | 16 wakeup tags | Saved | Slack |
    |---|---|---|---|---|
    | ST | 6,425 | 4,802 | −1,623 (−25%) | +0.145 → +0.518 ns |
    | v1 (SMT2) | 8,895 | **5,506** | **−3,389 (−38%)** | +0.112 → +0.218 ns |
    | v2 (SMT2 + 3-wide) | 12,515 | 7,703 | −4,812 (−38%) | +0.057 → +0.026 ns |

    v1's scheduler is now about 2.8K under its 8.35K budget ([budgets.md](perf/budgets.md)).

  - **Consequence:** the window size no longer sets the scheduler's LUTs.
- **Wakeup timing:**
  - 1-cycle operations wake at select, so dependants issue back to back.
  - Fixed multi-cycle operations wake through a delay line.
  - Long-latency operations wake on their LLT when they complete.
- **Speculative load wakeup:** dependants issue 3 cycles after a load, assuming it hits.
  - On a miss, everything issued in the 2-cycle shadow is cancelled on all ports, its W bits cleared, and its rows return to "not issued". Rows are held for 2 cycles after issue.
  - The load replays from the LQ when the line arrives, or completes from the completion buffer if it has already retired.
  - A per-PC hit predictor stops speculative wakeup for loads that often miss.

### 4.7 Register files and bypass
- **Writer-sharded banks.** Each bank has exactly one write port, and rename allocates from the producing port's bank. This is Seznec's register write specialisation (MICRO 2002), applied to FPGAs by Wong and by SmolRV64.

  | File | Banks | Size | Read ports |
  |---|---|---|---|
  | Integer | B0 (P0), B1 (P1, FP→int, CSR), B2 (loads, SC/AMO) | 3 × 64 = 192 | 7: P0×2, P1×2, LD, STA, plus a shared port for store data and FP's integer source |
  | FP | F0 (FP pipe), F1 (FP loads) | 2 × 64 | 4: the three FMA sources plus FP store data |

  Each bank is one RAM64M8 per bit (7 reads, 1 write). Estimated cost: about 2.0K LUTs for the integer file and 1.3K for the FP file.
- **Width-generic generator.** The register-file generator takes the read-port count as a parameter. Beyond 7 read ports it either replicates a bank or shares ports with arbitration at select.
  - **Why it matters for 3-wide:** a third ALU (`N_ALU = 3`) needs 9 integer read ports.
  - **Cost of the two options:** replication doubles every bank (+2.7K LUTs, the largest single item of the 3-wide option); sharing costs about +1.0K plus some port conflicts (§4.15).
- **Write-port conflicts:** P1's write port is shared by ALU, MUL, DIV, FP→int and CSR results, and arbitrated with a reservation shift register. Load misses replay through the load pipe or complete through the completion buffer's slot on B2/F1.
- **Bypass:** full bypass among ALU0, ALU1 and load results, from EX and WB, through an 8:1 operand mux (about 1.2–1.5K LUTs). FP has a separate bypass network.

### 4.8 Execution units
- **ALU0/ALU1 (1 cycle):** add, logic, shifts, compares, Zba, Zbs and simple Zbb. ALU1 also does clz, ctz, cpop, rev8 and orc.b (1–2 cycles).
  - **min/max/minu/maxu go on the 2-cycle path** with clz/ctz/cpop, at both widths (spike S3, 2026-10-13). They were the worst ALU path: with them in the 1-cycle loop, 3 ALUs miss 200 MHz (−0.09 ns). With them moved out, 2 ALUs gain +0.34 ns of slack and 3 ALUs pass (+0.05).
- **`N_ALU`:** a third ALU port is an RTL parameter, off in v1.
  - **At 2-wide decode:** it is worth +1.2%, mostly from its extra queue entries.
  - **With 3-wide decode:** it is part of the +13% option (§4).
- **Branch unit** on P0.
- **MUL:** DSP48E2-based (about 12–16 DSPs), 3 cycles, pipelined.
- **DIV:** radix-4 iterative, about 34 cycles at worst, with early-out; can retire early.
- **Protected loop:** 1-cycle ALU → bypass → ALU.

### 4.9 Load/store unit
- **Load pipe:** AG → M1 (8-way BRAM read, LUTRAM tags, DTLB) → M2 (compare, way select, align), giving 3-cycle load-to-use.
- **LQ (split):**
  - A 16-entry **CAM part** for loads that have not retired. It handles forwarding, ordering checks and snoops.
  - An **8-entry retired-load completion buffer** in LUTRAM, with no CAM: {destination, LLT, MSHR, offset, size, sign}. It fills from the line refill and survives flushes.
  - **M1:** the buffer is worth +2.4% at 120 cycles for about 64 LUTs; a 16-entry buffer gains nothing. The CAM part stays at 16 (+8 entries: +0.04%).
- **SQ:** **12 entries** (M1: 12 → 16 gains +0.21% against a 0.49% LUT share; borderline, re-judged at synthesis), plus an in-order drain of committed stores to the D$.
- **Early ownership prefetch:** when a store address resolves and the line is absent or shared, an ownership request goes out right away, not when the store drains. Otherwise every store miss stalls the drain for a full DRAM round trip.
- **Forwarding:** page-offset compare first, then a full physical check. The youngest older store covering all the load's bytes forwards; partial overlaps wait.
- **Ordering violations:** a store-address search over younger executed loads. A hit flushes at commit.
- **Memory-dependence prediction:** none in v1. A 1K wait table remains an RTL option, with store sets in v1.x if Linux workloads show violation storms; the violation-flush counter will tell.
  - **M1 evidence:** the wait table gained 0.02%. Store addresses issue early from their own queue, so even a store-to-load aliasing kernel saw no ordering violations.
- **RVWMO:**
  - Stores become visible at commit.
  - Same-address load-load ordering: snoops, invalidations and evictions mark executed loads, and matching younger loads replay.
  - FENCE executes at the ROB head after the drain empties.
  - A retired load completes from the line it is waiting on. The LSU spec must show this preserves same-address ordering, and litmus tests must confirm it (§9).
- **Atomics:** at the ROB head in L1D on a unique line, with one reservation per hart. Probes are held off for 32–64 cycles after LR.
- **MMIO:** non-speculative, at the head, uncached.
- **Second load pipe** (both pipes able to load or store, as on the A73): **rejected in M1.**
  - It gains +0.4% suite IPC (CoreMark +1.5%) for about 1.5K LUTs, plus a second D$ read port (8 BRAM36 per core).
  - Behind a 2-wide decoder, loads arrive at about 0.5–0.6 per cycle, so one load pipe is rarely busy enough to matter.

### 4.10 MMU
- **L1 TLBs:** ITLB 16 entries and DTLB 32, fully associative, supporting 4K, 2M and 1G pages.
- **L2 TLB:** 512 entries, 4-way, in BRAM.
- **Page-walk cache:** 8 entries.
- **Page walker:** walks go through the load pipe. A second concurrent walk is a design-latency sweep option, since every walk step may go to DRAM.
- **Tags and PMP:** entries are tagged {TID, ASID}; PMP results are cached in the TLB.

### 4.11 L1 caches and prefetch
- **D$:** 32 KiB, 8-way, VIPT, write-back, MESI. One BRAM36 per way: port A serves loads and dirty reads; port B serves refills and stores.
- **MSHRs:** **16**, each with a 64 B fill buffer.
  - **M1:** 12 → 16 gains +1.26% against a 0.73% LUT share; 16 → 20 gains nothing.
  - The 16-chain MLP test sustains 15.65 misses in flight.
- **No blocking evictions:** an eviction never blocks a refill (Rocket's blocking evictions turned a 14-cycle L2 hit into 24).
- **Prefetchers:**
  - **v1, L1D:** a PC-stride prefetcher (16-entry table). M1: +0.96% against a 0.73% LUT share, mostly from the index streams of sparse and gather code.
  - **v1, L2:** a stream prefetcher. M1: +6.6% at 120 cycles and +8.6% at 250.
  - **Both:** prefetch distance is a run-time register, so the same RTL tunes for 30 or 250 cycles of latency. The stream prefetcher's default is distance 16, degree 4 (§5.1).
- **Fallback:** 16 KiB, 4-way L1s.

### 4.12 FPU (written from scratch)
- **FMA pipe:** one fused multiply-add pipeline, double precision with single NaN-boxed, **5 cycles**, about 2.5K LUTs and 10–14 DSPs.
  - **4 cycles:** worth +0.22% suite IPC (st +4%). That is a timing question, so 4 is adopted only if synthesis shows it costs no Fmax.
- **One FMA pipe.** M1 rejected a second pipe: +0.08% suite IPC for about 4.4K LUTs.
  - **Why so little:** behind 2-wide decode, even a blocked matrix multiply (44% FMAs) needs only about 0.9 FMAs per cycle.
  - **Where the cost is:** DSPs are plentiful; the cost is the FMA's LUT logic and the FP register-file ports.
- **Divide and square root: Goldschmidt on two dedicated DSP multipliers** (56×56, 4-cycle pipelined, about 24 DSP48E2), with a 10-bit reciprocal / reciprocal-square-root seed table in a BRAM18.
  - **Latency (as built):** divide 19 cycles (single) / 23 (double); square root 19 / 27. A rounding stage, added to meet timing, makes single divide and double square root one cycle longer than the plan's 18 / 26.
  - **Throughput:** pipelined; a new operation starts whenever one of four slots is free (one FDIV.D every 4 cycles in steady state).
  - **Rounding:** a final remainder multiply and ±1 ulp correction give correctly rounded results.
  - **Early retirement:** it can retire early.
  - **Cost:**
    - **M1 estimate:** about the LUTs of the radix-4 unit it replaces (+0.2K net); its multipliers use DSPs, which the XCK26 has in excess.
    - **Measured (FPU track):** 3,125 LUTs, 26 DSPs and 1 BRAM18, against 1,714 LUTs for the radix-4 unit as built. That is +1.4K LUTs, 3.7% of the core.
  - **M1:** +1.3% suite IPC (+2.2% counting nbody); st +67%, minver +14%.
    - Radix-16 digit recurrence was rejected: +1.1% for 1.2K LUTs.
    - A 14-bit seed adds only +0.04%.
  - **Re-modelled with the as-built latencies** (120 cycles): +2.4% suite IPC over the radix-4 unit as built (18 / 33 cycles, unpipelined); nbody +71%, st +70%, minver +23%.
  - **Decision (D17, user, 2026-10-13):** keep Goldschmidt in v1, although at its measured cost it fails the acceptance rule (2.4% IPC against 3.7% LUTs).
    - **Fallback:** if the dual-core runs short of area at the end, switch to the radix-4 unit. Both are built and verified, and `FDIV_RADIX4` in `tg_fpu_pkg` selects between them.
    - **Lever R4** (§8.5), integer divide on the Goldschmidt multipliers, would remove about 0.5K of the difference.
- **FMISC unit:** compares, sign injection, min/max, class, moves, and FP→integer conversions.
  - **Lever R5** (§8.5) moves integer→FP and FP→FP conversions into the FMA, which shares its normaliser and rounder. Those conversions then take `FMA_LAT` cycles.
  - **R5 measured:** FMISC shrinks by 584 LUTs and the FMA grows by about 150–250. Even the upper-bound IPC cost, every FMISC operation at 5 cycles, is −0.09% suite IPC, so R5 passes the rule.
- **Queue:** IQ-FP has 10 entries (exception E5, §4.6).
- **Verification:** TestFloat from the first commit, plus directed hard-rounding cases for the Goldschmidt remainder correction.

### 4.13 Commit, traps and CSRs
- **Commit:** 2 micro-ops per cycle (`DECODE_WIDTH`). With the fusion, predication and folding options off, every micro-op is one instruction.
- **Traps:** taken at commit. They never cancel early-retired operations.
- **WFI** parks at the ROB head until any locally enabled interrupt is pending.
- **CSR file:** banked by thread ID; menvcfg/senvcfg present; `time` is broadcast from the ACLINT.
- **Counters:** at least 16 live HPM counters (events in §10.2).
- **mhartid** = core × NUM_THREADS + TID.

### 4.14 Parameter table (M1 freeze and the SMT2 release, approved 2026-10-13)

| Structure | ST bring-up (M1 freeze) | **v1 release (SMT2)** | Draft 0.3 | Basis ([ledger](perf/feature_ledger.md)) | NaxRiscv |
|---|---|---|---|---|---|
| Harts per core | 1 (`TID_W = 0`) | **2** (`TID_W = 1`) | 1 | D16 | 1 |
| Fetch | 16 B, decoupled, 32-entry FTQ, fetch-directed + next-line I$ prefetch | same; ICOUNT picks the thread, per-thread FTQ | same | E1; §6.5 | 64-bit |
| Prediction | 64-entry 2-way LUTRAM micro-BTB · 1K×4 block BTB · TAGE-lite with 4 × 4K tagged tables (~29 KB) · 32-entry RAS | same tables, TID hashed in; history and RAS per thread | 32 FA · 1K×4 · 4 × 1K · 32 | rule | 512-entry BTB, 4 KB gshare |
| Decode / rename / commit | 2 / 2 / 2 (`DECODE_WIDTH`; 3-wide build in CI) | same; slots alternate between threads, idle slots shared | 2 / 2 / 2 + fusion, SFB, folding | rule (options off) | 2 / 2 / 2 |
| ROB | 48, with early retirement | **80**: per-thread halves of 40 | 64 | greedy; §4.5 GO; §6.5 | 64 |
| Long-latency tags | 16 | **24**, shared | 32 | greedy; §6.5 | — |
| Physical registers | 192 integer, 128 FP | same, shared | same | not swept | 64 |
| Issue queues A0 / A1 / LD / STA / FP | 10 / 10 / 6 / 4 / 10 | same, shared; ≤ 75% per thread | 12 / 12 / 12 / 8 / 12 | greedy; FP from E5; §6.5 | 32 unified |
| Select | oldest first | same | + branch-first in IQ-A0 | rule | — |
| Checkpoints | 4, with commit fallback | 4 per thread | 8 | E2 | 0 |
| LQ (CAM + completion buffer) / SQ | 16 + 8 / 12 | **24 + 8 / 20**, per-thread halves | 16 + 16 / 16 | greedy; §6.5 | 16 / 16 |
| Memory-dependence prediction | none (option) | same | 1K wait table | rule | — |
| L1D MSHRs / L1I MSHRs | 16 / 4 | same, shared | 12 / 2 | greedy / E1 | 2 refill slots / 1 |
| L1I / L1D | 32 KiB 8-way | same, shared | same | rule | 16 KB 4-way |
| L2 / L2 MSHRs / stream prefetch defaults | 1 MiB / 48 / distance 16, degree 4 | same | 1 MiB / 32 / 8, 2 | E3 / E4 | — |
| FMA / divide-sqrt | 5 cycles / Goldschmidt, pipelined (18/23 divide, 20/26 sqrt) | same, shared | 4–5 / radix-4 (30–60) | rule | — |
| TLBs | I16 / D32, 512-entry L2, 8-entry page-walk cache | same, entries tagged {TID, ASID} | same | not modelled | 192-entry LUTRAM |
| Minimum mispredict penalty | 9 cycles, at execute | same | same | — | 10, at commit (best case) |

**Reading the table.**
- **"Rule"** means the ablation verdict, **"greedy"** the combined size freeze (§2.5), and **§6.5** the SMT2 sizing pass. E1–E5 are the provisional exceptions in the ledger.
- **In the model:** ST is `tgsim --preset v1_freeze` (the preset's name predates the release renaming). The release is `v1_freeze` with `threads=2` and the §6.5 sizes.
- **SMT off at run time:** with one hart offline, the release core merges its halves and runs one thread on the whole window (§6.5).

### 4.15 Width-generic design (3-wide reserve)

v1 ships 2-wide; a 3-wide version is planned for later (D13, D14). Everything whose size depends on the machine width is an RTL parameter from the first commit. That version is then a configuration change plus timing closure, verification and a new freeze, not a redesign.

**Parameters** (in `tg_pkg`, next to `TID_W`):

| Parameter | v1 | 3-wide build | What it sizes |
|---|---|---|---|
| `FETCH_BYTES` | 16 | 16 (32 as an option) | Fetch block, I$ read width, pre-decode and compaction slots. 16 B holds about 4–5 instructions with RVC, enough for 3-wide. |
| `DECODE_WIDTH` | 2 | 3 | Instruction-queue read ports; decoders and RVC expanders |
| `RENAME_WIDTH` | `DECODE_WIDTH` | 3 | Rename-table read and write ports; intra-group dependency checks; free-list pops per bank; checkpoint capture for branches in a group |
| `DISPATCH_WIDTH` | `DECODE_WIDTH` | 3 | ROB, LQ and SQ allocations per cycle; issue-queue write ports; dependency-vector and age-matrix row writes |
| `COMMIT_WIDTH` | `DECODE_WIDTH` | 3 | Retire ports; free-list pushes; committed rename-table writes; retire counters and lockstep records |
| `N_ALU` | 2 | 3 | ALU ports with their issue queues and register banks; register-file read ports; bypass sources and sinks |
| `BTB_SLOTS` | 2 | 2–3 | Branches predicted per fetch block |
| `ROB_BANKS`, `FL_BANKS` | 2 (even/odd) | 3–4 | LUTRAM interleaving for N writes and N retires per cycle (ROB, free lists, checkpoints) |
| All sizes | §4.14 | re-frozen by the acceptance rule for the 3-wide build | ROB, issue queues, LQ/SQ, LLTs, MSHRs, registers per bank, checkpoints |

**Rules, enforced in RTL reviews** (like §6.2):
1. **No literal widths.** Every per-instruction structure in a cycle comes from a generate loop over its width parameter; no hand-unrolled "slot 0 / slot 1" logic.
2. **Rename is generated for N.** That covers the intra-group dependency check, the producer-table reads and the free-list pops. A decode group may hold several branches, so checkpoints are captured per branch, not per group.
3. **Banking follows width.** The ROB, free lists and checkpoint storage use `ROB_BANKS`- and `FL_BANKS`-way interleaved LUTRAM, generalising even/odd.
4. **Ports are generated from lists.**
   - The register-file generator takes (banks, read ports per bank) and replicates a bank beyond 7 read ports.
   - The bypass network is generated from the producer and consumer port lists.
   - Steering, issue queues and age matrices are generated per port.
   - Adding an ALU port therefore adds a queue, a register bank and a bypass source without touching the others.
5. **Commit-side bookkeeping is width-aware.** `instret`, the HPM counters and the lockstep retire record accept up to `COMMIT_WIDTH` retirements per cycle.
6. **What stays width-independent:**
   - FTQ, predictors (apart from `BTB_SLOTS`), RAS;
   - the load and store-address pipes, LSU and caches;
   - FPU, MMU, CSRs and the SMT hooks.

**Keeping the reserve honest:**
- **CI:** builds both the 2-wide/2-ALU and the 3-wide/3-ALU configurations from M2. Both pass riscv-tests and Spike lockstep.
- **Random tests:** the random generator covers 3-instruction groups with intra-group dependencies and two branches per group.
- **Spikes:** S2 (wakeup-select), S3 (register file and bypass) and S5 (fetch, compaction, rename) are also run at width 3. The 3-wide timing problems and their fallbacks are then known before v1's RTL settles.
- **Synthesis:** M6 synthesises the 3-wide build for LUTs and Fmax, alongside `TID_W = 1`.
- **Model:** `tgsim` keeps 3-wide configurations in its regression. The 3-wide freeze is redone by the acceptance rule when that version is planned.

**What M1 says about the 3-wide build:**
- **Gain:** +13.2% suite IPC with a third ALU (+5.0% without one). CoreMark/MHz on rv64gc is 6.08 (flag set A) and 5.92 (flag set B).
- **Cost of the reserve in v1:** RTL effort only. Generate loops at width 2 produce the same logic as hand-written 2-wide code.

**3-wide cost, per unit** (estimates on the §8.2 basis; refined 2026-10-13 from M1's first-pass ~10K):

| Item, per core | Bank replication | Read-port sharing |
|---|---|---|
| Third decoder and RVC expander; compaction of a third slot | 0.7K | 0.7K |
| Rename at width 3 (read ports, intra-group checks, free-list pops) | 0.5K | 0.5K |
| Dispatch: issue-queue rows banked by dispatch slot, so row writes don't widen | 0.5K | 0.5K |
| ROB and commit at width 3 | 0.4K | 0.4K |
| Third ALU and its 10-entry issue queue | 1.6K | 1.6K |
| Integer register file: a 4th bank, plus 9 read ports | 2.7K (every bank doubled) | 1.0K (ports kept ≤ 7, arbitrated at select) |
| Bypass (one more producer, two more consumers), steering, counters | 1.3K | 1.3K |
| **Total** | **≈ 7.7K** | **≈ 6.0K** |

Read-port sharing has two costs:
- an arbitration term in the select loop;
- some IPC lost to port conflicts. `tgsim` does not model register-port conflicts yet.

Both options are measured at width 3 in spike S3.

**Dual-core fit on the XCK26** (117.1K LUTs; per-core costs as above, the SMT2 study, and §8.2):

| Configuration | Per core vs ST | SoC LUTs | XCK26 |
|---|---|---|---|
| ST: 2-wide, 1 thread (bring-up) | — | ≈ 88.7K | 76% |
| 3-wide, 3 ALUs, 1 thread (`st_w3`, bring-up for v2) | +6.0–8.2K (incl. ~0.5K of sizes) | ≈ 101–105K | 87–90% |
| **v1: SMT2, 2-wide (§6.5)** | +8.3K (6.2–10.7K) | ≈ 105K (101–110K) before area recovery | 90% (86–94%) now; target ~80% (§8.5) |
| **v2: SMT2 + 3-wide** | +15.5–17.5K | ≈ 120–124K before area recovery | 103–106% now; limit 85–90% (§8.5) |

**Getting both releases onto the XCK26.**
- **The commitment:** both releases stay on the KV260 (D14). These first-pass estimates are conservative.
- **v1 (SMT2):** the free §8.5 levers, which cost no IPC and are in the RTL from the first commit, bring it to about 72–79% on paper.
- **v2:** all the levers bring it to about 83–90% on paper. Synthesis and further RTL-level savings close the rest.

**Fmax matters as much as LUTs.** At 175 instead of 200 MHz, 3-wide's +13% IPC is mostly cancelled (−12.5% clock). The 3-wide configurations are therefore synthesised and timed early: spikes S2, S3 and S5 at width 3, S6 for the `smt2_w3` floorplan, and M6 for all four configurations.

**Named configurations** (`tg_pkg` parameter sets; `tgsim` presets in brackets where they exist):

| Configuration | `TID_W` | `DECODE_WIDTH` / `N_ALU` | ROB / LQ / SQ / LLTs | Role |
|---|---|---|---|---|
| `st` [`v1_freeze`] | 0 | 2 / 2 | 48 / 16 + 8 / 12 / 16 | single-thread bring-up (M2–M6), CI reference (§4.14) |
| **`smt2`** | 1 | 2 / 2 | 80 / 24 + 8 / 20 / 24, static halves | **v1, the first release** (§6.5) |
| `st_w3` | 0 | 3 / 3 | ST sizes until v2's freeze | the 3-wide reserve in CI; bring-up stage for v2 |
| `smt2_w3` | 1 | 3 / 3 | 96 / 32 + 16 / 20 / 24 (the SMT2 study's rule-12 sizing) | **v2**, on the XCK26 via §8.5; its own freeze when planned |

---

## 5. Dual-core memory system

### 5.1 Shared L2
- **Capacity:** **1 MiB** by default (32 UltraRAM, which nothing else uses), 8-way, inclusive of both L1Ds. 512 KiB (16 UltraRAM) is the fallback if timing or placement fails.
  - **M1:** 1 MiB vs 512 KiB gains only +0.1%, because no suite workload sits between 0.5 and 1 MiB.
  - **Status:** kept as exception E3, since its cost is UltraRAM with no other use.
- **Banks:** 2, interleaved on address bit 6. Each is 4 UltraRAMs wide (256-bit rows, 2 beats per line) and cascaded 4 deep. Tags and directory take about 13–16 BRAM36.
- **Hit latency target:** 10–12 cycles load-to-use, as seen from an L1 miss.
- **MSHRs:** **24 per bank (48 in total).** The PS port's 16-outstanding-transaction limit is a SoC parameter in the KV260 build, never a core or L2 assumption.
  - **M1:** 16 → 32 MSHRs gains +2.7% at 120 cycles.
  - **Why 48 (exception E4):** at 250 cycles, memcpy-class streams need about 28 lines in flight. With 32 MSHRs and a prefetch distance of 8, memcpy halves. 48 MSHRs with distance 16 / degree 4 hold it at 1.57 IPC and keep the 250-cycle ratio above the native one (§2.5 criterion 1). The dual-core's two miss streams share these MSHRs.
- **Behaviour:** the L2 is the ordering point. It prefers victims with an empty presence vector and keeps a 2–4-line victim buffer.
- **Stream prefetcher:** run-time distance and degree; reset defaults are distance 16, degree 4.
  - A prefetch that finds no free MSHR is dropped today. A small prefetch queue that retries would close the holes this leaves.

### 5.2 Coherence protocol
- **L1D states:** MESI. Exclusive is granted when no other agent holds the line. There is no Owned state in L1; the L2 absorbs dirty data on a downgrade.
- **Transactions:** Acquire, Grant and GrantAck; Release and ReleaseAck; Probe and ProbeAck. These follow TileLink TL-C semantics and its channel-priority deadlock rule, and handle the documented races explicitly.
- **Probes** go only to agents whose presence bit is set.
- **I$ refills** are coherent "get" reads. FENCE.I drains the store queue, invalidates the local I$ and refetches. Other harts are reached through SBI RFENCE.

### 5.3 Memory-model summary
- **Visibility:** a store is globally visible when its L1D write completes with M permission.
- **Atomics:** performed at the ROB head on a unique line. Atomics with .aq or .rl are fully ordering in v1.
- **Fences:** SFENCE.VMA and FENCE.I are local to the hart; cross-hart effects use SBI RFENCE (SBI v3.0).
- **Early-retired loads:** they keep their ordering obligations through the completion buffer (§4.9).

### 5.4 Interconnect and memory map

| Physical address | Size | Device |
|---|---|---|
| `0x0000_1000` | 4 KiB | Boot ROM: sets a0 = hartid and a1 = DTB, jumps to `0x8000_0000` |
| `0x0200_0000` | 64 KiB | ACLINT (MSWI + MTIMER), CLINT-compatible layout |
| `0x0C00_0000` | 64 MiB | PLIC (`riscv,plic0`), M and S contexts per hart |
| `0x1000_0000` | 4 KiB | UART (`ns16550a`) |
| `0x1000_1000` | 4 KiB | Host mailbox, control, latency-injector registers |
| `0x1001_0000` | 4 × 4 KiB | virtio-mmio slots (console, block, network, rng) |
| `0x1100_0000` | 64 KiB | Debug module, trace and performance-counter windows |
| `0x8000_0000` | 1 GiB | DRAM window, remapped onto the PS DDR carve-out; the PMA's memory region is exactly this (DR-151, `tg_map_pkg::DRAM_REGION`, a power of two), so nothing past RAM is memory |

The A53 host reaches RISC-V memory through a coherent DMA port on the L2, so virtio needs no software cache maintenance.

### 5.5 PS DDR interface
- **Ports:** one AXI4 master per L2 bank, 128 bits at the core clock, to S_AXI_HP1 and HP2.
- **Address mapping:** an offset maps the DRAM window onto the carve-out.
- **Verified in S1 (2026-10-14):** the `mem=3G` carve-out works (Linux RAM ends at 0x83fffffff), and the PL reaches DDR through the HP ports with no DECERR. This Kria image has no SMMU driver and its device tree disables the SMMU, so the bypass setting is moot here; it stays on the command line as a guard.
- **Isolation:** all of this lives in the SoC layer. The L2 sees a generic AXI4 memory, so a future board with DDR on the programmable logic needs only a different SoC top.

### 5.6 Latency injector (new)
- **Where:** a small block between the L2's AXI masters and the PS ports.
- **What it does:**
  - delays each read response by a programmable 0–1023 cycles from request issue;
  - can optionally cap bandwidth;
  - is set by the host at run time.
- **Buffering:** responses wait in BRAM (1–2 BRAM36 per port), so the PS port's outstanding-transaction limit does not distort the emulation.
- **What it enables:**
  - Linux-scale workloads at the 90-, 120- and 250-cycle points, at full FPGA speed;
  - checking `tgsim`'s latency curves on hardware;
  - showing the advantage over NaxRiscv does not shrink as latency grows.

  XiangShan did the same thing on its FPGA prototype for the same reason.

---

## 6. SMT2 (first release) and CMT readiness

### 6.1 Which multithreading
- **SMT2: in the first release (D16).** Two-thread SMT has delivered +15–60% throughput for 5–25% area in shipping designs.
  - **Plan vs model:** our planning estimate was +20–40% for +10–20% core logic. The SMT2 study measured +33% on the single-thread (ST) sizes and +43% with the §6.5 window, for an estimated 6.4K LUTs of SMT logic (15.6% of the core) plus 1.9K for sizes.
  - **Where the gain is:** almost all on memory-bound threads. Compute pairs gain about 15%, pinned by the 2-wide decoder; v2's 3-wide decode lifts them.
- **Bulldozer-style CMT.** Kept possible through interfaces (rule 9 below) but not planned: a shared front end starves a 2-wide machine.
- **Chip MT.** The L2 supports 4 agents: 2 cores × 2 harts.
- **Coarse-grained MT** (switch on L2 miss): dropped, since SMT2 ships in v1.

### 6.2 Design rules, enforced in RTL reviews from the first commit
1. `NUM_THREADS` and `TID_W` are global parameters; in v1, TID is tied to 0.
2. **Every flush, kill or redirect carries a TID.** Nothing flushes globally except reset.
3. **Age** comes from allocation-order matrices in the issue queues, and from per-thread ROB and LSQ pointers. Nothing subtracts ROB indices across threads.
4. **Memory:** forwarding and ordering checks require a TID match. Sibling commits drive the same snoop and reservation-kill path as remote probes.
5. **Translation:** TLB and page-walk-cache entries are tagged {TID, ASID}, and SFENCE.VMA is scoped to a thread.
6. **Predictors:** global history, RAS and FTQ are per thread. Shared tables may hash in the TID, and context tags provide Spectre-v2-style isolation.
7. **Occupancy:** per-TID counters with caps on the issue queues, LQ, completion buffer, SQ, MSHRs, LLTs and free lists.
   - **Issue-queue caps** (75%) are required in the SMT2 build.
   - **MSHR and LLT caps** never bound in the model; keep the counters, with the default "no cap" (§6.5).
8. **Per-hart state:** CSRs, interrupts, timers, the LR reservation, debug state and counters are arrays indexed by TID.
9. **Interfaces are queue-decoupled and TID-tagged:** front end ↔ back end, integer back end ↔ FPU, and core ↔ L2.
10. **Security knobs:** predictor flush, flushable buffers, and an SMT-off mode. In SMT-off mode, or with hart 1 offline, the partitions merge after a drain, so the remaining thread gets the whole window (§6.5).
11. **Early retirement is per thread.** A thread's flush never touches its sibling's retired-but-pending operations, nor its own.
12. **Width is a parameter too (0.4).** The width parameters live next to `TID_W` and follow the rules in §4.15. A 2-thread, 3-wide core must remain a valid configuration, so per-thread structures (rule 7 caps, partitions) are sized from both `TID_W` and the width parameters.

### 6.3 Hook checklist and cost
- **The checklist:** 28 items, in `research_notes/…/multithreading_smt_cmt.md` §6. It becomes `docs/spec/threading.md`.
- **Cost in the ST bring-up build:** the hooks cost under 1% of LUTs, with no extra stages.
- **Cost of the full SMT2 logic:** about 6.4K LUTs per core (estimate, §6.5). The release configuration (`TID_W = 1`) is synthesised from M6 to measure it.

### 6.4 Path

| Stage | Configuration |
|---|---|
| ST (bring-up, M2–M6) | 2 cores × 1 hart, 2-wide: `st` (`TID_W = 0`). Not released. |
| **v1 (first release)** | **SMT2** on the 2-wide core: 2 cores × 2 harts = 4 Linux CPUs; `smt2` (§6.5) |
| **v2** | **3-wide decode added to the SMT2 core**: `smt2_w3` (§4.15), on the XCK26 via §8.5 |

**SMT2 and 3-wide** trade off differently, and reinforce each other:

| Direction | Model result ([SMT2 study](perf/smt2_report.md), M1) | Est. cost per core vs ST | Strength |
|---|---|---|---|
| SMT2 (v1, the §6.5 configuration) | weighted throughput 1.36 / 1.43 / 1.45× ST at 30 / 120 / 250 cycles; single thread +2.5% | +8.3K LUTs | throughput, mostly on memory-bound code |
| 3-wide decode with a third ALU | +13% single-thread suite IPC; 6.08 CoreMark/MHz on rv64gc | +6.0–7.7K LUTs (§4.15) | single-thread performance |
| Both (v2) | 1.67 / 1.74 / 1.75×; single thread +18% | +15.5–17.5K before area recovery | both |

- **Complements:** 3-wide adds 22% to an SMT2 core but 11% to a single-thread one.
- **Order (D14, D16, decided 2026-10-13):** SMT2 ships in v1, and 3-wide is added in v2.
  - Both are on the KV260, through the area-recovery plan (§8.5).
  - v2's sizes come from its own freeze.
  - **For v2's discussion after v1 (the user's notes, 2026-10-23, not yet decisions):** v1 fills 95.9% of the XCK26, so 3-wide's estimated +6.0–7.7K LUTs a core does not fit beside two full SMT2 cores. Ways to validate it on the KV260 anyway:
    - the full-feature 3-wide SMT2 core as one core with two threads (1C2T) on the board, and as two cores with four threads (2C4T) in simulation first;
    - a lean 3-wide version that fits, for board tests.
    - The width is a build parameter (`DECODE_WIDTH`, `N_ALU`; `st_w3`, `smt2_w3`), so 2-wide and 3-wide come from the same RTL.

### 6.5 SMT2 configuration of the first release (decided 2026-10-13)

v1, the first release, is configuration `smt2` (§4.15): `TID_W = 1`, sized by the acceptance rule on two-thread throughput ([SMT2 study](perf/smt2_report.md) §8).

| Structure | ST bring-up (1 thread) | v1 release (SMT2) |
|---|---|---|
| ROB | 48 | **80**, static halves of 40 |
| LQ CAM / completion buffer | 16 / 8 | **24** / 8, halves of 12 / 4 |
| SQ | 12 | **20**, halves of 10 |
| Long-latency tags | 16 | **24**, shared, no per-thread cap |
| Issue queues A0 / A1 / LD / STA / FP | 10 / 10 / 6 / 4 / 10 | unchanged, shared; **each thread ≤ 75% of each queue (required)** |
| Checkpoints | 4 | 4 per thread |
| L1D / L2 MSHRs; physical registers | 16 / 48; 3 × 64 integer, 2 × 64 FP | unchanged, shared; never binding in the model |
| Fetch | — | ICOUNT, one thread per cycle (fetch only) |
| Decode, rename, commit | — | the thread served first alternates; a thread may use slots its sibling leaves idle |
| Predictors | — | shared tables with the TID hashed in; history, RAS and FTQ per thread |

**Model results.**
- **Throughput:** weighted 1.36 / 1.43 / 1.45× ST at 30 / 120 / 250 cycles. SMT2 on ST's sizes reaches 1.30 / 1.33 / 1.34×; the larger window adds the rest.
- **Single thread:** +2.5% over ST, with SMT off.
- **Cost:** about +8.3K LUTs per core (1.9K for sizes, 6.4K for SMT logic). That puts the dual-core at ≈105K LUTs (90%) before area recovery. The free §8.5 levers, built in from the first commit, target ~80%.
- **Trims if needed:** share the checkpoints between threads, halve hart 1's performance counters, or step the window back. Synthesis at M6 (`TID_W = 1`) replaces the estimate.

**SMT can be turned on and off.**
- **Compile time:** `TID_W = 0` builds a core with no SMT hardware at all; the thread hooks reduce to constants. This is the ST bring-up build.
- **Run time** (the release): SMT turns off when hart 1 is offline, through SBI HSM stop or the SMT-off mode of §6.2 rule 10.
  - The core drains, and the static halves merge, so hart 0 gets the whole window: ROB 80, LQ 24, SQ 20, completion buffer 8.
  - The model puts that at +2.5% over ST. The idle SMT logic stays on the chip, so this mode is a convenience and security switch, not a way to save area.
  - The halves split again, after a drain, when hart 1 starts.
- **Every size is a parameter,** so `smt2` (the release) differs from `st` (bring-up) only in its parameter set.

**Design notes from the study.**
- **ICOUNT at fetch only.** Applied at rename, it starves a thread waiting on misses; rename and commit alternate instead.
- **Issue-queue caps are mandatory.** Without them, a stalled thread fills the queues with its dependants.
- **Shared window, an option.** A window shared with 75% per-thread caps adds +2.7–3.7%. It needs age-ordered ROB and LSQ logic that static halves avoid, so it is an option to judge on RTL cost.
- **The shadow cancel is not selective.** The speculative-wakeup shadow cancel also cancels the sibling's issues. That is a measured cost, included above.
- **The store drain re-requests ownership** when a line is evicted after its grant (LSU spec).

---

## 7. KV260 platform integration

### 7.1 PS configuration and clocks
- **PS ports:** HP1 and HP2 carry L2 traffic; HPM0_FPD (100 MHz) carries host control; `pl_ps_irq` carries doorbells to the A53.
- **Clocks:** `pl_clk0` feeds an MMCM that produces `clk_core` and `clk_host` (100 MHz). `clk_core` is 100 MHz since DR-152 and DR-177; the first goal was 200 MHz with a 150 MHz floor. With the integer register file in UltraRAM (DR-174), the MMCM also makes `clk2x` at twice the core clock, so the register file does two accesses per core cycle. There is one clock-domain crossing, at the host bridge.
- **ACLINT timer:** ticks at a fixed rate, e.g. 10 MHz, matching `timebase-frequency`.
- **Fan:** driven from the PL design.

### 7.2 Boot flow
1. KV260 firmware boots A53 Linux from SD.
2. `tanager-host` loads the bitstream with the RISC-V harts held in reset.
3. It copies OpenSBI, the Linux `Image`, the DTB and an initramfs into the carve-out, and sets the latency injector.
4. It releases reset. The boot ROM jumps to OpenSBI, which brings up hart 1 through HSM.

### 7.3 Console, storage and network
- **Console:** the PL UART is bridged to a pty on the A53, with optional Pmod pins.
- **Storage and network:** an initramfs first, then virtio-mmio block, network and RNG devices with back-ends in `tanager-host`, using the coherent L2 DMA port.

### 7.4 Debug
- **Commit trace:** a per-hart BRAM ring plus a streaming mode into the A53 lockstep checker.
  - Early-retired operations emit a retire record first and a writeback record later (§9).
- **Debug module:** our own, implementing RISC-V Debug 1.0 (0.13-compatible). The A53 bit-bangs its JTAG TAP over AXI GPIO, with OpenOCD running `remote_bitbang`. This avoids the ZynqMP BSCAN traps.
- **ILA:** behind a build flag.

### 7.5 Floorplan and tools
- **Floorplan:** a pblock per core. The L2 goes in the UltraRAM columns nearest the PS. Floorplanning starts at spike S6.
- **Tools:** Vivado 2025.2, frozen (§13); Verilator 5.x and Verible, pinned in CI; GCC 14/15 and LLVM, pinned.

---

## 8. FPGA implementation strategy

### 8.1 Protected loops (1 cycle at 200 MHz on a -1-class corner)

The clock target is now 100 MHz (DR-152, DR-177). This section records the loops as they were designed and measured for the first goal of 200 MHz. The 200 MHz-era structures were audited on 10-22: apart from the uncore slices DR-186 turned off, they still guard paths that fail at 100 MHz in the full chip, so they stay (devlog 10-22 01:15 – 07:10).

| Loop | Design rule | Fallback |
|---|---|---|
| Next PC | 64-entry, 2-way LUTRAM micro-BTB (M1 freeze); read, tag compare and target select in one cycle | 32 fully associative entries in flip-flops, one-hot select (−2.0% suite IPC) |
| Wakeup → select | ≤ 10 rows per queue (M1 freeze); AND-OR readiness over 48 ROB + 16 LLT columns; age matrix | Smaller queues (the ALU queues cost about 1.2–1.5% per 2 entries removed) |
| ALU → bypass → ALU | 64-bit CARRY8 adder plus an 8:1 operand mux | Limit ALU0's bypass sources |
| Load-to-use | Index from address bits 11:3; DTLB in M1; compare, way select and align in M2 | 4-cycle load-to-use |
| Mispredict path | Redirect to IF1 directly; pre-decode in IF2, compaction in IF3 | 10 cycles |

**Measured (spikes S2–S6, 2026-10-13, 200 MHz on xck26-2LV; [report](perf/spikes.md)).** Every loop closes without a fallback, given the structures noted:
- **Next PC (S5):** the LUTRAM micro-BTB loop has +1.8 ns. Next PC to the I$ BRAM address has +0.6–0.9 ns, so the zero-bubble redirect holds. The flip-flop fallback is worse on both counts (3.6K LUTs, +0.29 ns).
- **Wakeup → select (S2):** closes with DUP_SEL + EARLY_W in ST, and needs MX in the SMT2 builds (§4.6).
- **ALU → bypass → ALU (S3):** closes with min/max on the 2-cycle path (§4.8). The register file is 2.0K LUTs, as planned. Bank replication for 3 ALUs costs +1.25K, not +2.7K.
- **Load-to-use (S4):** 3 cycles, +0.68 ns, 2.4K LUTs. The DTLB lookup in M1 is the path to watch: +0.17 ns at 88% fill, −0.11 ns in the v2 floorplan.
- **Mispredict path (S5):** pre-decode in IF2 is the worst stage (+0.36 ns at width 3). The 9-cycle penalty stands.

**At width 3 (§4.15)** the same loops get harder, and the spikes measure them at both widths:
- **Rename:** the intra-group dependency check grows from 1 to 3 compare pairs per source; its fallback is a 2-stage rename.
- **Wakeup → select:** a third ALU queue, and more ROB columns if the ROB grows.
- **ALU → bypass → ALU:** three ALU producers make the operand mux about 10:1; the fallback is a limited bypass for the third ALU.
- **Compaction:** IF3 must place three instructions.

### 8.2 Resource budget (estimates; spikes S2–S6 calibrate them)

| Unit, per core | LUTs (0.4) | Draft 0.3 | Change from 0.3 (M1 freeze) |
|---|---|---|---|
| Front end (micro-BTB 64, TAGE 4 × 4K, fetch-directed I$ prefetch, 4 I$ MSHRs) | 6.1K | 5.8K | +0.3K |
| Decode, RVC (fusion, SFB, jump folding removed) | 1.6K | 2.6K | −1.0K |
| Rename, 4 checkpoints, free lists, deferred free, producer table | 1.6K | 2.1K | −0.5K |
| ROB (48), commit, early retirement, traps, CSRs, PMP | 3.6K | 4.1K | −0.5K |
| Issue queues (10/10/6/4/10; 48 ROB + 16 LLT columns) | 2.9K | 4.6K | −1.7K |
| Register files and bypass | 4.6K | 4.6K | — |
| Integer execution | 4.0K | 4.0K | — |
| LSU (split LQ 16 + 8, SQ 12, ownership prefetch, stride prefetcher, 16 MSHRs) | 6.4K | 6.5K | −0.1K |
| MMU | 2.2K | 2.2K | — |
| FPU (Goldschmidt divide/sqrt) | 4.7K | 4.5K | +0.2K |
| **Core total** | **≈ 37.7K** | ≈ 41K | **−3.3K** |
| Uncore (L2 1 MiB control and directory with 48 MSHRs, latency injector, interconnect, AXI, ACLINT, PLIC, UART, debug module, host bridge, trace) | ≈ 13.3K | ≈ 12.5K | +0.8K |
| **SoC total** | **≈ 89K (76%)** | ≈ 94K (80%) | **−5.7K** |

**Measured so far (2026-10-13), replacing estimates where they exist:**
- **Issue queues and wakeup** (S2): 5.3K (ST), 8.9K (SMT2, with MX) and 12.5K (SMT2 + 3-wide), against 2.9K above. That is +4.2K to +6.0K per core for v1.
- **FPU:** 7.6K with the Goldschmidt divider (D17) and 6.2K with radix-4, against 4.7K: +2.9K per core.
- **Within plan:** the register files and bypass (S3), the load path (S4) and the fetch path (S5).
- **v1 dual-core:** 119–123K LUTs before area recovery, and 99–110K after the §8.5 levers (85–94%).

- **These totals are the single-thread ST build.**
  - **ST:** about 4% below the 80% guideline.
  - **The release (SMT2, §6.5):** adds about 8.3K LUTs per core (1.9K for sizes, 6.4K for SMT logic), for ≈105K (90%) before area recovery. The free levers of §8.5 bring it back to about 72–79%.
  - The first real numbers come from spike S6 and the M6 synthesis.
- **Block RAM:** about 42 per core (+6 for TAGE, +0.5 for the Goldschmidt seed table) plus about 18 uncore, roughly 103 of 144.
- **Other resources:** 32 of 64 UltraRAM; about 108 of 1,248 DSPs (+24 per core for the Goldschmidt multipliers).

### 8.3 Memory-primitive policy
- **Inference is checked, not trusted.** Multi-port LUTRAM goes through wrapper modules (RAM64M8/RAM32M16 for synthesis, behavioural models for Verilator); BRAM and URAM use XPM macros.
- **Scripted check:** every synthesis run is checked against the expected primitive counts per module (Vivado can silently drop a RAM read port).
- **No reset on datapath state.**

### 8.4 Trim ladder (in order)

The 0.3 ladder's first three steps (ROB 48, smaller issue queues, a smaller SQ) are already in the M1 freeze. What remains is ordered by IPC loss per LUT saved (M1 model):

| # | Trim | Saves | Costs |
|---|---|---|---|
| 1 | IQ-FP 10 → 6 (drop exception E5) | 0.3K | −0.07% suite; dense FP −13% |
| 2 | Checkpoints 4 → 0 (drop E2) | 0.5K | −0.6%; branchy code −5% |
| 3 | Take complex Zbb off the 1-cycle path | — | timing |
| 4 | DTLB 32 → 16 | — | not modelled |
| 5 | L1s 32 → 16 KiB | 0.2K, 12 BRAM36 | −0.85% |
| 6 | Goldschmidt → radix-4 divide/sqrt | 24 DSPs | −1.3% |
| 7 | L2 back to 512 KiB | 16 UltraRAM | −0.1% on the suite (more on Linux) |
| 8 | `clk_core` down to 175 or 150 MHz | — | — |

Latency structures (MSHRs, LLTs, completion buffer, prefetchers) are not exempt: the feature ledger judges them by the same rule as everything else. A trim is refused only if it breaks the MLP target or creates a cliff at 250 cycles. Shrinking the ALU issue queues or the ROB below the freeze costs 1–3% (§2.5) and is not on the ladder.

### 8.5 Area recovery: both releases on the XCK26 (decided 2026-10-13)

**The roadmap stays on the KV260.**
- **ST:** 2-wide, 1 hart. The bring-up stage, ≈89K LUTs (76%).
- **v1, the first release:** SMT2 (§6.5).
- **v2:** SMT2 + 3-wide (`smt2_w3`, §4.15).

**The gap.** The first-pass per-unit estimates put the dual-core at:
- v1: ≈105K LUTs (90%);
- v2: ≈120–124K LUTs (103–106%).

They are conservative: unit-by-unit guesses, counted before LUT packing and before moving work into the device's idle DSPs, BRAM and UltraRAM. This section is how the gap closes.

**Target.** v1 at about **80% of the XCK26** (≈94K LUTs), at ≥ 150 MHz (goal 200). v2's limit is set by measurement.
- **Why there is a limit at all.** Utilisation is limited by placement, routing and timing, not by LUT count alone. As the device fills:
  - the placer loses freedom, so related logic spreads out;
  - routing congests around the PS interface and the BRAM, URAM and DSP columns;
  - nets get longer and Fmax falls;
  - run times grow;
  - room for debug cores (ILA) and late fixes disappears.
  This design is especially exposed: deep 1-cycle loops (wakeup-select, bypass) and many wide multiplexers.
- **Two more ceilings besides LUTs:**
  - **LUTRAM:** it needs SLICEM sites, about 57K of the 117K LUTs. Register files, issue queues, ROB and rename use them heavily.
  - **Control sets:** they limit how flip-flops pack.
- **How the limit is set.**
  - **Working assumption:** 85% (≈100K LUTs).
  - **The fill test:** spike S6 measures Fmax at 80%, 85% and 90% fill with real core logic.
  - **The decision:** up to 90% (≈105K) is allowed if timing still closes at ≥ 150 MHz (goal 200) and IPC × Fmax favours the extra logic. For example, v2's 3-wide +13% IPC is worth it only if going from 85% to 90% costs less than about 13% of Fmax.

**Levers identified so far**, per core unless noted. All are estimates, to be replaced by synthesis results.

| # | Lever | Saves | IPC cost | From |
|---|---|---|---|---|
| R1 | Performance counters in DSP48E2 accumulators (cycle, instret, HPM, both harts), not LUT incrementers | 1.0–1.5K | none | first commit |
| R2 | Cold CSRs (scratch, epc, tval, tvec, cause, envcfg …) in one LUTRAM array indexed by (TID, CSR); hot CSRs stay in flip-flops | 0.5–1.0K | none: CSR access is serialised | first commit; pays in v1 (SMT2) |
| R3 | Rename maps in multi-ported LUTRAM with versioned checkpoints, not flip-flops with 32:1 read muxes | 0.3–0.6K | check recovery latency | first commit, if S5 agrees |
| R4 | Integer DIV/REM on the Goldschmidt unit's DSP multipliers; the radix-4 integer divider goes | 0.4–0.6K | none, or faster divides | first commit |
| R5 | FMISC conversions share the FMA's normaliser and rounder | 0.3–0.5K (measured: −584 in FMISC, +150–250 in the FMA) | ≤ 0.09% suite IPC (modelled upper bound) | first commit (being built, 2026-10-13) |
| R6 | L1 TLBs as set-associative LUTRAM, not fully associative CAMs | 0.3–0.5K | small hit-rate loss (model) | first commit |
| R7 | Cold storage in BRAM: FTQ PCs, commit-time ROB payload, page-walk cache, BTB metadata | 0.3–0.6K | none (latency hidden) | first commit |
| R8 | EX-only bypass with LUTRAM write-through, no WB bypass level | ~0.5K (measured: 51–305 LUTs) | none, if the write path closes timing | **rejected** (spike S3: no timing gain) |
| R9 | Store-to-load forwarding for aligned same-size stores only; others wait | 0.2–0.3K | measurable (`fwd_strict` in `tgsim`) | if the model agrees |
| R10 | The 4 checkpoints shared between the two threads | ~0.5K | small (model) | v1 (SMT2) |
| R11 | Third ALU's register reads through shared, arbitrated ports (≤ 7 per bank) instead of replicated banks | ~1.7K (measured: 0.71K) | port conflicts (model); timing worse (S3: −0.32 ns) | v2 (3-wide) |
| R12 | Asymmetric third decoder: common subset only (ALU, load/store, branch); CSR, FP, AMO and system ops decode in slots 0–1 | ~0.2K | rare (model) | v2 (3-wide) |
| R13 | Simple third ALU: add, logic, compare, Zba; shifts and Zbb stay on ALU0/1 | ~0.4K | steering conflicts (model) | v2 (3-wide) |
| R14 | Implementation: LUT6_2 packing, F7/F8 muxes, area-optimised directives on non-critical units, no datapath resets | 2.0–3.0K | none | always |
| R15 | Lean uncore build: trace and debug buffers trimmed, L2 MSHR state in LUTRAM | 1.5–2.5K per SoC | none | v1 (SMT2) |

**Effect of the identified levers.**
- **Savings:** about 8.6–11.9K per core, plus 1.5–2.5K in the uncore.
- **v1 (SMT2) dual-core:** the first-commit levers plus R10, R14 and R15 bring it from ≈105K to about 84–92K LUTs (72–79%).
- **v2 dual-core:** ≈98–105K LUTs (83–90%) from the conservative 124K starting point; ≈94–101K from 120K.
- **The rest of the gap** to v2's limit (85–90%) comes from two places: real synthesis numbers, which the estimates are expected to overstate, and further levers found during RTL design.

**Spike S6 result (2026-10-13): fill test and measured fit.**

*Fill test* (whole-device floorplans):

| Configuration | Fill | Slack (Fmax) |
|---|---|---|
| v1 (SMT2) | 83.9% | +0.105 ns (204 MHz) |
| v1 (SMT2) | 88.3% | +0.007 ns (200 MHz) |
| v2 (SMT2 + 3-wide) | 89.3% | −0.238 ns (191 MHz) |

- **What limits it:** routing congestion is moderate. The limits are the protected loops (S2 MX, the 3-ALU loop, the DTLB), not routing.
- **The utilisation limit:** plan with **85%**; treat **88–90% as the ceiling** if M6 synthesis agrees. The synthetic filler routes more easily than real logic.

*Measured fit* (spikes plus the FPU; plan estimates elsewhere):
- **v1:** 119–123K LUTs before recovery. The levers above, without R8, save 12.7–20.1K per SoC, leaving **99–110K (85–94%)**. Holding 200 MHz at about 88% (103K) needs the levers in their upper half, or some of these:
  - 8-row ALU queues: about 2K per SoC, −1.2–1.5% IPC;
  - the radix-4 divider (the D17 fallback): 2.8K, −2.4%;
  - ROB 64 for the SMT2 window: about 2.6K in the scheduler, −1.5%;
  - R14 applied to the scheduler and the FPU;
  - accepting 190–195 MHz.
- **v2:** 136–144K LUTs before recovery and 113–128K after (97–109%). **v2 does not fit as planned. It needs a re-plan, not only levers:**
  - a smaller window;
  - readiness computed only over the columns a queue can depend on;
  - fewer ALU-queue rows;
  - or 3-wide without SMT2.
- **This triggers the deferred area-recovery study below:** v2 cannot fit, and v1 is close to its ceiling.

**Contingencies** (they cost IPC):
- the SMT2 window steps back to ROB 64 (−1.5% throughput);
- exceptions E1–E5 dropped (about −1.3K);
- 16 KiB L1s.

**Process.**
- **Free levers** (marked "first commit") are adopted now. They carry forward, because the RTL is width- and thread-generic from the first commit.
- **Levers with an IPC cost** (R6, R9–R13) go through the acceptance rule in reverse: adopted if the LUT saving (%) is at least the IPC loss (%). They are judged by the area-recovery study below.
- **Every configuration has per-unit LUT budgets in CI:** `st`, `smt2`, `st_w3`, `smt2_w3`.
- **Spike S6** floorplans the `smt2_w3` dual-core as well as v1, and runs the fill test.
- **M6** synthesises all four configurations.

**Area-recovery study, model side: done (2026-10-14; [area_recovery.md](perf/area_recovery.md)).** Decisions:

| # | Item | Status |
|---|---|---|
| AR-1 | Wakeup tags (16), every configuration | **Adopted** (no IPC cost; §4.6) |
| AR-2 | R9 (strict store forwarding) and R10 (shared checkpoints): −0.04% / −0.00% at most | **Held as the first reserve.** They share or reduce function, which D18 puts last. |
| AR-3 | v1 keeps D15's structures and uses no IPC-costing lever. With tags it fits 103K at 200 MHz if every unit meets its budget (92–104K projected). | **Adopted.** A bigger window (ROB 96, LQ 32, SQ 24: +1.84% throughput, +0.69% single thread, ≈0.7K per core) is **kept as an option and not adopted** (user, 2026-10-14). It can be reconsidered when the measured fit leaves room. |
| AR-4 | v2 re-plan: `smt2_w3` with tags (plus R9, R10, R12 and completion buffer 8 if needed); R11 and R13 dropped (both fail the rule); target 180–190 MHz. At 190 MHz v2 still beats v1 at 200 MHz by +15.6% throughput and +9.3% single thread. | Direction recorded; v2 comes after v1 |
| AR-5 | Fill test at 180–190 MHz with v2's core (with tags), at 90 / 93 / 96% | **First result (2026-10-14):** v2 with tags closes 180 MHz at 94.2% fill: 110,280 LUTs, +0.049 ns. The worst real paths are S3's ALU loop (+0.178 ns) and fetch (+0.19 to +0.20 ns); the scheduler has more than 1 ns of slack. The 90, 95 and 96% points and v1 at 93% are running ([area_synth.md](perf/area_synth.md) §5). |
| AR-6 | Reserve order. **v1:** R9, R10, FP queue 8, LD queue 4, then release builds without the commit trace (DR-121, last; development builds keep it). **v2:** 8-row ALU queues. Everything else fails the reverse rule. **Radix-4 is out of the reserve (user, 2026-10-14, DR-118):** re-measured at 1,036 LUTs, it fails the reverse rule. | Ranking only |
| AR-7 | Re-measure the real RTL after the core track's no-IPC area pass, then redo the fit | **Done (2026-10-14; [area_recovery.md](perf/area_recovery.md) §7).** The area pass took `st` from 88K to 45.1K LUTs, and AR-1 to 44.4K. With F/D the `st` core is 56.5K against a 38.2K budget, and `smt2` 62.5K against 46.1K. The uncore is 22.3K against 10.8K. **v1 ≈ 155.7K (133%) against 103K at 200 MHz and 110.3K at 180 MHz; v2 ≈ 182K.** |
| AR-8 | The gap is implementation, not IPC. D18 step 1 (no-IPC work) continues unit by unit against the per-unit budgets before any clock or reserve decision. Step 2 (180 MHz) is worth 7.2K but needs the user's approval (DR-137); the reserve about 2.2K per SoC. | **Adopted** (coord, within D18). **Progress:** v1 went from ≈155.7K to ≈141.3K after the second pass, then to ≈127.0K after the third pass with DR-113's settings (the uncore under the same settings), 24.0K over 103,040; the FPGA-friendly rewrites (DR-123) continue. **Refit after the core's fn2 pass (area_recovery §7.7; cores at 7d60948, uncore at 9be0707, all measured):** ≈118.4K with hart 1 on the budgets' basis. With hart 1 in RAM form and its measured PMP descriptor select (≈4.3K per core, [hart1_ram_form.md](perf/hart1_ram_form.md)) v1 is **≈118.6K** (+15.5K over 103,040; +6.9K at 180 MHz); as second copies it would be ≈123.1K. DR-133's URAM operands are rejected: gate 3 missed 200 MHz by about 5 ns of wire to the device's single URAM column. The SoC's DSP slices (DR-136, 78e40f5) then took the uncore from 19,933 to 18,603 at smt2: **v1 ≈117.2K with hart 1 in RAM form** (+14.2K over 103,040; refit 87e0cea). **Refit after fn4 (DR-139's PMP sharing) and the L2's S2 restructure (59ae4ad): ≈115.7K in RAM form.** Against the measured fill ceilings, which are the user's decision under DR-137:
- 200 MHz: +6.3K over 93.4% (109,407), or +4.1K over the harness-only 95.3%;
- 150–180 MHz: 0.6K under the device limit (≈116.3K), since 99.3% closes at all four clocks.
Watch item: the SoC's per-site DSP default (not merged) adds about 0.76K to the uncore. **Timing (10-15 01:00):** the units close 200 MHz out of context, but the integrated core does not. The whole `st` core placed and routed alone at 200 MHz reaches WNS −7.071 ns (about 83 MHz; fn3 1c0eaca). Every deep path family is 10.5–12 ns at 15–32 levels, 65–75% of it wire, and all are true paths, so none fits uncut at 150–200 MHz:
- the LSU's address stage (AG → DTLB → PMP → decisions; fix: move the TLB and PMP into M1, M6's split brought forward);
- the front end's DE (decode and the redirect compare; fix: `pc + imm` in F2's predecode, else one more stage) and F1/F2 (ITLB/PMP and the I$ miss restart);
- the D$ atomic read-modify-write;
- rename.
Their reserve cuts are measured on the RTL (cycles, st/smt2):
- fault reports a cycle later: about 0;
- the head DTLB retry: about 0;
- store completion and replay mark: +0.1 to +0.4%.
The uncore misses by 1.8 ns on the L2's S2 path (restructured cycle-identically, 0a29936).

**Fill test by clock (S6 method, v1 with tags, 10-15):** 93.4% closes 200 MHz (109,407 LUTs, +0.037 ns), up from 88%; 98.3% closes 180 MHz (≈115.2K, +0.057 ns; 97.3% +0.071 ns); 98.3% closes 150 MHz (+0.492) and 170 MHz (+0.183), where the device's placement, not timing, is the limit: 99.3% closes 150 MHz (116,301 LUTs, +0.459 ns, about 800 LUTs left on the device). At 200 MHz, 95.3% misses by 0.037 ns only on a harness filler register (11 levels); the worst real path keeps +0.077 ns, so the real ceiling there is about 94–95% (≈110–111.6K). 99.3% closes 160 MHz (116,295 LUTs, +0.262 ns) and 170 MHz (116,306 LUTs, +0.250 ns) too, so 150–170 MHz reach the device's limit. 99.3% closes 180 MHz as well (merged 16ee6b2). **The fill test is complete:** 150–180 MHz all reach the device's limit (≈116.3K), and 200 MHz holds 93.4% (≈94% for real paths). These are inputs to the user's clock decision (DR-137); the target stays 200 MHz. (At 17:21 RAM form was ≈119.9K; the earlier ≈116.4K / ≈115.2K left out the PMP select.) The `smt2` core is 45,055, 1,065 under its line before hart 1. The uncore, 19,933 against 10.8K, is more than half of the gap; its DSP pass (DR-136) is estimated at −4.0K. **Timing first (DR-142, the user, 10-15 11:35):** v1 fits at 150–180 MHz, so effort goes to timing closure. Area work happens only alongside it, within the ≈0.6K margin; the 200 MHz area gap waits for the clock decision. **The cuts under Linux on the board (DR-141, 10-15 12:57, fec03ee):** against the fallback, the default costs +0.6% averaged over 18 Linux tests (memcpy 1 MiB +2.4%, Dhrystone +2.3%, tlbwalk +1.1%, syscall +0.9%; CoreMark 0). Without #2 it costs +0.25%. #2 alone costs syscalls +3.4% and goes back to the user (DR-140). **The full chip (G4, spikes.md §8.3, 10-15 15:23, 63b788f):** v1 in `kv260_top` at 200 MHz (two smt2 cores at 759ea6a, 107,536 LUTs, 91.8%) reaches WNS −10.041 ns, about 67 MHz. The cores set it (core 1's LSU `r_data_q` → the ROB's `g_ft` write enable, 32 levels): about 4 ns worse than a core alone. The uncore misses by −7.145 ns internally (−0.7 to −1.0 ns out of context): the placer split an L2 bank across the device (10.6 of 12.0 ns wire). The crossbar's core-side paths are 6–8 ns of wire on 6–7 levels. Next: G4-FP (the same design with pblocks: the L2 banks compact, then one per core) measures what placement recovers at zero cycles; interface registers that cost a cycle would be DR-135 items. **G4-FP (a), the L2 banks and crossbar in pblocks (spikes.md §8.4, 10-15 19:47):** the split bank was placement: its path goes from −7.1 to −1.2/−1.5 ns (the SoC's cycle-identical registered response shape would close the rest). The uncore's worst is now logic depth: probe pending → probe sent across both banks, 17–18 levels (−6.80 ns; 200 MHz holds about 12), which needs RTL. The crossbar's core-side paths gain 1.7–3.3 ns of wire but still miss by about 3 ns. The L2 → PS memory path gets 1–2 ns worse, because the banks sit at the URAM column (X2), two columns from the PS ports (X0). Chip −9.382 ns (the cores, at 759ea6a). So the L2 floorplan stays, and the uncore needs RTL on its deep paths plus a register stage at each long interface; a stage that costs a cycle is a DR-135 item. (b) (each core's LSU against the crossbar) follows. **The margin reconciled (spikes-2, 10-15 20:53):** G4 placed 107,536 LUTs, but its smt2 cores run hart 0 only until M7. Adding hart 1 in RAM form (+7.4K, about 3.7K per core with the PMP descriptor select) gives about 114.9K against the ≈116.3K device limit at 150–180 MHz: **a margin of about 1.4K**, not the refit's 0.6K. The refit's other differences are small: cores +0.3K (out-of-context and in-context sizes are about equal), uncore +0.56K (in context the uncore comes out about 1.3–1.5K smaller than out of context). Caveats: hart 1 as second copies would put v1 about 3K over, so RAM form is required. Changes since G4's 759ea6a (the SoC's +0.4K out of context, core-2's later work) are not in it. **The uncore passes 200 MHz out of context for the first time (soc-2, 10-15 21:00, merged 4a0be01):** +0.030 ns in the ExtraTimingOpt placement, −0.322 ns in the default one (one design varies by 0.1–0.2 ns between placements). It comes from two cycle-identical changes: the response shape held in registers, and the probe pick made a cycle ahead. The second takes G4-FP's −6.80 ns probe loop to about 8 levels. Still failing in the default placement, at −0.25 to −0.32 ns each: the L2 error flag, the allocation into the pick register, the D channel's cross-bank credits, and the victim read-out into the data array's address. The AR slice (DR-143) is on; the B slice is an optional reserve. **The full chip with today's timing work (G4 refresh, spikes.md §8.5, 10-16 01:03):** main 4a0be01 + fpu-2's 50fee76 (core-2's fn7 with DR-144) in the default profile, with G4-FP (a)'s L2 floorplan. **Chip −7.978 ns, about 77 MHz** (G4 −10.04, (a) −9.38). The worst path is core 0's DTLB → ROB at 28 levels; the 2,000 worst paths are 15–23 levels (22–31 in G4). Uncore internal −5.19 ns (directory RAM → MSHR state). The core alone at core-2's MR head is −3.836 ns (113 MHz), so the full chip costs about 4 ns more than the core alone. **Area:** 108.6K LUTs placed (cores 44.8K / 45.0K, uncore 18.7K, 1.0K more than G4). Plus hart 1 in RAM form (+7.4K), that is about 116.0K against the ≈116.3K limit at 150–180 MHz: **a margin of about 0.3K**. Today's timing work used most of the 1.4K. **Target changed (DR-145, the user, 10-16 01:25):** 125 MHz preferred, 100 MHz minimum, v1 stays 2 cores × SMT2. A study first (full chip at 125 and 100 MHz with hart 1 emulated, fixes per target, cuts and slices that can go off, the model against NaxRiscv); every resulting decision is the user's. **Study, full chip at 125 MHz (spikes.md, 10-16):** G5, the fn7-era core: 82 MHz without hart 1's area (−4.14 ns), and 64.5 MHz with a 7.4K filler at 98.4% fill (−7.50 ns; it routes only with free placement and spread logic). **G5R, core-2's fn10 head 63e51b4, performance build (TG_COMMIT_TRACE=0), filler, L2 pblocks: −2.61 ns, about 94 MHz at 96.1% fill (112,572 LUTs).** The cores set it (DTLB → LSU M2, 24–29 levels, 60–70% wire); uncore −1.32, core ↔ uncore −0.34 / −0.85. 100 MHz is about 0.6 ns away. The fn10 smt2 core alone reaches 113.7 MHz (−0.79 ns at 125). **The smt2 core alone meets 125 MHz out of context (core-2, 10-16 11:12, 4101948: fn10 + A10b + A4): WNS +0.028 ns, 125.4 MHz,** every path group in slack, with cycle-free restructures only; post-route LUTs 45,681 → 46,049 for all of fn9 and fn10 (+368), against the trace switch's −1,420 per core in trace-off builds. core-2's cut review: the core keeps every timing cut at 125 and at 100 MHz (about 0.2% of the Linux boot at stake in total). **G6, the full chip at 125 MHz on today's RTL (spikes-2, 10-16 14:50, 1a17ef1; main 7c99e84 + core-2's 764e3ad + soc-2's b46e893, hart 1's filler, L2 pblocks, performance build): −1.65 ns, about 104 MHz, so the 100 MHz minimum is reached with hart 1's area included.** 110,516 LUTs placed (94.4%; cores 43.6K each, uncore 15.8K; the performance build also drops the uncore's trace lanes), so the performance build has about 5.8K left to the device's ≈116.3K limit, though fill costs clock. Cores −1.65 / −1.64, uncore −1.06 (L2 bank 1's directory → MSHR state, 14 levels, 78% wire), core → uncore +0.25, uncore → core −0.66 (inside core 0), PS paths +4.5 / +5.1. The worst 2,000 endpoints are 14–20 levels (G5R 17–23). The 20 worst paths are all in the LSU, within 0.06 ns: DTLB → M2 forwarding (24–28 levels, about 60% wire), the M2 address → the LQ's store-tag enable (20 levels, 71% wire), DTLB → the replay registers (19–20 levels). soc-2's write-enable fix holds: the URAM cascade enables pass with +1.61 ns (−0.87 before). Next: core-2's closing plan for 125 MHz (cycle-free fixes, stage options with cycle costs), soc-2's for the uncore's two paths. **Caveat (10-17):** every synthesized core from fn6 (0c4b011, 10-15) until the fix 24ada50 had rename's free-list `pop` tied to an undriven implicit net in Vivado (rn_fire used before its declaration in a generate block; Verilator resolved it, so every simulation passed). The board's two-core hang traced to it. G4-refresh, G5, G5R and G6 and the budget LUTs in that window are therefore likely optimistic around rename, and the 115 MHz runs (G7 onward) re-measure on the fixed tree. **G7 (spikes-2, 10-17, spikes.md §8.7), the full chip at 115.315 MHz on the fixed rename with hart 1's filler, about 110.5K LUTs placed (94.4%):** main 82463e2 reaches about 107.6 MHz (−0.622 ns, 2,296 failing endpoints). With fn11 it reaches about 105.4 MHz (−0.817 ns, within the 0.37 ns placement noise measured between identical runs), with half the failing endpoints (1,175) and 39% less TNS. With fn11 plus LSU pblocks it drops to 96.7 MHz (−1.671 ns), so that floorplan is dropped. The rename fix costs 54 LUTs per core. 115 MHz still needs 0.6–0.8 ns, mostly wire (66–80% of the delay at 13–17 levels): in the cores, the D$ write enables, DTLB → replay, M2 forwarding, the LQ enables and the ROB field table's write enables; in the uncore, the L2 bank's internal paths (0.3–0.7 ns). The instruction-queue paths that fpu-2's QUEUE_DECODE switch (+648 LUTs on the chip) targets are not in G7's failing list, so it stays off. Fill is a timing lever at this size: 92% → 98% fill cost about 17 MHz in G5. **Study, the model against NaxRiscv (smt2-study, area_recovery.md §6.2, 10-16, merged c64cc3c):** v1 as built (one L1D miss in flight, no prefetchers) ÷ NaxRiscv at 135 / 150 MHz, one thread: at 100 MHz 0.86 / 0.79 on the suite and 0.60 / 0.58 on memsuite; at 125 MHz 1.03 / 0.95 and 0.64 / 0.62. With four L1D misses in flight: 1.13 / 1.04 and 1.34 / 1.29 at 100 MHz, 1.36 / 1.25 and 1.49 / 1.44 at 125 MHz (four threads: 1.82 / 1.68 and 1.88 / 1.82 at 125 MHz). **Misses in flight are worth more than the clock:** at 125 MHz four of them add 32% on the suite and 132% on memsuite (one thread); 100 → 125 MHz adds 19–20% and 8–11%. Per clock, v1's core leads NaxRiscv's by 1.37–1.43× on cache-resident code; the single-miss L1D holds it back. The timing-cut profiles move nothing measurable in the model. **core-2's answers (10-16 12:28):** (1) The model's store starvation can't happen in today's RTL: the smt2 core runs hart 0 only until M7, and a waiting store takes the MSHR ahead of a load miss. M7, where two harts share the LQ, SQ and MSHR, needs per-hart fairness in the store drain and the load replays (the model deadlocked five thread pairs without it). (2) A paper estimate for more misses in flight, per core (today's D$: 2,707 LUTs, 286 FFs, 32 RAMB36): 2 misses +300–400 LUTs and +150 FFs, 4 misses +450–600 LUTs and +260 FFs, plus about 100 LUTs for a release buffer and a store-address prefetch; no block RAM; twice that for the chip, so it needs an offset (trace off, −1,420 per core, or a cut). Clock risk moderate: the allocation and the refill wakeup each gain 1–2 levels; registering them, a cycle each on a 20+ cycle L2 round trip, should hold 125 MHz. Correctness risk medium-high (probes against in-flight misses, overlapping Release and Acquire, victim reservation): it needs probe-stress and two-core coherence soak time. Building it is the user's decision (DR-145). |
| AR-9 | v2 per-core budget about 49.7K at 180 MHz, from the 94.2% fill with the uncore on budget. The 3-wide increment measures about +13.2K per core against 6–8K planned. | **Adopted** as v2's budget line |

**Area-recovery study (started 2026-10-13, triggered by S6).**
- **Priority (D18).** IPC comes first. The study proceeds in three steps and moves to the next only when the previous one is exhausted:
  1. **Standard implementation tricks that cost no IPC:**
     - LUT packing, F7/F8 muxes, encodings;
     - LUTRAM payloads; cold state in BRAM or UltraRAM; arithmetic and counters in DSPs;
     - control-set reduction and area directives on non-critical units;
     - R1–R5, R7 and R14.
     These are measured unit by unit in synthesis.
  2. **A lower clock, down to about 180 MHz,** rather than smaller structures. A fill test at 180 MHz sets how full the device may be at that clock.
  3. **Only then the IPC-costing levers,** ranked by IPC lost per LUT saved: smaller queues or window, shared checkpoints, narrower or shared units (R6, R9–R13, and the S6 candidates).
- **Trigger (met).** The study was to run if a release configuration missed its LUT budget at S6 or M6. S6 shows v2 cannot fit and v1 is near its ceiling. The 2-wide RTL work does not wait for it.
- **Scope.** Add each IPC-cost lever to `tgsim` as an off-by-default option, with model support where it is missing:
  - R9, store-to-load forwarding restricted to aligned same-size stores (the existing `fwd_strict`);
  - R10, checkpoints shared between threads;
  - R11, register-read ports shared and arbitrated at select (this needs per-bank read-port counts and a port-conflict check in issue);
  - R12, an asymmetric third decoder;
  - R13, a simple third ALU.

  R6, set-associative TLBs, needs an MMU in the model, which `tgsim` lacks.
- **Measurement.**
  - **Configurations and latencies:** each lever, and the combination that passes, on the configurations it applies to, at 30, 120 and 250 cycles.
  - **Metrics:** single-thread suite IPC, and weighted speedup for SMT2 builds (the SMT2 study's pairs).
  - **Verdict:** the reverse acceptance rule at 120 cycles, against the synthesised LUT savings where they exist and the estimates above otherwise.
- **Output.** `docs/perf/area_recovery.md`, with verdicts and the resulting fit. Adopted levers enter the feature ledger.

---

## 9. Verification and debug

| Layer | Tooling | When |
|---|---|---|
| Unit tests | Verilator or cocotb testbenches; random-versus-model checks for execution units; TestFloat for the FPU; random traffic and scoreboards for caches and the L2 | From each unit's first commit |
| Formal | SymbiYosys on free lists, age matrices, FIFOs, arbiters and the deferred-free queue; riscv-formal through RVFI | M2 onward |
| ISA lockstep | Spike as a library, compared commit by commit, with rules for legal differences. **Early retirement:** the RTL emits a retire record, then a writeback record carrying the value. The checker holds the comparison until the value arrives. The same applies to the SFB, folding and fusion options when enabled (instruction count per record). | From day one |
| ISA suites | riscv-tests; riscv-arch-test (ACT4 with Sail) | M2–M3 |
| Random programs | FORCE-RISCV, plus our own generator aimed at LSU, ordering and early-retirement corners (flush storms over pending retired loads) | M3 onward |
| FP divide/sqrt | TestFloat on the Goldschmidt unit, plus directed hard-rounding cases for its remainder correction, and back-to-back pipelined operations with mixed precisions | From the unit's first commit |
| Width builds | Both the 2-wide/2-ALU and 3-wide/3-ALU configurations pass riscv-tests and Spike lockstep in CI. The random generator covers 3-instruction groups with intra-group dependencies and two branches per group (§4.15). | M2 onward |
| Coherence | Murphi or Rumur model before the L2 RTL; TL-C assertions; multi-agent random traffic; axe | Model at M5, RTL at M7 |
| Memory model | litmus-tests-riscv on FPGA, run with the latency injector at 0, 120 and 250 cycles (latency changes interleavings) | M7 |
| Linux | Buildroot boot in simulation from architectural checkpoints; Debian and stress on hardware | M3+ |
| FPGA lockstep | Commit trace streamed to the A53 checker | M4+ |
| Snapshots | Fork-based simulation snapshots | M2 |

Simulation speed: 5–30 kHz in Verilator. Long runs belong on the FPGA.

---

## 10. Performance methodology

### 10.1 Model before RTL (`tgsim`): done in M1
- **What it is:** `perfmodel/`, an execution-driven, cycle-level C++ model, written from scratch.
  - Its own RV64/RV32 instruction-set simulator (IMAFDC, Zicsr, Zba, Zbb, Zbs, Zicond) feeds the correct-path stream to the timing model.
  - This replaced the planned Spike-trace front end, because the clean-sheet rule meant writing our own simulator anyway.
  - Built with GCC 15.2 in WSL Ubuntu 24.04; the workloads are built with xPack GCC 15.2.
- **What it models:**
  - every mechanism in §4, including the options that are off in v1 (fusion, SFB predication, jump folding, the wait table);
  - the width options (`decode_width`, `alu3`, pair decode);
  - a second load pipe and a second FMA pipe;
  - the Goldschmidt and radix-16 dividers.
- **Calibration:**
  - **Against NaxRiscv's published RV32 IPC:** worst error 8.9% (CoreMark +8.9%, Dhrystone +0.2%, Embench −5.7%).
  - **RV64 cross-checks:** DMIPS +1.7%; soft-float Embench −2.0%.
  - **Still to do:** the unmodified NaxRiscv RV64 control run in Verilator on our binaries remains a later check. It needs NaxRiscv's sources, a download to be approved.
- **Latency points:** 30 and 60 (a bracket for native latency until spike S1), 90, 120 and 250 cycles.
- **Results:**
  - [DSE report](perf/dse_report.md): IPC-vs-latency curves, ablations, the early-retirement study, the FPU and decode-width studies, and the freeze validation;
  - [feature ledger](perf/feature_ledger.md);
  - the ST configuration as preset `v1_freeze`;
  - [SMT2 study](perf/smt2_report.md): `tgsim` with two threads (`threads=2`), which sized the release (§6.5).
- **Correlation:** RTL counters must later match the model within 10% (M2–M7).
- **Next model work:**
  - Linux/SPEC-like workloads to re-judge the five provisional exceptions (M5), and multiprogrammed pairs for SMT2;
  - a dual-core model for shared-L2 and DRAM bandwidth with 4 harts;
  - the deferred area-recovery study, if a configuration misses its LUT budget (§8.5).

### 10.2 Benchmark protocol and rules
- **Control:** NaxRiscv RV64IMAFDC, unmodified, in the same simulated memory system and, ideally, on the KV260 behind the same bridge and injector.
- **What M1 found on the CoreMark target (D11).**
  - **Standard rv64gc binaries** from GCC 15 execute about 338K instructions per CoreMark iteration, so 6.0 needs IPC ≥ 2.03, which a 2-wide decoder cannot deliver. The freeze scores 5.31 (flag set A) and 5.16 (flag set B).
  - **Zba/Zbb builds** (rv64gcb) need IPC 1.82 and reach 5.86. Pair-decode fusion lifts that to about 6.0–6.07, flag set A only.
  - **NaxRiscv's published 4.94** came from a modified CoreMark ("u32 as s32" plus unlisted flags), so it can't anchor an absolute target.
  - **On identical binaries,** Tanager is 1.34–1.48× the NaxRiscv-like control, against the 1.21× that 6.0 vs 4.94 implied.
- **CoreMark target (D11, decided 2026-10-13).** CoreMark/MHz at least **1.21× the NaxRiscv control's**, for each flag set, on identical binaries.
  - **Reporting:** absolute scores are reported alongside.
  - **Where 6.0 goes:** 6.0 on rv64gc becomes a target for the 3-wide version (the M1 model gives 6.08 / 5.92 there).
  - **Which control:** the NaxRiscv-like model until M4/M6, then unmodified NaxRiscv RV64 RTL on the same binaries.
- **CoreMark rules:**
  - EEMBC-valid runs: at least 10 seconds, unmodified core files, the memory-to-core clock ratio reported.
  - `rv64gc` binaries; one pinned GCC; two flag sets, both reported, and both must meet the ratio:
    - `-O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las` (the SCR1/SSRV set);
    - `-O3 -funroll-loops`.
  - The same binaries for the NaxRiscv control.
  - No predictor state or tables trained on the benchmark.
  - A CoreMark-motivated feature is accepted only if it does not regress Embench or the Linux suite.
  - `rv64gc_zba_zbb_zbs_zicond` builds are reported separately, as extension gains.
- **Suites:**
  - Dhrystone under its ground rules (`-O3 -fno-inline`); Embench-IoT, version pinned.
  - SPEC CPU2017 intrate test/train inputs if a licence is available. Otherwise sqlite, xz/zstd, a Lua interpreter, a gcc compile and the 7-zip benchmark.
  - Linux boot time; lmbench `lat_mem_rd` and `bw_mem`; STREAM.
  - **MLP microbenchmarks:**
    - pointer chains (8 and 16 chains, with 0 or 16 independent instructions between hops; §2.5);
    - a strided column walk and a gather with dependent work, whose misses have consumers waiting in the window.
  - **Model suite (`perfmodel/bench`, revision 2):**
    - CoreMark (flag sets A and B), Dhrystone, the 19 Embench programs, and 11 memory kernels;
    - targeted kernels for large code, branchy L2-resident code, store-to-load aliasing and dense FP.
- **Every memory-sensitive result is reported at all latency points.** On hardware, the injector supplies them.
- **Minimum performance-counter set:**
  - cycles and retired instructions; fused, predicated and folded counts (when those options are enabled);
  - mispredicts by type; micro-BTB and BTB misses; override bubbles;
  - I$, D$ and L2 misses, with prefetch-useful and prefetch-late counts;
  - TLB misses and page walks;
  - full stalls on the ROB, each issue queue, LQ, completion buffer, SQ, LLTs, MSHRs and free lists;
  - shadow cancels, replays, ordering violations, forwarding hits;
  - early-retired operations;
  - fetch-starved cycles; commit-blocked cycles by cause;
  - occupancy histograms of outstanding misses.

---

## 11. Phases and milestones

Durations are wall-clock estimates for an **agent-built** project (D8): Claude agents write the RTL, testbenches, scripts and host software. The earlier estimate (2.5–3.5 years for 2–3 engineers) assumed people writing the code and no longer applies. The FPU units were built in parallel and are done; their integration into the core is part of M3. Every speculative or latency feature has its own enable bit, for bisection and ablation.

| Milestone | Content | Exit criteria | Wall-clock (agent-built) |
|---|---|---|---|
| **M0 Foundations** | Repository, CI, coding rules, Spike lockstep (including deferred writeback records), unit-spec templates. Spikes on XCK26 at 200 MHz:<br>S1: PL→DDR latency and bandwidth, idle and loaded; loader, carve-out and SMMU checks.<br>S2: one queue's wakeup-select over ROB and LLT columns.<br>S3: 3-bank register file with 2 ALUs and the shared store-data port, plus the replicated-bank variant for 3 ALUs.<br>S4: load path.<br>S5: 64-entry LUTRAM micro-BTB loop, I$, pre-decode in IF2 and compaction in IF3.<br>S6: dual-core floorplan dry run with a 1 MiB L2, for `st`, the `smt2` release and the `smt2_w3` (v2) area estimate. It includes a fill test (Fmax at 80%, 85% and 90% LUT utilisation) that sets the utilisation limit (§8.5). | Loops close or fallbacks are chosen; KV260 latency known; front-end, back-end, LSU and L2 specs reviewed | About 1 week, overlapping M2. The spikes need Vivado and the board. |
| **M1 Model and DSE** | `tgsim` calibrated; sweeps at the latency points | v1 parameters frozen through the acceptance rule and recorded in the feature ledger; predicted CoreMark ≥ 1.21× the control (D11; was ≥ 6.0); suite margin ≥ 1.2× at all latency points; early-retirement go/no-go | **Done 2026-10-13.**<br>Freeze approved; margin 1.62–1.69×; CoreMark 1.46× / 1.34× of the control; early retirement GO.<br>[DSE report](perf/dse_report.md) |
| **M2 Core alpha (sim, ST)** | RV64IM, M-mode, single-thread bring-up (`st`). Conservative out-of-order: commit-time recovery, wakeup on confirmed hits, a simple predictor behind the FTQ, 1-MSHR D$. **TID, LLT and deferred-free plumbing in place; width-generic front end, rename, dispatch and commit (§4.15).** | riscv-tests and CoreMark/Dhrystone pass in lockstep, **in both the 2-wide and 3-wide builds** | **Done 2026-10-14.** Lockstep passes in all four configurations. `st`: CoreMark 3.04 / 2.88 CM/MHz (flag sets A/B), Dhrystone 1.66 DMIPS/MHz, from the conservative M2 core; M6 adds the performance features. First synthesis: 88K LUTs against a 38K budget, so an area pass comes first (D18). |
| **M3 Linux-capable (sim)** | A, C, privileged modes, Sv39, PMP, ACLINT, PLIC, UART, boot ROM, Zba/Zbb/Zbs/Zicond/Sstc. **F/D integration moves here from M5 (2026-10-13):** the FPU units are already built and verified, and with F/D in place the board runs the same `lp64d` image as QEMU, with no soft-float userland. | ACT4 passes, including F/D; OpenSBI and Buildroot (`lp64d`) reach a shell in Verilator | 1–2 weeks. **Progress 2026-10-14:** A, C, S/U, Sv39, PMP and interrupts built behind switches; riscv-tests 280/280 and ACT4 rv64imac 355/355 pass. **F and D are in the core (2026-10-14), on by default.** In lockstep with Spike, in all four configurations: ACT4 rv64imafdc 895/895, riscv-tests 284/284 (with rv64uf/ud), and random rv64gc programs. **Next:** OpenSBI and Buildroot (`lp64d`) to a shell in Verilator. |
| **M4 KV260 single core** | KV260 top, simple single-agent L2, `tanager-host`, commit-trace streaming, **latency injector** | Linux on hardware at ≥ 100 MHz; FPGA lockstep; Linux boots at 0 and 250 injected cycles | About 1 week; board work starts during M3. **Progress 2026-10-14:** stage A and spike S1 done (36.8-cycle idle DDR read at 200 MHz); stage B's traffic-generator bitstream passes bring-up steps 1–5 (memory path 0 errors at native and 250 injected cycles; the PMOD console works; Linux's fan control kept). **Linux on the board (18:18):** the M4 bitstream (one `st` core at 60 MHz, SoC 20435b1) runs the SoC test program to PASS and boots OpenSBI 1.9 and Linux 6.18.56 to a root shell and a clean poweroff, at native latency (TANAGER-BOOT-OK in 8 s) and at 250 injected read cycles; native latency while Linux ran averaged 19.8 cycles (max 54) at 60 MHz ([fpga/kv260/README.md](../fpga/kv260/README.md)). Met: Linux boots at 0 and 250 injected cycles. **FPGA lockstep met (21:58):** the verification track's A53 checker (`tanager-lockstep`, Spike as a library) checked all 335,786,888 commit records of a Linux boot to a root shell and poweroff on the board, with no difference (native latency; 39 min to TANAGER-BOOT-OK under the checker against 8 s unchecked), and at 250 injected read cycles (355,612,637 records, no difference; 23:26). `tanager-host load` zeroes the RISC-V window first, because Linux checksums bytes past the end of its device tree that nothing wrote. Left: at least 100 MHz. **The 100 MHz build misses by 3.761 ns** on 3,914 endpoints, all inside the core, in two cross-unit path families that per-unit timing runs cannot see: `u_lsu/r_data_q` → `u_rob/exr_*` (38 levels, ≈13.5 ns, through EX, the walker's leaf logic, the DTLB, the load PMP and the CSRs) and `u_ex/wbq_q` → `u_rob/cmp_q` (35 levels, ≈13.3 ns). The core track now owns a whole-core 200 MHz timing run and the cuts; any cut that moves a cycle goes to the user under DR-135 ([results.md](../fpga/kv260/results.md)). **Met 2026-10-17:** Linux on hardware at 100 MHz, with two cores: build sc3_100 (main 5172c6a, two smt2 cores with the commit trace and stage C's hardware; WNS +0.347 ns) boots Debian 13 and runs gcc and sysbench at about 1.45× the 70 MHz results. |
| **M5 Debian** | virtio-blk served by the ARM (interim), then the PS peripherals driven by the RISC-V with the ARM parked (board stage D, DR-126); coherence model (F/D moved into M3) | Debian 13 boots; SPEC-like workloads run | About 1 week after M4. **Progress 2026-10-17 (board stage C, DR-147):** Debian 13.7 boots on two Tanager cores on the board (sc2, 70 MHz) the standard way: OpenSBI, U-Boot 2026.07, then Debian's own kernel package (6.12, SMP) from a virtio disk the A53 serves; systemd reports running with no failed units. virtio-net is bridged onto the LAN (DHCP, DNS, time, `apt-get update`). Stage C's hardware and software are on main (5172c6a). **10-17, later:** at 100 MHz (sc3) Debian boots from the RISC-V's own SD partition, apt installs gcc and sysbench, and the workload set runs (CoreMark 276.9/s per core, 547.2/s for two; Dhrystone 140.6 DMIPS). **Stage D (10-17/18):** D0's probes, D1 (the RISC-V's window to the PS's peripherals), D2 (the fan regulated from the PL) and D3 (the RISC-V's console on the PS's UART1, DR-163) pass on the board; D4 (the A53 hands SD1 to the RISC-V with kexec, DR-164) is approved for a daytime run. **D4 met (10-19, DR-172, which replaced DR-164's kexec handover):** two exclusive modes chosen at boot from a record in SD sector 2047. In RISC-V mode the A53's boot script loads the bitstream, hands SD1, UART1 and the fan to the RISC-V, and parks; Debian 13 boots from p3 through the PS's SD controller (14.9 MB/s reads). Debian's reboot stays in RISC-V mode; `tanager-mode arm` or a PMOD UART break returns to Ubuntu. **D5 met (10-19):** in RISC-V mode Debian drives GEM3 with its own macb and dp83867 drivers. The link runs at 1 Gb/s with a DHCP lease, ping and SSH work, scp runs at 1.77 / 2.09 MB/s (bounded by SSH on the cores) and `apt-get update` works. No PL change was needed; riscv.scr releases the PHY's reset and sets GEM3's clocks before the A53 parks. **Left:** USB driven by the RISC-V; the final D4 bitstream from main with DR-141's rerun and a 24 h soak in RISC-V mode. **2026-10-20:** RISC-V mode's occasional loss of SD1's interrupts (about one boot in 11) was traced to a race in the core and fixed (DR-176). d4r2, d4r1's build with the fix, meets 100 MHz and is under a 60-boot check before the 24 h soak. |
| **M6 Performance (ST)** | Micro-BTB (64), TAGE-lite (4 × 4K), RAS repair, 4 checkpoints, speculative wakeup with replay, early retirement, 16 MSHRs, early ownership prefetch, I$/stride/stream prefetchers, Goldschmidt divide/sqrt; 200 MHz single core; synthesis of all four configurations (`st`, `smt2`, `st_w3`, `smt2_w3`) against their LUT budgets (§8.5) | All single-thread §0 targets at all latency points (via the injector); model correlation within 10% | 2–4 weeks; 200 MHz timing closure is the long pole. **Progress 2026-10-18 (DR-153, at 100 MHz under DR-152):** on main, four L1D misses in flight (DR-156) and speculative load wakeup (DR-154): CoreMark 3.06 → 3.44 / 2.79 → 3.11 CM/MHz (flag sets A/B), Dhrystone 1.48 → 1.59 DMIPS/MHz (rv64gc timed regions, RTL simulation). **The first M6 set merged (aae0503, 22:00):** the 32-entry RAS, TAGE-lite with two tagged tables of 2K entries (DR-170), returns and straddlers at F2 with fpu-2's restructured F2 (DR-165), and the two rename levers (DR-169): CoreMark 4.55 / 4.27 CM/MHz, Dhrystone 3.08 DMIPS/MHz; the 20M-cycle boot retires 14.2% (st) and 12.7% (smt2) more than before the merge; about +2.1K LUTs per core. Full chip at 100 MHz with hart 1's area: with the RAS about 95 MHz (within DR-162); with TAGE as first built about 66 MHz from a 40–44-level F2 path; with F2 restructured cycle for cycle (DR-165) and ExploreArea (DR-166) the M6 set routes at 100 MHz, +0.725 ns, no failing endpoint, 97.1% of the LUTs (spikes.md §8.11–8.12). The model (tgsim rtl_m2 revision 7) tracks the RTL with a 4.2% mean error over 17 programs. **10-19:** the merged M6 (31e65c6) routes at 100 MHz with hart 1's area, +0.348 ns at 97.1% placed (spikes.md §8.13). PMP with 8 entries (DR-167) saves about 2,970 LUTs a chip. **On the board under Linux (100 MHz, three boots):** CoreMark 4.61 / 4.36 CM/MHz and Dhrystone 2.82 DMIPS/MHz (2.77 / 2.29 and 1.41 before M6), /init 21% sooner, instructions per operation unchanged. The board found a micro-BTB alias bug that every simulation check had passed (Linux panicked at about 2.2 s); it is fixed (c261c1f) with a directed test (ab6cd47). **Later on 10-19:** FENCE.I by generation (855922a, +23 LUTs a core) and the store ownership prefetch (c072fff, +31 LUTs, on by default) merged (DR-171). On the board's d4r1 against d4s2: page faults −28.1%, memcpy 1 MiB −34.5%, /init 0.929 → 0.831 s (−10.5%), with CoreMark and Dhrystone unchanged. Over the whole boot to /init, the model ranks the I$ next-line prefetch next (+1.7%); the DTLB replay from the LQ is parked (+0.30%). **The I$ next-line prefetch merged (d3e124a, IPF_ON on by default):** +109 LUTs a core. Simulating as the board runs, /init comes 2.30% sooner (0.586 → 0.573 s). make perf is −0.16% / −0.20% cycles. Every suite total is faster, though a few random programs are 3.5–8.8% slower because useless prefetches evict lines they need. The RTL run as the board runs predicted d4r1's /init within 0.1% (area_recovery.md §6.14). DR-174 holds the integer register file in UltraRAM as the next area reserve, built behind a switch (URF, off). |
| **M7 SMT2** | `TID_W = 1` with the §6.5 configuration: second hart, per-thread partitions and caps, ICOUNT fetch, second CSR file and counters, TID-scoped flush and memory ordering, run-time SMT-off. Per-hart lockstep; random tests aimed at sibling interactions. | Linux on 2 harts of one core; weighted throughput at step 7's measured result, about 1.2× ST (DR-184, replacing 1.3×), with no pair hangs and no loss for one thread alone; SMT-off mode works; litmus with sibling harts clean | 1–2 weeks. **Progress 2026-10-21 (DR-175):** the plan was approved on 10-19: eight steps, each behind a switch and cycle-identical with hart 1 off, about 5.3K LUTs a core, so DR-174's URF is expected to switch on. Steps 1–6 are on main (step 6, run-time SMT-off with merged halves while hart 1 sleeps, at 124edb9f, 10-21), with `SOLO_TID`, a test mode that runs the one thread as tid 1, and `HART1` (TG_HART1), which builds the second hart. FP banks of 64 with renaming across both banks are on main (DR-179, −1,630 LUTs a core). **Linux on all four harts passes under lockstep** (smp4, 109.0M records to 100M cycles on 5f). Exit 2's merged basis on 5e: 1.203 / 1.169 / 1.136. 5f gained what the model predicted (+1.4% / +3.5% / +4.2% on the half basis), and step 7 with 5f is about 1.20, 0.09–0.12 under the 1.3 bar (1.24–1.28 at best), and the user took step 7's measured result as exit 2 (DR-184). Step 6 measures 1.216 / 1.190 / 1.173 on the merged basis. stride + Dhrystone hangs at 120 and 250 until step 7's R2. **The full chip with hart 1 and URF on (hp1) places at 97.2% and −0.096 ns with DR-181's L2-bank and crossbar floorplan** (−2.098 ns without). DR-180's release builds take −1,783 LUTs a chip. **Step 7 is on main (002ea157, 10-23):** the bank rule on the sibling's need (a thread may not take an issue-queue bank's last row while its sibling waits for a row there), groups short of rows waiting at rename while split, and no per-thread cap. The plan's ICOUNT with a 75% cap and the 50% caps all slowed the two-hart Linux boot by 2–3%. The 42 pairs run 204 of 204 with no hang at 1.226 / 1.217 / 1.192 (exit 2, DR-184); the two-hart boot band is +0.68% on five points and +0.15% on nine, within noise (DR-189); +161 LUTs a core. Next: step 8, then the M8 release build. The area exploration (spikes §8.18) found the levers for M8's area pass (DR-183, DR-185). The litmus suite (on the SoC with harts 0 and 1, all 1,716 two-thread tests pass) and the pair runner for the throughput exit (REPEAT method) are ready. The model predicts 1.27–1.31× at step 5 and 1.33–1.35× with step 7's caps. **M7 is complete (2026-10-23): exit 4 is clean on main e394b23a.**
- **Step 8's fixes, found by the four-hart litmus:**
  - CoRR by snoop marking (§4.9, b095eca3): a younger load could keep a value overwritten before its older same-address load read.
  - The FENCE.I sweep (679ceb2c): a refill started during a sweep lost its writes.
- **The RVWMO litmus suite:**
  - 3,504 of 3,504 on four harts (two smt2 cores, tb_boot) at board timing, +120 and +250 injected cycles;
  - 1,716 of 1,716 on one core's two threads (tg_vsim) at the default, 120 and 250;
  - no state herd forbids, none missing.
- **Every exit is met:**
  - Linux on two harts of one core, and on all four (the board at 100 MHz, DR-188);
  - exit 2 at 1.226 / 1.217 / 1.192 with no pair hang and no loss alone (DR-184);
  - SMT-off (step 6);
  - the litmus. |
| **M8 Dual core, four harts** (revised 2026-10-20, DR-177) | Two SMT2 cores (2 cores × 2 harts) on the board in RISC-V mode, the product configuration. **Already running before M8:** the coherent L2 with the host DMA port, two-core SMP Debian 13 on harts 0 and 2 (DR-150; D4, D5), FENCE.I by generation, LR/SC, the litmus suite on two harts. **Four-hart Linux on the board (10-22):** a temporary 80 MHz bring-up bitstream of the product form (DR-187; main with step 6, no step 7) boots on one core's two harts and on all four. On four harts `/init` comes at 59.3 s and the login at 190.4 s. CoreMark validates on every hart, the atomics test passes on every pair, and hart hotplug works; its soak ran 11 h 14 min, 56 rounds, with no failure. **Four-hart Linux at 100 MHz on the board (10-23, DR-188, board MR35):** the preview image from the first product build to close 100 MHz, with PMP checks at TLB fill on. On four harts `/init` comes at 52.3 s and the login at 154.4 s; CoreMark validates on every hart at d4r2's per-MHz figure; three rounds of hart stop and start and the stress 10 of 10 pass; no access fault in any log. Open for soc-2: the page-fault test is 8.8% slower than d4r2 and DDR write streaming about 14% slower. **M8 adds:** the four-hart device tree and OpenSBI (ready, soc-2); coherent I$ refills and LR/SC forward progress checked with sibling harts; the release build with real hart 1 in both cores fitting the XCK26 at 100 MHz. The fit uses DR-174's URF, release builds without the latency injectors (DR-167, taken 10-20) and spikes §7.1's fetch timing fixes. A lower board clock comes only after every other method is exhausted (the user, 10-20). **The fit, revised 2026-10-21:** the full chip with real hart 1 but without the product windows (hp1f) places at 97.2% and −0.096 ns with DR-181's floorplan (−0.426 ns on a second sample); release builds drop the uncore's development-only blocks (DR-180, −1,783 LUTs a chip); the target is about 2K LUTs a chip back from hu1 (DR-181). **The product build (10-22, c0030303 with DR-181) places at 97.2% but doesn't route** (28,100 signals unrouted for congestion): it has hp1f's LUTs but 1,896 more flip-flops, mostly 5d's second rename register. It routes with AltSpreadLogic_high, DR-186's slices off and the ACLINT registers (−1.740 ns), and with DR-185's payload in LUTRAM as a preview at −1.108 ns (TNS −595, 4,296 fewer flip-flops). Flow levers first (congestion-spreading placement, the router's congestion directive, control-set merging), then **the area pass after M7's step 7**, all keeping Linux's speed, in this order: rename's payload in a LUTRAM queue (about 3.4K FFs and up to 1K LUTs a chip); PMP checks at TLB fill with one shared checker per core (DR-183, about 2.5–3K LUTs a chip, behind a switch, after DR-182's per-page check); the issue queues' readiness carry chains (DR-185, −474 LUTs a chip). **All three are on main by 10-22 21:50**, and DR-183's switch is on by default since 10-23 01:15 (its rule: a measured boot cost of 0.17–0.19%, under 1%). **The near-final product chip closes 100 MHz (10-22 23:20, spikes §8.18):** with every timing fix merged or in check (DR-183 with its head register, core-2's LSU and fetch fixes), one of two placements routes at WNS +0.257 ns with no failing endpoint; the other misses by 0.720 ns. A four-hart preview board image at 100 MHz follows from it (DR-188); the release image is built from main.
- **10-23, the litmus exit is met:** the same runs as M7's exit 4, clean on four harts at 0, 120 and 250 injected cycles.
- **rc2 on the board** (main's step 7 with marg3 and CoRR's first commit, 100 MHz in both placements):
  - every planned step passed;
  - its soak lost SD1's interrupt after 15 rounds. CoRR's first form replayed a PLIC claim read; that was fixed by b30b57b3 before rc3 (DR-176's line).
- **The release pair on main (rc3) missed 100 MHz in both placements** (−1.104 / −0.959 ns). rc3's RTL differs from rc2's by a dozen lines; the miss came from synthesis re-rolling the netlist at 96% fill.
- **The release build at 100 MHz is met (10-23 18:30, rc3_u095r):** WNS +0.748 ns, WHS +0.006 ns, no failing endpoint; 112,806 LUTs (96.3%).
  - It is coord/rc3's RTL, which is main's (tag m8-release-rc3).
  - The flow: AltSpreadLogic_high, router directive AlternateCLBRouting, 0.95 ns of placement uncertainty.
  - **The tries before it** were placement luck at 96% fill:
    - fresh placements at −1.104, −0.959 and −0.237 ns;
    - a post-route optimisation pass;
    - incremental runs from rc2's placement (86% reuse), where the placer found no room.
- **rc3 on the board (10-23/24, MR40):** every step passed before the long run. Four harts, with the login at 154.2 s; hart_check 0 fails; 33 rounds of hart stop and start with 0 failed fences; the stress 10 of 10; the DR-141 set and memgap matched u100.
- **The 72-hour stress started at 02:43 UTC on 10-24.** The user stopped it at 05:26 UTC for travel: 16 rounds, 48 stress passes, 0 FAIL (MR41). It restarts on the user's word, on rc3 or on v1's image.
- **Open:** that 72-hour stress. | SMP Debian 13 on 2 cores × 2 harts, booted standalone in RISC-V mode; the litmus suite clean on four harts at 0, 120 and 250 injected cycles (simulation and development builds); 72-hour stress clean on the board; the release build at 100 MHz (DR-152). No fixed LUT ceiling: the measured fill and timing closure decide. The old exit (≥ 150 MHz, goal 200; LUTs ≤ ~80%) predates DR-152 and SMT2 on this part. | About an agent week after M7's step 8, plus the 72-hour stress run |
| **M9 Hardening** | **Scope approved 2026-10-23 (DR-190, [m9-plan.md](spec/m9-plan.md)):** the hardening that costs no LUTs (the trigger CSRs in the spec's no-trigger form, the device tree's ISA string checked against the RTL) and the v1 documentation; Sscofpmf/perf with 4 counters a hart behind `TG_HPM` (up to 1.4K LUTs a chip); an indirect-target predictor sized by smt2-study's model; the debug module with OpenOCD in development builds only. virtio-net is done (stage C; the product uses GEM3). After v1: Svpbmt, Zicbom, Zicbop prefetches, misaligned hardware, store sets, Sdtrig; Zicboz after a page-zeroing measurement. No-IPC area cuts pay for the release additions first. **Sized and added (10-23):** the predictor is the 256-entry path table, estimated at +2.4–2.9% of the two-hart boot's busy cycles. The user added a 16-entry load-wait table: +0.58% on the suite, about 0.2K LUTs a chip, behind a switch. **On main:** the trigger CSRs (b512ef98). Sscofpmf behind `TG_HPM`, off by default, +870 LUTs a chip when on, complete on 10-24: the RTL (889c3b11), lockstep and ACT4 with the counters (d7c2d835; 895 of 895 with them on) and the device tree's `riscv,pmu` node (d6b3ae49; OpenSBI and Linux's SBI PMU driver find the four counters in simulation). The ISA string is decided (DR-194), and the Zkt audit is done (1bae4021). A boot under lockstep with the counters on and `perf` on the board remain. **Also on main, off by default (10-24):** the load-wait table (`TG_LWT`, 68819220), the indirect-target table (`TG_ITT`, mode 2, 3a9f5e1b; the two-hart boot band 2.43% faster) and both halves of the debug module (`TG_DEBUG`, development builds only: 7cf692fc and 11489ea3, about 1.2K LUTs a chip; in simulation it halted, stepped and resumed Linux over JTAG). **First:** structural fixes for the timing families that recur at 96% fill (DR-191). All five are on main (ca06e559, 10-24), with fix 1's follow-up; out of context each takes its family 1–4 ns clear. **The full-chip pair of record on that RTL closes 100 MHz in both placements (10-24): +1.066 ns at 1.05 ns of uncertainty (no core-clock endpoint within 1 ns, against rc3's 668) and +0.337 ns at 0.95 (through congestion level 6), 112,862 LUTs (96.4%).** Closure no longer depends on the placement. **The full-chip fit with every release feature on failed placement (10-24):** 117,539 LUTs after opt_design (100.36%), against 115,724 with the three off; each alone, the counters +277, the load-wait table +424, the indirect-target table +922. Program counters at Sv39 width (DR-195) recover about 2.4K LUTs a chip with no IPC cost. The release package goes to the user with these measured prices once that lands. | **v1 release: the SMT2 dual-core** | About 1 week; parts run in parallel with M8 |
| **M10 v2: 3-wide on the SMT2 core** | `smt2_w3` (§4.15) with its own freeze by the acceptance rule; the `st_w3` bring-up stage first; v2 area-recovery levers (§8.5) | CoreMark/MHz ≥ 6.0 on rv64gc; v2 suite targets; dual-core within the measured utilisation limit on the XCK26 (85–90%, §8.5), ≥ 150 MHz | After v1; about 1–2 months |

**Board stages (user, 2026-10-14; DR-126).**
- **The connection:** the KV260 hangs off the laptop by a direct Ethernet cable with shared networking, and a PMOD UART on the PL is the RISC-V debug console. The 5950X builds; the laptop runs board work.
- **The stages:**
  - **A:** the ARM side up (Kria Ubuntu, the `mem=3G` carve-out, the SMMU check, spike S1).
  - **B:** the RISC-V core: the traffic-generator bitstream, then the real core booting Linux (M4).
  - **C:** the board's peripherals bridged to the RISC-V side, with virtio-blk through the ARM as the interim.
  - **D:** dual boot. The ARM and the RISC-V each have a partition on the SD card. Once the ARM has booted, it can hand everything to the RISC-V, which drives the PS's SD, Ethernet, USB and UART directly, and park.

**Total.** About 3 months to the v1 release (10–18 weeks). Linux runs on the board after about 4–6 weeks, and the single-thread core reaches 200 MHz (M6) after about 2 months. These are first estimates. Re-estimate after M2 with measured rates, as the model was calibrated in M1.

**What sets the pace.** Writing code is not the critical path: an earlier clean-sheet out-of-order core written by Opus reached CoreMark 4.6 in a few days. The time goes to:
1. **Tool runtime.** The current PC has 8 threads and 32 GB, so full-device Vivado runs go one at a time and take hours each (an estimate; S6 measures it). A Linux boot in Verilator also takes hours.
2. **Fixed-length gates:** the 72-hour stress run, litmus at three latency points, and Debian boots.
3. **The board.** The first setup, and recovering a hung board, need a person.
4. **Long-tail bugs** in memory ordering, coherence, Sv39 and sibling-hart interactions. Random tests and lockstep find them, and each fix costs a rebuild.

**How we keep it short.**
- **Parallel tracks.** Independent work runs in parallel sessions, each in its own git worktree: the core pipeline; the FPU; the SoC, board and host software; verification infrastructure. The interfaces between tracks are fixed in `docs/spec/` first.
- **Lockstep against Spike from the first commit,** plus constrained-random instruction streams. Every bug found becomes a regression test.
- **Go to the board early.** Board work starts during M3 with bare-metal programs. Long programs (Linux boots, stress) then run on the FPGA at 100 MHz with commit-trace lockstep, instead of for hours in Verilator.
- **Prove software images on QEMU first.** OpenSBI, Linux and Buildroot images boot on QEMU (already installed) before they meet the RTL. The SoC uses standard device compatibles, so the same images run on both with a different device tree.
- **Small Vivado runs first.** Per-unit out-of-context runs take minutes; full-device runs take hours and go overnight.
- **A faster build machine** (16+ cores, 64+ GB) would shorten M6 and M8 the most.

---

## 12. Risks and mitigations

| Risk | Early signal | Mitigation |
|---|---|---|
| Two cores do not fit within about 80% of LUTs | S6 or M6 synthesis | The M1 freeze brought the estimate to about 76% (§8.2). Per-unit budgets in CI; trim ladder (§8.4), latency structures last |
| Protected loops miss 200 MHz on -2LV | S2–S5 | Fallbacks (§8.1), including 32 flip-flop micro-BTB entries; 150 MHz floor. **Retired:** every loop closed (S2–S6), and the target is 100 MHz since DR-152. The open timing risk is the full chip's routing at 97% fill (spikes §8.18). |
| CoreMark 6.0 out of reach at 2-wide | **Confirmed by the M1 model** (§10.2) | **Resolved by D11:** v1's target is ≥ 1.21× the NaxRiscv control (met in the model, 1.46× / 1.34×); 6.0 moves to the 3-wide version. Report honestly rather than tune to the benchmark. |
| **v1 (SMT2) or v2 (3-wide) does not fit the XCK26.** **Measured at S6 (2026-10-13):** v1 is 99–110K after levers (85–94%) against a ~88% ceiling at 200 MHz; v2 is 113–128K (97–109%). | S6 (done); M6 synthesis of all four configurations | Area-recovery levers R1–R15 (§8.5), the free ones from the first commit; the area-recovery study (triggered by S6); the S6 candidates (8-row ALU queues, ROB 64 window, R14 on the scheduler and FPU); the D17 radix-4 fallback; a v2 re-plan; per-unit LUT budgets in CI for every configuration |
| **The 3-wide reserve rots**: parameters that are never exercised stop working | 3-wide build failures in CI; widths hard-coded in reviews | CI builds and lockstep at width 3 from M2; spikes S2, S3 and S5 at both widths; M6 synthesis of the 3-wide build; §4.15 review rules |
| **The model suite under-represents Linux and SPEC behaviour** (large code, branchy integer code, 0.5–4 MiB working sets, dense FP) | Provisional ledger exceptions E1–E5 | Targeted kernels for now; re-judge the exceptions with Linux/SPEC-like workloads at M5 |
| **Size decisions taken one parameter at a time miss interactions** | M1: issue-queue and ROB trims looked cheap alone and cost 3.2% together | Freeze sizes on the combined design (greedy acceptance rule, §2.5) |
| Goldschmidt divide/sqrt: rounding or DSP-cascade timing | TestFloat; S6 or M6 synthesis | Remainder correction with directed tests; radix-4 fallback (17/31 cycles) |
| **Overfitting to the KV260's short DRAM latency** | Gains that vanish at 120 cycles in the model or injector | Decide at 120 cycles (§2.5); four-point reporting; the injector |
| **Over-building for latency**: structures grown only because DRAM is 120 cycles away | Ledger entries below the acceptance line | Acceptance rule; written, reviewed exceptions (§2.5) |
| Overfitting to CoreMark | CoreMark gains without suite gains | Benchmark rules (§10.2); no benchmark-trained state |
| Early retirement adds subtle ordering and verification bugs | Lockstep or litmus failures at high injected latency | Enable bit; deferred writeback records; targeted random tests; a formal model of the completion buffer |
| PS DDR behaves unexpectedly (A53 contention, SMMU) | S1 | Port and carve-out choice; quiet the A53 while benchmarking |
| Verification drags, especially LSU and coherence | Bug rate at M3–M7 | Lockstep from day one; FPGA lockstep; staged enables |
| **Tool runtime and board access set the pace** (one 8-thread, 32 GB PC: one full-device Vivado run at a time) | M0 spike run times; M6 closure iterations per day | Out-of-context unit runs first; full-device runs overnight; long programs on the board rather than in Verilator; a faster build machine if M6 closure stalls |
| FPU corner cases | TestFloat | TestFloat in CI |
| Linux bring-up stalls on platform details | M3 | Standard compatibles; the pitfall list (§2.2) |
| Vivado churn | 2026.x releases | Pin 2025.2 |
| Scope creep | Change requests | Non-goals (§1); threading as hooks only until M9 |
| Clean-room contamination | Reviews | §2.3 |

---

## 13. Decisions for you

The plan assumes the defaults below; say if any should change. Each default lists its recorded pros and cons (DR-124), the same as in the [decision register](decisions.md); "(not recorded)" marks reasoning that was never written down.

| # | Decision | Default | Alternatives |
|---|---|---|---|
| D1 | HDL | SystemVerilog-2017<br>**Pros:** (not recorded).<br>**Cons:** (not recorded). | SpinalHDL; Chisel |
| D2 | A53 as host | Yes<br>**Pros:** the A53 loads images, bridges the console, serves virtio back-ends and runs a lockstep checker; virtio needs no software cache maintenance; it avoids the ZynqMP BSCAN traps; long programs run on the FPGA at 100 MHz with commit-trace lockstep instead of for hours in Verilator.<br>**Cons:** PS DDR may behave unexpectedly (A53 contention, SMMU), so the A53 must stay quiet while benchmarking; the RISC-V window must be hidden from A53 Linux, setup steps that need a person (S1); the host bridge (1,667 LUTs) and the trace stream (2,853) add to the uncore's excess. | A standalone soft SoC |
| D3 | Vivado | 2025.2, frozen<br>**Pros:** 2025.2 supports the XCK26 for free (ML Standard); pinning avoids churn from the 2026.x releases; 2026.1 uses tiered licences (a one-year CORE voucher ships with Kria kits).<br>**Cons:** (not recorded). | 2026.1 with the CORE voucher |
| D4 | v1 ISA scope | RV64GC + Sv39 + §4.1 extensions; no RVA23<br>**Pros:** runs Debian 13 (RV64GC with lp64d) and Ubuntu 24.04; Zba/Zbb remove 10.3% of the instructions; Sscofpmf is the IPC tuning tool under Linux; Zfhmin completes RVA22.<br>**Cons:** no RVA23 (V and H), so no Ubuntu 25.10+; misaligned accesses trap and are emulated by OpenSBI at first. | V in a release after v2 |
| D5 | L2 size | **1 MiB** (UltraRAM is otherwise unused)<br>**Pros:** its cost is UltraRAM (32 blocks), which nothing else uses; 512 KiB costs −0.1% on the suite, more on Linux; S6: the 4-deep UltraRAM cascade keeps +0.4 ns or more.<br>**Cons:** only +0.1% over 512 KiB, since no suite workload sits between 0.5 and 1 MiB: below the line, so it is kept as exception E3 (re-judged on Linux workloads with 0.5–4 MiB working sets); the 4-deep cascade needs pipeline stages at 200 MHz (hit latency about 7 cycles, 9 with `DATA_LAT` = 4). | 512 KiB if timing or placement fails |
| D6 | Multithreading path | **SMT2 in the first release (D16)**; hooks from the first commit<br>**Pros:** two-thread SMT has delivered +15–60% throughput for 5–25% area in shipping designs; the model gives +33% on the ST sizes and +43% with the §6.5 window, passing the rule by a factor of about 2; the hooks cost under 1% of LUTs, with no extra stages.<br>**Cons:** compute pairs gain only about 15%, pinned by the 2-wide decoder; about 6.4K LUTs per core (estimate); the shadow cancel also cancels the sibling's issues; a CMT experiment is not planned, because a shared front end starves a 2-wide machine. | A CMT experiment |
| D7 | Licence | **Solderpad 2.1 for the hardware, Apache-2.0 for the software (user, 2026-10-14)**<br>**Pros:** the usual split for RISC-V cores; Solderpad adapts Apache-2.0 to hardware, with a patent grant; Apache-2.0 is the familiar software licence.<br>**Cons:** two licences to track (by directory); Solderpad is less known outside hardware. | MIT; proprietary; Apache-2.0 for everything |
| D8 | Team and timeline | **Agent-built (2026-10-13): Linux on the board in about 4–6 weeks, v1 in about 3 months (§11); re-estimated after M2**<br>**Pros:** writing code is not the critical path (an earlier clean-sheet out-of-order core reached CoreMark 4.6 in a few days), and the human-team estimate assumed people writing the code; measured: about 16 hours of wall-clock time from an empty repository to M0, M2 and most of M3.<br>**Cons:** first estimates, to be redone after M2; the pace is set by tool runtime (full-device Vivado runs and Verilator Linux boots take hours), fixed-length gates (the 72-hour stress run, litmus, Debian boots), the board (it needs a person) and long-tail bugs; the account usage limit stops every session at once. | A faster build machine to shorten M6–M8 |
| D9 | Name | **Tanager (user, 2026-10-14)**<br>**Pros:** no rename churn, since the name is already in every module and tool.<br>**Cons:** check for clashes with other projects or trademarks before publishing. | Any |
| D10 | Latency points and rule | **Native, 90, 120 (decision point) and 250 (stress) cycles, with the acceptance rule** (decided 2026-10-12)<br>**Pros:** points above native keep latency-tolerance features from being cut for the wrong reason, and keep the design from leaning on the KV260's short DRAM latency, which a faster FPGA could not hide; the 250-cycle point exposed memcpy halving, which E4 fixed; the rule keeps performance per LUT from falling: big window enlargements usually fail it, and cheap BRAM-backed features usually pass.<br>**Cons:** judging one feature at a time misses interactions (sweeps that each showed under 1% together cost 3.2% of suite IPC, and a single step can look too expensive while the whole step does not); verdicts near the line rest on estimated LUT costs; anything below the line needs a written exception (E1–E5); running the points on the board takes latency injectors (1,481 LUTs in the uncore at 5c124f2). | Other values if a specific future platform is chosen; a different acceptance ratio |
| D11 | CoreMark target | **CoreMark/MHz ≥ 1.21× the NaxRiscv control on identical binaries, for each flag set** (decided 2026-10-13). 6.0 on rv64gc is the 3-wide version's target.<br>**Pros:** it keeps the ratio that 6.0 against NaxRiscv's 4.94 implied, since 4.94 came from a modified CoreMark and cannot anchor an absolute target; identical binaries per flag set; met in the model at 1.46× / 1.34×; the alternatives fall short: 6.0 on rv64gc needs IPC ≥ 2.03, which a 2-wide decoder cannot deliver, and pair-decode fusion reaches about 6.0–6.07 on flag set A only, for about 1K LUTs, and changes what "2-wide decode" means.<br>**Cons:** the control's FMA latency is our assumption, and every ratio moves with it; the control stays a model until M4/M6 (the RTL control needs a download approval); the absolute score is 5.31 / 5.16, not 6.0. | ≥ 6.0 on rv64gcb with pair-decode fusion; 6.0 on rv64gc for v1, which would need 3-wide now |
| D12 | v1 parameter freeze | **M1 freeze, approved 2026-10-13** (§4.14, ledger)<br>**Pros:** +4.6% suite IPC over draft 0.3 for about 3.3K fewer LUTs per core; the SoC estimate fell from about 94K to 89K (76%); in the model the ratio over the control rises with latency (1.615 to 1.691), and CoreMark is 1.46× / 1.34× the control.<br>**Cons:** five provisional exceptions (E1–E5), and several verdicts near the line (early retirement 2.39% against 2.20%); the model is correct-path only, with fixed-latency DRAM and no MMU or supervisor code; sizes were frozen lean for one thread, so SMT2 re-judged the window and miss handling; its LUT estimates were low: the `st` core measures 51,707 against its 38,220 budget (5c124f2). | Re-judge exceptions E1–E5 at M5 |
| D13 | Width | **v1 is finished at 2-wide. Everything width-dependent is parameterized and a 3-wide, 3-ALU build is kept working (§4.15)** (decided 2026-10-13)<br>**Pros:** 3-wide becomes a configuration change plus timing closure, verification and a new freeze, not a rewrite of rename, dispatch and commit; generate loops at width 2 give the same logic as hand-written 2-wide code, so v1 pays nothing; the owner's rule: "for things that can be parameterized, do it"; lockstep passes in all four configurations.<br>**Cons:** unexercised parameters rot, so the 3-wide build must be kept working; timing closure and verification remain real work; the measured 3-wide increment is +14.6K per core (`smt2_w3` − `smt2`), against ≈7.2K planned, with rename at +4.55K against +0.5K. | Hand-written 2-wide logic, which would make 3-wide a rewrite |
| D14 | Roadmap | **v1 = SMT2 2-wide (first release), then v2 = 3-wide added to the SMT2 core, all on the KV260** (decided 2026-10-13). Both fit the XCK26 through the area-recovery plan (§8.5).<br>**Pros:** SMT2 first gives the most throughput for the least logic: 58% of the combined core's throughput gain for 42% of its LUTs; 3-wide then adds 22% to an SMT2 core but 11% to a single-thread one; at 190 MHz v2 still beats v1 at 200 MHz by +15.6% throughput and +9.3% single thread.<br>**Cons:** SMT2 first brings only 14% of the combined single-thread gain (3-wide first suits a single-thread priority); v2 measures 171.1K, 60.8K over the 180 MHz limit, with a 3-wide increment about twice the plan's (DR-117). | — |
| D16 | First release and bring-up | **The first release is the SMT2 dual-core (2 cores × 2 harts).** Single-thread (`st`, `TID_W = 0`) is the bring-up stage (M2–M6), the CI reference and the run-time SMT-off mode; it is not released (decided 2026-10-13).<br>**Pros:** `st` is the same RTL with `TID_W` = 0, so it costs no extra design work; the release gives 1.36 / 1.43 / 1.45× ST throughput and runs one program with SMT off about 2.5% faster than ST; a clean single-thread core with a larger window would not pay for itself (+2.5% for about 4.6% of the LUTs).<br>**Cons:** SMT off at run time keeps the idle SMT logic (about 6.4K LUTs per core); compute pairs gain only about 15%, pinned by the 2-wide decoder; an ST release was put at about 4–6 months sooner. | A single-thread release before SMT2 (about 4–6 months sooner) |
| D15 | SMT2 configuration of the first release | **§6.5, decided 2026-10-13:** ROB 80 in static halves, LQ 24, SQ 20, 24 LLTs, 75% issue-queue caps, ICOUNT fetch; SMT switchable at compile time (`TID_W`) and at run time (hart offline: partitions merge)<br>**Pros:** every step passed the rule on its own: WS_ref 1.359 / 1.428 / 1.446 for 1.88K LUTs; static halves avoid the age-ordered ROB and LSQ logic a shared window needs; the caps stop a stalled thread from filling the queues with its dependants; ICOUNT beats round robin by 0.4–0.8%; `TID_W` = 0 builds a core with no SMT hardware at all; ROB 64 saves only 0.16K once rows wake on tags, for −1.5% throughput.<br>**Cons:** +8.3K LUTs per core, ≈105K (90%) before area recovery; SMT off at run time saves no area; the shadow cancel is not selective, a measured cost; a shared window's +2.7–3.7% is forgone, though it costs more than the model charges. | ROB 64 (−1.5% throughput, −0.5K LUTs); a shared window with caps |
| D17 | FP divide/sqrt unit | **Goldschmidt in v1 (user, 2026-10-13)**, kept despite failing the acceptance rule at its measured cost (+2.4% suite IPC against +1.4K LUTs, 3.7% of the core; §4.12)<br>**Pros:** kept for its latency: +2.4% suite IPC over radix-4 as built (nbody +71%, st +70%, minver +23%); pipelined, so a new operation starts whenever one of four slots is free; its multipliers use DSPs, which the XCK26 has in excess.<br>**Cons:** it fails the acceptance rule (2.4% IPC against 3.7% of the core's LUTs, +1.4K as built); after the FPU's LUT pass it still costs 1,036 LUTs, 29 DSPs and a BRAM18 more than radix-4, not the plan's +0.2K, because the logic around the DSPs is LUTs; 2,262 flip-flops against radix-4's 899; correct rounding needs the remainder step. | The radix-4 unit (`FDIV_RADIX4 = 1`), built and verified. **No longer an area fallback (user, 2026-10-14, DR-118):** after the FPU's no-IPC pass it saves only 1,036 LUTs, which fails the reverse rule. It stays buildable. |
| D18 | Area-recovery priority | **(user, 2026-10-13)** Optimise for IPC first, in this order:<br>1. Standard implementation tricks with no IPC cost.<br>2. A lower clock, down to about 180 MHz, rather than cutting IPC. **Only with the user's explicit approval (DR-137, 10-14):** the coordinator brings the measured case when step 1 runs out; until then every target is 200 MHz.<br>3. Only then shrink sizes, share units, or reduce widths or components (the IPC-costing levers).<br>**Pros:** IPC comes first; IPC × Fmax often agrees with taking a lower clock before IPC-costing levers, and in the middle of v2's projected range every modelled cut together is worse than 190 MHz even by IPC × Fmax; against the measured gap, steps 2 and 3 are both small next to step 1's 38.5K.<br>**Cons:** in the model every trim costs less IPC than the clock it replaces (180 MHz costs −10.0% in throughput × clock, FP queue 8 plus LD queue 4 −0.21%); in the lower fifth of v2's projected range, radix-4 plus 8-row ALU queues at 200 MHz beat any clock below 195 MHz by IPC × Fmax; free levers that share or reduce function (R9, R10) wait in the reserve. | — |

---

## 14. Repository layout and conventions

```
docs/            architecture_plan.md (this file), spec/ (one per unit, with provenance), perf/ (DSE report, feature ledger)
reports/         literature review
research_notes/  sourced notes behind the review
rtl/common/      packages, parameters, primitive wrappers (LUTRAM/BRAM/URAM), FIFOs, arbiters
rtl/core/        frontend/ decode/ rename/ rob/ issue/ regfile/ exec/ lsu/ mmu/ fpu/ csr/
rtl/uncore/      l2/ interconnect/ latency_injector/ aclint/ plic/ uart/ bootrom/ debug/ hostbridge/ axi/
rtl/soc/         tanager_soc.sv (sim top), kv260_top.sv
fpga/kv260/      Vivado Tcl (non-project), XDC, PS configuration, pblocks, utilisation/primitive checks
sim/             Verilator harness, DDR latency model, Spike lockstep, snapshots, checkpoint restore
perfmodel/       tgsim
sw/              boot ROM, OpenSBI platform/DTS, Buildroot/Debian recipes, tanager-host (A53)
tests/           unit, formal, ISA/arch suites, random generators, benchmarks, MLP microbenchmark, litmus
tools/           scripts, CI
```

**Conventions:**
- One module per file, `tg_` prefix; a `_q` suffix on registered signals; parameters in `tg_pkg`.
- Every interface is a struct plus valid/ready.
- No latches; synchronous resets on control state only.
- `tid` ports everywhere a thread ID applies.
- **No KV260 or PS constant inside `rtl/core` or `rtl/uncore/l2`.**

---

## Appendix A. Lesson-to-decision traceability

| Lesson (source) | Decision |
|---|---|
| Multiported structures built from RAM: −45% LUTs, +6% Fmax (RSD) | LUTRAM for everything multiported (§4.4–4.7, §8.3) |
| One register-file bank per writer avoids LVT/XOR (Seznec 2002, Wong, SmolRV64) | Writer-sharded register files (§4.7) |
| A matrix beats CAMs below about 20–24 entries; oldest-first select gains more than 15% (Wong) | Distributed matrix queues with age matrices (§4.6) |
| Replay-based load speculation: +8.9% IPC (RSD); NaxRiscv flushes on a wrong hit guess | Shadow cancel and replay (§4.6) |
| TAGE with repaired history is SonicBOOM's biggest gain; 8 → 64 KB adds only 2.7% | TAGE-lite; M1 sized it at 4 × 4K tagged entries, about 29 KB (§4.2) |
| Taken-branch bubbles cost BOOM part of its gap to RSD; the A73 takes 2 cycles per taken branch | Zero-bubble micro-BTB; M1: 64 entries (§4.2) |
| 6–8 checkpoints cover 88–97% of cycles (Wong) | M1: 4 checkpoints with commit fallback (exception E2), because early retirement makes commit-time recovery cheap (§4.4) |
| SFB predication: 4.9 → 6.15 CoreMark/MHz (SonicBOOM) | M1: +0.17% with TAGE-lite and GCC 15; an option, off in v1 (§4.3) |
| Fusion: −5.4% effective instructions (Celio); the A73 decoder fuses pairs | M1: +0.14%, and jump folding +0.01%; options, off in v1. Pair decode is the only fusion form that pays (+1.7%) (§4.3) |
| M1: behind a 2-wide decoder, extra execution bandwidth barely helps (second load pipe +0.4%, second FMA +0.1%, third ALU +1.2%) | One pipe each; the width question goes to v2 (§6.4) |
| M1: the FPU's leverage is divide/sqrt latency; DSPs are plentiful on the XCK26 | Pipelined Goldschmidt divide/sqrt on dedicated DSPs (§4.12) |
| M1: misses with dependent work need issue-queue and ROB capacity; early retirement cannot retire the dependents | Combined-design freeze; ALU queues grew to 10 (§2.5, §4.6) |
| M1: at 250 cycles, memcpy needs about 28 lines in flight at the L2 | 48 L2 MSHRs with a deeper stream prefetch (§5.1) |
| A73: no conventional ROB limit; loads retire once they cannot fault (Chips and Cheese) | Early retirement with LLTs, a completion buffer and deferred free (§4.5) |
| A73: shallow front end (4-stage fetch, 1-cycle decode vs 3 on the A72) | 9-cycle mispredict path (§3.2) |
| A73: two 6-entry ALU schedulers, multi-cycle integer ops folded into ALU pipes, schedulers its practical limit | Small queues in the sweep; MUL/DIV on P1; queue sizes judged at 120 cycles by the acceptance rule (§2.5, §4.6) |
| SSRV: 6.4 CoreMark/MHz comes from 3-wide issue, a short pipeline and ideal memory, with in-order memory access; its predictor was tuned on CoreMark | CoreMark is won in the front end and branch handling, not the window; benchmark rules ban benchmark-trained state (§4.2, §10.2) |
| No store queue: −16% average, up to −40% (RSD/OPA); store sets near-ideal | 16 + 8 LQ and 12-entry SQ. M1 found no ordering violations to predict, so the wait table and store sets are options (§4.9). |
| Non-blocking L1 +32%, L2 +60% (Wong); blocking evictions inflate L2 latency (Rocket) | 16 MSHRs, no blocking evictions, 1 MiB L2 (§4.11, §5.1) |
| Design principle (2026-10-12): efficient latency tolerance, not latency hiding at any cost | Four latency points; acceptance rule and feature ledger; latency injector; MLP target (§2.5, §5.6, §8.4, §10) |
| The FPU sharing ALU2's write port regressed CVA6S+ | The FPU has its own port and bank (§4.6–4.7) |
| A shared front end starved Bulldozer | SMT2 preferred; CMT only via interfaces (§6) |
| Flush and age logic were Hyper-Threading's real cost | Thread-scoped flush and allocation-order age from v1 (§6.2) |
| Coherence bugs appear after 10⁹–10¹¹ cycles | Protocol model first; FPGA lockstep; litmus at three latencies; 72-hour stress (§9) |
| Vivado can drop a RAM read port silently (SmolRV64) | Scripted primitive checks (§8.3) |
| ZynqMP JTAG tunnelling traps | A53 bit-banged debug TAP (§7.4) |

**The sources named above,** as the literature review gives them (`research_notes/`, `reports/`; [provenance.md](provenance.md) §3.2):
- **RSD:** Mashimo et al., "An Open Source FPGA-Optimized Out-of-Order RISC-V Soft Processor", ICFPT 2019, pp. 63–71 (https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf).
- **Wong:** Henry Wong, FCCM 2016 (https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf) and TRETS 2016 (https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongtrets16.pdf); his PhD thesis, University of Toronto, 2017 (https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf).
- **Seznec 2002:** Seznec, Toullec and Rochecouste, MICRO 2002. The review names it but could not retrieve it.
- **SmolRV64:** an independent design of 2026, described in its project's README (https://github.com/tommythorn/smolrv64); not a paper.
- **SonicBOOM:** Zhao et al., CARRV 2020 (https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf). It is also the source of Rocket's blocking evictions.
- **Celio:** Celio et al., arXiv 1607.02318 (2016).
- **OPA:** ORConf 2015 (https://github.com/terpstra/opa), as the RSD paper measures it.
- **Store sets:** Chrysos and Emer, ISCA 1998 (https://acg.cis.upenn.edu/milom/cis501-Fall10/papers/store-sets.pdf).
- **CVA6S+:** the papers the review names as Tedeschi (arXiv 2505.03762) and Fu (arXiv 2505.24363, CF 2025).
- **Coherence-bug latency:** NaxRiscv's 37C3 slides (2023), on SpinalDoc.
- **The A73:** the Chips and Cheese articles in Appendix B.

---

## Appendix B. Design discussion record (2026-10-12)

**Is NaxRiscv a textbook design?** Architecturally yes: an R10K-style rename table, physical register file, ROB, unified scheduler and LSQ. Its originality is cost-cutting for FPGAs, and it lacks the industry's slot-efficiency tricks. Hence the strategy: same width, better use of each slot.

**Cortex-A73 vs A72.**
- **Per clock:** Chips and Cheese measured a higher IPC ceiling on the A72. The A73's win was performance per watt and area, and sustained clocks.
- **What we adopted:**
  - early retirement (§4.5);
  - a shallow front end, as the 9-cycle penalty target (§3.2);
  - small schedulers as a sweep range (§4.6);
  - MUL/DIV folded into an ALU pipe, which we already had;
  - fusion (§4.3). *In 0.4, fusion became an option after M1.*
- **What we did not adopt:**
  - its 2-cycle taken branches;
  - its lack of memory-dependence prediction. *In 0.4 we match it: M1 found nothing to predict.*
  - a dedicated branch port (branch-first select instead). *In 0.4, branch-first was also removed after M1.*
  - a unified integer/FP register file, which costs too many ports on an FPGA.

**SSRV (risclite).** Its 6.4 CoreMark/MHz is not comparable to our target:
- RV32IMC with 4-wide fetch, 3-wide issue and 3 multiply/divide units; 4.9–5.1 at its 2-wide settings.
- Idealised memories with fetch from any byte address.
- A one-iteration extrapolation, which CoreMark itself flags as invalid.
- A 5-bit-history predictor table filled by running the benchmarks (about 88% accurate, roughly 27 mispredicts per 1,000 instructions).
- In-order loads, stores, multiplies and divides; no interrupts or exceptions; about 30 MHz on a Cyclone IV.

Lesson: CoreMark rewards fetch width, short pipelines and low latency; renaming pays on cache misses.

**Targets.**
- CoreMark/MHz ≥ 6.0 is committed, under the rules in §10.2. That is an IPC of about 1.35–1.55 depending on the binary, so identical binaries are required.
  - *Superseded in 0.4.* The IPC estimate assumed binaries as short as NaxRiscv's modified build. GCC 15 rv64gc binaries need IPC 2.03–2.05, and rv64gcb binaries 1.82–1.84. See D11.
- Mispredicts must stay below about 10 per 1,000 instructions at the 9-cycle penalty, hence TAGE-lite plus SFB.
  - *In 0.4,* TAGE-lite alone holds CoreMark at about 0.9 mispredicts per 1,000 instructions, so SFB became an option.

**Latency principle** (from the project owner). The KV260's 30–60-cycle DRAM must not be over-leveraged, because a faster FPGA could not hide memory latency the same way. This produced §2.5, §5.6 and G7.

**Latency principle, refined** (from the project owner, same day). The 120-cycle target must not justify blindly widening the pipeline or enlarging the ROB and other structures. Optimizations must show meaningful IPC gains relative to their area, timing and complexity costs; the goal is efficient latency tolerance, not complete latency hiding at any cost. A 90-cycle point was added. This produced the four latency points, the testable definitions, the acceptance rule and the feature ledger (§2.5).

**Sources added after the literature review:**
- [Chips and Cheese: Arm's Cortex A73: Resource Limits, What are Those?](https://old.chipsandcheese.com/2024/07/18/arms-cortex-a73-resource-limits-what-are-those/)
- [Chips and Cheese: Cortex A73's Not-So-Infinite Reordering Capacity](https://chipsandcheese.com/p/cortex-a73s-not-so-infinite-reordering-capacity)
- [The Register: Arm Cortex-A73](https://www.theregister.com/2016/06/01/arm_cortex_a73/)
- [risclite/SuperScalar-RISCV-CPU](https://github.com/risclite/SuperScalar-RISCV-CPU) and its design document `wiki/SSRV全解析.pdf`

---

## Appendix C. M1 discussion record (2026-10-13)

**Clean-sheet rebuild of the toolchain** (from the project owner). Nothing pre-existing is reused.
- Everything runs in WSL Ubuntu 24.04, and GCC 15 is used for both host and target (xPack `riscv-none-elf-gcc` 15.2.0-1, host `g++-15`).
- The model, workloads and scripts in `perfmodel/` were written for this project.

**FPU** (question from the project owner: "we need an FPU; does it void the search?").
- **Answer:** No. The FPU had been in the plan, the model and the hard-float binaries all along.
- **What the question exposed:**
  - **A divider error:** the model's divide/sqrt latency was faster than the plan's radix-4 unit. It was corrected, and everything was rerun.
  - **A weighting gap:** FP-heavy code is 5 of the 33 suite workloads.
- **What followed:**
  - a costed second FMA pipe (rejected);
  - FMA latency 4 vs 5 (a timing question);
  - radix-16 and Goldschmidt dividers. Goldschmidt, using DSPs that would otherwise sit idle, was adopted.

**Extra pipes behind 2-wide decode** (questions on a second FPU pipe and a second LSU). Neither pays:
- **The data:** +0.1% and +0.4%.
- **Why:** a 2-wide decoder delivers about 0.9 FMAs or 0.6 loads per cycle at most, so one pipe of each suffices.
- **Under SMT2:** utilisation rises toward the decode cap, but the answer does not change while decode stays 2-wide.

**Decode width** (questions on a µop cache, an extra decoder, 3-wide, issue wider than decode, and Intel E-core decode clusters).

| Question | M1 answer |
|---|---|
| Issue wider than decode? | Tanager already does: 5 issue ports behind 2-wide decode |
| µop cache | At most +1.4%. It does not widen rename or commit, and RISC-V decode is cheap. |
| Decode clusters | They fix x86's serial length decoding, which RISC-V doesn't have, and leave wide rename's cost untouched |
| 3-wide with a third ALU | +13% and CoreMark 6.08 on rv64gc, for about +10K LUTs per core. Most of that cost is register-file bank replication. |
| Building 3-wide on 2-wide later | Possible if the RTL is width-generic from the start (D13); otherwise it is a rewrite of rename, dispatch and commit. Timing closure and verification still need real work. |

**SMT2** (question from the project owner).
- **What SMT2 does not change:** the extra-pipe answers, while decode stays 2-wide.
- **What it changes:** the window and miss-handling sizes, which were frozen lean for one thread.
- **Next step:** an SMT2 extension of `tgsim` will size v2 and compare it with 3-wide (§6.4, D14).

**Freeze approval** (from the project owner). The M1 freeze was approved and this draft updates the plan to it.

**CoreMark target and the 3-wide path** (decisions from the project owner, later the same day).
- **CoreMark:** the target is option (b), at least 1.21× the NaxRiscv control on identical binaries for each flag set. The M1 model gives 1.46× and 1.34×.
- **3-wide:** committed for a later version. This plan finishes 2-wide but must reserve 3-wide, and "for things that can be parameterized, do it."
- **Result:**
  - §4.15 makes every width-dependent structure a parameter: fetch, decode, rename, dispatch and commit widths, ALU ports, banking, register-file and bypass generators;
  - it keeps a 3-wide, 3-ALU build in CI, spikes and synthesis;
  - goal G8 and decisions D11, D13 and D14 record this.

**SMT2 study outcome** (the same day).
- **Results:** SMT2 measured +33% throughput on v1's sizes and +43% with a rule-sized window, at about +8.3K LUTs per core.
- **Decision:** the project owner kept the rule's window, ROB 80, for the SMT2 build (§6.5, D15), after checking that it is 2 × 40 per thread. The single-thread v1 stays at ROB 48.
- **Answers recorded:**
  - **ROB size, SMT on/off:** both are parameters. SMT also turns off at run time, and the remaining thread then gets the whole window.
  - **Does 3-wide fit the XCK26?** A per-unit estimate puts 3-wide at 6.0–7.7K LUTs per core, rather than the first-pass 10K. That makes 3-wide alone (or SMT2 alone) a tight fit at 83–90% with trims, gated by its Fmax.
  - **SMT2 and 3-wide together** exceed the first-pass estimate. The roadmap decision below commits them to the XCK26 anyway, through area recovery (§8.5).

**Roadmap decision** (from the project owner, the same day).
- **The roadmap:** SMT2 first (v2), then 3-wide on the SMT2 core (v3), all on the KV260.
- **The owner's view:** "don't say on larger device, then you just don't try". The estimates are conservative, and there are many ways to save LUTs.
- **Result:**
  - goal G3 now covers v2 and v3;
  - §8.5 lists area-recovery levers R1–R15, from DSP-based counters and CSRs in LUTRAM to shared register-read ports for the third ALU, and how each is adopted;
  - S6 and M6 floorplan and synthesise the v3 configuration early;
  - milestones M9 (v2) and M10 (v3) carry LUT limits on the XCK26.

**Focus and utilisation** (from the project owner, the same day).
- **Focus:** finish the 2-wide v1 first.
- **Area-recovery study:** written into §8.5 as a deferred task. It runs only if a 3-wide configuration misses its LUT budget.
- **Utilisation limit:** asked "why 85%, and can we go to 90%?".
  - **Why it exists:** routability and timing, not LUT count itself. Congestion grows near the hard-block columns and Fmax falls as the device fills. LUTRAM (SLICEM) sites and control sets are separate ceilings.
  - **How it is now set:** by S6's fill test (Fmax at 80/85/90%). Up to 90% is allowed when timing still closes and IPC × Fmax favours the extra logic.

**First release is SMT2** (decision from the project owner, the same day).
- **The question:** asked what "v1" was, and why a single-thread release was still needed now that SMT2 comes next.
- **The answer:**
  - A single-thread build is the same RTL with `TID_W = 0`, so it costs no extra design work.
  - SMT off at run time keeps the idle SMT logic (about 6.4K LUTs per core). A clean single-thread core with a larger window would not pay for itself (+2.5% for about 4.6% of the LUTs).
- **Decision (D16):** the first release is the SMT2 dual-core, and single-thread is the bring-up stage.
- **Renaming:** the plan renumbered the roadmap. The old "v2 (SMT2)" is now **v1**, the old "v3 (SMT2 + 3-wide)" is **v2**, and the single-thread configuration is **ST**.
- **Milestones:** they gained an SMT2 stage (M7) between single-thread performance (M6) and dual-core (M8). Hardening (M9) delivers the v1 release.
- **Older records:** entries above this one use the old version numbers.
