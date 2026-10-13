# Linux-capable in-order and modest-superscalar RISC-V baseline cores (CVA6/CVA6S/CVA6S+, Rocket, Shuttle, BlackParrot, NutShell, Shakti C-class, biRISC-V, CVA5, OpenC906, MicroBlaze V, SiFive U74/U8) — state as of 2026-10-12

Scope note: covers Linux-capable (MMU + S-mode) in-order / dual-issue in-order cores used as baselines. NaxRiscv/VexiiRiscv/VexRiscv, BOOM, XiangShan, C910 and FPGA-academic OoO cores are covered by other researchers. C910 appears below only as a comparison point inside a CVA6 paper. All mechanisms are described in prose; no source code is reproduced. Every number carries its date/version/config where the source gave one; numbers that are stale, secondary, or conflicting are flagged.

## Q1. What IPC do these cores achieve and what limits them? What did CVA6's dual-issue/superscalar mode gain in IPC and cost in area/Fmax?

### Takeaway
Single-issue in-order Linux cores sit at roughly 0.7–0.85 IPC (CVA6 Embench average 0.70; Ariane Dhrystone 0.82) and about 2–3 CoreMark/MHz. The main limits are branch mispredictions, load-use stalls behind a 3-cycle D-cache, a small 8-entry scoreboard/ROB, and a blocking cache. CVA6's dual-issue in-order modes add about 20–45% IPC, depending on benchmark and configuration: CVA6S gave +40% CoreMark/MHz for +11% area and −1.75% Fmax (ASIC), and CVA6S+ gave +43.5% Embench IPC for +9.3% total area. They still reach only about 0.94 IPC, against 1.61 for the 3-wide OoO C910 in the same study. Two well-tuned dual-issue in-order designs set the bar that a 2-wide OoO core has to clear clearly: SiFive U74 (late ALU and correlating BHT; ~5.1 CoreMark/MHz, secondary source) and biRISC-V (gshare/BTB/RAS; 4.1 CoreMark/MHz, RV32IM).

### Cited Findings

#### Per-core snapshot (dates/configs inline; see later questions for details)

| Core | Pipeline / issue | ISA (as documented) | Performance (config, date) | Linux / multicore | Verification | Sources |
|---|---|---|---|---|---|---|
| CVA6 (Ariane), OpenHW | 6-stage, single-issue in-order issue, out-of-order execute/write-back via scoreboard; commit up to 2/cycle | RV64GC (Ariane tapeout; paper inconsistent, abstract says RV64IMC); CVA6 family has 32/64-bit configs, M/S/U | Ariane: up to 1.65 DMIPS/MHz, Dhrystone IPC 0.82 (2019, GF22FDX). CoreMark/MHz: 2.08 (CF'21 survey, flagged), 2.19 (CF'25, 64 KB 2-way caches), 2.83 (RV32 on Cheshire/Genesys2, May 2025), 3.10 (RV32 imac+Zb*, 1-cycle cache assumed, 2024), 1.98 (Cheshire on ZCU104 @50 MHz, thesis) | Boots Linux; multicore via OpenPiton (Fedora on dual-core, Nov 2023) or Culsans snoop unit (2–4 cores, 2024) | core-v-verif (UVM, riscv-dv, Spike + Verilator); RVFI traces | [Ariane paper](https://ar5iv.labs.arxiv.org/html/1904.05442); [CF'25](https://arxiv.org/html/2505.24363v1); [CVA6S+](https://arxiv.org/html/2505.03762v2); [Allart](https://arxiv.org/pdf/2410.01442); [repo](https://github.com/openhwgroup/cva6) |
| CVA6S (Thales, Allart et al.) | Dual-issue in-order, 2 ALUs, 64-bit fetch, speculative scoreboard | cv32a6_imac_sv0 + Zba/Zbb/Zbc/Zbs; no FPU | 4.35 CoreMark/MHz (+40.1%); Dhrystone +24% (2024) | Linux boots on FPGA without speculative-scoreboard option | Python cycle model 99.2% accurate vs RTL | [arXiv 2410.01442](https://arxiv.org/pdf/2410.01442) |
| CVA6S+ (ETH/UniBo) | Dual-issue in-order + WAW renaming, 2-level BP, same-cycle ALU forwarding, HPDCache | RV32IMAC + Zba/b/c/s + FPU | 3.69 CoreMark/MHz; Embench IPC +43.5% vs CVA6 (May 2025); avg IPC 0.94 in CF'25 | Evaluated in Cheshire SoC on Genesys2 | — | [arXiv 2505.03762v2](https://arxiv.org/html/2505.03762v2); [CF'25](https://arxiv.org/html/2505.24363v1) |
| Rocket (rocket-chip / Chipyard) | 5-stage in-order scalar | RV64GC, M/S/U | 2.94 CoreMark/MHz, 1.71 DMIPS/MHz (CF'21 survey, table garbled, verify); SiFive U54 (Rocket-class) 2.75 CoreMark/MHz, 1.7 DMIPS/MHz (2017 vendor) | Debian on FPGA, 1–8 cores (vivado-risc-v, current) | Chisel generator, upstream CI (not detailed here) | [Chipyard](https://chipyard.readthedocs.io/en/main/generators/rocket/); [vivado-risc-v](https://github.com/eugene-tarassov/vivado-risc-v); [cnx 2017](https://www.cnx-software.com/2017/10/06/sifive-u54-mc-coreplex-is-the-first-linux-ready-risc-v-based-64-bit-quad-core-application-processor/) |
| Shuttle (Chipyard) | Rocket-based 6-stage superscalar in-order, 2/3/4-issue (2 "most sensible") | RV64IMAFDC, S/U | No numbers published; "not designed to meet any PPA targets" | S/U modes (Linux not explicitly stated); tape-out proven | — | [Chipyard Shuttle](https://chipyard.readthedocs.io/en/main/generators/shuttle/) |
| BlackParrot (UW/BU) | In-order (pipeline details not retrieved) | RV64IMAFDC + Zfencei, Zicsr, Zcbo, Zba, Zbb, Zbs | No CoreMark/IPC found | Linux 5.15 on 8-core FPGA build at 50 MHz (2025); up to 16-core+ coherent (BedRock) | CI regression + Synopsys DC check; CMurphi model checking of coherence | [repo](https://github.com/black-parrot/black-parrot); [BedRock thesis](https://arxiv.org/html/2505.00962) |
| NutShell (UCAS OSCPU) | Single-issue, 9-stage, in-order | RV64IMAC, M/S/U | No CoreMark found | Linux + Debian; taped out SMIC 110 nm (Dec 2019, chips back Apr 2020) | difftest (from XiangShan) + NEMU reference | [slides](https://docs.google.com/presentation/d/1yUEGu6CObkBsoUtOf06S5ro3Kg5ZYk7r/htmlpresent); [repo](https://github.com/OSCPU/NutShell); [ithome](https://www.ithome.com/0/499/804.htm) |
| Shakti C-class (IIT Madras) | 5-stage (2019) → 6-stage in-order (current docs) | RV64GCSUN | 1.72 DMIPS/MHz (2019 slides) vs "<1 DMIPS/MHz" (overview), conflicting; no CoreMark found | Boots Linux; multiple silicon prototypes | — | [2019 slides](https://riscv.org/wp-content/uploads/2019/12/12.11-14.20a5-Menon-IITMadras-Processor-IP-Showcase-with-Andes-Technology-CHIPS-Alliance-Codasip-Shakti-Project-SiFive-Syntacore-OpenHW-Group-4.pdf); [overview](https://shakti.org.in/docs/Shakti-Overview.pdf); [docs](https://c-class.readthedocs.io/en/latest/intro.html) |
| biRISC-V (ultraembedded) | Dual-issue in-order, 6 or 7 stages | RV32IMZicsr (no hardware A) | 4.1 CoreMark/MHz; 1.9 DMIPS/MHz | Linux 5.0.0-rc8 (RV32IMA, atomics emulated in bootloader) on Arty A7; single core | RISCV-DV random tests + co-sim vs C++ ISA model | [repo](https://github.com/ultraembedded/biriscv) |
| CVA5 (ex-Taiga, SFU/OpenHW) | "Application-class 5-stage", parallel variable-latency execution units, ID-tracked | RV32IMAFD (README) | Taiga: up to +42% IPC vs fixed pipeline; no CoreMark found | MSU modes and TLBs in config; Linux boot not confirmed | Verilator testbench, GitLab CI | [repo](https://github.com/openhwgroup/cva5); [config](https://raw.githubusercontent.com/openhwgroup/cva5/master/core/types_and_interfaces/cva5_config.sv); [SFU](https://summit.sfu.ca/item/35160) |
| OpenC906 (T-Head) | 5-stage single-issue in-order | RV64IMAFDC in open release, Sv39 | Vendor: 3.8 CoreMark/MHz (O3), 2.4 DMIPS/MHz (O2), via secondary source with visible errors | Linux-class SoC core (BL808 per Pine64; Allwinner D1 per linuxadictos); open RTL boot only tested in sim in LiteX (2022) | smart_run testbench (iverilog/VCS/irun) | [repo](https://github.com/XUANTIE-RV/openc906); [Ox64](https://pine64.org/documentation/Ox64/Further_information/SoC_and_Memory_Specification/); [cnx 2021](https://www.cnx-software.com/2021/10/20/alibaba-open-source-risc-v-cores-xuantie-e902-e906-c906-and-c910/); [linuxadictos](https://www.linuxadictos.com/en/allwinner-xuantie-c906-risc-v.html) |
| AMD MicroBlaze V | 3/4/5/8-stage options (classic MicroBlaze pipeline with RISC-V decode) | RV32/RV64 IMAFDC; Sv32 / Sv39 / Sv48 / Sv57 | No DMIPS/CoreMark in UG1629 2026.1 resource tables | "Linux" config RV64IMAFDC + MMU; Linux 6.8 DT bindings; ACE coherent cache interface | AMD-internal (not public) | [UG1629 resources](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization); [Phoronix](https://www.phoronix.com/news/AMD-MicroBlaze-V-Linux-6.8) |
| SiFive U74 (published) | 8-stage dual-issue in-order, peak 2 IPC | RV64GC_Zba_Zbb_Sscofpmf, M/S/U | ~5.1 CoreMark/MHz (secondary, via cnx-software) | Linux SoCs (JH7110, FU740) | — | [U74 manual 21G3.02.00](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf) |
| SiFive U84 (published) | 12-stage, 3-wide OoO, physical register file | RV64GC | 3.1x U74 (2.3x IPC × 1.4x freq to 2.6 GHz), SiFive internal (Oct 2019) | — | — | [SiFive blog](https://sifive.com/blog/incredibly-scalable-high-performance-risc-v-core-ip); [cnx](https://www.cnx-software.com/2019/10/26/sifive-u8-series-out-of-order-risc-v-core-ip-takes-on-arm-cortex-a72-core/) |

#### CVA6 / Ariane baseline: IPC and limiters
- Ariane is a 6-stage, single-issue, in-order RV64 core (PC generation, fetch, decode, issue, execute, commit). The scoreboard and ROB are one circular buffer of 8 entries, commit retires up to 2 instructions per cycle, and WAW hazards were handled by a one-bit renaming scheme. — [Zaruba & Benini, arXiv 1904.05442 (2019)](https://ar5iv.labs.arxiv.org/html/1904.05442)
- Ariane reaches up to 1.65 DMIPS/MHz (depends on branch predictor and load latency) and Dhrystone IPC 0.82 with a 128-entry BHT and 64-entry BTB at a 5.77% mispredict rate. A 16-bit 2D convolution reaches IPC 0.85. — [Ariane paper](https://ar5iv.labs.arxiv.org/html/1904.05442)
- The authors attribute IPC losses to mispredicted branches and to load-use stalls caused by the 3-cycle D-cache latency. More advanced predictors (gshare, loop, tournament) were not explored, and lowering load latency would cost cycle time. — [Ariane paper](https://ar5iv.labs.arxiv.org/html/1904.05442)
- The one-bit register renaming was later removed from CVA6 (footnote in the 2024 superscalar paper). — [Allart et al., arXiv 2410.01442](https://arxiv.org/pdf/2410.01442)
- CF'25 configuration table for CVA6: decode width 1, commit width 2, 6 stages, BHT/BTB 128/32 entries, RAS 2, 32 architectural registers (no physical register file), ROB 8, 1 ALU + 1 FPU, 1 load + 1 store port, load/store queue 2/4. Average Embench IPC 0.70 and 2.19 CoreMark/MHz with L1 I/D forced to 64 KB 2-way. — [Fu et al., CF'25, arXiv 2505.24363v1 (30 May 2025)](https://arxiv.org/html/2505.24363v1)
- CoreMark/MHz for the scalar baseline varies widely by configuration: 3.10 (cv32a6_imac_sv0 + Zba/Zbb/Zbc/Zbs, assuming 1-cycle cache latency) — [Allart](https://arxiv.org/pdf/2410.01442); 2.83 (32-bit, RV32IMAC + bitmanip, Cheshire on Genesys2, 32 KiB 8-way D$, 16 KiB 4-way I$) — [CVA6S+ paper](https://arxiv.org/html/2505.03762v2); 2.19 (CF'25 configuration) — [CF'25](https://arxiv.org/html/2505.24363v1); 2.08 CoreMark/MHz and 1.21 DMIPS/MHz in a 2021 comparative survey (extracted table had garbled headers, verify) — [CF'21 survey](https://dl.acm.org/doi/pdf/10.1145/3457388.3458657); 1.98 CoreMark/MHz bare-metal for single-core CVA6 at 50 MHz in Cheshire ported to ZCU104 (from thesis abstract via search snippet; page fetch failed) — [Tampere thesis](https://trepo.tuni.fi/handle/10024/232795)

#### CVA6S: Thales dual-issue CVA6 (model-driven)
- Model first: a Python cycle model of CVA6 (control path only; omits fetch) achieved 99.2% accuracy on the second CoreMark iteration, or 99.8% with the RAS disabled in both model and RTL. It was compared against RTL at three levels: global cycle counts, cycle-annotated RVFI traces, and per-cycle scoreboard dumps. — [Allart et al., arXiv 2410.01442 (2024)](https://arxiv.org/pdf/2410.01442)
- Predicted gains (vs single-issue): 64-bit fetch +1%, dual issue with one ALU +21%, two ALUs +47%. The model also showed that moving the multiplier to the FPU write-back port would gain under 3%, so that change was discarded. — [Allart](https://arxiv.org/pdf/2410.01442)
- Implementation lessons:
  - After the dual-issue step only +12% (not +21%) was reached. The cause was that the instruction after a predicted control-flow instruction could not issue in the same cycle, because the scoreboard could only be fully flushed. The fix was an optional "speculative scoreboard": a per-entry cancelled bit plus an interval mask between the branch and the issue pointer allows a partial flush. — [Allart](https://arxiv.org/pdf/2410.01442)
  - Requiring two free scoreboard entries before issuing made the small embedded scoreboard under-utilized. The fix detects "full" and "exactly one free" separately using odd/even entry occupancy. — [Allart](https://arxiv.org/pdf/2410.01442)
  - The second ALU reuses the FPU write-back port to avoid adding a port, so this superscalar CVA6 dropped FPU support. — [Allart](https://arxiv.org/pdf/2410.01442)
- Results (configuration as above; technology node not stated in the extracted text): CoreMark/MHz 3.10 → 4.35 (+40.1%); max frequency 892 → 877 MHz (−1.75%; the critical path is not in the modified parts); power 32.45 → 34.84 mW (+7.37%); area 250 → 278 kGE (+11.1%); Dhrystone +24%. Enabling register renaming in the model raises the CoreMark gain to +45%. — [Allart](https://arxiv.org/pdf/2410.01442)
- Linux boots on FPGA for single-issue and for superscalar without the speculative scoreboard; Linux with the speculative scoreboard was left as future work. A prior superscalar CVA6 by others reported only +16% on Dhrystone. — [Allart](https://arxiv.org/pdf/2410.01442)

#### CVA6S+: ETH/UniBo superscalar plus HPDCache
- CVA6S+ adds to CVA6S:
  - renaming that tracks the latest writer of integer and FP registers, to mitigate WAW hazards;
  - a two-level branch predictor (128 entries, 3-bit private history per entry), which cuts misprediction penalty by 30% on Embench-IoT versus CVA6's bimodal predictor;
  - ALU-to-ALU forwarding within the same issue pair;
  - an integrated FPU that shares its write-back port with the second ALU, with extra hazard logic;
  - HPDCache in place of the legacy cache (3-stage pipeline, multiple request ports, deep MSHR, out-of-order, hardware prefetcher, write-through and write-back, atomics).
  — [Tedeschi et al., arXiv 2505.03762v2 (8 May 2025, RISC-V Summit Europe 2025)](https://arxiv.org/html/2505.03762v2)
- Results: Embench-IoT average IPC +43.5% vs CVA6 and +10.9% vs CVA6S. CoreMark/MHz: CVA6 2.83, CVA6S 3.41 (+20.2%), CVA6S+ 3.69 (+30.2%). RaiderSTREAM bandwidth +74.1% for HPDCache vs the legacy cache. — [CVA6S+ paper](https://arxiv.org/html/2505.03762v2)
- Cost (GF22FDX, worst case 0.72 V, −40 °C):
  - Total area +9.30%; pipeline area excluding caches +28.6%.
  - HPDCache cuts D-cache area by 19% and raises max frequency by 13.5%.
  - Max frequency: CVA6 1090 MHz, CVA6S+ with legacy cache 960 MHz, CVA6S+ with HPDCache 1095 MHz (the "<0.5% degradation" claim).
  - An optional load-unit output register adds one cycle of load latency for timing closure.
  — [CVA6S+ paper](https://arxiv.org/html/2505.03762v2)
- Independent comparison (CF'25), with all L1s set to 64 KB 2-way:
  - Average IPC: CVA6 0.70, CVA6S+ 0.94 (+34.4%), C910 1.61 (+119.5%).
  - CoreMark/MHz: 2.19 / 2.84 / 4.86.
  - On nbody, CVA6S+ IPC is 0.35, below CVA6's 0.47. The authors attribute this to the single FPU and the write-back port it shares with the second ALU.
  - CVA6S+ area: +16.5% excluding caches (+6% including). Fetch 50 → 100 kGE, integer execute 77 → 103 kGE, decode/issue 90 → 120 kGE.
  - Fmax (FFG corner, −40 °C, 0.88 V): CVA6 1340 MHz, CVA6S+ 1227 MHz, C910 1718 MHz.
  - CVA6S+ draws about 34% more power and has the best area efficiency (1.65x CVA6 GOPS/mm²).
  — [Fu et al., CF'25](https://arxiv.org/html/2505.24363v1)
- Conflict flag: the Fmax cost of CVA6 dual issue is reported as −1.75% (Allart, 892 → 877 MHz), about 0% (Tedeschi with HPDCache, worst-case corner) and −8.4% (Fu et al., 1340 → 1227 MHz, fast corner). The area cost is reported as +11.1% (Allart, kGE), +9.3% (Tedeschi) and +6% including caches (Fu et al.). The differences come from configurations, caches and corners, so these are not like-for-like. — [Allart](https://arxiv.org/pdf/2410.01442); [Tedeschi](https://arxiv.org/html/2505.03762v2); [Fu](https://arxiv.org/html/2505.24363v1)
- Mainline status is ambiguous. OpenHW docs say CV32A60X is an interim part number "until the team can decide if this configuration is single- or dual-issue" and that it becomes CV32A65X if dual issue is selected. A CV32A65X design document exists, but its text still describes a "6-stage in-order and single issue" core. — [CVA6 user manual intro](https://docs.openhwfoundation.org/projects/cva6-user-manual/01_cva6_user/Introduction.html); [CV32A65X design doc](https://cva6.readthedocs.io/en/latest/04_cv32a65x/design/design.html)

#### Rocket / SiFive U5-class
- Rocket is a 5-stage in-order scalar core (RV64GC, M/S/U) with a configurable BTB/BHT/RAS front end, a non-blocking data cache, and page-based VM with configurable TLB sizes. — [Chipyard Rocket docs](https://chipyard.readthedocs.io/en/main/generators/rocket/)
- Default rocket-chip predictor parameters:
  - 28-entry fully associative BTB (pseudo-LRU) and 6-entry RAS.
  - 512-entry BHT with 1-bit counters and an 8-bit global history hashed to 3 bits.
  - The BHT and RAS are consulted only when the BTB hits, so a BTB miss means no direction prediction at all.
  — [rocket-chip BTB.scala (master, fetched 2026-10)](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/BTB.scala)
- Default core parameters: fastLoadWord on and fastLoadByte off, so byte/halfword loads and SC incur a 2-cycle load-use delay. — [RocketCore.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/RocketCore.scala)
- Default D-cache: 64 sets × 4 ways × 64 B (16 KiB), random replacement, 1 MSHR (non-blocking only in the minimal sense; zero MSHRs selects the blocking variant), store data queue 17, replay queue 16. — [HellaCache.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/HellaCache.scala)
- Benchmarks:
  - CF'21 survey: Rocket 2.94 CoreMark/MHz and 1.71 DMIPS/MHz, versus CVA6 2.08 / 1.21. Table headers were garbled in extraction, so verify. The survey also says Rocket "dominates 3 out of 4 categories". — [CF'21 survey](https://dl.acm.org/doi/pdf/10.1145/3457388.3458657)
  - SiFive U54 (single-issue in-order, Rocket lineage): 1.7 DMIPS/MHz and 2.75 CoreMark/MHz (2017 vendor figures, stale). — [cnx-software 2017](https://www.cnx-software.com/2017/10/06/sifive-u54-mc-coreplex-is-the-first-linux-ready-risc-v-based-64-bit-quad-core-application-processor/)

#### SiFive U74 (dual-issue in-order) and U8 (OoO): published microarchitecture
- U74 (manual 21G3.02.00, PDF dated 2022-01-04):
  - Pipeline: 8-stage dual-issue in-order with peak 2 IPC. Stages are F0–F2, ID, AG (address generation), M1, M2, WB.
  - Late ALU: integer ALU and branch instructions execute in AG if operands are ready, otherwise in M2. This gives no load-use delay for most integer consumers. Loads, stores and indirect jumps need their address operands in AG, so the load-to-address-use delay is 2 cycles.
  - Latencies: loads produce results in M2 (LW 3-cycle latency); MUL 3 cycles, fully pipelined; DIV 6–68 cycles.
  - CSR writes usually flush the pipeline, a 7-cycle penalty.
  — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf)
- U74 dual-issue rules: the pipeline interlocks on RAW and WAW. A pair may issue together if there are no data hazards between them and at most one accesses memory, at most one is a branch/jump, and at most one is FP arithmetic. Fetch delivers 8 bytes/cycle (up to four 16-bit instructions). — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf)
- U74 branch prediction:
  - 16-entry BTB with 1-cycle latency.
  - 3.6 KiB correlating BHT supporting long histories.
  - 8-entry indirect-jump target predictor, 6-entry RAS, and a 16-entry return-instruction predictor.
  - BHT/IJTP/RAS override the BTB at a cost of a 1-cycle bubble.
  - Mispredict penalty: usually 4 cycles, 6 if resolved late; mispredicted indirect jumps cost 6.
  — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf)
- U74 CoreMark: about 5.1/MHz, from a secondary article comparing T-Head cores; no SiFive primary document was retrieved. — [cnx-software 2021](https://www.cnx-software.com/2021/10/20/alibaba-open-source-risc-v-cores-xuantie-e902-e906-c906-and-c910/)
- U8-Series/U84 (announced Oct 2019): superscalar OoO, 12-stage pipeline, triple issue, configurable depth and issue-queue width. Claimed 3.1x U74 performance, of which 2.3x is IPC and 1.4x is frequency (2.6 GHz), from SiFive internal testing. AnandTech notes physical register files, structure sizes not disclosed, and fetch/decode wider than issue. — [SiFive blog](https://sifive.com/blog/incredibly-scalable-high-performance-risc-v-core-ip); [cnx-software](https://www.cnx-software.com/2019/10/26/sifive-u8-series-out-of-order-risc-v-core-ip-takes-on-arm-cortex-a72-core/); AnandTech page summarized via search (direct fetch failed): [AnandTech](https://at-web1.www.anandtech.com/show/15036/sifive-announces-first-riscv-ooo-cpu-core-the-u8series-processor-ip/2)

#### Other cores
- biRISC-V: dual-issue in-order with 6 or 7 stages (an optional extra decode stage for timing). It has 2 integer ALUs (each with shifter and branch), 1 load/store unit, an out-of-pipeline divider, 64-bit fetch and 32-bit data. Branch prediction is bimodal/gshare with configurable BTB and RAS. It scores 4.1 CoreMark/MHz and 1.9 DMIPS/MHz (legal compile options). The stated goal was about 80% of WD SweRV's CoreMark. — [biRISC-V README](https://github.com/ultraembedded/biriscv)
- NutShell: single-issue, 9-stage, in-order RV64IMAC (M/S/U), with a BPU using PHT, a 512-entry BTB, a 16-entry RAS, 32 KB L1I and L1D, a 128 KB L2, and next-line prefetch. No CoreMark/IPC was found. — [NutShell slides](https://docs.google.com/presentation/d/1yUEGu6CObkBsoUtOf06S5ro3Kg5ZYk7r/htmlpresent)
- OpenC906: five-stage single-issue in-order pipeline per the Pine64 BL808 page. The vendor quotes 3.8 CoreMark/MHz (O3) and 2.4 DMIPS/MHz (O2), relayed by a secondary source whose spec list has visible errors. — [Pine64 Ox64](https://pine64.org/documentation/Ox64/Further_information/SoC_and_Memory_Specification/); [cnx-software](https://www.cnx-software.com/2021/10/20/alibaba-open-source-risc-v-cores-xuantie-e902-e906-c906-and-c910/)
- Shakti C-class: 2019 slides give 1.72 DMIPS/MHz; the Shakti overview says "DMIPS/MHz: <1". These conflict and neither gives CoreMark. Current docs describe a 6-stage in-order RV64GCSUN core in Bluespec with multiple silicon prototypes. — [2019 slides](https://riscv.org/wp-content/uploads/2019/12/12.11-14.20a5-Menon-IITMadras-Processor-IP-Showcase-with-Andes-Technology-CHIPS-Alliance-Codasip-Shakti-Project-SiFive-Syntacore-OpenHW-Group-4.pdf); [Shakti overview](https://shakti.org.in/docs/Shakti-Overview.pdf); [C-class docs](https://c-class.readthedocs.io/en/latest/intro.html)
- CVA5/Taiga: the parallel execution-unit design, heavily using FPGA LUTRAMs, achieved up to +42% IPC over a basic fixed-pipeline design and was up to 28% more performance-efficient per LUT (device not stated). — [SFU record](https://summit.sfu.ca/item/35160)
- BlackParrot: no CoreMark/IPC figures found. Its L1 is blocking for cacheable requests and uncacheable loads, which bounds memory-level parallelism. — [BedRock dissertation, arXiv 2505.00962 (May 2025)](https://arxiv.org/html/2505.00962)
- Shuttle: no performance numbers; documented as "not designed to meet any power, performance, or area targets". — [Chipyard Shuttle](https://chipyard.readthedocs.io/en/main/generators/shuttle/)

### Inferences
- In-order dual issue on CVA6 buys about +20–45% IPC. In the same CF'25 study (same caches, Embench), a 3-wide OoO (C910: 64-entry ROB, 96 physical registers, 2 load/store pipes, 16/12 LQ/SQ) reaches about 1.7x CVA6S+. A 2-wide OoO RV64 should therefore plausibly land between them, roughly 1.1–1.4 Embench IPC, if it has non-blocking memory and a competent predictor. This is an extrapolation, not a measurement.
- The common IPC limiters across these baselines are:
  - weak or BTB-gated direction prediction (Rocket's BHT predicts only on BTB hit; CVA6 had a bimodal BHT and a 2-entry RAS);
  - load-use latency of 2–3 cycles without a late ALU;
  - tiny in-flight windows (8-entry scoreboard);
  - write-back port sharing;
  - blocking or 1-MSHR caches.
  An OoO core removes the window limit, but only if the memory system (MSHRs, LSQ) and the front end (BTB, RAS, return/indirect predictors) are scaled with it.
- CoreMark/MHz figures for "the same" core vary by about 1.5x with cache latency, XLEN, extensions and compiler (CVA6: 1.98 to 3.10). Any "beat NaxRiscv" claim should be measured on the same FPGA SoC, cache sizes, compiler version and flags.

### Gaps
- No primary SiFive document for U74 CoreMark/DMIPS was retrieved; the ~5.1 CoreMark/MHz is secondary.
- No CoreMark/IPC was found for BlackParrot, NutShell, MicroBlaze V (the AMD product page table is based on Vivado 2023.2 and was not fetched), CVA5, or current Shakti C-class.
- The CF'21 survey table (Rocket 2.94 vs CVA6 2.08 CoreMark/MHz) could not be read directly (publisher PDF 403; mirror blocked by a bot check).
- The technology node behind Allart's 892 MHz / 250 kGE figures was not visible in the extracted text.
- The mainline merge status of the superscalar/CVA6S+ options in openhwgroup/cva6 could not be confirmed (see the ambiguity above).

## Q2. What FPGA Fmax/area do they reach, and what were the critical paths? Which ports to Zynq UltraScale+ / Kria boards exist?

### Takeaway
On 7-series FPGAs the ASIC-oriented Linux cores land around 50–100 MHz:
- CVA6 RV64GC on Kintex-7: about 41k LUTs, about 50 MHz.
- Rocket RV64: about 27.5k LUTs per core, up to 100 MHz on Virtex-7.
- BlackParrot: 50 MHz in an 8-core Linux build.

AMD's FPGA-native MicroBlaze V in its RV64IMAFDC + MMU "Linux" configuration uses only about 15k LUTs, 16 BRAM and 6 DSP, and reaches 258 MHz on Zynq UltraScale+ (XCZU9EG). On 7-series it reaches about 101 MHz (XC7Z020). That is about a 2x Fmax gap against CVA6 on comparable 7-series parts and about 5x against ZU+ (a cross-family comparison). It sets the realistic frequency ceiling and resource reference for a KV260 design. Documented critical paths center on the L1 D-cache (8-way tag compare and data select) and on large fully associative, combinational TLBs.

Zynq UltraScale+ ports that exist: NutShell (ZCU102 and other ZynqMP boards), Cheshire/CVA6 on ZCU104 (thesis, 50 MHz, Linux), and MicroBlaze V (native). No KV260-specific Linux soft-core port was found for these cores.

### Cited Findings

#### CVA6 FPGA numbers and critical path
- PERCIVAL (CVA6-based) FPGA synthesis, Vivado 2020.2 on Genesys II (Kintex-7 XC7K325T-2FFG900C). — [Mallasén et al., IEEE TETC 2022, arXiv 2111.15286v3 (7 Jul 2022)](https://arxiv.org/pdf/2111.15286)
  - Utilization: bare CVA6 without FPU uses 28,950 LUTs / 19,579 FFs. With F it uses 35,402 / 21,618; with F+D it uses 41,260 / 23,945. The FD FPU module alone is 8,163 LUTs / 2,244 FFs.
  - Timing: the 20 ns (50 MHz) constraint was met with only +0.177 ns slack. The critical path does not go through the arithmetic units.
- The CVA6 hypervisor study targeted Genesys2 at 100 MHz with Vivado 2020.2. It omitted absolute utilization but reported relative costs: a 64-entry L1 TLB adds about 50% FPGA resources, a 32-entry L1 TLB adds about 15–17%, and 32 entries plus an 8-entry GTLB adds about 20%. It notes CVA6 TLBs are fully combinational and affect area, energy and timing. — [Sá et al., arXiv 2302.02969 (Feb 2023)](https://ar5iv.labs.arxiv.org/html/2302.02969)
- Conflict flag: PERCIVAL's +0.177 ns slack at 20 ns implies about 50 MHz for that build, while Sá et al. state a 100 MHz Genesys2 target (achieved timing not reported in the retrieved text). The CVA6 Cheshire ZCU104 port also runs at 50 MHz. — [PERCIVAL](https://arxiv.org/pdf/2111.15286); [Sá et al.](https://ar5iv.labs.arxiv.org/html/2302.02969); [Tampere thesis](https://trepo.tuni.fi/handle/10024/232795)
- ASIC critical path (Ariane, GF22FDX): around the data cache, from SRAM macros through the 8-way tag comparison and data selection (about 30 gate delays), with routing congestion near memory macros. Sign-off was 902 MHz worst case (SSG, 0.72 V, 125 °C); measured 220 MHz–1.7 GHz from 0.5 to 1.15 V. — [Ariane paper](https://ar5iv.labs.arxiv.org/html/1904.05442)
- A 2021 survey states that "CVA6 clocking is restricted by L1D logic" (via search-result summary). — [CF'21 survey](https://dl.acm.org/doi/pdf/10.1145/3457388.3458657)
- CVA6S+: the legacy cache version clocks at 960 MHz versus 1095 MHz with HPDCache (+13.5% Fmax), and an optional load-unit output register exists for timing closure. Both point to the D-cache/LSU path as the frequency limiter. — [CVA6S+](https://arxiv.org/html/2505.03762v2)
- CVA6 FPGA platforms:
  - Genesys2 (Kintex-7) is the reference board; Zephyr's cv64a6 board has RV64IMAFDC, Sv39 and 1 GB DDR3. — [Zephyr](https://docs.zephyrproject.org/latest/boards/openhwgroup/cv64a6_genesys_2/doc/index.html)
  - Cheshire (PULP) is a minimal Linux-capable CVA6 host platform. — [Cheshire repo](https://github.com/pulp-platform/cheshire)
  - The OpenHW "CVA6 Platform" ran Fedora on coherent dual-core CVA6 (OpenPiton-based) on Genesys2 (Nov 2023). — [BusinessWire](https://www.businesswire.com/news/home/20231107507370/en/OpenHW-Group-Announces-CORE-V-CVA6-Platform-Project-for-RISC-V-Software-Development-Testing)
  - Culsans has a Genesys2 synthesis target. — [Culsans repo](https://github.com/Aquaticfuller/culsans)
- Zynq UltraScale+ port: Cheshire/CVA6 on ZCU104 with OpenSBI, U-Boot and Linux brought up; single-core at 50 MHz, 1.98 CoreMark/MHz bare-metal (thesis abstract via search; full text not retrieved). — [Tampere thesis](https://trepo.tuni.fi/handle/10024/232795)
- LiteX's CPU wiki lists CVA6 only under "standard/full" variants and not under the "linux" target, whereas Rocket has "Full upstream Linux support (for models with MMU enabled)". — [LiteX CPUs wiki](https://github.com/enjoy-digital/litex/wiki/CPUs)

#### Rocket
- vivado-risc-v (Debian on FPGA; supports Vitis 2021.2–2026.1):
  - LUT costs: a 64-bit Linux-capable Rocket core costs about 27,500 LUTs per core plus a 10,800-LUT base; a 32-bit small core is 6,100 per core.
  - BOOM for scale: a 2-wide Medium BOOM single core with L2 is 148,500 LUTs; a 3-wide Large BOOM is 252,700.
  - Boards and clocks: VC707 up to 8 cores at up to 100 MHz; KC705 and Genesys 2 up to 4 cores "as fast as VC707"; Nexys Video up to 2 cores at 50 MHz; Nexys A7/Arty A7-100T about one core at 50 MHz, "barely able" to run Linux.
  - No Zynq UltraScale+ boards are listed.
  — [vivado-risc-v](https://github.com/eugene-tarassov/vivado-risc-v)
- LiteX + Rocket 64-bit Linux on Arty A7-100T is documented (LiteX 2023.04). — [JASA guide](https://www.jasa.or.jp/risc-v-en/linux-on-litex-en/)

#### MicroBlaze V (UG1629 v2026.1, released 2026-07-31)
- Resource utilization by configuration (ranges over 13 device families):
  - Linux (RV64IMAFDC, C_USE_MMU=3): 14,562–15,880 LUTs, 7,500–7,954 FFs, 16 BRAM36, 6 DSP, Fmax 90–258 MHz.
  - Application (RV32IMAFC, MMU=3): 8,154–9,206 LUTs, 16 BRAM, 6 DSP, 94–290 MHz.
  - Real-time (RV32IMAC, MMU=1): 3,848–4,564 LUTs.
  - Microcontroller (RV32IMC): 2,199–2,663 LUTs, 132–420 MHz.
  — [UG1629 Resource Utilization](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization)
- Zynq UltraScale+ XCZU9EG Linux configuration: 14,994 LUTs / 7,504 FFs / 16 BRAM / 6 DSP at 258 MHz. The Application configuration on the same device is 8,171 LUTs at 264 MHz. On Zynq-7000 XC7Z020 the Linux configuration is 15,422 LUTs at 101 MHz. — [UG1629 Resource Utilization](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization)
- Maximum-frequency configuration (fastest speed grade): Zynq UltraScale+ 504 MHz, Kintex UltraScale+ 558 MHz, Artix-7 227 MHz. — [UG1629 Maximum Frequencies](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Maximum-Frequencies)

#### BlackParrot
- An 8-core BP-BedRock system (32 KiB L1 I/D, HBM-based main memory) ran Linux v5.15 (BuildRoot/BusyBox) at a 50 MHz core clock for Splash-3. The excerpt did not name the FPGA device. The dissertation shows FPGA layouts for 1, 2, 4, 8 and 16 cores. — [BedRock dissertation (May 2025)](https://arxiv.org/html/2505.00962)
- ZynqParrot is BlackParrot's supported FPGA environment ("rapid design iteration of accelerators on Zynq FPGAs"; boards not listed on the README). — [black-parrot README](https://github.com/black-parrot/black-parrot); [zynq-parrot](https://github.com/black-parrot-hdk/zynq-parrot)
- A 2021 UW thesis describes ZynqParrot as a Zynq-7000 system supporting hardware co-simulation, plus ParrotPiton (BlackParrot in the OpenPiton memory system validated on FPGA). — [UW thesis](https://digital.lib.washington.edu/researchworks/items/72458b74-6b2a-4114-bcb4-d8fd9f632140)
- Silicon: 12 nm quad-core (Jul 2019), 12 nm dual-core accelerator host (Jul 2020), 28 nm heterogeneous dual-core (Aug 2022 and Jan 2025). Releases: v1.0 Mar 2020, v2.0 Jan 2024, v2.1 Nov 2025. — [black-parrot README](https://github.com/black-parrot/black-parrot)

#### NutShell
- Vivado 2019.1 board projects exist for pynq, zedboard, zcu102, sidewinder, ultraZ and axu3cg; the last two are not publicly available. The boot flow covers both Zynq and ZynqMP PS boot, and there is a "Running Debian on FPGA" demo. — [NutShell README](https://github.com/OSCPU/NutShell)
- Tape-out: SMIC 110 nm (submitted Dec 2019, chips back Apr 2020), running Linux and the UCAS-Core teaching OS. — [ithome](https://www.ithome.com/0/499/804.htm)

#### Shakti C-class, biRISC-V, OpenC906, CVA5
- Shakti C-class:
  - 2019 slides on Artix-7: RV64IACMNSU about 6.5k LUTs at 80 MHz; RV32 about 4.5k LUTs at 100 MHz. Note there is no F/D in that ISA string.
  - The Shakti overview claims under 3k LUTs on 7-series, which conflicts with the slides.
  - 2026: the "Ganga" RV64IMACSU reference design targets Arty A7-100T and Nexys Video.
  — [2019 slides](https://riscv.org/wp-content/uploads/2019/12/12.11-14.20a5-Menon-IITMadras-Processor-IP-Showcase-with-Andes-Technology-CHIPS-Alliance-Codasip-Shakti-Project-SiFive-Syntacore-OpenHW-Group-4.pdf); [overview](https://shakti.org.in/docs/Shakti-Overview.pdf); [electronicsforu](https://www.electronicsforu.com/news/artix-7-board-runs-indias-64-bit-shakti-risc-v-core)
- biRISC-V: no measured LUT/Fmax published. The stated (achieved) goals are to fit "cheap hobbyist FPGAs (e.g. Xilinx Artix 7)" and synthesize above 50 MHz. The RTL has an EXTRA_DECODE_STAGE timing option and a SUPPORT_REGFILE_XILINX option. Linux was demonstrated on a Digilent Arty Artix-7. — [biRISC-V README](https://github.com/ultraembedded/biriscv)
- OpenC906: initial LiteX support (June 2022) was boot-tested in simulation and build-tested in Vivado, not run on hardware. The commit says it needs a device with more than 100k LUT4s and that the XC7A100T is too small (summarized via a LiteX commit-log mirror). — [LiteX commit mirror](https://software.mcgoron.com/Hardware/litex/commits/commit/577674bff230c2eb2da58dbbb9cc779647e81efe?page=19)
- CVA5: the repo includes scripts to package it as Vivado IP and a hello-world system for Nexys A7. Its cache configuration recommends at least 512 lines for efficient BRAM packing. — [CVA5 README](https://github.com/openhwgroup/cva5); [cva5_config](https://raw.githubusercontent.com/openhwgroup/cva5/master/core/types_and_interfaces/cva5_config.sv)

### Inferences
- Area: on Kintex-7, CVA6 RV64GC (about 41k LUTs) costs about 1.5x a Rocket RV64 core (about 27.5k, different tool and config) and about 2.7x MicroBlaze V's RV64 Linux configuration (about 15k across families).
- Frequency: CVA6's roughly 50 MHz on Kintex-7 is about half of MicroBlaze V's Linux configuration on a slower 7-series part (101 MHz on XC7Z020), and about 5x below its 258 MHz on ZU+. The ZU+ comparison is cross-family.
- The gap reflects ASIC-oriented structures (flip-flop-based fully associative TLBs, wide associative D$ lookup in a single stage), not ISA complexity. A KV260 design should treat about 250 MHz (single-issue, AMD-tuned) as the practical ceiling and expect a 2-wide OoO core to land meaningfully lower unless the pipeline is deep and LUTRAM/BRAM-aware.
- From vivado-risc-v, one 2-wide Medium BOOM with L2 is 148.5k LUTs. That is likely above the K26 SOM's LUT budget (commonly cited as about 117k LUTs; not verified in this session), so a dual-core 2-wide OoO on KV260 needs to be far leaner than BOOM, ideally under about 40–50k LUTs per core.
- For KV260 integration, the closest reusable references are NutShell's ZynqMP flow (PS boot plus PS DDR use) and the Cheshire-on-ZCU104 thesis. MicroBlaze V is a native drop-in IP and makes a useful A/B baseline on the same board. That the K26 has no PL-attached DDR, so a soft core must reach DDR through PS AXI ports, is from memory and needs verification.

### Gaps
- No absolute post-route CVA6 Fmax table for Kintex-7 or UltraScale+ was found (only synthesis LUT/FF plus a 50 MHz constraint).
- No published LUT/FF/BRAM per core for BlackParrot, NutShell, biRISC-V or CVA5/Taiga was found in retrieved sources, and NutShell FPGA clock rates were not found.
- No documented KV260 (XCK26) port of CVA6, Rocket, BlackParrot, NutShell or LiteX-Linux was found.
- ZynqParrot's current board list (whether Ultra96/ZU+ is supported) was not visible on the README.
- Rocket's FPGA critical path was not documented in the retrieved sources.
- XCK26 resource totals were not fetched (verify against the AMD K26 datasheet).

## Q3. How do they implement MMU/page-table walker/TLBs, caches, AMOs/LR-SC, and interrupts (CLINT/PLIC) for Linux? Any notable FPGA-friendly or FPGA-hostile choices?

### Takeaway
All of these cores use Sv39 (Sv32 for the RV32 cores), a hardware page-table walker, and the standard CLINT/PLIC pair. They differ sharply in TLB and cache organization:
- TLBs: CVA6 has 16-entry flip-flop fully associative combinational TLBs, expensive to scale on FPGA. U74 uses 40-entry fully associative L1 TLBs backed by a 512-entry direct-mapped unified L2 TLB. Rocket uses a 32-way DTLB, an 8-entry PTE cache and an optional L2 TLB. C906 has a 128-entry jTLB.
- Caches: blocking or 1-MSHR L1s are common (BlackParrot, Rocket default, legacy CVA6). Only HPDCache-style non-blocking caches deliver the bandwidth an OoO core needs.
- Atomics: the robust patterns are executing AMOs at or after commit in the L1 on an owned line, plus an LR reservation equal to a cache line with a bounded hold time. biRISC-V's software-emulated atomics are not viable for SMP Linux.

### Cited Findings

#### CVA6 / Ariane
- MMU: separate ITLB and DTLB with 16 entries each, fully set-associative and flip-flop based, pseudo-LRU, a hardware PTW on miss, and single-cycle TLB flush. TLB/PTW energy reaches 3.8 pJ per instruction, and virtual memory accounts for up to 27% of instruction energy. — [Ariane paper](https://ar5iv.labs.arxiv.org/html/1904.05442)
- Caches: 16 kB 4-way VIPT I$; 32 kB 8-way write-back D$ with 3-cycle latency; caches are the largest area and energy overhead. — [Ariane paper](https://ar5iv.labs.arxiv.org/html/1904.05442)
- Atomics: the LSU handles AMOs; atomics wait in the store buffer until commit, and interrupts are not taken when an atomic retires. — [Ariane paper](https://ar5iv.labs.arxiv.org/html/1904.05442)
- Hypervisor-era MMU options:
  - L1 TLBs of 16, 32 or 64 entries.
  - A G-stage TLB (8 or 16 entries, fully associative, PLRU) inside the nested PTW.
  - Set-associative L2 TLB options looked up in parallel with the PTW: 128 or 256 entries for 4 KiB pages, 32 or 64 entries for 2 MiB pages, 4- or 8-way.
  - Sstc (supervisor timer compare) had negligible area impact.
  - The selected design (Sstc + 8-entry GTLB, no L2 TLB) gives up to 16% (about 12.5% average) speedup on virtualized MiBench at 0.78% area. A 32-entry L1 TLB raises power by 31%.
  — [Sá et al.](https://ar5iv.labs.arxiv.org/html/2302.02969)
- HPDCache, the newer CVA6 option, is a 3-stage pipelined, multi-port, deep-MSHR, out-of-order, prefetching data cache that supports both write-through and write-back plus atomics. — [CVA6S+](https://arxiv.org/html/2505.03762v2)
- Multicore: Culsans adds a snoop-based coherence unit using MOESI via Arm ACE for 2–4 CVA6 cores. It snoops the AXI crossbar to the LLC, and the LLC does not take part in coherence. The unit is 1.6% of system area in GF22, and the system is up to 32.87% faster (dual-core) and 15.8% faster on average than OpenPiton on Splash-3. — [Culsans search summary of arXiv 2407.19895](https://arxiv.org/pdf/2407.19895)

#### Rocket
- MMU and caches: Sv39 with three-level walk, 8 PMP entries, no L2 TLB by default (configurable), 8 PTE-cache (page-walk cache) entries. The default DTLB is 1 set × 32 ways with 4 superpage entries. The D$ default is 16 KiB 4-way with 64 B blocks, 1 MSHR and 1 MMIO entry. — [RocketCore.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/RocketCore.scala); [HellaCache.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/HellaCache.scala)
- LR/SC: the cache code notes that the ISA requires constrained 16-instruction LR/SC sequences to succeed, and it blocks LR/SC reacquisition for 3 cycles after a reservation, a forward-progress mechanism. — [HellaCache.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/HellaCache.scala)
- RocketCoreParams defaults have user and supervisor modes off. Linux configurations enable them; vivado-risc-v's rocket64b* configurations boot Debian. — [RocketCore.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/RocketCore.scala); [vivado-risc-v](https://github.com/eugene-tarassov/vivado-risc-v)

#### SiFive U74
- MMU: Sv39 with fully associative 40-entry L1 ITLB and DTLB, kept separate because they are accessed in different pipeline stages. Behind them is a direct-mapped 512-entry unified L2 TLB (4 KiB pages only), with a hardware page-table walk on a miss in both. Both levels use pseudo-LRU, and SFENCE.VMA invalidates both. — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf)
- Caches: 32 KiB 2-way VIPT I$ with 1-cycle access and parity; 32 KiB 4-way D$ with ECC, inclusive with the L2; 128 KiB 8-way L2 in the documented core complex. A JH7110 SoC with U74 cores has up to 2 MB L2. — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf); [cnx-software JH7110](https://www.cnx-software.com/?p=103040)
- Atomics: LR/SC are supported only in the data-cacheable region, and AMOs are not supported on the System Port. — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf)
- Interrupts: CLINT for M-mode timer and software interrupts, and a PLIC with 132 global interrupts and 7 priority levels. PMP has 8 regions with 4 KiB granularity. — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf)

#### BlackParrot
- L1 caches: VIPT, 2/4/8-way, 64–512-bit blocks; the default is 64 sets × 8 ways × 512-bit blocks = 32 KiB. Sv39 with 4 KiB pages and a 40-bit physical address. — [BedRock dissertation](https://arxiv.org/html/2505.00962)
- Blocking and atomics: the L1 blocks on cacheable requests and uncacheable loads, while uncacheable stores are non-blocking under a credit counter. The L1 executes 32/64-bit atomic RMW on valid read-write blocks; other atomics go to the LCE and are handled like uncacheable requests. — [BedRock dissertation](https://arxiv.org/html/2505.00962)
- Coherence:
  - BedRock is a MOESIF directory protocol with transient states removed, carried on four physically separate networks (2-D mesh with Y-X routing) and a non-inclusive memory-side L2.
  - The directory engine (CCE) comes in FSM, microcoded and hybrid versions. The microcoded engine costs about 15–25 extra cycles per full-path request (about 100% occupancy overhead at 8 cores).
  - A duplicate-tag directory has a constant 6.25% storage overhead.
  - All engines implement sequential consistency, and the protocol was model-checked with CMurphi.
  — [BedRock dissertation](https://arxiv.org/html/2505.00962)
- The L2 (bsg_cache) is blocking, and the project seeks a non-blocking alternative. — [black-parrot README](https://github.com/black-parrot/black-parrot)

#### NutShell, OpenC906, MicroBlaze V, CVA5, biRISC-V, Shakti
- NutShell: Sv39 with hardware TLB refill; 32 KB L1 I/D; 128 KB L2; next-line prefetch. — [NutShell slides](https://docs.google.com/presentation/d/1yUEGu6CObkBsoUtOf06S5ro3Kg5ZYk7r/htmlpresent)
- OpenC906 (user manual dated 2024-06-27; Chinese text partially garbled in extraction, numbers legible):
  - RV64IMAFDC, Sv39 MMU translating 39-bit VA to 40-bit PA, a 128-entry jTLB.
  - 32 KB I$ and 32 KB D$ with 64 B lines, a 16 Kb BHT, a 128-bit AXI4 master.
  - PMP with 8 or 16 regions at 4 KB granularity.
  - Dedicated chapters on the CLINT and PLIC, and a multi-stream data prefetcher into L1.
  — [OpenC906 doc folder](https://github.com/XUANTIE-RV/openc906/tree/main/doc)
- MicroBlaze V (UG1629 v2026.1):
  - MMU: enabled with C_USE_MMU=3 (Supervisor). Sv32 on RV32; Sv39, Sv48 and Sv57 on RV64. The satp ASID field is 7 bits, and PMP is unavailable when the MMU is on. — [UG1629 Virtual Memory](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Virtual-Memory-Management)
  - Other features: ACE for coherent cache interfaces; stream-buffer and victim-cache options; low-latency vectored, NMI, resumable NMI and "platform" interrupts; lockstep. — [UG1629 Features](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Features)
  - UG1711 (2025.2) describes an "Application" preset with floating point, Supervisor mode and page-based virtual memory. — [UG1711](https://docs.amd.com/r/en-US/ug1711-microblaze-v-embedded-design/MicroBlaze-V-Configuration-Wizard-Welcome-Page)
  - Linux 6.8 added the MicroBlaze V DeviceTree bindings, reusing MicroBlaze support because the hardware pipeline is largely the same with a new RISC-V decoder. — [Phoronix](https://www.phoronix.com/news/AMD-MicroBlaze-V-Linux-6.8)
- CVA5 (example configuration in the repo):
  - Privilege and MMU: MSU privilege mode; independent ITLB and DTLB (example: 2-way, 64 entries).
  - Atomics: the A extension is optional (off in the example). The AMO unit has an LR wait limit (32 cycles, covering the longest constrained LR/SC sequence) and a reservation size of 8 words, which must match the cache line size.
  - Caches and memory: 2-way 16 KiB I/D caches; a 4-entry store queue with store-to-load forwarding.
  - Back end: 2 retire ports, 2 register-file read ports, 16 in-flight IDs, 3 write-back groups.
  - Branch prediction: 2-way 512-entry predictor plus an 8-entry RAS.
  — [cva5_config](https://raw.githubusercontent.com/openhwgroup/cva5/master/core/types_and_interfaces/cva5_config.sv)
- biRISC-V: "basic MMU support" with no hardware atomics. Linux boots with A instructions emulated in the bootloader. — [biRISC-V README](https://github.com/ultraembedded/biriscv)
- Shakti C-class: RV64GCSUN (including the N user-interrupt extension), Linux-capable. Its TLB and cache organization was not found in the retrieved pages. — [C-class docs](https://c-class.readthedocs.io/en/latest/intro.html)

#### Explicit FPGA-friendly and FPGA-hostile choices
- FPGA-hostile:
  - CVA6's flip-flop, fully associative, combinational TLBs: going to 64 entries costs about 50% more FPGA resources. — [Sá et al.](https://ar5iv.labs.arxiv.org/html/2302.02969)
  - CVA6's 8-way D$ tag compare and select on the critical path. — [Ariane paper](https://ar5iv.labs.arxiv.org/html/1904.05442)
  - OpenC906 needs over 100k LUT4s. — [LiteX commit mirror](https://software.mcgoron.com/Hardware/litex/commits/commit/577674bff230c2eb2da58dbbb9cc779647e81efe?page=19)
- FPGA-friendly:
  - Taiga/CVA5's heavy LUTRAM use and parallel variable-latency units. — [SFU record](https://summit.sfu.ca/item/35160)
  - CVA5's BRAM-sized cache guidance. — [cva5_config](https://raw.githubusercontent.com/openhwgroup/cva5/master/core/types_and_interfaces/cva5_config.sv)
  - biRISC-V's Xilinx-specific register-file option and extra decode stage. — [biRISC-V README](https://github.com/ultraembedded/biriscv)
  - MicroBlaze V's AMD-native implementation (258 MHz RV64 Linux configuration on ZU+). — [UG1629](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization)

### Inferences
- U74's two-level TLB is the most FPGA-transferable pattern among those documented: a small fully associative L1 TLB plus a large direct-mapped or set-associative L2 TLB that fits naturally in LUTRAM or BRAM. Pair it with a PTE cache (Rocket has 8 entries) and keep L1 TLBs at 8–16 entries to protect Fmax. CVA6's data shows FA TLB growth is the expensive dimension on FPGA.
- For a dual-core OoO with SMT hooks, three choices follow:
  - Tag TLB entries with ASID and, for future SMT, a thread ID. MicroBlaze V's 7-bit ASID shows vendors trimming ASID width; a design can do likewise.
  - Implement Sstc so the S-mode timer avoids M-mode traps. Sá et al. found negligible area cost.
  - Use a snoop-based MOESI/MESI coherence unit for two cores, as Culsans does (1.6% area). A directory protocol like BedRock is only warranted at 8 or more cores.
- AMO/LR-SC design pattern from these cores:
  - Execute AMOs non-speculatively at the head of the ROB, in the L1, on a line held exclusively, as CVA6 and BlackParrot do in the L1.
  - Size the reservation to one cache line, as CVA5 does.
  - Bound the LR hold time and add a short re-acquire block after SC, like Rocket's 3 cycles, for forward progress.
  - Do not rely on software emulation, as biRISC-V does.

### Gaps
- The following organizations were not available in the retrieved sources:
  - Rocket's PTW internals and AMO ALU placement (only parameter defaults were retrieved);
  - NutShell's TLB sizes;
  - OpenC906's uTLB sizes and non-blocking/MSHR details (the manual's Chinese text was garbled);
  - MicroBlaze V's TLB sizes and whether its walker is hardware or software;
  - Shakti C-class's cache and TLB organization;
  - BlackParrot's core pipeline, PTW and branch predictor.
- The full Culsans paper text was not retrieved (HTML 404); its numbers come from the search summary of the arXiv PDF.

## Q4. What are their pros/cons as references, and which lessons apply to an original 2-wide OoO RV64 core (dual-core, Linux, SMT/CMT hooks, KV260, must beat NaxRiscv)?

### Takeaway
- CVA6 (with CVA6S/CVA6S+) is the best-documented quantitative baseline, with published IPC, area and frequency for scalar vs dual-issue. It is FPGA-hostile: about 41k LUTs and about 50 MHz on Kintex-7.
- MicroBlaze V is the best FPGA-efficiency yardstick on the target device family: about 15k LUTs and 258 MHz for an RV64 Linux configuration on ZU+.
- U74/U84 manuals and announcements give the clearest published dual-issue in-order and 3-wide OoO design points.
- Rocket offers a mature Linux/SMP ecosystem and the vivado-risc-v Debian flow, but weak default predictor and MSHR parameters.
- BlackParrot and Culsans illustrate the coherence choices.
- NutShell contributes difftest-style verification and a ZynqMP board flow.
- biRISC-V shows how far careful in-order dual issue can push CoreMark (4.1/MHz).

The transferable lessons:
- model-driven design;
- dedicated write-back ports;
- same-cycle issue past predicted branches with partial squash;
- a real direction predictor not gated by BTB hits;
- a non-blocking, multi-MSHR, pipelined D-cache;
- LUTRAM/BRAM-shaped TLBs;
- snoop coherence for two cores;
- lockstep ISS co-simulation.

### Cited Findings

#### Pros/cons per core as a reference
- **CVA6/Ariane.**
  - Pros: open, industrially maintained (OpenHW), and Linux-capable. Strong published PPA data: Ariane tapeout figures, CVA6S/CVA6S+ IPC/area/Fmax, and a CF'25 energy study. A public performance model lives in the repo (perf-model/). Verification uses core-v-verif with UVM, riscv-dv, and Spike + Verilator. — [Ariane](https://ar5iv.labs.arxiv.org/html/1904.05442); [CF'25](https://arxiv.org/html/2505.24363v1); [CVA6 repo](https://github.com/openhwgroup/cva6)
  - Cons: about 41k LUTs (RV64GC) and about 50 MHz on Kintex-7 — [PERCIVAL](https://arxiv.org/pdf/2111.15286). Combinational FA TLBs are costly to scale — [Sá et al.](https://ar5iv.labs.arxiv.org/html/2302.02969). The legacy blocking write-back D$ — [CVA6S+](https://arxiv.org/html/2505.03762v2). The 8-entry ROB/scoreboard and 2-entry RAS — [CF'25](https://arxiv.org/html/2505.24363v1).
- **CVA6S/CVA6S+.**
  - Pros: a quantified dual-issue in-order step: +40% CoreMark (Allart), +43.5% Embench IPC (Tedeschi), +34.4% IPC (Fu), for about 6–11% area. — [Allart](https://arxiv.org/pdf/2410.01442); [Tedeschi](https://arxiv.org/html/2505.03762v2); [Fu](https://arxiv.org/html/2505.24363v1)
  - Cons: shared FPU/ALU2 write-back port causes regressions on FP code (nbody IPC 0.35 vs 0.47). — [Fu](https://arxiv.org/html/2505.24363v1). Linux with the speculative scoreboard was not yet demonstrated (2024). — [Allart](https://arxiv.org/pdf/2410.01442)
- **Rocket.**
  - Pros: mature Chisel generator; Debian on 1–8-core FPGA builds with recent Vivado (vivado-risc-v); about 27.5k LUTs per RV64 core. — [vivado-risc-v](https://github.com/eugene-tarassov/vivado-risc-v)
  - Cons: defaults include a 1-MSHR D$, a BHT that only predicts on a BTB hit, a 1-bit-counter BHT and a 2-cycle load-use for sub-word loads. — [BTB.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/BTB.scala); [HellaCache.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/HellaCache.scala); [RocketCore.scala](https://raw.githubusercontent.com/chipsalliance/rocket-chip/master/src/main/scala/rocket/RocketCore.scala). No ZU+ boards are in vivado-risc-v. — [vivado-risc-v](https://github.com/eugene-tarassov/vivado-risc-v)
- **Shuttle.**
  - Pros: a Rocket-based superscalar in-order core configurable to 2/3/4-issue, and tape-out proven.
  - Cons: explicitly not PPA-targeted, with no published numbers.
  — [Chipyard Shuttle](https://chipyard.readthedocs.io/en/main/generators/shuttle/)
- **BlackParrot.**
  - Pros: actively released (v2.1 Nov 2025); multiple tapeouts (12 nm/28 nm); scalable coherent multicore with a model-checked protocol; Linux 5.15 on 8 cores on FPGA. — [README](https://github.com/black-parrot/black-parrot); [dissertation](https://arxiv.org/html/2505.00962)
  - Cons: blocking L1 and L2, a 50 MHz FPGA clock, and no public CoreMark/IPC. — [dissertation](https://arxiv.org/html/2505.00962); [README](https://github.com/black-parrot/black-parrot)
- **NutShell.**
  - Pros: student-built RV64IMAC Linux/Debian core; taped out (110 nm); ZynqMP board flows (ZCU102/AXU3CG); difftest co-simulation. — [README](https://github.com/OSCPU/NutShell); [ithome](https://www.ithome.com/0/499/804.htm)
  - Cons: single-issue; Vivado 2019.1-era flows (stale); no published CoreMark, resource or Fmax figures. — [README](https://github.com/OSCPU/NutShell)
- **Shakti C-class.**
  - Pros: commercial-grade Bluespec generator with silicon prototypes and adopters (InCore, Mindgrove). — [C-class docs](https://c-class.readthedocs.io/en/latest/intro.html)
  - Cons: published numbers are old (2019) and internally inconsistent (6.5k vs <3k LUTs; 1.72 vs <1 DMIPS/MHz). — [2019 slides](https://riscv.org/wp-content/uploads/2019/12/12.11-14.20a5-Menon-IITMadras-Processor-IP-Showcase-with-Andes-Technology-CHIPS-Alliance-Codasip-Shakti-Project-SiFive-Syntacore-OpenHW-Group-4.pdf); [overview](https://shakti.org.in/docs/Shakti-Overview.pdf)
- **biRISC-V.**
  - Pros: compact dual-issue in-order with high CoreMark/MHz (4.1); clear configuration knobs (bypass options, gshare, RAS); RISCV-DV plus ISS co-simulation.
  - Cons: RV32 only, no hardware atomics, 37 commits with 34 open issues (low activity), and no FPGA numbers.
  — [README](https://github.com/ultraembedded/biriscv)
- **CVA5/Taiga.**
  - Pros: FPGA-first design (LUTRAMs, parallel variable-latency units, ID-based tracking). — [SFU](https://summit.sfu.ca/item/35160); [config](https://raw.githubusercontent.com/openhwgroup/cva5/master/core/types_and_interfaces/cva5_config.sv)
  - Cons: RV32 only, Linux boot unconfirmed, no published FPGA numbers. — [README](https://github.com/openhwgroup/cva5)
- **OpenC906.**
  - Pros: open RTL (Apache-2.0) of a shipping Linux SoC core (D1/BL808 class) with complete manuals (2024-06-27). — [repo](https://github.com/XUANTIE-RV/openc906)
  - Cons: 10 commits and a vendor toolchain dependency for tests — [repo](https://github.com/XUANTIE-RV/openc906). Needs over 100k LUT4s and was only simulation-booted in LiteX — [LiteX mirror](https://software.mcgoron.com/Hardware/litex/commits/commit/577674bff230c2eb2da58dbbb9cc779647e81efe?page=19).
- **MicroBlaze V.**
  - Pros: vendor-supported on all AMD families, including Zynq UltraScale+; RV64 Linux configuration at about 15k LUTs and 258 MHz on ZU9EG; ACE coherence port. — [UG1629](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Resource-Utilization); [Features](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Features)
  - Cons: closed RTL, no published IPC in UG1629 v2026.1, and only device-tree-level upstream Linux changes noted so far (Linux 6.8). — [Phoronix](https://www.phoronix.com/news/AMD-MicroBlaze-V-Linux-6.8)
- **SiFive U74/U84.**
  - Pros: detailed, authoritative U74 pipeline/BP/TLB manual (21G3.02.00); a U84 OoO design point with a quoted 2.3x IPC uplift over U74. — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf); [SiFive blog](https://sifive.com/blog/incredibly-scalable-high-performance-risc-v-core-ip)
  - Cons: closed; the U84 structure sizes are undisclosed. — [cnx-software](https://www.cnx-software.com/2019/10/26/sifive-u8-series-out-of-order-risc-v-core-ip-takes-on-arm-cortex-a72-core/)

#### Lessons documented by the sources
- Performance model first, accurate to under 1% against RTL on the target benchmark: it caught design errors early (dropping a low-value write-back port change; fixing scoreboard under-utilization and the same-cycle branch-issue gap). — [Allart](https://arxiv.org/pdf/2410.01442)
- Same-cycle issue past predicted-taken branches requires partial squash. The speculative-scoreboard fix closed most of the gap between the 12% achieved and the 21% predicted at that step. — [Allart](https://arxiv.org/pdf/2410.01442)
- Do not share write-back ports between a new ALU and a variable-latency unit. It created structural hazards and an FP regression in CVA6S+. — [Fu](https://arxiv.org/html/2505.24363v1); [Tedeschi](https://arxiv.org/html/2505.03762v2)
- Branch prediction pays even in small cores. A 128-entry two-level predictor cut mispredict penalty by 30–40% and gave +4.6% on Embench. — [Tedeschi](https://arxiv.org/html/2505.03762v2); [Fu](https://arxiv.org/html/2505.24363v1)
- Memory system: replacing the blocking cache with HPDCache gave +74.1% bandwidth, −19% D$ area and +13.5% Fmax. — [Tedeschi](https://arxiv.org/html/2505.03762v2)
- A late ALU in a dual-issue in-order pipeline removes load-use delay for most integer consumers (U74). A U84-class 3-wide OoO yields 2.3x U74 IPC. — [U74 manual](https://www.scs.stanford.edu/~zyedidia/docs/sifive/sifive-u74.pdf); [SiFive blog](https://sifive.com/blog/incredibly-scalable-high-performance-risc-v-core-ip)
- OoO is not inherently energy-inefficient: C910 surpasses the in-order cores in energy efficiency beyond a 500 MHz target, while CVA6S+ wins area efficiency. — [Fu](https://arxiv.org/html/2505.24363v1)
- Coherence:
  - Snoop-based MOESI for 2–4 cores is cheap (1.6% area) and faster than directory-based OpenPiton (up to +32.87% dual-core). — [Culsans](https://arxiv.org/pdf/2407.19895)
  - Directory protocols without transient states, with an FSM engine as default and microcode only for flexibility, scale to 16 or more cores. — [BedRock](https://arxiv.org/html/2505.00962)
- Verification:
  - difftest against NEMU (NutShell). — [NutShell](https://github.com/OSCPU/NutShell)
  - RISCV-DV plus ISS co-simulation (biRISC-V). — [biRISC-V](https://github.com/ultraembedded/biriscv)
  - UVM with riscv-dv and Spike (CVA6). — [CVA6](https://github.com/openhwgroup/cva6)
  - CMurphi model checking for coherence (BlackParrot). — [BedRock](https://arxiv.org/html/2505.00962)

### Inferences (applied to an original 2-wide-decode OoO RV64 dual-core on KV260)
- **IPC target framing.** CVA6S+ gives about 0.94 Embench IPC with 2-wide in-order issue and an 8-entry window; C910 gives 1.61 with 3-wide decode and a 64-entry ROB. A 2-wide OoO core should at least clear CVA6S+ by a wide margin. For CoreMark, biRISC-V's 4.1/MHz (RV32, TCM-friendly) and U74's about 5.1/MHz (secondary) show that well-tuned in-order dual issue is already strong. To be credibly OoO-class, the design likely needs at least 5–6 CoreMark/MHz on RV64 with realistic caches (inference). NaxRiscv's numbers come from the parallel researcher; compare on identical SoC, caches and compiler.
- **Front end.**
  - Decouple direction prediction from BTB hits; Rocket's default gates the BHT on a BTB hit.
  - Provide a RAS of at least 6–16 entries and a return/indirect predictor (U74 has an 8-entry IJTP and a 16-entry return predictor).
  - Size the BTB for LUTRAM (U74's 16-entry BTB is backed by a 3.6 KiB BHT; NutShell uses a 512-entry BTB).
  - Plan for 4–6 cycle mispredict penalties to grow in a deeper FPGA pipeline. The BP accuracy investment that gave CVA6S+ 30–40% lower penalties matters more for OoO.
- **Back end.**
  - Give each issue pipe its own write-back port (FPGA: replicated or banked LUTRAM physical register files).
  - Allow ALU-to-ALU same-cycle forwarding only if it is not on the critical path. At FPGA frequencies, prefer one-cycle-later bypass plus speculative wakeup.
  - Support partial squash by branch mask or ROB index; Allart's cancelled-bit approach is the in-order analog.
- **LSU/D$.**
  - Use a non-blocking, pipelined D$ with several MSHRs and a load/store queue. Rocket's default has 1 MSHR, BlackParrot's L1 is blocking, and legacy CVA6 was blocking; HPDCache's +74% bandwidth shows the stakes.
  - Keep associativity at 2–4 ways with pipelined tag/data (way-select was Ariane's critical path).
  - Expect a 2–3 cycle load-use and rely on OoO scheduling or speculative wakeup to hide it.
- **MMU.**
  - Use small fully associative L1 I/D TLBs (8–16 entries, LUT-based) plus a BRAM/LUTRAM set-associative or direct-mapped L2 TLB (U74 has 512 direct-mapped entries) and a PTE cache (Rocket has 8).
  - Avoid large FA TLBs, which cost about 50% more FPGA resources at 64 entries in CVA6.
  - Add ASID tags plus a thread-ID field reserved for future SMT.
- **Atomics and coherence for dual-core.**
  - Execute AMOs and SC at the ROB head in L1 on an owned line, with a cache-line reservation granule and a bounded LR timeout (CVA5 and Rocket patterns).
  - Use a lightweight snoop-based MOESI/MESI unit between the two cores' L1s and a shared L2 (Culsans-like).
  - A directory protocol (BedRock) is unnecessary at two cores but is a template if CMT scaling is planned.
- **Interrupts.** Use standard CLINT/ACLINT plus PLIC, as in U74 and C906, and implement Sstc (cheap per Sá et al.) to cut M-mode timer trap overhead under Linux.
- **FPGA timing realism.** MicroBlaze V shows an AMD-tuned single-issue RV64 Linux core reaching 258 MHz on ZU+, while ASIC-style open cores sit at 50–100 MHz on 7-series. Set an Fmax target early (for example 150–200 MHz on XCK26), pipeline the TLB, D$ and wakeup/select loops for it, and budget at most about 40–50k LUTs per core so two cores plus the L2 and uncore fit (all inferences; verify the XCK26 budget).
- **Verification and methodology.**
  - Adopt a cycle-approximate performance model validated against RTL traces (Allart's three-level comparison).
  - Run lockstep commit-trace co-simulation against an ISS (difftest/Spike) with RVFI-like trace output.
  - Use riscv-dv random streams.
  - Model-check the coherence protocol (CMurphi-style) before RTL.
  - Bring up on the KV260 using a ZynqMP PS-boot flow, as NutShell's ZCU102/AXU3CG flows do, and use MicroBlaze V and Cheshire/CVA6 on ZU+ as same-board A/B baselines.

### Gaps
- No public per-structure FPGA breakdown (LUTs for TLB, D$, scoreboard) of CVA6 or Rocket on UltraScale+ was found, so the per-core LUT budget above is an inference.
- No SMT/CMT implementations exist among these baselines; MicroBlaze V offers lockstep, not SMT. SMT hook guidance is therefore inferred rather than sourced.
- No head-to-head of these cores against NaxRiscv on the same FPGA was found in this scope; the parallel NaxRiscv research covers that.
- Chips and Cheese coverage of U74 or C906 was not found in searches.
