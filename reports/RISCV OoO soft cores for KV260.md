# Out-Predict NaxRiscv Without Surrendering the Clock

A clean-room, 2-wide-decode RV64 out-of-order core can beat NaxRiscv's IPC on the Kria KV260. The literature is clear about how: fix what NaxRiscv deliberately under-built (branch prediction, branch recovery, load speculation and the memory system) rather than go wider, and keep the clock rate, because IPC gains only count if Fmax holds. NaxRiscv's published bar is modest. Its RV64 build scores **4.94 CoreMark/MHz, 2.94 DMIPS/MHz and 1.84 Embench at 137 MHz in 17.9K LUTs on Artix-7, and its RV32 sibling posts IPCs of 1.28 (CoreMark), 1.65 (Dhrystone) and 1.42 (Embench)** ([NaxRiscv performance docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)). Its own documentation lists the weak points: a 4 KB gshare predictor; branch recovery applied at commit, with a 10-cycle best-case mispredict penalty; a 32-slot issue queue that never compacts; one pipe shared by loads, stores, multiply, divide and CSRs; a full pipeline flush whenever a predicted cache hit misses; two refill slots; and 16 KB L1 caches ([NaxRiscv frontend docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html); [NaxRiscv 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)). Cores designed for FPGAs from the start supply a measured fix for each. Building every multiported structure from RAM blocks cut RSD's LUTs by **45%** while raising Fmax, and its replay-queue load speculation added **8.9%** IPC on average ([RSD, FPT 2019](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)). The KV260's XCK26 has 117,120 LUTs and runs its fabric at 0.72 V, which puts its timing roughly at a -1 speed-grade level. It has no DRAM attached to the programmable logic, so both cores reach DDR through processing-system (PS) AXI ports capped at 333 MHz ([K26 data sheet DS987](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf); [DS925](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Processor-System-PS-Performance-Characteristics)). That points to a core of about 40K LUTs clocked at 150–200 MHz, a 512 KiB–1 MiB inclusive L2 in UltraRAM with a presence-bit directory over MESI L1 caches, and a boot flow run from the on-chip Arm cores. Preparing for SMT or CMT costs almost nothing if thread IDs are wired through the design at zero width from day one, and costs a redesign if they are not. Bulldozer-style clustering is a dead end at 2-wide. The same author's in-order dual-issue VexiiRiscv already reaches **5.24 CoreMark/MHz** ([VexiiRiscv performance docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)), so a credible win must show higher IPC on identical binaries across Dhrystone, Embench and SPEC-like Linux workloads on the same board, not on CoreMark alone.

## NaxRiscv sets a modest bar, and its author documented the weak points

NaxRiscv is a good target precisely because it was never tuned for IPC. Charles Papon's SpinalHDL core is an out-of-order RV32/RV64 IMAFDCSU machine built from plugins. Its stated design goal is low area and high Fmax on FPGA distributed RAM; IPC is explicitly secondary ([NaxRiscv introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)). The reference build fetches 64 bits per cycle and decodes, renames and retires two instructions. It issues to three execution units: two integer/branch ALUs and one pipe shared by loads, stores, multiply, divide and CSRs. Around them sit a **64-entry ROB, 64 physical registers, a 32-entry unified issue queue, 16-entry load and store queues, 16 KB 4-way L1s with two refill and two writeback slots, a 512-entry direct-mapped BTB, a 4 KB gshare and a 32-entry RAS** ([NaxRiscv performance docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)). Nearly every structure lives in asynchronous-read LUTRAM. The register file uses one bank per write port, and an XOR-based live-value table picks the right bank on each read ([NaxRiscv backend docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html)).

| NaxRiscv build | DMIPS/MHz | CoreMark/MHz | Embench-iot | IPC (Dhrystone / CoreMark / Embench) | Area | Fmax | Source |
|---|---|---|---|---|---|---|---|
| RV32 "A": 2 decode, 3 issue, 2 retire | 2.93 | 5.02 | 1.67 | 1.65 / 1.28 / 1.42 | 13.3K LUT, 10.3K FF, 12 BRAM, 4 DSP | 155 MHz, Artix-7 -3 | [perf docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV32 "B": one integer ALU | 2.71 | 4.44 | 1.46 | not published | 12.1K LUT | 148 MHz | [perf docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV32 "C": one decode lane, one ALU | 1.70 | 3.35 | 1.06 | not published | 10.8K LUT | 155 MHz | [perf docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV64 (like A, no FPU) | 2.94 | 4.94 | 1.84 | not published | 17.9K LUT, 12.5K FF, 12 BRAM, 16 DSP | 137 MHz, Artix-7 -3 | [perf docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) |
| RV64GC, third-party Verilator run (2022) | 2.94 | 4.59 | — | — | — | — | [Luffca, Jul 2022](https://www.luffca.com/2022/07/benchmark-rv64gc-riscv-ooo-simulator/) |
| RV32 on Artix-7 hardware under Linux | 2.11–2.29 | 3.92–4.01 | — | — | — | 100 MHz SoC | [Luffca, May 2022](https://www.luffca.com/2022/05/linux-litex-naxriscv32/) |
| RV32, May 2022 RTL | — | — | — | — | — | 360 MHz, Kintex UltraScale+ -3 | [2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf) |

The ablation rows show where NaxRiscv's IPC comes from. Adding a second decode lane (C to A) raised CoreMark/MHz by about 50%, but the second integer ALU (B to A) added only about 13%. The author also notes that extra execution units hit diminishing returns quickly and that a 2-cycle ALU cost about 15% ([NaxRiscv performance docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)). The 360 MHz UltraScale+ figure is a single datapoint on the fastest speed grade, most likely from synthesizing the core on its own rather than in a full SoC. The KV260 ships slower -2LV silicon ([K26 data sheet DS987](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf)).

Read against the literature, NaxRiscv's documentation is a catalog of deliberate economies, and each is a target. **Branch recovery happens at commit.** A reschedule register records the oldest ROB entry with a pending jump or trap, and the commit logic applies it by restoring the committed rename map in one step through per-register location bits ([NaxRiscv backend docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html); [NaxRiscv frontend docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html)). That recovery is cheap, but it makes the **10-cycle mispredict penalty a best case** ([NaxRiscv 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)): a mispredicted branch sitting behind an older cache miss cannot redirect fetch until it reaches the ROB head. After a reschedule the RAS pointer is repaired but overwritten RAS entries are not, and decode accepts BTB targets without recomputing them because the check would make too long a path ([NaxRiscv branch-prediction docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/branch_prediction/index.html)). The issue queue fills a whole row on each dispatch, never compacts holes, and is described as limited to about **32 slots by timing** ([NaxRiscv frontend docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html)). Loads get 3-cycle load-to-use from a cache-hit predictor, but **a predicted hit that misses flushes the whole pipeline**. Store address and store data both travel through the issue queue, which forced the addition of a separate store-to-load hazard predictor. Forwarding works only when a load depends on a single older store of the same size, and the first disambiguation pass compares only the 4 KB page offset ([NaxRiscv memory docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/memory/index.html); [NaxRiscv 2022 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/nax_040522/slides_nax_040522.pdf)). No memory-dependence predictor or hardware prefetcher is documented.

The author has stopped developing the design. In April 2024 he wrote that a few NaxRiscv design decisions keep it from scaling up, pointed readers to BOOM and RSD for out-of-order ideas, and said his priority was the in-order VexiiRiscv. In the same thread, a user's quad-core build at 100 MHz on a Nexys Video had failing timing, lost cores and I/O errors, and the only RTL change offered was shrinking the load/store queues ([NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89)). Commits since 2025 are bug fixes ([NaxRiscv commits](https://github.com/SpinalHDL/NaxRiscv/commits/main)). Most issues filed in 2026 are open FPU corner cases: subnormal comparisons, reserved rounding modes and exception flags ([NaxRiscv issues](https://github.com/SpinalHDL/NaxRiscv/issues?q=is%3Aissue)). The documentation even demonstrates a Meltdown-style leak when hardware protection is disabled: a faulting load writes the register file, and the hit predictor wakes its dependents early ([NaxRiscv misc docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/misc/index.html)).

The harder comparison is with the author's in-order core. VexiiRiscv's dual-issue configuration with "late" ALUs placed further down the pipeline reaches **5.24 CoreMark/MHz, 2.50 DMIPS/MHz and 1.62 Embench**, with area not published ([VexiiRiscv performance docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)). In a 2024 chocolate-doom timedemo with a 128 KB L2, NaxRiscv ran at 74.07 fps against VexiiRiscv's 64.58 ([VexiiRiscv issue #1](https://github.com/SpinalHDL/VexiiRiscv/issues/1)). The configurations differ, but out-of-order execution bought NaxRiscv roughly nothing on CoreMark, about 17% on Dhrystone and about 15% on doom. We estimate it cost two to four times the core LUTs. **That is the real bar: the new core must beat NaxRiscv's IPC and also clear a tuned in-order dual-issue core by enough to justify its area.**

NaxRiscv's numbers also need careful handling:
- They come from Verilator simulation with an unstated memory model.
- The RV64 CoreMark build redefines u32 as s32, which conflicts with EEMBC's rule that data types match their stated widths ([CoreMark README](https://github.com/eembc/coremark)).
- A third party measured the RV32 core 15–20% lower on Artix-7 hardware running Linux at 100 MHz ([Luffca, May 2022](https://www.luffca.com/2022/05/linux-litex-naxriscv32/)).

## Prior cores split into FPGA-native successes and ASIC-first giants

Across roughly thirty designs, one pattern dominates. Cores designed for FPGA fabric from the start reach about 95–260 MHz in 15–115K LUTs. Out-of-order RTL written for ASICs and compiled onto FPGAs runs at 25–72 MHz and needs several times the logic. The RSD authors trace the gap to multiported structures: commercial FPGAs lack RAM primitives with multiple write ports, so BOOM and OPA build their register files, map tables, ready bits and ROB state from flip-flops ([RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)). Gray and Smith's report (written in 2014, released in 2018) concluded that earlier out-of-order soft cores had not matched in-order soft cores on area or absolute performance ([Gray & Smith](https://arxiv.org/pdf/1803.06617)). Wong noted in 2016 that no commercial out-of-order soft processor existed ([Wong, FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)).

### FPGA-first out-of-order cores proved the circuit recipe

| Core | Configuration | Performance | Fmax, area, device | Does well | Does badly | Sources |
|---|---|---|---|---|---|---|
| RSD (2019) | RV32IM, 2-wide, ROB 64, unified IQ 16, LQ/SQ 16/16, gshare | 2.04 DMIPS/MHz | 95.3 MHz; 15,379 LUT, 8,584 FF, 6 BRAM, caches excluded (XC7Z020-1) | Multiport structures built from RAM throughout; replay-queue load speculation; 1-bit memory-dependence predictor | RV32 only, no MMU or Linux; gshare and store-queue CAM set the critical path | [RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf), [RSD GitHub](https://github.com/rsd-devel/rsd) |
| Wong x86 (2017) | 2 µops/cycle, ROB 64, 4×8 distributed matrix schedulers, LQ/SQ 16/16, 8 KB L1s + 256 KB L2 | SPECint2000 IPC 0.66: 2.73× Nios II/f per clock, 2.2× in wall-clock time | ~200 MHz, ~28,700 ALMs (Stratix IV, partly projected) | Register file split by producing unit, needing no live-value table; fused-logic scheduler; FPGA-tuned memory system | Branch predictor, ROB and microcode never built as circuits; relies on 7-input ALM functions; one simple ALU | [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) |
| Aasaraai & Moshovos (2009–12) | Single-issue OoO Nios II; CFC renamer; SPREX runahead core; NCOR cache | Simulated IPC 0.37; SPREX up to +38% over Nios II | CFC 996 LUT + 6 BRAM at 220 MHz; NCOR 4 KB at 329 MHz in 270 LEs (Stratix III) | Rename checkpoints in BRAM without copying; non-blocking cache without MSHRs | Single-issue; IPC from simulation only | [CFC](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf), [Aasaraai thesis](https://utoronto.scholaris.ca/items/5f3d7bbf-6ba4-42b9-8f6f-17ceec607184), [NCOR](https://www.eecg.utoronto.ca/~moshovos/research/NCOR.pdf) |
| OPA (2015) | RV32IM, 2-wide, merged 64-entry ROB/IQ/LDQ, no store queue, no direction predictor | 0.577 DMIPS/MHz | 134 MHz, ≈20K LUT, 0 BRAM (XC7Z020-1) | Shallow logic, high Fmax | No store queue costs up to 40% IPC; merged ROB/IQ wastes scheduler entries | [RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf), [OPA](https://github.com/terpstra/opa) |
| SmolRV64 (2026) | RV64 RVA22, 3-wide dispatch, 32-entry status-only ROB, 4 schedulers, register file in 4 single-write shards, 128 KiB L1s, YAGS predictor | Geekbench 5 single-core 14; suite IPC ≈1.02 | 166.67 MHz; 114,092 LUT, 53,029 FF, 169.5 BRAM, 28 DSP (XCKU5P) | Boots Ubuntu on UltraScale+; register file sharded by writer; netlist checks for RAM inference | Uses about one XCK26's worth of LUTs; self-reported and changing fast | [SmolRV64](https://github.com/tommythorn/smolrv64) |
| SoomRV (2023–) | RV32IMAC+ with virtual memory, up to 4-wide, TAGE | 5.42 CoreMark/MHz | 41.67 MHz, near the Arty A7-100T LUT limit | Aggressive IPC; boots Linux | Low FPGA clock; no area data | [SoomRV](https://github.com/mathis-s/SoomRV), [SoomRV-Arty](https://github.com/mathis-s/SoomRV-Arty) |

RSD is the strongest evidence that FPGA-native structures change the outcome. On the same Zynq-7020 it delivered **1.9× BOOM's DMIPS/MHz using 36% of BOOM's LUTs**. Its authors credit three things: fetching through predicted-taken branches without a bubble, speculatively scheduling instructions that depend on loads, and building multiported structures from RAM ([RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)).

Wong's thesis is the most complete FPGA-first out-of-order study and the most candid about returns. Per clock, his core beat a performance-tuned Nios II/f by 2.73× on SPECint2000 but only 1.32× on CoreMark and 1.45× on Dhrystone. Because it ran at 0.8× the clock, the wall-clock gain on those two kernels shrinks to roughly 1.1–1.2×. The core alone is 6.5× the size of the Nios II/f, but a complete Linux-capable system grows only 2.9×. The memory system dominates both area (about 13.9K of 28.7K equivalent ALMs) and timing ([Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)).

OPA is the cautionary tale. It reached 134 MHz by dropping the store queue and the direction predictor, and fell to 0.577 DMIPS/MHz. RSD's simulations show the missing store queue alone costs up to 40% of IPC, 16% on average ([RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)).

SmolRV64 is the closest public analogue to the project: an RV64 core that boots Ubuntu at 166.67 MHz on UltraScale+. But its 114,092 LUTs would fill essentially the whole XCK26. Its author also warns that Vivado can silently reduce a RAM read port to nothing in a netlist that still passes RTL simulation ([SmolRV64](https://github.com/tommythorn/smolrv64)).

The remaining open designs offer ideas rather than templates:
- **VRoom!** claims RV64 with 2-way SMT but had to be trimmed to fit a VU9P ([VRoom!](https://github.com/MoonbaseOtago/vroom); [Hackaday](https://hackaday.com/tag/system-verilog/)).
- **SCOoOTER** provides a clean SMT model with thread-tagged fetch, but reports only ASIC results: 77–83 MHz in SKY130 ([SCOoOTER](https://www.esa.informatik.tu-darmstadt.de/assets/publications/materials/2025/2025_WCAE_MS.pdf)).
- **FabScalar's** FPGA mapping was a time-multiplexed simulator running at an effective 4.5–16.7 MHz ([FPGA-Sim](https://ericrotenberg.wordpress.ncsu.edu/files/2025/06/paper_ISPASS-2012.pdf)).
- **Gray and Smith's** EDGE scheduler showed that interconnect makes up 70–85% of the delay in an FPGA scheduler's wakeup-select critical path ([Gray & Smith](https://arxiv.org/pdf/1803.06617)).

### ASIC-first out-of-order cores donate ideas, not netlists

| Core | Configuration | Performance | FPGA cost | Does well | Does badly | Sources |
|---|---|---|---|---|---|---|
| BOOMv2 / SonicBOOM (2017–20) | MediumBoom: 2-wide decode, ROB 64, 80 int physical registers, issue queues 20/12/16, LQ/SQ 16/16, TAGE-L | 6.2 CoreMark/MHz (4.9 without SFB), 3.93 DMIPS/MHz; SPEC06 IPC 0.86 vs 0.42 for BOOMv2 | RV32 2-wide at 71.7 MHz on XC7Z020; MegaBoom at 50 MHz on VCU118; Medium BOOM + L2 ≈148.5K LUT | TAGE with repaired history, micro-BTB, RAS repair, SFB, D-cache with line-fill buffers | Full flush on memory-ordering violations, no memory-dependence predictor, no load-hit speculation; flip-flop heavy | [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf), [BOOMv2](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf), [config-mixins](https://raw.githubusercontent.com/riscv-boom/riscv-boom/master/src/main/scala/v3/common/config-mixins.scala), [vivado-risc-v](https://github.com/eugene-tarassov/vivado-risc-v) |
| RiscyOO / Toooba (2018–) | RV64, 2-wide, ROB 64, 4×16 issue queues, LQ 24/SQ 14, 32 KB L1s, 1 MB L2 | ≈BOOM's IPC with an 80-entry ROB; +53%/+319% over Rocket with 10/120-cycle memory | 40 MHz single-core, 25 MHz quad-core (VU9P); CHERI-Toooba 2 cores ≈261.5K LUT at 25 MHz | Non-blocking TLBs plus page-walk cache (+29%); TSO and WMM multicore | ASIC-style Bluespec; unusable as a KV260 template | [RiscyOO](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf), [CHERI-Toooba](https://arxiv.org/html/2609.11590v1) |
| XiangShan (2021–26) | 6-wide; Kunminghu: 160-entry compressed ROB, 224 int physical registers, 3 load + 2 store pipes, store sets + wait table | Yanqihu 5.3 CoreMark/MHz and 7.03 SPECint2006/GHz (silicon); Kunminghu ≈14.7/GHz (simulation) | Nanhu ≈564K LUT at 50 MHz (VU19P) | Decoupled branch predictor with fetch-target queue (FTQ), macro-op fusion, move elimination, DiffTest | ≈5× the XCK26; criticality-aware issue gave no gain | [MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf), [HC2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf), [Nanhu-vdot](https://arxiv.org/pdf/2409.00661) |
| XuanTie C910 (2019–) | 3 decode, 4 rename, 8 issue, 12 stages, 64 ROB entries holding 192 instructions | 7.1 CoreMark/MHz; 6.11 SPECint2006/GHz; Embench IPC 1.61 | VU9P edition at 200 MHz (configuration unstated); HAPS-80 prototype at 60 MHz | L0 BTB, loop buffer, prefetch (3.8–5.4× on STREAM), 16-bit ASID | Schedulers too small for its window; 60-cycle L2; loses SPECint2017 to a lower-clocked P550 | [ISCA'20](https://ftp.libre-soc.org/466100a052.pdf), [C&C C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910), [C&C benchmark](https://chipsandcheese.com/p/a-risc-v-progress-check-benchmarking), [CF'25](https://arxiv.org/html/2505.24363v1) |
| SiFive U84 / P550 / P650 | 3-wide OoO (U84, P550), 4-wide (P650) | U84 claimed 2.3× U74 IPC; P550 8.65 and P650 >11 SPECint2006/GHz (vendor) | — | P550 32-entry zero-bubble BTB, 40-entry integer scheduler | P550 misaligned accesses trap for ≈1,000 cycles | [SiFive U8 blog](https://sifive.com/blog/incredibly-scalable-high-performance-risc-v-core-ip), [P550 release](https://www.businesswire.com/news/home/20210622005290/en/SiFive-Performance-P550-Core-Sets-New-Standard-as-Highest-Performance-RISC-V-Processor-IP), [C&C P550](https://chipsandcheese.com/p/inside-sifives-p550-microarchitecture), [CNX P650](https://cnx-software.com/?p=93869) |

BOOM's history is the best-documented record of which out-of-order features pay off. SonicBOOM roughly doubled SPEC06 IPC over BOOMv2 (0.86 vs 0.42). Its authors name a TAGE predictor with a speculatively updated, repairable global history as the largest single contributor. The other gains came from:
- a micro-BTB that removed a 2-cycle redirect;
- RAS repair, which cut return mispredictions tenfold;
- short-forward-branch (SFB) predication, which turns a branch over a few instructions into predicated operations (+25.5% CoreMark/MHz);
- a non-blocking data cache with line-fill buffers, which brought an L2 the core had observed at 24 cycles back toward its native 14 ([SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)).

BOOMv2 is the negative lesson. Cutting cycle time by 24% cost up to 20% of CoreMark IPC, more than half of it from longer load-to-use latency ([BOOMv2 tech report](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)). BOOM still flushes the whole pipeline and resets rename on a memory-ordering violation, has no memory-dependence predictor, and wakes a load's dependents only at writeback ([BOOM LSU docs](https://docs.boom-core.org/en/latest/sections/load-store-unit.html); [BOOM issue docs](https://docs.boom-core.org/en/latest/sections/issue-units.html)).

XiangShan shows the complete industrial toolkit: a decoupled predictor feeding a fetch-target queue, TAGE-SC and ITTAGE predictors, macro-op fusion, move elimination, store sets plus a wait table, and split RAR/RAW load queues. It also has the verification infrastructure behind them. But a Nanhu build occupies about 564K LUTs at 50 MHz on a VU19P ([XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf); [Nanhu-vdot](https://arxiv.org/pdf/2409.00661); [S2C case study](https://www.s2cinc.com/customer-case/bosc)). XiangShan's own trial of criticality-aware issue produced no visible gain, because its 2-issue queues rarely held more than two ready instructions ([XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)).

C910 proves that engineered out-of-order RTL can reach 200 MHz on a VU9P (configuration unstated), and that front-end and prefetch features pay. It has a 16-entry zero-bubble L0 BTB and a loop buffer, prefetching gave 3.8–5.4× on STREAM, and a 16-bit ASID cut context-switch TLB flushes about tenfold. It also shows that imbalance hurts. Chips and Cheese found its schedulers and register files too small for its 192-instruction window and its 60-cycle L2 slow, and a 1.85 GHz C910 lost every SPECint2017 test to a 1.4 GHz SiFive P550 ([Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf); [Chips and Cheese C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910); [Chips and Cheese benchmark](https://chipsandcheese.com/p/a-risc-v-progress-check-benchmarking)).

The P550 provides a balance reference: a 40-entry integer scheduler across three ALU ports and a 32-entry zero-bubble BTB. It also carries a warning: misaligned accesses trap for about a thousand cycles ([Chips and Cheese P550](https://chipsandcheese.com/p/inside-sifives-p550-microarchitecture)). The 6–8-wide commercial cores (Veyron, Ascalon, C930/C950) rely on 12K-entry BTBs, multi-thousand-entry TLBs and wide vector units that do not transfer to this budget ([Chips and Cheese Veyron](https://chipsandcheese.com/p/hot-chips-2023-ventanas-unconventional-veyron-v1); [CNX C950](https://www.cnx-software.com/2026/03/25/alibaba-xuantie-c950-a-powerful-rva23-complaint-64-bit-risc-v-core-for-edge-ai-computing/)).

### In-order Linux cores set the IPC floor and the frequency ceiling

| Core | Pipeline | Performance | FPGA Fmax and area | Does well | Does badly | Sources |
|---|---|---|---|---|---|---|
| CVA6 (Ariane) | 6-stage, single issue, 8-entry scoreboard | Embench IPC 0.70, 2.19 CoreMark/MHz; Dhrystone IPC 0.82 | 41,260 LUT with F/D at ≈50 MHz (Kintex-7) | Rich published PPA data; core-v-verif | Fully associative flip-flop TLBs (64 entries ≈ +50% FPGA resources); 8-way D-cache select on the critical path | [PERCIVAL](https://arxiv.org/pdf/2111.15286), [Sá et al.](https://ar5iv.labs.arxiv.org/html/2302.02969), [Ariane](https://ar5iv.labs.arxiv.org/html/1904.05442), [CF'25](https://arxiv.org/html/2505.24363v1) |
| CVA6S / CVA6S+ (2024–25) | Dual-issue in-order; S+ adds WAW renaming, two-level predictor, HPDCache | S: 4.35 CoreMark/MHz (+40%); S+: Embench IPC +43.5%, 0.94 average | ASIC: S +11.1% area, −1.75% Fmax; S+ +9.3% area | Design driven by a performance model; HPDCache +74.1% bandwidth, +13.5% Fmax | FPU shares ALU2's write port: nbody IPC 0.35 vs 0.47 | [Allart](https://arxiv.org/pdf/2410.01442), [Tedeschi](https://arxiv.org/html/2505.03762v2), [CF'25](https://arxiv.org/html/2505.24363v1) |
| Rocket | 5-stage scalar | 2.32–2.94 CoreMark/MHz (sources conflict) | ≈27.5K LUT per core; up to 100 MHz on VC707 | Mature Debian SMP flow, 1–8 cores | Direction predictor consulted only on BTB hit; 1-MSHR D-cache | [vivado-risc-v](https://github.com/eugene-tarassov/vivado-risc-v), [BTB.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/BTB.scala), [HellaCache.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/HellaCache.scala) |
| BlackParrot | In-order RV64GC | None published | 8 cores running Linux 5.15 at 50 MHz | Model-checked directory protocol; several tape-outs | Blocking L1 and L2 | [BedRock dissertation](https://arxiv.org/html/2505.00962), [README](https://github.com/black-parrot/black-parrot) |
| NutShell | 9-stage single-issue RV64IMAC | None published | ZCU102 flow; 110 nm tape-out | DiffTest; boot hosted by the ZynqMP PS | Single issue; 2019-era tools | [NutShell](https://github.com/OSCPU/NutShell) |
| biRISC-V | Dual-issue in-order RV32IM | 4.1 CoreMark/MHz, 1.9 DMIPS/MHz | Not published | Compact dual issue | No hardware atomics | [biRISC-V](https://github.com/ultraembedded/biriscv) |
| CVA5 (Taiga) | Parallel variable-latency units | +42% IPC over a fixed pipeline | Not published | FPGA design centered on LUTRAM | RV32 only | [SFU](https://summit.sfu.ca/item/35160), [CVA5](https://github.com/openhwgroup/cva5) |
| MicroBlaze V | AMD-native, 3–8 stages | Not published | RV64 "Linux" configuration: 14,994 LUT, 16 BRAM, 6 DSP at 258 MHz (ZU9EG) | Fmax and area yardstick on our device family | Closed RTL | [UG1629](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization) |
| SiFive U74 | 8-stage dual issue with late ALU | ≈5.1 CoreMark/MHz (secondary source) | ASIC only | Late ALU hides load-use delay; two-level TLB | Closed | [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf), [CNX](https://www.cnx-software.com/2021/10/20/alibaba-open-source-risc-v-cores-xuantie-e902-e906-c906-and-c910/) |
| VexiiRiscv | In-order 1–2 issue with late ALU | 5.24 CoreMark/MHz, 2.50 DMIPS/MHz, 1.62 Embench | Single-issue rv64i: 186 MHz, 2,157 LUT; quad-core RV64GC Debian at 200 MHz (Efinix Ti375) | MESI-coherent L1s, prefetchers, Debian | Dual-issue area unpublished | [perf docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html), [ORConf 2024](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/orconf_2024/orconf_2024.pdf) |
| VexRiscv | RV32 single issue | 1.21–1.57 DMIPS/MHz, 2.27–2.57 CoreMark/MHz | 180–240 MHz, 0.5–2.9K LUT (Artix-7) | Tiny | Write-through D-cache; RV32 only | [VexRiscv](https://github.com/SpinalHDL/VexRiscv) |
| VeeR EH2 | 9-stage dual issue, 2 hardware threads, RV32, machine mode only | 6.3 CoreMark/MHz with both threads (simulated) | 0.067 mm² in 16 nm | Clear split between per-thread and per-core CSRs | Cannot run Linux | [VeeR EH2 PRM](https://raw.githubusercontent.com/chipsalliance/Cores-VeeR-EH2/main/docs/RISC-V_VeeR_EH2_PRM.pdf), [WD release](https://www.westerndigital.com/company/newsroom/press-releases/2019/2019-12-10-western-digital-brings-memory-closer-to-compute-with-new-risc-v-innovations) |
| OpenC906 | 5-stage single-issue RV64GC | 3.8 CoreMark/MHz (vendor, secondary source) | Needs >100K LUT4 | Core of shipping Linux SoCs | FPGA-hostile | [OpenC906](https://github.com/XUANTIE-RV/openc906), [LiteX log](https://software.mcgoron.com/Hardware/litex/commits/commit/577674bff230c2eb2da58dbbb9cc779647e81efe?page=19) |
| Muntjac | In-order RV64 | 2.17 DMIPS/MHz, 3.01 CoreMark/MHz | 17,420 LUT at 89 MHz with FPU (Kintex-7) | TileLink coherence (TL-C), AMO ALU inside the D-cache | Low Fmax | [Muntjac](https://arxiv.org/abs/2206.06769) |

The cleanest like-for-like comparison comes from a 2025 study that placed CVA6, its dual-issue successor and C910 in one SoC with identical 64 KB L1s. Average Embench IPC rose from **0.70 (CVA6) to 0.94 (CVA6S+) to 1.61 (C910)**, for +6% and +75% area respectively ([Fu et al., CF'25](https://arxiv.org/html/2505.24363v1)). A 2-wide out-of-order core with a competent predictor and non-blocking memory should land between the last two.

CVA6 is also the clearest FPGA cautionary tale. ASIC-oriented choices, such as flip-flop fully associative TLBs and an 8-way tag compare in the load path, leave it at about 41K LUTs and 50 MHz on a Kintex-7 ([PERCIVAL](https://arxiv.org/pdf/2111.15286); [Sá et al.](https://ar5iv.labs.arxiv.org/html/2302.02969)). MicroBlaze V is the opposite yardstick: AMD's single-issue RV64 Linux configuration closes at **258 MHz in about 15K LUTs on a ZU9EG**, which marks the practical frequency ceiling for our device family ([UG1629](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization)).

The in-order designs also isolate failure modes to avoid:
- Rocket's default direction predictor is consulted only on a BTB hit, and its data cache has one MSHR ([rocket-chip BTB.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/BTB.scala); [HellaCache.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/HellaCache.scala)).
- BlackParrot's L1 and L2 caches block ([BedRock dissertation](https://arxiv.org/html/2505.00962)).
- biRISC-V emulates atomics in its bootloader, which rules out SMP ([biRISC-V](https://github.com/ultraembedded/biriscv)).
- CVA6S+ regressed on floating-point code because its FPU shares the second ALU's write-back port ([Fu et al., CF'25](https://arxiv.org/html/2505.24363v1)).
- Shakti C-class publishes mutually inconsistent figures (1.72 vs under 1 DMIPS/MHz), so it cannot serve as a baseline ([Shakti 2019 slides](https://riscv.org/wp-content/uploads/2019/12/12.11-14.20a5-Menon-IITMadras-Processor-IP-Showcase-with-Andes-Technology-CHIPS-Alliance-Codasip-Shakti-Project-SiFive-Syntacore-OpenHW-Group-4.pdf); [Shakti overview](https://shakti.org.in/docs/Shakti-Overview.pdf)).

Two in-order cores contribute the most transferable ideas. VeeR EH2, a dual-threaded RISC-V core, splits its CSRs cleanly into per-thread and per-core sets ([VeeR EH2 PRM](https://raw.githubusercontent.com/chipsalliance/Cores-VeeR-EH2/main/docs/RISC-V_VeeR_EH2_PRM.pdf)). SiFive's U74 uses a late ALU that hides most load-use latency ([U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf)).

## Read ports are cheap; write ports, CAMs and long loops are not

### Build every multiported structure from LUTRAM, and give each writer its own bank

UltraScale+ distributed RAM explains most of the circuit choices. A SLICEM's eight LUTs hold 512 bits, with synchronous writes, asynchronous reads and **one shared write address**. The RAM64M8 primitive provides a 64-deep memory with **one write port and seven independent read ports in a single CLB** ([UG574](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Distributed-RAM-SLICEM-Only); [UG974 RAM32M16](https://docs.amd.com/r/en-US/ug974-vivado-ultrascale-libraries/RAM32M16)). Read ports are therefore nearly free, but every extra write port duplicates the whole storage.

The classic multiport schemes formalize this. A live-value-table (LVT) design gives each write port a bank and replicates it per read port, while a small table records which bank holds the latest value. An XOR design needs m(m−1+n) banks for m write and n read ports. On Virtex-6 at 2 writes/4 reads, the LVT is the fastest choice from depth 32 up to about 1024 entries ([LaForest et al., TRETS 2014](https://people.csail.mit.edu/ml/pubs/trets_multiport.pdf)). Storing the LVT itself in RAM ("invalidation-based LVT") raised Fmax 38% over XOR on Stratix V ([Abdelhadi & Lemieux](https://people.ece.ubc.ca/lemieux/publications/abdelhadi-fpga2014.pdf)).

The whole-core payoff has been measured. RSD moved its register file, map table, ready bits, wakeup tables, issue-queue payload and ROB status into invalidation-based LVT and banked RAM, and cut **LUTs 45% (28,166 to 15,379) and flip-flops 36% while raising Fmax 6%** ([RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)). Wong removed multi-write register files entirely. Each execution unit owns a bank, and the renamer always allocates a destination register from the bank of the unit that will produce it. The result was a 7-read/3-write register file plus bypass at 260 MHz in 2,413 ALMs ([Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)). SmolRV64 uses the same writer-sharded idea on UltraScale+ ([SmolRV64](https://github.com/tommythorn/smolrv64)).

The table below gives our structural estimates for a 64-bit integer register file, built from the UG574 primitive capacities. Storage and read muxes only; none of these figures is timing-closed.

| Integer register file option | 96 × 64-bit, 6 reads / 3 writes | 128 × 64-bit, 8 reads / 4 writes | Trade-off |
|---|---|---|---|
| Flip-flops plus read muxes | ≈16K LUT + 6.1K FF | ≈25–26K LUT + 8.2K FF | Prohibitive: about 22% of the XCK26 per core |
| LVT over LUTRAM banks (NaxRiscv-style) | ≈3.3–4.1K LUT | ≈6.5–7.7K LUT | Fully flexible |
| XOR over LUTRAM | ≈4.0K LUT | ≈8.5K LUT | Adds an internal write cycle |
| LVT in BRAM | 18 BRAM36 | 32 BRAM36 | Adds a read stage; consumes cache BRAM |
| One LUTRAM bank per writer (Wong, SmolRV64) | ≈1.15K (3×32) to 1.9K (3×64) LUT | ≈2.0K (4×32) to 3.1K (4×64) LUT | Needs per-bank free lists and binding each instruction to a unit at rename |

The estimates favor one bank per writer, sized generously at 48–64 entries each because LUTRAM depth is cheap, to absorb stalls when one bank fills up. A LUTRAM LVT is the fallback if binding instructions to units at rename hurts IPC; that IPC cost has never been measured for RV64 code.

The primitives impose two packing caveats. The XCK26's 3.5 Mb of distributed RAM corresponds to roughly 57K LUTs that can act as RAM (our estimate). And because each SLICEM has a single write address, the density of SLICEM placement, not total LUT count, can become the limit for a dual-core design. Multipumping (clocking memory at a multiple of the core clock) is ruled out: at a 250–300 MHz core clock it would need BRAMs faster than their 510–585 MHz limits on the KV260's -2LV grade ([DS925 BRAM](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Block-RAM-and-FIFO-Switching-Characteristics)).

### Schedulers, renaming, ROB and load/store queues have measured FPGA sweet spots

| Structure | Measured result | Device | Source |
|---|---|---|---|
| Scheduler entries that fit a 240 MHz cycle | CAM ≈20; age matrix 22; fused-logic matrix 42 | Stratix IV, fastest grade | [Wong, FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf) |
| Distributed scheduler for four units | 16–32 entries at 325–280 MHz, 1,750–3,750 ALMs | Stratix IV | [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) |
| RSD issue queue | 128/120/107 MHz at 16/24/32 entries; DMIPS flat from 16 to 32 entries | XC7Z020-1 | [RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf) |
| Replay-queue load speculation | −2 cycles load-to-use; IPC +8.9% average, +26.8% max (simulated); 2.2× fewer LUTs than replaying from the issue queue | XC7Z020-1 | [RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf) |
| Copy-free checkpointed renamer, 8 checkpoints | 996 LUT + 6 BRAM at 220 MHz, vs 7,082 LUT at 196 MHz (RAM table) or 2,327 LUT at 105 MHz (CAM) | Stratix III | [CFC](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf) |
| Load/store queue, 64 + 64 entries | CAM: 7,715 ALUTs at 186 MHz, 1.21 µops/cycle; NoSQ: 3,356 at 328 MHz, 1.19; in-order: 0.86 at 397 MHz | Stratix IV | [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) |
| 16-entry store queue / load queue | 1,113 / 528 ALMs | Stratix IV | [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) |
| Non-blocking cache without MSHRs | NCOR 4 KB at 329 MHz vs 207 MHz for a conventional MSHR cache | Stratix III | [NCOR](https://www.eecg.utoronto.ca/~moshovos/research/NCOR.pdf) |
| Double-precision FMA (AMD IP) | 1,671 LUT, 2,591 FF, 10 DSP, 575 MHz | ZU9EG -1LV | [AMD FP Operator](https://download.amd.com/docnav/documents/ip_attachments/floating-point.html) |
| Iterative double divide / square root | 321 / 204 LUT, 0 DSP | ZU9EG -1LV | [AMD FP Operator](https://download.amd.com/docnav/documents/ip_attachments/floating-point.html) |

**Scheduling.** FPGAs lack wired-OR logic, so a dependency matrix wakes instructions faster than a tag CAM up to about 20–24 entries per queue. Wong's fused-logic matrix compacts entries so that position equals age and folds selection into wakeup, which doubles the capacity that fits a 240 MHz cycle. His studies also set the priorities:
- Losing back-to-back issue of dependent instructions costs about 10% IPC.
- Oldest-first selection beats random selection by over 15% in large schedulers.
- Schedulers below 16 entries lose significant IPC in a machine with a 64-entry ROB.
- Dual issue gains about 70% IPC over single issue but needs about four times the scheduler entries.

Distributed per-unit queues also beat a unified pool on speed, because each selection searches fewer entries ([Wong, FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf); [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)). The single-issue case is different: Aasaraai and Moshovos measured under 10% IPC difference between 2 and 32 scheduler entries and recommended four ([Aasaraai & Moshovos, FPT 2010](https://www.eecg.utoronto.ca/~moshovos/research/sch.pdf)). The KV260's -2LV BRAM limit of 585 MHz puts it in the same speed class as Wong's Stratix IV parts. His 280–325 MHz results for small per-unit queues are therefore an upper bound for us, and a unified 32-entry oldest-first queue like NaxRiscv's realistically sits nearer 200–240 MHz (our inference).

**Renaming.** RAM-based rename tables beat CAMs. Aasaraai and Moshovos's copy-free checkpointing keeps several map tables in BRAM and uses a small LUT array of flags to record which table holds each register's newest mapping, so taking or restoring a checkpoint never copies anything ([CFC](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)). Wong found that recovering from the committed map was sufficient at 2-wide, and measured its price. Rename stalls while waiting for a mispredicted branch to commit cost 2.3% of cycles (4.2 clocks per flush); six checkpoints would have covered 88% of cycles and eight 97% ([Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)). His branches executed in order. Our core will resolve branches out of order and wait on PS-DDR misses, which makes recovery at execute time more valuable than Wong's numbers suggest.

**ROB.** Only the completion status is written out of order, so the rest of the ROB fits banked LUTRAM with no write conflicts. Wong measured about 1% IPC lost per extra commit-pipeline cycle, because commit latency only lengthens recovery ([RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf); [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)).

**Load/store queues.** These are the most FPGA-hostile structure. A CAM queue falls behind in frequency beyond about four entries, but at 16 entries it costs about the same area as CAM-free schemes and runs only about 30% slower ([Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)). The low-risk choice is a 16/16 CAM queue that compares page-offset bits first, plus a cheap PC-indexed wait predictor (RSD's uses 2 BRAMs). Store sets or NoSQ are upgrades if the queues must grow ([RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)). C910 shows how narrow disambiguation can be in shipping silicon: it compares address bits 11:4 only ([Chips and Cheese C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)).

### Front ends and caches must work around synchronous BRAM

At -2LV, BRAM clock-to-out is 1.46 ns without the output register and 0.42 ns with it ([DS925 BRAM](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Block-RAM-and-FIFO-Switching-Characteristics)). Any BTB or TAGE table kept in BRAM is therefore a timing hazard inside a single-cycle next-PC loop. RVCoreP measured a BRAM BTB access at about 2.54 ns of a 6.1 ns fetch path on Artix-7 and fixed it by indexing the table one stage earlier ([RVCoreP](https://arxiv.org/pdf/2002.03568)). RSD and BOOM were both limited by their global predictors on the Zynq-7020 ([RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)).

The pattern that works is a small zero-bubble predictor in LUTRAM or flip-flops at fetch, overridden a cycle or two later by a pipelined BRAM predictor. Wong's simulated early/late pair gave IPC 0.744, against 0.722 without the late predictor, 0.698 without the early one and 0.376 with neither ([Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)). No published FPGA TAGE implementation reports UltraScale+ area and Fmax. A student BATAGE design on Artix-7 at 50 MHz had to limit its banks to fit a single-cycle access and fell short of published accuracy ([Saveau](https://arxiv.org/pdf/2312.10426)). We estimate that four to six tagged tables of 1K–2K entries plus a bimodal base table fit in 4–8 BRAM36 per core.

**Caches.** With 4 KiB pages, a virtually indexed, physically tagged (VIPT) L1 is limited to 4 KiB per way, which happens to equal the 32 Kb data capacity of one BRAM36. A 32 KiB 8-way L1 therefore costs about eight BRAM36 with tags in LUTRAM (our estimate). Wong's non-blocking L1 was worth 1.32× in SPECint2000 IPC, and adding an L2 gave a further 1.60× ([Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)). CAM-based MSHRs are slow on FPGAs; the MSHR-free NCOR ran 58% faster than a conventional design ([NCOR](https://www.eecg.utoronto.ca/~moshovos/research/NCOR.pdf)). UltraRAM runs at 500 MHz with its output register at -2LV, which makes it the natural L2 data store ([DS925 UltraRAM](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/UltraRAM-Switching-Characteristics)).

**Datapath.** Wong measured bypassing at about 20% of the critical path ([Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)). DSP48E2 slices run at 644 MHz when fully pipelined at -2LV ([DS925 DSP](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/DSP48-Slice-Switching-Characteristics)). With 1,248 DSPs on the XCK26, multipliers and the FPU are limited by latency, not area.

### Front-end accuracy and memory parallelism top the IPC lever list

| Rank | Lever | Strongest evidence | NaxRiscv today | XCK26 cost |
|---|---|---|---|---|
| 1 | TAGE-class direction predictor (8–16 KB) with repairable speculative history | SonicBOOM's largest contributor to 0.42 → 0.86 SPEC06 IPC; perfect prediction worth +18.5% IPC; 8 KB TAGE-SC-L at 4.99 MPKI | 4 KB gshare | 4–8 BRAM36 |
| 2 | Zero-bubble micro-BTB plus a fetch-target queue that decouples prediction from fetch | RSD's 1.9× over BOOM partly from BOOM's taken-branch bubble; C910 L0 BTB 16 entries; P550 32 | 512-entry direct-mapped BTB | A few hundred flip-flops |
| 3 | Branch recovery at execute (4–8 checkpoints) plus RAS repair | 4.2 cycles lost per flush (Wong); RAS repair gives 10× fewer return mispredictions | Recovery at commit; 10-cycle best case | ≈450 bits per checkpoint |
| 4 | 1-cycle ALU, ≤3-cycle load-to-use with speculative wakeup and replay | BOOMv2 lost up to 20% IPC, more than half from load-to-use; RSD +8.9%; 2-cycle ALU −15% | Hit predictor; full flush on a wrong guess | LUTRAM FIFO |
| 5 | Memory-dependence prediction | Store sets near-ideal; no load speculation ≥2× slower on some SPEC95 programs; no store queue −16% on average | Hazard predictor only | 1 BRAM |
| 6 | Non-blocking L1D with fill buffers, 4–8 MSHRs, stride/next-line prefetch, shared L2 | Wong +32% / +60%; VexiiRiscv 204 → 791 MiB/s; C910 3.8–5.4× on STREAM; RiscyOO TLB changes +29% | 2 refill slots, 16 KB L1s | BRAM and UltraRAM |
| 7 | Short-forward-branch predication | +25.5% CoreMark/MHz; up to 1.7× on some code sequences | None | Predicate renaming |
| 8 | More issue ports than decode width | Second ALU +13% CoreMark; BOOM 2-wide → 4-wide +20% | 3 ports | Ports and bypass |
| 9 | Zba/Zbb plus macro-op fusion | Fusion removes 5.4% of effective instructions; shift-and-add address (LEA) idiom 2.24%, indexed load 2.44% | Not documented | Decode logic |
| 10 | Window size (ROB, issue queues, register file, load/store queues) | Issue queues need only 30–50% of ROB size; RSD's DMIPS flat from 16 to 32 IQ entries | 64 / 32 / 64 / 16 | LUTRAM |

Sources for the table: [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf), [Lin & Tarsa](https://ar5iv.labs.arxiv.org/html/1906.08170), [Seznec CBP-2016](https://jilp.org/cbp2016/paper/AndreSeznecLimited.pdf), [Store Sets](https://acg.cis.upenn.edu/milom/cis501-Fall10/papers/store-sets.pdf), [Celio et al. fusion](https://arxiv.org/abs/1607.02318), [Xuantie-910 Hot Chips 32](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf), [VexiiRiscv memory docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Memory/index.html), [RiscyOO](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf), and the NaxRiscv, RSD and Wong sources above.

The ordering reflects gain per unit of FPGA cost, not raw gain. Branch prediction leads because the evidence is consistent across scales. Intel's Lin and Tarsa found that removing every misprediction would raise IPC by 18.5% even with an 8 KB TAGE-SC-L, while growing that predictor to 64 KB bought only 2.7% ([Lin & Tarsa](https://ar5iv.labs.arxiv.org/html/1906.08170)). An 8–16 KB TAGE-lite is therefore the sweet spot for an FPGA core, and it costs BRAM, which NaxRiscv barely uses at 12 blocks, rather than scarce LUTs. Window size comes last: Wong found schedulers need only 30–50% of the ROB's size, and RSD's DMIPS did not move between 16 and 32 issue-queue entries ([Wong, FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf); [RSD](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)).

On an FPGA the objective must be IPC × Fmax, and the trade-off cuts both ways. BOOMv2 traded +30% frequency for up to 20% of CoreMark IPC, a net gain of as little as 4% ([BOOMv2 tech report](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)). VexiiRiscv's late-ALU option raises IPC but drops Artix-7 Fmax from about 190–210 MHz to 140 MHz ([VexiiRiscv performance docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)).

FPGA memory timing distorts the picture further. A 134 ns DRAM access, as measured for C910 on TH1520, costs about 248 core cycles at 1.85 GHz but only about 20 cycles at 150 MHz and 33 at 250 MHz (our arithmetic from [Chips and Cheese C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)). XiangShan had to add 250 cycles of artificial memory latency on FPGA because its DDR effectively answered in about one CPU cycle ([XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)). Features that create memory-level parallelism therefore look less valuable on an FPGA than on an ASIC, while CoreMark, which fits in the L1, cannot see them at all. That favors spending on the front end over a large window, and it means results should also be reported with DRAM latency padded to ASIC-like values.

## SMT and CMT readiness costs almost nothing now and a redesign later

Across 25 years of designs, two-thread SMT has bought roughly 15–60% more throughput for 5–25% more core area. Narrow cores sit at the high end, because they stall more.

| Design | Core type | Threads | Throughput gain | Area cost | Source |
|---|---|---|---|---|---|
| Pentium 4 Hyper-Threading (2002) | Deep OoO | 2 | 15–27% on applications | <5% of chip | [Koufaty & Marr](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf) |
| IBM POWER5 (2004) | Wide OoO | 2 | ≈20% with a simple design; nearly double that after resizing | 24% per core | [POWER5 DAC](https://www.cs.york.ac.uk/rts/docs/SIGDA-Compendium-1994-2004/papers/2004/dac04/pdffiles/p670.pdf) |
| MIPS 34K (2006) | Single-issue in-order | 2 | 60% | 14% of die | [Design & Reuse](https://us.design-reuse.com/news/12502/new-multi-threading-solution-mips-significant-gains-system-performance-embedded-market.html) |
| Godson-2 SMT (2006) | OoO MIPS | 2 | 31.3% average | 18.8% | [ICCD 2006](https://websrv.cecs.uci.edu/~papers/iccd2006/papers/paper_38.pdf) |
| MIPS I6400 (2014, preliminary) | Dual-issue in-order | 2 | 40–60% | <10% of cluster | [Design & Reuse](https://us.design-reuse.com/news/35317/mips-multicore-clustering.html) |
| Arm Neoverse E1 (2019) | Small OoO, 40-entry ROB | 2 | Stall cycles cut from ≈50% to ≈30% | Undisclosed | [Arm blog](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/arm-neoverse-e1-platform-empowering-the-infrastructure-to-meet-next-generation-throughput-demands) |
| MIPS P8700 (2024) | 4-wide-decode OoO RV64 | 2+ | ≈60% typical (vendor) | Undisclosed | [P8700 datasheet](https://mips.com/wp-content/uploads/2024/11/P8700_Data_Sheet.pdf) |

The industrial recipe converged early. Tullsen's 1996 study listed what SMT adds to an out-of-order superscalar:
- several PCs with a fetch selector;
- a return stack per thread;
- per-thread retirement, queue-flush and trap logic;
- thread IDs in BTB entries, so one thread's branches do not trigger predictions in another;
- a larger shared physical register file.

Its only single-thread penalty, under 2%, came from two extra pipeline stages for that register file. Its ICOUNT fetch policy, which favors the thread with the fewest instructions in flight, beat round-robin by 23% ([Tullsen et al., ISCA'96](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf)).

Intel's Hyper-Threading used three policies: split the in-order queues evenly between threads, cap each thread's share of the small schedulers, and share caches fully. Shared caches gave a 40% better hit rate and 12% better performance than partitioned ones. The real cost Intel reported was not area (under 5% of the chip) but redesigning algorithms that depend on instruction age, adding livelock avoidance, and validating every combination of the two threads' modes ([Koufaty & Marr](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf)). Raasch and Reinhardt showed that an equal static split of the issue queue and ROB performs well, while statically splitting issue bandwidth hurts ([Raasch & Reinhardt](https://static.aminer.org/pdf/PDF/000/009/820/the_impact_of_resource_partitioning_on_smt_processors.pdf)). AMD's Zen still splits its ROB, store queue and micro-op queue statically, because a dynamically shared ROB is hard to build; its 192-entry retire queue becomes 96 per thread. Caches and TLBs are shared and tagged by thread ([Chips and Cheese Zen interview](https://chipsandcheese.com/2024/07/15/a-video-interview-with-mike-clark-chief-architect-of-zen-at-amd/); [LLVM review](https://reviews.llvm.org/D47676?id=151408)).

"CMT" has three meanings, and only one fits this project.
- **AMD Bulldozer's clustered multithreading** duplicated the integer cores and L1Ds and shared fetch, decode, the FPU and the L2, targeting about 80% of two-core throughput for about 12% more module area ([HEXUS](https://hexus.net/tech/news/cpu/21664-amd-talks-servers-present-future/?page=3)). Per-thread windows, a 16 KB write-through L1D and a slow L2 sank it. The shared decoder had to be duplicated in Steamroller, and Zen replaced the scheme with SMT ([Chips and Cheese Bulldozer](https://chipsandcheese.com/p/bulldozer-amds-crash-modernization-caching-and-conclusion); [AnandTech Steamroller](https://at-web1.www.anandtech.com/show/6201/amd-details-its-3rd-gen-steamroller-architecture); [Zen at Hot Chips 28](https://old.hotchips.org/wp-content/uploads/hc_archives/hc28/HC28.23-Tuesday-Epub/HC28.23.90-High-Perform-Epub/HC28.23.930-X86-core-MikeClark-AMD-final_v2-28.pdf)).
- **Sun's chip multithreading** ran four fine-grained threads on each of eight simple in-order cores for about 20% extra core area ([Niagara slides](https://www.oracle.com/docs/tech/systems/59-niagara-microarch-poonacha.pdf)). That suits a throughput tile, not a single-thread IPC goal.
- **Coarse-grained, switch-on-event threading**, as in Itanium's Montecito, cost under 2% of core area for an estimated 15–35% gain on database workloads ([Montecito ISSCC 2005](https://ewh.ieee.org/r5/denver/sscs/References/2005_02_Naffziger.pdf)). But every thread switch in an out-of-order core flushes the window, and the CUSTARD soft-processor work found this block style of multithreading inferior to fine-grained threading on FPGAs ([Labrecque & Steffan](https://www.eecg.utoronto.ca/~steffan/papers/fpl07.pdf)).

For a 2-wide core, a Bulldozer-style shared front end halves fetch bandwidth exactly where the machine is narrowest. The one Bulldozer idea that transfers is sharing an FPU and an L2, and a dual-core with a parameterized coherent L2 already occupies that position.

The FPGA multithreading evidence is real, but all of it is in-order. Barrel-threading 3-, 5- and 7-stage soft processors raised IPC by 24%, 45% and 104% and area efficiency by 33–106%, by deleting hazard and forwarding logic. The key trick was keeping every thread's registers in one BRAM addressed by thread ID ([Labrecque & Steffan](https://www.eecg.utoronto.ca/~steffan/papers/fpl07.pdf)). Octavo ran eight threads at Stratix IV's 550 MHz BRAM limit ([Octavo](https://www.eecg.utoronto.ca/~steffan/papers/laforest_octavo_fpga12.pdf)). **No out-of-order SMT soft processor with measured FPGA cost was found**; this is a genuine gap in the literature. An out-of-order core already tolerates hazards, so SMT on it will behave like ASIC SMT, recovering idle execution slots. Because FPGA DRAM latency is short in core cycles, its latency-hiding benefit will likely be smaller than the ASIC figures. Our planning range is +20–40% throughput, extrapolated from Arm's statement that out-of-order execution plus SMT cut Neoverse E1 stall cycles from about 50% to about 30% ([Arm Neoverse E1 blog](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/arm-neoverse-e1-platform-empowering-the-infrastructure-to-meet-next-generation-throughput-demands)).

RISC-V adds specific obligations, and they define the hooks:
- **Harts look like independent CPUs.** The ISA lets one core implement several hardware threads ("harts"), but each must appear to software as an independent CPU with full privileged state ([RISC-V unprivileged spec](https://docs.riscv.org/reference/isa/v20260120/unpriv/intro.html)).
- **No early store forwarding between threads.** The memory models (RVWMO and RVTSO) are multi-copy atomic, so a hart may not forward a value from a neighbouring hart's private store buffer, and coherence may not hand a value from one hart to another early ([RVWMO explanatory material](https://docs.riscv.org/reference/isa/v20260120/unpriv/mm-eplan.html)).
- **Reservations and forward progress.** An SC must fail if another hart's store to the reservation set can be observed. Loads from other harts, possibly within the same core, must not block progress indefinitely, and reservations must survive evictions from a shared cache ([A extension](https://docs.riscv.org/reference/isa/v20260120/unpriv/a-st-ext.html)).
- **Per-hart translation.** ASIDs are local to a hart, and translation caches must appear private to each hart, so a shared TLB must tag entries by hart, not just by ASID ([privileged spec, Supervisor](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)).
- **Per-hart timers and interrupts.** The ACLINT provides a timer-compare register and a software-interrupt (IPI) register for each hart ([ACLINT](https://github.com/riscv/riscv-aclint/blob/main/riscv-aclint.adoc)).
- **Software support.** The PAUSE hint lets a multithreaded core hand resources to the sibling thread ([Zihintpause](https://docs.riscv.org/reference/isa/v20260120/unpriv/zihintpause.html)), and Linux learns about sibling threads from devicetree cpu-map thread nodes ([Linux cpu-topology binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/cpu/cpu-topology.txt)).

Two shipping cores show workable splits. VeeR EH2 labels every CSR as per-thread or per-core, gives each thread its own timer and software-interrupt pins, and clears a thread's reservation on a store from the other hart, a trap or an mret ([VeeR EH2 PRM](https://raw.githubusercontent.com/chipsalliance/Cores-VeeR-EH2/main/docs/RISC-V_VeeR_EH2_PRM.pdf)). MIPS's P8700 gives each hart its own fetch buffer, return stack and branch histories, shares the TAGE tables and the micro and main TLBs, and arbitrates issue round-robin across harts ([P8700 datasheet](https://mips.com/wp-content/uploads/2024/11/P8700_Data_Sheet.pdf)).

Security makes some of these hooks useful in a single-threaded first version (v1). PortSmash used execution-port contention between sibling threads to recover an OpenSSL P-384 private key ([TechTarget PortSmash](https://www.techtarget.com/cybersecurity/news/252452053/PortSmash-side-channel-attack-targets-Intel-Hyper-Threading)). TLBleed recovered signing keys through shared TLBs with 99.8% success, and OpenBSD responded by disabling Hyper-Threading by default ([TechTarget TLBleed](https://www.techtarget.com/cybersecurity/news/252443819/TLBleed-attack-can-extract-signing-keys-but-exploit-is-difficult?amp=1)). The industry answers each need hardware support:
- isolating indirect-branch predictors between sibling threads (Intel's STIBP) ([Intel mitigation guidance](https://intel.com/content/www/us/en/develop/articles/software-security-guidance/technical-documentation/speculative-execution-side-channel-mitigations.html));
- flushing internal buffers on privilege transitions (the MDS mitigation) ([Linux MDS docs](https://kernel.org/doc/html/v7.2-rc2/_sources/arch/x86/mds.rst.txt));
- Linux core scheduling, which forces a sibling thread idle rather than co-run untrusted tasks ([Linux core scheduling](https://www.kernel.org/doc/html/v5.14/admin-guide/hw-vuln/core-scheduling.html)).

Speculative leaks are not hypothetical for FPGA out-of-order cores (NaxRiscv's documentation demonstrates one), so context tags on predictor entries are worth having in v1 for Spectre-v2-style mitigation alone.

| Hook to build into v1 (thread-ID width 0) | Why it is expensive to add later | Basis |
|---|---|---|
| Global harts-per-core parameter; a thread ID on every fetch packet, micro-op, queue entry, memory request and page-walk request | Touches every interface | Tullsen; Intel; Zen |
| Every flush source is thread-local: flush(TID) rather than flush-all, covering exceptions, interrupts, FENCE.I, SFENCE.VMA, replays, debug and WFI | Intel had to redesign flush and age logic | Koufaty & Marr |
| Age tracked by allocation order (age matrix), not by subtracting ROB indices | A partitioned ROB breaks index-based age | Koufaty & Marr; Zen |
| Store forwarding requires matching address and matching thread ID; sibling commits drive the load-queue snoop path | RVWMO forbids early forwarding between harts | RVWMO |
| One LR reservation per thread, with a hold-off timer against sibling livelock | Two siblings can kill each other's reservations indefinitely | A extension; VeeR EH2 |
| TLB and page-walk-cache entries tagged {thread ID, ASID}; cached PMP results per thread | ASIDs are hart-local | Supervisor spec; Zen |
| All ISA CSRs (PMP, satp, Sstc, counters) in banks indexed by thread ID | Full per-hart privileged state is mandatory | RISC-V; VeeR EH2 |
| Per-thread occupancy counters with caps on issue queues, load/store queues, MSHRs and the free list | Prevents one thread clogging shared queues | Intel threshold policy |
| Register-file size, tag width and rename-table depth as parameters | SMT2 needs +32 integer and +32 FP registers | Tullsen; POWER5 |
| Predictor context tags, flushable fill and store buffers, an SMT-off mode | Hardware equivalents of STIBP and the MDS flush | Intel; Linux |
| Coherent L2 with a parameterized number of agents; presence tracked per physical L1, not per hart | Needed for dual-core anyway; allows more cores or a second cluster later | Coherence section below |

If these hooks are parameterized with a thread-ID width of zero, we estimate the v1 resource overhead at well under 1% of core LUTs and flip-flops, with no added pipeline stages; the real cost is perhaps 5–10% more design and verification time. Moving to two threads (SMT2) would add roughly 10–20% of core LUTs and flip-flops. That cost is dominated by register-file growth multiplied by port replication and by doubling the depth of the rename tables and CSR banks, which is consistent with the 5–24% ASIC range above. These are first-principles estimates, so synthesizing a thread-ID-width-1 build early, even one never shipped, is the cheapest way to measure them.

The evidence supports a three-step path:
1. **v1:** a single-threaded out-of-order core with the hooks in place.
2. **v1.5 (optional):** switch-on-L2-miss coarse-grained threading. It exercises per-thread flush, CSR banking, TLB tagging and reservation snooping under Linux with the least added logic.
3. **v2:** SMT2 with a statically split ROB and load/store queues, a capped shared issue queue, ICOUNT fetch (one thread per fetch cycle is enough at 2-wide), shared thread-tagged TLBs and caches, and an SMT-off mode.

## An inclusive UltraRAM L2 with a presence-bit directory fits two cores and scales to four

Open RISC-V multicore designs use three coherence families:

| Family | Examples | Evidence | Fit for two out-of-order cores on the XCK26 |
|---|---|---|---|
| Broadcast snooping through a central unit | Culsans (CVA6, MOESI over AMBA ACE), OpenC910 CIU, Muntjac broadcaster | Culsans +15.8% average over OpenPiton for 1.6% of system area; capped at 4 cores | Workable, but probes compete with load pipelines when each core has many misses outstanding |
| Directory in the tags of an inclusive L2 | rocket InclusiveCache, SpinalHDL coherent L2 (NaxRiscv/VexiiRiscv), XiangShan CoupledL2 | VexiiRiscv quad-core Debian at 200 MHz; NaxRiscv dual-core Debian | Best fit: 2–8 presence bits per line, one ordering point |
| Standalone duplicate-tag directory with a non-inclusive L2 | BlackParrot BedRock | Aimed at 4–32 cores; fixed and microcoded engines within 1%; protocol model-checked | Overkill at 2–4 cores |

Sources: [Culsans](https://arxiv.org/abs/2407.19895), [OpenC910 datasheet](https://github.com/XUANTIE-RV/openc910/blob/main/doc/openc910_datasheet.pdf), [Muntjac](https://arxiv.org/abs/2206.06769), [BedRock paper](https://ar5iv.arxiv.org/html/2211.06390), [riscv_sc_2024 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/riscv_sc_2024/riscv_sc_2024.odp), [37C3 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/37c3_271223/37c3_271223.pdf).

The headline snooping result is weaker than it looks. Culsans' CCU orders coherent requests through a single central controller and leaves the last-level cache outside the protocol. It ran Splash-3 15.8% faster on average than a dual-core OpenPiton (up to +32.87% on OCEAN, 0% on FFT and −0.72% on RADIX) for 1.6% of system area ([Culsans](https://arxiv.org/abs/2407.19895)). But OpenPiton adds a write-through L1 and an extra L1.5 level, so the comparison measures hierarchy depth as much as snooping versus directories. Culsans' own authors note that CVA6 keeps few transactions outstanding ([Culsans](https://arxiv.org/abs/2407.19895); [BedRock dissertation](https://arxiv.org/abs/2505.00962)). BedRock removes transient states by letting the directory serialize requests. Its microcoded engine came within 1% of the fixed-function one (2.3% worst case), the directory costs a constant 6.25% of storage, and the protocol was verified with CMurphi ([BedRock paper](https://ar5iv.arxiv.org/html/2211.06390)).

The SpinalHDL scheme behind NaxRiscv and VexiiRiscv is the closest FPGA precedent:
- each L1 line holds unloaded, shared or unique permission;
- probes reuse the D-cache store pipeline;
- the L2 is inclusive of the data caches only, and the instruction cache is not coherent ([NaxRiscv memory docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/memory/index.html)).

It ran dual-core RV64GC Debian at 100 MHz. One bug, a D-cache releasing permissions a second time after a probe, surfaced only as a kernel spinlock hang after about an hour on hardware, roughly 3.6 × 10¹¹ cycles, or about 40 days of simulation ([37C3 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/37c3_271223/37c3_271223.pdf)).

**The recommended architecture is an inclusive, banked shared L2 that serves as the single point where coherent requests are ordered.** Each line's tag records:
- valid, tag and dirty bits;
- a "unique holder" flag;
- a presence vector with one bit per L1 data cache, optionally one per instruction cache as well (2 bits for two cores, 8 bits for four cores with separate I and D tracking).

The L1 data caches are write-back with 64-byte lines and use MESI, moving from Exclusive to Modified silently. The L2 grants Exclusive whenever the presence vector shows no other holder. There is no Owned state at L1: on a downgrade the L2 takes the dirty data and keeps the line dirty. That is C910's split of MESI at L1 and MOESI at L2 ([OpenC910 docs](https://github.com/XUANTIE-RV/openc910/tree/main/doc)).

Transactions should follow the public TileLink TL-C semantics: Acquire/Grant/GrantAck, Release/ReleaseAck and Probe/ProbeAck. Strict channel priority (A < B < C < D < E) guarantees freedom from deadlock, and the spec spells out the races ([TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)):
- a probe arriving while the core's own Acquire is outstanding;
- a voluntary writeback crossing a probe;
- the window between Grant and probe, which GrantAck closes;
- a write upgrade issued while a read miss is in flight.

We avoid broadcast because two out-of-order cores, each with eight or more misses outstanding plus prefetches, would steal L1 tag bandwidth from each other's load pipelines on every miss, whereas presence bits filter almost all probes because most lines are private. This reasoning is ours; no FPGA measurement compares the two schemes for two out-of-order cores.

**Sizing on the XCK26.** One UltraRAM is 4K × 72 bits. Using 64 data bits per row gives 32 KiB per block. A 512 KiB L2 therefore takes 16 UltraRAMs: four side by side give 256-bit rows, so a 64-byte line takes two beats. Two banks interleaved on physical-address bit 6 mirror C910's L2 ([Chips and Cheese C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)). The tags and directory for an 8-way 512 KiB L2 fit in about seven or eight BRAM36. A 1 MiB 16-way L2 takes 32 UltraRAMs and 13–16 BRAM36 (our estimates from the [K26 data sheet](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf)). An L2 hit should take about 8–12 cycles at 200–250 MHz; this is an estimate, not a measurement.

**MSHRs.** rocket-chip's InclusiveCache rule allots each bank 2 + max(2, ⌈round-trip ÷ beats per block⌉) miss-status holding registers ([InclusiveCache](https://github.com/chipsalliance/rocket-chip-inclusive-cache)). A 40-cycle trip to PS DDR over a 128-bit port (4 beats per line) gives 12 per bank, which also fits the PS port limits of 8 unique IDs and 16 outstanding transactions per port ([UG1085](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)).

**Inclusion victims.** An inclusive L2 must invalidate L1 copies when it evicts a line. Mitigations: make the L2 at least eight times the total L1D capacity, prefer victims with empty presence vectors, and keep a small victim buffer (the SpinalHDL L2 defaults to two lines) ([SpinalHDL coherent cache](https://github.com/SpinalHDL/SpinalHDL/blob/dev/lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Cache.scala)). Scaling to four cores widens the presence vector and adds banks without changing the protocol.

**What the RISC-V memory model requires of the core.** RVWMO has 13 preserved-program-order rules and three axioms ([ISA manual snapshot, Oct 2026](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)). For an out-of-order core they translate into concrete mechanisms:
- **Same-address load ordering.** Two loads to the same byte must stay ordered, so a probe, invalidation or eviction that hits a performed-but-uncommitted load must replay the younger loads to that line.
- **Stores.** Stores become visible only after commit.
- **Atomics.** No load may take a value early from an AMO or SC, so AMOs, LR and SC execute non-speculatively at the ROB head, in the L1 data cache, on a line held unique.
- **LR/SC forward progress.** Constrained LR/SC loops of at most 16 instructions must eventually succeed; the guarantee is freedom from livelock, not from starvation. Za64rs caps reservation sets at 64 bytes, which matches the line size. Designs bound the hold window differently: Rocket holds a reservation for up to 80 cycles and then backs off for 3, VexiiRiscv locks a line for 32 cycles and toggles the reservation so a spinning LR cannot starve others, and Muntjac locks lines for 16 cycles after a refill ([RocketCore.scala](https://github.com/chipsalliance/rocket-chip/blob/master/src/main/scala/rocket/RocketCore.scala); [VexiiRiscv memory docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst); [Muntjac](https://arxiv.org/abs/2206.06769)).
- **Fences are local.** FENCE.I and SFENCE.VMA affect only the local hart. Cross-hart instruction and TLB coherence go through inter-processor interrupts or the SBI v3.0 remote-fence extension, and Svinval can batch invalidations later ([SBI v3.0](https://github.com/riscv-non-isa/riscv-sbi-doc/releases/tag/v3.0)).

The instruction cache can start non-coherent, flushed by FENCE.I and SBI remote fences. Later, an instruction-cache presence bit lets stores invalidate stale lines and gives Ziccid, which makes stores visible to other harts' instruction fetch without FENCE.I, provided the fetch buffer stays in program order ([ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)).

**Coherence with the PS side.** The PS ports have different coherence properties ([UG1085](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft); [PG201](https://docs.amd.com/r/3.4-English/pg201-zynq-ultrascale-plus-processing-system/Slave-Interface)):
- **HP0–3** are non-coherent.
- **HPC0/1** snoop the A53 caches through the CCI interconnect, which adds latency.
- **ACE** gives full two-way coherence but accepts only 64-byte lines.
- **ACP** allows at most four outstanding transactions, and AMD discourages it.

The cleanest arrangement keeps the soft cores in their own coherence domain behind the L2, over HP ports. PL DMA masters attach to the L2 as uncached clients. Buffers shared with the A53 Linux use Zicbom cache maintenance or non-cacheable (Svpbmt) mappings.

**Verification** should follow BedRock and the TileLink rules:
1. A Murphi- or Rumur-style model of 2–4 caches with crossing writebacks and probes, before writing RTL.
2. Per-channel assertions for every TL-C rule of the form "must not send X while Y is pending."
3. Random traffic generators against the L2.
4. The axe trace checker, which found serious bugs in Rocket Chip and BERI and caught a TSO-forbidden pattern caused by a non-blocking L1 ([axe](https://github.com/CTSRD-CHERI/axe); [FMCAD 2016](https://www.cl.cam.ac.uk/~swm11/research/papers/fmcad2016-coherency-checker.pdf)).
5. The 7,000-plus litmus-tests-riscv suite, whose full hardware runs take days to weeks ([litmus-tests-riscv](https://github.com/litmus-tests/litmus-tests-riscv)).

XiangShan's dual-core L2 bug surfaced only after more than 168 hours of simulated Redis, about 3 billion cycles ([JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)).

## The KV260 dictates the memory path, clocking, boot flow and tooling

### A -1-class device with 117K LUTs and no DRAM attached to the programmable logic

| Resource | XCK26 (K26 SOM) |
|---|---|
| CLB LUTs / flip-flops | 117,120 / 234,240 |
| Distributed RAM | 3.5 Mb (≈57K LUTs usable as RAM, our estimate) |
| Block RAM | 144 × 36 Kb (5.1 Mb) |
| UltraRAM | 64 × 288 Kb, 72-bit with ECC |
| DSP48E2 | 1,248 |
| Speed grade | -2LV, fabric VCCINT 0.72 V |
| Memory | 4 GB DDR4-2400 x64 on the PS only |

Source: [K26 data sheet DS987](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf).

The low-voltage grade matters. At -2 and 0.72 V, BRAM reaches 585/510 MHz (write-first/read-first mode) against 738/637 MHz at the standard 0.85 V. UltraRAM reaches 500 MHz with its output register against 600, and DSPs reach 644 MHz against 775 ([DS925 BRAM](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Block-RAM-and-FIFO-Switching-Characteristics); [DS925 UltraRAM](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/UltraRAM-Switching-Characteristics); [DS925 DSP](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/DSP48-Slice-Switching-Characteristics)). That is roughly 80% of a standard -2 part, so timing should be planned against a -1-class corner. Fmax published for ZCU102/ZCU104 boards will overstate what the K26 achieves. The hard blocks still leave ample margin at 150–250 MHz, so the CPU's Fmax will be set by LUT depth and routing.

Calibration points:
- MicroBlaze V at 258 MHz on a ZU9EG ([UG1629](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization));
- NaxRiscv RV32 at 360 MHz on the fastest UltraScale+ grade (a single 2022 datapoint);
- SmolRV64 at 166.67 MHz on a KU5P;
- NaxRiscv RV64 at 137 MHz on Artix-7.

From these we set **150 MHz as the floor and 200 MHz as the goal for a closed dual-core SoC**, with 250 MHz reachable only if the load-to-use, wakeup-select and next-PC loops are all short.

The LUT budget is the binding constraint. SmolRV64 alone uses 114K LUTs, and a single Medium BOOM with L2 uses 148.5K, more than the whole device ([vivado-risc-v](https://github.com/eugene-tarassov/vivado-risc-v)). Keeping total utilization near 80% (a common rule of thumb, not a sourced figure) and reserving 10–15K LUTs for L2 control, AXI bridges, debug and peripherals leaves **about 40K LUTs per core, including FPU and MMU**.

**Memory path.** The KV260 has no DRAM attached to the programmable logic. The cores must reach the PS's DDR4-2400 x64 (19.2 GB/s peak) through PS slave ports. HP0–3 are the direct non-coherent path. HP1 and HP2 share one DDR controller port that offers relatively low latency, HP0 shares a port with DisplayPort, and HP3 shares one with the FPD DMA. Each port's PS side is 128 bits wide and handles 8 unique IDs and up to 16 outstanding transactions ([UG1085](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)). Every PS–PL AXI interface is capped at **333 MHz**, or 5.33 GB/s per direction for one 128-bit port ([DS925](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Processor-System-PS-Performance-Characteristics)). On a ZCU102 with the same DDR4 configuration, measured throughput reached 75% of theoretical, at best 13.7 GB/s over three HP ports at 300 MHz. Average read latency under saturating traffic ranged from 250 to 10,000 cycles ([Manev et al., FPT 2019](https://pure.manchester.ac.uk/ws/files/137731499/FPT19_paper_14.pdf)). No source gives the idle latency from the programmable logic to PS DDR, so it must be measured on the board before MSHR counts are fixed. Bandwidth is not the constraint; latency is.

**I/O and clocks.** The programmable logic reaches only a single 8-signal Pmod, the fan pin and the MIPI camera inputs. Ethernet, microSD, USB and DisplayPort/HDMI belong to the PS. There is no oscillator on the programmable-logic side, so clocks come from the PS's PL_CLK outputs through an MMCM, or from the Pmod's clock-capable pin ([UG1089](https://docs.xibif.ch/_downloads/480ec1217d1ac2bd520e695148cfe86f/KV260_Userguide.pdf); [KV260 devicetree overlay](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/xilinx/zynqmp-sck-kv-g-revB.dtso); [LiteX KV260 platform](https://github.com/litex-hub/litex-boards/blob/master/litex_boards/platforms/xilinx_kv260.py)). The fansink is rated for a 10 W budget, so a full-chip bitstream should keep driving the fan pin ([UG1089](https://docs.xibif.ch/_downloads/480ec1217d1ac2bd520e695148cfe86f/KV260_Userguide.pdf)).

### Boot through the A53s, debug through BSCAN, and plan around Vivado licensing

The KV260 boots its A/B firmware from QSPI and then Linux from microSD on the A53 cores ([UG1089](https://docs.xibif.ch/_downloads/480ec1217d1ac2bd520e695148cfe86f/KV260_Userguide.pdf)), and loads programmable-logic designs at runtime through xmutil and dfx-mgr ([Kria on-target utilities](https://xilinx.github.io/kria-apps-docs/creating_applications/2022.1/build/html/docs/target.html)). That makes the A53s the natural host for the soft cores:
1. Reserve a no-map memory carveout in the boot devicetree ([reserved-memory binding](https://github.com/devicetree-org/dt-schema/blob/main/dtschema/schemas/reserved-memory/reserved-memory.yaml)).
2. Copy OpenSBI, the kernel Image, the devicetree and an initramfs into it, using UIO or a remoteproc driver ([UIO HOWTO](https://www.kernel.org/doc/html/latest/driver-api/uio-howto.html); [remoteproc](https://www.kernel.org/doc/html/latest/staging/remoteproc.html)).
3. Release the cores' reset through an AXI GPIO.

NutShell already uses this pattern on a ZCU102, with a PS-side loader and a programmable-logic UART that Linux on the PS sees as /dev/ttyUL1 ([NutShell](https://github.com/OSCPU/NutShell)). Storage and networking can be provided as virtio-mmio devices whose back-ends run on the A53s, following a published shared-memory design on the ZCU102 ([hypervisorless virtio](https://github.com/danmilea/hypervisorless_virtio_zcu102)). **No verified soft RISC-V Linux port on the KV260 was found.** LiteX's KV260 target runs on the A53, and linux-on-litex-vexriscv's ZCU104 build relies on a DDR4 SODIMM attached to the programmable logic, which the KV260 lacks ([LiteX KV260 target](https://github.com/litex-hub/litex-boards/blob/master/litex_boards/targets/xilinx_kv260.py); [linux-on-litex-vexriscv](https://github.com/litex-hub/linux-on-litex-vexriscv)).

**Debug.** OpenOCD mainly supports Debug spec 0.13, and the ratified v1.0 (February 2025) is almost entirely compatible with it ([OpenOCD manual](https://openocd.org/doc/html/Architecture-and-Core-Commands.html); [Debug v1.0](https://docs.riscv.org/reference/debug/v1.0/index.html)). On Zynq UltraScale+, the JTAG tunnel has known traps ([jsteward](https://jsteward.moe/risc-v-hardware-design-part-b-edgeboard-series.html)):
- the BSCANE2 tunnel must use USER4, because ILA and VIO occupy USER1;
- UltraScale+ USER opcodes are 0x920–0x923 rather than 0x20–0x23;
- the PS and PL TAPs are chained, and the Arm DAP adds a 1-bit shift, which required patching OpenOCD.

LiteX's own JTAG helper rejects ZynqMP devices outright ([linux-on-litex-vexriscv](https://github.com/litex-hub/linux-on-litex-vexriscv)).

**Tooling.** Up to Vivado 2025.2, the free edition targets the K26 when the project names part xck26-sfvc784-2LV-c ([AMD support answer](https://adaptivesupport.amd.com/s/question/0D52E00007G0tIJSAZ/vivado-and-kria-board-k26-som?language=en_US)). Vivado 2026.1 moved to tiered licensing and checks the license at launch. Secondary reports say the free BASIC tier runs on Windows only and has reduced ILA support ([AMD licensing options](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html); [TE Labs](https://www.telabs.dev/articles/vivado-2026-1-licensing-changes)). AMD says Kria kits now include a one-year CORE voucher ([AMD support thread](https://adaptivesupport.amd.com/s/question/0D5Pd00001tiKr4KAE/kv260-purchased-new-but-no-vivado-core-license-voucher-included-is-this-expected-with-vivado-20261?language=en_US)). A team on Linux hosts should either freeze on 2025.2 or budget for CORE renewals over a multi-year CPU project.

### Linux fixes the ISA floor and a list of privileged-spec traps

**Kernel plus Buildroot** needs:
- RV64IMA with Zicsr and Zifencei, and machine, supervisor and user modes;
- Sv39, with satp ignoring writes of unsupported modes, because Linux probes Sv57, then Sv48, then Sv39 by writing satp and reading it back ([Linux mm/init.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/mm/init.c));
- an ACLINT machine timer and software-interrupt block, a PLIC, a UART, and a devicetree that OpenSBI's generic platform can parse;
- SBI firmware providing the TIME, IPI, RFENCE and HSM extensions;
- a boot hand-off with a0 holding the hart ID, a1 pointing to an 8-byte-aligned devicetree, satp at zero, and the kernel 2 MB-aligned ([Linux boot requirements](https://docs.kernel.org/arch/riscv/boot.html); [OpenSBI generic platform](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/platform/generic.md)).

The A extension is not optional in the kernel; the FPU and compressed instructions are ([Linux Kconfig](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/Kconfig)).

**PMP.** The spec allows only 0, 16 or 64 PMP entries, and once any exist, a supervisor or user access that matches none of them fails. OpenSBI aborts with "insufficient PMP entries" if it runs out, and its ACLINT timer driver claims extra machine-only regions ([machine-level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html); [OpenSBI PMP code](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart_pmp.c)). Sixteen PMP CSRs with at least eight working entries is the practical floor (our inference).

**Timers, CSRs and ASIDs.**
- A hardware time CSR avoids trapping every rdtime, including those from the vDSO ([OpenSBI requirements](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/docs/platform_requirements.md)).
- Without menvcfg, OpenSBI will not detect Sstc or enable the cache-block and Svpbmt features ([OpenSBI sbi_hart.c](https://raw.githubusercontent.com/riscv-software-src/opensbi/master/lib/sbi/sbi_hart.c)).
- Linux enables its ASID allocator only if there are more than twice as many ASIDs as possible CPUs; otherwise it flushes the whole TLB on every context switch ([Linux mm/context.c](https://raw.githubusercontent.com/torvalds/linux/master/arch/riscv/mm/context.c)). C910's 16-bit ASID cut those flushes about tenfold ([Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)).

**Distributions** need far more. Debian 13, Fedora and Arch require RV64GC with the lp64d ABI. Ubuntu 24.04 targets RVA20, and Ubuntu 25.10 and later require RVA23, which brings the vector (V) and hypervisor (H) extensions ([Debian wiki](https://wiki.debian.org/RISC-V); [Fedora at FOSDEM 2026](https://fosdem.org/2026/events/attachments/SQGLW7-fedora-on-riscv/slides/266759/fedora-ri_x3tr93d.pdf); [Arch Linux RISC-V](https://riscv.mirror.pkgbuild.com/); [Canonical](https://ubuntu.com/blog/canonical-and-ubuntu-risc-v-a-2025-retro-and-looking-forward-to-2026)). A core without an FPU therefore cannot run any mainstream distribution, so F/D and C are mandatory for the Debian-class milestone.

**Cheap extensions to add from day one:**
- Zba/Zbb/Zbs, Zicond, Zkt, Zihintpause and Svinval.
- Sstc: Linux raises the timer's rating from 100 to 450 and stops making an SBI call on every timer reprogram ([timer-riscv.c](https://raw.githubusercontent.com/torvalds/linux/master/drivers/clocksource/timer-riscv.c)).
- Sscofpmf: without it, perf supports counting but not sampling ([riscv_pmu_sbi.c](https://raw.githubusercontent.com/torvalds/linux/master/drivers/perf/riscv_pmu_sbi.c)), and sampling is how we will tune IPC under Linux.

**Traps in the privileged spec:**
- Never cache invalid PTEs. Linux does not fence after allocating a page, so an out-of-order core whose page walker reads memory while a PTE store still sits in the store queue takes a fault an in-order reference model would not take ([JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)).
- Start with Svade semantics, which fault when the accessed or dirty bit must be set. If hardware updating is added later, dirty-bit updates must be exact, never speculative.
- WFI must wake on any locally enabled pending interrupt, regardless of the global enables ([machine-level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)).
- NutShell shipped bugs worth testing for: 32-bit AMOs not sign-extending, MPRV not cleared on return, misaligned LR/SC not faulting, TVM not trapping, misaligned superpages not faulting, and mtval written instead of stval under delegation ([JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)).
- The P550's thousand-cycle misaligned-access traps argue for handling misaligned accesses in hardware, for robustness in Linux userland ([Chips and Cheese P550](https://chipsandcheese.com/p/inside-sifives-p550-microarchitecture)).

### Verification has to be lockstep, tolerant of legal differences, and FPGA-accelerated

Every open core that boots Linux relies on lockstep co-simulation: an instruction-set simulator runs alongside the RTL and every committed instruction is compared.
- **NaxRiscv** runs Spike as a shared library inside Verilator. Its full regression, including FreeRTOS and Linux, takes about 30 minutes with Verilator pinned to 4.228 ([NaxRiscv simulation docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/simulation/index.html); [NaxRiscv simulator README](https://raw.githubusercontent.com/SpinalHDL/NaxRiscv/main/src/test/cpp/naxriscv/README.md)).
- **SpinalHDL's RVLS** extends this to multicore by keeping a per-CPU view of when loads read and when stores become globally visible ([RVLS](https://github.com/SpinalHDL/rvls)).
- **XiangShan's DiffTest** compares against the NEMU model and tolerates legal mismatches through "diff rules": at least 120 static rules for implementation-defined CSR fields, plus dynamic rules. The core tells the reference model when to take interrupts, its page faults are accepted as hints, MMIO values are copied, and a global memory model handles multicore ordering. XFUZZ coverage-guided fuzzing found 33 NutShell bugs. LightSSS fork-based snapshots cost under 1%, and turning on waveforms slows simulation to 8.5% of normal speed ([JCST 2023](https://jcst.ict.ac.cn/article/doi/10.1007/s11390-023-3285-8)).

SonicBOOM's authors found the LSU and D-cache the most bug-prone components, and aggressive speculative page walks exposed a missing FENCE in Linux's page-table setup ([SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)).

The supporting tools have limits:
- The ACT4 architectural tests with the Sail model show compatibility, but the README itself says they are not verification ([riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test)).
- riscv-dv needs a commercial SystemVerilog simulator, which makes FORCE-RISCV the open alternative ([riscv-dv](https://github.com/chipsalliance/riscv-dv); [FORCE-RISCV](https://github.com/openhwgroup/force-riscv)).
- TestFloat should check the FPU in isolation from the start, given NaxRiscv's open FPU bugs ([TestFloat](http://www.jhauser.us/arithmetic/TestFloat.html)).
- riscv-formal covers instruction semantics through the RVFI trace interface ([riscv-formal](https://github.com/YosysHQ/riscv-formal)).

Simulation speed forces most long runs onto hardware. Booting Linux single-threaded in Verilator, Rocket simulates at about 30 kHz, BOOM at about 9 kHz and XiangShan at about 0.9 kHz ([GSIM](https://arxiv.org/html/2508.02236v1)). At 3–10 kHz, a billion cycles takes one to four days. A practical stack therefore pairs:
- a minimal Linux image for simulation;
- LightSSS-style snapshots;
- streaming the commit trace from the programmable logic to a checker running on the A53s, as FireSim's Dromajo and Spike bridges do on other FPGAs ([FireSim Dromajo docs](https://firesim.readthedocs.io/en/latest/Advanced-Usage/Debugging-and-Profiling-on-FPGA/Dromajo.html)).

**A performance model should come before RTL.** CVA6S's Python model was 99.2% accurate on CoreMark. It caught a dual-issue step that delivered 12% instead of the predicted 21%, and a small scoreboard that was under-used ([Allart et al.](https://arxiv.org/pdf/2410.01442)). XiangShan's calibration method cut its gem5 model's error on targeted microbenchmarks from 59.2% to 1.4% ([Microarchitecture Cliffs](https://arxiv.org/abs/2602.11580)). An uncalibrated gem5 model of RSD missed by up to 36% on individual benchmarks, mostly in the branch predictor and memory system ([gem5 vs RSD](https://arxiv.org/abs/2106.09991)).

## Design targets: the numbers our core must beat

The evidence converges on a specification that keeps NaxRiscv's width and its LUTRAM-centered philosophy, while replacing each documented economy with a measured FPGA fix.

| NaxRiscv choice (documented) | Replacement in our core | Evidence for the gain | Cost class |
|---|---|---|---|
| 4 KB gshare; 512-entry direct-mapped BTB; decode trusts BTB targets | 16–32-entry micro-BTB, 512–1K set-associative BTB, 8–16 KB TAGE-lite with repairable history, small indirect predictor, fetch-target queue | SonicBOOM 0.42 → 0.86 SPEC06 IPC; perfect prediction worth +18.5% IPC | 4–8 BRAM36 plus a few hundred flip-flops |
| Recovery at commit; 10-cycle best case; RAS entries not repaired | 4–8 rename checkpoints (copy-free style), redirect at execute, RAS snapshot repair | Wong: 4.2 cycles lost per flush; 10× fewer return mispredictions | ≈450 bits per checkpoint |
| 32-slot unified queue filled by rows, never compacted | Distributed age-ordered matrix queues: 2×12–16 ALU, 12–16 memory, 8–12 multiply/divide/FP | Matrix fastest at ≤20–24 entries per queue; dual issue needs larger totals | ≈2–4K LUT (estimate) |
| One pipe shared by loads, stores, multiply, divide and CSRs | Separate load pipe and store-address pipe, store data decoupled from the issue queue, multiply/divide/FP on their own port | Second ALU alone +13% CoreMark; keeping stores from waiting for data avoids bad load speculation | One or two more ports |
| Full flush when a predicted hit misses | Speculative wakeup with a LUTRAM replay queue | RSD +8.9% average IPC, 2.2× fewer LUTs than replaying from the issue queue | LUTRAM FIFO |
| No memory-dependence predictor; page-offset-only first pass | Store-set-lite (1 BRAM table plus a small LUTRAM table) or a wait table; keep the two-pass compare | Store sets near-ideal; no load speculation ≥2× slower on some programs | 1 BRAM |
| 16 KB L1s, 2 refill slots, no prefetcher documented | 32 KiB 8-way VIPT L1D (8 BRAM36), 4–8 MSHRs with fill buffers, stride and next-line prefetch, shared UltraRAM L2 | Non-blocking cache +32% and L2 +60% (Wong); prefetch gave VexiiRiscv 3.9× read bandwidth | BRAM and UltraRAM |
| 192-entry LUTRAM TLBs; no page-walk cache documented | 8–16-entry fully associative L1 TLBs, 512-entry L2 TLB in BRAM, page-walk cache, 16-bit ASID | RiscyOO TLB changes +29%; growing fully associative TLBs cost CVA6 ≈50% more resources | BRAM |
| Placement and timing failures above two cores | Floorplanned cores, L2 placed near the PS ports, protocol ready for four agents | NaxRiscv issue #89 | Design effort |
| Open FPU subnormal and rounding-mode bugs | Clean-room F/D verified with TestFloat from day one | NaxRiscv 2026 issues | Verification effort |

| Structure | Proposed v1 starting point | NaxRiscv | BOOM Medium |
|---|---|---|---|
| Fetch / decode / rename / retire | 2 per cycle, with compressed-instruction aligner and fetch-target queue | 64-bit fetch, 2 / 2 / 2 | 4-instruction fetch, 2-wide decode |
| Issue ports | 5: 2 ALU with branch, load, store address, multiply/divide/FP | 3 | 2 integer, 1 memory, 1 FP |
| ROB | 64 entries (explore up to 96) | 64 | 64 |
| Integer physical registers | 96–128 in per-writer LUTRAM banks, LVT as fallback | 64, XOR-LVT banks | 80 |
| Issue queues | ≈40 entries in four distributed age-ordered matrix queues | 32 unified, filled by rows | 20 integer / 12 memory / 16 FP |
| Branch recovery | 4–8 rename checkpoints, resolved at execute | Committed map, applied at commit | Map snapshot per branch, 12 maximum |
| Load path | 3-cycle load-to-use, speculative wakeup, replay queue | 3 cycles with hit predictor, flush on a wrong guess | Dependents woken at writeback |
| L1 caches | 32 KiB 8-way VIPT each (16 KiB 4-way fallback) | 16 KB 4-way | 16 KiB 4-way |
| Shared L2 | 512 KiB–1 MiB inclusive in UltraRAM, 2 banks, presence-bit directory | Optional (128 KB in the doom test) | — |

Sources for the reference columns: [NaxRiscv performance docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html), [BOOM config-mixins](https://raw.githubusercontent.com/riscv-boom/riscv-boom/master/src/main/scala/v3/common/config-mixins.scala), [BOOM issue docs](https://docs.boom-core.org/en/latest/sections/issue-units.html), [BOOM rename docs](https://docs.boom-core.org/en/latest/sections/rename-stage.html). The v1 column is our recommendation, synthesized from the evidence above.

| Metric (identical binaries, same SoC) | NaxRiscv | Strongest in-order rival | Recommended target |
|---|---|---|---|
| CoreMark/MHz, EEMBC-compliant | 4.94 (RV64); 4.59 (RV64GC, simulated) | 5.24 VexiiRiscv; 5.63 Andes AX45MP (vendor) | ≥5.5; stretch ≈6 with SFB (SonicBOOM reached 6.15) |
| DMIPS/MHz, -O3 -fno-inline | 2.94 | 2.50 VexiiRiscv | ≥3.2 |
| Embench-iot, pinned version | 1.84 (RV64) | 1.62 VexiiRiscv | ≥2.0 |
| IPC reference (RV32 build "A") | 1.28 CoreMark, 1.65 Dhrystone, 1.42 Embench | — | Higher on every shared binary |
| Linux applications | 74.07 fps chocolate-doom with 128 KB L2 | 64.58 fps VexiiRiscv | ≥15–20% over NaxRiscv on a SPEC CPU2017 intrate subset |
| Core Fmax | 137 MHz RV64 (Artix-7 -3); 360 MHz RV32 (UltraScale+ -3, 2022 datapoint) | 258 MHz MicroBlaze V RV64 Linux configuration (ZU9EG) | ≥150 MHz floor, 200 MHz goal, dual-core SoC closed on the XCK26 |
| Area per core | 17.9K LUT (RV64, no FPU) | ≈15K LUT MicroBlaze V | ≤40K LUT including FPU, MMU and L1s |
| SMP | Dual-core Debian at 100 MHz; builds above two cores failed timing | VexiiRiscv quad-core Debian at 200 MHz (Efinix) | Dual-core Debian on the KV260, protocol ready for four |

Sources for the reference columns: [NaxRiscv performance docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html), [Luffca](https://www.luffca.com/2022/07/benchmark-rv64gc-riscv-ooo-simulator/), [VexiiRiscv performance docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html), [Andes AX45MP](https://www.andestech.com/en/products-solutions/andescore-processors/riscv-ax45mp/), [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf), [VexiiRiscv issue #1](https://github.com/SpinalHDL/VexiiRiscv/issues/1), [UG1629](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization), [NaxRiscv issue #89](https://github.com/SpinalHDL/NaxRiscv/issues/89), [riscv_sc_2024 slides](https://github.com/SpinalHDL/SpinalDoc/blob/master/presentation/en/riscv_sc_2024/riscv_sc_2024.odp). The targets are our recommendations.

The margins are deliberate. A bare win over NaxRiscv's 4.94 CoreMark/MHz is meaningless when an in-order dual-issue core scores 5.24. The SPEC-like target needs to exceed the roughly 15% gap separating NaxRiscv from VexiiRiscv on doom, or the out-of-order area buys nothing an in-order design could not.

**Measurement protocol.**
- Run NaxRiscv's RV64 build (with FPU) on the same KV260 SoC as a control. Its LiteX integration assumes DRAM attached to the programmable logic, so it needs the same PS-DDR AXI bridge as our core (our inference).
- Use one GCC version and one flag set for every core.
- Keep CoreMark's 2000-byte buffer, validation seeds and minimum 10-second runs, report the memory-to-core frequency ratio its rules require, and drop type redefinitions ([CoreMark README](https://github.com/eembc/coremark)).
- Build Dhrystone only under the ground rules (-fno-inline, separate compilation), and pin the Embench version.
- Report DRAM latency in both nanoseconds and core cycles from a pointer-chase test, and repeat runs with latency padded to ASIC-like values.
- Convert per-MHz scores to IPC explicitly. NaxRiscv's RV32 CoreMark implies about 255K dynamic instructions per iteration (1.28 × 10⁶ ÷ 5.02, our arithmetic), so different compilers or extensions change instruction counts as well as IPC.
- Report SMT throughput separately, declaring parallel contexts in CoreMark's "M" field. VeeR EH2's 6.3 CoreMark/MHz is a two-thread figure, not single-thread IPC ([CoreMark README](https://github.com/eembc/coremark)).

**Engineering discipline.**
- Write a calibrated performance model before the RTL.
- Synthesize a thread-ID-width-1 build early.
- Treat the 1-cycle ALU loop, back-to-back wakeup, the load-to-use loop and the next-PC loop as protected, since losing them cost 15%, 10% and up to 20% of IPC in the cited studies. Buy cycle time on rename, dispatch and commit first.
- Floorplan both cores from the beginning.

## Conclusion

The literature recasts the project's risk. Beating NaxRiscv's IPC is the easy half. Its author traded IPC for LUTs in specific, documented places, and each trade has a published fix already mapped to FPGAs. The hard half is beating it by enough to matter. The same author showed that an in-order dual-issue core gets within 0–17% of NaxRiscv for a fraction of the area, and Wong's results show that a lower clock can erase most of a per-clock gain: his core's 1.3–1.45× per-clock lead on CoreMark and Dhrystone shrank to about 1.1–1.2× at 0.8× the clock. The asymmetry is favorable, though. Most of the winning levers (predictor tables, larger L1s, an L2 TLB, an UltraRAM L2) spend BRAM and UltraRAM, which NaxRiscv leaves nearly idle at 12 BRAMs, while LUTs are the binding resource on the XCK26. The LUT-hungry structures (register file, schedulers, load/store queues) all have measured FPGA-native forms. A dual-core design at about 40K LUTs per core is therefore feasible, provided Fmax is defended loop by loop.

Two less obvious implications follow. First, on the KV260, measured IPC is partly a property of the platform. PS-DDR latency is short in core cycles, which flatters per-MHz scores and hides the value of memory-level parallelism, so the core must be judged with both real and padded latency, on identical binaries, against a NaxRiscv control on the same board. Second, the schedule risk sits in verification and threading discipline, not in microarchitectural novelty. Coherence and L2 bugs in XiangShan and NaxRiscv surfaced only after roughly 3 × 10⁹ and 3.6 × 10¹¹ cycles respectively, and SMT readiness is a matter of discipline that is nearly free at thread-ID width zero and expensive to retrofit. The A53 cluster beside the fabric is the project's most under-used asset: it can load the soft cores' software, host their virtio devices, and run a lockstep checker that consumes their commit trace at hardware speed.
