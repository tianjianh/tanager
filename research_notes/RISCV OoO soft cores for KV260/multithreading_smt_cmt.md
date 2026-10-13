# Multithreading (SMT / "CMT") as a later extension of a 2-wide out-of-order RV64 soft core: literature, numbers, RISC-V requirements, FPGA evidence, security, and day-one hooks

Context for the reader: the target is an original 2-wide-decode OoO RV64 dual-core, Linux-capable, on the AMD/Xilinx Kria KV260 (Zynq UltraScale+ XCK26), which must out-IPC NaxRiscv and keep a low-cost path to SMT or CMT later. Notes compiled 2026-10-12. Every number below carries its date and configuration where the source gives them. Some lookups could not be completed because the shared web-search budget for this research turn was exhausted partway through; affected items are listed under the relevant "Gaps".

---

## 1. Foundational SMT results and industrial SMT designs: throughput gains, area overhead, and what is replicated vs partitioned vs shared (emphasis on narrow cores)

### Takeaway
Across 25+ years of academic and industrial data, two-thread SMT typically buys roughly 15-60% more throughput for roughly 5-25% more core area, and the industry has converged on a recipe: replicate only architectural state plus a few small per-thread predictors (RAT, PC, return stack, histories), statically partition the in-order queues and the ROB/LSQ, share the issue queue with per-thread limits, and share execution units and caches dynamically (tagging caches/TLBs/predictors by thread where needed). Narrow cores (2-wide in-order or small OoO) report gains at the upper end of that range (30-60%) because they stall more, which is directly relevant to a 2-wide OoO design.

### Cited Findings

#### Academic foundations
- (ISCA 1995; simulated wide-issue superscalar) Tullsen, Eggers and Levy concluded that simultaneous multithreading has the potential to reach about 4x the throughput of a superscalar and about 2x that of fine-grain multithreading on the same wide-issue resources. — [UW SMT project, ISCA'95 abstract](https://dada.cs.washington.edu/smt/papers/isca95abstract.html)
- (ISCA 1996; simulated OoO machine with 8-instruction fetch/decode, 6 integer units of which 4 do loads/stores, 3 FP units, 32-entry integer and FP instruction queues, 256-entry 4-way BTB, 2K x 2-bit PHT, 12-entry return stack per context, up to 8 threads) a minimal SMT extension gave 1.8x the throughput of the unmodified superscalar (peak 84% higher), and small tuning raised that to 2.5x (up to 5.4 IPC). With one thread the SMT machine was less than 2% slower than the baseline superscalar; the loss came from the two extra pipeline stages added for the larger register file. — [Tullsen et al., ISCA'96 (Utah mirror)](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf)
- (ISCA 1996) The paper's list of what SMT adds to a conventional OoO superscalar is short: multiple PCs plus a fetch-selection mechanism; a separate return stack per thread; per-thread instruction retirement, instruction-queue flush and trap mechanisms; a thread ID in each BTB entry, to avoid predicting "phantom" branches; and a larger register file. Renaming maps every thread's logical registers onto one fully shared physical register file. — [Tullsen et al., ISCA'96](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf)
- (ISCA 1996) Register-file sizing: supporting 8 threads requires at least 8 x 32 = 256 physical integer registers, plus 100 more for renaming. The single-thread baseline modeled 132 (32 + 100). Register read and write each took two cycles, which added two stages between rename and commit and lengthened physical-register lifetime. — [Tullsen et al., ISCA'96](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf)
- (ISCA 1996) Fetch policy: the ICOUNT heuristic gives fetch priority to the thread with the fewest instructions in the front end and queues, which avoids queue clog. ICOUNT.2.8 means fetching up to 8 instructions per cycle from up to 2 threads. It reached 5.3 IPC, 23% above the best round-robin policy. Instruction counting gave about as much benefit over round-robin at 2 and 4 threads as at 8, and intelligent thread selection helped more than partitioning the fetch unit. — [Tullsen et al., ISCA'96](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf)
- (ISCA 1996, Table 3; base architecture at 1, 4 and 8 threads) Shared-structure pressure grew with thread count. I-cache miss rate went from 2.5% to 7.8% to 14.1%, D-cache miss rate from 3.1% to 6.5% to 11.3%, and branch misprediction rate from 5.0% to 7.4% to 9.1%. Meanwhile wrong-path instructions fetched fell from 24% to 7%, because each thread's speculation depth shrinks. (The table was realigned from a PDF text extraction, so check against the original.) — [Tullsen et al., ISCA'96](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf)
- (PACT 2003; simulated SMT, execution portion of the pipeline) Raasch and Reinhardt found the following:
  - For storage resources such as the instruction queue and reorder buffer, giving each thread an equal static share performs well, partly because it prevents starvation. That enforced fairness largely removes the need for sophisticated fetch policies.
  - Dynamically sharing storage did not give a significant benefit.
  - Statically dividing issue bandwidth hurts throughput; dynamically multiplexing bursty threads onto shared function units is a key source of SMT's gain.
  - In clustered machines, putting threads on separate clusters removes inter-cluster communication, but the resulting partition of issue bandwidth can cancel that benefit.
  
  The authors note that academic studies usually assume dynamic sharing, while industrial designs usually partition statically. — [Raasch & Reinhardt, PACT 2003 (PDF)](https://static.aminer.org/pdf/PDF/000/009/820/the_impact_of_resource_partitioning_on_smt_processors.pdf)

#### Intel Hyper-Threading: NetBurst (2002), Nehalem (2008), Atom/Bonnell (2008)
- (Koufaty & Marr, IEEE Micro, March-April 2003; first shipped on Xeon in early 2002 and on Pentium 4 at 3.06 GHz in November 2002) Hyper-Threading added less than 5% to chip size and gave about a 25% boost. The first implementations deliberately emphasized cost containment. — [Koufaty & Marr, IEEE Micro 2003 (KFUPM copy)](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf)
- (same source) Replicated per logical processor:
  - the register alias tables (a separate table per logical processor);
  - next-instruction-pointer logic (two sets: one at the trace cache, one at the decoder);
  - the return stack predictor;
  - instruction streaming buffers and trace-cache fill buffers;
  - the ITLB, because it was small and replicating it was simpler than sharing;
  - APIC registers, so each thread receives interrupts independently.
  
  Shared: nearly everything else, including caches, execution units, branch predictors, control logic and buses. — [Koufaty & Marr 2003](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf)
- (same source) Intel used three sharing policies:
  - **Partition:** each thread gets half the entries. Used for the major queues in the in-order parts of the pipeline, to guarantee fairness and forward progress.
  - **Threshold:** a per-thread cap on entries. Used for the small, bursty schedulers, which allocate round-robin until a thread reaches its cap. These schedulers were double-pumped, so a 3 GHz part had 6 GHz schedulers.
  - **Full sharing:** used for large structures such as caches.
  
  — [Koufaty & Marr 2003](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf)
- (same source; workload = two copies of the same application on a P4 with HT) A fully shared cache gave on average a 40% better hit rate and 12% better performance than a partitioned cache, and no workload lost performance. — [Koufaty & Marr 2003](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf)
- (same source; 3.06 GHz Pentium 4, D850EMV2 board, 256 MB PC1066 RDRAM, Windows XP) Measured gains were 15-26% on multithreaded applications and 15-27% on multitasking mixes. — [Koufaty & Marr 2003](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf)
- (same source) The area cost was small but the complexity cost was substantial:
  - algorithms that depend on micro-op age had to be redesigned, because age and priority across two threads are ill-defined;
  - livelock between logical processors had to be avoided by design, with fallback algorithms added "just in case";
  - validation had to cover every combination of operating mode and event across two threads.
  
  — [Koufaty & Marr 2003](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf)
- (Nehalem, 2008) The 128-entry ROB is split statically and equally between the two threads, the 36-entry reservation station is competitively shared, and the load and store queues are statically partitioned. This comes from secondary course slides. — [Univ. Cantabria course slides](https://ocw.unican.es/pluginfile.php/1827/course/section/1428/11_Final.pdf). Nehalem also grew load buffers from 32 to 48 and store buffers from 20 to 32 relative to its predecessor. — [bit-tech Nehalem EP review](https://bit-tech.net/reviews/tech/cpus/intel-xeon-w5580-nehalem-ep-review/2/)
- (Atom/Bonnell, 2008; 2-wide in-order) The 32-entry scheduling queue becomes two 16-entry per-thread queues when SMT is on. AnandTech estimated that SMT raised Atom's power by under 20% and its performance by 30-50% (unsourced estimate). — [AnandTech, "The Case for SMT"](https://at-web1.www.anandtech.com/show/2493/10). Bonnell has two integer ALUs and no instruction reordering, speculative execution or register renaming. — [Wikipedia, Bonnell](https://en.wikipedia.org/wiki/Bonnell_(microarchitecture))
- Other Atom figures are second-hand. Tom's Hardware measured "up to 37%" from Hyper-Threading on Atom. — [Tom's Hardware](https://www.tomshardware.com/reviews/Intel-Atom-Efficient,1981.html). An Intel slide relayed on a forum showed +39% on SPECint2K rate and +53% on Cinebench. — [AnandTech forum](https://forums.anandtech.com/threads/intel-atoms-hyperthreading.163947/latest)

#### IBM POWER5 (2003-2004)
- (DAC 2004; 276M transistors, 130 nm SOI, 8-level Cu, >1.5 GHz, 2 cores x 2 threads) A simplistic SMT implementation promised about 20% improvement. Resizing critical microarchitectural resources "almost doubles in many cases" that benefit, at a 24% area cost per core. The GPR and FPR files were redesigned to provide more renames with minimal growth, and the L1D became 4-way associative rather than larger. — [POWER5 DAC 2004 paper](https://www.cs.york.ac.uk/rts/docs/SIGDA-Compendium-1994-2004/papers/2004/dac04/pdffiles/p670.pdf)
- (Hot Chips, August 2003, pre-silicon claim) IBM projected about 40% more performance than POWER4 for about 24% more per-core die area, with physical registers growing from 80 to 120. — [eWeek](https://www.eweek.com/networking/ibm-power5-chip-to-tap-threading/). The slides gave "20-25% execution unit utilization" as typical, motivating SMT. — [Hot Chips 15 slides](https://old.hotchips.org/wp-content/uploads/hc_archives/hc15/3_Tue/11.ibm.pdf)

#### AMD Zen (2016-2017 onward)
- (Hot Chips 28, August 2016; Zen 1) Configuration:
  - 2 threads per core, with an advertised 40% IPC uplift over Excavator;
  - 192-entry retire queue (vs 128), 72 out-of-order loads (vs 44), 44-entry store queue (vs 32);
  - 168-entry integer PRF, 6 x 14-entry integer scheduling queues, 4 ALUs + 2 AGUs;
  - 32 KB 8-way write-back L1D, 64 KB 4-way L1I, 512 KB private L2.
  
  The "SMT Overview" slide colour-codes each structure as one of: competitively shared; competitively shared and SMT-tagged; competitively shared with algorithmic priority; statically partitioned; or vertically threaded. Front-end queues are round-robin with priority overrides. — [Hot Chips 28 Zen slides (Mike Clark)](https://old.hotchips.org/wp-content/uploads/hc_archives/hc28/HC28.23-Tuesday-Epub/HC28.23.90-High-Perform-Epub/HC28.23.930-X86-core-MikeClark-AMD-final_v2-28.pdf)
- (Chips and Cheese interview with Mike Clark, July 2024) Zen statically partitions the retire queue/ROB, store queue and micro-op queue. Clark said this is "not really a big performance thing"; AMD does it because a dynamically shared reorder buffer is very hard to build. Caches and TLBs are competitively shared and must be tagged by thread, and execution resources are competitively shared. — [Chips and Cheese interview](https://chipsandcheese.com/2024/07/15/a-video-interview-with-mike-clark-chief-architect-of-zen-at-amd/)
- (AMD optimization guide, as quoted in an LLVM review, 2018) The Zen retire queue holds 192 micro-ops, or 96 per thread in SMT mode. — [LLVM review D47676](https://reviews.llvm.org/D47676?id=151408)

#### Arm Neoverse E1 / Cortex-A65AE (announced 2019): a small OoO SMT core
- (Arm blog, February 2019) The E1 is a two-thread SMT core whose threads appear as two CPUs and may run at different exception levels or under different OSes. Its OoO window is deliberately small: a 40-instruction ROB and 8-entry reservation stations. Arm's rationale:
  - on Cortex-A53/A55-class cores, cache misses take up to 80% of cycles;
  - adding OoO cuts stall cycles to about 50%;
  - OoO plus SMT cuts them to about 30% on typical throughput workloads.
  
  Against Cortex-A53, Arm claimed 2.7x throughput, 2.4x throughput per watt and 2.1x compute. The 16-core reference design drew under 4 W at 2.3 GHz. — [Arm Neoverse E1 blog](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/arm-neoverse-e1-platform-empowering-the-infrastructure-to-meet-next-generation-throughput-demands); [Arm product page](https://arm.com/products/silicon-ip-cpu/neoverse/neoverse-e1)
- AnandTech described the E1 as Arm's first SMT core, sharing its design with the Cortex-A65AE. — [AnandTech E1 page (mirror)](https://at-web1.www.anandtech.com/show/13959/arm-announces-neoverse-n1-platform/5)

#### MIPS (34K 2006, I6400/I6500 2014-2016, P8700 2024)
- (MIPS internal benchmarks, 2006; 34Kc) Two threads were 60% faster than a single-threaded processor for a 14% die-size increase. — [Design & Reuse (MIPS 34K announcement)](https://us.design-reuse.com/news/12502/new-multi-threading-solution-mips-significant-gains-system-performance-embedded-market.html)
- (BDTI) A different baseline: a 360 MHz 34K was about 50% faster than a 400 MHz single-threaded 24KE running the same benchmarks back-to-back, at 4.2 mm², about 30% larger than the 24KE. Both areas are for TSMC CL013G, excluding L1 caches. — [BDTI](https://www.bdti.com/node/387)
- (I6400 launch, 2014; dual-issue in-order; preliminary) A second thread gave +40-60% on SPECint and CoreMark for under 10% cluster area. This quote reached me through search aggregation, and I could not pin down the exact article (see Gaps). — [Design & Reuse, "MIPS Moves Multicore Battle to Clustering"](https://us.design-reuse.com/news/35317/mips-multicore-clustering.html)
- (I6500, October 2016) Up to 4 hardware threads per core, up to 6 cores per cluster; 1,536 threads is the theoretical system maximum. — [EEJournal](https://www.eejournal.com/article/20161012-mips/); [CNX Software](https://www.cnx-software.com/2016/10/13/imagination-technologies-announces-mips-warrior-i-class-i6500-heterogeneous-cpu-with-up-to-384-cores/)
- (P8700 datasheet rev 1.22, November 2024; RV64GC + Zba/Zbb) An OoO multithreaded RISC-V core: "typical 60% performance boost" from running two harts simultaneously rather than sequentially (configuration not stated). It is 8-wide fetch, 4-wide decode/rename/graduation and 7-wide issue. Details are in Section 3. — [MIPS P8700 datasheet](https://mips.com/wp-content/uploads/2024/11/P8700_Data_Sheet.pdf)

#### Other data points
- (ICCD 2006; Godson-2 SMT, an OoO MIPS-compatible core) SMT gave a 31.3% average speedup for 18.8% area overhead. This figure comes from a search snippet; the full text could not be fetched, so the exact configuration is unverified. — [ICCD 2006 paper 38](https://websrv.cecs.uci.edu/~papers/iccd2006/papers/paper_38.pdf)
- (2000-2005) Burns and Gaudiot published transistor- and interconnect-level layout analyses of SMT overhead: HPCA 2000 "Quantifying the SMT Layout Overhead: Does SMT Pull Its Weight?", IEEE TPDS 13(2) 2002 "SMT Layout Overhead and Scalability", and IEEE TC 54(2) 2005 "Area and System Clock Effects on SMT/CMP Throughput". Their numbers were not retrieved. — [dblp listing](https://dblp1.uni-trier.de/pers/hd/b/Burns:James)

#### Summary table of throughput and area numbers (all vendor or paper figures; differing baselines)
| Design (date) | Core type | Threads | Throughput gain | Area cost | Source |
|---|---|---|---|---|---|
| Tullsen ISCA'96 (sim.) | 8-wide OoO | up to 8 | 1.8x minimal, 2.5x tuned (5.4 IPC) | Larger PRF, +2 pipe stages; area not given | [paper](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf) |
| Pentium 4 HT (2002) | Deep OoO | 2 | 15-27% (apps); ~25% headline | <5% of chip | [IEEE Micro](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf) |
| POWER5 (2004) | Wide OoO | 2 | ~20% simplistic, ~2x that with resizing; ~40% vs POWER4 (claim) | 24% per core | [DAC](https://www.cs.york.ac.uk/rts/docs/SIGDA-Compendium-1994-2004/papers/2004/dac04/pdffiles/p670.pdf), [eWeek](https://www.eweek.com/networking/ibm-power5-chip-to-tap-threading/) |
| MIPS 34Kc (2006) | Single-issue in-order | 2 | 60% | 14% die | [D&R](https://us.design-reuse.com/news/12502/new-multi-threading-solution-mips-significant-gains-system-performance-embedded-market.html) |
| Godson-2 SMT (2006) | OoO MIPS | 2 (assumed) | 31.3% avg | 18.8% | [ICCD](https://websrv.cecs.uci.edu/~papers/iccd2006/papers/paper_38.pdf) |
| Atom Bonnell (2008) | 2-wide in-order | 2 | 30-50% (est.), up to 37% | Not found | [AnandTech](https://at-web1.www.anandtech.com/show/2493/10), [Tom's](https://www.tomshardware.com/reviews/Intel-Atom-Efficient,1981.html) |
| MIPS I6400 (2014) | Dual-issue in-order | 2 | 40-60% (prelim.) | <10% of cluster | [D&R](https://us.design-reuse.com/news/35317/mips-multicore-clustering.html) |
| Neoverse E1 (2019) | Small OoO (40 ROB) | 2 | Stall cycles ~50% to ~30% | Not disclosed | [Arm](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/arm-neoverse-e1-platform-empowering-the-infrastructure-to-meet-next-generation-throughput-demands) |
| MIPS P8700 (2024) | 4-wide-decode OoO RV64 | 2+ | "Typical 60%" | Not disclosed | [datasheet](https://mips.com/wp-content/uploads/2024/11/P8700_Data_Sheet.pdf) |

### Inferences
- **Expected gain for this core.** For a 2-wide OoO RV64 core, the most comparable data points are Neoverse E1 (small OoO window plus SMT2) and the narrow in-order SMT designs (Atom, MIPS I6400, 34K).
  - E1's stall reduction from about 50% to about 30% implies roughly 1.4x more useful cycles in throughput mode (70% busy vs 50%). This is my arithmetic on Arm's stall percentages, not an Arm-stated SMT gain.
  - A planning range of +20-40% throughput for SMT2 on mixed Linux workloads seems reasonable, with the higher end on memory-bound or branchy server-style code. Expect about 0% or a small negative effect on single-thread IPC.
  - On an FPGA, memory latency measured in core cycles is much smaller than on GHz-class ASICs because the core clock is low. SMT's latency-hiding gain may therefore be smaller than the ASIC numbers suggest, while the utilization gain from filling dependency and mispredict bubbles still applies. This needs simulation to confirm.
- **Partitioning recipe.** Convergent industrial practice (P4, Nehalem, Zen) and Raasch & Reinhardt's results both point the same way:
  - statically partition the in-order queues and the ROB/LQ/SQ;
  - share the issue queue with per-thread caps (HT "threshold");
  - share execution units cycle by cycle;
  - share caches but tag TLBs and caches by thread where semantics require it.
  
  This is also the simplest scheme to verify, and Clark's comment confirms that static ROB partitioning costs little performance.
- **Area.** The 5-24% ASIC area range is dominated by register-file growth and resizing (POWER5) rather than by replicated architectural state (P4 <5%). On an FPGA, the analogous cost driver will be multi-ported LUTRAM/FF register files and rename tables that must grow in depth. See the cost table in Section 6.
- **Hidden cost.** The non-area cost (age logic, livelock avoidance, validation) is what Intel flagged as the real price. That argues for building per-thread qualifiers into the v1 RTL now, so the SMT step is not a redesign of every age, flush and ordering mechanism.

### Gaps
- Burns & Gaudiot's quantitative layout overheads (per issue width and thread count) were not retrieved; they are the best academic source for how SMT area scales with narrow widths.
- IBM POWER7/8/9/10 SMT4/SMT8 partitioning (thread sets, dynamic mode switching) and Intel's ITJ 2002 description of single-task mode, where partitioned resources are recombined when a thread halts, were not verified. The web-search budget was exhausted before they could be looked up.
- No primary source found for Atom/Bonnell Hyper-Threading area or an Intel-verified gain; the Atom figures above are secondary.
- Neoverse E1's decode width and a standalone SMT throughput figure are not disclosed in the sources found.
- No published SMT measurement specifically on a 2-wide OoO RISC-V core (simulation or RTL) was found.
- The I6400 "40-60% for <10% cluster area" quote reached me through search aggregation, and the exact article could not be pinned down.

---

## 2. The three meanings of "CMT": AMD Bulldozer clustered multithreading, Sun-style chip multithreading, and coarse-grained / switch-on-event multithreading

### Takeaway
- **Bulldozer CMT** duplicated the integer cores and L1Ds and shared the front end, FPU and L2. It delivered roughly 80% of two-core throughput for about 12% more module area, but per-thread performance suffered from halved OoO resources, a 16 KB write-through L1D, a slow L2 and process issues. AMD fixed the shared decoder in Steamroller and then abandoned CMT for SMT in Zen.
- **Sun-style chip multithreading** means many simple, fine-grained-threaded in-order cores (Niagara: 8 x 4 threads, about 20% core area for MT).
- **Coarse-grained / switch-on-event MT** (Montecito) costs under 2% core area for an estimated 15-35% on memory-bound database workloads, but only one thread uses the pipeline at a time.

For a 2-wide OoO core, Bulldozer-style sharing of a narrow front end is the least attractive option.

### Cited Findings

#### AMD Bulldozer "clustered multithreading" (2011; refined through Excavator, 2015)
- (AMD pre-launch claims, 2009-2010) The two framings of the throughput claim differ:
  - HEXUS reported up to 80% more throughput with two threads than one thread on a single integer core, and about 12% extra circuitry per module, which is about 5% of the total die. — [HEXUS](https://hexus.net/tech/news/cpu/21664-amd-talks-servers-present-future/?page=3)
  - Other coverage described a module as reaching about 80% of the performance of two complete cores, with the second integer core adding about 12% to module area (excluding L3 and northbridge). — [Lowyat forum relay](https://forum.lowyat.net/topic/1538872); [XtremeHardware](https://www.xtremehardware.com/6039-amd-bulldozer-at-debut-architecture-analysis?page=2)
  
  These are pre-silicon targets.
- (Hot Chips 2010 coverage and AMD's 2012 Titan workshop slides) What the module shared and duplicated:
  - Shared: instruction fetch and decode, the floating-point unit, the 64 KB 2-way L1I, a write-coalescing cache, and the 2 MB 16-way L2.
  - Duplicated per core: the integer scheduler and execution units, and a 16 KB 4-way write-through L1D.
  
  The FPU had one scheduler with some duplication so it could serve two threads, behind two 128-bit FMAC pipes and two 128-bit packed-integer pipes. — [HPCwire, Aug 2010](https://www.hpcwire.com/2010/08/24/amd_blazes_new_path_with_bulldozer/); [AMD Titan Workshop 2012 slides](https://www.olcf.ornl.gov/wp-content/uploads/2012/01/TitanWorkshop2012_Day1_AMD.pdf); [AnandTech Hot Chips 2010](https://at-web1.www.anandtech.com/show/3863/amd-discloses-bobcat-bulldozer-architectures-at-hot-chips-2010/4)
- (Bulldozer/Piledriver vs Steamroller, 2012-2014) The shared decoder served one core per cycle, alternating between the two. Steamroller duplicated the decoders so each core had its own and both could decode in parallel, at a cost in area and power. — [AnandTech Steamroller](https://at-web1.www.anandtech.com/show/6201/amd-details-its-3rd-gen-steamroller-architecture); [SemiAccurate](https://www.semiaccurate.com/2012/09/06/a-brief-look-at-amds-steamroller-core/)
- (Chips and Cheese retrospective, measured on FX-8150-class parts) Why it underperformed:
  - **Per-thread window.** Each thread got only its own core's reordering capacity: 2 x 128 ROB entries per module, while Sandy Bridge splits 192 entries into 2 x 96 under Hyper-Threading. Combined resources looked fine; single-thread performance did not.
  - **Shared front end and FPU.** These were not judged the main bottleneck.
  - **L1D.** Shrunk from 64 KB (K10) to 16 KB, latency up from 3 to 4 cycles, write-through; the 4 KB write-coalescing cache sustained just over 10 B/cycle.
  - **L2/L3.** The L2 had 20-cycle latency, and L3 latency exceeded 18 ns versus 12.7 ns on Sandy Bridge EP.
  - **TLB.** L2 TLB hits cost about 20 cycles.
  - **Process.** The 32 nm node was difficult, and duplicating the integer register file consumed area.
  - **Overall.** AMD "aimed too high" by combining a new architecture, a new node and multithreaded cores at once.
  
  — [Chips and Cheese, Bulldozer conclusion](https://chipsandcheese.com/p/bulldozer-amds-crash-modernization-caching-and-conclusion)
- (Zen 1, Hot Chips 2016) AMD replaced CMT with two-thread SMT. The L1D became write-back, and the I-cache was no longer shared between two cores. AMD claimed a 40% IPC uplift over Excavator. — [Hot Chips 28 Zen slides](https://old.hotchips.org/wp-content/uploads/hc_archives/hc28/HC28.23-Tuesday-Epub/HC28.23.90-High-Perform-Epub/HC28.23.930-X86-core-MikeClark-AMD-final_v2-28.pdf); [Wikipedia, Zen (first generation)](https://en.wikipedia.org/wiki/Zen_(first_generation))

#### Sun Niagara-style chip multithreading (UltraSPARC T1, 2005)
- (IEEE Micro, March-April 2005; Kongetira, Aingaran, Olukotun) "Niagara: A 32-Way Multithreaded Sparc Processor", optimized for commercial-server throughput rather than single-thread speed. — [IEEE Xplore](https://ieeexplore.ieee.org/document/1453485)
- (Sun slides, via search summary because direct fetch returned HTTP 403) Structure:
  - 8 cores x 4 threads; each core is a single-issue, 6-stage in-order pipeline.
  - Per thread: register sets, parts of the instruction-fetch datapath, and store and miss buffers.
  - Shared per core: caches, TLBs and execution units.
  - Multithreading adds roughly 20% to core area.
  
  — [Sun/Oracle Niagara microarchitecture slides](https://www.oracle.com/docs/tech/systems/59-niagara-microarch-poonacha.pdf)

#### Coarse-grained / switch-on-event ("temporal") multithreading: Intel Montecito (2005-2006)
- (ISSCC 2005; Itanium 2 "Montecito": 2 cores x 2 threads, 26.5 MB cache, 90 nm, 21.5 x 27.7 mm die, 1.72B transistors, 100 W)
  - Temporal MT switches threads on long-latency events such as an L3 miss.
  - All architectural state and some microarchitectural state is duplicated, so the die appears as 4 processors.
  - The thread-switch logic has no cycle-time impact. Only one thread occupies a core's pipeline at a time, while the caches keep serving both.
  - Estimated benefit on database workloads is 15-35%, depending on memory latency.
  - The integer and FP register files hold a duplicate register set with a 15% area impact on those files; other duplicated state uses dual-threaded latches.
  - Total MT cost is less than 2% core area growth.
  
  — [ISSCC 2005 paper 10.1 (IEEE Denver SSCS copy)](https://ewh.ieee.org/r5/denver/sscs/References/2005_02_Naffziger.pdf)
- (Secondary) The Montecito switch penalty is about 15 cycles, implemented by flushing the pipeline. — [RealWorldTech, "Two Approaches to Multithreading"](https://www.realworldtech.com/super-heavyweights/8); [Wikipedia, Montecito](https://en.wikipedia.org/wiki/Montecito_(processor))
- (FPGA analogue) The CUSTARD soft-processor project tried block multithreading, which switches only on long-latency events, and found it inferior to fine-grained multithreading for their soft processors. — [Labrecque & Steffan, FPL 2007](https://www.eecg.utoronto.ca/~steffan/papers/fpl07.pdf)

#### Middle ground: conjoined cores (academic)
- (MICRO 2004; Kumar, Jouppi, Tullsen) The paper treats CMP and SMT as two ends of a spectrum and proposes sharing FPUs, crossbar ports, I-caches and D-caches between adjacent cores. Arbitration is either simple (e.g., odd/even cycles) or smarter. The authors report that the performance loss from sharing is much smaller than the area saved. Numeric results were not retrieved (direct fetch returned HTTP 403). — [Conjoined-core CMP, MICRO 2004 (PDF)](https://www.eecis.udel.edu/~cavazos/cisc879-spring2008/papers/conjoining_micro04.pdf)

### Inferences
- **Bulldozer-style CMT on a 2-wide core.** Sharing a 2-wide fetch/decode between two clusters would halve each thread's front-end bandwidth whenever both run; this is exactly the bottleneck AMD removed in Steamroller. A Bulldozer-style extension would therefore need a wider shared front end, which on an FPGA likely costs more than SMT. A shared FPU (FP/vector datapaths are large on FPGAs) plus a shared L2 is the one Bulldozer idea that maps well onto an FPGA.
- **Coarse-grained MT as a first step.** Switch-on-L2-miss MT is the cheapest first step in ASIC terms (<2% area at Montecito). In an OoO core, however, every switch flushes the in-flight window, and the second thread's architectural registers must stay resident (extra physical registers) or be swapped from BRAM. On FPGA DDR latencies of on the order of 100 core cycles at low clock rates, a 15-30-cycle refill penalty eats much of the gain. Treat it as a fallback, not the target.
- **Niagara-style fine-grained barrel threading.** This suits small in-order FPGA cores (Section 4), but conflicts with the goal of beating NaxRiscv on single-thread IPC. It is relevant only if a separate throughput tile is ever wanted.
- **"Dual-core" today already resembles one corner of CMT.** The best hedge is a coherent L2/interconnect with a parameterized agent count, so that either a third or fourth core, a Bulldozer-style second cluster, or SMT threads can attach without a fabric redesign.

### Gaps
- The Butler et al. IEEE Micro 2011 Bulldozer paper and the Hot Chips 2010 slides were not read directly. Module figures come from AMD's 2012 workshop slides and press coverage.
- No source was retrieved for AMD's own stated reasons for dropping CMT; the Chips and Cheese analysis is third-party.
- Spracklen & Abraham (HPCA 2005, "Chip Multithreading: Opportunities and Challenges"), which popularized the term "chip multithreading", was not retrieved.
- The Montecito 15-cycle switch penalty comes from secondary sources and Intel presentations; the McNairy & Bhatia IEEE Micro 2005 text was not read.

---

## 3. RISC-V specifics: the hart model, per-hart state, LR/SC between siblings, RVWMO and shared store buffers, TLB/ASID tagging, per-hart interrupts and timers, and existing multithreaded RISC-V cores

### Takeaway
RISC-V explicitly allows a core to implement several harts via multithreading, and each hart must look like an independent CPU. The spec text creates several concrete SMT obligations:
- **Full privileged state per hart.** Every hart needs its own CSRs and privileged state, including PMP and `satp`.
- **No early inter-hart store forwarding.** RVWMO is (other-)multi-copy atomic, so SMT siblings must never forward from each other's not-yet-globally-visible stores.
- **Sibling stores break reservations.** A sibling's store must break an LR reservation just as a remote store would.
- **Thread-tagged TLBs.** ASIDs are local to a hart and translation caches must appear private to each hart, so a shared TLB must tag entries by hart, not just by ASID.
- **Per-hart interrupts and timers.** These are per hart via the ACLINT/PLIC/AIA platform devices.
- **Optional hints.** PAUSE and Zawrs give SMT-aware spin-waiting.

The existing multithreaded RISC-V cores (VeeR EH2, MIPS P8700, Akeana, FlexPRET) show workable partitionings.

### Cited Findings

#### Hart model and topology
- (Unprivileged ISA, v20260120) "A RISC-V-compatible core might support multiple RISC-V-compatible hardware threads, or harts, through multithreading." A hart is "a resource that autonomously fetches and executes RISC-V instructions", and a core is a component with "an independent instruction fetch unit". — [RISC-V unprivileged spec, Introduction](https://docs.riscv.org/reference/isa/v20260120/unpriv/intro.html)
- (Linux DT binding) Linux learns SMT topology from the `cpu-map` binding. Thread nodes sit inside a core node, one per hardware thread when the system supports SMT, and each points to a `cpu` node. The binding states that ARM and RISC-V intend to use it. — [Linux DT cpu-topology binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/cpu/cpu-topology.txt)

#### Per-hart interrupts and timers
- (ACLINT spec, GitHub) MTIMECMP registers are per hart, while one physical MTIME may be shared. MSWI provides a per-hart 32-bit MSIP register for machine IPIs, and SSWI a per-hart SETSSIP register for supervisor IPIs. One device supports up to 4095 harts. A device's hart index starts at zero and "may or may not have any relationship" to `mhartid`. — [RISC-V ACLINT spec](https://github.com/riscv/riscv-aclint/blob/main/riscv-aclint.adoc)
- (Privileged spec, v20260120) With Sstc, `stimecmp` is a CSR and so per hart; STIP reflects the comparison against `time`. — [RISC-V privileged spec, Supervisor chapter](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)

#### LR/SC between SMT siblings
- (A extension, v20260120) Reservation rules:
  - A hart holds only one reservation at a time, and an SC pairs only with the most recent LR in program order.
  - Any SC, whether it succeeds or fails, invalidates the hart's reservation.
  - The SC must fail if the address is not in the reservation set, or if a store from another hart to the reservation set "can be observed to occur" between the LR and SC.
  - Implementations may fail an SC occasionally for any reason, and may unconditionally fail unconstrained LR/SC sequences.
  
  — [RISC-V A extension](https://docs.riscv.org/reference/isa/v20260120/unpriv/a-st-ext.html)
- (same) Forward-progress guarantee for constrained LR/SC loops:
  - The loop is at most 16 sequential instructions of base "I" (plus allowed compressed forms), with no loads, stores, backward jumps, taken backward branches, JALR, FENCE or SYSTEM between LR and SC, in memory with the LR/SC eventuality property.
  - The environment must guarantee that eventually one of these happens: the SC succeeds, another hart stores or does an AMO to the set, the loop is exited, or a trap is taken.
  - Other harts' loads, "possibly within the same core", must not impede progress indefinitely.
  - Evictions from a shared cache must not block progress, which "implies reservations are tracked independently of evictions from any shared cache."
  
  — [RISC-V A extension](https://docs.riscv.org/reference/isa/v20260120/unpriv/a-st-ext.html)
- (VeeR EH2 PRM rev 1.4, 2022-12-22; dual-threaded RV32IMAC core) An LR reservation is cleared by:
  - an SC to any address on that hart;
  - any store from the other hart, or from the DMA slave, to the reserved address;
  - an interrupt, exception or `mret` on that hart;
  - that hart entering or exiting debug halt or sleep.
  
  EH2 also limits all atomics to the core-local DCCM, because their main purpose is synchronizing the two harts. It inserts an implicit fence before every atomic and treats LR/SC as if both aq and rl were set. — [VeeR EH2 Programmer's Reference Manual (PDF)](https://raw.githubusercontent.com/chipsalliance/Cores-VeeR-EH2/main/docs/RISC-V_VeeR_EH2_PRM.pdf)

#### RVWMO and store buffers shared between harts (multi-copy atomicity)
- (RVWMO explanatory material, section "Implementation Guidelines", v20260120) The spec is explicit on four points:
  - "Both RVWMO and RVTSO are multi-copy atomic (or other-multi-copy-atomic)."
  - Harts may forward from their own previous stores before those stores are globally visible, but "no early inter-hart forwarding is permitted."
  - "a hart may not legally forward a value from a neighbor hart's private store buffer."
  - "Nor may a cache coherence protocol forward a value from one hart to another" early.
  
  The same appendix notes that because RISC-V is multi-copy atomic, fences can be reasoned about thread-locally (they are not cumulative). — [RVWMO explanatory material](https://docs.riscv.org/reference/isa/v20260120/unpriv/mm-eplan.html)
- (Cambridge tutorial on ARM/POWER; background for why this matters) A straightforward microarchitectural explanation of POWER's non-multi-copy-atomic IRIW behaviour is a storage hierarchy in which two threads are "neighbours" that see each other's writes before other threads do. SMT siblings sharing a store buffer or cache level are exactly such neighbours. — [Maranget, Sarkar, Sewell, "A Tutorial Introduction to the ARM and POWER Relaxed Memory Models"](https://www.cl.cam.ac.uk/~pes20/ppc-supplemental/test7.pdf)
- (POPL 2018) ARMv8 was originally non-multi-copy-atomic, but because that freedom "has not been exploited in production implementations", the architecture was revised to be multicopy-atomic. RISC-V's model is formalized alongside it. — [Pulte et al., POPL 2018](https://popl18.sigplan.org/event/popl-2018-papers-multicopy-atomic-axiomatic-and-operational-models-for-armv8); [Cambridge repository, "The Semantics of Multicopy Atomic ARMv8 and RISC-V"](https://www.repository.cam.ac.uk/handle/1810/292229)
- (VeeR EH2 PRM) EH2's memory-ordering rules apply per thread only: "No ordering is maintained between loads and stores of different harts." Each thread's bus-bound loads and stores go through a per-thread unified read/write FIFO buffer. — [VeeR EH2 PRM](https://raw.githubusercontent.com/chipsalliance/Cores-VeeR-EH2/main/docs/RISC-V_VeeR_EH2_PRM.pdf)

#### Address translation: ASIDs, TLB sharing, SFENCE.VMA
- (Privileged spec, Supervisor chapter, v20260120) The spec makes several points that bind SMT designs directly:
  - "the meaning of an ASID is local to a hart", so software may reuse one ASID value for different address spaces on different harts. A future extension could make ASIDs global, which would enable shared translation caches.
  - An address-translation cache "must appear to be private to that hart."
  - SFENCE.VMA orders only the local hart's implicit memory-management references; other harts must be notified separately by IPI and run their own SFENCE.VMA (the RISC-V "TLB shootdown").
  
  — [RISC-V privileged spec, Supervisor chapter](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
- (AMD Zen, for comparison) Zen's caches and TLBs are competitively shared but must be tagged by thread. — [Chips and Cheese interview with Mike Clark](https://chipsandcheese.com/2024/07/15/a-video-interview-with-mike-clark-chief-architect-of-zen-at-amd/)

#### SMT-relevant hints
- (Zihintpause) PAUSE (encoded as a FENCE hint) indicates "the current hart's rate of instruction retirement should be temporarily reduced or paused". The spec notes "Multithreaded cores might temporarily relinquish execution resources to other harts when PAUSE is executed" and recommends one PAUSE per spin-wait loop iteration. — [Zihintpause](https://docs.riscv.org/reference/isa/v20260120/unpriv/zihintpause.html)
- (Zawrs) WRS.NTO and WRS.STO stall the hart in a low-power state while its reservation set is valid, until a store hits the set, an interrupt is pending, or (for WRS.STO) a short timeout expires. Implementations may end the stall early. The rationale is to avoid wasteful polling; SMT is not mentioned explicitly. — [Zawrs](https://docs.riscv.org/reference/isa/v20260120/unpriv/zawrs.html)

#### Existing multithreaded RISC-V cores and how they partition state
- (VeeR EH2, formerly SweRV EH2; announced December 2019; RV32IMAC, M-mode only, 9-stage, dual-issue, "mostly in-order with some out-of-order execution capability", 2 threads)
  - **Performance and area:** 6.3 CoreMark/MHz simulated with two threads, and 0.067 mm² in TSMC 16 nm per WD. — [Western Digital press release](https://www.westerndigital.com/company/newsroom/press-releases/2019/2019-12-10-western-digital-brings-memory-closer-to-compute-with-new-risc-v-innovations); [CHIPS Alliance repo](https://github.com/chipsalliance/Cores-VeeR-EH2)
  - **Duplicated hardware:** the GPRs, CSRs, fetch buffers and instruction buffers, so software "sees two cores". — [SemiEngineering](https://semiengineering.com/about-the-swerv-core-eh2/)
- (VeeR EH2 PRM rev 1.4) Thread-related provisions:
  - CSRs and memory-mapped registers are each documented as either per thread (a thread sees only its own copy) or per core (shared). My count of the PRM's labels found roughly as many "shared by the harts" registers as "hart-specific" ones, across CSRs and memory-mapped registers.
  - Separate timer and software interrupt pins per thread.
  - One PIC, with each external interrupt source delegated to one thread. The PIC's evaluation tree is shared and time-multiplexed: alternate cycles when both threads run, a 7:1 cycle ratio when one is halted, and 8-cycle slots when both are halted.
  - An NMI-steering register.
  - Per-thread power management and debug halt/resume.
  - Hart 0 starts at reset and releases hart 1 via an `mhartstart` CSR, and `mhartnum` reports the thread count.
  - A thread has no access to its sibling's registers or CSRs.
  
  — [VeeR EH2 PRM](https://raw.githubusercontent.com/chipsalliance/Cores-VeeR-EH2/main/docs/RISC-V_VeeR_EH2_PRM.pdf)
- (MIPS P8700, datasheet rev 1.22, November 2024; RV64GC + Zba/Zbb, OoO, "full hardware multithreading and hardware virtualization")
  - **Front end:** a "Fetch Director" chooses which hart to fetch next; each hart has its own instruction buffer and return prediction stack. The TAGE predictor is shared, but global and local histories are stored per hart.
  - **Execution:** issue can mix harts in one cycle, with round-robin priority among harts. Up to 4 instructions graduate per clock per hart, and operands come from an architectural register file plus a working register file.
  - **TLBs:** micro-ITLB/DTLB are shared between harts; the VTLB has 32 dual entries per hart; the 512-dual-entry FTLB is shared by all harts.
  - **Caches and debug:** 32/64 KB L1I and L1D, shared by harts. Each hart can enter debug mode independently.
  - **Interrupts:** the cluster interrupt controller conforms to AIA.
  - **Scale:** up to 64 clusters, 512 cores and 2048 harts. The harts-per-core value is configurable; 4 per core is implied by that ratio but not stated.
  
  — [MIPS P8700 datasheet](https://mips.com/wp-content/uploads/2024/11/P8700_Data_Sheet.pdf)
- (Akeana, 2024-2025) SMT is a configuration option of up to four threads per core across in-order and out-of-order designs. Demos at the RISC-V Summit (Santa Clara, 2025) ran 1, 2 and 4 threads on the Akeana 1200 (RV64 in-order) and Akeana 5100 (RV64 OoO). The launch coverage and later material disagree on whether the 100 series is single-threaded. — [Akeana demos](https://www.akeana.com/category/demos/); [SemiWiki webinar listing](https://semiwiki.com/events/359777-unlocking-efficiency-and-performance-with-simultaneous-multi-threading/); [All About Circuits launch article](https://www.allaboutcircuits.com/news/akeana-exits-stealth-with-low-to-high-end-riscv-alternatives-to-arm/)
- (FlexPRET, Berkeley, 2013-2015; Chisel) A 5-stage fine-grained multithreaded RISC-V core for mixed-criticality systems with no branch predictor. Hard real-time threads get fixed cycle slots and soft real-time threads use the rest. — [FlexPRET GitHub](https://github.com/pretis/flexpret); [Berkeley tech report EECS-2013-172](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2013/EECS-2013-172.html)
- (Academic RISC-V SMT, 2022-2025)
  - B4SMT, a RISC-V SMT processor (2022), was extended with vectors; SMT cut cycles by about 53.8% on matrix multiplication versus single-thread execution (IEICE, March 2024). — [IEICE technical report](https://ken.ieice.org/ken/paper/20240322fcc3/eng/)
  - A UPC master's thesis (2024) built the front end of an SMT superscalar OoO RISC-V core. — [UPCommons](https://upcommons.upc.edu/server/api/core/bitstreams/8e1a8a59-a3c6-4220-ab80-e21ed345ea31/content)
  - IEEE Access (2025) proposed a 2-way superscalar in-order multithreaded RISC-V microarchitecture. — [DOAJ record](https://doaj.org/article/67741b6d26584a1abe15db5ccd3afb55)

### Inferences
- **Store forwarding.** In a shared store queue or committed store buffer, store-to-load forwarding must match on thread ID as well as address. A sibling's load may see a store only after the store is written into the L1D with write permission. That write is the global-visibility point, and it is legal because the L1D is the single coherence agent for both threads. Unified LSQs that forward on address alone would violate RVWMO's other-multi-copy atomicity in exactly the way the spec forbids.
- **Ordering violations from siblings.** A sibling's commit into the L1D must be treated like an external coherence invalidation for this thread's speculatively executed loads, so same-address load-load ordering (coherence) holds. A dual-core design already needs an invalidation-snoop path into the LQ; the hook is to let the sibling's store-commit port drive the same path.
- **LR/SC.** Each hart needs its own reservation register. The L1D write/AMO port must compare sibling stores against the other hart's reservation; coherence probes already cover remote cores.
  - Livelock is a real risk: two siblings running LR/SC loops on the same line can kill each other's reservations indefinitely. A bounded hold-off (after an LR, briefly delay the sibling's conflicting store or SC) or deterministic priority is needed to honour the eventual-success guarantee. Intel's experience with livelock-avoidance plus fallback algorithms is the cautionary precedent.
  - Clearing reservations on traps or `mret` (as EH2 does) is a simple conservative choice.
- **TLB tagging.**
  - Shared TLB and page-walk-cache entries must carry a hart tag, because ASIDs are hart-local.
  - The PTE "G" (global) bit makes an entry global across that hart's ASIDs only, not across siblings.
  - PMP is per hart, so any PMP/PMA result cached in a TLB entry must also be hart-specific.
  - An SFENCE.VMA by one hart may invalidate its sibling's entries too (over-invalidation only costs performance), which permits a simple "flush all" implementation.
- **Platform.** Size ACLINT/PLIC/AIA instances by harts, not cores. Map `mhartid` as core index times threads per core plus thread index, describe siblings with DT `cpu-map` thread nodes so Linux (and its core-scheduling feature) can see them, and boot harts through standard SBI hart-state management.
- **EH2's split is a useful template.** Keep all ISA-architected CSRs per hart, and allow implementation-defined control CSRs (cache control, error counters, debug knobs) to be per core. For S-mode Linux, though, every standard M/S/U CSR including PMP and the counters must be per hart.
- **PAUSE and WRS.\*** These are cheap to implement as "deprioritize or stop this thread's fetch" in an SMT core. In v1, PAUSE can be a no-op and WRS a WFI-like stall.

### Gaps
- The MIPS I8500 (RISC-V, in-order, multithreaded) thread count and partitioning were not verified, and neither were the exact P8700 harts-per-core options.
- No SMT implementation of BOOM, XiangShan or another open-source OoO RISC-V core was found; the search budget ran out before "XiangShan SMT" and "Chipyard SMT" queries could be run.
- The spec does not discuss SMT LR/SC livelock explicitly; the recommendation above is an inference.
- The AIA IMSIC per-hart interrupt-file model and PLIC per-hart contexts were not re-fetched for citation (both are standard RISC-V platform knowledge).

---

## 4. Multithreading in FPGA soft processors: gains and FPGA-specific costs

### Takeaway
On FPGAs, fine-grained (barrel) multithreading of simple pipelines is well proven: it removes hazard detection and forwarding logic, raises clock rate, and improves area efficiency by 33-106% (Stratix, 2007) or reaches BRAM-limited clock rates (Octavo, 550 MHz on Stratix IV, 2012). The enabling FPGA trick is to keep per-thread architectural state in one deeper on-chip RAM addressed by thread ID, instead of replicating registers and adding multiplexers. Published OoO SMT soft processors were not found, so costs for this design must be estimated from first principles (see Section 6).

### Cited Findings
- (FPL 2007; Labrecque & Steffan; MIPS-like SPREE soft processors on Altera Stratix EP1S40, fastest speed grade, Quartus 5.0, 10 placement seeds)
  - Single-threaded baselines were 3-stage (1256 equivalent LEs, 78.3 MHz), 5-stage (1365 LEs, 86.79 MHz) and 7-stage (1639 LEs, 100.59 MHz).
  - Fine-grained multithreaded versions, with as many threads as pipeline stages, improved IPC by 24%, 45% and 104% and area efficiency (MIPS per 1000 LEs) by 33%, 77% and 106% respectively.
  - Multithreading removes hazard-detection logic, forwarding paths and load/branch delay slots.
  - The register file is not physically replicated. Different address ranges of one shared BRAM (M4K) register file are indexed by shifting the register number by the thread ID, which avoids costly multiplexers. Instruction and data memories are mapped the same way.
  - Replicated Hi/Lo registers cost noticeably more area than 3-operand multiplies, because of the extra multiplexing.
  
  — [Labrecque & Steffan, FPL 2007](https://www.eecg.utoronto.ca/~steffan/papers/fpl07.pdf)
- (same paper) Fort et al. built a 4-way multithreaded soft processor that saved significant area compared with four soft processors, at a moderate performance cost, and showed hazard detection and forwarding can be dropped when thread count equals pipeline depth. CUSTARD built a similar 4-stage, 4-way multithreaded soft processor and found block (switch-on-event) multithreading inferior to fine-grained. FPGAs suit replicated thread state because on-chip memory latency grows only slowly with memory size, unlike in ASICs. — [Labrecque & Steffan, FPL 2007](https://www.eecg.utoronto.ca/~steffan/papers/fpl07.pdf)
- (FPGA 2012; LaForest & Steffan) Octavo is a 10-stage, 8-thread processor that runs at the 550 MHz block-RAM maximum of Stratix IV, built around the FPGA's fixed blocks rather than ASIC-derived layouts. The author's rough estimate is 2.6x a scalar soft processor, and up to 4x in practice, at the cost of splitting programs across 8 threads. A follow-up reached 500 MHz on Stratix IV with 1.07x-1.92x speedups from overlapping overhead computation. — [Octavo, FPGA 2012 (PDF)](https://www.eecg.utoronto.ca/~steffan/papers/laforest_octavo_fpga12.pdf); [Octavo project page](https://fpgacpu.ca/octavo/)
- (FlexPRET) This RISC-V fine-grained MT core relies on a "barrel" register file and thread interleaving instead of branch prediction to avoid pipeline bubbles. — [FlexPRET GitHub](https://github.com/pretis/flexpret)

### Inferences
- **The FPGA results transfer only partly to OoO.** The 33-106% gains depend on removing hazard and forwarding logic in in-order pipelines with as many threads as stages. An OoO core already tolerates hazards, so SMT on an OoO soft core will look more like ASIC SMT (utilization recovery), not like barrel threading.
- **What does carry over is the storage technique.** Put thread state where depth is cheap and index it by thread ID: BRAM for architectural copies and coarse-grained context swap; LUTRAM banks whose depth grows from 32 to 64 for RAT and CSR banks. Avoid structures whose cost scales with read ports times threads, such as FF-based register files with full multiplexers.
- **Multi-ported register files are the main SMT cost on an FPGA OoO core.** Adding 32 integer plus 32 FP physical registers for the second architectural context is about 4 kbit of raw storage, but it multiplies by the port-replication factor of the multi-port scheme used (LUTRAM banking, live-value-table or XOR-based designs). Expect this, plus rename/CSR depth growth and arbitration muxes, to dominate, rather than the per-entry thread-ID bits.
- **LUTRAM depth (to verify).** On AMD UltraScale+ fabric, LUTRAM is natively organized in 64-deep (or 32-deep dual-bit) LUT primitives. Whether doubling a 32-entry RAT or CSR bank to 64 entries is nearly free or doubles LUTs depends on which primitive v1 uses; check against the CLB guide (UG574) and synthesis results before committing.
- **Fmax risk.** Thread muxing in wakeup/select, bypass and rename can lower Fmax, which directly erodes the single-thread IPC-per-second goal against NaxRiscv. Hooks must not add logic levels in v1, so they should be compile-time parameters that tie off to constants.

### Gaps
- No published out-of-order SMT soft processor (FPGA implementation with measured LUT/FF/Fmax overhead) was found. This is a genuine literature gap, or at least one not reachable before the search budget ran out.
- The original Fort et al. (FPL/FCCM 2006) and CUSTARD (Dimond, Mencer, Luk, FPL 2005) numbers were not retrieved directly; they are known here only through Labrecque & Steffan's summary.
- Multithreaded MicroBlaze/Nios variants (e.g., Moussali et al., 2007) were not retrieved.
- Precise UltraScale+ LUTRAM primitive configurations (depth and port counts) were not fetched from AMD documentation.

---

## 5. SMT security issues (PortSmash, cache/TLB side channels, Spectre/MDS) and mitigations that affect hooks

### Takeaway
Because sibling threads share execution ports, TLBs, caches, predictors and internal buffers in the same cycle, SMT creates side channels that context-switch flushing cannot close. The industry answers are: optionally disable SMT; schedule only mutually trusting tasks on siblings (Linux core scheduling); isolate predictors between siblings (STIBP); flush shared buffers on privilege transitions (MDS); and write port- and cache-independent crypto. Each answer maps to a hardware hook: thread-tagged or partitionable predictors and buffers, a per-core SMT on/off control, and well-defined flush points.

### Cited Findings
- (PortSmash, disclosed November 2018; Tampere University of Technology and Universidad Tecnológica de La Habana; CVE-2018-5407)
  - Execution-port contention between SMT siblings forms a timing side channel.
  - The researchers recovered an OpenSSL P-384 private key (OpenSSL up to 1.1.0h) from a TLS server running on the sibling thread.
  - Proposed mitigations were disabling SMT, and writing port-independent code.
  
  — [TechTarget](https://www.techtarget.com/cybersecurity/news/252452053/PortSmash-side-channel-attack-targets-Intel-Hyper-Threading); [Gigazine](https://www.gigazine.net/gsc_news/en/20181105-intel-cpu-hyperthreading-exploit-portsmash); [Security Affairs](https://securityaffairs.com/77671/hacking/portsmash-flaw.html)
- (TLBleed, 2018; Vrije Universiteit Amsterdam) The attack goes through the TLBs shared between hyperthreads and recovers a 256-bit signing key with 99.8% success on Skylake/Coffee Lake and 98.2% on Broadwell Xeon. Its lesson is that cache-only side-channel defences are insufficient. OpenBSD responded by adding a switch to disable hyperthreading and turning HT off by default. — [TechTarget, TLBleed](https://www.techtarget.com/cybersecurity/news/252443819/TLBleed-attack-can-extract-signing-keys-but-exploit-is-difficult?amp=1)
- (Intel STIBP, 2018) Single Thread Indirect Branch Predictors prevents a sibling hyperthread from controlling indirect-branch predictions. It exists because the logical processors of a core may share indirect branch predictors, and the sharing happens only within a core. — [Intel speculative-execution mitigations guidance](https://intel.com/content/www/us/en/develop/articles/software-security-guidance/technical-documentation/speculative-execution-side-channel-mitigations.html)
- Enabling STIBP everywhere was costly enough that Linux applies it selectively. It is combined with IBPB flushes of the BTB when switching to or from a protected program. — [LWN](https://lwn.net/Articles/773118)
- (MDS, 2019; Linux documentation) Microarchitectural buffers can expose a sibling's data. The mitigation flushes these buffers on exit to user space or on VMENTER. — [Linux kernel MDS documentation](https://kernel.org/doc/html/v7.2-rc2/_sources/arch/x86/mds.rst.txt)
- (Linux core scheduling, merged around v5.14 in 2021)
  - Each scheduling event selects tasks for all siblings of a core so that co-running tasks share a trust "cookie"; if none is available, a sibling is forced idle.
  - Documented limitations: a short window of concurrent untrusted execution caused by IPI latency; no protection against MDS when one sibling runs kernel code on behalf of a task; and no protection against L1TF guest attacks, for which disabling EPT is described as the only solution.
  
  — [Linux core scheduling documentation](https://www.kernel.org/doc/html/v5.14/admin-guide/hw-vuln/core-scheduling.html)
- (Zen) Caches and TLBs are shared but tagged by thread. — [Chips and Cheese interview with Mike Clark](https://chipsandcheese.com/2024/07/15/a-video-interview-with-mike-clark-chief-architect-of-zen-at-amd/)
- (Tullsen 1996) Per-entry thread IDs in the BTB stop "phantom branch" mispredictions caused by another thread's entries. — [Tullsen et al., ISCA'96](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf)

### Inferences
- **Predictor tagging serves v1 too.** A context tag on BTB/RAS/indirect-predictor entries (thread ID, privilege level and/or ASID bits), or a cheap predictor-flush control, is needed for Spectre-v2-style mitigation even in a single-threaded v1. It doubles as the SMT isolation knob, STIBP-like when tagging by thread.
- **Fill and store buffers.** Keep miss-handling (fill) buffers and store buffers either partitioned per thread or tagged with thread ID and cleared or invalidated on privilege transitions. The hardware equivalent of the MDS "flush on exit" is easier to provide than to retrofit.
- **SMT disable switch.** Provide a per-core control (CSR or boot-time strap) that runs one thread with all partitioned resources recombined. This gives OS and administrator policy (OpenBSD-style) a clean single-thread mode and is also the performance mode for single-thread benchmarks.
- **Port contention cannot be designed away** without giving up SMT's benefit (Raasch shows static issue partitioning costs throughput). Leave it to software (core scheduling, constant-time crypto) and document it.
- **Cache partitioning.** Optional L1D/L2 way-partitioning masks per thread are a cheap hook. They trade some of the shared-cache benefit Intel measured (+12% performance) for isolation when wanted.

### Gaps
- CacheBleed (cache-bank conflicts between hyperthreads, CHES 2016), Percival's 2005 "Cache missing for fun and profit" HT attack, SMoTherSpectre (CCS 2019) and RIDL/ZombieLoad primary papers were not retrieved; MDS details above come from Linux documentation only.
- No RISC-V-specific SMT security guidance (e.g., from the RISC-V security SIGs) was found within budget.

---

## 6. Concrete checklist of day-one hooks for a single-threaded 2-wide OoO RV64 core (with estimated v1 cost)

### Takeaway
Nearly every SMT hook can be built into v1 at close to zero FPGA cost if it is expressed as a compile-time "harts per core" parameter set to 1, with thread-ID fields of width 0 or tied to a constant. What does have real cost later is:
- the larger physical register file and rename tables;
- per-hart CSR banks;
- thread-aware arbitration.

What is expensive to retrofit is anything whose v1 design implicitly assumes a single thread:
- ROB-index-based age comparisons;
- global "flush everything" events;
- store forwarding by address only;
- untagged TLB and predictor entries;
- a single LR/SC reservation register with no sibling snoop.

These are the hooks to get right on day one.

### Cited Findings (evidence underpinning each hook)
- **Minimum per-thread additions (Tullsen 1996):** multiple PCs with fetch selection, a return stack per thread, per-thread retirement, instruction-queue flush and trap mechanisms, BTB thread IDs, and a larger shared physical register file. — [Tullsen et al., ISCA'96](https://www-old.cs.utah.edu/~rajeev/cs7810/papers/tullsen96.pdf)
- **What Intel replicated:** RAT, next-PC, return stack, streaming/fill buffers, ITLB and APIC per logical processor, with partition, threshold or full-sharing policies chosen per structure. — [Koufaty & Marr 2003](https://faculty.kfupm.edu.sa/COE/mudawar/coe502/papers/2003.HyperthreadingNetburst.IEEEMicro.pdf)
- **What AMD partitions:** the ROB/retire queue, store queue and micro-op queue are statically partitioned in Zen, chosen for design simplicity; caches and TLBs are shared and tagged. — [Chips and Cheese interview](https://chipsandcheese.com/2024/07/15/a-video-interview-with-mike-clark-chief-architect-of-zen-at-amd/); [LLVM review (96 retire entries per thread)](https://reviews.llvm.org/D47676?id=151408)
- **Static partitioning costs little:** equal static partitioning of IQ/ROB performs well, while static issue-bandwidth partitioning hurts. — [Raasch & Reinhardt, PACT 2003](https://static.aminer.org/pdf/PDF/000/009/820/the_impact_of_resource_partitioning_on_smt_processors.pdf)
- **A modern RISC-V SMT partitioning:** per-hart fetch buffers and return stacks; a shared TAGE with per-hart histories; round-robin issue across harts; shared micro-TLBs and FTLB with per-hart VTLB. — [MIPS P8700 datasheet](https://mips.com/wp-content/uploads/2024/11/P8700_Data_Sheet.pdf)
- **RISC-V rules any SMT implementation must satisfy:**
  - no inter-hart forwarding before global visibility — [RVWMO explanatory material](https://docs.riscv.org/reference/isa/v20260120/unpriv/mm-eplan.html)
  - hart-local ASIDs and translation caches that appear private — [privileged spec, Supervisor](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
  - SC fails on another hart's store, with the constrained-loop forward-progress guarantee — [A extension](https://docs.riscv.org/reference/isa/v20260120/unpriv/a-st-ext.html)
  - per-hart timers and IPIs — [ACLINT](https://github.com/riscv/riscv-aclint/blob/main/riscv-aclint.adoc)
  - SMT resource relinquishing on PAUSE — [Zihintpause](https://docs.riscv.org/reference/isa/v20260120/unpriv/zihintpause.html)
- **EH2's per-thread provisions:** per-thread vs per-core CSR split, per-thread timer/software-interrupt pins, PIC delegation, per-thread debug/power, and reservation clearing on sibling store, trap or `mret`. — [VeeR EH2 PRM](https://raw.githubusercontent.com/chipsalliance/Cores-VeeR-EH2/main/docs/RISC-V_VeeR_EH2_PRM.pdf)
- **FPGA storage trick:** index per-thread state in one RAM by thread ID rather than adding replicated registers and multiplexers. — [Labrecque & Steffan, FPL 2007](https://www.eecg.utoronto.ca/~steffan/papers/fpl07.pdf)
- **Coarse-grained MT cost on ASIC:** duplicated register sets plus dual-threaded latches, under 2% core area, with a pipeline flush on switch. — [Montecito ISSCC 2005](https://ewh.ieee.org/r5/denver/sscs/References/2005_02_Naffziger.pdf)
- **OS visibility:** SMT siblings are described to Linux through DT thread nodes. — [Linux cpu-topology binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/cpu/cpu-topology.txt)
- **OS-side mitigations assume hardware support:** core scheduling (forced idle), STIBP-like predictor isolation, and buffer flushes on privilege transitions. — [Linux core scheduling docs](https://www.kernel.org/doc/html/v5.14/admin-guide/hw-vuln/core-scheduling.html); [Intel mitigation guidance](https://intel.com/content/www/us/en/develop/articles/software-security-guidance/technical-documentation/speculative-execution-side-channel-mitigations.html)

### Inferences

#### Hook checklist
Cost estimates are mine and assume an illustrative v1 configuration: 2-wide decode/rename/commit, a 64-entry ROB, a 96-128-entry integer PRF, a 64-96-entry FP PRF, about 40 issue-queue entries, 16-entry LQ and SQ, 16-32-entry L1 TLBs, a 256-512-entry L2 TLB in BRAM, a 512-1K-entry BTB and a 16-entry RAS. "v1 cost" means what including the hook costs in the single-thread build. "SMT2 add-on" means the extra resources when harts per core goes to 2. All figures are rough FPGA estimates, not measurements.

| # | Hook | What to build into v1 (single-thread) | Est. v1 cost | Est. SMT2 add-on | Why / evidence |
|---|---|---|---|---|---|
| 1 | Global "harts per core" parameter and thread-ID (TID) type on every internal interface: fetch packet, uop, ROB/IQ/LQ/SQ entries, branch tags, exceptions, CSR ops, memory and PTW requests, TLB/BTB entries, perf events, debug | TID width = log2(harts) = 0 bits, or a constant 0 that synthesis removes | ~0 LUT/FF; mostly interface discipline and a verification plan | 1 bit per entry everywhere: a few hundred FFs plus spare BRAM width; small equality comparators | Tullsen per-thread mechanisms; HT/Zen tagging |
| 2 | Hart-ID mapping and platform sizing | `mhartid` = core index x harts-per-core + TID; ACLINT/PLIC/AIA and DT generated per hart; DT `cpu-map` with core/thread nodes | ~0 | One more set of per-hart timer/IPI/PLIC-context registers per thread (64-bit compare + small regs) | ACLINT per-hart MTIMECMP/MSIP; DT thread nodes |
| 3 | Per-thread fetch state and fetch arbiter | Store PC/next-PC, fetch-target queue and fetch-buffer pointers in TID-indexed arrays of depth 1; a thread-select point in the front end (round-robin, later ICOUNT using per-thread in-flight counters) | ~0 (1-input arbiter) | Duplicated PC regs plus small counters (~200-400 FFs); fetch-buffer partition logic | ICOUNT (Tullsen); P8700 Fetch Director; HT duplicated next-IP |
| 4 | Non-blocking I-fetch per thread | One I-cache MSHR, but "fetch blocked" kept per TID so a missing thread can be parked | ~0 | +1 I-MSHR and a park/unpark state machine | Tullsen fetches only from threads not stalled on an I-cache miss |
| 5 | Branch-predictor state | Speculative and committed global history plus checkpoints and the RAS stored per TID (depth 1); reserve a context-tag field in BTB entries (also usable for ASID/privilege tagging against Spectre-BTB in v1); shared PHT/TAGE tables | ~0 for histories/RAS; BTB tag bits often free in BRAM width slack | RAS copy (16 x ~40 bits) + GHR copy (tens to hundreds of bits) | Tullsen BTB thread ID + per-thread return stack; HT duplicated RAS; P8700 shared TAGE with per-hart histories and RAS |
| 6 | RVC alignment and decode state | Any cross-fetch-block state (half-instruction buffer, fusion window) indexed by TID | ~0 | Tiny | Correctness when threads interleave fetch blocks |
| 7 | Rename tables | Speculative RAT, committed RAT and branch checkpoints addressed by {TID, arch reg}; checkpoint pool sizing parameterized | ~0 if parameterized | RAT depth 32 to 64 for int and FP (~0.9 kbit per thread for spec + committed tables at 7-bit tags); LUT cost depends on LUTRAM primitive (verify against UG574) | HT replicated RATs; Tullsen shared PRF |
| 8 | Physical register file and tag width | Make PRF size and tag width parameters (do not hard-code 7-bit tags); shared free list with an optional per-thread allocation cap | ~0 as parameter (avoid physically reserving an extra tag bit, which widens every wakeup comparator) | +32 int + 32 FP registers (~4 kbit raw, times the multi-port replication factor); likely the largest SMT2 cost on FPGA | Tullsen: 32 regs per thread plus a rename pool; POWER5 80 to 120 registers and 24% area mainly from resizing |
| 9 | ROB organization | Circular ROB with per-thread head/tail and base/limit registers (one thread with base 0 and limit N in v1); commit logic written as "per-thread commit lanes" | ~0 | Second pointer set + commit arbitration (round-robin, or one commit per thread per cycle) | Static ROB partition in Zen and Nehalem; Raasch shows equal static partition is fine |
| 10 | Age ordering in issue queues and LSQ | Age by allocation order (age matrix or per-entry age stamp), not by subtracting ROB indices, so cross-thread "oldest" stays defined with a partitioned ROB | Small if chosen in v1 (age matrix ~N^2 FFs, e.g. 256 FFs per 16-entry queue); expensive to retrofit | Per-thread oldest-first plus thread round-robin, or a global age matrix | HT: age-dependent algorithms became "much more complicated" |
| 11 | Per-thread occupancy limits | Occupancy counters on IQ, LQ, SQ, MSHRs and the free list exposed as "per-TID" with an optional cap register (cap = full size in v1) | ~0 (counters exist for full-detection anyway) | Second set of counters + compare | HT threshold policy for schedulers; prevents clogging/starvation |
| 12 | Branch tags and kill masks | Kill/flush bus carries a TID qualifier; branch-tag pool allocation written to allow a per-TID split | ~0 | Per-thread tag pools or TID qualification on every kill compare | Tullsen per-thread IQ flush |
| 13 | Flush taxonomy (most important) | Classify every flush source as thread-local: exceptions, interrupts, CSR side effects, FENCE.I, SFENCE.VMA, memory-ordering replays, debug entry, WFI. Implement "flush(TID)" rather than "flush all" | ~0 logic; design discipline | Nothing extra if done in v1; a major redesign if not | Tullsen per-thread flush/trap; Montecito flushes per switch |
| 14 | LSQ thread tags and store forwarding | TID in LQ/SQ entries; forwarding match = address and same TID; ordering-violation checks fed by both own stores and an "external store/invalidation" port | ~0 | 1 bit per entry + TID compare in the forward CAM (~tens of LUTs) | RVWMO: "no early inter-hart forwarding" |
| 15 | Sibling store as external event | Make the L1D write port (committed stores, AMOs, SCs) able to broadcast to the LQ snoop path and the reservation snoop, gated by TID ≠ own; the same path already exists for remote-core invalidations in the dual-core design | ~0 (gated off) | Snoop broadcast wiring; possibly an extra LQ compare port (moderate LUTs) | RVWMO coherence/MCA; dual-core coherence already needs it |
| 16 | Committed store buffer and FENCE | Per-TID "stores outstanding" counters; FENCE waits only on own TID; L1D write with M permission defined as the global-visibility point | ~0 | Second counter; buffer partition or TID tag | RVWMO; EH2's per-thread write buffer |
| 17 | LR/SC reservation | Reservation register array indexed by TID; reservation cleared on own SC, sibling store/AMO/SC, coherence invalidation, and (optionally) trap/`mret`; place a livelock hold-off timer next to it | ~0 | +1 reservation register (~60 FFs) + hold-off logic | A-extension SC failure rules and forward-progress guarantee; EH2 clearing rules |
| 18 | AMO execution and line locking | AMOs execute at L1D under a line lock that already blocks remote probes; make the lock also block sibling accesses (TID-agnostic) | ~0 | ~0 | Atomicity against the sibling |
| 19 | TLBs and page-table walker | TLB entry tag = {TID, ASID, (VMID), VPN}; "G" bit global only within its TID; SFENCE.VMA by a TID may over-flush; cached PMP/PMA results per TID; PTW requests tagged, at least one outstanding walk per thread | ~0 (TID width 0) | +1 bit per entry (16-32 L1 entries in FFs; L2 TLB in BRAM width slack), compare logic, second walker state machine optional | ASIDs hart-local and translation caches "appear private"; Zen tags TLBs; P8700 per-hart VTLB |
| 20 | Caches and coherence | L1D is one coherence agent serving all local threads; L2/interconnect built with a parameterized agent count (needed for dual-core anyway) so a Bulldozer-style second cluster or extra cores can attach; optional per-TID way-partition mask | Way mask: tens of LUTs; agent parameterization ~0 | Mask register per thread | HT shared cache +12%; Zen shared and tagged; Bulldozer L2 shared |
| 21 | CSR file banking | All ISA CSRs (M/S/U, PMP, `satp`, counters, Sstc `stimecmp`, Sscofpmf state) in TID-indexed banks; implementation-defined control CSRs may be per core; CSR access and serialization tagged with TID | ~0 if parameterized | Roughly 2-4k FFs per extra hart (full M+S CSRs incl. 16 PMP entries and 64-bit counters; estimate) | RISC-V per-hart privileged state; EH2 per-thread vs per-core CSRs |
| 22 | Interrupt and timer delivery | Interrupt inputs (MEIP/SEIP/MTIP/MSIP/SSIP) and WFI wake modeled per TID; WFI parks only that thread's fetch and releases its partitioned share | ~0 | Second set of pending/enable plumbing | EH2 separate timer/software-interrupt pins and delegated PIC; ACLINT per-hart |
| 23 | Spin-wait hints | Decode PAUSE (no-op or short stall in v1) and WRS.NTO/STO (WFI-like stall until reservation-set store or interrupt) | Trivial | Use as "deprioritize/stop this TID's fetch" | Zihintpause rationale; Zawrs |
| 24 | Performance counters | `mcycle`/`minstret`/`hpmcounter*` per TID; event wires carry TID; reserve SMT events (fetch slots lost to sibling, IQ-cap stalls, cross-thread conflicts) | ~0 | Second counter bank (64-bit counters are FF-heavy; consider a BRAM-backed counter bank) | Per-hart CSR model; needed for fetch-policy tuning |
| 25 | Debug | Debug halt/resume/step and the debug-mode flush per TID; debug module configured for a hart array | ~0 | Second set of debug state | EH2 per-thread debug; P8700 per-hart debug entry |
| 26 | Security knobs | Predictor-flush control and/or context-tagged BTB/RAS/indirect predictor (useful for Spectre mitigation in v1 too); fill and store buffers clearable on privilege change; per-core "SMT disable / single-thread mode" that gives one thread all partitioned entries | Small (tens to low hundreds of LUTs) | Thread-tag bits on predictor entries; mode logic | STIBP; MDS flushes; core scheduling; OpenBSD HT-off |
| 27 | Coarse-grained MT fallback (optional) | Make thread switch = flush(TID) + swap TID selector + fetch from the other PC. Resident second architectural context requires the PRF sizing from hook 8 (or a BRAM shadow plus a swap engine) | ~0 if hooks 7-13 exist | Mostly the PRF/RAT growth; plus an L2-miss-triggered switch FSM and a fairness timer | Montecito <2% area (ASIC); CUSTARD found block MT inferior on FPGA |
| 28 | CMT (Bulldozer-style) fallback (optional) | Clean, queue-decoupled interface between the front end (fetch/decode/predict) and the rename/back end, and between the integer back end and a shared FPU, so a second integer cluster could attach; the front end would need widening | ~0 (good modularity) | Large: second integer cluster + L1D + wider front end | Bulldozer shared front end became a bottleneck (Steamroller duplicated decoders) |

#### Overall assessment
- **v1 overhead.** If hooks 1-26 are implemented as parameterized structures with TID width 0, the v1 resource overhead should be well under 1% of core LUTs/FFs, with no added pipeline stages. Tullsen's single-thread penalty came from adding pipeline stages for a larger register file, so do not add stages in v1. The real v1 cost is design and verification effort: maybe 5-10% more design time for disciplined TID plumbing and per-thread flush semantics. This is my judgment, not a sourced figure.
- **SMT2 overhead.** The add-on is plausibly in the 10-20% range of core LUTs/FFs, dominated by PRF growth with multi-port replication, RAT/CSR depth doubling, and arbitration muxes. That is consistent with the 5-24% ASIC range (P4 <5%, 34K 14%, Godson-2 18.8%, Niagara ~20%, POWER5 24%), with FPGA multi-port storage pushing toward the upper end. Expected throughput gain is +20-40% (Section 1). Verify both numbers by synthesizing a TID-width-1 build early, even if it is never shipped.
- **Recommended path.**
  1. v1: single-thread OoO with the hooks above.
  2. Optional v1.5: coarse-grained switch-on-L2-miss MT, reusing the same hooks with the lowest added logic, to validate per-thread flush, CSR banking, TLB tagging and LR/SC snooping on real Linux.
  3. v2: SMT2 with a static ROB/LSQ partition, a threshold-shared IQ, ICOUNT-style fetch (one thread per fetch cycle is enough for a 2-wide front end), shared tagged TLBs and caches, and an SMT-off mode.
  
  Bulldozer-style CMT is not recommended for a 2-wide core because of the shared-front-end bottleneck and the cost of duplicating integer clusters and L1D.

### Gaps
- No measured FPGA (LUT/FF/BRAM/Fmax) cost for adding SMT to an OoO soft core was found. The per-hook costs above are first-principles estimates and should be validated by synthesizing a TID-width-1 configuration early.
- The exact UltraScale+ LUTRAM primitive trade-offs (32- vs 64-deep, read-port counts) behind the RAT/CSR depth-doubling estimate were not fetched from AMD UG574.
- How NaxRiscv's own internal structures (ROB, PRF port scheme) would accommodate thread tags was not examined here; it is covered by the NaxRiscv research notes in the same folder.
