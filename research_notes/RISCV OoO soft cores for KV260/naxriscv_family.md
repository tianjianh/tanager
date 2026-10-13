# NaxRiscv (SpinalHDL OoO RISC-V softcore by Charles Papon / Dolu1990), with VexiiRiscv and VexRiscv as reference points

Research date: 2026-10-12. Scope: microarchitecture, parameters, published IPC/benchmarks, FPGA cost and Fmax, Linux/SMP, limitations, and comparison with the same author's in-order cores. All mechanisms are described in my own words; no source code is reproduced. Abbreviations: CM = CoreMark, DMIPS = Dhrystone MIPS, A7-3 = Artix-7 speed grade -3, KU+ = Kintex UltraScale+, IQ = issue queue, LQ/SQ = load/store queue, RAT = rename table, EU = execution unit.

---

## 1. NaxRiscv microarchitecture and default/max parameters

### Takeaway
NaxRiscv is a parameterizable (plugin-elaborated) RV32/RV64 IMAFDCSU out-of-order core. Its reference configuration has a 64-bit fetch, 2-wide decode/rename, 3 issue ports and 2-wide retire. The back end has a 64-entry ROB, 64 physical registers and a unified 32-entry matrix-style IQ that wakes up by ROB ID. The 3 EUs are 2 ALU/branch pipes plus 1 shared LSU/mul/div/CSR pipe. The LSU has 16-entry LQ and SQ, with a hit predictor giving a 3-cycle load-to-use. Caches are 16 KB 4-way I$ and D$. Branch prediction is a 512-entry BTB, 4 KB GShare and 32-entry RAS, with a 10-cycle mispredict penalty.

Nearly every structure is designed to live in Xilinx-style asynchronous-read LUTRAM. This covers the RAT, the free list, the register-file banks with an XOR-based live-value table (LVT) and the TLB ways. Area and Fmax were prioritized explicitly over IPC. The name "NavRiscV" in the request almost certainly means NaxRiscv; no core by that name was found.

### Cited Findings
**Identity and design goals**
- Name check: a search for "NavRiscV"/"NavRiscv" returned no RISC-V core of that name. The results were unrelated cores (SCR1, cv32e40x, SweRV, a Rust RV32I core). — [WebSearch results (no matching core)](https://github.com/andreasfelix/riscv-core)
- Core features:
  - out-of-order with register renaming, superscalar;
  - RV32/RV64 IMAFDCSU;
  - Linux/Buildroot runs on hardware;
  - portable HDL that targets FPGAs with distributed RAM, with Xilinx 7-series treated as the reference family so far;
  - the toplevel is an empty shell parameterized by plugins.
  - The explicit design goal is relatively low area and high Fmax rather than best-in-class IPC. — [NaxRiscv README](https://github.com/SpinalHDL/NaxRiscv); [NaxRiscv RTD Introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)
- Project history: started October 2021 and later funded by NLnet (NGI0 Entrust grant period 2022-10 to 2024-02). The grant goals were stable Debian, documented binaries/rootfs build, memory coherency, multicore, an L2 cache, and ASIC synthesis with open tools. — [NaxRiscv RTD Introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html); [NLnet NaxRiscv](https://nlnet.nl/project/NaxRiscv/)

**Pipelines and state machines**
- The core is composed of several pipelines:
  - Fetch: raw instruction data per PC, first-level branch prediction, and PC translation.
  - Frontend: align, decode, second-level prediction, allocation and renaming.
  - EUs: operand read, execute, writeback, completion.
  - LSU load: D$ read, translation, older-store dependency check, store-to-load bypass.
  - LSU store: translation, check against younger loads.
  - LSU writeback: committed stores written into the D$.
- There are also separate state machines:
  - LSU atomics: SC/AMO executed in order when they reach commit;
  - MMU refill (hardware page-table walk);
  - privileged (CSRs, traps, mret/sret). — [NaxRiscv RTD Introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)

**Reference "RV32 configuration A" (current RTD performance page; undated)**
- Core widths and resources:
  - RV32IMASU;
  - fetch 64 bits, decode 2, issue 3, retire 2;
  - shared IQ of 32 entries;
  - renaming onto 64 physical registers;
  - 3 EUs: 2x Int/Shift/Branch and 1x load/store/mul/div/csr/env.
- LSU:
  - 16-entry LQ and 16-entry SQ;
  - load hit predictor giving a 3-cycle load-to-use;
  - store-to-load bypass.
- Caches and TLBs:
  - I$ 16 KB 4-way;
  - D$ 16 KB 4-way with 2 refill slots and 2 writeback slots;
  - ITLB and DTLB each 6-way, 192 entries.
- Branch prediction: BTB 1-way/512 entries, GShare 1-way/4 KB, RAS 32 entries. The page notes that more GShare storage or a TAGE predictor should help. — [NaxRiscv RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- The same configuration as described in May 2022 (RISC-V Week Paris slides):
  - 2 decode and 3 issue (2 ALU plus 1 shared EU);
  - 10-cycle branch mispredict penalty;
  - 64 physical registers and a 64-entry ROB;
  - 4 KB GShare and 4 KB BTB (both 1-way) plus a RAS;
  - non-blocking D$; I$ and D$ each 16 KB 4-way;
  - I$ and D$ each with 192 TLB entries (2+4 ways). — [RISC-V Week Paris 2022 slides (nax_040522)](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)
- RV64 configuration: described only as similar to RV32 configuration A (2x Int/Shift/Branch and 1x shared EU). Its full parameter list is not restated. — [NaxRiscv RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- A third-party RV64GC configuration (CEA-Leti, 2026):
  - dual-issue NaxRiscv with a 32-entry IQ;
  - two integer ALUs, one FPU and one LSU;
  - 64-entry ROB and a GShare predictor;
  - 16 KB 4-way L1 I$ and D$. — [Hubinet et al., arXiv 2607.21130 (Jul 2026)](https://arxiv.org/html/2607.21130)

**Rename and recovery**
- Free physical registers are held in a circular buffer, which the docs say suits FPGA distributed RAM.
- Renaming uses three tables:
  - a speculative arch-to-phys map, updated at decode and stored in distributed RAM;
  - a committed arch-to-phys map, updated at commit and stored in distributed RAM;
  - per-architectural-register "location" bits, kept in flip-flops, that select which map is valid. These bits are cleared on a misprediction, so the translation state reverts in one step without walking a structure. No per-branch checkpoints are described. — [NaxRiscv RTD Frontend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html)
- A distributed-RAM table maps each physical register to the ROB ID of its producer. Busy bits are kept per ROB ID: set at dispatch, cleared at completion. — [NaxRiscv RTD Frontend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html)
- Commit has two parts:
  - a "reschedule status" register that records the oldest ROB ID with a pending jump or trap;
  - commit logic that retires the oldest completed instructions and applies any pending reschedule at commit time. — [NaxRiscv RTD Backend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html)

**Issue queue**
- One unified IQ is shared by all EUs, chosen for area and to keep entries well used.
- Layout is 2D: decodeCount columns by slotCount/decodeCount rows. Each dispatch consumes a whole row even if it is partly empty.
- Holes are never compacted. Instead the queue shifts by one row per push, which helps flip-flop inference for the matrix and gives smaller, faster ROB-ID wake logic.
- A half-matrix records which instructions depend on which.
- Wake-up is by ROB ID, not physical register ID.
- Selection is oldest-first per EU.
- 32 slots is described as the practical limit for timing, and IQ area is described as minor relative to the whole CPU. — [NaxRiscv RTD Frontend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html)
- The 2022 talk describes the same IQ: shared between EUs, 32 entries grouped by "wave" (e.g., 2x16), older-first, no compression, matrix design with removal on completion. — [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)

**Register file and multi-porting on FPGA**
- The default register file is "dual-port based":
  - each write port has its own bank;
  - each read port reads every bank;
  - the correct bank is selected through an XOR-based live-value table (LVT) held in distributed RAM.
- An alternative latch-based register file targets ASIC. It stores data in latches, uses tristate read "muxes", and is derived from ibex's register file with multi-write support added. — [NaxRiscv RTD Backend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html)
- A generic SpinalHDL transformation pass handles the many multi-write-port memories in the design. Such memories with only asynchronous reads are rewritten into groups of simple dual-port RAMs joined with XOR logic, because synthesis tools usually cannot infer them directly. — [NaxRiscv RTD Abstraction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/abstraction/index.html)

**Load/store unit**
- Queues: LQ and SQ are typically 16 entries each.
- AGU bypass: when the LQ has nothing pending for the load pipeline, the AGU's fresh address goes straight to the D$, skipping the LQ.
- Hit speculation: a cache-hit predictor speculatively wakes dependent instructions, cutting load-to-use from 6 cycles to 3.
- Store hazard predictor: store address and data both come through the IQ, so late store data can delay the store address and cause store-to-load hazards. A hazard predictor was added on loads to reduce this.
- Store-to-load forwarding is allowed when the load depends on a single older store of the same size.
- Loads translate their address in parallel with the cache read.
- Loads and stores share one pipeline for address translation and hazard checks. — [NaxRiscv RTD Memory](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/memory/index.html)
- Further LSU detail from the 2022 talk:
  - Load-to-use is 3 cycles when the hit prediction is right and 6 cycles when a miss is predicted. A predicted hit that actually misses causes a full pipeline flush.
  - The register file is written 1 cycle before completion.
  - A load checks older stores in the SQ in two passes. The first pass compares only the 4 KB page offset (virtual). The second pass does a full physical compare, only if the first pass found exactly one hit.
  - Store address goes through the IQ, while store data is read directly from the register file.
  - A store checks the LQ for younger conflicting loads using the 4 KB virtual page offset only.
  - The store-side slide also lists four pipelines, without explanation. — [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)
- Design note: keeping stores from waiting in the IQ for their data helps avoid bad load speculation. — [NaxRiscv RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)

**Caches and MMU**
- The D$ is non-blocking with multiple refill and writeback slots. The MMU is hardware-refilled and supports SV32 and SV39. — [NaxRiscv README](https://github.com/SpinalHDL/NaxRiscv)
- TLB organization is "2D": each page-table level gets a configurable number of direct-mapped TLB ways, each inferred into distributed RAM.
- The RV32 defaults are:
  - level 0 (4 KB pages): 4 ways x 32 entries;
  - level 1 (4 MB pages): 2 ways x 32 entries.
- An optional "direct hit" mode lets the I$ compare its way tags directly against TLB storage, trading area for timing. — [NaxRiscv RTD Memory](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/memory/index.html)

**Branch prediction**
- Prediction happens at two levels:
  - In fetch, the BTB (plus GShare) predicts per fetch word: the target, whether the slot is a branch or jump, and which 16- or 32-bit slice ends the instruction.
  - In decode, static jumps, the RAS for returns, and GShare (when the BTB made no prediction) can redirect fetch.
- Decode accepts a BTB-predicted target without recomputing it, because recomputing and comparing would create too long a combinational path.
- A jump/branch circular buffer handles verification and training:
  - pushed at decode;
  - read by the branch EU to detect mispredictions;
  - popped after commit, which is when predictors are trained.
- After a reschedule the RAS pointer is repaired, but speculatively overwritten RAS entries are not. — [NaxRiscv RTD Branch prediction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/branch_prediction/index.html)

**ISA, privilege, debug and tooling**
- ISA: RV32/RV64 IMAFDCSU, with M/S/U privilege modes.
- Debug: JTAG/OpenOCD/GDB per RISC-V External Debug Support v0.13.2.
- Pipeline visualization: Konata/gem5-format traces from Verilator.
- Verification: lock-step checking against Spike. Simulation runs at roughly 150-200 kHz in Verilator. — [NaxRiscv README](https://github.com/SpinalHDL/NaxRiscv); [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)
- FPU:
  - In May 2022, an FPU (as the step toward Debian support) was still listed as planned work. — [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)
  - By July 2022 a third party was benchmarking an RV64IMAFDC (RV64GC) NaxRiscv Verilator model. — [Luffca, 2022-07-16](https://www.luffca.com/2022/07/benchmark-rv64gc-riscv-ooo-simulator/)
  - LiteX builds enable F/D through the scala-args rvf/rvd. — [NaxRiscv RTD Hardware](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/hardware/index.html)

### Inferences
- Branch-mispredict recovery is effectively at commit. Restoration uses the committed RAT plus location bits, and the reschedule is applied by the commit logic. Two consequences follow:
  - The 10-cycle penalty is a best case. A mispredicted branch stuck behind a long-latency instruction (e.g., a D$-missing load) waits until it reaches the ROB head before the frontend is redirected.
  - This trades IPC for very cheap rename recovery: no checkpoint SRAMs and no RAT walk. It is a prime candidate for improvement in a new design, for example a few RAT checkpoints in LUTRAM, or early redirect with lazy RAT repair.
- Load-hit misspeculation causes a full flush rather than a selective replay. The hazard check against older stores compares only the page offset first. Together these suggest NaxRiscv accepts some false-positive serialization and flush cost to keep the CAM narrow and Fmax high.
- Waking up by ROB ID with a physical-to-ROB translation, and filling the IQ by rows without compaction, are both FPGA-specific choices: they keep the wake-up and select logic shallow. Both cost effective IQ capacity, because a half-empty row wastes slots.
- NaxRiscv's heavy use of asynchronous-read LUTRAM maps directly onto UltraScale+ SLICEM LUTRAM on the XCK26. Its structure would port poorly to devices without async-read distributed RAM; VexiiRiscv, by contrast, offers sync-read options.
- XOR/LVT register-file cost scales roughly as (write ports x read ports) full-width LUTRAM banks. A 2-wide RV64 OoO core needs about 4-6 integer read ports and 2-3 write ports. The register file should therefore be costed early.
  - This is my estimate, not a published number: with 64x64-bit banks built from 4-LUT LUTRAM primitives giving 3 bits each, each 1W1R bank costs about 85 LUTs. A 3W x 6R arrangement would then cost about 1.5 KLUT plus LVT and muxes.

### Gaps
- No published maximum parameter ranges were found, such as maximum decode width, IQ size beyond 32, or ROB size beyond 64.
- Missing details:
  - the default port counts of the integer and FP register files in the RV64GC configuration;
  - FPU microarchitecture (latencies, pipelining, sharing);
  - whether fetch is decoupled from decode by a fetch queue;
  - fetch-stage depth;
  - the exact recovery point after a memory-order violation (whether the violating load is refetched);
  - how the load hazard predictor is indexed;
  - PMP support;
  - any hardware prefetcher (none is documented for NaxRiscv).
- The RTD does not restate the RV64 parameter list (TLB sizes for SV39, for example).

---

## 2. Published performance numbers (CoreMark/MHz, DMIPS/MHz, Embench, IPC), with configuration and compiler flags

### Takeaway
The official, most-cited "IPC bar" is the RV32 configuration A, measured in Verilator simulation:
- 2.93 DMIPS/MHz (IPC 1.65);
- 5.02 CoreMark/MHz (IPC 1.28);
- Embench-iot 1.67 (IPC 1.42).

For RV64: 2.94 DMIPS/MHz, 4.94 CoreMark/MHz, Embench 1.84. Adding the FPU (RV64GC) dropped a third party's simulated CoreMark/MHz to 4.59. On real LiteX hardware under Linux at 100 MHz, a third party measured only 3.92-4.01 CoreMark/MHz and 2.11-2.29 DMIPS/MHz (RV32). These numbers date from roughly 2022 and have not been updated since; they should be treated as stale but still current, since NaxRiscv's microarchitecture has not materially changed.

### Cited Findings
**Official numbers (RTD performance page, undated; README repeats the configuration-A headline)**

| Config (all RV32 unless noted) | DMIPS/MHz (IPC) | CoreMark/MHz (IPC) | Embench-iot baseline (IPC) | Source |
|---|---|---|---|---|
| A: RV32IMASU, 2 decode / 3 issue / 2 retire, 2 ALU + 1 shared EU | 2.93 (1.65) | 5.02 (1.28) | 1.67 (1.42) | [RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html), [README](https://github.com/SpinalHDL/NaxRiscv) |
| B: single int ALU, branch moved to shared pipeline | 2.71 | 4.44 | 1.46 | [RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| C: 1 decode, 1 ALU, 1 shared EU | 1.70 | 3.35 | 1.06 | [RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV64 (similar to A) | 2.94 | 4.94 | 1.84 | [RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |

- Compiler flags:
  - Dhrystone: -O3 -fno-common -fno-inline. The run executes 318 instructions per Dhrystone iteration; the Dhrystone variant is not named beyond this.
  - CoreMark: -O3 plus many additional flags that are not enumerated. For RV64, u32 is typed as s32.
  - Embench-iot: -O2 -mcmodel=medany -ffunction-sections for RV32; -O2 -ffunction-sections for RV64.
- IPC is published only for configuration A.
- All numbers come from the Verilator simulator; the page gives run instructions, uses the NaxSoftware baremetal ELFs, and uses the SpinalHDL embench-iot fork. — [NaxRiscv RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- Embench baseline is Cortex-M4 = 1.0. — [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)

**Older (May 2022) numbers for the same 2-decode/3-issue RV32IMASU configuration**
- Dhrystone 2.64 DMIPS/MHz (IPC 1.48, -O3 -fno-common -fno-inline).
- CoreMark 4.70/MHz (IPC 1.19).
- Embench 1.59 (IPC 1.35).
- These are superseded by the RTD numbers above, which are higher. — [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)

**Third-party simulator numbers (Luffca blog, posted 2022-07-16, updated 2022-12-10; GCC 11.1.0)**
- RV32IMA: 5.00 CoreMark/MHz, 2.94 DMIPS/MHz.
- RV64IMA: 4.91 CoreMark/MHz, 2.97 DMIPS/MHz.
- RV64GC (IMAFDC): 4.59 CoreMark/MHz, about 7% below RV64IMA; 2.94 DMIPS/MHz; Whetstone 0.976 WMIPS/MHz.
- Flags match the official ones: Dhrystone -O3 -fno-common -fno-inline; CoreMark -O3 plus many flags. — [Luffca 2022-07](https://www.luffca.com/2022/07/benchmark-rv64gc-riscv-ooo-simulator/)

**Third-party hardware numbers (Luffca, posted 2022-05-21; 32-bit NaxRiscv in LiteX on Arty A7-35T / Nexys Video at 100 MHz, run under Linux/Buildroot, GCC 10.3.0)**

| Benchmark | Hardware result | Simulator result |
|---|---|---|
| CoreMark, -O3 | 392-401 (3.92-4.01 /MHz) | 4.70 |
| CoreMark, -O2 | 366-368 | not reported |
| Dhrystone 2.1, -O3 | 2.11-2.29 DMIPS/MHz | 2.60 |

Source for the table: [Luffca 2022-05](https://www.luffca.com/2022/05/linux-litex-naxriscv32/)

**Application-level numbers**
- About 75 FPS in chocolate-doom at 100 MHz under Linux (May 2022). — [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)
- Chocolate-doom timedemo posted by Dolu1990 on 2024-04-09:
  - NaxRiscv with 128 KB L2: 74.07 fps;
  - VexiiRiscv with 128 KB L2: 64.58 fps;
  - VexRiscv with no L2: 36.15 fps.
  - The author notes that not all options were enabled; clock frequency is not stated. — [VexiiRiscv issue #1](https://github.com/SpinalHDL/VexiiRiscv/issues/1)

**Sensitivity notes from the author**
- An OoO core without branch prediction performs very poorly.
- Two-cycle-latency ALUs, tried in anticipation of RV64 timing relaxation, cost about 15% performance (to be confirmed on more benchmarks).
- Adding EUs quickly reaches diminishing returns.
- Fmax, IPC and area can be traded against one another. — [NaxRiscv RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)

**Secondary-source discrepancy**
- A 2023 survey states that RV64 NaxRiscv at 137 MHz on Artix-7 reached 2.97 DMIPS[/MHz]. — [MDPI survey (2023)](https://www.mdpi.com/2078-2489/14/2/64)
- This differs from the official 2.94 DMIPS/MHz and matches Luffca's RV64IMA simulator figure instead. — [NaxRiscv RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)

### Inferences
- The RTD and README numbers closely match Luffca's mid-2022 simulator runs (5.00 vs 5.02, 4.91 vs 4.94, 2.94/2.97 vs 2.93/2.94). This suggests the official table dates from about mid/late 2022. Commit history shows only bug-fix activity in 2025-2026 (Section 4), so the numbers are stale but are probably still representative of the current RTL.
- The roughly 15-20% drop from simulation to hardware for CoreMark and Dhrystone was measured under Linux with DDR3 at 100 MHz. It likely reflects OS and timer overhead, TLB effects and DRAM latency, not core IPC. When the new core is compared against NaxRiscv, both should be measured the same way (bare-metal simulation, or the same LiteX board and OS).
- Concrete IPC bar for a 2-wide RV64 OoO design that aims to beat NaxRiscv:
  - more than 4.94 CoreMark/MHz (RV64 IMA), or more than 4.59 if FPU-enabled RV64GC builds are compared;
  - more than 2.94 DMIPS/MHz with -fno-inline;
  - more than 1.84 Embench-iot (RV64, -O2);
  - IPC above 1.28 (CoreMark), 1.65 (Dhrystone) and 1.42 (Embench), from the RV32 configuration-A IPC figures.
- CoreMark is a weak discriminator. The in-order dual-issue VexiiRiscv already claims 5.24 CoreMark/MHz (Section 5). The OoO advantage shows up more in Dhrystone and in memory-bound applications such as doom fps.

### Gaps
- Not published:
  - IPC for configurations B and C, and for RV64;
  - IPC and CoreMark for the RV64GC (FPU) configuration from the author;
  - the exact CoreMark flag set (the additional flags are not enumerated);
  - SPEC-class or Linux-workload IPC.
- Not stated: the memory latency model used in the Verilator benchmark runs.

---

## 3. Published Fmax and LUT/FF/BRAM/DSP utilization (Artix-7, Kintex-7, UltraScale+, ECP5; with/without FPU and MMU)

### Takeaway
On Artix-7 -3, standalone core synthesis reaches:
- RV32 configuration A: 155 MHz with 13.3 KLUT, 10.3 KFF, 12 BRAM, 4 DSP;
- RV64 (no FPU): 137 MHz with 17.9 KLUT, 12.5 KFF, 12 BRAM, 16 DSP.

The only UltraScale+ datapoint is from May 2022: 360 MHz on Kintex UltraScale+ -3 for the RV32 configuration, which was then 145 MHz on A7-3. A third party ran RV64GC with an FPU at 175 MHz on Kintex-7 -2.

Real LiteX SoCs on Artix-7 typically run at 100 MHz. Quad-core builds had timing trouble on a Nexys Video (XC7A200T). No ECP5 numbers and no absolute FPU-enabled area numbers were found.

### Cited Findings
| Configuration | Device | Fmax | LUT | FF | BRAM | DSP | Date / source |
|---|---|---|---|---|---|---|---|
| RV32 config A (RV32IMASU, MMU, 16K/16K caches, no FPU) | Artix-7 -3 | 155 MHz | 13.3 K | 10.3 K | 12 | 4 | undated RTD (about 2022) — [RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV32 config B (1 ALU) | Artix-7 -3 | 148 MHz | 12.1 K | 9.9 K | 12 | 4 | [RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV32 config C (1 decode, 1 ALU) | Artix-7 -3 | 155 MHz | 10.8 K | 9.7 K | 12 | 4 | [RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV64 (like A, no FPU listed) | Artix-7 -3 | 137 MHz | 17.9 K | 12.5 K | 12 | 16 | [RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV32IMASU 2-decode/3-issue (May 2022 RTL) | Artix-7 -3 | 145 MHz | 14.6 K | 9.8 K | 12.5 | 4 | [2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf) |
| Same RV32 configuration | **Kintex UltraScale+ -3** | **360 MHz** | not given | not given | not given | not given | [2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf) |
| RV64IMASU, same configuration (May 2022) | Artix-7 -3 | 140 MHz | 19.5 K | 12.0 K | 12.5 | 16 | [2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf) |
| RV64GC with FPU, dual-issue, 2 ALU + FPU + LSU, 64-entry ROB, 16K 4-way L1s | Kintex-7 XC7K325T-2 (Vivado 2021.1) | 175 MHz (operating point) | not given | not given | not given | not given | Jul 2026 — [arXiv 2607.21130](https://arxiv.org/html/2607.21130) |

- In the CEA-Leti design, adding scalar Zfh (float16) cost +1.15% LUT6 and +0.05% FF, with no frequency degradation at 175 MHz. — [arXiv 2607.21130](https://arxiv.org/html/2607.21130)
- LiteX SoC practice:
  - Single-core RV32 and RV64 NaxRiscv run at 100 MHz on Arty A7-35T / Nexys Video. — [Luffca 2022-05](https://www.luffca.com/2022/05/linux-litex-naxriscv32/)
  - The 37C3 demo used a dual-core RV64GC build (alu-count 2, decode-count 2, F/D/C, coherent DMA) at 100 MHz system clock on a Nexys Video. — [37C3 slides (Dec 2023)](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/37c3_271223/37c3_271223.pdf)
  - A community guide ran a single-core RV64 build with FPU and MMU, L2 size 0, at 100 MHz on QMTech Wukong (XC7A100T) and an XC7A200T board. — [roryt12 guide (about Apr 2023)](https://github.com/roryt12/RISCV64-Debian-Linux-on-FPGA-with-Litex)
- Quad-core RV64GC NaxRiscv (alu-count 2, decode-count 2) on a Nexys Video at a 100 MHz target gave unsatisfactory timing, occasional lost cores and IO errors (user report, April 2024). The author's view:
  - he saw the same problem above two cores;
  - he blamed over-constrained placement and floorplanning;
  - critical paths appeared even in logic isolated from other cores;
  - he suggested more Vivado effort or manual floorplanning;
  - the only RTL knob he named was reducing LQ/SQ entries, which he called undesirable. — [NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89)
- ASIC (OpenLane, sky130) with reduced caches and a reduced BTB: about 100 MHz and 1.633 mm² cell area. The critical path is a high-fanout net in the MMU TLB lookup (6 ways x 32 entries). The 4R2W latch/tristate register file caused severe density and congestion problems in OpenROAD. — [NaxRiscv RTD Hardware](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/hardware/index.html)
- The KV260's K26 SOM uses the XCK26-SFVC784-2LV-C/I, i.e., speed grade -2 low-voltage, not -3. — [K26 SOM data sheet (mirror)](https://www.sundance.com/wp-content/uploads/docs/k26-som-Data-Sheet.pdf)

### Inferences
- In 2022 the KU+ -3 result was about 2.5x the A7-3 Fmax for the same RV32 RTL (360 vs 145 MHz). This is a single datapoint, probably out-of-context synthesis with an aggressive clock constraint.
  - Scaled naively to RV64 (137-140 MHz on A7-3) and derated for the KV260's -2LV grade, a NaxRiscv-class RV64 core plausibly lands around 250-300 MHz standalone on the XCK26. This is speculative.
  - A full SoC with an L2, coherent interconnect and DDR (via the PS or a PL MIG) will be lower.
  - Treat this only as a sanity range for the new design's timing targets.
- Going from RV32 to RV64 costs about +35% LUTs (13.3K to 17.9K), 4x the DSPs, and about 12% Fmax on Artix-7, for roughly equal IPC. The integer datapath and register-file width, not the OoO control logic, dominate this delta.
- The flat 12 BRAM count across RV32 configurations A, B and C shows that BRAM is spent on caches and predictors, while the OoO machinery (RAT, IQ, ROB, register file, TLBs) lives in LUTs and LUTRAM. LUT/LUTRAM budget, not BRAM, is the scarce resource to plan for on the XCK26.

### Gaps
- No published absolute LUT/FF/DSP/BRAM numbers for NaxRiscv with an FPU (RV64GC), on any device.
- No ECP5, Kintex-7 (absolute area), Zynq UltraScale+ (ZCU104/KV260) or Virtex UltraScale+ results.
  - A user asked about VCU118 memory sizes in March 2026, but posted no area or Fmax. — [NaxRiscv issues](https://github.com/SpinalHDL/NaxRiscv/issues?q=is%3Aissue)
- No published dual-core or quad-core NaxRiscv SoC utilization numbers.
- No breakdown of LUTs by unit (IQ, RAT, ROB, LSU, register file).

---

## 4. Documented limitations, bottlenecks, why VexiiRiscv was started, and the author's view of OoO cost-effectiveness on FPGAs

### Takeaway
The author built NaxRiscv to improve single-thread performance, to hide memory latency on FPGAs (which cannot afford big L2s), and to experiment with HDL paradigms. He has since stated that "There is a few design decision that prevent NaxRiscv scaling up enough i think" ([NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89), Apr 2024).

Since 2024 he has concentrated on the in-order VexiiRiscv. He says its performance is not far off NaxRiscv, and it fills the open-source gap between single-issue in-order and OoO cores. He floated a possible OoO successor ("NaxiiRiscv") but has not committed to one.

NaxRiscv is now effectively in maintenance mode, with bug fixes only. Most open issues in 2025-2026 are ISA-compliance and FPU edge cases reported by third parties.

### Cited Findings
**Original rationale for an OoO FPGA core (paraphrased from the docs)**
- improve single-threaded performance;
- hide memory latency, because FPGAs lack the memory for a big L2;
- experiment with Scala/SpinalHDL description paradigms;
- personal interest;
- few open OoO softcores existed (Marocchino, RSD, OPA, and so on);
- a bet that it was possible to do better in some metrics. — [NaxRiscv RTD Introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)

**The author's statements on limits and direction (paraphrased except the one quote above)**
- April 2024: VexiiRiscv performance is not far off NaxRiscv. He was working on VexiiRiscv, whose only missing Linux feature at the time was the FPU. — [NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89)
- April 2024: a few NaxRiscv design decisions prevent it from scaling up. A "NaxiiRiscv" might come someday, but his priority was to finish the in-order design space with VexiiRiscv. He pointed people to BOOM's documentation and the RSD paper for OoO ideas. — [NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89)
- "Why VexiiRiscv" slide (2024; folder "riscv_sc_2024", probably RISC-V Summit China 2024):
  - VexRiscv lacked multi-issue, RV64 and a write-back cache;
  - its branch prediction and framework could have been better;
  - it suffered technical debt and ossification;
  - there was an open-source gap between single-issue in-order and out-of-order cores;
  - the goal was to expand the design space covered by one design. — [riscv_sc_2024 slides (ODP)](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/riscv_sc_2024/riscv_sc_2024.odp)
- VexiiRiscv docs on why VexRiscv was retired:
  - messy frontend and branch prediction;
  - plugin-system limits;
  - technical debt since 2017;
  - a write-through D$ that causes problems as frequency rises;
  - weak verification based on its own golden model. — [VexiiRiscv RTD Introduction](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Introduction/index.html)

**Documented NaxRiscv bottlenecks and trade-offs**
- Issue queue: capped at 32 entries for timing, and row-granular allocation wastes slots. — [NaxRiscv RTD Frontend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html)
- Branch handling:
  - mispredict penalty is 10 cycles at best — [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf);
  - the reschedule is applied at commit — [NaxRiscv RTD Backend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html);
  - RAS contents are not repaired, and decode trusts BTB targets for timing reasons — [NaxRiscv RTD Branch prediction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/branch_prediction/index.html).
- Load speculation:
  - a wrong hit prediction causes a full flush — [RISC-V Week Paris 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf);
  - stores delivering address and data through the IQ cause store-to-load hazards, which required a load hazard predictor — [NaxRiscv RTD Memory](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/memory/index.html).
- IPC and area sensitivities: 2-cycle ALUs cost about 15%, extra EUs give diminishing returns, and the predictor is undersized (bigger GShare or TAGE suggested). — [NaxRiscv RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- Multi-core timing and placement problems above 2 cores; the only RTL lever offered was shrinking LQ/SQ. — [NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89)
- Security: the docs demonstrate a Spectre/Meltdown-style leak in which user code reads supervisor memory.
  - Mechanism: a faulting load still writes its value to the register file; the hit predictor wakes dependents early; a cache-line refill encodes the secret.
  - The demo requires NaxRiscv's hardware protection to be disabled, implying a mitigation exists and is on by default. — [NaxRiscv RTD Misc](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/misc/index.html)
  - The 37C3 talk walked through the same leak with Konata traces. — [37C3 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/37c3_271223/37c3_271223.pdf)
- I/O: the SPI SD card (about 500 KB/s) is the main Debian bottleneck; the coherent-DMA SD path reaches about 4 MB/s. — [NaxRiscv RTD Hardware](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/hardware/index.html)

**Project activity and maturity (2025-2026)**
- Recent commits are sparse bug fixes:
  - CSR/trap legality, an FPU write to x0, and debug-mode interrupts in Oct-Nov 2025;
  - a tooling update on 2026-01-23, the latest visible commit. — [NaxRiscv commits](https://github.com/SpinalHDL/NaxRiscv/commits/main)
- Issues filed Aug-Oct 2026 are mostly open FPU correctness bugs: subnormal comparisons, illegal reserved-frm rounding modes, and exception flags. Another open issue (#171) reports a core stall with a Vivado AXI Interconnect data FIFO. — [NaxRiscv issues](https://github.com/SpinalHDL/NaxRiscv/issues?q=is%3Aissue)
- A 2025 batch of ISA-compliance issues (mtvec/stvec mode, MPP legality, mtval, tselect) was fixed within weeks. — [NaxRiscv issues](https://github.com/SpinalHDL/NaxRiscv/issues?q=is%3Aissue)

### Inferences
- The author's revealed position: on FPGAs, a well-designed in-order dual-issue core with late-ALU, good branch prediction, non-blocking caches and prefetchers recovers most of NaxRiscv's single-thread performance at much lower area and higher Fmax. OoO's measurable gain is roughly:
  - CoreMark: about 0% (VexiiRiscv is even higher);
  - Dhrystone: about +17% (2.93 vs 2.50);
  - doom: about +15% (74 vs 64.6 fps).
  - These figures are inferred from Sections 2 and 5, and the configurations differ.
- In the author's framing, OoO only pays off on FPGA if it scales past what Nax's choices allow. The likely culprits, inferred from the docs:
  - commit-time recovery;
  - the 32-slot unified IQ;
  - the shared single LSU/mul/div/CSR pipe;
  - full-flush recovery on hit misprediction;
  - page-offset-only store/load checks;
  - poor multi-core placement.
- For the new 2-wide OoO RV64 core, the lessons point to:
  - early (execute-time) branch recovery, with a few RAT checkpoints or a fast-walk mechanism;
  - separate load and store-address pipes, with store data decoupled from the IQ;
  - selective replay, or at least cheaper recovery, on load-hit mispredictions;
  - a larger or less wasteful scheduler (split per-class queues, or compaction);
  - a stronger direction predictor (TAGE-lite);
  - floorplan-aware design for the dual-core.
- Without these, the result is likely to match NaxRiscv, and VexiiRiscv dual-issue, rather than beat them.
- FPU robustness is NaxRiscv's least mature area as of late 2026, based on the open issues. A clean-room FPU should be validated against subnormal and frm corner cases from day one.

### Gaps
- Not stated: which specific "design decisions" prevent NaxRiscv from scaling up.
- Not found: a post-mortem or slide quantifying OoO area or IPC efficiency (for example, a perf/LUT comparison of Nax vs Vexii dual-issue on the same FPGA). Author posts on X/Twitter were not retrievable.
- Not found: the 37C3 talk transcript; only the slides were read.

---

## 5. VexiiRiscv (in-order, single/dual-issue) and VexRiscv profiles, and head-to-head comparison with NaxRiscv

### Takeaway
**VexiiRiscv** (public roadmap opened 2023-11; NLnet-funded from 2024-04) is an in-order RV32/RV64 IMAFDC[B]SU core. It supports:
- optional dual issue with asymmetric lanes and "late ALU" layers;
- BTB, GShare and RAS;
- non-blocking write-back MESI-coherent L1s with a store buffer, I$/D$ prefetchers and CMO;
- SV32/SV39, PMP and JTAG;
- Debian on quad-core SoCs.

Its best published figures, for a dual-issue late-ALU configuration with no area or Fmax published, are 5.24 CoreMark/MHz, 2.50 DMIPS/MHz and 1.62 Embench. Single-issue Linux configurations run at 200 MHz in a 4-core Efinix Ti375 Debian demo.

**VexRiscv** (2017 onward) is RV32-only, single-issue, 2 to 5+ stages, with a write-through D$. It reaches 1.21-1.57 DMIPS/MHz and 2.27-2.57 CoreMark/MHz at about 180-240 MHz on Artix-7, in about 0.5-2.9 KLUT.

Against NaxRiscv RV32 (5.02 CM/MHz, 2.93 DMIPS/MHz, 13.3 KLUT, 155 MHz on A7-3), VexiiRiscv matches or beats it on CoreMark but trails on Dhrystone and doom fps.

### Cited Findings
**VexiiRiscv: features and status**
- Status per the docs (dated 07/01/2025; docs build 2025-03-17):
  - RV32/64 IMAFDCSU;
  - single and dual issue, early and late ALU;
  - BTB/RAS/GShare;
  - non-blocking I$ and D$; D$ hardware and software prefetch; I$ hardware prefetch;
  - multi-core memory coherency;
  - LSU store buffer and CMO;
  - AXI4/Wishbone/TileLink (RVA unavailable in some bus configurations);
  - SV32/SV39, PMP, JTAG, hardware watchpoints.
- It runs Linux/Buildroot/Debian on FPGA via LiteX.
- Headline: 2.50 Dhrystone/MHz and 5.24 CoreMark/MHz.
- Example diagram: a "2 issue / early+late ALU / 6 stages" configuration. — [VexiiRiscv RTD Introduction](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Introduction/index.html); [VexiiRiscv README](https://github.com/SpinalHDL/VexiiRiscv)
- The configuration behind the best numbers: max IPC 2, issue 2, late ALU 2, BTB 512 / RAS 4, GShare 4 KB. It gives 2.50 Dhrystone/MHz, 5.24 CoreMark/MHz and 1.62 Embench. The page says it is still too early to publish area/Fmax metrics. — [VexiiRiscv RTD Performance](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)
- An example IPC-oriented generator option set includes BTB/GShare/RAS, 2 decoders, 2 lanes, aligner and dispatcher buffers, late ALU, async register file, bypass from stage 0, and a radix-4 divider. — [VexiiRiscv RTD HowToUse](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/HowToUse/index.html)
- Dispatch:
  - instructions dispatch in order to asymmetric lanes and "layers" with static priorities;
  - in a 2-lane example, early ALUs sit at E1 and late ALUs at E3, with the LSU/MUL/DIV on one lane;
  - the scheduler checks at which stage each operand must be readable, which is what makes late-ALU work;
  - the execute pipeline never collapses bubbles and stalls all lanes together. — [VexiiRiscv RTD Decode](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Decode/index.html); [VexiiRiscv RTD Execute intro](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Execute/introduction.html)
- LSU and D$:
  - the D$ is integrated into the execute pipeline to save area and improve timing;
  - it is non-blocking, with configurable refill/writeback slots (4 ways and 4 slots recommended for performance);
  - it is write-back with MESI permission-based coherency, bridgeable to TileLink.
- Instead of stalling, VexiiRiscv takes a "hardware trap" (flush and refetch) on:
  - cache or TLB misses;
  - refill aliasing;
  - a load hitting the store queue;
  - a store miss with a full store queue.
- Store-miss buffering is optional, e.g., a 32-op store queue with 4 slots.
- LR locks the line for 32 cycles, with anti-starvation toggling.
- Prefetch:
  - next-line;
  - RPT stride (128 PC-indexed entries by default);
  - software prefetch via CMO.
- Prefetch gains measured on a quad-core RV64GC at 200 MHz with 16 KB L1s and a 512 KB L2:

| Workload | Without prefetch | With prefetch |
|---|---|---|
| LiteX BIOS read | 204.2 MiB/s | 790.9 MiB/s |
| iperf3 RX | 617 Mbit/s | 766 Mbit/s |
| chocolate-doom | 43.1 fps | 50.2 fps |

  Source for the LSU, D$ and prefetch findings above: [VexiiRiscv RTD Memory](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Memory/index.html)
- FPU:
  - IEEE-754 compliant by default, including subnormals;
  - most ops issue at 1 per cycle;
  - deeply pipelined, with about a 10-cycle FMA;
  - rounding and adder logic shared; FDIV and FMUL reuse the integer DIV and MUL;
  - subnormals handled by small state machines that stall 2-3 cycles;
  - optional reduced-accuracy FMA and no-subnormal modes for area and timing, validated by running Debian. — [VexiiRiscv RTD FPU](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Execute/fpu.html)
- Single-issue synthesis table (best speed grade per family; area slightly inflated by stressed constraints and I/O serialization):
  - rv32i: 206 MHz, 1,413 LUT on Artix-7.
  - rv64i: 186 MHz, 2,157 LUT, 2,332 FF.
  - rv32imasu Linux (branch prediction, 8 KB/8 KB caches): 199 MHz, 3,351 LUT, 3,833 FF; 1.45 DMIPS/MHz, 2.96 CM/MHz.
  - rv32im IPC-max late-ALU: 140 MHz, 3,247 LUT; 1.74 DMIPS/MHz, 3.41 CM/MHz. — [VexiiRiscv RTD Performance](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)
- Demo SoCs:
  - ORConf and RISC-V Summit 2024 (Efinix Ti375 board): 4x VexiiRiscv RV64GC (IMAFDCSU), single-issue in-order, at 200 MHz.
    - Per core: BTB/GShare/RAS, store buffer, prefetchers, 16 KB 4-way I$ and 16 KB 4-way write-back D$.
    - Shared: 512 KB 8-way inclusive, non-blocking, out-of-order L2 on a 128-bit coherent TileLink.
    - Total resources: about 100 KLUT4 (87,660 LUT4 + 8,679 adders), 56,329 FF, 68 DSP, 1,284 RAM10.
    - Benchmarks for this configuration: 3.04 CoreMark/MHz and 1.59 DMIPS/MHz. — [ORConf 2024 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/orconf_2024/orconf_2024.pdf); [riscv_sc_2024 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/riscv_sc_2024/riscv_sc_2024.odp)
  - COSCUP 2024: 4x RV64GC, 256 KB L2, 16 KB I$/D$, on Artix-7 ("A7-1"), about 65 KLUT at 100 MHz.
    - The D$ prefetcher slide shows memory bandwidth of 168.4 MiB/s write and 113.3 MiB/s read in one setting, versus 250.5 MiB/s write and 422.9 MiB/s read in the other. — [COSCUP 2024 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/coscup_2024/coscup_2024.pdf)
- Debian on Nexys Video:
  - LiteX "debian" CPU variant, 2 CPUs, AXI-lite peripheral bus, coherent DMA;
  - optional extras: async register file, 32-op store buffer with 2 slots, 2 refill and 2 writeback slots, 256 KB L2;
  - requires RV64IMAFDC and about 128 MB RAM. — [VexiiRiscv Debian LiteX doc](https://github.com/SpinalHDL/VexiiRiscv/tree/dev/doc/litex/debian)
- Roadmap (opened 2023-11-14) lists items including SMT support, multi-issue, MMU, I$/D$ and FPU.
- Contributor reports:
  - 2025-11/12: an H-extension port is in progress;
  - 2026-08: AXI and Wishbone lack AMO and coherency, so multi-core needs TileLink. — [VexiiRiscv issue #1](https://github.com/SpinalHDL/VexiiRiscv/issues/1)
- The NLnet grant (from 2024-04) describes VexiiRiscv as already surpassing VexRiscv in performance, 64-bit and Debian. Remaining parity gaps were TCM, JTAG and optimization, with a lightweight FPU and vector unit as goals. — [NLnet VexiiRiscv](https://nlnet.nl/project/VexiiRiscv/)

**VexRiscv**
- Architecture:
  - RV32I with optional M/A/F/D/C;
  - 2 to 5+ stages: fetch(es), decode, execute, [memory], [writeback];
  - optional hardware-refilled MMU, PMP, caches and debug;
  - M/S/U modes; runs Linux, Zephyr and FreeRTOS.
- Benchmarks are measured on the fastest speed grade with an unattainable clock constraint; Dhrystone uses -O3 -fno-inline. — [VexRiscv README](https://github.com/SpinalHDL/VexRiscv)

| VexRiscv configuration | DMIPS/MHz | CoreMark/MHz | Artix-7 Fmax | LUT | FF | Source |
|---|---|---|---|---|---|---|
| Small RV32I, no bypass | 0.52 | — | 240 MHz | 556 | 566 | [VexRiscv README](https://github.com/SpinalHDL/VexRiscv) |
| Full, max-perf, RV32IM, 8 KB I$/D$ | 1.38 | 2.57 | 200 MHz | 1,935 | 1,216 | [VexRiscv README](https://github.com/SpinalHDL/VexRiscv) |
| Full with MMU, 4 KB I$/D$ | 1.24 | 2.35 | 151 MHz | 2,021 | 1,541 | [VexRiscv README](https://github.com/SpinalHDL/VexRiscv) |
| Linux balanced, RV32IMA, MMU, 4 KB I$/D$ | 1.21 | 2.27 | 180 MHz | 2,883 | 2,130 | [VexRiscv README](https://github.com/SpinalHDL/VexRiscv) |

- The README also quotes up to 1.44 DMIPS/MHz for a near-full build, and 1.57 DMIPS/MHz with the divider lookup table. — [VexRiscv README](https://github.com/SpinalHDL/VexRiscv)
- The SMP variant uses SpinalHDL's BMB bus, which has optional coherency channels: inv (invalidate a range), ack and sync. — [SaxonSoc (BMB)](https://github.com/spinalhdl/saxonsoc)
- VexRiscv's D$ is write-through. — [VexiiRiscv RTD Introduction](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Introduction/index.html)

**Head-to-head summary (configurations differ; see the notes in each row)**

| Metric | NaxRiscv (OoO) | VexiiRiscv (in-order) | VexRiscv (in-order) |
|---|---|---|---|
| CoreMark/MHz | 5.02 (RV32 A) / 4.94 (RV64) | up to 5.24 (dual-issue, late ALU); 3.04 (single-issue RV64GC demo) | up to 2.57 |
| DMIPS/MHz | 2.93 / 2.94 | up to 2.50; 1.59 (demo) | 1.21-1.57 |
| Embench-iot | 1.67 / 1.84 | 1.62 | not published |
| Core LUTs and Fmax | 13.3 K at 155 MHz (RV32, A7-3); 17.9 K at 137 MHz (RV64) | about 3.4 K at 199 MHz (single-issue RV32 Linux, best grade); dual-issue: not published | about 2.9 K at 180 MHz (Linux RV32) |
| Doom fps (Apr 2024) | 74.07 (128 KB L2) | 64.58 (128 KB L2) | 36.15 (no L2) |

Sources: [NaxRiscv RTD Performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html); [VexiiRiscv RTD Performance](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html); [ORConf 2024 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/orconf_2024/orconf_2024.pdf); [VexRiscv README](https://github.com/SpinalHDL/VexRiscv); [VexiiRiscv issue #1](https://github.com/SpinalHDL/VexiiRiscv/issues/1).

### Inferences
- What OoO buys on FPGA, from the same author's three cores:
  - Going from VexRiscv to VexiiRiscv (better frontend, dual issue, late ALU, write-back non-blocking caches, prefetch) roughly doubles CoreMark/MHz.
  - Going from VexiiRiscv to NaxRiscv adds roughly 0-17% on the published metrics, for an estimated 2-4x core LUT cost and about 20-30% lower Fmax.
  - This is an estimate, because the dual-issue VexiiRiscv area is unpublished.
  - On performance per LUT and absolute performance (IPC x Fmax), a well-tuned in-order dual-issue core is very hard to beat on FPGAs. That appears to be why development pivoted.
- VexiiRiscv's "trap and refetch on miss" LSU policy shows that in-order FPGA cores can get non-blocking behaviour cheaply. An OoO design must deliver more than that to justify its area. The places to win are memory-level parallelism under misses (LQ/SQ, many MSHRs, prefetchers) and tolerance of long-latency FP and loads.
- VexiiRiscv's roadmap lists SMT, which is a reference point for the team's SMT/CMT hooks. No implementation details were found.

### Gaps
- Not published:
  - VexiiRiscv dual-issue (5.24 CM/MHz configuration) LUT/FF/Fmax on any device;
  - whether that configuration was RV32 or RV64;
  - its compiler flags.
- The VexiiRiscv Dhrystone figure is labelled only as per-MHz, without a DMIPS unit, and is misspelled in one table. It is presumably DMIPS/MHz but this is not explicitly confirmed.
- VexRiscv-SMP details (L1 coherency protocol, maximum cores, LiteX SMP benchmarks) were not found in a primary source. The BMB/write-through linkage is inferred.
- The COSCUP prefetcher slide does not label which bandwidth figures are with and without prefetch.

---

## 6. Multicore: coherency approach, demonstrated SMP Linux/Debian setups, and performance results

### Takeaway
NaxRiscv's D$ uses permission-based coherency with three states: unloaded, shared, and unique (dirty). Permissions are upgraded by acquire, written back by release, and downgraded by probes, which reuse the D$ store pipeline; the custom interface bridges to TileLink. The SoC uses either a cacheless coherency hub or an inclusive, non-blocking, PLRU L2. The L2 is inclusive of the D$ only; the I$ is not coherent.

Dual-core RV64GC Debian at 100 MHz on a Nexys Video was demonstrated (37C3, Dec 2023). Quad-core builds hit placement and timing problems, and no multicore benchmark scaling numbers were published for NaxRiscv. VexiiRiscv has since demonstrated quad-core Debian at 200 MHz (Efinix Ti375) with a 512 KB L2.

### Cited Findings
**NaxRiscv coherency and L2**
- D$ coherency mechanics:
  - Each cache block holds one of three permission levels: unloaded, shared (read-only) or unique (read/write, possibly dirty).
  - Upgrades use acquire on the read bus; evictions use release on the write bus; the interconnect downgrades through a probe bus.
  - Probes reuse the D$ store pipeline.
  - A lock interface can block downgrades on an address to support atomic sequences.
  - The native interface is custom but bridges to TileLink.
- SoC options: either a coherent L2 or a cacheless coherency hub.
- L2 properties:
  - TileLink up toward the CPUs and DMA, down toward memory;
  - inclusive of the L1 D$ only, so it sends only necessary probes;
  - PLRU replacement, non-blocking, multi-way;
  - data stored in simple dual-port RAM, which suits FPGAs;
  - per-address/per-source cacheability (e.g., to bypass video DMA);
  - default 5-cycle hit latency and 4-cycle miss penalty. — [NaxRiscv RTD Memory](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/memory/index.html)
- Coherent-L2 design tips from the author:
  - one pending transaction per 64-byte block;
  - at most 64 bytes per burst;
  - keep bursts aligned;
  - beware alignment aliasing.
- Linux SMP requires hardware cache coherency (between CPUs and DMA) and inter-CPU software interrupts. — [37C3 slides (Dec 2023)](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/37c3_271223/37c3_271223.pdf)

**Demonstrated setups**
- Dual-core NaxRiscv RV64 (C/F/D, alu-count 2, decode-count 2) on a Digilent Nexys Video at 100 MHz, running Debian (37C3, Dec 2023):
  - LiteX build with AXI-lite peripheral bus, video framebuffer, coherent DMA, SD card, Ethernet and JTAG TAP.
  - Debugging story: a dual-core Debian freeze (RCU stall) appeared after about 1 hour, about 3.6e11 cycles. That run would take about 40 days to reproduce in simulation at 100 kHz.
  - It was diagnosed over JTAG/OpenOCD: the CPU was spinning in a kernel spinlock.
  - The root cause was the D$ releasing data permissions a second time after already being probed out. — [37C3 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/37c3_271223/37c3_271223.pdf)
- The single-core Debian flow is documented:
  - Nexys Video, RV64IMAFDCSU;
  - prebuilt partition images, a litex-hub/linux kernel commit and OpenSBI;
  - Xfce, chocolate-doom, OpenTTD and similar demo packages. — [NaxRiscv RTD Hardware](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/hardware/index.html)
- Quad-core NaxRiscv (user build, April 2024, Nexys Video at 100 MHz): unsatisfactory timing, occasional lost cores and IO errors. The author had stayed within two cores and saw similar issues above two. — [NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89)
- A community single-core RV64 + FPU NaxRiscv Debian build used L2 = 0, on a suggestion attributed to Charles Papon. The author described the board as slow. — [roryt12 guide](https://github.com/roryt12/RISCV64-Debian-Linux-on-FPGA-with-Litex)
- VexiiRiscv multicore:
  - dual-core Linux with chocolate-doom: about 60 fps with two instances, vs 64.58 fps single (Apr 2024);
  - RV64 Debian boot (Apr 2024) — [VexiiRiscv issue #1](https://github.com/SpinalHDL/VexiiRiscv/issues/1);
  - multi-core RV32IMA on hardware running multiple doom instances for 24 h — [NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89);
  - quad-core RV64GC Debian at 200 MHz on Efinix Ti375 with a 512 KB 8-way inclusive, out-of-order, non-blocking L2 on a 128-bit TileLink; MESI coherency, with the I$ excluded — [riscv_sc_2024 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/riscv_sc_2024/riscv_sc_2024.odp);
  - a quad-core Debian demo video is linked from the README — [VexiiRiscv README](https://github.com/SpinalHDL/VexiiRiscv).

### Inferences
- The NaxRiscv/VexiiRiscv coherence scheme (MESI-like permissions over TileLink, an inclusive L2 that filters probes, probes sharing the store path, a non-coherent I$ handled by fence.i) is a proven, FPGA-friendly template for a dual-core KV260 design.
  - On the KV260, the L2 would likely sit in PL BRAM/URAM, with DDR reached through the PS. URAM availability on the XCK26 should be checked by the platform researcher.
- The coherence bug class seen in NaxRiscv (permission released twice after a probe), surfacing only after about 1e11 cycles on hardware, argues for:
  - formal or randomized coherence testing;
  - on-FPGA trace/JTAG debug hooks built into the new design from the start.
- Multicore scaling numbers for NaxRiscv are absent. The author's own multicore effort moved to VexiiRiscv.

### Gaps
- No published NaxRiscv SMP benchmarks: no multi-thread CoreMark, Linux kernel-build time, memory bandwidth per core, or L2 hit/miss latency in cycles on hardware.
- No published NaxRiscv quad-core success at timing closure.
- No NaxRiscv I$ coherence or snoop-filter details beyond "inclusive of D$".
- The exact LiteX SMP parameters (L2 size defaults for NaxRiscv) were not found in a primary doc. The doom test used a 128 KB L2.

---

## 7. Third-party evaluations (papers, theses, blogs) of NaxRiscv vs BOOM/CVA6/Rocket/VexRiscv

### Takeaway
No peer-reviewed head-to-head benchmark of NaxRiscv against BOOM, CVA6 or Rocket on the same FPGA was found. Third-party evidence consists of:
- Luffca's 2022 blog benchmarks (simulator and Artix-7 hardware);
- a 2023 Debian-on-FPGA community guide;
- CEA-Leti's 2026 arXiv paper using NaxRiscv RV64GC on a Kintex-7 at 175 MHz, plus CEA-Leti's unofficial NaxRiscv documentation;
- a few survey and thesis mentions.
The best-known comparative survey of application-class open cores (Rocket, BOOM, CVA6, SHAKTI) does not include NaxRiscv.

### Cited Findings
- **Luffca (2022), simulator and hardware.** RV32/RV64 CoreMark, Dhrystone and Whetstone numbers, plus hardware-vs-simulator gaps. No comparison with other cores. — [Luffca 2022-07](https://www.luffca.com/2022/07/benchmark-rv64gc-riscv-ooo-simulator/); [Luffca 2022-05](https://www.luffca.com/2022/05/linux-litex-naxriscv32/)
- **CEA-Leti (Hubinet, Moellic, Savry, Potin, Rigaud; arXiv 2607.21130, 23 Jul 2026).**
  - Platform: NaxRiscv RV64GC as described in Section 1, on an XC7K325T-2 at 175 MHz with Vivado 2021.1.
  - Zfh adds +1.15% LUT6 and +0.05% FF with no Fmax loss.
  - A 4-lane, VLEN=64 vector unit is being integrated; its performance is not yet measured.
  - No IPC or CoreMark results are given. — [arXiv 2607.21130](https://arxiv.org/html/2607.21130)
- **CEA-Leti unofficial docs.** An Obsidian-format per-plugin documentation set covering an OoO primer, pipelines, and a generic-OoO-vs-NaxRiscv schematic, now hosted under SpinalHDL. No numeric parameters on the landing page. — [naxriscv_doc](https://github.com/SpinalHDL/naxriscv_doc)
- **Community Debian guide (about Apr 2023).** NaxRiscv RV64+FPU vs Rocket on QMTech Artix-7 boards, qualitative only; no LUT or performance numbers. — [roryt12 guide](https://github.com/roryt12/RISCV64-Debian-Linux-on-FPGA-with-Litex)
- **Dörflinger et al., "A Comparative Survey of Open-Source Application-Class RISC-V Processor Implementations" (CF'21).** Compares Rocket, BOOM, CVA6 and SHAKTI. NaxRiscv is not included, and VexRiscv is mentioned only as background. Per the search summary, BOOM was slowest of the four on FPGA but fastest on ASIC. This is based on a search-result summary; the paper was not read directly. — [ACM DL PDF](https://dl.acm.org/doi/pdf/10.1145/3457388.3458657)
- **IST Lisbon MSc thesis on a Linux-capable CPU for IOb-SoC.** Reportedly describes NaxRiscv as early-stage with a primitive interface that complicates custom-SoC integration. Based on a search snippet; not read in full. — [IST thesis PDF](https://fenix.tecnico.ulisboa.pt/downloadFile/1970719973969589/thesis.pdf)
- **Aalto University thesis surveying branch predictors** in CVA6, BOOM, Rocket, VexRiscv and NaxRiscv. The page returned HTTP 403, so the content was not verified. — [Aalto thesis record](https://aaltodoc.aalto.fi/items/e7b28c94-f8af-43fd-81fd-8e497f404497)
- **2023 MDPI survey.** Cites RV64 NaxRiscv at 137 MHz on Artix-7 with 2.97 DMIPS[/MHz]; secondary source with a minor mismatch against the official 2.94. — [MDPI survey](https://www.mdpi.com/2078-2489/14/2/64)

### Inferences
- Because no controlled comparison exists, the report should present NaxRiscv's numbers as the author's own simulator measurements. Any cross-core claim (for example, "NaxRiscv beats BOOM on FPGA") needs a caveat.
- BOOM's poor FPGA Fmax (per Dörflinger et al.) and NaxRiscv's FPGA-first design suggest NaxRiscv wins on FPGA throughput per LUT. This is not demonstrated in any third-party study found.

### Gaps
- Not found:
  - any paper or thesis measuring NaxRiscv vs BOOM, CVA6 or Rocket on identical FPGA hardware;
  - any third-party NaxRiscv area/Fmax measurement with absolute LUT counts;
  - any third-party SMP evaluation.
- Not verified: the Aalto and IST theses were not accessible or not read in full.
