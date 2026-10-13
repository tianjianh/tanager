# IPC levers, published scores, benchmarking pitfalls and pre-RTL DSE for a 2-wide-decode OoO RV64 FPGA core (KV260)

Research date: 2026-10-12. All "retrieved" dates below are 2026-10-12. Numbers are vendor- or author-reported unless stated otherwise. The web-search budget for this session ran out partway through, so several sensitivity curves listed under Gaps could not be retrieved. Where a number comes only from a search-engine summary and not from the primary document itself, it is marked "(secondary/unverified)".

---

## 1. How sensitive is IPC to each microarchitectural feature, and which levers matter most for a small (2-wide) OoO RV64 core?

### Takeaway
Most of the published, quantified IPC gains for small and medium open RISC-V OoO cores come from four places. First, the branch/frontend path: a TAGE-class predictor, a single-cycle L0/micro-BTB, RAS repair, and short-forward-branch predication. Second, short ALU and load-to-use latencies. Third, a working memory-dependence predictor. Fourth, a non-blocking memory system whose evictions do not stall refills. Raw window size (ROB/IQ/PRF/LSQ) matters less at 2-wide, and published sweeps for 2-wide cores are scarce. NaxRiscv, the baseline to beat, uses only a 4 KB gshare, a 512-entry direct-mapped BTB, a 32-entry unified non-compacting issue queue, 64 physical registers and 16 KB L1s. Those choices leave clear headroom on the branch-prediction, issue-queue and cache levers.

### Cited Findings

#### Baseline to beat: NaxRiscv configuration and measured IPC
- NaxRiscv "RV32 A" configuration: RV32IMASU, OoO, Linux-capable; 64-bit fetch, 2 decode, 3 issue, 2 retire; shared 32-entry issue queue; 64 physical registers; 3 execution units (2x Int/Shift/Branch, 1x load/store/mul/div/csr/env); 16-entry LQ, 16-entry SQ; load-hit predictor giving 3-cycle load-to-use; store-to-load bypass; I$ 16 KB 4-way; D$ 16 KB 4-way with 2 refill and 2 writeback slots; ITLB/DTLB 192 entries 6-way; BTB 512 entries 1-way; GSHARE 4 KB; RAS 32 entries — [NaxRiscv Performance and Area docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- Measured IPC for RV32 A: Dhrystone 1.65, CoreMark 1.28, Embench-iot 1.42. Results are 2.93 DMIPS/MHz, 5.02 CoreMark/MHz and 1.67 Embench, on 13.3K LUT / 10.3K FF / 12 BRAM / 4 DSP at 155 MHz on Artix-7 speed grade 3. Simulated with Verilator (`VNaxRiscv`); the docs give no compiler version or memory-latency model — [NaxRiscv Performance and Area docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- RV64 NaxRiscv (2x Int/Shift/Branch + 1x LSU/mul/div/csr): 2.94 DMIPS/MHz (-O3 -fno-common -fno-inline), 4.94 CoreMark/MHz (-O3, "u32 as s32 and many other flags"), Embench 1.84 (-O2 -ffunction-sections), on 17.9K LUT, 12.5K FF, 12 BRAM, 16 DSP at 137 MHz. No IPC figure is given — [NaxRiscv Performance and Area docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- The author's own sensitivity notes:
  - An OoO core without branch prediction "is performing really bad".
  - A larger GSHARE or a TAGE predictor should help.
  - A 2-cycle ALU latency (tried in anticipation of RV64 timing) appeared to cost about 15%, but needs verification on more benchmarks.
  - Adding more execution units quickly hits diminishing returns.
  - Keeping stores from waiting for store data in the issue queue helps avoid bad load speculation.
  - [NaxRiscv Performance and Area docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- NaxRiscv's stated design goal is low area and high Fmax on FPGA distributed RAM; the docs say it is "not the best IPC" — [NaxRiscv introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)
- NaxRiscv issue-queue organization:
  - Unified, laid out as a 2D array with decodeCount columns. Each dispatch push consumes a whole row, and empty slots are not compacted, so effective occupancy drops when fewer than 2 instructions dispatch in a cycle.
  - Dependencies are tracked in a half-matrix; select is oldest-first; wakeup uses ROB IDs.
  - The author suggests about 32 slots as the practical timing limit.
  - Rename uses speculative and committed map tables plus a location table that is cleared on mispredict, giving instant rename recovery.
  - [NaxRiscv frontend/dispatch docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html)
- NaxRiscv register file: banked dual-port RAMs, one bank per write port, with an XOR-based live-value table to pick the correct bank on each read. This is the FPGA-friendly way to get multi-port register files — [NaxRiscv backend docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html)

#### Issue width vs decode width (same-family ablations)
- NaxRiscv RV32 ablations:
  - A (2-decode, 2 int ALUs + shared EU): 5.02 CoreMark/MHz, 2.93 DMIPS/MHz, 1.67 Embench.
  - B (only one int ALU, branch on a shared pipe): 4.44 CoreMark/MHz, 2.71 DMIPS/MHz, 1.46 Embench.
  - C (1 decode, 1 ALU, 1 shared EU): 3.35 CoreMark/MHz, 1.70 DMIPS/MHz, 1.06 Embench.
  - [NaxRiscv Performance and Area docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- BOOM 2-wide vs 4-wide CoreMark/MHz: 3.91 vs 4.7, as plotted in T-Head's Hot Chips 2020 slide. The slide cites Celio's 2018 Berkeley thesis (EECS-2018-151) as its data source. The same chart gives Rocket 2.32, "NXF" 3.22, SweRV 4.9, Syntacore SCR7 5.0, SiFive U74 5.1 and Xuantie-910 7.1 — [Xuantie-910 Hot Chips 2020 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf)
- CVA6 (in-order) scalar to dual-issue: 3.10 to 4.35 CoreMark/MHz (+40%) for about +11% area and +7% power — [Allart et al., arXiv 2410.01442](https://arxiv.org/abs/2410.01442) (the abstract gives +40% and 99.2% model accuracy; the absolute 3.10/4.35 and the area/power figures come from the paper text as quoted in search results — secondary/unverified)
- CVA6S+ (dual-issue plus a better branch predictor, register renaming and HPDCache): +43% IPC over scalar CVA6 and +11% over CVA6S on Embench-IoT — [CVA6S+ arXiv HTML](https://arxiv.org/html/2505.03762v2) (secondary/unverified; read only via summaries)
- VexiiRiscv, an in-order core with single or dual (optionally asymmetric) issue per its [README](https://github.com/SpinalHDL/VexiiRiscv): headline config is max IPC 2, issue 2, late ALU, BTB 512/RAS 4, GShare 4 KB, giving 2.50 DMIPS/MHz and 5.24 CoreMark/MHz. That CoreMark/MHz is higher than OoO NaxRiscv's 5.02. Single-issue configs: rv32im 1.20 / 2.70; with branch prediction 1.45 / 2.99; "ipcMax lateAlu" 1.74 / 3.41 (DMIPS/MHz / CoreMark/MHz). The ipcMax lateAlu config drops Artix-7 Fmax to 140 MHz, versus about 190-210 MHz for the other configs — [VexiiRiscv performance docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)
- Xuantie C910: decodes 3 instructions/cycle, renames 4 micro-ops/cycle, and issues to 8 ports (2 ALU, 1 branch, 3 memory, plus FP/vector) — [Chips and Cheese, C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910); "3-decode, 8-issue", fetch of 8 instructions/cycle — [Hot Chips 2020 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf)

#### Branch direction prediction (bimodal/gshare vs TAGE vs TAGE-SC-L, 8-64 KB)
- CBP-5 (2016) winner TAGE-SC-L: 4.991 MPKI at 8 KB and 3.986 MPKI at 64 KB on the CBP-5 training traces. Storage breakdown:
  - 8 KB total 67,349 bits: TAGE 58,165 bits with a 1000-bit global history, loop predictor 312 bits (8 entries), statistical corrector 8,872 bits.
  - 64 KB total 523,355 bits: TAGE 463,917 bits with a 3000-bit global history, loop predictor 1,248 bits (32 entries), statistical corrector 58,190 bits.
  - [Seznec, CBP-2016](https://jilp.org/cbp2016/paper/AndreSeznecLimited.pdf)
- Component value in the same paper:
  - The statistical corrector brings about 6% misprediction reduction at 8 KB and about 8% at 64 KB. The loop predictor brings about 0.3%.
  - Bank-interleaving plus partial associativity give 2-3% each.
  - The championship entries use an "unrealistic number of tables"; simpler designs with far fewer tables reach accuracy "in the same range".
  - At small budgets, accuracy comes mainly from more or larger TAGE tables.
  - [Seznec, CBP-2016](https://jilp.org/cbp2016/paper/AndreSeznecLimited.pdf)
- Intel study (Lin & Tarsa 2019), ChampSim, Skylake-like baseline, 8 KB TAGE-SC-L, SPECint2017:
  - Mean accuracy 0.952.
  - Removing all mispredictions would raise IPC by 18.5% at 1x pipeline scale and by 55.3% at a 4x-scaled pipeline.
  - Growing TAGE-SC-L from 8 KB to 64 KB yields only 2.7% more IPC, best case with no added latency.
  - Hard-to-predict branches cause 55.3% of mispredictions per 30M-instruction slice.
  - [Lin & Tarsa, "Branch Prediction Is Not a Solved Problem"](https://ar5iv.labs.arxiv.org/html/1906.08170)
- SonicBOOM: the "most significant contribution to overall core performance" was a TAGE predictor with a speculatively updated and repaired global history. BOOMv2's banked ICache feeding an unbanked predictor effectively halved predictor capacity through aliasing — [SonicBOOM, CARRV 2020](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Open OoO cores compared in SonicBOOM's Table 1 (SPEC06 IPC / predictor):
  - SonicBOOM: 0.86, TAGE.
  - BOOMv2: 0.42, GShare.
  - riscy-OOO: 0.48, tournament.
  - RSD: N/A, GShare.
  - Many other changes differ between these cores, so this is not a clean predictor ablation — [SonicBOOM, CARRV 2020](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- C910 predictor, about 17.3 KB in total:
  - Bi-mode conditional predictor: 1024-entry selector, two 16K-entry 2-bit tables, 22-bit global history.
  - 12-entry return stack and 256-entry indirect target array.
  - BTB: 1024 entries 4-way, plus a 16-entry fully associative L0 BTB.
  - Chips and Cheese flags the small predictor as struggling with many branches.
  - [Chips and Cheese, C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- VexiiRiscv: adding branch prediction to rv32im raises Dhrystone from 1.20 to 1.45 DMIPS/MHz (+21%) and CoreMark from 2.70 to 2.99 CoreMark/MHz (+11%) — [VexiiRiscv performance docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)

#### Frontend: L0/micro-BTB, BTB, RAS, indirect, decoupled frontend / FTQ, I-cache misses
- SonicBOOM added a small fully associative micro-BTB ("next-line predictor", "L0 BTB") that redirects in one cycle. This removed BOOMv2's minimum 2-cycle redirect penalty, "drastically improving fetch throughput on small loops" — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- C910 taken-branch latency: about 1 cycle from the L0 BTB, about 2 cycles from the main BTB, and about 4 cycles for branches not in the BTB — [Chips and Cheese, C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- A flip-flop-based fully associative BTB tops out at about 40 entries (BOOMv1). BOOMv2 moved to a set-associative 64x4 BTB targeting single-ported SRAM — [BOOMv2, CARRV 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- RAS: SonicBOOM snapshots and repairs the RAS and loop predictor on misprediction. This gives 10x fewer return mispredictions than BOOMv2's unrepaired RAS, and 98% accuracy on `ret` — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- RAS depths in practice:
  - NaxRiscv: 32 entries — [NaxRiscv docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
  - VexiiRiscv: 4 entries — [VexiiRiscv docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)
  - C910: 12 entries — [Chips and Cheese](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
  - The BOOM-Explorer design space sweeps RAS over 16/24/32 entries — [BOOM-Explorer, ICCAD 2021](https://www.cse.cuhk.edu.hk/~byu/papers/C122-ICCAD2021-DSE-BOOM.pdf)
- Branch resolution: SonicBOOM added multiple branch-resolution units (superscalar branch resolution). This raised branch-to-branch latency to 12 cycles but improved overall performance because more branches could be scheduled — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- An L1 I-cache miss on the fetch path inserts at least a 10-cycle bubble in SonicBOOM, "equivalent to a branch misprediction" — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Decoupled frontend: XiangShan's second generation (Nanhu) introduced a "new frontend: decoupled BP and instruction fetch", along with instruction fusion, move elimination and hybrid L2/L3 prefetchers — [XiangShan MICRO 2025 tutorial slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- FDIP literature:
  - PDIP (ASPLOS 2024) builds on FDIP and adds up to 5.1% IPC (cassandra) and a 3.2% geomean across 16 benchmarks with a 43.5 KB budget — [PDIP](https://collaborate.princeton.edu/en/publications/pdip-priority-directed-instruction-prefetching/) (secondary/unverified)
  - FDIP-X argues FDIP's effectiveness depends on a BTB large enough to hold the branch working set — [FDIP Revisited, arXiv 2006.13547](https://arxiv.org/pdf/2006.13547) (secondary/unverified)
- C910 frontend sustains about 3 IPC when code fits its 64 KB L1i, but drops below 1 IPC when code comes from L2 — [Chips and Cheese, C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)

#### Pipeline depth, frequency and misprediction penalty
- BOOMv2 vs BOOMv1:
  - Cycle time fell from 65 FO4 to 50 FO4 after place-and-route (-24%).
  - CoreMark IPC dropped by up to 20%. "Over half" of the drop came from the increased latency between loads and their dependents.
  - Making rename and register-read depth configurable lets designers recover most of the lost IPC at the cost of a longer clock period.
  - The 20-entry unified issue window with 3 issue ports was found too aggressive for timing and was replaced by three distributed 16-entry windows (integer, memory, FP).
  - [BOOMv2, CARRV 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- Pipeline depths of reference cores:
  - C910: 12 stages — [Chips and Cheese](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
  - XiangShan Yanqihu: 11 stages — [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
  - Cortex-A53: 8 stages, in-order 2-wide; Cortex-A72: 15 stages, 3-wide OoO; Cortex-A76: 11-13 stages, 4-wide OoO — [Wikipedia, Comparison of ARMv8-A processors](https://en.wikipedia.org/wiki/Comparison_of_ARMv8-A_processors)
- The misprediction penalty has two parts: front-end refill, plus the time to resolve the branch. The second part grows when branch operands depend on long-latency (missing) loads — [Kumar, Jain, Chaudhuri](https://cse.iitk.ac.in/users/mainakc/pub/p9-kumar.pdf) (secondary/unverified). The classic characterization is Eyerman, Smith & Eeckhout, "Characterizing the branch misprediction penalty", ISPASS 2006 — [bibliographic entry](https://research.cs.wisc.edu/arch/uwarch-wiki2/index.php/PubsUWArch/B2hd-DBLPconfispassEyermanSE06); full text not retrieved.

#### Window resources: ROB, issue queue, physical registers, LQ/SQ
- C910:
  - ROB is 64 entries in the source code; T-Head claims up to 192, and microbenchmarks agree with 192.
  - 64 integer physical registers are available for in-flight results (plus 32 architectural) and 32 FP.
  - Integer scheduler for common ALU ops has 16 entries, versus 40 on SiFive P550 and 30 on Goldmont Plus.
  - Integer register file has 10 read ports.
  - LQ is possibly 12 entries.
  - Chips and Cheese lists "small schedulers and register files relative to the 64-192 entry ROB" as a bottleneck.
  - [Chips and Cheese, C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- BOOM-Explorer design space:
  - FetchWidth 4/8; fetch buffer 8-40 entries; RAS 16/24/32; I$ ways 2/4/8; physical registers 48-112; LDQ/STQ 8-32 (constrained equal); D$ MSHRs 2/4/8.
  - The ROB must be divisible by decode width.
  - About 1.6x10^8 legal designs after pruning.
  - Evaluated with RTL simulation (clock cycles) plus a commercial VLSI flow (power).
  - [BOOM-Explorer, ICCAD 2021](https://www.cse.cuhk.edu.hk/~byu/papers/C122-ICCAD2021-DSE-BOOM.pdf)
- Window-size reasoning from SonicBOOM:
  - "the speculation depth in SonicBOOM cannot hide misses beyond L1".
  - With L3 hits around 50 cycles, a 4-wide BOOM would need about 200 instructions in flight, which exhausts the ROB.
  - Hence prefetchers are "vital".
  - [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- The store-sets study sized its instruction queue at 128 entries by doubling the IQ "until no further performance could be gained" on an 8-issue machine. This is old (SPEC95, Alpha), but it shows the method: sweep in powers of two to the knee — [Chrysos & Emer, ISCA 1998](https://acg.cis.upenn.edu/milom/cis501-Fall10/papers/store-sets.pdf)

#### Load-to-use and ALU latency
- Over half of BOOMv2's up-to-20% CoreMark IPC loss came from longer load-to-dependent latency — [BOOMv2](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- NaxRiscv: 2-cycle ALU latency costs about 15% (preliminary). It reaches 3-cycle load-to-use with a speculative cache-hit predictor — [NaxRiscv perf docs](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html), [NaxRiscv intro](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)
- C910: 3-cycle load-to-use and 1-cycle store execution — [Hot Chips 2020 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf). L1D latency is 3 cycles; a failed store-to-load forward costs 20+ cycles — [Chips and Cheese](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- VexiiRiscv's "lateAlu" (an extra ALU stage late in the pipeline) raises IPC but cuts Artix-7 Fmax from about 195-210 MHz to 140 MHz — [VexiiRiscv docs](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html)

#### Memory system: L1 D-cache, MSHRs/line-fill buffers, L2, prefetchers
- Rocket's L1D, as reused in BOOMv1/v2:
  - Only 1-wide.
  - Could not refill speculatively without polluting the cache.
  - Blocked refills during eviction, so an L2 access of 14 cycles was observed as 24 cycles from the core.
  - SonicBOOM's new L1D refills into line-fill buffers, so evictions overlap refills. Refills, upgrades, writebacks, prefetches and probes each have their own state machines.
  - The cache is even/odd banked from 1R1W SRAMs, supporting 2 loads or 1 store per cycle.
  - [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- SonicBOOM adds a small next-line prefetcher between L1 and L2, filling into line-fill buffers. The authors say a more robust outer-memory prefetcher is still needed — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- C910 memory hierarchy:
  - 64 KB 2-way L1D with 8 line-fill buffers.
  - L2 latency is 60 cycles (about 32 ns at 1.85 GHz), with no mid-level cache; Chips and Cheese calls this a bottleneck.
  - DRAM latency is 133.9 ns.
  - [Chips and Cheese, C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
  - "Multi-mode, multi-stream" prefetching on both virtual and physical addresses — [Hot Chips 2020 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf)
- Prefetcher speedups over no prefetching (ChampSim, memory-intensive SPEC CPU2017 traces; arXiv preprint of modest rigor):
  - L1D-centric: MLOP 38%, T-SKID 40%, their switching scheme 44.29%.
  - L2-centric: SPP 35.1%, next-line (degree 5) 32.6%, IP-stride (degree 8) 31.89%.
  - Storage: next-line 0 KB, IP-stride 5.47 KB, SPP 5.73 KB, MLOP 12 KB.
  - [Arsenal of Hardware Prefetchers, arXiv 1911.10349](https://arxiv.org/abs/1911.10349)
- Best-Offset prefetching (Michaud, HPCA 2016) selects the offset by timeliness. The abstract reports that it outperforms the Sandbox prefetcher on SPEC CPU2006 "with equally simple hardware" — [HAL hal-01254863](https://hal.archives-ouvertes.fr/hal-01254863) (abstract-level only; full text was blocked by bot protection)

#### Memory dependence prediction
- With no load speculation, some SPEC95 programs ran 2x or more slower than with perfect dependence prediction. Naive speculation also caused "significant" degradation from squashes. Store sets achieved "near-optimal" performance with a low-cost direct-mapped SSIT/LFST. Without store-set merging, 12% average performance was lost. The setup was 8-issue, 128-entry IQ, Alpha ISA — [Chrysos & Emer, Store Sets, ISCA 1998](https://acg.cis.upenn.edu/milom/cis501-Fall10/papers/store-sets.pdf)
- C910 lists "speculation fail prediction" in its LSU and uses an independent store-data pipeline — [Hot Chips 2020 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf)
- XiangShan's simulator-calibration work used the Store Set predictor as its showcase "tightly coupled feature": Cliff-guided calibration cut its relative error by 48.03%. Store sets are therefore a standard component of XiangShan's model — [Microarchitecture Cliffs, arXiv 2602.11580](https://arxiv.org/abs/2602.11580)

#### Macro-op fusion, short-forward-branch predication, move elimination, Zba/Zbb/Zbs
- Celio et al. 2016 (SPEC CINT2006, gcc 5.3 -O3 -static; RV64GC built with -mrvc -mno-save-restore):
  - RV64G executes 16% more dynamic instructions than x86-64, 3% more than IA-32, 9% more than ARMv8 and 4% fewer than ARMv7.
  - RV64G's count is within 2% of x86-64's retired micro-op count.
  - RV64GC fetches 8% fewer dynamic instruction bytes than x86-64.
  - Fusion cuts the effective instruction count by 5.4% on average, meaning 10.8% of instructions sit in a fused pair.
  - Half the benchmarks gain less than 2%, three gain about 10%, and 401.bzip2 gains nearly 20%.
  - 57% of fusion pairs were found only by manual inspection, because the fusion-unaware compiler splits pairs during register allocation.
  - [Celio et al., arXiv 1607.02318](https://arxiv.org/abs/1607.02318)
- Celio Table IV, average % reduction in effective instruction count by idiom:
  - Indexed load (add + ld): 2.44.
  - Clear-upper-word zero-extend (slli 32 + srli 32): 0.53.
  - Load-effective-address (slli 1/2/3 + add): 2.24.
  - Per-benchmark macro-op/instruction ratios: bzip2 0.81 (8.55 / 5.58 / 4.67 for the three idioms), h264ref 0.89, sjeng 0.90, astar 0.91 (LEA 6.05), gobmk 0.94, mean 0.95.
  - LUI-based idioms are under 1% in SPECint; AUIPC idioms are rare.
  - Other candidate pairs: MULH+MUL, DIV+REM, load-pair/store-pair (needs 2 register-file write ports or 3 read ports), post-indexed load (needs 2 write ports).
  - [Celio et al. PDF](https://arxiv.org/pdf/1607.02318)
- LLVM RISC-V fusion features:
  - zexth-fusion (slli 48 + srli 48), zextw-fusion (slli 32 + srli 32), and shifted-zextw (slli 32 + srli <32).
  - Ventana Veyron V1 enables LUI+ADDI, AUIPC+ADDI, the zero-extension fusions, and LD+ADD.
  - The PR notes that the zexth/zextw fusions are reusable for XiangShan, citing XiangShan's decode documentation.
  - [LLVM PR #76032](https://github.com/llvm/llvm-project/pull/76032)
- XiangShan Nanhu added "instruction fusions, move elimination" in its improved backend — [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- Short-forward-branch (SFB) predication: SonicBOOM detects a data-dependent branch over a short block and turns it into a "set-flag" micro-op that writes a renamed predicate register, plus conditional-execute micro-ops. The result is up to 1.7x IPC on some code sequences, and 6.15 CoreMark/MHz with SFB vs 4.9 without (+25.5%) — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- XiangShan's published SPEC estimates use RV64GCB binaries: Nanhu with GCC 10.2.0 -O2, and Kunminghu with GCC 12 -O3 plus jemalloc. Its current reporting therefore assumes bitmanip-enabled code — [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)

### Inferences
- **The NaxRiscv gap is mostly in the frontend and predictor.**
  - NaxRiscv's RV32 CoreMark IPC is 1.28 on a 2-decode/3-issue machine, with a 4 KB gshare and a 512-entry 1-way BTB.
  - CBP data put 8 KB TAGE-SC-L at 4.991 MPKI and 64 KB at 3.986. Lin & Tarsa show 8 KB to 64 KB buys only 2.7% IPC even on a Skylake-class core.
  - So the sweet spot for an FPGA 2-wide core is roughly an 8-16 KB TAGE-lite: about 4-6 tagged tables, a small statistical corrector, and a loop predictor. This fits BRAM well and should cut mispredictions substantially versus a 4 KB gshare. The exact gshare-vs-TAGE delta at equal budget was not retrieved (see Gaps), so it must be measured.
- **Convert CoreMark/MHz to IPC to compare like with like.** At 5.02 CoreMark/MHz and IPC 1.28, NaxRiscv executes about 1.28e6 / 5.02 ≈ 255k dynamic instructions per CoreMark iteration (RV32IM, their compiler).
  - The same identity works for any core: IPC = (CoreMark/MHz) × (instructions per iteration) / 1e6.
  - Zba/Zbb, fusion and different compilers change instructions per iteration. "Beat NaxRiscv IPC" should therefore be stated as either (a) higher IPC on the same binary, or (b) higher iterations/MHz on the same source and compiler.
- **Prioritized IPC lever list.** It is ordered by evidence of gain per FPGA cost for a 2-wide-decode OoO RV64 core on KV260. Each item is a starting hypothesis to sweep in DSE, not a validated result.
  1. **Direction predictor upgrade (gshare-4KB to TAGE-lite 8-16 KB, speculative history with repair).** Strongest published lever: it was SonicBOOM's largest single contributor, and NaxRiscv's author names it as the next step. Mispredictions are an 18.5% IPC opportunity even with 8 KB TAGE-SC-L on a wide core, and that opportunity grows with window size. Cost is BRAM plus a multi-cycle predictor pipeline, so pair it with a 1-cycle L0 BTB for back-to-back taken branches.
  2. **Short-forward-branch predication (or a branch-plus-one-instruction fusion).** It gave +25% CoreMark/MHz on SonicBOOM. It is cheap: a predicate rename and a conditional-move micro-op. Its benefit on SPEC-like code is not quantified (see Gaps), so treat the CoreMark gain as an upper bound.
  3. **Keep 1-cycle ALU and 3-cycle (ideally 2-cycle) load-to-use with speculative wakeup and replay.** NaxRiscv measured 2-cycle ALU at about -15%, and over half of BOOMv2's -20% CoreMark IPC loss came from load-to-use. On FPGA this conflicts with Fmax, so judge by IPC × Fmax, not IPC alone. BOOMv2's 1.30x frequency × 0.80 IPC nets only about +4% (inference from cited figures).
  4. **Frontend plumbing.**
     - A 16-32 entry L0/micro-BTB for 1-cycle redirects (C910: 16 entries; BOOMv1 found about 40 to be the flip-flop limit).
     - A 512-1K-entry set-associative main BTB.
     - A RAS of 16-32 entries with checkpoint repair (10x fewer return mispredictions).
     - A small indirect predictor (C910 uses 256 entries), since Linux and interpreters use many indirect calls.
     - A decoupled BPU with a fetch-target queue that enables FDIP-style I-cache prefetch, as XiangShan Nanhu does.
  5. **Memory-dependence prediction (store sets or a cheaper store-wait table).** Store sets get near-ideal results, while no speculation can cost 2x on some programs. NaxRiscv's note on store-data waiting suggests its current scheme is simpler.
  6. **Non-blocking L1D with refill/eviction overlap (line-fill buffers) and 4-8 MSHRs.** Add next-line plus IP-stride prefetchers at L1D/L2, and an L2 at a sensible latency.
     - Rocket's blocking eviction turned a 14-cycle L2 into 24 cycles.
     - Simple next-line and IP-stride prefetchers capture most of the gain of complex ones on memory-intensive traces (32-35% vs 38-44%).
     - NaxRiscv has only 2 refill slots and 16 KB L1s, so this is a likely gap on SPEC-like workloads, though it is invisible on CoreMark.
  7. **Compile with Zba/Zbb and fuse the leftover idioms.**
     - Zba's shNadd and add.uw/zext.w directly replace Celio's LEA (2.24%) and clear-upper-word (0.53%) idioms. That is about 2.8% fewer dynamic instructions on SPECint2006-era code (inference from Table IV).
     - Indexed-load fusion (add + ld) is worth about 2.4%, and LUI/AUIPC+ADDI fusion and zext.h/zext.w fusion are cheap decode pattern matches.
     - Fusion that shortens dependence chains also improves IPC. Fusion that only merges independent operations mainly saves rename and ROB bandwidth, which matters at 2-wide.
  8. **Issue ports beyond decode width.** NaxRiscv's second integer ALU is worth +13% CoreMark/MHz (config A vs B). BOOM 2-wide to 4-wide gave +20%, and NaxRiscv says more units quickly hit diminishing returns. So 2-decode with 3-4 issue ports (2 ALU incl. branch, 1 load, 1 store or AGU, plus a shared mul/div) is the efficient point.
  9. **Window sizing.** As starting points for DSE (inference): ROB 64-96, integer PRF about 96 for RV64, IQ either about 32 unified with row compaction or split int/mem queues of about 16 each, and LQ/SQ 16-24.
     - NaxRiscv's non-compacting 32-slot IQ wastes slots whenever fewer than 2 instructions dispatch, so compaction or split queues can raise effective window size at the same LUT count.
     - On an FPGA, DRAM latency in core cycles is small (see Q3), so large windows buy less than on an ASIC.
  10. **Move elimination (mv = addi rd,rs,0 handled at rename) and zero-idiom handling.** XiangShan Nanhu implemented move elimination, but no quantified RISC-V gain was found. Because RISC-V hard-wires x0, classic x86 zero-idiom elimination has little to do. Low priority until profiling shows rename or ALU bandwidth limits.
- **SMT/CMT hooks.** SweRV EH2 reports 6.3 CoreMark/MHz versus EH1's 4.9 by adding a second hardware thread (see Q2). For a dual-core with SMT hooks, the cheapest throughput lever after the above is a second thread context sharing the frontend and backend. It should be reported as throughput, not single-thread IPC.

### Gaps
- No published sweep of ROB, IQ, PRF and LQ/SQ sizes for a 2-wide OoO RISC-V core was retrieved. BOOM-Explorer defines the space but its text available to me gives no per-parameter sensitivities. The classic Plackett-Burman parameter-ranking study (Yi/Lilja/Hawkins, HPCA 2003) and Michaud's square-root law could not be fetched before the search budget ran out. These must come from our own DSE.
- No equal-budget gshare vs TAGE MPKI table (SPEC or CoreMark) was retrieved, and no CoreMark-specific MPKI data was found. A 2025 paper reportedly achieves 3.47 MPKI on CBP-2025 traces with 192 KiB, 7.4% better than the 2016 64 KiB winner, but this was not verified. A summary of the LDBP paper says 64 KB to unlimited TAGE only cuts MPKI from 3.986 to 2.596 ([arXiv 2009.09064](https://arxiv.org/pdf/2009.09064), secondary/unverified, budget unit ambiguous).
- ITTAGE gains, BTB-size curves, RAS-depth curves, MSHR-count curves, L1/L2 size and associativity curves, and BOP's exact SPEC speedups were not retrieved. The BOP paper was blocked by HAL's bot protection.
- No quantified IPC gain was found for move elimination, zero-idiom elimination, or Zba/Zbb/Zbs on SPEC dynamic instruction counts. A 2022 XiangShan bitmanip-plus-fusion paper ("Accelerate bit manipulation in XiangShan processor using RISC-V B extension and instruction fusion", ten new fusion targets) was identified but not read.
- XiangShan's own decode-stage fusion list (docs.xiangshan.cc frontend/decode) redirected and was not retrieved. The industry fusion list above comes from LLVM. SiFive 7-series fusion details were not retrieved.
- NaxRiscv's ROB size, misprediction penalty and pipeline depth are not stated on the docs pages fetched.

---

## 2. Published CoreMark/MHz and DMIPS/MHz for RISC-V and Arm cores (with sources, compiler, flags, date)

### Takeaway
Per-MHz scores for open and commercial RISC-V cores span about 2.3-7.1 CoreMark/MHz and about 1.2-3.9 DMIPS/MHz. Out-of-order cores do not dominate CoreMark: VexiiRiscv, which is in-order dual-issue, claims 5.24 CoreMark/MHz, above OoO NaxRiscv's 5.02. Most numbers are vendor-reported without full compiler and flag disclosure, several are simulated, and some conflict between sources. Treat the table as context, not as a ranking.

### Cited Findings

#### RISC-V cores (retrieved 2026-10-12)

| Core (class) | CoreMark/MHz | DMIPS/MHz | Other | Compiler / flags / conditions | Date of claim | Source | Flags |
|---|---|---|---|---|---|---|---|
| NaxRiscv RV32 "A" (OoO, 2-dec/3-issue) | 5.02 | 2.93 | Embench 1.67; IPC 1.65 / 1.28 / 1.42 (Dhry / CoreMark / Embench) | Verilator sim; compiler version not stated | docs current at retrieval | [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) | Memory model in sim unstated |
| NaxRiscv RV32 "B" (one int ALU) | 4.44 | 2.71 | Embench 1.46 | as above | as above | [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) | |
| NaxRiscv RV32 "C" (1-decode) | 3.35 | 1.70 | Embench 1.06 | as above | as above | [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) | |
| NaxRiscv RV64 | 4.94 | 2.94 | Embench 1.84; 137 MHz, 17.9K LUT on Artix-7 | Dhrystone -O3 -fno-common -fno-inline; CoreMark -O3, "u32 as s32 and many other flags"; Embench -O2 -ffunction-sections | as above | [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html) | CoreMark type change may conflict with run rules (Q3); not EEMBC-certified |
| NaxRiscv (README headline) | 5.02 | 2.93 | Embench 1.67; 155 MHz, 13.3 KLUT on Artix-7 | not stated | README at retrieval | [NaxRiscv GitHub](https://github.com/SpinalHDL/NaxRiscv) | Same as RV32 A |
| VexiiRiscv (in-order, single/dual issue, RV32/64, Linux-capable; dual-issue headline config) | 5.24 ("up to") | 2.50 (README says "dhystone/MHz") | Embench 1.62; BTB 512, RAS 4, GShare 4 KB, late ALU | not stated | docs/README at retrieval | [VexiiRiscv perf](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html); [VexiiRiscv README](https://github.com/SpinalHDL/VexiiRiscv) | Docs say "too early" for area/Fmax |
| VexiiRiscv rv32im (single issue) / +branchPredict / +ipcMax lateAlu | 2.70 / 2.99 / 3.41 | 1.20 / 1.45 / 1.74 | Artix-7 190 / 195 / 140 MHz | not stated | docs at retrieval | [VexiiRiscv perf](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html) | |
| VexRiscv "full max perf" RV32IM, 8 KB I$/D$ | 2.57 | 1.38 | 200 MHz, 1935 LUT on Artix-7 | Dhrystone -O3 -fno-inline; CoreMark flags not stated | README at retrieval (long-standing) | [VexRiscv GitHub](https://github.com/SpinalHDL/VexRiscv) | Separate 1.44 DMIPS/MHz quoted "--no-inline" with nearly all features |
| VexRiscv "Linux balanced" RV32IMA+MMU | 2.27 | 1.21 | 180 MHz, 2883 LUT on Artix-7 | as above | as above | [VexRiscv GitHub](https://github.com/SpinalHDL/VexRiscv) | Cached configs thrash on Dhrystone |
| SonicBOOM (BOOMv3, OoO, decode 1-5) | 6.2 (6.15 with SFB; 4.9 without) | 3.93 | SPEC06 IPC 0.86 | CoreMark config not stated; SPEC gcc -O3 -falign-X=16; FireSim with 3.2 GHz modeled target, 32K/32K L1, 512K L2, 4 MB L3 | 2020 (CARRV) | [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf) | Likely a large (4-wide-fetch) config; DMIPS flags unstated |
| BOOMv2 (OoO) | 2-wide 3.91 / 4-wide 4.7 | 1.91 | SPEC06 IPC 0.42 | Chart data from Celio 2018 thesis | 2017-2018 | [Hot Chips 2020 C910 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf); [SonicBOOM Table 1](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf) | Stale; third-party chart |
| riscy-OOO (MIT, OoO) | — | ? | SPEC06 IPC 0.48 | — | 2018 | [SonicBOOM Table 1](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf) | |
| RSD (FPGA-optimized OoO, RV32IM) | — | 2.04 | — | — | 2019 | [SonicBOOM Table 1](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf) | |
| Rocket (single-issue in-order, 5-stage per [Celio et al.](https://arxiv.org/pdf/1607.02318)) | 2.32 | — | — | chart data from Celio 2018 thesis | 2018 | [Hot Chips 2020 C910 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf) | |
| SiFive U54 (5-stage, in-order, single-issue, RV64GC) | 2.75 | 1.7 | up to 1.5 GHz | vendor launch figure | 2017 | [CNX Software](https://www.cnx-software.com/2017/10/06/sifive-u54-mc-coreplex-is-the-first-linux-ready-risc-v-based-64-bit-quad-core-application-processor/) | Vendor claim |
| SiFive U74 (in-order dual-issue, 8-stage) | 4.9 (or 5.1) | 2.5 | — | vendor launch figure | 2018 (CNX); 2020 (HC slide citing SiFive page) | [CNX Software](https://www.cnx-software.com/2018/11/02/sifive-7-series-risc-v-cores-e76-s76-u74/); [Hot Chips 2020 C910 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf); pipeline description from [Elektroniknet/Segger](https://www.elektroniknet.de/international/from-microcontroller-to-multicore-processor.191302/seite-3.html) | Conflict: 4.9 vs 5.1 |
| SiFive P550 (OoO, 13-stage, triple-issue) | not found | not found | 8.65 SPECint2006/GHz | vendor | 2021-06 | [SiFive PR via BusinessWire](https://www.businesswire.com/news/home/20210622005290/en/SiFive-Performance-P550-Core-Sets-New-Standard-as-Highest-Performance-RISC-V-Processor-IP); [Embedded Computing Design](https://embeddedcomputing.com/technology/processing/semiconductor-ip/sifive-performance-p550-core-sets-new-standard-as-highest-performance-risc-v-processor-ip) | Vendor claim |
| T-Head C910 / Xuantie-910 (OoO, 12-stage, 3-decode/8-issue) | 7.1 | — | TH1520 at 1.85 GHz; up to 2.5 GHz on 12 nm | not disclosed in slides | 2020 (ISCA / Hot Chips) | [Hot Chips 2020 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf) | Some press calls it a chip-level figure; per-core interpretation assumed |
| T-Head C906 | 3.8 (-O3) | 2.4 (-O2) | 1 GHz, 22 nm | vendor specs relayed by blog | about 2021 | [Linux Adictos](https://www.linuxadictos.com/en/allwinner-xuantie-c906-risc-v.html) | Secondary source |
| T-Head C908 | +24-64% vs C906 (synthetic suite, not per-benchmark) | — | — | process/frequency unstated | 2022-11 | [CNX Software](https://www.cnx-software.com/2022/11/04/t-head-xuantie-c908-risc-v-core-targets-aiot-applications/) | No absolute number |
| CVA6 (scalar baseline) | 3.10 | — | — | — | 2024 | [Allart et al. arXiv 2410.01442](https://arxiv.org/abs/2410.01442) | Absolute value secondary/unverified |
| CVA6S (dual-issue CVA6) | 4.35 (OpenHW post: "up to 4.5") | — | +11% area, +7% power | — | 2024 | [Allart et al.](https://arxiv.org/abs/2410.01442); [RISC-V blog](https://riscv.org/blog/using-a-performance-model-to-implement-a-superscalar-cva6/) | Absolute value secondary/unverified |
| SweRV / VeeR EH1 (dual-issue superscalar, 9-stage) | 4.9 | — | 28 nm, up to 1.8 GHz | — | 2018-2019 | [AnandTech](https://www.anandtech.com/show/15231); [Codasip/Design-Reuse](https://design-reuse.com/news/news48082.html) | Secondary/unverified: the AnandTech URL now redirects to its forum, so the figures come from search excerpts |
| SweRV / VeeR EH2 (EH1-based, 2 hardware threads) | 6.3 | — | 16 nm, 0.067 mm² | simulated | 2019 | [AnandTech](https://www.anandtech.com/show/15231) | Simulated; dual-thread throughput, not single-thread IPC; secondary/unverified |
| SweRV / VeeR EL2 (RV32IMC, single-issue, 4-stage) | 3.6 | — | — | expected/simulated | 2019 | [AnandTech](https://www.anandtech.com/show/15231) | Simulated; secondary/unverified |
| Syntacore SCR7 | 5.0 | — | — | — | 2019-2020 | [Hot Chips 2020 C910 slides](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf) | Third-party chart |
| XiangShan Yanqihu (gen 1, OoO, 11-stage, RV64GC) | 5.3 | — | SPEC CPU2006 7.01 @1 GHz (int 7.03, fp 7.00) on real 28 nm chip with DDR4-1600 | CoreMark gcc-9.3.0 -O2 | 2021-2022 | [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf) | |
| XiangShan Nanhu (gen 2, RV64GCBK) | — | — | est. SPECint2006 19.10 and SPECfp2006 22.18 @2 GHz (about 9.55 int/GHz) | RTL sim with DRAMsim3 DDR4-2400; GCC 10.2.0 -O2 RV64GCB; "confirmed on FPGA as well" | 2023-01-05 | [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf) | Estimate, not a SPEC submission |
| XiangShan Kunminghu (gen 3, RV64GCBKHV) | — | — | target SPEC CPU2006 45 @3 GHz (15/GHz); talk title ">15/GHz" | SimPoint checkpoints, GCC 12 -O3 RV64GCB, jemalloc, 1 MB L2 + 16 MB L3, DDR4-3200 in DRAMsim3, simulated at 3 GHz | 2025-03 / 2025-05 | [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf); [RISC-V Summit Europe 2025 slides](https://riscv-europe.org/summit/2025/media/proceedings/2025-05-14-RISC-V-Summit-Europe-09h30-BAO-slides.pdf) | Simulation estimate |

#### Arm cores (context)

| Core | CoreMark/MHz | DMIPS/MHz | Microarchitecture | Source | Flags |
|---|---|---|---|---|---|
| Cortex-A53 | not found | 2.24 | 2-wide in-order, 8 stages | [Wikipedia ARMv8-A comparison](https://en.wikipedia.org/wiki/Comparison_of_ARMv8-A_processors) | Secondary; Dhrystone caveat noted on the page |
| Cortex-A55 | not found (U74 is claimed about 11% higher) | 2.65 | 2-wide in-order, 8 stages | [Wikipedia](https://en.wikipedia.org/wiki/Comparison_of_ARMv8-A_processors); [Elektroniknet/Segger](https://www.elektroniknet.de/international/from-microcontroller-to-multicore-processor.191302/seite-3.html) | |
| Cortex-A72 | not found | 4.7-6.3 | 3-wide OoO, 15 stages | [Wikipedia](https://en.wikipedia.org/wiki/Comparison_of_ARMv8-A_processors) | Wide range reflects differing rules |
| Cortex-A76 | not found | 6.4 | 4-wide OoO, 11-13 stages | [Wikipedia](https://en.wikipedia.org/wiki/Comparison_of_ARMv8-A_processors) | |
| Cortex-M7 | about 5 (5.04 in TechRadar) | 2.14 / 2.55 / 3.23 depending on "scenario" | MCU-class (microarchitecture not retrieved) | [TechRadar 2014](https://www.techradar.com/news/computing-components/processors/arm-introduces-update-to-cortex-m-family-1266767); [UT Austin newsflash table](https://users.ece.utexas.edu/~ljohn/teaching/382m-15/newsflash/news9.pdf) (secondary) | 2014 launch figures |
| Cortex-M4 | 3.41 | 1.25 / 1.52 / 1.91 (CNX: up to 1.95) | MCU-class | [UT Austin newsflash table](https://users.ece.utexas.edu/~ljohn/teaching/382m-15/newsflash/news9.pdf); [CNX Software 2014](https://www.cnx-software.com/2014/09/24/arm-cortex-m7-mcu/) | Minor conflict 1.91 vs 1.95 |

- The XiangShan MICRO 2025 tutorial plots SPECint2006/GHz ("proportional to IPC") for XS v1/v2/v3 against Cortex-A73, A75, A76, A77, A78 and Neoverse N2, sourcing the Arm points from "XT910@ISCA'20, SiFive, AnandTech". Exact values could not be extracted from the PDF text — [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- Sustained-frequency context for the KV260 comparison: NaxRiscv RV64 reaches 137 MHz and RV32 155 MHz on Artix-7 speed grade 3 — [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)

### Inferences
- To "beat NaxRiscv" credibly, the minimum bar per MHz on RV64 is about 4.94 CoreMark/MHz, 2.94 DMIPS/MHz (no inlining) and 1.84 Embench, at the same compiler and flags. A reasonable stretch target is SonicBOOM-class CoreMark (about 6 CoreMark/MHz with SFB) plus a clear lead on SPEC-like or Embench workloads. Because VexiiRiscv in-order dual-issue already claims 5.24 CoreMark/MHz, a CoreMark-only win would not demonstrate OoO value.
- Two in-order dual-issue designs reach or beat NaxRiscv on CoreMark/MHz: SiFive U74 (4.9-5.1; described as an 8-stage in-order dual-issue pipeline by [Elektroniknet/Segger](https://www.elektroniknet.de/international/from-microcontroller-to-multicore-processor.191302/seite-3.html)) and VexiiRiscv (5.24). This suggests CoreMark mostly rewards short pipelines, good branch handling and dual ALUs rather than deep OoO windows. SweRV EH1 (4.9) and SCR7 (5.0) score similarly, but their pipeline types were not verified here.
- For the final report, the cleanest apples-to-apples comparison is to re-run NaxRiscv RV64, VexiiRiscv, our core and possibly CVA6 under one toolchain, one flag set and one memory-latency model. Published per-MHz tables mix compilers, flags, ISAs (RV32 vs RV64) and simulation vs silicon.

### Gaps
- No CoreMark/MHz values from sources for Cortex-A53/A55/A72/A76. The EEMBC scores page renders dynamically and could not be read, and Arm's own product pages redirected. A Phoronix Raspberry Pi 4 result (A72 at 1.8 GHz, 4 cores, CoreMark 38200) is multi-threaded and cannot be converted reliably — [OpenBenchmarking](https://mail.openbenchmarking.org/result/2401011-NE-2112090TJ10&grt&sor).
- No CoreMark/MHz or DMIPS/MHz for SiFive P550, XiangShan Nanhu or Kunminghu, or C908 (absolute).
- The "NXF" core in the T-Head chart (3.22 CoreMark/MHz) is not identified.
- Chinese state media reportedly cited 16.5 SPECint2006/GHz for Kunminghu on SpacemiT test chips. I saw this only in a search summary and could not verify it.
- Compiler versions are missing for most entries. EEMBC certification status is unknown for all entries.

---

## 3. Benchmark pitfalls: Dhrystone, CoreMark, CoreMark-vs-SPEC IPC, and per-MHz scores with slow FPGA DRAM

### Takeaway
Dhrystone is extremely sensitive to compile rules, and NaxRiscv/VexRiscv publish with -fno-inline. CoreMark is a 2 KB, L1-resident, branch-heavy kernel that rewards branch tricks such as SFB predication. Neither predicts SPEC-like IPC. Per-MHz scores from FPGA soft cores are flattered because DRAM latency is small in core cycles at 100-300 MHz. Report the memory-to-core frequency ratio (CoreMark's rules require it) and model ASIC-like latency when claiming IPC.

### Cited Findings
- **Dhrystone compile-rule sensitivity.**
  - Arm's Cortex-M7 is quoted at 2.14, 2.55 or 3.23 DMIPS/MHz depending on "scenario", a 51% spread for the same core. The Cortex-M4 equivalents are 1.25 / 1.52 / 1.91 — [TechRadar](https://www.techradar.com/news/computing-components/processors/arm-introduces-update-to-cortex-m-family-1266767); [UT Austin newsflash](https://users.ece.utexas.edu/~ljohn/teaching/382m-15/newsflash/news9.pdf) (secondary).
  - The three tiers are commonly understood as strict ground rules, then inlining allowed, then multi-file compilation allowed. The footnote text was not retrieved (see Gaps).
- NaxRiscv publishes Dhrystone with "-O3 -fno-common -fno-inline" — [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html). VexRiscv uses "-O3 -fno-inline" — [VexRiscv](https://github.com/SpinalHDL/VexRiscv).
- VexRiscv notes that every cached configuration except "full max perf" thrashes the cache on Dhrystone, which lowers results. Small-cache configurations can therefore produce misleading Dhrystone results — [VexRiscv](https://github.com/SpinalHDL/VexRiscv)
- Wikipedia's Arm comparison warns that DMIPS/MHz comes from a 1980s synthetic benchmark and "should be used with caution" — [Wikipedia](https://en.wikipedia.org/wiki/Comparison_of_ARMv8-A_processors)
- Embench's motivation: single synthetic programs such as Dhrystone and CoreMark have long been discouraged as benchmarks. Embench instead uses a suite of about 20 real programs (from BEEBS) and reports the geometric mean and geometric standard deviation relative to a reference platform. It reports code size separately; v0.5 targeted ≤64 KiB flash and ≤16 KiB RAM, with PULP RI5CY as the initial reference — [Patterson et al., SIGARCH blog](https://www.sigarch.org/embench-recruiting-for-the-long-overdue-and-deserved-demise-of-dhrystone-as-a-benchmark-for-embedded-computing/)
- **CoreMark run rules.**
  - A result is valid only if the run lasts at least 10 s.
  - It must validate with seeds 0,0,0x66 and 0x3415,0x3415,0x66, using a 2000-byte buffer.
  - All files must use the same flags. Only the core_portme* files may be modified.
  - Data types must match their stated widths (ee_u8, ee_s16, ee_u16, ee_s32, ee_u32).
  - PGO profiles must come from seeds 8,8,8 with a 1200-byte buffer.
  - The kernels are linked-list find/sort, matrix multiply, a state machine and CRC.
  - CoreMark/MHz must be reported as "CoreMark/MHz 1.0 : N / C / P [/ M]". P must include the memory-to-core frequency ratio, and the cache-to-core ratio if configurable. M declares parallel contexts.
  - [EEMBC CoreMark README](https://github.com/eembc/coremark)
- NaxRiscv's RV64 CoreMark used "-O3, u32 as s32 and many other flags" — [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html). Compare the run rule that types match their stated definitions — [CoreMark README](https://github.com/eembc/coremark).
- **CoreMark's branch sensitivity.**
  - SFB predication alone moved SonicBOOM from 4.9 to 6.15 CoreMark/MHz — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf).
  - Adding branch prediction to VexiiRiscv rv32im moved CoreMark 2.70 to 2.99 and Dhrystone 1.20 to 1.45 — [VexiiRiscv](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Performance/index.html).
  - SonicBOOM's authors note that "CoreMark is not a good evaluation of out-of-order core performance" — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- **CoreMark vs SPEC IPC divergence.**
  - SonicBOOM: 6.2 CoreMark/MHz versus SPEC06 IPC 0.86, under FireSim at a modeled 3.2 GHz with an L3 and DRAM — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf).
  - XiangShan Yanqihu: 5.3 CoreMark/MHz versus SPECint2006 7.03 @1 GHz on silicon with DDR4-1600 — [XiangShan MICRO25](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf).
  - NaxRiscv's IPC is 1.65 on Dhrystone but 1.28 on CoreMark — [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html).
- **Memory-latency regime.**
  - SonicBOOM was evaluated on FireSim, with FPGAs running at 30 MHz while modeling a 3.2 GHz target with 32K/32K L1, 512K L2, 4 MB L3 and 16 GB DRAM. Its speculation depth "cannot hide misses beyond L1" — [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf).
  - XiangShan's Nanhu and Kunminghu estimates likewise model DRAM with DRAMsim3 (DDR4-2400 at 2 GHz, DDR4-3200 at 3 GHz) rather than using the FPGA's real DRAM timing — [XiangShan MICRO25](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- Real-silicon DRAM latency example: the C910 in TH1520 measures 133.9 ns DRAM latency and a 60-cycle L2 at 1.85 GHz — [Chips and Cheese](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- **SMT counting pitfall.** SweRV EH2's 6.3 CoreMark/MHz is a dual-thread figure from simulation, compared with EH1's single-thread 4.9 — [AnandTech](https://www.anandtech.com/show/15231). CoreMark's "M" field exists to declare such parallel contexts — [CoreMark README](https://github.com/eembc/coremark).
- **Instruction-count vs IPC confound.** RISC-V instruction counts vary by ISA subset and compiler: RV64G runs 16% more instructions than x86-64 and 9% more than ARMv8 on SPECint2006, and fusion removes 5.4% — [Celio et al.](https://arxiv.org/abs/1607.02318)

### Inferences
- **FPGA per-MHz inflation** (computed from cited latencies; KV260-specific latency not measured).
  - A DRAM access of about 134 ns costs about 248 core cycles at 1.85 GHz, but only about 20 cycles at 150 MHz and about 33 cycles at 250 MHz.
  - So an FPGA soft core's SPEC-like IPC and CoreMark/MHz with real DDR can look far better per MHz than the same RTL at ASIC frequency.
  - Features that create memory-level parallelism (MSHRs, prefetchers, large ROB) look less valuable on FPGA than they would on an ASIC.
  - CoreMark/MHz is essentially immune to this because it is L1-resident. It cannot show MLP features at all.
- **Required reporting for every IPC claim on KV260:**
  1. Core clock, and DRAM latency in ns and in core cycles, measured with a pointer-chase.
  2. The memory-to-core frequency ratio, as CoreMark's P field requires.
  3. Whether DRAM latency was padded to emulate an ASIC target (FireSim-style).
  4. Compiler version and flags, the ISA string (with or without Zba/Zbb/Zbs, RVC), and whether the binary is identical across compared cores.
- **Dhrystone:** report only ground-rules numbers (-fno-inline, separate compilation) and treat them as a sanity check, not a target. Inlining and multi-file builds can inflate results by about 50%, as the M7 range shows.
- **CoreMark:**
  - Keep the 2000-byte size and validation seeds, and run at least 10 s.
  - Avoid type redefinitions such as "u32 as s32" if claiming comparability.
  - Report -O2 and -O3 with the same GCC/LLVM version as the NaxRiscv comparison.
  - Expect branch tricks (SFB, loop buffers) to move CoreMark far more than SPEC.
- **IPC vs performance:** comparing IPC across binaries built with different ISA extensions or compilers is meaningless. Use identical binaries for IPC comparison, and time or iterations for performance comparison.

### Gaps
- Arm's Dhrystone application note and the exact footnotes defining the three M7 DMIPS tiers were not retrieved; the tier semantics above are an interpretation.
- No primary source was retrieved on Dhrystone's strcpy/strcmp dominance or on compilers recognizing it.
- No KV260 (Zynq UltraScale+) PL-to-PS-DDR4 latency measurement was found. It must be measured on the board.

---

## 4. Which benchmark suites best demonstrate IPC on a Linux-capable FPGA core, and how XiangShan, BOOM, NaxRiscv and others measured performance

### Takeaway
Leading projects use a tiered approach:
- Small kernels (CoreMark, Dhrystone, Embench) for quick regressions and comparison with prior FPGA cores.
- SPEC CPU (2006 for comparability with XiangShan, 2017 for modern claims) with sampled checkpoints, modeled DRAM timing and fixed compilers for credible IPC.
- Linux boot and full-system runs as functional stress tests.

NaxRiscv publishes only Dhrystone, CoreMark and Embench from Verilator simulation. A new core that wants to beat it should match those three exactly and add SPEC-subset and memory-system evidence.

### Cited Findings
- **NaxRiscv's methodology.**
  - Dhrystone and CoreMark run in the Verilator model `VNaxRiscv`, loading the ELF with `--stats-print` options.
  - Embench-iot runs through a SpinalHDL fork with a `naxriscv_sim` board config.
  - Linux 5.10.1 boots in Verilator under OpenSBI v0.8 (RV32), and Linux/Buildroot "works on hardware".
  - Gem5-format and Konata pipeline logs are available for visualization.
  - [NaxRiscv perf](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html); [NaxRiscv GitHub](https://github.com/SpinalHDL/NaxRiscv)
- **BOOM/SonicBOOM methodology.**
  - FireSim on AWS F1 at 30 MHz FPGA clock modeling a 3.2 GHz single core, running CoreMark, SPECint2006 and SPECint2017.
  - SPEC built with gcc -O3 (-falign-X=16 for 2006).
  - Comparisons against AWS Graviton (A72-like) and Skylake SPEC17 IPC.
  - Linux (Buildroot, Fedora) used as a stress test: SonicBOOM's aggressive speculation exposed a missing FENCE in kernel page-table initialization.
  - Dromajo co-simulation on FireSim ("Fromajo") at over 1 MHz.
  - [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- **XiangShan methodology.**
  - Gen 1 (Yanqihu) was measured on a real chip: SPEC CPU2006 per-benchmark scores at 1 GHz with DDR4-1600, Debian running.
  - Gen 2 (Nanhu) was estimated by RTL simulation with DRAMsim3 DDR4-2400 (GCC 10.2.0 -O2 RV64GCB) and "confirmed on FPGA".
  - Gen 3 (Kunminghu) used SPEC CPU checkpoints selected by SimPoint (GCC 12 -O3 RV64GCB, jemalloc, 1 MB L2, 16 MB L3, DDR4-3200 in DRAMsim3 at 3 GHz).
  - Their FPGA environment (NEXST) runs Linux on VU37P/VU19P boards.
  - DiffTest-H hardware-accelerated co-simulation runs at 13.8 MHz on FPGA and found 151 bugs.
  - [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- Lin & Tarsa evaluated branch prediction on SPECint2017 with 10B-instruction traces, split into 30M-instruction slices (333 per trace), in ChampSim — [Lin & Tarsa](https://ar5iv.labs.arxiv.org/html/1906.08170)
- The gem5-vs-RSD validation used custom microbenchmarks (IntegerStress, BranchMisRandom, BranchMisNever, MemoryRandom, Bubblesort, Fib) plus MiBench programs (qsort, stringsearch) — [arXiv 2106.09991](https://arxiv.org/abs/2106.09991)
- **Embench-IoT.** 19 benchmarks largely derived from BEEBS. Each must fit in 64 kB of code and 64 kB of RAM. Each runs a warm-up and is scaled to about 4 s of CPU time. Stable tags are embench-0.5 and embench-1.0, with 2.0rc1/rc2 in development — [Embench GitHub](https://github.com/embench/embench-iot). NaxRiscv labels its Embench score relative to a "Cortex-M4 baseline", whereas Embench v0.5's initial reference was RI5CY, so the suite version must be stated — [NaxRiscv GitHub](https://github.com/SpinalHDL/NaxRiscv); [SIGARCH blog](https://www.sigarch.org/embench-recruiting-for-the-long-overdue-and-deserved-demise-of-dhrystone-as-a-benchmark-for-embedded-computing/)
- **Memory-subsystem microbenchmarks.** The C910 study used latency and bandwidth microbenchmarks to expose specific bottlenecks: a 60-cycle L2, 133.9 ns DRAM, about 10 GB/s single-core L2 read, store-forwarding failure cases, and frontend throughput from L1i vs L2 — [Chips and Cheese](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- XiangShan's 2025 tutorial reports SPEC CPU2006, not CPU2017, for all three generations, including the Kunminghu 15/GHz target — [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf). Its simulator-calibration work, by contrast, reports SPECint/fp2017 error — [arXiv 2602.11580](https://arxiv.org/abs/2602.11580).

### Inferences
Recommended benchmark ladder for the KV260 core:
1. **Microbenchmarks** for each mechanism: pointer-chase latency (L1/L2/DRAM, in ns and cycles), bandwidth, branch-predictor stress (random vs patterned), BTB and RAS capacity, store-to-load forwarding, and memory-dependence violations. These were the main tools in the C910 analysis and the gem5-RSD calibration.
2. **NaxRiscv-parity kernels**, run exactly as NaxRiscv does: Dhrystone (-O3 -fno-common -fno-inline), CoreMark (EEMBC-compliant, 2000 B, at least 10 s), and Embench-iot (pinned version, -O2 -ffunction-sections). Run them both in Verilator and on the KV260 with the NaxRiscv RV64 bitstream as a control.
3. **SPEC-like IPC.** Use a SPEC CPU2017 intrate subset, plus CPU2006 for XiangShan comparison, compiled once with a fixed GCC version for RV64GC and RV64GC+Zba/Zbb.
   - Use SimPoint-selected slices or checkpoints for simulator and RTL runs.
   - Use test or train inputs for full runs on the FPGA, where 100-300 MHz makes ref inputs take days.
   - Report IPC from mcycle/minstret and top-down counters.
4. **Full-system Linux.** Boot time to shell, plus lmbench-style lat_mem_rd and context-switch tests and STREAM bandwidth, to prove the memory system and MMU. Linux boot also serves as a speculation and correctness stress test, as SonicBOOM found.
5. **Multicore/SMT throughput.** CoreMark with the M field declared, plus rate-style SPEC copies, reported separately from single-thread IPC.

### Gaps
- No primary source was retrieved describing CoreMark-PRO's workload composition. Nor were sources found on lmbench or STREAM use by XiangShan, BOOM or NaxRiscv, or on MiBench beyond the gem5-RSD study.
- The Embench speed-score formula (frequency normalization, reference CPU) is in doc/README.md, which was not retrieved.
- BOOM's full SPEC methodology in Celio's thesis was not retrieved: the PDF exceeded the fetch size limit.

---

## 5. Pre-RTL design-space-exploration tools that support RISC-V, how they were used, and their accuracy

### Takeaway
Simulator choice matters less than calibration: published errors range from about 1% after targeted calibration up to about 45% uncalibrated. The proven pattern, used by XiangShan (XS-GEM5) and the Thales CVA6S project (a Python cycle model), is:
1. Build or adapt a cycle-level model.
2. Calibrate it against RTL with microbenchmarks that isolate one feature at a time.
3. Do design-space exploration on the model.
4. Implement on RTL and re-measure.
gem5 O3CPU is the most mature RISC-V-capable OoO model. Olympia is a lighter Sparta-based, trace-driven RISC-V OoO model. ChampSim and Scarab are x86-trace-centric. Sniper's RISC-V support is a side branch.

### Cited Findings
- **gem5 vs RTL (RSD).**
  - gem5 was configured to match the RSD OoO core, with RSD's gshare re-implemented in gem5 by translating its SystemVerilog.
  - Per-benchmark cycle counts differed by up to 36% (BubblesortC +36%, StringSearchSmall −35%), and by 18% on average in absolute terms.
  - Four microbenchmarks (IntegerStress, BranchMisRandom, MemoryRandom, BranchMisNever) matched within 6%.
  - Means across benchmarks were close to 1.0.
  - The main error sources were the branch predictor and the memory system ("abstraction errors").
  - [arXiv 2106.09991](https://arxiv.org/abs/2106.09991)
- **gem5 RISC-V full-system vs silicon (gXR5, EPFL 2023, vs SiFive HiFive Unleashed).** SPEC CPU2017 mean absolute error was 44.3% uncalibrated, falling to 24% after CPU calibration — [EPFL infoscience](https://infoscience.epfl.ch/record/302433) (secondary/unverified).
- UC Davis tuned gem5's RISCVMatched board (modeled on SiFive Unmatched) against perf counters by iterative microbenchmark fine-tuning — [UC Davis poster](https://arch.cs.ucdavis.edu/assets/papers/validating-hardware-and-simpoints-with-gem5-poster.pdf) (secondary/unverified)
- gem5 error can swing from −51% to +10% between two versions of the same model — [GemStone, Southampton](https://eprints.soton.ac.uk/418538) (Arm target; secondary/unverified)
- A single O3CPU parameter (IssueToExecute delay) cut one microbenchmark's error from 33.6% to 0.4% — [Warwick PMBS'19](https://www.dcs.warwick.ac.uk/pmbs/pmbs19/PMBS19/pres/paper7.pdf) (x86 Haswell target; secondary/unverified)
- **XS-GEM5 (XiangShan's calibrated gem5).**
  - XiangShan's Kunminghu workflow is "performance model calibrated with RTL", then "DSE on perf model", then "implementation and fine tuning on RTL" — [XiangShan MICRO25 slides](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
  - The Microarchitecture Cliffs method cut XS-GEM5's error vs XS-RTL from 59.2% to 1.4% on Cliff microbenchmarks.
  - It reduced absolute performance error on SPECint2017 and SPECfp2017 by 15.1% and 21.0% respectively.
  - It cut Store Set's relative error by 48.03%.
  - [arXiv 2602.11580](https://arxiv.org/abs/2602.11580)
  - The XS-GEM5 frontend, backend and caches are described as calibrated with Kunminghu — [XS-GEM5 mirror](https://gitee.com/mingyuncode/XS-GEM5) (secondary/unverified)
- TraceRTL, a trace-driven RTL CPU derived from XiangShan, reports 99.87% / 99.86% performance accuracy on SPECint2017 / SPECfp2017 — [BenchCouncil TBench](https://journal.benchcouncil.org/TBench/article/download/72/16/604) (secondary/unverified)
- **CVA6 performance model.** A model of CVA6 written before the RTL changes was 99.2% accurate on CoreMark. It was used to find and fix performance bugs and then guide the dual-issue implementation (+40% CoreMark) — [arXiv 2410.01442](https://arxiv.org/abs/2410.01442). The model is open source (cva6-perf-model) and written in Python per secondary summaries — [RISC-V blog](https://riscv.org/blog/using-a-performance-model-to-implement-a-superscalar-cva6/).
- **Olympia (riscv-perf-model).**
  - A C++ OoO RISC-V performance model built on the Sparta framework.
  - Models decode, ROB, rename (scoreboard with latency matrices), issue queues mapped to configurable execution pipes, the LSU with TLB, and DL1.
  - Trace-driven (STF .zstf or JSON); a functional backend is "under development".
  - small_core / medium_core / big_core YAML architectures.
  - PEvents for RTL correlation; pipeline viewer output.
  - Branch prediction and prefetching are listed as future extensions.
  - No speed or accuracy claims.
  - [Olympia GitHub](https://github.com/riscv-software-src/riscv-perf-model)
- **Sniper.**
  - Interval-simulation core model, with "several MIPS" speed.
  - Validated against Intel Core2/Nehalem within 25% average error.
  - The repository contains a `riscv` directory and README.riscv plus a SIFT trace frontend — [Sniper GitHub](https://github.com/snipersim/snipersim)
  - CoMeT's docs describe RISC-V support via Sniper's `riscv` branch, with Spike-generated traces — [CoMeT RISC-V docs](https://deepwiki.com/marg-tools/CoMeT/6.1-risc-v-support) (secondary/unverified)
- **Scarab.**
  - Single-threaded x86-64 via Intel PIN, plus DynamoRIO memtraces; RISC-V is not mentioned.
  - Models an OoO pipeline with TAGE-SC-L, prefetchers, Ramulator DRAM and McPAT power.
  - 600 KIPS trace-driven and 100 KIPS execution-driven.
  - [Scarab GitHub](https://github.com/hpsresearchgroup/scarab)
- **ChampSim.**
  - Trace-based simulator with pluggable branch predictors, BTB, prefetchers and replacement policies, used for the DPC-3 and CRC-2 championships.
  - RISC-V is not mentioned — [ChampSim GitHub](https://github.com/ChampSim/ChampSim)
- **BOOM-Explorer (ICCAD 2021 best paper; TODAES 2024).**
  - Microarchitecture-aware active learning picks initial designs; a deep-kernel Gaussian process models the space; correlated multi-objective Bayesian optimization finds the Pareto front over BOOM RTL (cycles) and VLSI power.
  - The TODAES version reports +18.75% Pareto hypervolume and −65.38% runtime versus prior methods.
  - [ICCAD 2021 PDF](https://www.cse.cuhk.edu.hk/~byu/papers/C122-ICCAD2021-DSE-BOOM.pdf); [TODAES 2024 PDF](https://www.cse.cuhk.edu.hk/~byu/papers/J98-TODAES2024-BOOM-Explorer.pdf) (TODAES figures secondary/unverified)
- **FPGA-accelerated RTL simulation.**
  - FireSim lets SonicBOOM run SPEC at a modeled 3.2 GHz with realistic memory timing, at 30 MHz on FPGA.
  - Dromajo co-simulation ran at over 1 MHz.
  - [SonicBOOM](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)

### Inferences
Recommended pre-RTL DSE flow for the KV260 core:
1. **Workload capture.** Generate RV64GC and RV64GC+Zba/Zbb binaries with one pinned GCC. Collect SimPoint slices (or 30-100M-instruction samples) from Spike or QEMU for SPECint2017/2006 subsets, CoreMark, Embench and Linux boot segments.
2. **Fast component studies.** Use a trace-driven branch/BTB/RAS/ITTAGE simulator and a cache/prefetch simulator. ChampSim-style infrastructure needs a RISC-V trace converter; none was found, so this would be our own tooling. Sweep predictor budgets (4-64 KB), BTB and RAS sizes, L1/L2 sizes and associativity, and prefetchers. These components are where gem5-vs-RTL errors concentrate, so model them bit-exactly from the start.
3. **Core model.** Use gem5 O3CPU (RISC-V, SE then FS) or an Olympia derivative. Configure the 2-wide machine and port our exact predictor and LSU policies into it, as the RSD study had to do for gshare. Expect 10-40% raw error. Calibrate with per-feature microbenchmarks (Cliff-style) until errors are in single digits, then sweep ROB/IQ/PRF/LQ/SQ, issue ports, and ALU and load latency with Bayesian or fractional-factorial DSE (BOOM-Explorer-style).
4. **Objective function for FPGA.** Optimize performance = IPC × Fmax (and per LUT/BRAM), not IPC alone. BOOMv2 (+30% frequency, −20% IPC) and VexiiRiscv lateAlu (more IPC, −33% Fmax) show the trade-offs cut both ways. Use a synthesis-in-the-loop estimate for the top candidates, as BOOM-Explorer did with its VLSI flow.
5. **RTL validation loop.** Run Verilator with DiffTest-style co-simulation, then KV260 hardware. Keep the performance model in lock-step with RTL; CVA6 shows 99.2% CoreMark agreement is achievable. Re-run the calibration microbenchmarks after every RTL change.
6. **Memory-latency realism.** In both model and FPGA runs, add a configurable DRAM-latency padding mode to emulate ASIC-like latency in cycles. Report both modes, so FPGA-flattered IPC is not mistaken for architectural IPC (see Q3).

### Gaps
- No published BOOM-vs-gem5 O3 validation was found; the RSD study lists it as future work.
- No accuracy figures were found for Olympia, Sniper-RISC-V or Scarab on RISC-V. No RISC-V-to-ChampSim trace converter was located; the search budget was exhausted.
- XiangShan's NEMU speed, the full XS-GEM5 SPEC error table, and the LightSSS/ChiselDB/top-down tool details were not retrieved beyond the slide-level mentions.
- gem5's official RISC-V documentation (FS support status, O3 RISC-V specifics) and Ta et al.'s CARRV 2018 gem5-RISC-V paper were identified but not read.
