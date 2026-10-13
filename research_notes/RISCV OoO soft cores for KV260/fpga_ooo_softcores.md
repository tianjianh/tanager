# FPGA-oriented out-of-order and aggressive superscalar soft processors: whole-design results (2009-2026)

Scope note: whole-design surveys of OoO soft cores built for, or measured on, FPGAs. NaxRiscv/VexiiRiscv/VexRiscv, BOOM, XiangShan, C910, CVA6, Rocket, BlackParrot, CVA5/Taiga and biRISC-V are covered by other researchers. They appear here only where a covered paper used them as a comparison point. Every number is tagged with its year, device and configuration. The research date is 2026-10-12. The web-search budget for this session ran out near the end, so a few items are marked as unverified or listed under Gaps. The local text of the RSD, Wong, CFC, FPGA-Sim, AnyCore, RiscyOO, SCOoOTER and Gray/Smith PDFs was extracted and read directly.

## Q1. What each design is and what it achieved: ISA, microarchitecture, structure sizes, device, Fmax, resources, IPC, Linux, FPGA findings, pros/cons

### Takeaway
Only two designs were built for FPGA from the ground up and then measured whole against comparison cores on the same device: RSD and Henry Wong's x86 core. RSD (RV32IM, 2-wide, 2019) runs at 95.3 MHz on a Zynq-7020 -1, reaches 2.04 DMIPS/MHz, and uses about 15.4k LUTs without caches. Wong's x86 (2-wide, 2017) is projected at about 200 MHz and 28.7k ALMs on Stratix IV, for 2.2x the SPECint2000 wall-clock performance of Nios II/f.

ASIC-first OoO RTL is large on FPGAs and runs at only 25-50 MHz there. This covers RiscyOO/Toooba, FabScalar/AnyCore, VRoom! and RIDECORE. The closest analogue to a Linux-capable RV64 OoO core on UltraScale+ is the independent SmolRV64: 166.67 MHz on XCKU5P, 114k LUTs, boots Ubuntu. Its numbers are self-reported and change quickly.

### Cited Findings

#### Summary table (each value's source is given in the per-design bullets below)

| Design (year) | ISA | Front-end / issue | ROB / IQ / LSQ | FPGA device | Fmax | Area | Performance | Linux |
|---|---|---|---|---|---|---|---|---|
| RSD (FPT 2019) | RV32IM (README now RV32IMF) | 2-wide fetch/decode/rename; 5 issue ports (README now 6-wide issue) | 64 / 16 unified / 16 LDQ + 16 STQ | XC7Z020-CLG484-1 (Synplify) | 95.3 MHz | 15,379 LUT, 8,584 FF, 6 BRAM, caches excluded | 2.04 DMIPS/MHz, 194 DMIPS (HW divide) | No (Zephyr) |
| OPA (ORCONF 2015; measured by RSD 2019) | RV32IM without DIV/CSR (LM32 package also present) | 2-wide; 2 Int + 2 Ld/St/Mul ports | ROB = IQ = LDQ = 64; no store queue | XC7Z020-1 | 134 MHz | about 20k LUT (derived: RSD = 76% of OPA), no BRAM | 0.577 DMIPS/MHz, 77.5 DMIPS | No |
| BOOM RV32 config (as measured by RSD 2019, comparison only) | RV32IMAC | 2-wide; 3 Int + 1 Ld/St | 64 / 16+16 / 16+16 | XC7Z020-1 | 71.7 MHz | about 43k LUT (derived: RSD = 36% of BOOM) | 1.06 DMIPS/MHz, 76.1 DMIPS | n/a |
| Wong x86 (thesis 2017) | IA-32 (P6 target; x87 emulated by trap) | 2 x86 instructions = 2 uops/cycle; 4 exec units | 64 / 4 x 8 distributed / 16 LQ + 16 SQ | Stratix IV (40 nm) | about 200 MHz (estimated, memory-limited) | about 28,700 equivalent ALMs incl. 8 KB L1s + 256 KB L2 (projected) | SPECint2000: 0.66 x86-IPC, 2.73x Nios II/f per clock, 2.2x wall clock | Boots most 32-bit x86 OSes (cycle-level model) |
| RiscyOO-B (MICRO 2018) | RV64 (Linux-capable; Toooba = RV64GC) | 2-wide; 4 pipes (2 ALU, 1 MEM, 1 FP/MUL/DIV) | 64 / 16 per pipe / 24 LQ + 14 SQ + 4 SB | AWS F1 (VU9P) | 40 MHz single-core, 25 MHz quad-core | not reported | IPC about equal to BOOM (80-entry-ROB variant) | Yes |
| CHERI-Toooba (2026 paper using it) | RV64GC + CHERI | RiscyOO-derived | n/a | VCU118 | 25 MHz synthesis target | 261,552 LUT, 129,099 FF (2 cores + 1 MB LLC + tag controller) | n/a | CheriBSD |
| SmolRV64 (2026, independent) | RV64, RVA22 profile | README: 3-wide (repo tagline says 2-way) | 32-entry status-only ROB; 4 schedulers | XCKU5P | 166.67 MHz | 114,092 LUT, 53,029 FF, 169.5 BRAM, 28 DSP | Geekbench 5 single-core 14, suite IPC 1.02 | Yes (Ubuntu 25.04) |
| SoomRV (2023-, independent) | RV32IMAC+ with S-mode/VM | up to 4/cycle | sky130 build: 64 ROB; GF180 build: 2-wide, 32 ROB | Arty A7-100T | 41.67 MHz | "very close to LUT limit" | 5.42 CoreMark/MHz | Yes, on FPGA |
| VRoom! (2021-, independent) | RV64IMAFDCHBK(V) | up to 8 IPC peak; 2-way SMT | n/a | AWS F1, trimmed to fit | n/a | n/a | about 11.3 DMIPS/MHz (self-reported, work in progress) | Yes |
| RIDECORE (about 2015) | RV32 | n/a | n/a | VC707 (Virtex-7) | 50 MHz prototype | n/a | n/a | No |
| SCOoOTER (WCAE 2025) | RV32I[M][A] | configurable (largest built: dual-issue) | configurable (largest built: 32 ROB, 8-slot RS) | ASIC SKY130 (FPGA via TaPaSCo, no numbers) | 77-83 MHz (SKY130) | 1.32-1.43 mm^2 (SKY130) | competitive with CVA6 class (Embench) | NoMMU proof of concept |
| CFC renamer (FPL 2009) | Nios II, single-issue OoO | 1 | simulated: ROB 32, scheduler 32, 64 PRF | Stratix III / Cyclone II | renamer: 220 MHz (SIII, 8 checkpoints) | 996 LUT + 6 BRAM (renamer only) | simulated IPC 0.37 | uClinux (simulator) |

#### RSD (Univ. of Tokyo / Kyushu / Nagoya; FPT 2019; GitHub through 2023)
- The paper is "An Open Source FPGA-Optimized Out-of-Order RISC-V Soft Processor", ICFPT 2019, pp. 63-71. It was listed as a Best Paper Candidate — [Shioya publications](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/publications-e.html)
- **ISA, language and evaluated parameters (2019).** RV32IM in SystemVerilog. Fetch/decode/rename width 2. ROB 64, PRF 64, one unified IQ of 16, LDQ 16, STQ 16. Issue ports: 2 Int, 1 Ld, 1 St, 1 Mul/Div. Gshare plus RAS — [RSD paper, Tables I/III](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Later README.** The upstream README now lists RV32IMF, a 2-wide fetch front end, a 6-wide issue back end, and up to 64 in-flight instructions (configurable). It also lists a speculative scheduler with replay, speculative OoO loads/stores with dynamic disambiguation, a non-blocking L1D, AXI4, Zedboard support and Zephyr support. It has no Linux support and no Fmax or area table. Copyright is 2019-2023 under Apache-2.0 — [RSD GitHub](https://github.com/rsd-devel/rsd). Older forks describe "2-fetch, 5-issue" RV32IM — [mithro/rsd fork](https://github.com/mithro/rsd)
- **Device and tool.** All results are for Xilinx Zynq XC7Z020-CLG484-1 using Synplify Premier M-2017.03-SP1. L1I/L1D resources are excluded from the resource numbers. The performance comparison used 8 KB L1I, 8 KB L1D and a 1-cycle main memory — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Headline results (Table VII).**

  | Core | Fmax | DMIPS (HW div / SW div) | DMIPS/MHz (HW div / SW div) |
  |---|---|---|---|
  | RSD | 95.3 MHz | 194 / 177 | 2.04 / 1.86 |
  | OPA | 134 MHz | N/A / 77.5 | N/A / 0.577 |
  | BOOM (RV32 config) | 71.7 MHz | 76.1 / 74.5 | 1.06 / 1.03 |

  RSD used 88% of OPA's registers and 76% of its LUTs, and 40% of BOOM's registers and 36% of its LUTs — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Whole-core area with and without RAM-mapped multiport structures (Table VI).** FF+logic: 28,166 LUTs, 13,511 registers, 89.8 MHz. I-LVT plus banked RAM: 15,379 LUTs, 8,584 registers, 95.3 MHz. That is 45% fewer LUTs, 36% fewer registers and 6% higher Fmax — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **BRAM use.** RSD uses 6 BRAMs (2 for the memory dependence predictor, 4 for the branch predictor) out of 140 on the device. BOOM uses 3; OPA uses none — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Wakeup and select.** Wakeup uses a dependency-bit matrix with random select. A "wakeup allocation table" (a RAM) maps a logical source register to the IQ slot of its youngest older producer. A ready-bit table covers producers that have already issued, and a destination RAM maps an IQ slot back to its physical register — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Memory dependence predictor.** It is a 1-bit-per-entry table indexed by load PC and set on an ordering violation. A load predicted dependent waits in the IQ until all older stores have issued, enforced through the same matrix wakeup. Loads search the STQ for forwarding, and stores search the LDQ for violations, which triggers replay — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Pros:** the best published perf/LUT among the OoO soft cores, open source, and real speculative memory disambiguation. **Cons:** 32-bit only, no MMU or Linux, 95 MHz on a -1 7-series part, and a branch predictor and CAM store queue on the critical path — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf); [RSD GitHub](https://github.com/rsd-devel/rsd)
- **Follow-ups from the same group.**
  - "An Area-Efficient Out-of-Order Soft-Core Processor Without Register Renaming", FPT 2018, pp. 374-377 — [DBLP Kadomoto](https://dblp.uni-trier.de/pid/243/5225.html)
  - "A High-Performance Out-of-Order Soft Processor Without Register Renaming", FPL 2020, pp. 73-78 — [Shioya publications](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/publications-e.html)
  - The group's STRAIGHT ISA (MICRO 2018) names each source operand by its distance back to the producing instruction, which removes renaming entirely — [STRAIGHT MICRO'18](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Irie-MICRO%2718.pdf)

#### Henry Wong: superscalar OoO x86 soft processor (U. Toronto PhD 2017; FCCM 2016; TRETS 2016)
- **Headline.** The 2017 thesis designs a two-issue OoO x86 soft core. It reaches 2.7x the per-clock performance of a performance-tuned Nios II/f at 0.8x the frequency, for a 2.2x total speedup. It is projected at about 28,700 Stratix IV ALMs, 6.5x Nios II/f — [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) (mirror: [stuffedcow.net](https://www.stuffedcow.net/files/henry-thesis-phd.pdf))
- **Completeness caveat.** The design is complete enough to boot most unmodified 32-bit x86 OSes in its cycle-level model. Not every unit has a circuit: branch prediction, ROB/commit and microcode area are estimates, and decode is only partially implemented (Table 13.5) — [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **Baseline configuration (Table 12.2).**
  - Front end: 8 B/cycle fetch; 16K-entry BTB; 16-entry RAS; decode of 2 x86 instructions and 2 uops per cycle.
  - Rename: integer, segment and flag registers renamed at 2 ops/cycle.
  - Back end: 64-entry ROB; an 8-entry scheduler per execution unit; units are 1 branch/complex, 1 ALU, 1 AGU and 1 store-data; 16-entry SQ and 16-entry LQ.
  - L1: L1I 2-way 8 KB blocking. L1D 2-way 8 KB write-back, 3-cycle, 4 MSHRs.
  - TLBs: ITLB and DTLB both 2-way, 128 entries; the DTLB allows 2 outstanding page walks.
  - L2 and memory: L2 4-way 256 KB, 9-cycle, 8 outstanding misses; 30-cycle memory.
  - Source — [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **Clustered PRF.** Each cluster has its own register file and can only write locally but can read every cluster. This gives three 7-read/1-write register files with no LVT, because the renamer steers each destination to the producing cluster — [Wong thesis, Sec. 5.1](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **Per-unit area and Fmax on Stratix IV (Table 13.5).**

  | Unit | Area (equiv. ALMs) | Fmax | Status |
  |---|---|---|---|
  | Decode | 4,300 (estimate 5,000) | 247 MHz | partial |
  | Rename | 1,900 | 317 MHz | complete |
  | Scheduler | 3,800 (estimate 4,000) | 275 MHz | complete |
  | Register file | 2,400 | 260 MHz | complete |
  | Execution | 2,300 | 240 MHz | complete |
  | Memory system logic | 9,000 | 200 MHz | complete |
  | L1/L2 cache RAM | 5,000 | — | — |
  | Branch prediction | about 1,000 | — | estimate, no circuit |
  | ROB + commit | about 2,000 | — | estimate, no circuit |
  | Microcode | about 500 | — | estimate, no circuit |

  The core is estimated at about 200 MHz, set by the memory system; the next slowest unit is 240 MHz — [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **Per-clock performance (Table 13.4).** Values are x86 instructions per clock for Nios II/f vs. this design (multiplier in brackets):
  - Dhrystone: 0.78 vs 1.13 (1.45x)
  - CoreMark: 0.77 vs 1.02 (1.32x)
  - SPECint2000 geomean: 0.24 vs 0.66 (2.73x)
  - MiBench: 0.47 vs 1.06 (2.25x)
  - Stanford: 0.54 vs 1.00 (1.83x)
  - Haswell, for reference: 3.07 on Dhrystone and 1.49 on SPECint2000
  - Source — [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **Wall clock and context (Table 13.7).** Nios II/f is 4,400 ALMs at 245 MHz, at 0.37 relative perf/clock and 0.45 relative SPECint2000 performance. The design's per-clock sits between the Pentium Pro and Atom Silvermont, and above the hard Cortex-A9. The A9 is still 2.8x faster in wall clock thanks to its 800 MHz — [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **System-level area.** In a minimal Linux-capable Nios II/f system (DDR3 controller plus Qsys), the CPU is about one third of the system. Swapping in the 6.5x-larger OoO core grows the whole system only 2.9x — [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **Memory system.**
  - Non-blocking OoO memory raised SPECint2000 IPC 1.32x over a blocking cache, and an L2 added another 1.60x.
  - The TLB+cache lookup path is 4.29 ns, against 6.0 ns for Nios II/f.
  - Memory-system area is 9,080 ALMs + 39 M9K + 14 M144K, about 13,937 equivalent ALMs.
  - Of that, L1 memory execution is 4,462 ALMs: 16-entry SQ 1,113; 16-entry LQ 528; 8-entry replay scheduler 375; D-cache 1,513.
  - Sources — [Wong thesis Ch. 12](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf); journal version: [TRETS 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongtrets16.pdf)
- **Pros:** the most complete FPGA-first OoO study, with a real OS-capable ISA and circuit-level data for every block. **Cons:** a projected rather than fully built core; Stratix IV only; relies on 7-input ALM functions (Xilinx 6-LUTs would need redesign); one simple ALU limits Dhrystone/CoreMark; x87 emulated in software — [Wong thesis Ch. 14](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

#### Kaveh Aasaraai and Andreas Moshovos (U. Toronto; FPL 2009, FPT 2010, SPREX/NCOR 2012, thesis)
- **CFC (FPL 2009).** Copy-Free Checkpointing is an FPGA-friendly renamer for a single-issue OoO Nios II core. Compared with the best conventional renamer it needs 7.5x-6.4x fewer LUTs and is at least 10% faster — [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- **CFC mechanism.**
  - Instead of copying the whole map table at each checkpoint, CFC keeps C+1 BRAM map tables managed as a circular queue: C checkpoint tables plus one committed table.
  - Each new epoch writes only its own table. A LUT-based "dirty flag" array records which table holds the newest mapping for each architectural register.
  - Recovery simply discards the tables after the restored one.
  - The tables are flattened into one BRAM so only single-write-port BRAMs are needed, and replicated three times for the three read ports.
  - Rename is pipelined over 2 stages.
  - Source — [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- **Results, 4 checkpoints (LUTs @ MHz).**

  | Device | CFC | RAT-CAM | RAT-RAM |
  |---|---|---|---|
  | Stratix III | 399 @ 292 | 1,802 @ 133 | 3,002 @ 195 |
  | Cyclone II | 501 @ 137 | 2,378 @ 85 | 3,220 @ 122 |

  Source — [CFC paper Table 2](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- **Results, 8 checkpoints on Stratix III.**

  | Renamer | LUTs | BRAMs | Fmax | Avg IPC | Runtime |
  |---|---|---|---|---|---|
  | CFC | 996 | 6 | 220 MHz | 0.37 | 12.76 s |
  | RAT-RAM | 7,082 | 0 | 196 MHz | 0.38 | 14.16 s |
  | RAT-CAM | 2,327 | 0 | 105 MHz | 0.38 | 26.44 s |

  The extra rename stage costs negligible IPC — [CFC paper Tables 3-4](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- **Simulated core and the case for 1-wide OoO.**
  - Simulated core: 7-stage single-issue OoO with scheduler 32, ROB 32, 64 physical registers, 4 checkpoints, 512-entry bimodal predictor and BTB, 4-32 KB caches and a 20-cycle memory, running SPEC CPU2006 under uClinux in a full-system Nios II simulator.
  - On Stratix III, a 4-way 5-stage datapath with full bypass has 33% lower Fmax than a 1-way datapath.
  - 1-wide OoO beat 1- and 2-way in-order superscalars on IPC at every cache size, and beat 4-way everywhere except at 32 KB.
  - Source — [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- **FPT 2010 scheduler design-space exploration.** This covers single-issue, compacting, age-priority CAM schedulers on Stratix III. It recommended a 4-entry scheduler because IPC changed by less than 10% between 2 and 32 entries. Wong's CAM circuit was 40% faster at 16 entries on the same Stratix III (matrix +47%, fused-logic +60%). Wong also found that dual issue needs much larger schedulers — [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf); [Wong thesis Sec. 9.8](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **SPREX** is a runahead soft core combining CFC with NCOR. The thesis reports up to 38% higher performance than Nios II on applications with irregular data-level parallelism, at minimal area overhead — [Aasaraai thesis record](https://utoronto.scholaris.ca/items/5f3d7bbf-6ba4-42b9-8f6f-17ceec607184). An earlier 2012 report gives +9% on average and up to +36% over a simple 5-stage pipeline (via search abstract) — [SPREX seminar](https://www.eecg.utoronto.ca/~jayar/FPGAseminar/2012/sprex-a-soft-processor-with.html)
- **NCOR** is a CAM-free non-blocking data cache built around runahead execution. A 4 KB NCOR runs at 329 MHz in 270 LEs, and 32 KB at 278 MHz in 269 LEs, on Stratix III (from the journal abstract via search) — [NCOR, IJRC 2012](https://api.crossref.org/works/10.1155%2F2012%2F915178)
- **Pros:** shows that renaming and checkpointing can live almost entirely in BRAM at high Fmax, and runahead gives memory-level parallelism cheaply. **Cons:** single-issue only; never built as a full OoO core with full-system silicon results (simulator-based IPC) — [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)

#### AnyCore / FabScalar (NCSU, Rotenberg et al.)
- FabScalar (ISCA 2011) generates synthesizable RTL for arbitrary superscalar cores inside a canonical template — [RSD paper reference list](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **FPGA-Sim (ISPASS 2012)** maps FabScalar cores to FPGA, but as a simulation accelerator, not a soft core.
  - Platform: BEE3 with four Virtex-5 LX155T FPGAs and a 50 MHz core clock.
  - Multiported RAMs and CAMs are time-multiplexed over several FPGA cycles per model cycle. Effective peak speed falls from 16.7 MHz (3 FPGA cycles per model cycle) to 4.5 MHz (11 cycles).
  - Measured speed: bzip reached 15.1/4.4 MHz and parser 5.8/3.1 MHz.
  - It averages 87x faster than the C++ simulator.
  - Source — [FPGA-Sim](https://ericrotenberg.wordpress.ncsu.edu/files/2025/06/paper_ISPASS-2012.pdf)
- **FPGA-Sim resource findings.**
  - A naively synthesized 2-way core with 64 physical registers and a 16-entry IQ ran out of resources on that Virtex-5.
  - A 4-read/2-write 32x32 register file took 373 LUTs and 94 slices in LUTRAM (8 replicas), against 1,882 LUTs, 1,024 FFs and 472 slices in flip-flops.
  - CAMs were emulated with a value RAM plus a transposed "match-vector" RAM.
  - Source — [FPGA-Sim](https://ericrotenberg.wordpress.ncsu.edu/files/2025/06/paper_ISPASS-2012.pdf)
- **AnyCore** (ISPASS 2016) is an adaptive superscalar RTL model aimed at fabrication. Its FPGA (ML605) appears only as the chip tester, and no soft-core FPGA Fmax or area is reported — [AnyCore ISPASS 2016](https://ericrotenberg.wordpress.ncsu.edu/files/2025/06/paper_ISPASS-2016.pdf). AnyCore-1 is a "comprehensively adaptive 4-way superscalar" chip — [Hot Chips 28 poster](https://old.hotchips.org/wp-content/uploads/hc_archives/hc28/HC28.24-Posters-Epub/HC28.24.120-74_Anycore-1%20Poster.pdf); [AnyCore page](https://ericrotenberg.wordpress.ncsu.edu/anycore)
- The 2015 FabScalar-RISC-V talk lists porting FabFPGA to RISC-V and adding the privileged ISA for Linux as future work — [RISC-V workshop 2015 slides](https://ericrotenberg.wordpress.ncsu.edu/files/2022/08/workshop_RISCV-2015.pdf)
- **Pros:** parameterizable and verified, a superb design-space tool. **Cons:** an ASIC-style multiported design that cannot be a practical soft core without FPGA-specific restructuring.

#### RiscyOO (MIT, MICRO 2018) and Bluespec Toooba / CHERI-Toooba
- **Background.** RiscyOO is built with Composable Modular Design (Bluespec SystemVerilog modules with guarded methods and atomic rules). It boots Linux and runs on FPGAs at 25-40 MHz; 32 nm ASIC synthesis gives 1.0-1.1 GHz — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf)
- **RiscyOO-B configuration.**
  - Front end: 2-wide fetch/decode/rename; 256-entry direct-mapped BTB; 21264-style tournament predictor; 8-entry RAS.
  - Back end: 64-entry ROB with 2-way insert/commit; 4 pipelines (2 ALU, 1 MEM, 1 FP/MUL/DIV), each with a 16-entry IQ.
  - Load/store: 24-entry LQ, 14-entry SQ, 4-entry store buffer.
  - TLBs: L1 TLBs 32-entry fully associative; L2 TLB 2,048-entry 4-way.
  - Caches: 32 KB 8-way L1s; 1 MB 16-way L2.
  - Memory: 120-cycle latency, modelling a 2 GHz clock.
  - Source — [RiscyOO paper Fig. 12](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf)
- **Platform.** AWS F1 at 40 MHz for single-core SPEC CINT2006 ref runs (64 billion to 2.7 trillion instructions) under Linux. A quad-core TSO/WMM build with 48-entry ROBs ran PARSEC at 25 MHz. FPGA resource usage is not reported — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf)
- **Results.**
  - Non-blocking TLBs plus a page-walk translation cache (T+) gave +29% on SPECint2006 on average and 2x on astar.
  - T+ beat in-order Rocket by 53% (10-cycle memory) and 319% (120-cycle memory).
  - Cortex-A57 and Denver were 34% and 45% faster than T+.
  - With an 80-entry ROB, RiscyOO matched BOOM's IPC overall (mcf 0.16 vs 0.10; sjeng 0.73 vs 1.05).
  - 32 nm synthesis: 1.1 GHz / 1.78M NAND2-equivalent gates (T+) and 1.0 GHz / 1.89M (80-entry ROB).
  - Source — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf)
- **Toooba** is a slight variation on RISCY-OOO: RV64ACDFIMSU (RV64GC), adds C, tandem verification and a debug module, passes the ISA tests, boots Linux, and is tested on Xilinx FPGAs. No Fmax or area is published — [Toooba GitHub](https://github.com/bluespec/Toooba). Cambridge describes RiscyOO/Toooba as a parameterisable superscalar OoO core — [Cambridge projects](https://www.cst.cam.ac.uk/research/comparch/student-projects)
- **CHERI-Toooba, as used in a 2026 temporal-safety paper.** A 2-core system on VCU118 at 25 MHz (Vivado 2019), with 32 KB 8-way L1D and a shared 16-way 1 MB LLC plus tag controller. The baseline uses 261,552 LUTs of logic, 129,099 registers and 5,343 LUTs of LUTRAM — [arXiv 2609.11590](https://arxiv.org/html/2609.11590v1)
- **Pros:** a full RV64 Linux OoO core, multicore with TSO/WMM, and fast design iteration (the TLB changes took two weeks). **Cons:** an ASIC-style microarchitecture compiled from BSV, so FPGA clocks are 25-40 MHz and area is very large; useless as a direct KV260 template — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf); [arXiv 2609.11590](https://arxiv.org/html/2609.11590v1)

#### OPA: Open Processor Architecture (Wesley Terpstra, GSI; ORCONF 2015)
- **Repository.** VHDL, GPL-3.0. It has issue, rename, prefix-sum, register-file and predictor modules, Altera LUT/DPRAM primitives, and ISA packages for both LM32 and RISC-V — [OPA GitHub](https://github.com/terpstra/opa)
- **As evaluated by RSD (2019).**
  - ISA: RV32IM without divide/CSR.
  - Window: 2-wide; ROB, IQ and LDQ all 64, because they cannot be sized separately; PRF 98.
  - No store queue: stores execute only at the ROB head, and loads cannot forward from stores.
  - Prediction: loop predictor plus RAS only, with no direction predictor.
  - Issue ports: 2 Int + 2 Ld/St/Mul.
  - Scheduling: IQ-based speculative scheduling merged into the ROB.
  - Results: 134 MHz on XC7Z020-1, no BRAM, 0.577 DMIPS/MHz.
  - Source — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Effect of having no store queue.** RSD's simulator study found that removing the store queue costs up to 40% IPC (16% on average) on SPECint 2006/2017 — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Scheduler comparison.** On Arria V, Wong's fused-logic matrix scheduler alone clocks about 30% higher than the complete OPA at 18 and 27 entries. A merged ROB/scheduler wastes capacity, since schedulers need only 30-50% of the ROB size — [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)
- **Pros:** high Fmax and small logic depth. **Cons:** IPC collapses without a store queue or direction predictor, and it is the textbook case for co-optimizing Fmax and IPC.

#### SCOoOTER (TU Darmstadt; WCAE 2025)
- **Design.** Bluespec SystemVerilog, RV32I[M][A], Tomasulo-style. Instructions are tagged by ROB slot; a speculative register file tracks pending writes; reservation stations per unit latch operands from a broadcast result bus. ROB/RS sizes, unit mix and issue width are configurable. CSR and load/store units wait until the instruction reaches the ROB head, so there is no speculative memory — [SCOoOTER paper](https://www.esa.informatik.tu-darmstadt.de/assets/publications/materials/2025/2025_WCAE_MS.pdf)
- **Multithreading.** Fetch alternates between per-thread PCs. Instructions carry a thread ID, and each hart replicates its architectural register file, CSRs and speculative registers. Multi-core memory goes through a shared arbiter that serializes accesses and holds the LR/SC reservation — [SCOoOTER paper](https://www.esa.informatik.tu-darmstadt.de/assets/publications/materials/2025/2025_WCAE_MS.pdf)
- **Results (ASIC only).** Core-only on SKY130 with OpenLane:

  | Configuration | Area | Fmax |
  |---|---|---|
  | SCOoOTER 60X | 1,322,280 um^2 | 83 MHz |
  | SCOoOTER 65X | 1,432,540 um^2 | 77 MHz |
  | CVA6 CV32A60X | 887,526 um^2 | 56 MHz |
  | CVA6 CV32A65X | 946,298 um^2 | 53 MHz |

  The largest Caravel build is dual-issue with a 32-entry ROB and 8-slot RSs. There are no caches (direct memory access), and Linux exists only as a NoMMU student proof of concept. FPGA builds go through TaPaSCo, but no FPGA numbers are reported — [SCOoOTER paper](https://www.esa.informatik.tu-darmstadt.de/assets/publications/materials/2025/2025_WCAE_MS.pdf); [SCOoOTER GitHub](https://github.com/esa-tu-darmstadt/SCOoOTER)

#### Proteus (KU Leuven; RISC-V Summit Europe 2023)
- SpinalHDL, RV32IM plus machine mode, built on a plugin system. It can be configured as a classic 5-stage pipeline or as a superscalar OoO core with configurable ROB entries and execution units ("-O" releases since 23.02). It underpins security research (ProSpeCT, AMI, Libra). The README gives no Fmax, area, IPC or Linux data; its only example FPGA part is xc7a50ticsg324-1L — [Proteus GitHub](https://github.com/proteus-core/proteus)

#### Independent and open-source OoO cores 2015-2026
- **SmolRV64 (Tommy Thorn; README as of 2026-10).**
  - ISA and memory model: Verilog, written from scratch, RV64 (RVA22 profile, Sv39), 36-bit physical addresses.
  - Front end: one 16-byte fetch per cycle. An aligner emits up to 3 RVC or 32-bit instructions per cycle into an 8-entry queue. A 2,048-entry BTB and 2,048-entry YAGS predictor sit in 8 BRAM banks, with 11-bit global history and an 8-entry RAS.
  - Dispatch, retire and ROB: 3-wide dispatch and retire. The 32-entry ROB holds 17 status bits per entry only, and stores commit early via a second pointer.
  - Register file and rename: a unified PRF split into 4 shards with one write port each, organized by writer; one-cycle rename recovery.
  - Scheduling: 4 schedulers (2 integer, 1 in-order memory, 1 FP/branch/MUL/DIV) with fixed-priority select and wake-at-select, and no age matrix.
  - Memory: loads wait only on possibly-aliasing older stores; up to 8 loads in flight. 128 KiB 2-way VIVT I$ and 128 KiB 2-way non-blocking D$ with 8 MSHRs; 2,048-entry direct-mapped dTLB; CVFPU.
  - Implementation: XCKU5P with Vivado 2025.1 at 166.67 MHz, using 114,092 LUTs (53%), 53,029 FFs, 169.5 BRAM tiles and 28 DSPs.
  - Results: Geekbench 5 single-core 14, with an IPC of 1.02 over the suite; sha256sum IPC 1.56-1.63. Ubuntu 25.04 boots via OpenSBI and mainline Linux.
  - Verification: lockstep co-simulation against an ISA model.
  - The repo tagline still says "2-way ... scores 5 in Geekbench 5", which conflicts with the README body — [SmolRV64 GitHub](https://github.com/tommythorn/smolrv64)
- **SoomRV (mathis-s).**
  - Design: SystemVerilog, RV32IMAC+ with M/S/U modes and virtual memory, boots Linux. Up to 4 instructions per cycle; tag-indexed register file; TAGE; 2 loads per cycle; VIPT cache.
  - Performance: 5.42 CoreMark/MHz, and 4.0-11.8 DMIPS/MHz depending on compiler flags — [SoomRV GitHub](https://github.com/mathis-s/SoomRV)
  - FPGA: Arty A7-100T at 41.67 MHz, "very close to the LUT limit", booting Linux from a ramfs — [SoomRV-Arty](https://github.com/mathis-s/SoomRV-Arty)
  - ASIC builds: the GF180 build is 2-wide with a 32-entry ROB and 2 KiB caches — [SoomRV-GF180](https://repositories.efabless.com/mathis/SoomRV-GF180MCU). The sky130 build is 4-wide with 64 registers, a 64-entry ROB and 4 KiB caches — [sky130 shuttle](https://foss-eda-tools.googlesource.com/third_party/shuttle/sky130/mpw-007/slot-018/+/6774e665e8059df37f5c31f35ad7b445973a21dc)
- **VRoom! (Paul Campbell, Moonbase Otago).**
  - Design: SystemVerilog, RV64IMAFDCHBK(V), OoO, 2-way SMT, multi-core, aimed at server-class ASICs. Peak 8 IPC. About 11.3 DMIPS/MHz, self-reported as work in progress. Boots Linux on an AWS FPGA instance — [VRoom! GitHub](https://github.com/MoonbaseOtago/vroom)
  - The Linux FPGA build had to be trimmed to fit a VU9P — [Hackaday](https://hackaday.com/tag/system-verilog/)
  - Earlier figures conflict: about 2 DMIPS/MHz in 2021 — [BeagleBoard forum](https://forum.beagleboard.org/t/vroom-high-end-risc-v-implementation/30908) — and 6.5 DMIPS/MHz — [Hackaday](https://hackaday.com/tag/system-verilog/)
- **RIDECORE.** Verilog OoO RISC-V following Shen and Lipasti's textbook, with some modules from vscale. The prototype runs on a VC707 (Virtex-7) at 50 MHz with Vivado 2015.2 — [RIDECORE GitHub](https://github.com/ridecore/ridecore)
- **EDGE soft processor (Jan Gray and Aaron Smith; MSR TR written 2014, released 2018).**
  - Argument: prior OoO superscalar soft cores lacked competitive area or absolute performance. An EDGE ISA encodes dataflow explicitly, removing rename and CAMs.
  - 32-entry dataflow schedulers on a Kintex-7 -1 (LUTs, period, period when pipelined):

    | Scheduler | Core LUTs | Total LUTs | Period | Pipelined |
    |---|---|---|---|---|
    | Parallel | 288 | 340 | 5.0 ns | 2.9 ns |
    | Incremental | 78 | 150 | 4.3 ns | 2.5 ns |

  - Interconnect was 85% and 70% of the two critical paths. Pipelining the scheduler loses back-to-back issue of dependent instructions.
  - Source — [Gray & Smith](https://arxiv.org/pdf/1803.06617)
- **Morpheo / Rosiere et al. (DATE 2012).**
  - RSD summarizes it as a banked ROB using 2-port RAMs, with a queue to absorb bank conflicts, costing up to 10% IPC — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf); original: [Rosiere DATE 2012](https://past.date-conference.com/date16/files/proceedings/2012/pdffiles/12.5_2.pdf)
  - Wong describes the combined ROB/scheduler as unbalanced: a 128-512-entry ROB with only the oldest 4-16 instructions schedulable. On Virtex-5 it is 4.7x slower than his fused-logic matrix at 16 entries — [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)

#### In-order reference points reported alongside these designs
- **Nios II/f (Wong, Stratix IV).** 4,400 equivalent ALMs at 245 MHz, configured with 32 KB caches, MMU, a 256-entry dynamic branch predictor and a radix-2 divider — [Wong thesis Table 13.6/13.7](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **MicroBlaze Fmax (UG984).** Maximum frequencies at each family's fastest speed grade: Zynq UltraScale+ 661 MHz, Kintex UltraScale+ 650 MHz, Zynq-7000 265 MHz — [AMD UG984](https://docs.amd.com/r/en-US/ug984-vivado-microblaze-ref/Maximum-Frequencies)
- **MicroBlaze presets (Vivado 2023.2, -3 parts).** Microcontroller is 1.09 DMIPS/MHz; Real-Time and Applications (MMU) are 1.38. On Zynq UltraScale+ MPSoC: Microcontroller 518 MHz / 565 DMIPS, Real-Time 365 MHz / 504 DMIPS, Applications 334 MHz / 461 DMIPS. This is from a search summary of the AMD page, which timed out on direct fetch — [AMD MicroBlaze page](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/microblaze.html)

### Inferences
- **Two design styles.** "FPGA-first" OoO (RSD, Wong, SmolRV64, CFC) reaches 95-200+ MHz with 15-115k LUT-class budgets. "ASIC-first" OoO compiled to FPGA (RiscyOO/Toooba, FabScalar, VRoom!, BOOM) runs at 25-72 MHz and uses several times the LUTs. The difference comes from RAM-mapping multiported structures and from circuit-level attention to the scheduler and memory loops.
- **Derived perf/LUT on XC7Z020-1** (core only, no caches; OPA/BOOM LUT counts back-computed from RSD's percentages):

  | Core | DMIPS/kLUT |
  |---|---|
  | RSD | about 12.6 |
  | OPA | about 3.8 |
  | BOOM (RV32 config) | about 1.8 |

  So RSD is roughly 3x OPA and 7x BOOM.
- **SmolRV64 as the KV260 analogue.** It is the closest public analogue to the user's goal (RV64, Linux, UltraScale+, 2-3 wide). Its 114k LUTs on KU5P suggest that a dual-core Linux OoO RV64 on a part the size of XCK26 would need well under 60k LUTs per core. That implies a leaner configuration than SmolRV64 (smaller caches/TLBs, narrower width). The XCK26 LUT budget was not verified here; see Gaps.

### Gaps
- RSD follow-ups without renaming (FPT 2018, FPL 2020): abstracts, Fmax and area were not retrievable; the PDFs were not found at guessed URLs and DBLP was bot-blocked.
- No published FPGA resource numbers for RiscyOO or Toooba single cores; no OPA self-reported Fmax/area (the ORCONF 2015 talk was not found); no Proteus-O Fmax/IPC; no SCOoOTER FPGA numbers; no VRoom! or RIDECORE area.
- AnyCore: no FPGA soft-core implementation results exist in the sources found; only FabScalar's FPGA-Sim simulation-acceleration numbers.
- The details of Aasaraai's FPT 2010 scheduler paper (exact Fmax/area per size) come only via Wong's summary. The ReConFig 2014 paper "What limits the operating frequency of a soft processor design" and the FCCM 2014 paper were not retrieved — [Aasaraai DBLP](https://dblp.dagstuhl.de/pid/95/1849.html)
- The MicroBlaze per-preset DMIPS table could not be opened directly (the page timed out); it comes from a search summary.

## Q2. Which structures limited Fmax or dominated area in each design?

### Takeaway
Fmax was most often set by memory-side loops: the store-queue CAM, cache/TLB/L2 access, and the branch predictor. Area was dominated by multiported state built from flip-flops (PRF, map tables, ROB, IQ payload), by dependency-matrix wakeup, and by the memory system. The wakeup-select loop was rarely the global limiter once it was designed carefully, but it caps IQ size.

### Cited Findings
- **RSD (XC7Z020-1, 2019).**
  - The critical path of every full-core configuration is the branch predictor, which pins all six speculative-scheduling variants near 95 MHz. Relative to OPA, the CAM-based STQ and the global predictor are named as RSD's critical paths — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
  - The scheduler circuit alone is limited by the select-wakeup loop: 128-107 MHz (IQ-based replay) and 124-106 MHz (RQ-based) from 16 to 32 entries — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
  - In the scheduler's area, the dependency-bit-matrix wakeup logic is the largest contributor; IQ-based replay doubles it with shadow copies — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
  - Building multiported components from FFs and logic accounted for about half of the core's LUTs: 28,166 down to 15,379 when RAM-mapped. Open-source OoO cores including OPA and BOOM implement most of these structures that way — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **BOOM (as measured by RSD, XC7Z020-1).** The critical path is also the global branch predictor (71.7 MHz). Every predicted-taken branch inserts a one-cycle fetch bubble, which hurts DMIPS/MHz — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **OPA.** Its higher Fmax (134 MHz) comes from eliminating the STQ and using a trivial predictor, which leaves few timing-critical components — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Wong x86 (Stratix IV, 2017).**
  - The memory system limits the core to about 200 MHz, with coherence and L2 most critical; the L2 data array in M144K has long routes. Removing L2 raises Fmax only 7% because the L1 load stage is nearly critical. Every other unit is at least 240 MHz — [Wong thesis Sec. 12.9.2, 13.4.2](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
  - The memory system is the largest block: about 13.9k of 28.7k equivalent ALMs including the L2 RAM. Within L1 memory execution, the associatively searched store queue, the load queue and the replay scheduler are about half the area (16-entry SQ: 1,113 ALMs) — [Wong thesis Table 12.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
  - A CAM-based LSQ at 64+64 entries costs 7,715 equivalent ALUTs and limits Fmax to 186 MHz. NoSQ costs 3,356 at 328 MHz and SQIP 4,568 at 324 MHz. All are measured on OS-boot workloads — [Wong thesis Table 11.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
  - In the matrix scheduler, the preprocessing that maps source registers to producer entries is about 60% of scheduler area. Multi-issue distributed schedulers at 16-32 entries cost 1,750-3,750 ALMs at 325-280 MHz — [Wong thesis Sec. 9.7](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
  - Computing condition codes was a particular delay problem in the ALUs; x86-specific — [Wong thesis Ch. 14](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **Aasaraai and Moshovos (Stratix III / Cyclone II, 2009).**
  - A CAM-style rename table is the slowest renamer (105-133 MHz on Stratix III) and a RAM-style one the largest (3,002-7,082 LUTs) — [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
  - Bypass and datapath replication for 4-way superscalar cost 33% Fmax against 1-way — [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- **FabScalar on Virtex-5 (2012).** Flip-flop-based multiported register files use 5x the LUTs and slices of LUTRAM-based ones, and a naive 2-way core did not fit an LX155T — [FPGA-Sim](https://ericrotenberg.wordpress.ncsu.edu/files/2025/06/paper_ISPASS-2012.pdf)
- **EDGE scheduler (Kintex-7 -1).** In the wakeup-select critical path, interconnect is 70-85% of delay, because every ready bit must reach every other through a large netlist — [Gray & Smith](https://arxiv.org/pdf/1803.06617)
- **ASIC-first cores.** RiscyOO ran at 40 MHz single-core and 25 MHz quad-core on VU9P — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf). The CHERI-Toooba 2-core system on VCU118 is about 261.5k LUTs at a 25 MHz target — [arXiv 2609.11590](https://arxiv.org/html/2609.11590v1). FPGA-synthesized Intel cores: Atom Bonnell 176k 6-LUTs at 50 MHz and Pentium 66k 4-LUTs at 25 MHz — [Wong thesis Table 13.7](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **SmolRV64 (XCKU5P).** It sits at 6.0 ns (166.67 MHz), and 250 MHz is listed as an open question. Write ports came from sharding the PRF by writer, since duplication only adds read ports. Vivado can silently fold a RAM read port to zero in a netlist that passes RTL simulation, so the project added netlist and RAM-inference checks — [SmolRV64 GitHub](https://github.com/tommythorn/smolrv64)

### Inferences
- For a 2-wide RV64 OoO on UltraScale+, the likely Fmax limiters, in rough order of evidence:
  1. L1D/TLB/store-forwarding access path (Wong, RSD).
  2. Branch predictor and next-PC loop (RSD, BOOM).
  3. Store-queue CAM search if fully associative (RSD, Wong Table 11.3).
  4. Wakeup-select loop only if the IQ grows beyond roughly 16-24 entries per scheduler (Wong, RSD).
- Area will be dominated by the memory system (L1D with replicated tags, LSQ, TLB/PTW) and any multiported state left in FFs. RAM-mapping ROB, map tables, IQ payload and PRF is the largest single area lever measured (about -45% LUTs on RSD).

### Gaps
- No design reported a structure-by-structure LUT breakdown on an UltraScale+ device. RSD's breakdown figure (Fig. 6) is graphical and its per-stage values were not extractable.
- SmolRV64 publishes no per-module utilization or critical-path report.

## Q3. Did OoO beat in-order soft cores, in absolute performance and per LUT? What IQ/ROB sizes and widths were sweet spots?

### Takeaway
OoO wins in absolute single-thread performance only when Fmax stays within about 20% of the in-order core. Wong's x86 got 2.2x Nios II/f on SPECint2000 at 0.8x Fmax. On small, cache-resident benchmarks (Dhrystone, CoreMark) the gain shrinks to about 1.1-1.2x in wall clock. Per LUT/ALM, OoO loses (6.5x area for 1.1-2.2x performance), although the system-level cost is much smaller (2.9x).

Consistent sweet spots:
- 2-wide rename/dispatch.
- About 64-entry ROB (32 is workable with status-only entries).
- 16-32 total scheduler entries for 2-issue, distributed per pipe, at roughly 30-50% of the ROB.
- 16+16 LSQ.
- A non-blocking L1 plus L2 and good TLBs under Linux.

### Cited Findings
- **Wong vs Nios II/f (Stratix IV).**
  - Per clock: 2.73x on SPECint2000, 2.25x MiBench, 1.83x Stanford, 1.45x Dhrystone, 1.32x CoreMark.
  - Wall clock: 2.2x on SPECint2000 at 200 vs 245 MHz.
  - Area: 6.5x for the processor alone, 2.9x for a minimal Linux system — [Wong thesis Tables 13.4, 13.7, Sec. 13.4.1](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- Wong's per-clock gains are smaller on Dhrystone and CoreMark, possibly because the design has only one simple-arithmetic ALU — [Wong thesis Sec. 13.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **RiscyOO vs Rocket (per cycle, FPGA-hosted with modelled memory).**
  - Against 120-cycle memory: +319% (RiscyOO-T+) and +196% (smaller-cache RiscyOO-C-).
  - Against 10-cycle memory: +53% and +8% — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf)
- **1-wide OoO (simulated, Stratix III datapath data).** It beats 1- and 2-way in-order superscalar IPC at every cache size and 4-way except with 32 KB caches. A 4-way datapath loses 33% Fmax — [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- **Runahead instead of full OoO.** SPREX is up to 38% faster than Nios II on irregular-DLP applications at minimal area — [Aasaraai thesis record](https://utoronto.scholaris.ca/items/5f3d7bbf-6ba4-42b9-8f6f-17ceec607184). An earlier report gives +9% average, up to +36%, over a 5-stage pipeline — [SPREX seminar](https://www.eecg.utoronto.ca/~jayar/FPGAseminar/2012/sprex-a-soft-processor-with.html)
- Gray and Smith judged that prior OoO superscalar soft cores had not shown competitive area or absolute performance against in-order RISC soft cores — [Gray & Smith](https://arxiv.org/pdf/1803.06617)
- **IQ sizing (Wong, 2-issue).**
  - Schedulers above 32-40 entries are wasteful, and those much below 16 lose significant IPC.
  - MIPS peaks at 20 entries (275 MIPS) and varies little between 14 and 33. A 17-entry scheduler gives 0.83 IPC at 324 MHz; 32 entries give 0.95 IPC at slightly lower MIPS (264).
  - At Nios II/f cycle time (240 MHz, Stratix IV), the largest feasible age-based scheduler is about 20 entries for CAM, 22 for matrix and 42 for the fused-logic matrix.
  - Source — [Wong thesis Sec. 9.6-9.7](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf); [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)
- **IQ to ROB ratio.** Schedulers need only 30-50% of ROB size with almost no IPC loss (Wong, 64-entry ROB); RSD repeats this when criticizing OPA's merged ROB/IQ — [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf); [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Distributed vs unified.** Distributed schedulers have lower delay but need more total entries for the same IPC. Wong chose four per-unit schedulers (8 entries each in the baseline) — [Wong thesis Sec. 9.7.1, Table 12.2](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **RSD IQ sweep (XC7Z020-1).** With replay-queue scheduling, DMIPS is flat from IQ 16 to 32 (188.6, 188.5, 188.1) while scheduler-circuit Fmax drops from 124 to 106 MHz. RSD ships with IQ 16 — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Single-issue OoO.** Fewer than 10% IPC difference between 2 and 32 scheduler entries; Aasaraai recommends 4 — [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)
- **ROB sizes.**
  - 64: Wong, RSD, OPA, RiscyOO-B.
  - 80: RiscyOO-T+R+, needed to match BOOM's IPC.
  - 48: RiscyOO in the quad-core build, to fit the FPGA.
  - 32 status-only: SmolRV64 at 3-wide — [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf); [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf); [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf); [SmolRV64 GitHub](https://github.com/tommythorn/smolrv64)
- **LSQ sizes.**
  - 16+16: Wong, RSD.
  - 24 LQ + 14 SQ + 4-entry store buffer: RiscyOO.
  - For SQIP and NoSQ, IPC is only slightly sensitive to LQ/SQ size at a fixed predictor size — [Wong thesis Ch. 11-12](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf); [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf)
- **Width.** Every FPGA-first OoO here renames 2 per cycle (Wong, RSD, OPA, RiscyOO, CFC-era 1-wide aside), except SmolRV64 at 3-wide (README) — sources above. RiscyOO's authors believe going beyond 2-wide would need more front-end work — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf)
- **Memory-level parallelism under Linux.**
  - Wong: non-blocking OoO memory +32% and L2 +60% on SPECint2000. A large, low-associativity TLB (128-entry, 2-way) loses under 1% IPC against higher associativity — [Wong thesis Ch. 12](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
  - RiscyOO: non-blocking TLBs plus a page-walk cache +29% — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf)

### Inferences
- **Wong's wall-clock gain by benchmark.** Applying his 200/245 MHz Fmax ratio to the per-clock ratios gives about 1.18x (Dhrystone), 1.08x (CoreMark), 1.84x (MiBench) and 2.2x (SPECint2000) over Nios II/f. OoO pays off mainly on memory-intensive, OS-hosted workloads, which matches a Linux-capable target.
- **Per-ALM.** Wong's perf/ALM is about 0.34x of Nios II/f on SPECint2000 and about 0.18x on Dhrystone. Nobody demonstrated an OoO soft core with better perf/LUT than a tuned in-order core. The defensible goal is absolute performance at an acceptable LUT budget.
- **RSD against MicroBlaze.** At 2.04 DMIPS/MHz, RSD would need above roughly 226 MHz to match the Applications-preset MicroBlaze's 461 DMIPS on a -3 Zynq UltraScale+. Fmax discipline is therefore decisive, though the speed grade, compiler and benchmark conditions differ.
- **Suggested starting point for a 2-wide RV64 OoO aiming to beat NaxRiscv IPC:**
  - ROB 48-64.
  - 2-3 distributed schedulers of about 8-16 entries each (about 24-40 total), with matrix wakeup per small queue.
  - LQ/SQ 16/16 (or larger only if the search is pipelined or predictor-based).
  - Non-blocking L1D with at least 4 MSHRs.
  - L2, plus non-blocking TLB/PTW with a page-walk cache.

### Gaps
- No same-device, same-benchmark comparison of an OoO RISC-V soft core against MicroBlaze or Nios V/g (or NaxRiscv) on UltraScale+ was found in this set.
- No CoreMark/MHz is published for RSD or SmolRV64. SmolRV64's Geekbench IPC is not comparable to Dhrystone- or CoreMark-based numbers.

## Q4. Which FPGA-aware design decisions did each design make, and what did they measure?

### Takeaway
The decisions that measurably paid off:
- RAM-mapping every multiported structure (I-LVT/banking: -45% LUTs, +6% Fmax).
- Avoiding multi-write-port register files by clustering or sharding by writer.
- BRAM-based checkpointed renaming (7x fewer LUTs, +50-118% Fmax over table-based renamers).
- Small matrix schedulers with flash-clear, or fused-logic circuits (up to 42 entries at 240 MHz on Stratix IV).
- Replay-queue speculative scheduling (load-to-use -2 cycles, up to +26.8% IPC, 2.2x fewer LUTs than IQ-based replay).
- Predictor-based or small-CAM memory disambiguation instead of large CAMs.
- Low-associativity, high-capacity caches and TLBs.
- Hand-mapped LUT circuits on critical loops.

### Cited Findings
| Design (device, year) | FPGA-aware decision | Measured result | Source |
|---|---|---|---|
| RSD (XC7Z020-1, 2019) | I-LVT multiport RAM for map table, ready-bit table, wakeup allocation table, destination RAM, IQ payload, ROB execution state, PRF and store-data array. Banked RAM (no conflicts in FIFOs) for both free lists and ROB metadata | -45% LUTs, -36% registers, +6% Fmax vs FF+logic | [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf) |
| RSD | Hybrid ROB: only the out-of-order-written execution status is true-multiport; everything else is banked | Avoids Rosiere's banked-ROB IPC loss (up to 10%) | [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf) |
| RSD | Speculative scheduling: dependents of loads issue assuming an L1 hit; misses replay through a separate FIFO replay queue (in LUTRAM, 32 deep) that holds whole "issue waves" with latency counters, rather than keeping entries in the IQ | -2 cycles load-to-use; up to +26.8% IPC (8.9% avg; SPECint 2006/2017 in simulation); up to 2.2x fewer LUTs than IQ-based replay; up to +3.7% DMIPS at IQ=16 because entries free at issue | [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf) |
| RSD | Matrix wakeup indexed by IQ slot, using a RAM to map logical register to producer slot; random select | Scheduler loop 106-124 MHz at 16-32 entries (not the core limiter) | [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf) |
| RSD | 1-bit PC-indexed "wait for all older stores" memory dependence predictor (2 BRAMs) | Very low cost; trades some early-load opportunities. OPA's no-STQ alternative costs up to 40% IPC (16% avg) | [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf) |
| Wong x86 (Stratix IV, 2017) | PRF organization with execution clusters, each register file 7R1W; renamer steers writes | No LVT/FF multi-write RF needed; RF 2,400 ALMs @ 260 MHz | [Wong thesis](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) |
| Wong | Renamer without multiple checkpoints: recover by copying committed map into speculative map | 1,892 ALMs @ 317 MHz; found sufficient for IPC | [Wong thesis Ch. 7/14](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) |
| Wong | Distributed compacting matrix schedulers (age order by compaction); new "fused-logic" matrix; flash-clear of schedulers at flush; relaxed wakeup for complex ALU and AGU | 16-32 entries @ 325-280 MHz; fused-logic is 20% faster at 22-36 entries, or 2x capacity at 240 MHz; matrix faster than CAM below about 20-24 entries; CAM scales better at large sizes | [Wong thesis Ch. 9](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf); [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf) |
| Wong | Memory: VIPT 2-way L1s, large 2-way 128-entry TLBs, page walker attached to L2, non-blocking L1 with 4 MSHRs, memory dependence speculation, manual LUT mapping | 1.32x IPC (non-blocking) and 1.60x (L2) on SPECint2000; TLB+cache lookup 4.29 ns vs Nios II/f 6.0 ns; manual mapping +14% on L1 access, +54% on barrel shifter | [Wong thesis Ch. 12/14](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) |
| Wong (Ch. 11, 64 LQ/SQ) | Compared in-order, CAM, SQIP and NoSQ disambiguation | NoSQ vs CAM: 3,356 vs 7,715 equivalent ALUTs; 328 vs 186 MHz; uPC 1.19 vs 1.21 (in-order: 0.86 at 397 MHz). NoSQ was later abandoned for risk/effort but recommended as future work | [Wong thesis Table 11.3, Ch. 14](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf) |
| CFC (Stratix III, 2009) | Checkpoints as BRAM tables in a circular queue plus a LUT dirty-flag array; flattened single-write-port tables; 2-stage rename | 996 LUTs + 6 BRAM @ 220 MHz vs 7,082 LUTs @ 196 MHz (RAM-style) or 2,327 LUTs @ 105 MHz (CAM-style); IPC loss negligible | [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf) |
| SPREX / NCOR (Stratix III, 2012) | Runahead plus a CAM-free non-blocking cache instead of full OoO | Up to +38% vs Nios II; NCOR 4 KB @ 329 MHz in 270 LEs | [Aasaraai thesis](https://utoronto.scholaris.ca/items/5f3d7bbf-6ba4-42b9-8f6f-17ceec607184); [NCOR](https://api.crossref.org/works/10.1155%2F2012%2F915178) |
| OPA (XC7Z020-1 via RSD; Arria V via Wong) | Merged ROB+IQ+LDQ; no store queue; trivial predictor | 134 MHz, but 0.577 DMIPS/MHz | [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf); [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf) |
| FabScalar FPGA-Sim (Virtex-5, 2012) | Time-multiplexed multiport RAMs; CAM as value RAM plus transposed match-vector RAM | Fits on FPGA, but the effective clock is only 4.5-16.7 MHz | [FPGA-Sim](https://ericrotenberg.wordpress.ncsu.edu/files/2025/06/paper_ISPASS-2012.pdf) |
| EDGE (Kintex-7 -1, 2014/2018) | ISA-encoded dataflow targets; ready state kept in LUTRAM; incremental event-driven wakeup | 150 LUTs total for a 32-entry scheduler @ 4.3 ns (2.5 ns pipelined, but no back-to-back issue) | [Gray & Smith](https://arxiv.org/pdf/1803.06617) |
| RiscyOO (AWS F1, 2018) | None FPGA-specific; latency-insensitive BSV modules | 40 MHz single core, 25 MHz quad core | [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf) |
| SmolRV64 (XCKU5P, 2026) | PRF sharded by writer (4 x 1W); status-only 32-entry ROB; fixed-priority select with wake-at-select (no age matrix); predictor tables banked in BRAM without valid bits; cache tag/valid/dirty bits in LUTRAM per page color; large direct-mapped dTLB; netlist RAM-inference checks | 166.67 MHz, 114k LUTs, Linux/Ubuntu; suite IPC about 1.0 | [SmolRV64 GitHub](https://github.com/tommythorn/smolrv64) |
| SoomRV (Artix-7, 2023-) | Tag-indexed register file; loads issue before their data is available; through-memory dependency tracking | 41.67 MHz on Arty A7-100T; 5.42 CoreMark/MHz | [SoomRV GitHub](https://github.com/mathis-s/SoomRV); [SoomRV-Arty](https://github.com/mathis-s/SoomRV-Arty) |

- **Synthesis behavior.** Synthesis tools aggressively extract shared subcircuits at the cost of logic depth. Wong needed explicit "keep" and logic-cell directives to force the intended LUT structure — [Wong thesis Sec. 14.1.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **No commercial OoO soft cores.** As of 2016 there were still no commercial out-of-order superscalar soft processors — [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)

### Inferences
- On Xilinx parts, RSD's I-LVT/banking and replay-queue choices are directly portable because they were measured on 7-series LUTRAM. Wong's fused-logic matrix relies on Stratix IV 7-input ALM functions and would need rework for 6-LUT UltraScale+ (his own caveat).
- The two RF strategies that avoid LVT write-port cost are worth evaluating against I-LVT for an RV64 PRF: clustering (Wong) and writer-sharding (SmolRV64). Both have the renamer pick a physical register in the writing unit's shard. That decouples write ports from multiport RAM tricks, at the cost of free-list partitioning and possible shard imbalance.

### Gaps
- No design here reports memory dependence prediction beyond RSD's 1-bit scheme, the SQIP/NoSQ studies in Wong's simulator, and SmolRV64's alias-wait policy. Store-sets on FPGA were not measured in any whole design found.
- There is no whole-core measurement of LVT vs XOR vs banked PRFs at RV64 widths (64-bit data) on UltraScale+. Block-level studies are covered elsewhere.

## Q5. Pros/cons of each design and lessons for a 2-wide OoO RV64 dual-core (Linux, SMT/CMT hooks) on Kria KV260 (Zynq UltraScale+ XCK26)

### Takeaway
The best-evidenced recipe:
- Keep RSD-style RAM-mapped OoO bookkeeping and replay-queue speculative scheduling.
- Use Wong-style clustered or SmolRV64-style sharded single-write-port PRFs, small distributed matrix schedulers with flash-clear, and RAM-based rename with committed-map recovery or CFC-like BRAM checkpoints.
- Use a modest-associativity, high-capacity memory hierarchy with a non-blocking L1D, an L2 and non-blocking TLB/PTW. This matters most for Linux.
- Above all, protect Fmax (at least about 0.8x of an in-order core on the same part). OPA shows that buying Fmax by deleting the STQ or the branch predictor destroys IPC.

### Cited Findings
- **RSD.** Pro: about 1.9x BOOM's DMIPS/MHz and 2.5x its DMIPS at 36% of its LUTs (XC7Z020-1). Contributing causes are no fetch bubble on taken branches, speculative scheduling and RAM-mapped structures. Con: 95 MHz, branch predictor and STQ critical, RV32 only, no Linux — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf); [RSD GitHub](https://github.com/rsd-devel/rsd)
- **Wong.**
  - Pros: about 0.8x Nios II/f Fmax with full OoO and OS support. The lessons are that FPGA OoO needs no exotic microarchitecture; that PRF organization and low-associativity caches/TLBs suit FPGAs; and that the page walker should hang off the L2.
  - Cons: x86-specific complexity (atomic microcode commit forces minimum queue sizes, partial-register serialization, x87 emulation) and an estimated rather than built full core — [Wong thesis Ch. 14](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **CFC/SPREX.** Pros: BRAM-resident renaming at high Fmax, and runahead as a cheap memory-level-parallelism alternative. Cons: single-issue, simulator-only IPC — [CFC paper](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf); [Aasaraai thesis](https://utoronto.scholaris.ca/items/5f3d7bbf-6ba4-42b9-8f6f-17ceec607184)
- **RiscyOO/Toooba.** Pros: RV64 Linux, multicore TSO/WMM, and quick design iteration on TLB improvements (+29%). Cons: 25-40 MHz and very large on VU9P/VCU118 — [RiscyOO paper](https://people.csail.mit.edu/szzhang/paper/micro2018.pdf); [arXiv 2609.11590](https://arxiv.org/html/2609.11590v1)
- **AnyCore/FabScalar.** Pro: configurable, verified RTL. Con: FPGA mapping only as a time-multiplexed simulator (4.5-16.7 MHz effective) — [FPGA-Sim](https://ericrotenberg.wordpress.ncsu.edu/files/2025/06/paper_ISPASS-2012.pdf)
- **OPA.** Pro: 134 MHz with no BRAM. Con: 0.577 DMIPS/MHz; merged ROB/IQ wastes scheduler capacity; no STQ costs up to 40% IPC — [RSD paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf); [Wong FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)
- **SCOoOTER.** Pros: a clean SMT model (thread-tagged fetch, replicated architectural state) and multi-core atomics via an arbiter holding the LR/SC reservation. Cons: Tomasulo-style operand broadcast into RSs, non-speculative memory, no caches, no FPGA data — [SCOoOTER paper](https://www.esa.informatik.tu-darmstadt.de/assets/publications/materials/2025/2025_WCAE_MS.pdf)
- **SmolRV64.** Pros: RV64 Linux at 166.67 MHz on a UltraScale+ part, and a disciplined verification flow (lockstep co-simulation, always-on invariants, a board boot gate for every change). Cons: 114k LUTs, too big for two copies on a KV260-class part as configured (see Gaps); self-reported and fast-moving — [SmolRV64 GitHub](https://github.com/tommythorn/smolrv64)
- **SoomRV and VRoom!.** Pros: show aggressive OoO RISC-V by individuals, with Linux. Cons: low FPGA clocks (41.67 MHz on Artix-7) or trimmed FPGA builds, and no FPGA area data — [SoomRV-Arty](https://github.com/mathis-s/SoomRV-Arty); [VRoom! GitHub](https://github.com/MoonbaseOtago/vroom); [Hackaday](https://hackaday.com/tag/system-verilog/)
- **Verification and correctness lessons.** Wong used an "execute-in-execute" cycle model, so timing bugs show up as functional errors, and tracked time in committed instructions so interrupts line up with the ISA simulator — [Wong thesis Sec. 14.1.1](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf). SmolRV64 notes that bug-detection latency, not defect rate, dominates schedule — [SmolRV64 GitHub](https://github.com/tommythorn/smolrv64)

### Inferences
1. **Fmax budget first.** The RSD-vs-MicroBlaze and Wong-vs-Nios arithmetic shows that per-clock gains of 1.3-2.7x are erased by Fmax losses of 2-3x. A realistic target is at least 150-200 MHz on the KV260's speed grade, the same class as SmolRV64's 166.67 MHz on KU5P. Pipeline the L1D/TLB/store-forward path and the next-PC/predictor loop first.
2. **RAM-map everything multiported.**
   - ROB metadata and free lists: banked LUTRAM/BRAM.
   - Execution status, ready bits and map table: I-LVT or a single-write-port design.
   - PRF: clustered or writer-sharded single-write-port banks, replicated for reads.
   - This is the biggest measured LUT lever (-45% on RSD) and it also helped Fmax.
3. **Schedulers.** Use 2-3 per-pipe matrix schedulers of 8-16 entries (age by compaction or position), mapping logical registers to producer slots through a RAM table (RSD's wakeup allocation table, Wong's logical-register mapping). Flash-clear wrong-path entries. Add RSD-style replay-queue speculative wakeup for loads (+8.9% average IPC in simulation). Keep the total IQ around 30-50% of the ROB.
4. **Rename and recovery.** A RAM-based RAT with committed-map copy recovery is enough at 2-wide according to Wong. If branch-recovery latency proves to matter for beating NaxRiscv, CFC-style BRAM checkpoints give fast multi-checkpoint recovery at low LUT cost.
5. **Memory.**
   - Keep a store queue; OPA shows deleting it is fatal.
   - Keep the LQ/SQ around 16 entries each, or use SQIP/NoSQ-style or RSD-style prediction to avoid wide CAM searches (Wong: CAM LSQ halves Fmax at 64 entries).
   - Non-blocking L1D (at least 4 MSHRs) plus a shared L2 for the dual-core, and non-blocking TLBs with a page-walk cache (+29% for RiscyOO under Linux).
   - Prefer 2-way VIPT L1s and large low-associativity TLBs (Wong, SmolRV64).
6. **SMT/CMT hooks.** SCOoOTER's thread-ID tagging with replicated architectural, CSR and speculative state is the simplest published model. For CMT, RiscyOO shows TSO and WMM variants differing mainly in the LSQ. Leave thread-ID bits in ROB, IQ, LSQ and map-table indexing from day one.
7. **Branch prediction.** Avoid predictors with long combinational index/compare paths. RSD and BOOM were both predictor-limited on Zynq-7020. Bank the predictor tables in BRAM and override from a simpler fast predictor, as Wong (fetch BTB then decode gshare) and SmolRV64 (BRAM-banked BTB/YAGS) did. Eliminate taken-branch fetch bubbles, which cost BOOM DMIPS/MHz in RSD's comparison.

### Gaps
- The KV260/XCK26 device budget (LUT/FF/BRAM/URAM counts) and speed grade were not researched here. The 114k-LUT SmolRV64 data point should be checked against the real XCK26 capacity before drawing dual-core conclusions.
- No source measured an OoO core with SMT on an FPGA. VRoom! claims 2-way SMT but publishes no FPGA data; SCOoOTER's SMT has no FPGA results.
- NaxRiscv IPC and Fmax baselines on UltraScale+ are covered by another researcher; no direct OoO-vs-NaxRiscv comparison was found among the designs here.
- The web-search budget was exhausted before searching ProSpeCT/Libra papers (Proteus-O sizes and area), RSD Linux/MMU work, and any 2024-2026 FPT/FPL OoO soft-core papers beyond those listed. A follow-up search is recommended.
