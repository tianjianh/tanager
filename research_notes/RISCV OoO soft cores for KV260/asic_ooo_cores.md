# ASIC-oriented OoO RISC-V cores (BOOM, XiangShan, OpenC910/XuanTie) and industrial OoO reference points: microarchitecture, performance, FPGA cost, design lessons

Research date: 2026-10-12. Every number below carries its version/date/config where the source gave one. Vendor numbers are marked "vendor" and are not independently verified. Several primary PDFs were read in full (SonicBOOM CARRV'20, BOOMv2 TR'17, Xuantie-910 ISCA'20 + Hot Chips 32 slides, XiangShan MICRO'22, XiangShan Hot Chips 2024 slides, XiangShan RVSE'25 slides/poster, XiangShan MICRO'25 tutorial). Note: the shared WebSearch budget ran out partway through this research, so a few items (P670, Ascalon family, AX65) rely on search-engine summaries of pages that could not be fetched directly; these are flagged.

## Key question 1: Per-core microarchitecture parameters (widths, depth, ROB/IQ/PRF/LQ/SQ, scheduler, rename, branch prediction, LSU, caches/TLBs/prefetch, coherence)

### Takeaway
BOOM v3 ("SonicBOOM", 2020) is the only open core here with a full 1-wide to 5-wide parameter ladder. MediumBoom is the 2-wide reference point: 64-entry ROB, 80 integer physical registers, 16-entry LQ and SQ, split issue queues and TAGE-L. XiangShan Kunminghu (2024–2026) is a 6-wide, 13-stage core aimed at Neoverse N2. It has a compressed 160-entry ROB, 3 load and 2 store pipes, store-set plus wait-table memory-dependence prediction and a split load queue. OpenC910 (2019; open-sourced 2021) is a 12-stage core that decodes 3 and renames 4. Its 64 ROB entries hold up to 192 instructions, but its schedulers and register files are small for that window. The commercial 3–4-wide cores (P550/P650, AX65) sit between BOOM Medium/Large and C910. Veyron, Ascalon, C930 and C950 are 6–8-wide and show the direction of the field rather than templates.

### Cited Findings

#### BOOM v1 → v2 (Celio et al., CARRV 2017 / UCB TR EECS-2017-157)
- BOOMv1 followed the MIPS R10K 6-stage structure (fetch, decode/rename, issue/register-read, execute, memory, writeback). It had a single unified issue window, a unified int+FP physical register file and a short 2-stage front end, with conditional branch prediction made after decode — [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- Analysis configurations, v1 → v2:
  - BTB: 40 entries, fully associative → 64×4 set-associative.
  - Fetch: 2 instructions per cycle in both.
  - Issue: 3 → 4 micro-ops per cycle.
  - Issue entries: 20 unified → 16/16/16 (int/mem/FP).
  - Register file ports: 7R3W unified → int 6R3W plus FP 3R2W.
  - Execution units: v1 had iALU+iMul+FMA, iALU+fDiv and Load/Store; v2 has iALU+iMul+iDiv, iALU, FMA+fDiv and Load/Store.
  - Source: [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- BOOMv2 changes:
  - 3-stage front end: BPD index hashing gets its own stage (F1), table access and predecode happen in F2, and the redirect happens in F3.
  - The BTB became partially tagged and set-associative, with a checker that verifies BTB predictions against the fetched instructions.
  - Rename was pipelined, and issue-select and register-read became separate stages.
  - Integer and FP register files were split, and FP got its own pipeline.
  - Source: [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- The BOOMv2 integer register file has 70 entries with 6 read and 3 write ports: 4,480 bits, each needing 18 wires. The smaller FP register file (3R2W) was fully synthesized — [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- BOOM docs describe 10 conceptual stages (Fetch, Decode, Rename, Dispatch, Issue, RegRead, Execute, Memory, Writeback, Commit). The implementation merges these into 7 counted stages, and commit runs asynchronously — [BOOM docs: pipeline](https://docs.boom-core.org/en/latest/sections/intro-overview/boom-pipeline.html)

#### BOOM v3 "SonicBOOM" (Zhao, Korpan, Gonzalez, Asanović, CARRV 2020)
- New superscalar fetch unit with RVC support:
  - It decodes a possible 2- or 4-byte instruction at every 2-byte parcel.
  - An extra stage then compacts the decoded instructions into a dense fetch packet.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Branch prediction:
  - Hierarchical, pipelined predictor behind a general interface.
  - Single-cycle micro-BTB (also called next-line predictor or L0 BTB) from a small fully-associative buffer.
  - TAGE driven by a superscalar global history that is updated speculatively and repaired.
  - The predictor is banked to match the banked ICache, and the predictors were made superscalar.
  - The loop predictor and RAS are snapshotted and repaired on mispredict.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Superscalar branch resolution: there are multiple branch units, and an extra post-writeback stage reads the fetch-PC queue only for the oldest mispredicted branch. This raises branch-to-branch latency to 12 cycles — [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- New LSU and L1D:
  - The D$ is striped into even and odd banks of 1R1W SRAM.
  - Load-address and store-address CAMs are duplicated, and the TLB is dual-ported.
  - Per cycle it handles 2 loads or 1 store: 16 B/cycle read or 8 B/cycle write.
  - Misses go to line-fill buffers, so eviction and refill overlap.
  - Independent state machines handle refill, permission upgrade, writeback, prefetch and probe.
  - A next-line prefetcher sits between L1 and L2.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Table 1 of the paper (SonicBOOM vs BOOMv2):
  - Decode width: 1–5 vs 1–4.
  - Memory width: 16 B/cycle vs 8 B/cycle.
  - Branch predictor: TAGE vs GShare.
  - ISA: RV64GC vs RV64G.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Predefined v3 configurations (current repo):
  - **Small** (1-wide decode, fetch width 4):
    - ROB 32; mem/int/FP issue queues 8 entries each, 1-issue each.
    - 52 int / 48 FP physical registers; LQ 8, SQ 8; max branches 8.
    - Fetch buffer 8; FTQ 16.
    - 16 KiB L1I and 16 KiB L1D (64 sets × 4 ways); 2 MSHRs.
  - **Medium** (2-wide decode, fetch width 4):
    - ROB 64.
    - Issue queues: mem 12 entries (1-issue), int 20 entries (2-issue), FP 16 entries (1-issue).
    - 80 int / 64 FP physical registers; LQ 16, SQ 16; max branches 12.
    - Fetch buffer 16; FTQ 32.
    - L1 geometry same as Small; no prefetch.
  - **Large** (3-wide, fetch width 8, described as about Cortex-A15 class):
    - ROB 96.
    - Issue queues: mem 16 (1-issue), int 32 (3-issue), FP 24 (1-issue).
    - 100 int / 96 FP physical registers; LQ 24, SQ 24; max branches 16.
    - Fetch buffer 24; FTQ 32.
    - L1 64 sets × 8 ways (32 KiB); 4 MSHRs.
  - **Mega** (4-wide):
    - ROB 128.
    - Issue queues: mem 24 (2-issue), int 40 (4-issue), FP 32 (2-issue).
    - 128 int / 128 FP physical registers; LQ 32, SQ 32; max branches 20.
    - Fetch buffer 32; FTQ 40; 8 MSHRs; prefetch enabled.
  - **Giga** (5-wide): ROB 130, int issue queue 40 entries (5-issue); otherwise similar to Mega.
  - Source: [BOOM v3 config-mixins](https://raw.githubusercontent.com/riscv-boom/riscv-boom/master/src/main/scala/v3/common/config-mixins.scala)
- Predictor variants:
  - TAGE-L, the default: loop predictor, TAGE, BTB, bimodal (BIM) and a fully-associative micro-BTB, with a 64-bit global history.
  - Boom2BPD: BIM + BTB + gshare, built as a single-table TAGE of 256 entries with 16-bit history and 7-bit tags.
  - Alpha21264BPD: tournament predictor with 32-bit global and 32-bit local history and 128 local-history sets.
  - Source: [BOOM v3 config-mixins](https://raw.githubusercontent.com/riscv-boom/riscv-boom/master/src/main/scala/v3/common/config-mixins.scala)
- Rename:
  - The map table is snapshotted on every branch or JALR, which gives single-cycle map recovery.
  - The free list is a bit-vector; a cascading priority decoder allocates several registers per cycle.
  - Each branch has an allocation list of registers allocated after it. On a mispredict that list is OR'd back into the free list, because snapshotting the free list alone leaks registers.
  - A busy table tracks readiness.
  - An optional committed map table gives a single-cycle reset on exceptions; without it, the ROB unwinds one row per cycle.
  - No move elimination is documented.
  - Sources: [BOOM docs: rename](https://docs.boom-core.org/en/latest/sections/rename-stage.html); each instruction carries a branch tag so dependents can be killed on mispredict — [BOOM docs: pipeline](https://docs.boom-core.org/en/latest/sections/intro-overview/boom-pipeline.html)
- Issue:
  - Separate int, FP and mem queues.
  - The default policy is an age-ordered collapsing queue; an R10K-style unordered policy is the alternative.
  - Each port uses a static-priority encoder.
  - ALU ops wake dependents at issue (fast wakeup); FP, load and variable-latency ops wake them at writeback.
  - There is no speculative load-hit issue.
  - Source: [BOOM docs: issue](https://docs.boom-core.org/en/latest/sections/issue-units.html)
- LSU:
  - LDQ and STQ entries are allocated at decode, and each load carries a store mask.
  - Loads fire optimistically and forward from a matching store. If the store data is not ready, the load sleeps and retries.
  - Memory-ordering failures are detected when a store searches the LDQ. The response is a full pipeline flush plus rename reset, which the docs call "incredibly expensive".
  - No memory-dependence predictor is documented.
  - Source: [BOOM docs: LSU](https://docs.boom-core.org/en/latest/sections/load-store-unit.html)
- FTQ and backing predictor:
  - The FTQ has one entry per fetch cycle (not per instruction), decoupled from the ROB, and holds predictor metadata for update.
  - The predictor is updated at commit.
  - Global history is speculative, with a snapshot per fetch packet plus a commit copy.
  - In-flight predictions are not bypassed, so loops with several iterations in flight can mispredict more.
  - Source: [BOOM docs: backing predictor/FTQ](https://docs.boom-core.org/en/latest/sections/branch-prediction/backing-predictor.html)

#### BOOM "v4" (in-repo development line, 2024–2026; no paper found)
- The riscv-boom repo now contains parallel `v3` and `v4` source trees — [riscv-boom src tree](https://api.github.com/repos/riscv-boom/riscv-boom/contents/src/main/scala)
- What the v4 commit log shows (dates as listed):
  - The oldest visible commits touching v4 date from March 2024, on an "organize" branch; the commit that created v4 was outside the retrieved window.
  - Decode coalescing/simplification and B-extension support (Aug 2024).
  - Counter-based dependency tracking, described as the first step toward a decoupled-vector BOOM (Sep 2024, merged Jan 2025).
  - A "naive" non-speculative-interference (NSI/SNI) secure BOOM (Feb 2025).
  - RoCC CSRs in v4 (Mar 2025).
  - Matrix-based scheduler support (Apr 2025), then "fall back to non-matrix issue for now" (Dec 2025).
  - A fix for program-order inversion in the matrix issue queue (Aug 2026).
  - Source: [riscv-boom v4 commit log](https://api.github.com/repos/riscv-boom/riscv-boom/commits?path=src/main/scala/v4&per_page=100)
- The README still describes only SonicBOOM/BOOMv3 at 6.2 CoreMark/MHz — [riscv-boom README](https://raw.githubusercontent.com/riscv-boom/riscv-boom/master/README.md)
- Chipyard's BOOM FPGA config instantiates MegaBoomV3 — [Chipyard VCU118 configs](https://raw.githubusercontent.com/ucb-bar/chipyard/main/fpga/src/main/scala/vcu118/Configs.scala)

#### XiangShan Yanqihu (YQH, gen 1) and Nanhu (NH, gen 2), MICRO 2022 Table II and text
- Tape-out parameters, YQH vs NH:
  - ISA: RV64GC vs RV64GCBK.
  - Process and clock: 28 nm at 1.3 GHz vs 14 nm at 2 GHz.
  - Cores: 1 vs 2.
  - micro-BTB: 32 vs 256 entries.
  - BTB: 2K vs 4K entries.
  - TAGE-SC: 16K entries in both; NH adds ITTAGE alongside the RAS.
  - L1 caches: YQH has a 16 KB 4-way L1I plus a 128 KB 8-way "L1+" cache and a 32 KB 8-way L1D; NH has 128 KB 8-way L1I and 128 KB 8-way L1D.
  - L2: 1 MB 8-way in both (inclusive in YQH, non-inclusive in NH).
  - L3: none in YQH; 6 MB 6-way non-inclusive in NH.
  - TLBs: L1 ITLB 40 in both; L1 DTLB 40 vs 136; STLB 4K vs 2K.
  - Fetch: 8×4 B instructions per cycle in both; decode/rename 6 per cycle in both.
  - ROB/LQ/SQ: 192/64/48 vs 256/80/64.
  - Int/FP physical registers: 160/160 vs 192/192.
  - Instruction fusion and move elimination: NH only.
  - Source: [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- NH microarchitecture:
  - Decoupled BPU and IFU; the BPU "runs ahead" and fills an FTQ.
  - 4-table 16K-entry TAGE-SC plus an indirect-jump predictor.
  - Macro-op fusion at decode, to reduce latency and enlarge the effective ROB and IQ.
  - Separate int and FP register files; move elimination uses reference counting on integer physical registers.
  - Distributed reservation stations of 32 or 16 entries, each issuing 2 or 1 per cycle.
  - Cascade FMA with 5-cycle latency, allowed to start early once the multiply operands are ready.
  - Two bank-interleaved load pipelines; stores are split into address (STA) and data (STD) micro-ops.
  - L1 DTLB of 128 direct-mapped plus 8 fully-associative entries.
  - VIPT 128 KB L1I and L1D with a hardware fix for aliasing.
  - Non-inclusive L2 and L3; best-offset prefetcher; 2048-entry L2TLB.
  - 63K lines of Chisel; the first generation took 10 months.
  - Source: [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- YQH is described as an 11-stage pipeline — [XiangShan MICRO'25 tutorial](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- The NH upgrade list: new decoupled branch prediction and fetch; better scheduler; instruction fusion and move elimination; new L2/L3 with hybrid prefetchers — [XiangShan MICRO'25 tutorial](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)

#### XiangShan Kunminghu (KMH, gen 3), Hot Chips 2024 + design docs + code
- Front end:
  - First-level 256-entry BTB, then a 2K-entry BTB with an optional L2 BTB.
  - 16K-entry TAGE-SC, 2K-entry ITTAGE, 48-entry RAS.
  - 64 KB 4-way ICache, 48-entry ITLB and a fetch-directed instruction prefetcher.
  - Source: [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- Pipeline:
  - 13 stages, 16-cycle branch-mispredict penalty, 3-cycle best-case L1 load-to-use, 2 branch predictions per cycle.
  - Branch prediction in 3 stages: micro-BTB; then BTB and TAGE; then ITTAGE, SC and RAS.
  - Fetch in 4 steps: FTQ; ICache access; RVC expansion of up to 16 instructions per cycle; branch-fault check and instruction-buffer write.
  - 1-cycle decode (2 cycles for vector).
  - Issue in 3 stages: issue, register read (2 cycles for FP/vector), bypass.
  - Source: [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- Back end:
  - 6-wide decode, rename and dispatch.
  - Physical registers: 224 int, 192 FP, 128 vector.
  - Move elimination and instruction fusion.
  - 160-entry ROB that compresses up to 6 ops per entry and retires up to 8 entries per cycle.
  - Recovery by checkpoint plus rollback, with a 256-entry rename buffer between commit and rename-table update.
  - Source: [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf); same widths, ROB, PRF and 256-entry RAB in [XiangShan design doc: backend](https://docs.xiangshan.cc/projects/design/en/latest/backend/)
- Execution units:
  - 4 ALUs (2 with a 3-stage multiplier), 3 branch units and 1 SRT radix-16 divider.
  - 4 FPUs plus 2 FP dividers; 3-cycle FP add/multiply and 5-cycle FMA.
  - 4 vector units plus 1 vector divider (RVV 1.0, VLEN 128).
  - Source: [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- Memory side:
  - 3 load pipes and 2 store pipes; 72 loads and 64 stores in flight.
  - 48-bit virtual / 52-bit physical addresses.
  - 48-entry L1 DTLB and 2K-entry L2 TLB; up to 7 outstanding page walks; nested walks for the H extension.
  - 64 KB 8-way VIPT L1D with hardware anti-aliasing and a way predictor.
  - Composite prefetchers: stream, stride, SMS, BOP and temporal.
  - Private L2: 8-way, up to 1 MB, 10-cycle load-use, 64+ outstanding transactions.
  - Shared L3: 16-way, up to 16 MB, about 30-cycle load-use.
  - Source: [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- Mechanisms visible in the current source tree:
  - The memory-dependence predictor directory contains a store-set implementation and a wait table.
  - The load queue is split into a virtual (allocation) LQ, a RAR queue, a RAW queue, a replay queue and an uncached-load queue; the store queue has a virtual counterpart.
  - Issue queues are built from age detectors (age matrix), separate enqueue and other entries, a multi-wakeup queue and FU-busy tables.
  - Sources: [XiangShan src: mdp](https://api.github.com/repos/OpenXiangShan/XiangShan/contents/src/main/scala/xiangshan/mem/mdp), [XiangShan src: lsqueue](https://api.github.com/repos/OpenXiangShan/XiangShan/contents/src/main/scala/xiangshan/mem/lsqueue), [XiangShan src: issue](https://api.github.com/repos/OpenXiangShan/XiangShan/contents/src/main/scala/xiangshan/backend/issue)
- XiangShan "MinimalConfig" (current master), a useful small-core sizing reference:
  - Decode and rename stay 6-wide; commit 8.
  - ROB 48, RAB 96, FTQ 8, instruction buffer 24.
  - 64 int physical registers; 160 shared FP/vector.
  - Every issue queue 10 entries.
  - Virtual LQ 24, RAR 24, RAW 12, replay 24; SQ 20; store buffer 4.
  - FTB 256 entries 2-way; RAS 8 plus 16 speculative.
  - TAGE 3 tables (512/512/1024), SC 2×128, ITTAGE 3 tables (256/256/512).
  - ICache 16 KB; DCache 32 KB 8-way with 4 MSHRs.
  - Separate FPGA configs exist (e.g., FpgaDefaultConfig with 1 MB L2 and 3 MB L3; FpgaDiffMinimalConfig).
  - Source: [XiangShan Configs.scala](https://raw.githubusercontent.com/OpenXiangShan/XiangShan/master/src/main/scala/top/Configs.scala)
- Interconnect and SoC: CHI, AXI4 and TileLink; directory-based optional cluster L3; AIA, IOMMU and debug/trace support — [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- Generation and branch status (README updated 2026-06-30):
  - Yanqihu and Nanhu-V2: minimum maintenance.
  - Nanhu-V5 (external OpenNanhu-V5): active.
  - Kunminghu-V2: maintained and recommended for research and downstream use.
  - Kunminghu-V3: under active, unstable development.
  - Source: [XiangShan README (kunminghu-v3)](https://cdn.jsdelivr.net/gh/openxiangshan/xiangshan@kunminghu-v3/README.md)

#### XuanTie C910 / OpenC910 (ISCA 2020, Hot Chips 32, Chips and Cheese) and successors
- ISA and pipeline:
  - RV64GCV (RVV 0.7.1) plus more than 50 custom instructions.
  - 12-stage pipeline. The front end spans 7 stages (IF, IP, IB, ID, IR, IS, RF), followed by EX1–EX4 and RT1–RT2.
  - IF fetches 128 bits (up to 8 instructions); IP packs up to 8; IB sends up to 3 to decode.
  - Decode 3; rename up to 4; issue up to 8.
  - Source: [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- Execution units: 2 single-cycle ALUs, 1 branch unit, a dual-issue LSU (1 load plus 1 store, with store-address and store-data pipes), 2 scalar FP units and 2 vector units. Issue queues pick by age vector with dynamic load balancing. The ROB holds up to 192 instructions — [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- Front end:
  - 16-entry fully-associative L0 BTB acts at IF (zero-bubble taken branches); the L1 BTB has more than 1K set-associative entries and is checked at IB.
  - Bi-mode/hybrid direction predictor, plus a RAS and an indirect predictor.
  - A two-level prediction-prefetch buffer (BUF1/BUF2) hides SRAM latency so back-to-back and multiple branches per 128-bit line can be predicted.
  - 16-entry loop buffer.
  - Source: [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- LSU and memory system:
  - Four LSU stages (AG, DC, DA, WB), with separate load and store tag RAMs.
  - Load/store-violation prediction tags risky loads and stores; a violation causes a global flush.
  - Two prefetch modes: a global mode with any stride and up to 64 lines of depth, and a multi-stream mode with 8 streams and up to 32 lines of depth. Both include cross-page virtual-address prefetch.
  - Fully-associative micro-TLB plus a 4-way joint TLB; 4K, 2M and 1G pages are supported at every TLB level.
  - 16-bit ASID.
  - 1–4 cores per cluster with an inclusive L2 of up to 8 MB using MOESI and a snoop filter; up to 4 clusters via Ncore.
  - Source: [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- Hot Chips 32 slide claims: "3-decode, 8-issue"; fetch 8 instructions per cycle; 3-cycle load-to-use; 1-cycle store execution; directory-based MOESI with a snoop filter; L1 32 or 64 KB each — [Xuantie-910 Hot Chips 32](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf)
- Measured on TH1520 at 1.85 GHz, front end:
  - IF reads 256 bits plus predecode from both ways of the 64 KB 2-way L1I.
  - L0 BTB: 16 entries; L1 BTB: 1024 entries, 4-way, costing 1 bubble.
  - Bi-mode predictor: a 1024-entry selector, two 16K-entry 2-bit counter tables and a 22-bit global history.
  - 12-entry RAS and 256-entry indirect predictor; about 17.3 KB of predictor storage in total.
  - 32×16-bit instruction queue.
  - Source: [Chips and Cheese: C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- Measured on TH1520 at 1.85 GHz, back end:
  - 3 decoders but at most 4 micro-ops per cycle, with no micro-op queue in front of the 4-wide rename.
  - ROB: 64 entries in the RTL, holding 192 instructions per the paper and microbenchmarks.
  - About 96 int and 64 FP physical registers.
  - The integer register file has 10 read ports.
  - Distributed schedulers with a 7-bit age vector per entry; only 16 entries for common ALU ops.
  - Source: [Chips and Cheese: C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- Measured on TH1520 at 1.85 GHz, memory side:
  - 1 load AGU and 1 store AGU.
  - Load queue of about 12 entries per the RTL (microbenchmarks were confusing).
  - Disambiguation compares only address bits 11:4.
  - Store forwarding works for any load fully contained in a store, except loads crossing 16 B or stores crossing 8 B; failure costs 20+ cycles.
  - 17-entry fully-associative DTLB; 1024-entry 4-way L2 TLB at +4 cycles.
  - L1D: 64 KB, 2-way, 3 cycles, 8 line-fill buffers.
  - L2: 1 MB 16-way inclusive at 60 cycles; DRAM latency 133.9 ns.
  - Source: [Chips and Cheese: C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- BTB size conflict: ISCA'20 says "more than 1K" L1 BTB entries and Chips and Cheese reads 1024 entries, 4-way from the RTL. A 2025 arXiv study is summarized as describing a 4K-entry set-associative L1 BTB (not read in full) — [Fu et al. 2025](https://arxiv.org/pdf/2505.24363)
- OpenC910 repository:
  - Now at XUANTIE-RV/openc910, Apache-2.0, created 2021-10-19, last pushed 2024-06-28, not archived.
  - Contains Verilog RTL, the smart_run testbench (Verilator/iverilog/VCS) and a user manual.
  - No FPGA flow or FPGA numbers in the README; the README links opene902.
  - Sources: [OpenC910 repo metadata](https://api.github.com/repos/XUANTIE-RV/openc910), [OpenC910 README](https://raw.githubusercontent.com/XUANTIE-RV/openc910/main/README.md)
- C920: Chips and Cheese says C920 moved to RVV 1.0 while otherwise keeping the C910 design. A reader comment warns the naming is inconsistent: some call C910 + RVV 0.7.1 "C920", and "C920v2" has RVV 1.0 + bitmanip — [Chips and Cheese: C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910), [C&C comments](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910/comments)
- SG2042: 64 C920 cores at 2 GHz in clusters of 4, each core with 64 KB L1I/L1D, 1 MB L2 shared per cluster, 64 MB L3 and RVV 0.7.1 — [EPCC SG2042 study](https://arxiv.org/html/2309.00381v2)
- SG2044: 64 cores with RVV 1.0 and an upgraded memory subsystem; up to 4.91× SG2042 at 64 cores — [SG2044 study](https://arxiv.org/abs/2508.13840)
- C930 (launched 2025-02-28), secondary reports of vendor material:
  - More than 15 SPECint2006/GHz.
  - 6-wide decode, 16-stage pipeline, RVA23.
  - 512-bit RVV 1.0 plus an 8 TOPS matrix engine.
  - Typical 4-core cluster with 64 KB I/D and 1 MB L2.
  - Sources: [TechNews (zh-TW), Mar 2025](https://technews.tw/2025/03/05/china-to-publish-policy-to-boost-risc-v-chip/), [Xenospectrum](https://xenospectrum.com/china-makes-risc-v-semiconductors-a-national-strategy-alibabas-high-performance-cpu-enters-the-practical-stage/), [ANU LINK list repost, Mar 2025](https://mailman.anu.edu.au/pipermail/link/2025-March/042153.html)
- C950 (announced Mar 2026):
  - 8-wide decode; up to 3.2 GHz on 5 nm.
  - 22+ SPECint2006/GHz base, about 70 at 3.2 GHz.
  - RVV 1.0 plus vector crypto; RVA23.1.
  - L2 256 KB–3 MB, L3 1–8 MB, up to 8 cores per cluster.
  - Sister core C925: 12+/GHz, 34% smaller than C930, 11% better power efficiency.
  - Sources: [CNX: C950](https://www.cnx-software.com/2026/03/25/alibaba-xuantie-c950-a-powerful-rva23-complaint-64-bit-risc-v-core-for-edge-ai-computing/), [The Register: C950](https://www.theregister.com/2026/03/25/alibaba_damo_xuantie_c950_chip/); a 16-stage pipeline is reported by [CircuitDigest: C950](https://circuitdigest.com/news/alibaba-unveiled-xuantie-c950-high-performance-risc-v-core-for-edge-ai)

#### SiFive P550 / P650 / P670
- P550 (announced June 2021): 13-stage, triple-issue OoO, RV64GC — [SiFive P550 press release](https://www.businesswire.com/news/home/20210622005290/en/SiFive-Performance-P550-Core-Sets-New-Standard-as-Highest-Performance-RISC-V-Processor-IP)
- P550 measured in Eswin EIC7700X (4 cores at 1.4 GHz, TSMC 12FFC, 4 MB L3), front end:
  - 9.1 KiB direction table.
  - Single-level 32-entry BTB that handles taken branches with zero bubbles; past 32 branches, one taken branch every 3 cycles.
  - 16-entry RAS.
  - 32 KB 4-way L1I at 12 B/cycle; sustains 3 IPC from L1I.
  - Source: [Chips and Cheese: P550](https://chipsandcheese.com/p/inside-sifives-p550-microarchitecture)
- P550 back end and memory system:
  - FP scheduler: 28 entries.
  - 1 load AGU and 1 store AGU.
  - Fast store forwarding only on exact, aligned address match; misaligned accesses trap (1,062 cycles for a load, 741 for a store).
  - L1D 32 KB 4-way, 3 cycles.
  - L2 256 KB 8-way, 13 cycles; L3 about 38 cycles.
  - 32-entry fully-associative ITLB and DTLB; 512-entry L2 TLB at 9 cycles.
  - Directory coherence.
  - Source: [Chips and Cheese: P550](https://chipsandcheese.com/p/inside-sifives-p550-microarchitecture)
- The P550 integer scheduler has 40 entries across 3 ALU ports, versus 16 for C910's common ALU ops — [Chips and Cheese: C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- P650 (Dec 2021):
  - 13-stage, four-issue OoO, RV64GCB, Sv39/Sv48.
  - More than 11 SPECint2006/GHz (vendor estimate), about 40% per clock over P550.
  - Up to 16 cores; private L2, streaming prefetcher, L3 stashing.
  - Sources: [CNX: P650](https://cnx-software.com/?p=93869); 3.5 GHz maximum per [eeNews: P650](https://www.eenewseurope.com/news/sifive-claims-fastest-risc-v-processor-core-p650)
- P670 (late 2022): more than 12 SPECint2006/GHz, 2×128-bit vector units; P650 is described as P670 without the vector units. This comes from a search-engine summary because the page could not be fetched — [WikiChip: P670](https://fuse.wikichip.org/?p=7318)

#### Andes AX45 / AX65 / AX66
- **Correction to the brief:** AX45MP is not OoO. It is an in-order, dual-issue, 8-stage core:
  - 5.63 CoreMark/MHz and 3.27 DMIPS/MHz (no-inline Dhrystone rules).
  - L1 8–64 KB, L2 128 KB–8 MB, Sv39/Sv48.
  - Source: [Andes AX45MP page](https://www.andestech.com/en/products-solutions/andescore-processors/riscv-ax45mp/)
- AX65 (general-availability release; the exact date was not captured, roughly 2023–24): 13-stage, 4-wide decode, 8-wide OoO execution; more than 2.0 GHz at 12 nm; 8.25 SPECint2006/GHz (vendor; claimed above Cortex-A75) — [Andes AX65 GA release](https://www.design-reuse.com/news/55479/andes-risc-v-out-of-order-superscalar-multicore-processor.html) (via search summary)
- AX66 (announced 2024-10-18): same pipeline and widths as AX65, plus RVV, vector crypto, H, AIA, CHI multi-cluster (up to 8 cores per cluster, shared L3 up to 32 MB) and RVA23 — [Andes AX66 release](https://us.design-reuse.com/news/56937/andes-andescore-ax66-rva23-multi-cluster-hypervisor-and-android.html). A secondary source says AX66/AX46 add +15% integer performance over AX65/AX45 — [XPU.pub: AX66](https://xpu.pub/?p=1200)

#### Ventana Veyron V1 / V2
- V1 (Hot Chips 2023), front end:
  - "Eight-wide" OoO core with a 15-cycle mispredict pipeline.
  - Single-level 12K-entry BTB with single-cycle next lookup; 3-cycle redirect on a BTB miss.
  - 512 KB instruction cache acting as both L1 and L2; up to 64 B/cycle misaligned fetch.
  - Source: [Chips and Cheese: Veyron V1 at HC2023](https://chipsandcheese.com/p/hot-chips-2023-ventanas-unconventional-veyron-v1)
- V1, back end and memory:
  - Single-level 3K-entry ITLB and DTLB (no L1 DTLB).
  - 64 KB VIVT L1D, 4 cycles, ASID-tagged; L2 hit 11–12 cycles.
  - Four combined int/memory ports; scalar FP only.
  - TSMC 5 nm; 16-core clusters with 3 MB L3 per core.
  - Target 3.6 GHz.
  - Source: [Chips and Cheese: Veyron V1 at HC2023](https://chipsandcheese.com/p/hot-chips-2023-ventanas-unconventional-veyron-v1)
- V2 (Nov 2023): up to 32 RVA23 cores per chiplet, up to 3.85 GHz, 512-bit RVV 1.0 plus a matrix unit, large shared L3 — [The Register: Veyron V2](https://www.theregister.com/2023/11/07/ventana_riscv_server/). A 3.6 GHz figure also circulates, so the clock is unresolved.
- Qualcomm acquired Ventana on 2025-12-10 — [The Register: Qualcomm buys Ventana](https://www.theregister.com/2025/12/10/qualcomm_riscv_arm_ventana/)

#### Tenstorrent Ascalon
- Roadmap disclosure, April 2023:
  - 8-wide decode; 6 integer ALUs and 2 branch units; 3 load/store pipes.
  - 2 FPU/SIMD pipes, each 256 bits.
  - 128 KB 8-way L1D; 32 B/cycle fetch; TAGE-type predictor.
  - ROB not disclosed.
  - Source: [HWCooling: Ascalon (Apr 2023)](https://www.hwcooling.net/en/?p=147287)
- Licensing coverage, Oct 2025: 8 decoders; 6 ALUs, 2 of which also handle branches; 3 LS units; 2 FP plus 2×256-bit vector datapaths. IPC is said to approach Arm Cortex-X — [XPU.pub: Ascalon X (Oct 2025)](https://xpu.pub/?p=1830)
- TT-Ascalon X is an 8-wide-decode OoO RVA23 core — [Design&Reuse: TT-Ascalon X](https://www.design-reuse.com/ip/view/RV_161/tt-ascalon-x-out-of-order-superscaler-risc-v-cpu)
- A search-engine summary of Tenstorrent's IP page said the Ascalon decoder scales from 2-wide to 8-wide across the X/H/S/U variants. A direct fetch of the page returned no content, so this is unverified — [Tenstorrent Ascalon IP page](https://tenstorrent.com/ip/ascalon)

### Inferences
- Consolidated sizing ladder, from the findings above:

| Core (date) | Decode/rename | ROB | Int/FP PRF | Int IQ (organization) | LQ/SQ | Notes |
|---|---|---|---|---|---|---|
| BOOM Small v3 (2020) | 1 | 32 | 52/48 | 8, collapsing | 8/8 | TAGE-L |
| BOOM Medium v3 | 2 | 64 | 80/64 | 20 (2-issue), collapsing | 16/16 | 16 KiB L1s |
| BOOM Large v3 | 3 | 96 | 100/96 | 32 (3-issue) | 24/24 | 32 KiB L1s |
| C910 (2019) | 3 dec / 4 ren | 64 entries (≤192 instr) | ~96/~64 | ~16 ALU, age vectors | ~12/? | 64 KB L1s |
| P550 (2021) | 3 | n/a (> A75) | n/a | 40 across 3 ALU ports | "thin" | 32 KB L1s |
| XS MinimalConfig (2026) | 6 | 48 | 64/160 (FP+vector) | 10 per IQ | 24 (+RAR 24/RAW 12)/20 | small TAGE-SC/ITTAGE |
| XS Nanhu (2022) | 6 | 256 | 192/192 | 16–32 RS | 80/64 | 128 KB L1s |
| XS Kunminghu (2024) | 6 | 160 compressed | 224/192/128 vec | age-matrix IQs | 72/64 | 3 load / 2 store pipes |

- C910's 64 RTL ROB entries holding 192 instructions implies grouped entries, about 3 instructions per entry, matching its 3-wide decode. Kunminghu does the same explicitly (up to 6 ops per entry). Both write the ROB once per dispatch group.
- For a 2-wide clean-room core, BOOM Medium (64 ROB, 80 int registers, 16/16 LQ/SQ, 20-entry int IQ) and XiangShan's MinimalConfig (48 ROB, 64 int registers, 10-entry IQs, 24/20 LQ/SQ) bracket a sensible window on a small FPGA.

### Gaps
- No primary Kunminghu design-doc pages for IQ sizes, FTQ depth, store-set SSIT/LFST sizes or LQ-RAR/RAW sizes for the default config could be fetched (sub-page URLs 404). Only HC2024 totals and code-directory evidence are cited.
- C910 store queue size and issue-queue sizes per queue are not given in the fetched sources.
- P550/P650/P670 ROB, PRF and LSQ sizes are not published (Chips and Cheese gives only qualitative comparisons).
- Ascalon ROB, PRF, pipeline depth and SPEC numbers were not found. AX65's ROB/IQ sizes were not found.
- No other open-sourced T-Head OoO core was found. The OpenC910 README only links opene902, and the full XUANTIE-RV repo list was too long to read completely, so this was not verified exhaustively.
- No public BOOM v4 design description or paper exists. v4 content is inferred only from commit messages.

## Key question 2: Published performance (CoreMark/MHz, DMIPS/MHz, SPECint2006/2017 per GHz, IPC) with configuration, date and source

### Takeaway
Per-clock performance spans roughly 2–3× across this group. BOOMv2 had a SPEC06 IPC of 0.42 against 0.86 for SonicBOOM. C910 scores 6.11 SPECint2006/GHz, P550 8.65 (vendor), Nanhu about 8.5–10, Kunminghu V2 about 14.7, C930 above 15 (vendor) and C950 above 22 (vendor). CoreMark/MHz ranges from 3.9 (BOOM 2-wide, v1 era) and 5.3 (Yanqihu) to 6.2 (SonicBOOM, with short-forward-branch predication) and 7.1 (C910). In-order dual-issue commercial cores reach 5.1–5.6. CoreMark therefore separates OoO from good in-order cores poorly, while SPEC-class workloads do. Many headline numbers are vendor estimates or simulations with differing compilers, so comparisons are fragile.

### Cited Findings

#### BOOM
- SonicBOOM (2020):
  - 6.2 CoreMark/MHz (abstract); 6.15 with SFB enabled vs 4.9 without (body text).
  - DMIPS/MHz 3.93 vs BOOMv2 1.91.
  - SPEC06 IPC 0.86 vs BOOMv2 0.42 (riscy-OOO 0.48).
  - "2x higher IPC on SPEC CPU" than any prior open-source OoO core.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- SonicBOOM evaluation setup:
  - FireSim on AWS F1 at 30 MHz, modeling a 3.2 GHz system.
  - 32 KB L1I, 32 KB L1D, 512 KB L2, 4 MB simulated L3, 16 GB DRAM.
  - SPEC built with gcc -O3 and instruction-alignment flags.
  - On SPEC17 intspeed it is "competitive with" AWS Graviton (A72-like) and matches Skylake on some benchmarks.
  - The paper's Figure 1 config (4-wide fetch, 8-wide issue) is called Graviton-competitive.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- SonicBOOM was physically synthesized at 1 GHz on a commercial FinFET process, the same as BOOMv2 — [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- BOOM v1-era (Celio thesis data, cited by T-Head in 2020): BOOM-2w 3.91 and BOOM-4w 4.7 CoreMark/MHz — [Xuantie-910 Hot Chips 32](https://hc32.hotchips.org/assets/program/conference/day1/HotChips2020_Edge_Computing_Xuantie910_v1.1.pdf)
  - The same chart's bars are labeled rocket, NXF, BOOM-2w, BOOM-4w, SweRV, SCR7, U74 and Xuantie910, with values 2.32, 3.22, 3.91, 4.7, 4.9, 5, 5.1 and 7.1.
  - The label-to-value mapping is read from bar order in a text extraction. The ISCA paper's text gives SweRV "up to 5.0" and U74 5.1, so treat the mid-chart mapping as approximate.
- BOOMv2 (2017) lost up to 20% IPC on CoreMark relative to BOOMv1 in exchange for timing — [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- BOOM measured on FPGA by the RSD authors (FPT 2019):
  - Config: RV32IMAC, same front-end width and ROB size as RSD, 8 KB L1s, 1-cycle main memory.
  - 1.06 DMIPS/MHz with hardware divide and 1.03 without.
  - For comparison, RSD reached 2.04 DMIPS/MHz.
  - Source: [RSD FPT'19 preprint](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
  - This conflicts with the 1.91–3.93 DMIPS/MHz above; the build, flags and version differ.

#### XiangShan
- YQH silicon (28 nm, chip back early 2022):
  - SPECint2006 7.03/GHz and SPECfp2006 7.00/GHz at 1 GHz with DDR4-1600.
  - FPGA with a fixed 90-cycle AMAT: 6.87/7.23 per GHz.
  - RTL simulation with DDR4-2400: 7.67/GHz.
  - Source: [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- YQH CoreMark: 5.3 CoreMark/MHz (gcc 9.3.0 -O2) — [XiangShan MICRO'25 tutorial](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- NH, MICRO'22:
  - 10.06/GHz SPEC CPU2006 in RTL simulation at 2 GHz with DDR4-2400 and representative program fragments.
  - On FPGA with 4 MB LLC and 250-cycle AMAT: 7.94 (int) and 9.27 (fp) per GHz.
  - Source: [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- NH estimate dated Jan 5, 2023: SPECint2006 19.10 and SPECfp2006 22.18 at 2 GHz. Setup: RTL sim, DDR4-2400 under DRAMsim3, GCC 10.2 -O2, RV64GCB; "confirmed on FPGA as well" — [XiangShan MICRO'25 tutorial](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- NH at Hot Chips 2024: SPECint2006 16.94 and SPECfp2006 19.42 at 2 GHz. Setup: GCC 12 -O3, jemalloc, 64 KB I$/D$, 256 KB L2, 4 MB L3, DDR4-3200 with 70 ns latency — [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- NH V2 silicon (launched 2021.06, sign-off 2022.11, chip back 2023.04): 2.5 GHz, SPEC CPU2006 about 10/GHz — [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf), [Bao, RISC-V Summit Europe 2025](https://riscv-europe.org/summit/2025/media/proceedings/2025-05-14-RISC-V-Summit-Europe-09h30-BAO-slides.pdf)
- KMH at Hot Chips 2024 (Aug 2024): SPECint2006 44.00 at 3 GHz. A 47.63 figure is shown for fp, and a 49.96 value is marked "with compiler optimizations". The slide extraction is ambiguous about which column each belongs to. Setup: 64 KB I$/D$, 1 MB L2, 16 MB L3 — [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- KMHv2 (May 2025):
  - SPECint2006 estimate 14.7/GHz and SPECfp2006 14.62/GHz; base scores at 3 GHz 44.1 (int) and 43.86 (fp).
  - Setup: SimPoint sampling, GCC 12 -O3, RV64GCB, jemalloc, 64 KB I/D, 1 MB L2, 2× DDR4-3200, 3×5 mesh with 8×2 MB LLC.
  - KMHv2 "ready to tape-out".
  - KMHv3 under development at about +30% on SPEC06 and +33% on SPEC17 over KMHv2.
  - Source: [Bao, RISC-V Summit Europe 2025](https://riscv-europe.org/summit/2025/media/proceedings/2025-05-14-RISC-V-Summit-Europe-09h30-BAO-slides.pdf)
- KMHv2 poster (May 2025): SPECint2006 geomean 44.61 and SPECfp2006 47.48 at 3 GHz; "1.5x IPC of XS Gen2" — [Tang et al. poster, RVSE 2025](https://riscv-europe.org/summit/2025/media/proceedings/2025-05-13-RISC-V-Summit-Europe-P2.1.06-TANG-poster.pdf)
- Secondary reports: about 15/GHz (KMH V2), and a state-media figure of 16.5/GHz said to come from SpacemiT test chips. Treat both as unverified — [Hackernoon](https://hackernoon.com/the-open-chip-revolution-has-reached-the-real-world)
- An "XiangShan-parameter-aligned" gem5 model scored 7/GHz, 30% below XiangShan RTL — [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)

#### C910 / C920 / C930 / C950
- C910 (ISCA 2020):
  - 7.1 CoreMark/MHz (40% above U74's 5.1).
  - SPECint2006 6.11/GHz vs Cortex-A73's 6.75/GHz.
  - Config: 64 KB L1I/L1D and 2 MB L2 to match the Kirin 970 A73; GCC 8.1 -O2.
  - Custom ISA extensions plus the tuned compiler add about 20% over native RISC-V + compiler. It is not stated whether the 6.11 includes them.
  - 2.0 GHz (LVT, 0.8 V) to 2.5 GHz (30% ULVT, 1.0 V) at TSMC 12 nm; 2.8 GHz in a 7 nm experiment.
  - Source: [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- C910 vs P550, SPEC CPU2017 (2025):
  - The C910 (TH1520, 1.85 GHz) wins no SPECint2017 test against the P550 at 1.4 GHz.
  - P550 exceeds 2 IPC on 548.exchange2 and 525.x264; C910 "struggles to use its 3-wide width"; on x264, P550 runs close to 3 IPC vs C910's 1.38.
  - Source: [Chips and Cheese: P550 vs C910 benchmarks](https://chipsandcheese.com/p/a-risc-v-progress-check-benchmarking)
- C910 vs CVA6 (Fu et al. 2025, 22 nm, same Cheshire SoC):
  - C910: +119.5% IPC for +75% area over single-issue in-order CVA6.
  - Dual-issue in-order CVA6S+: +34.4% IPC for +6% area.
  - C910 is "highly competitive" in GOPS/W.
  - Source: [Fu et al. 2025](https://arxiv.org/abs/2505.24363)
- C930: more than 15 SPECint2006/GHz (vendor, Feb 2025) — [Xenospectrum](https://xenospectrum.com/china-makes-risc-v-semiconductors-a-national-strategy-alibabas-high-performance-cpu-enters-the-practical-stage/)
- C950: 22+/GHz (about 70 at 3.2 GHz), said to be "three times faster" than C920. C925: 12+/GHz (vendor, Mar 2026) — [CNX: C950](https://www.cnx-software.com/2026/03/25/alibaba-xuantie-c950-a-powerful-rva23-complaint-64-bit-risc-v-core-for-edge-ai-computing/)

#### Other commercial cores
- P550: 8.65 SPECint2006/GHz (vendor, Jun 2021) — [SiFive P550 press release](https://www.businesswire.com/news/home/20210622005290/en/SiFive-Performance-P550-Core-Sets-New-Standard-as-Highest-Performance-RISC-V-Processor-IP). A reader comment cites 8.9 (unverified) — [CNX: P650](https://cnx-software.com/?p=93869)
- P650: above 11/GHz (vendor estimate, Dec 2021) — [CNX: P650](https://cnx-software.com/?p=93869)
- P670: above 12/GHz (vendor) — [WikiChip: P670](https://fuse.wikichip.org/?p=7318)
- AX65: 8.25/GHz (vendor) — [Andes AX65 GA release](https://www.design-reuse.com/news/55479/andes-risc-v-out-of-order-superscalar-multicore-processor.html)
- AX45MP (in-order): 5.63 CoreMark/MHz and 3.27 DMIPS/MHz — [Andes AX45MP page](https://www.andestech.com/en/products-solutions/andescore-processors/riscv-ax45mp/)

### Inferences
- Derived per-GHz figures:
  - NH: 19.10/2 = 9.55/GHz (Jan 2023, -O2) and 16.94/2 = 8.47/GHz (HC2024, smaller 256 KB L2 / 4 MB L3).
  - KMH: 44.0/3 ≈ 14.7/GHz.
  - KMHv3, if the +30% materializes: about 19/GHz.
  - C950: about 21.9/GHz.
- The NH spread of 8.5–10.1/GHz across sources is driven by cache configuration and compiler, not RTL. For calibration, use the same compiler, flags and memory model across cores.
- A 2-wide core that wants to "beat NaxRiscv on IPC" should be benchmarked on more than CoreMark. In-order dual-issue cores already reach 5.1–5.6 CoreMark/MHz (U74, AX45MP), and a single trick (SFB predication) moves BOOM by about 25% on CoreMark alone.
- BOOMv2's SPEC06 IPC of 0.42 shows what a 2-wide OoO with a weak front end (GShare, no RAS repair, 1-wide D$) delivers. SonicBOOM's 0.86 shows the gain from fixing the front end and LSU.

### Gaps
- No SPEC numbers were found for SonicBOOM MediumBoom (2-wide) specifically. The paper's SPEC configuration is not explicitly named.
- No independent (non-vendor) SPEC2006 results were found for P550/P650/P670, AX65, C930 or C950.
- No SPEC or CoreMark numbers were found for Veyron V1/V2 or Ascalon.
- No published CoreMark/MHz for P550 or Kunminghu was found.

## Key question 3: FPGA prototyping cost (LUT/FF/BRAM/DSP, Fmax) and why these designs are FPGA-unfriendly

### Takeaway
Published FPGA numbers for these cores are sparse, and all point the same way: ASIC-oriented OoO cores run at 30–70 MHz on large FPGAs and use tens to hundreds of thousands of LUTs.
- BOOM: MegaBoom at 50 MHz on VCU118 (Rocket: 100 MHz); SonicBOOM at 30 MHz on F1; a 2-wide RV32 BOOM at 71.7 MHz on a Zynq-7020 using about 2.8× the LUTs of the FPGA-optimized RSD.
- XiangShan: Nanhu at 50 MHz on VU19P using about 564K LUTs.
- C910: the outlier, with a VU9P edition at 200 MHz deployed by Alibaba (config unstated) and 60 MHz on HAPS-80.

The root causes are documented: flip-flop multiported register files and rename/ROB tables, wide CAMs (wakeup, LSQ, fully-associative BTB/TLB), and deep single-cycle loops such as select-wakeup and branch-predictor redirect.

### Cited Findings

#### BOOM on FPGA
- 2016 mailing-list data (Celio): a single-core, L1-only BOOM uses about 50% of LUTs, 9% of FFs and 5% of BRAMs.
  - Config: 2-wide / 3-issue, 48-entry ROB, 16 LSU entries, 7R3W register file, roughly Cortex-A9 size.
  - The board is implied to be a ZC706 but was not confirmed.
  - Suggested shrink options: 2-issue (5R3W register file), integer-only, or an 8-entry LSU.
  - Source: [riscv-boom mailing list, Nov 2016](https://groups.google.com/g/riscv-boom/c/sBv6-eheAAo)
- RSD paper (FPT 2019), BOOM on Zynq XC7Z020-1:
  - Synthesized with Synplify; caches excluded from resource counts; RV32 config.
  - Fmax: BOOM 71.7 MHz, RSD 95.3 MHz, OPA 134 MHz.
  - RSD uses 36% of BOOM's LUTs and 40% of its registers; RSD itself is 15,379 LUTs and 8,584 registers with its FPGA-optimized multiport RAMs.
  - BOOM uses 3 BRAMs (branch predictor).
  - BOOM's FPGA critical path is its global branch predictor; BOOM "is not optimized for an FPGA".
  - Source: [RSD FPT'19 preprint](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- Chipyard prototypes:
  - VCU118: BoomVCU118Config (MegaBoomV3) is set to 50 MHz; RocketVCU118Config runs at 100 MHz — [Chipyard VCU118 configs](https://raw.githubusercontent.com/ucb-bar/chipyard/main/fpga/src/main/scala/vcu118/Configs.scala)
  - Arty100T: Rocket-only configs at 50 MHz; no BOOM config — [Chipyard Arty100T configs](https://raw.githubusercontent.com/ucb-bar/chipyard/main/fpga/src/main/scala/arty100t/Configs.scala)
- FireSim: SonicBOOM SPEC/CoreMark evaluation ran on AWS F1 FPGAs at 30 MHz. Fromajo (Dromajo co-simulation inside FireSim) runs above 1 MHz — [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Survey abstracts with numbers not retrieved:
  - Dörflinger et al. (CF'21) evaluated Rocket, BOOM, CVA6 and SHAKTI on Virtex UltraScale+ and 22FDX. Rocket was best on FPGA resource use and energy efficiency, BOOM best on ASIC performance, with up to 3.1× differences — [Dörflinger et al. CF'21 abstract](https://research.uni-luebeck.de/en/publications/a-comparative-survey-of-open-source-application-class-risc-v-proc/)
  - Lazzeri et al. (DFT 2024) compared BOOM, NOEL-V and CVA6 on Kintex-7 for area, power and performance — [Lazzeri et al. DFT'24](https://re.public.polimi.it/handle/11311/1286074)

#### XiangShan on FPGA
- Prototyping on an S2C Prodigy S7-19P (VU19P) ran at 50 MHz overall. SPEC and Linux with a GUI were run, along with flash, GMAC and PCIe daughter cards — [S2C BOSC case study](https://www.s2cinc.com/customer-case/bosc)
- MICRO'22 FPGA observations:
  - More than 150 hours to run SPEC CPU2006 on one FPGA at 50 MHz.
  - DDR runs at 1.6 GHz while the CPU runs at 50 MHz, giving about one CPU-cycle DRAM latency, so 250 padding cycles were added. FPGA SPECint results are therefore "conservative".
  - NH-on-FPGA used a smaller LLC (4 MB or 2 MB vs 6 MB) "due to limited BRAM resources".
  - Source: [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- Nanhu on VU19P (Vivado 2020.2):
  - 564,211 LUTs, 278,746 FFs and 436.5 BRAMs; about 8.45 W.
  - A vector-dot-product extension (nanhu-vdot) added 15,677 LUTs (+2.8%) and 2,486 FFs (+0.9%).
  - The search summary of this paper says the minimal Nanhu configuration was chosen to save FPGA resources. The paper's Chinese body text could not be machine-extracted to confirm that this table is the minimal config.
  - Source: [Chen et al., Nanhu-vdot (arXiv 2409.00661)](https://arxiv.org/pdf/2409.00661)
- NEXST FPGA environment (as of Oct 2025):
  - Boards: VU37P (VCU128, U280, ICT NM37) and VU19P (Corigine MimicTurbo, ICT NP19A).
  - Configs: octa-core Rocket-H, single- and dual-core Nanhu-G, and single-core Kunminghu.
  - DiffTest-H hardware co-simulation runs at 13.8 MHz on FPGA.
  - Source: [XiangShan MICRO'25 tutorial](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
- KMHv2 plus a WYH NoC SoC passed 2-, 4- and 8-core emulation/FPGA tests — [Bao, RISC-V Summit Europe 2025](https://riscv-europe.org/summit/2025/media/proceedings/2025-05-14-RISC-V-Summit-Europe-09h30-BAO-slides.pdf)

#### C910 on FPGA
- The FPGA implementation runs on a Xilinx VU9P at 200 MHz under Linux and was deployed in "several hundred" FPGAs in Alibaba Cloud data centers. It was used for application acceleration with custom and vector extensions and is claimed 20% faster per core than a 2.5 GHz Xeon Platinum 8163 on blockchain transactions — [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- The prefetch experiments in the same paper ran on a HAPS80-S26 FPGA at 60 MHz, with memory latency padded to about 200 CPU cycles — [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- The OpenC910 README documents no FPGA flow or numbers — [OpenC910 README](https://raw.githubusercontent.com/XUANTIE-RV/openc910/main/README.md)

#### Documented reasons for FPGA- or physical-design unfriendliness
- BOOMv1 critical paths in 28 nm: issue-select, rename busy-table read, conditional-predictor redirect and register-file read. Register-file read became the dominant critical path after place-and-route — [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- Register file: the multiported file failed to synthesize cleanly (wire shorts from 18 wires per bit) and needed hand-placed standard-cell bit cells with hierarchical bitlines — [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- BTB: about 40 entries was the practical limit for a fully-associative flip-flop BTB, so it was rewritten as set-associative SRAM — [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- Issue window: a 20-entry, 3-port unified issue window was "aggressive" and was split into three 16-entry queues — [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- Multiport RAMs on FPGA:
  - Commercial FPGAs usually lack RAM primitives with two or more write ports.
  - BOOM and OPA implement their multiport structures (register file, map table, ready bits, ROB state, payload RAM) in flip-flops plus logic.
  - Rebuilding them with I-LVT and banked RAM cut RSD by 45% in LUTs and 36% in registers and raised Fmax by 6%.
  - Source: [RSD FPT'19 preprint](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- Wakeup/select: on FPGA the select-wakeup loop limits Fmax. Synthesized alone on XC7Z020, the scheduler circuits reached 105.8–128.3 MHz for 16–32-entry IQs, falling as the IQ grows. In the full RSD design the branch predictor became the critical path at about 95 MHz. Dependency-matrix wakeup with a shadow copy for speculative-scheduling recovery is the largest LUT consumer — [RSD FPT'19 preprint](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- C910 port and imbalance pressure: the integer register file has 10 read ports, there are 8 execution ports, and per-entry age vectors are used — [Chips and Cheese: C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)

### Inferences
- The RSD ratios imply a 2-wide RV32 BOOM (2019 vintage, caches excluded) of roughly 42.7K LUTs and 21.5K registers on a Zynq-7020: 15,379 / 0.36 and 8,584 / 0.40. The same method gives OPA about 20.2K LUTs, which agrees with an independent figure of about 20.5K, so the method is consistent.
  - An RV64GC MediumBoom with FPU, MMU and L1s would be substantially larger. That is consistent with the 2016 "about 50% of a large Zynq" data point.
  - A 35–45K-LUT/core budget therefore cannot hold BOOM-style FF-based structures plus a 64-bit datapath and FPU. FPGA-native structures (LUTRAM/BRAM with LVT or banking, narrow CAMs) are mandatory.
- A Nanhu build of about 564K LUTs is several times the whole KV260 programmable logic (XCK26 is about 117K LUTs; figure not re-verified here). Kunminghu is only supported on VU19P-class boards. XiangShan and C910 RTL are reference material, not candidates for porting.
- C910's 200 MHz on a 16 nm VU9P is the strongest evidence that a commercially engineered 3-wide OoO RISC-V core can close timing at about 4× BOOM's FPGA clock. The ISCA paper does not say whether the FPGA edition was a reduced configuration (e.g., without vector or with smaller L2). Treat it as a ceiling indicator, not a reproducible number.
- On UltraScale+, BRAM/URAM give 1–2 ports per block, LUTRAM gives 1W/nR, and carry chains and wide muxes are relatively cheap. Wakeup CAMs and multi-write register files are the costly parts. This matches the RSD and BOOM evidence above.

### Gaps
- No LUT/FF/BRAM/DSP numbers were found for SonicBOOM Small/Medium/Large on VCU118, ZCU102, Arty or F1. The Dörflinger and Lazzeri tables were not accessible.
- No LUT numbers were found for OpenC910 on any FPGA, or for Kunminghu.
- The XiangShan VU19P utilization table's exact configuration (minimal vs default, single vs dual core, with or without L2/L3) could not be confirmed from the text.
- FireSim build-recipe frequencies for BOOM targets could not be retrieved (the recipe file now lists only Rocket and GCD examples).
- KV260/XCK26 resource counts were not re-verified in this session (the AMD page timed out).

## Key question 4: Quantified ablations and documented design lessons (SonicBOOM, BOOMv2/Celio, XiangShan MICRO'22 and later, Xuantie-910, Chips and Cheese, Hot Chips)

### Takeaway
The largest documented IPC gains come from the front end and the memory pipeline, not from widening the back end.
- SonicBOOM:
  - TAGE with a properly maintained superscalar global history was "the most significant contribution" toward roughly doubling SPEC IPC over BOOMv2.
  - The micro-BTB removed a 2-cycle redirect.
  - RAS repair gave 10× fewer return mispredicts.
  - SFB predication gave +25% on CoreMark.
  - A non-blocking dual-load D$ with fill buffers recovered about 10 cycles of effective L2 latency.
- C910: prefetching gave 3.8–5.4× on STREAM.
- XiangShan: larger LLC gave +5–9% SPEC; criticality-aware issue (PUBS) gave no measurable gain over oldest-first.
- Negative lessons:
  - BOOMv2's timing-driven pipelining cost up to 20% IPC, mostly from longer load-to-use latency.
  - C910's large ROB with small schedulers and register files is "poorly balanced".
  - P550's misaligned-access traps are expensive.

### Cited Findings

#### SonicBOOM (CARRV 2020)
- TAGE and global history:
  - A TAGE predictor with a speculatively updated and repaired superscalar global-history vector is "the most significant contribution to overall core performance".
  - BOOMv2's front-end changes and bug fixes frequently degraded predictor accuracy.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Predictor banking and aliasing:
  - BOOMv2 paired a banked ICache with an unbanked predictor, which "effectively halved" predictor capacity because some branches needed two entries.
  - Aliasing between branches in the same fetch packet degraded accuracy, so SonicBOOM's predictors were made superscalar and banked to match the ICache.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- The micro-BTB removes BOOMv2's minimum 2-cycle redirect penalty, "drastically improving fetch throughput on small loops" — [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- RAS and loop-predictor snapshot/repair: 10× fewer mispredicts than BOOMv2's unrepaired RAS, with 98% return accuracy — [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Short-forward-branch (SFB) predication:
  - Short forward branches over small blocks are recoded into "set-flag" and "conditional-execute" micro-ops. A renamed predicate register file supports multiple in-flight SFB sequences.
  - Up to 1.7× IPC on some code sequences.
  - CoreMark: 6.15 CoreMark/MHz with SFB vs 4.9 without (+25.5%).
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Multiple branch-resolution units, at the cost of one extra stage (branch-to-branch latency 12 cycles), "overall improved performance" thanks to scheduling flexibility — [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- D$ and LSU:
  - The Rocket-derived D$ was 1-wide, could not refill speculatively (cache pollution) and blocked refills during eviction: L2 latency was 14 cycles but the core observed 24.
  - The new non-blocking D$ with line-fill buffers and parallel state machines fixes this.
  - Even/odd banking of 1R1W SRAMs was "sufficient" for 2 loads per cycle, because stack restores and array walks alternate banks.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Verification:
  - The LSU and D$ are "the most bug-prone components".
  - TraceGen random load/store stress testing and a memtrace consistency checker were needed; some bugs appeared only after trillions of cycles.
  - Aggressive speculative page-table walks exposed a missing FENCE in Linux page-table initialization.
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
- Prefetching outlook:
  - An L1I miss costs at least a 10-cycle bubble.
  - A 4-wide core would need about 200 instructions in flight to hide a 50-cycle L3 hit, which exhausts the ROB, so instruction and data prefetchers are "vital".
  - Source: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)

#### BOOMv2 tech report (2017)
- Timing and IPC:
  - 37 FO4 after synthesis and 50 FO4 after place-and-route, vs 65 FO4 for BOOMv1 (−24%).
  - IPC dropped up to 20% on CoreMark.
  - Over half the IPC loss came from the added latency between loads and their dependents.
  - New parameters let designers buy back IPC with a longer clock period by shortening rename and register-read pipeline depth.
  - Source: [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- Port and window reduction:
  - Splitting issue-select from register-read and splitting the unified register file and issue window removed issue-select from the critical path.
  - Moving the 3-operand FMA to the FP register file cut integer register-file read ports.
  - Two integer issue ports were kept to sustain 2 ALU ops plus 1 memory op per cycle.
  - Source: [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- Methodology lessons:
  - "Chasing down and fixing all critical paths can be a fool's errand." Fixing post-synthesis-only critical paths may only cost IPC.
  - Tall, skinny memories time poorly and should be reshaped.
  - Splitting register files and issue windows took a week in Chisel, but physical design is the stumbling block.
  - Source: [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)
- The new 3-stage front end "suffers from additional bubbles even on correct branch predictions" — [BOOMv2 TR 2017](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2017/EECS-2017-157.pdf)

#### BOOM documentation and FPGA comparison
- BOOM pays a full pipeline flush plus rename reset on memory-ordering failures and has no memory-dependence predictor — [BOOM docs: LSU](https://docs.boom-core.org/en/latest/sections/load-store-unit.html)
- BOOM updates the predictor at commit without bypassing in-flight predictions, which can cause extra mispredicts for tight loops — [BOOM docs: backing predictor/FTQ](https://docs.boom-core.org/en/latest/sections/branch-prediction/backing-predictor.html)
- RSD vs BOOM on FPGA:
  - RSD achieved 1.9× BOOM's DMIPS/MHz.
  - The authors attribute this partly to BOOM always inserting a 1-cycle bubble on predicted-taken branches and partly to BOOM lacking speculative (load-hit) scheduling.
  - Source: [RSD FPT'19 preprint](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- Removing the store queue (OPA-style) cost up to 40% IPC (16% average) on SPECint 2006/2017 in the RSD authors' simulation — [RSD FPT'19 preprint](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)

#### Xuantie-910 (ISCA 2020) and Chips and Cheese
- Prefetch ablation on STREAM (HAPS80 at 60 MHz, about 200-cycle memory):
  - L1 prefetch alone: 3.8×.
  - Adding L2 and TLB prefetch: 4.9×.
  - Large prefetch distance: 5.4×.
  - Disabling TLB prefetch then cost about 2.4%.
  - Source: [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- Custom ISA extensions (register+register addressing, indexed load/store, unsigned-extend during address generation, bit-manipulation, MAC) plus compiler work (induction-variable optimization, global-variable anchoring, dead-store elimination) gave about +20% over native RISC-V + compiler — [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- A 16-bit ASID cut context-switch TLB flushes by about 10×. Hardware broadcast of TLB maintenance over the interconnect replaces IPI shootdowns — [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- Front-end mechanisms:
  - The L0 BTB (16 entries) captures programs whose IP-stage jump bubbles cannot be hidden by the instruction buffer.
  - The loop buffer lets the last instruction of an iteration issue with the first of the next, sustaining 3 per cycle, and avoids ICache accesses (power).
  - Mispredicts resolved at the branch unit cost at least 7 cycles more than IP-stage redirects.
  - Source: [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- C910 balance:
  - The OoO engine is "poorly balanced": schedulers and register files are too small for its ROB.
  - The L2 is "both slow and small" at 60 cycles, and the cache subsystem is "exceptionally weak".
  - Store forwarding is flexible but fails across 16 B/8 B boundaries, costing 20+ cycles.
  - Source: [Chips and Cheese: C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- P550 vs C910: P550's "well balanced" OoO engine sustains higher IPC and often keeps pace despite a 1.4 GHz vs 1.85 GHz clock; C910 "often fails to turn clock speed into performance" — [Chips and Cheese: P550 vs C910 benchmarks](https://chipsandcheese.com/p/a-risc-v-progress-check-benchmarking)
- P550 weaknesses:
  - Misaligned accesses trap to the OS at about 1,000 cycles each, vs 15 cycles worst case on Cortex-A75.
  - High core-to-core latency.
  - Forwarding only on exact aligned matches.
  - Source: [Chips and Cheese: P550](https://chipsandcheese.com/p/inside-sifives-p550-microarchitecture)

#### XiangShan (MICRO'22, HC2024, RVSE'25)
- PUBS (prioritizing unconfident branch slices) was implemented in about 300 lines of Chisel in under 200 minutes.
  - Result: no visible IPC change vs oldest-first (AGE) issue on sjeng checkpoints. The original paper reported +6.5% on sjeng and +7.8% average for high-MPKI programs.
  - Reason: XiangShan's distributed 2-issue queues rarely have more than 2 ready instructions (12.8% of cycles), so at most about 1.3% of instructions could issue earlier.
  - Source: [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- LLC size on FPGA: 4 MB vs 2 MB gave +8.9% SPECint and +5.4% SPECfp for NH — [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- Macro-op fusion is used to reduce execution latency and enlarge the effective ROB and issue-queue capacity. The 128-direct-mapped plus 8-fully-associative DTLB gives capacity "without negatively impacting timing" — [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- Evaluation methodology:
  - SimPoint checkpoints plus RTL simulation deviate 5–10% from FPGA and silicon.
  - FPGA performance runs are slow (more than 150 hours) and distorted by the memory clock ratio.
  - gem5 models aligned to the RTL can be 30% off.
  - Source: [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- Generation-level gains:
  - KMHv2 is "1.5x IPC of XS Gen2" — [Tang et al. poster, RVSE 2025](https://riscv-europe.org/summit/2025/media/proceedings/2025-05-13-RISC-V-Summit-Europe-P2.1.06-TANG-poster.pdf)
  - KMHv3 adds about 30% on SPEC06 and 33% on SPEC17 over KMHv2.
  - Partner companies contributed 462 bugs (37%) during KMH development.
  - Source: [Bao, RISC-V Summit Europe 2025](https://riscv-europe.org/summit/2025/media/proceedings/2025-05-14-RISC-V-Summit-Europe-09h30-BAO-slides.pdf)
- KMH design emphases: decoupled front end "to reduce fetch bubbles" and be "instruction prefetching friendly"; large ROB/LQ/SQ; closely coupled load/store pipe with L1/L2; heavily banked design; multi-level composite prefetching — [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- LightSSS fork-based simulation snapshots cost under 0.1% overhead at 1-minute intervals. Development went from conception to a Debian boot in simulation in 3 months — [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)

#### Veyron V1 (Hot Chips 2023)
- Veyron V1 uses unconventional choices to reach 3.6 GHz in 5 nm: a 512 KB instruction cache serving as L1+L2, a single-level 12K-entry BTB, single-level 3K-entry TLBs, a VIVT L1D with ASID tags, and four flexible execution ports — [Chips and Cheese: Veyron V1 at HC2023](https://chipsandcheese.com/p/hot-chips-2023-ventanas-unconventional-veyron-v1)

### Inferences
- SonicBOOM's paper gives no per-feature SPEC ablation. Only SFB (+25% CoreMark), RAS (10× fewer return mispredicts) and the L2-latency fix (24 → about 14 cycles) are quantified. Its 2× SPEC IPC over BOOMv2 is the combined effect of TAGE + history repair + micro-BTB + RVC fetch + dual-load LSU + non-blocking D$. Treat the attribution to TAGE as qualitative.
- The PUBS null result is architecture-dependent. With 1–2 issue ports and small queues, select policy matters more. On a 2-wide FPGA core, oldest-first via an age matrix is still the safe default, but criticality hints for loads and branches could be revisited later.
- The BOOMv2 lesson is directly relevant to FPGA. Each pipeline stage added for Fmax on the load-to-use or branch-redirect loops costs measurable IPC, so cycle time should be bought on non-critical-loop stages (rename, dispatch, commit) first.

### Gaps
- No quantified per-feature ablations (e.g., store sets vs wait table, move elimination, fusion, ROB compression) were found in XiangShan's public papers or slides. The biweekly reports that might contain them were not accessible.
- The Celio thesis (EECS-2018-151) could not be retrieved (over 10 MB); only its CoreMark numbers via T-Head's slide are cited.
- No public ablations were found for P550/P650, AX65, Veyron or Ascalon beyond vendor generation-over-generation claims.

## Key question 5: Pros and cons of each core, and a ranked list of ideas transferable to a ~35–45K-LUT/core 2-wide OoO RV64 core on Zynq UltraScale+ (KV260)

### Takeaway
None of these cores is a porting candidate for a KV260-class budget. BOOM and XiangShan are 3–15× too large on FPGA, and C910's FPGA build configuration is unknown. Their lessons transfer well, though, and the evidence points to a priority order:
1. A zero/one-bubble decoupled front end: tiny fully-associative micro-BTB, FTQ, BRAM TAGE-lite or bi-mode with repaired global history, and a repaired RAS.
2. A short load-to-use loop with load-hit speculation.
3. A store queue with forwarding plus a cheap memory-dependence predictor, instead of BOOM's flush-on-violation.
4. A non-blocking L1D with fill buffers and simple stride/next-line prefetch.
5. FPGA-native multiport structures: LVT/banked RAMs, grouped ROB entries, small age-matrix issue queues, and narrow partial-address CAMs.
6. Balance: size issue queues and physical registers relative to the ROB.

SFB predication is the cheapest large CoreMark lever if beating NaxRiscv on CoreMark matters.

### Cited Findings

#### BOOM (v3, plus the v4 line)
- Pros:
  - Fully parameterized from 1 to 5 wide; RVC-capable superscalar fetch; TAGE-L; repaired RAS; SFB.
  - Dual-load LSU; RoCC accelerator interface.
  - Proven Linux (Buildroot, Fedora).
  - Chipyard/FireSim ecosystem with Dromajo/Fromajo co-simulation.
  - Sources: [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf); v4 adds a matrix scheduler, B extension and decoupled-vector groundwork — [riscv-boom v4 commit log](https://api.github.com/repos/riscv-boom/riscv-boom/commits?path=src/main/scala/v4&per_page=100)
- Cons:
  - No memory-dependence predictor; memory-ordering failures cause a full flush — [BOOM docs: LSU](https://docs.boom-core.org/en/latest/sections/load-store-unit.html)
  - No speculative load-hit issue — [BOOM docs: issue](https://docs.boom-core.org/en/latest/sections/issue-units.html)
  - On FPGA: low Fmax and large FF/LUT usage (see Key question 3) — [RSD FPT'19 preprint](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
  - The 12-cycle branch-to-branch latency in v3 — [SonicBOOM CARRV'20](https://carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf)
  - The matrix scheduler was temporarily reverted (Dec 2025) — [riscv-boom v4 commit log](https://api.github.com/repos/riscv-boom/riscv-boom/commits?path=src/main/scala/v4&per_page=100)

#### XiangShan (Nanhu and Kunminghu)
- Pros:
  - The most complete open industrial-grade OoO design: decoupled BPU/FTQ, TAGE-SC/ITTAGE, fusion, move elimination, compressed ROB, store sets plus wait table, and split RAR/RAW/replay load queues.
  - Large documented verification infrastructure (DiffTest, LightSSS, NEXST FPGA environment).
  - Silicon-proven (YQH, NH V2) — [XiangShan MICRO'22](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf), [XiangShan Hot Chips 2024](https://www.hc2024.hotchips.org/assets/program/conference/day2/29_HC2024.ChineseAcademy.XiangShan.Kaifan.final.pdf)
- Cons:
  - Very large: about 564K LUTs for Nanhu on VU19P at 50 MHz — [Chen et al., Nanhu-vdot (arXiv 2409.00661)](https://arxiv.org/pdf/2409.00661), [S2C BOSC case study](https://www.s2cinc.com/customer-case/bosc)
  - The project itself says KMH's power and area still lag Arm (slide note: "Power & Area still behind ARM") — [XiangShan MICRO'25 tutorial](https://tutorial.xiangshan.cc/micro25/slides/Introduction.pdf)
  - The V3 branch is unstable — [XiangShan README (kunminghu-v3)](https://cdn.jsdelivr.net/gh/openxiangshan/xiangshan@kunminghu-v3/README.md)

#### OpenC910 / C9xx
- Pros:
  - Commercially proven Linux SMP core: MOESI L2 with snoop filter, 16-bit ASID, hardware TLB-maintenance broadcast.
  - Compact (0.6 mm² without vector in 12 nm).
  - L0 BTB plus loop buffer.
  - Strong prefetch engine.
  - A 200 MHz VU9P FPGA edition existed.
  - Source: [Xuantie-910 ISCA'20](https://ftp.libre-soc.org/466100a052.pdf)
- Cons:
  - Unbalanced window: 16-entry ALU scheduler and about 96 int physical registers vs 192 instructions.
  - Slow 60-cycle L2.
  - Narrow 1-load/1-store LSU.
  - RVV 0.7.1 and custom extensions in the open version.
  - Source: [Chips and Cheese: C910](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
  - The open repository has been static since 2024-06 — [OpenC910 repo metadata](https://api.github.com/repos/XUANTIE-RV/openc910)

#### Commercial reference points
- P550: balanced engine and zero-bubble BTB, but a 32-entry single-level BTB, trapping misaligned accesses, thin LSQ and high core-to-core latency — [Chips and Cheese: P550](https://chipsandcheese.com/p/inside-sifives-p550-microarchitecture)
- P650/P670: show that going from 3 to 4 issue was worth about 40% per clock (vendor) — [CNX: P650](https://cnx-software.com/?p=93869)
- AX65: 4-wide decode feeding 8-wide execution at a vendor 8.25/GHz — [Andes AX65 GA release](https://www.design-reuse.com/news/55479/andes-risc-v-out-of-order-superscalar-multicore-processor.html)
- C930, C950, Veyron and Ascalon: 6–8-wide data-center designs (vendor SPEC 15–22+/GHz) that rely on very large BTBs, TLBs and caches — [CNX: C950](https://www.cnx-software.com/2026/03/25/alibaba-xuantie-c950-a-powerful-rva23-complaint-64-bit-risc-v-core-for-edge-ai-computing/), [Chips and Cheese: Veyron V1 at HC2023](https://chipsandcheese.com/p/hot-chips-2023-ventanas-unconventional-veyron-v1), [HWCooling: Ascalon (Apr 2023)](https://www.hwcooling.net/en/?p=147287)

### Inferences

Ranked transferable ideas for a 2-wide-decode RV64GC OoO core at about 35–45K LUTs per core on Zynq UltraScale+. The ranking weighs documented IPC impact, FPGA cost and Fmax risk.

1. **Decoupled front end with a tiny zero-bubble predictor and an FTQ.**
   - Mechanism: a fully-associative micro-BTB of about 16–32 entries (C910 uses 16, P550 a 32-entry zero-bubble BTB, SonicBOOM a micro-BTB) predicts taken branches in the fetch cycle. Behind it sits a larger set-associative BTB in BRAM and a fetch-target queue that decouples prediction from fetch and holds update metadata.
   - Why first: RSD attributes much of BOOM's 1.9× DMIPS/MHz deficit to a forced bubble on every taken branch, and SonicBOOM calls the micro-BTB a "drastic" small-loop improvement.
   - Cost: small (a few hundred FFs plus a narrow CAM). Keep the CAM small because the ~40-entry fully-associative limit appeared even in ASIC.
2. **BRAM-resident TAGE-lite (or bi-mode) with speculative global history and repair, banked to match the fetch packet, plus a snapshot-repaired RAS.**
   - Evidence: SonicBOOM's single largest contributor (with BOOMv2's capacity-halving bank mismatch as the cautionary tale), and RAS repair giving 10× fewer return mispredicts.
   - Sizing references: XiangShan MinimalConfig (TAGE 3 tables of 512/512/1024, SC 2×128, ITTAGE 3 tables, RAS 8 + 16 speculative) and C910's 17.3 KB bi-mode.
   - FPGA note: BRAM read is synchronous, so plan a 2–3-stage overriding predictor (micro-BTB at F1, TAGE at F2/F3), as BOOMv2 and KMH do.
3. **A short load-to-use loop (≤3 cycles) with speculative wakeup on L1 hit and a cheap replay path.**
   - Evidence: BOOMv2 lost up to 20% IPC, more than half of it from load-to-use latency. C910 and KMH both use 3-cycle load-to-use.
   - On FPGA, RSD-style replay through a FIFO is much cheaper than shadowed dependency matrices.
4. **A real store queue with forwarding, store address/data split micro-ops, and cheap memory-dependence prediction (wait table or store-set-lite) instead of flush-on-violation.**
   - Evidence: an STQ-less design lost up to 40% IPC (16% average); BOOM's ordering failure is a full flush; XiangShan ships store sets plus a wait table; C910 tags violation-prone loads and stores.
   - Cost reducer: C910-style partial-address disambiguation (bits 11:4) keeps the CAM narrow. XiangShan's RAR/RAW split shows how to keep the expensive searches off the load issue path.
5. **Non-blocking L1D with line-fill buffers (refill not blocked by eviction, no speculative pollution) plus next-line/stride prefetch, a shared L2 TLB and a 16-bit ASID.**
   - Evidence: SonicBOOM cut observed L2 latency from 24 cycles toward 14; C910 prefetch gave 3.8–5.4× on STREAM; the 16-bit ASID gave 10× fewer TLB flushes.
   - Cost: BRAM plus small state machines.
6. **FPGA-native multiport storage.**
   - Mechanism: split int and FP register files; LVT or banked multiport RAM for the PRF, map table, ready table and ROB state; grouped (compressed) ROB entries, one per decode group, as in C910 and KMH; banked free lists.
   - Evidence: RSD saved 45% LUTs and 36% FFs and gained 6% Fmax this way.
   - For 2-wide: an int PRF of 4R + 2–3W can use LVT over LUTRAM.
7. **Small distributed issue queues (8–16 entries) with an age matrix and oldest-first select; avoid collapsing queues.**
   - Evidence: C910 age vectors, XiangShan AgeDetector and BOOM v4's matrix scheduler. PUBS showed fancy select adds little.
   - Balance warning: do not pair a large ROB with tiny queues and PRFs (C910's "poorly balanced" engine). P550's 40 scheduler entries across 3 ALU ports is a balance reference.
8. **Rename with per-branch map snapshots (maxBr about 8) and allocation-list free-list recovery, for single-cycle mispredict recovery.**
   - Evidence: the BOOM scheme. Kunminghu's checkpoint + rollback with a rename buffer is the alternative when snapshot FF cost bites.
   - Branch tags/masks are needed for selective kill.
9. **Short-forward-branch predication.**
   - Evidence: +25% CoreMark/MHz in SonicBOOM, up to 1.7× on some sequences.
   - Value: high if NaxRiscv is compared on CoreMark/Dhrystone-like code. Moderate cost: predicate rename plus conditional-move micro-ops.
10. **Macro-op fusion and move elimination.**
    - Evidence: used by XiangShan NH/KMH and claimed by C910's rename. They enlarge effective width and buffer capacity, but no public quantification was found.
    - Fusing common RISC-V pairs is attractive for a 2-wide decoder. Reference-counted move elimination complicates the free list, so do it second.
11. **Loop buffer (C910: 16 entries).**
    - Sustains full width across loop back-edges and saves ICache energy.
    - Partly redundant with a good micro-BTB plus fetch buffer; low priority on FPGA.
12. **Hardware misaligned-access handling.**
    - Evidence: P550's OS trap costs about 1,000 cycles. C910 handles misaligned accesses in hardware at only the cost of an extra access.
    - Important for Linux userland robustness rather than SPEC.
13. **Multicore: shared L2 with a directory or snoop filter (C910 MOESI + snoop filter) and attention to core-to-core latency (P550 over 300 ns is the counter-example).**
    - XiangShan's split SMP DiffTest and Chipyard TileLink show the verification side.
    - For future SMT/CMT hooks, none of these cores is multithreaded, so no data transfers.
14. **Verification infrastructure as a first-class feature.**
    - Evidence: DiffTest/LightSSS (XiangShan), Dromajo/Fromajo plus TraceGen/memtrace (SonicBOOM; "LSU and D$ are the most bug-prone").
    - Plan this from day one; it is cheap relative to debugging time.

Not transferable at this budget:
- 6–8-wide decode, 160–256-entry ROBs and 128 KB VIPT L1s (XiangShan NH/KMH).
- Full-size 16K TAGE-SC with 2K ITTAGE.
- Multi-level composite SMS/BOP/temporal prefetchers.
- Veyron's 12K BTB and 3K TLBs.
- Wide vector units (C930/C950, Ascalon, Veyron V2).

### Gaps
- No direct measurements exist of IPC per LUT for any of these techniques on FPGA. The ranking combines ASIC/simulation evidence with FPGA cost reasoning.
- The relative value of SFB, fusion and move elimination on SPEC (as opposed to CoreMark) for a 2-wide core is unquantified in the sources found.
- No SMT/CMT implementation data exists among the listed cores. The SMT hook design must be sourced elsewhere.
