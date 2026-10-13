# Cache Coherence, Shared-L2 Design and RISC-V Memory-Model Requirements for a Dual-Core (→4-Core) OoO RV64 SMP on the Kria KV260

*Notes compiled 2026-10-12. Main spec versions read in full text: RISC-V ISA manual snapshot release `riscv-isa-release-1b9ca13-2026-10-08` (combined unprivileged and privileged PDF); SiFive TileLink Specification v1.8.1 (27 Jan 2020); RISC-V SBI v3.0 (published 16 Jul 2025); AMD DS987 v1.2 (15 Mar 2022); AMD PG201 v3.4 (11 May 2022). The shared web-search budget ran out late in the session, so a few items are listed under Gaps instead of being verified: CHI state list, PS-DDR latency from the PL, URAM pipeline latency, and the XiangShan L2 design-doc chapter. Mechanisms are described in my own words. No source code is reproduced.*

---

## 1. Coherence protocols and open-source RISC-V multicore implementations: states, inclusion, snooping vs directory, reported cost and performance

### Takeaway
The open-source landscape splits into three groups:
- **Broadcast or snoop designs for 2–4 cores.** Examples: Culsans/ACE for CVA6, OpenC910's "centralized snoop buffer" CIU, and the Muntjac broadcaster.
- **A directory embedded in the tags of an inclusive shared L2.** Examples: rocket-chip InclusiveCache, the SpinalHDL coherent L2 used with VexiiRiscv/NaxRiscv, XiangShan CoupledL2's per-line client bits, and OpenPiton's L2.
- **A standalone duplicate-tag directory with a non-inclusive, memory-side L2.** Example: BlackParrot BedRock.

At 2 cores, the one published head-to-head is Culsans vs OpenPiton on Splash-3. It favours a tightly coupled design with few hops: +15.8% on average and up to +32.87%. However, that comparison mixes in cache-hierarchy differences (write-through L1 plus an extra L1.5 level in OpenPiton), so it is not a pure snooping-vs-directory result.

### Cited Findings

#### TileLink TL-C (SiFive spec v1.8.1, 27 Jan 2020)
- **Channels and operations.** TL-C adds three channels to the mandatory A (requests) and D (responses) channels: B (probes from slave to master), C (releases and probe acks) and E (grant acks). The transfer operations are Acquire (create a copy or permissions), Release (voluntary give-back or writeback) and Probe (forced downgrade). — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **Messages.** AcquireBlock/AcquirePerm, ProbeBlock/ProbePerm, ProbeAck/ProbeAckData, Grant/GrantData, GrantAck, Release/ReleaseData and ReleaseAck. Version 1.8.1 made textual corrections and improved the Deadlock Freedom chapter. — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **Permission tree.** Permissions form a per-address "coherence tree" whose node roles are None, Branch (read-only copy), Trunk (a copy on the path between the Tip and the root) and Tip. Only a Tip with no Branches may perform PutFull, PutPartial, Logical and Arithmetic accesses. The spec calls this inclusive TileLink coherence. — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **Channel priority.** Channel priority is strictly A < B < C < D < E, in increasing order, which guarantees deadlock freedom. The spec also says its rules make it clear which component is at fault if a system deadlocks. — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **No ordered delivery assumed.** TileLink does not assume point-to-point ordered delivery, and higher-priority messages must be able to bypass lower-priority ones. The slave (for example, the L2) is the serialization point. The spec lists these concurrency rules:
  - A master must not send an Acquire for a block while a Grant on it is pending.
  - A slave must not send a Grant while a ProbeAck is pending. After sending a Grant, it must not probe that block until GrantAck returns.
  - A master must not send a Release while a Grant is pending. After a Release, it may send no ProbeAcks, Acquires or further Releases for that block until ReleaseAck.
  - A slave must not Probe while a GrantAck is pending, and has at most one outstanding Probe per block per master.
  
  — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **Race handling.** A master must still process Probes while it has an outstanding Grant pending. A slave must put up-to-date data into a Grant for an upgrade unless it is certain that master was not probed since its Acquire. GrantAck exists because delivery is not ordered. If a voluntary Release crosses an Acquire from another master, the slave must accept the Release and any overtaken ProbeAcks, and may use the Release data to answer the Grant. — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **Multiple Acquires to one block.** A master may send a second Acquire for the same block, for example a write miss under a read miss, only with a distinct transaction ID. It must GrantAck the first Grant without waiting for the second. — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **Atomics in TL-UH.** The uncached heavyweight level adds atomic messages (ArithmeticData, LogicalData) and hints. These let atomics run at the slave, i.e. "far" atomics. — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **TL-C is not a complete protocol.** TL-C specifies channels and messages, not a full coherence policy, and does not require a directory. Its links are five-channel, i.e. "five-phase", whereas BedRock is a four-phase, four-network protocol. — [BP-BedRock dissertation, arXiv 2505.00962 (2025)](https://arxiv.org/abs/2505.00962)

#### rocket-chip / SiFive InclusiveCache (the shared L2 in Chipyard)
- **Directory in the tags.** It is an inclusive LLC with invalidation-based coherence and a complete coherence directory integrated into the tag storage. — [BP-BedRock dissertation (2025)](https://arxiv.org/abs/2505.00962)
- **Banking.** The cache is built from banks. Each bank has its own scheduler, MSHRs and directory. — [arXiv 2603.26054 (2026)](https://arxiv.org/pdf/2603.26054)
- **Chipyard default.** One bank, 512 KiB, 8-way. The number of ways and banks must be powers of two. — [Chipyard docs 1.14.0](https://chipyard.readthedocs.io/en/1.14.0/Customization/Memory-Hierarchy.html)
- **MSHR sizing rule (from the generator's parameter file).**
  - Each bank gets 2 dedicated MSHRs (for probe and release traffic) plus max(2, ceil(memory round-trip cycles / beats per block)). The minimum is 3 instead of 2 if the directory output is registered.
  - The default memory round trip is 40 L2 cycles, commented as "50 ns @ 800 MHz".
  - The secondary-miss queue is sized max(MSHRs, round-trip − MSHRs).
  - The put buffer allows one entry per round-trip cycle.
  - At least two sub-banks are required, for an inner read-modify-write concurrent with an outer Release and Grant.
  
  — [rocket-chip-inclusive-cache, Parameters.scala](https://github.com/chipsalliance/rocket-chip-inclusive-cache)
- **Commercial precedent.** SiFive's FU540 L2 controller "also acts as directory-based coherency manager". — [Linux DT binding](https://kernel.org/doc/Documentation/devicetree/bindings/riscv/sifive-l2-cache.txt)
- **Rocket L1D LR/SC.** The reservation window lasts up to 80 cycles, commented "worst case is 14 mispredicted branches + slop". The cache code notes the ISA requires 16-instruction LR/SC sequences to succeed. A 3-cycle back-off then briefly prevents re-acquiring the reservation. — [RocketCore.scala](https://github.com/chipsalliance/rocket-chip/blob/master/src/main/scala/rocket/RocketCore.scala), [HellaCache.scala](https://github.com/chipsalliance/rocket-chip/blob/master/src/main/scala/rocket/HellaCache.scala)

#### BlackParrot BedRock (paper arXiv 2211.06390, Nov 2022; dissertation arXiv 2505.00962, 2025)
- **Protocol family.** BedRock is a directory-based family built on MOESIF, with MI, MSI, MESI, MOSI, MOESI and MESIF variants. — [BedRock guide](https://github.com/black-parrot/black-parrot/blob/master/docs/bedrock_guide.md)
- **No transient states in L1.** The authors favour less protocol complexity over maximum concurrency, describing BedRock as "well suited for small- (4-core) to medium-scale (32-core)" systems. Cache controllers have no transient states: the directory serializes, allowing one transaction per "way group" (blocks mapping to the same set in any cache), with a pending bit per way group. The only silent transition is E→M. — [BedRock paper (ar5iv)](https://ar5iv.arxiv.org/html/2211.06390)
- **Directory structure.** The directory is a standalone, inclusive, duplicate-tag directory, segmented by cache type (I-cache, D-cache, accelerator). Its overhead is a constant 6.25%. There are four networks: Request and Response (cache to directory), Command (directory to cache) and Fill (cache-to-cache data). The protocol works over ordered or unordered networks. — [BedRock paper (ar5iv)](https://ar5iv.arxiv.org/html/2211.06390)
- **Non-inclusive L2.** In BP-BedRock the L2 is non-inclusive of the L1s and acts as a memory-side DRAM buffer. Each directory slice manages a slice of physical memory, using an address hash. — [BP-BedRock dissertation (2025)](https://arxiv.org/abs/2505.00962)
- **Two coherence engines.** One is a fixed FSM. The other is microcode-programmable, running a 125-instruction MOESIF program. Occupancy (C = cores, S = sharers):

  | Request | FSM | Microcode |
  |---|---|---|
  | Base | 7 + C/2 cycles | 8 + C/2 cycles |
  | Write to an S-state block | 8 + C/2 + 2S | 24 + C/2 + 2S |

  — [BedRock paper (ar5iv)](https://ar5iv.arxiv.org/html/2211.06390)
- **Request occupancy for 8 cores.** Roughly 27–36 cycles for reads and writes with no sharers, versus roughly 184–219 cycles for Stanford FLASH's MAGIC. These figures were extracted from a PDF table with garbled layout. — [BedRock paper, Table 10](https://arxiv.org/abs/2211.06390)
- **Microcode engine cost.** On an 8-core FPGA running Splash-3, the microcode engine is within 1% of the FSM on average (2.3% worst case). Its overhead relative to the FSM design:
  - ASIC: die area +4.08%, CCE +31.08%.
  - FPGA: logic LUTs +6.32% for the multicore, +7.08% per tile, +66.19% per CCE, plus one 18 Kib BRAM per CCE (+1.54%).
  
  — [BedRock paper (arXiv 2211.06390)](https://arxiv.org/abs/2211.06390)
- **FPGA and silicon setup.** 8 cores at 50 MHz on a VCU128, with 32 KiB L1I and L1D per tile and a 64 KiB L2 slice per tile. The paper's text says "512 MiB shared L2", which conflicts with 8 × 64 KiB = 512 KiB and is probably a typo. The design is silicon-validated in GF 12 nm and FPGA-validated on Xilinx Zynq and Virtex UltraScale+ HBM. — [BedRock paper](https://arxiv.org/abs/2211.06390)
- **Memory model.** BP-BedRock implements a sequentially consistent memory model, which is stronger than RVWMO. — [BP-BedRock dissertation](https://arxiv.org/abs/2505.00962)

#### OpenPiton P-Mesh / BYOC
- **Tile structure.** The design is a 2D-mesh tiled manycore. Each tile has a core, a private L1.5 and a slice of the distributed L2. The L1.5 originally converted the OpenSPARC T1's write-through L1 interface into a write-back one.
- **Coherence.** An invalidation-based MESI directory is integrated into the L2. The L2 is inclusive of both L1.5 and L1.
- **Networks and messaging.** Three physical NoCs provide point-to-point ordering, with 64-bit flits. Messaging takes four steps. Clean E and S blocks are evicted silently, and dirty writebacks get no ack.
- **Memory model.** TSO.

— [BP-BedRock dissertation §6.4.4 (2025)](https://arxiv.org/abs/2505.00962)
- **BYOC.** BYOC defines a Transaction-Response Interface (TRI). The BYOC private cache (BPC) corresponds to the L1.5 and the LLC to the L2. — [BP-BedRock dissertation](https://arxiv.org/abs/2505.00962), [P-Mesh slides, ICS 2020](https://ics2020.bsc.es/sites/default/files/uploaded/jbalkind-pmesh-final.pdf)
- **Ariane (CVA6) integration.** It adds a new write-through TRI interface, and LR/SC is handled in the L1.5. — [P-Mesh slides, ICS 2020](https://ics2020.bsc.es/sites/default/files/uploaded/jbalkind-pmesh-final.pdf)

#### Culsans (CVA6 snoop-based CCU; DSD/SEAA 2024 WiP; arXiv 2407.19895 v2, 12 Aug 2024)
- **Protocol and states.** MOESI over AMBA ACE. Each L1D line stores three flags (valid, shared, dirty) that encode the ACE states: UniqueDirty = M, SharedDirty = O, UniqueClean = E, SharedClean = S, Invalid = I. — [Culsans paper](https://arxiv.org/abs/2407.19895)
- **Scope.** The CCU snoops the AXI crossbar between 2–4 cores and the LLC. The LLC does not take part in coherence. The authors call distributed directories "overkill" for small embedded clusters. — [Culsans paper](https://arxiv.org/abs/2407.19895)
- **CCU flow.**
  - Requests are first split into coherent and non-coherent paths. Non-coherent requests bypass the controller.
  - Coherent requests are ordered round-robin by arrival and processed serially by one coherence controller.
  - Issuing snoop requests (AC) and processing snoop responses (CR) are decoupled and non-blocking.
  - Because ACE snoop channels have no transaction IDs, a FIFO tracks response order.
  - The first snooped core to respond supplies the data (CD), which is forwarded as an R burst. Snooped writebacks are buffered for the memory unit.
  - Only requests to the same line are serialized, using an associative "collision checker" table.
  
  — [Culsans paper](https://arxiv.org/abs/2407.19895)
- **L1D changes.**
  - A snoop controller was added with priority second only to the miss handler.
  - A controller that needs unique access must watch for a concurrent snoop read.
  - A snoop invalidation signal warns controllers that have operations in flight on that line.
  
  — [Culsans paper](https://arxiv.org/abs/2407.19895)
- **I-cache coherence.** It is an RTL option, needed for example by the Bao hypervisor. Otherwise it can be disabled to cut snoop traffic. — [Culsans paper](https://arxiv.org/abs/2407.19895)
- **Splash-3 results vs a dual-core OpenPiton+CVA6.**
  - Configurations: Culsans used 16 KB L1I, 16 KB write-back L1D and 128 KB L2. OpenPiton used 16 KB L1I, 8 KB write-through L1D, 8 KB L1.5 and 2×64 KB L2.
  - Speedups by benchmark:

    | Benchmark | Speedup |
    |---|---|
    | OCEAN | +32.87% |
    | BARNES | +29.65% |
    | CHOLESKY | +25.67% |
    | RADIOSITY | +24.81% |
    | FMM | +21.72% |
    | WATER-NSQ | +14.35% |
    | LU-NC | +12.97% |
    | WATER-SP | +6.50% |
    | LU-CONT | +6.26% |
    | FFT | 0.00% |
    | RADIX | −0.72% |

  - Average: +15.8%.
  - Area: the CCU is 1.6% of system area in GF 22 nm FDSOI and does not limit Fmax.
  
  — [Culsans paper](https://arxiv.org/abs/2407.19895)
- **Caveat from the authors.** CVA6's single-core write-back cache was slower than its write-through cache because of implementation bottlenecks, and CVA6 has limited support for outstanding transactions. — [Culsans paper](https://arxiv.org/abs/2407.19895)
- **Third-party view.** Culsans' snooping is limited to 4 cores. Its uplift over OpenPiton is "not surprising" because OpenPiton adds a cache level. — [BP-BedRock dissertation](https://arxiv.org/abs/2505.00962)
- **Repo.** The repo targets FPGA synthesis on the Genesys2 board and includes an integration test suite (CITS), sanity tests and regression tests. — [Culsans README](https://github.com/pulp-platform/culsans)

#### XiangShan CoupledL2 / HuanCun
- **Repo facts.** CoupledL2 is described as an "Open-source non-blocking L2 cache". Its default branch is kunminghu-v2, it pulls in HuanCun as a submodule, and it carries a TL-Test version file. — [CoupledL2 repo](https://github.com/OpenXiangShan/CoupledL2)
- **Per-line directory metadata.** Each line records:
  - a dirty bit and the TileLink state;
  - a client presence vector, one valid bit per client (a TODO notes that per-client states are not recorded);
  - alias bits for VIPT L1 aliasing;
  - prefetch flag and prefetch source;
  - an accessed bit;
  - ECC error flags.
  
  — [CoupledL2 Directory.scala](https://github.com/OpenXiangShan/CoupledL2/blob/master/src/main/scala/coupledL2/Directory.scala)
- **Default parameters.** 4 ways × 128 sets × 64 B, 16 MSHRs, DRRIP replacement and 32-byte TileLink beats. An optional CHI downstream interface exists (a tl2chi path and an enable-CHI switch). Product configurations override these defaults. — [CoupledL2 L2Param.scala](https://github.com/OpenXiangShan/CoupledL2/blob/master/src/main/scala/coupledL2/L2Param.scala)
- **Generations.** Yanqihu (1st), Nanhu (2nd) and Kunminghu (current, master branch). HuanCun is the "L2/L3 cache submodule". The project uses the difftest co-simulation framework. — [XiangShan README](https://github.com/OpenXiangShan/XiangShan)

#### OpenC910 / XuanTie C910 (closest open analogue: dual-core OoO RV64)
- **OpenC910 configuration.** 2 cores per cluster, a 12-stage OoO RV64GC pipeline, "MOESI coherency protocol" and a "2-way centralized snoop buffer".
- **Caches.** L1I: 64 KB, 2-way, VIPT. L1D: 64 KB, 2-way, PIPT. Lines are 64 B. The shared L2 is 1 MB, 16-way, PIPT, multi-bank with parallel access, and supports data prefetch.
- **Bus and TLB/I-cache maintenance.** The bus is an AXI4 128-bit master. The datasheet mentions "software and hardware collaborative" consistency between TLB, I-cache and D-cache.

— [OpenC910 datasheet](https://github.com/XUANTIE-RV/openc910/blob/main/doc/openc910_datasheet.pdf)
- **User manual (dated 2024-06-27; only the ASCII parts of the Chinese PDF were extractable).**
  - The L1D uses MESI, with states labelled like ACE's UniqueDirty and UniqueClean, while the L2 uses MOESI.
  - The CIU maintains L1 coherence and also handles TLB and I-cache maintenance.
  - A machine CSR bit (INSDE) makes I-cache misses snoop the D-cache.
  
  — [OpenC910 doc folder](https://github.com/XUANTIE-RV/openc910/tree/main/doc)
- **Commercial C910 as measured on the TH1520 (Chips and Cheese, 4 Feb 2025).**
  - Clusters have up to 4 cores. The CIU takes requests from up to four PIUs, is split into two "snb" instances each with a 24-entry request queue, arbitrates by age, and has a 512-bit path to L2.
  - L2: 1 MB, 16-way, FIFO replacement, 2 banks selected by physical-address bit 6, inclusive, ECC-protected, 60-cycle latency at 1.85 GHz.
  - L1D: 8 line-fill buffers.
  - DRAM latency: 133.9 ns.
  
  — [Chips and Cheese](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)

#### VexiiRiscv / NaxRiscv (SpinalHDL) and LiteX
- **L1 coherence model.** VexiiRiscv keeps L1 coherence "by permission" with MESI, bridgeable to TileLink. The L1 interface has:
  - acquire request, response and ack channels;
  - release request and response channels;
  - probe request and response channels (to-invalid, to-shared, to-unique).
  
  Unlike TileLink, probes may fail and be replayed, and data for a probe hit leaves through the writeback path. — [VexiiRiscv docs, Memory](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
- **AMOs (near atomics).** An AMO behaves like a load. If the line is missing or not unique it fails and retries. Once the line is unique, it is locked for a few cycles while the ALU updates it. The lock prevents any writeback, so together with the unique state no other agent can modify the block during the operation. — [VexiiRiscv docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
- **LR/SC.** LR needs the unique state and locks the line for 32 cycles. SC checks that the lock still holds. LR *toggles* the reservation rather than setting it, so a core spinning on LR cannot starve others. — [VexiiRiscv docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
- **Non-blocking L1D.** The number of refill and writeback slots is configurable (default 1 each). There is an optional store buffer and an RPT stride prefetcher.
- **LiteX measurements with the RPT prefetcher.** Setup: quad-core RV64GC at 200 MHz, 16 KB L1 per core, 512 KB shared L2 on a 128-bit bus, 4 refill and 4 writeback slots, plus a store queue. Results:
  - LiteX BIOS read: 204.2 → 790.9 MiB/s.
  - iperf3 RX: 617 → 766 Mbit/s.
  - Doom: 43.1 → 50.2 fps.
  
  — [VexiiRiscv docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
- **LiteX options.** LiteX can build dual-core RV64GC Debian SoCs with an L2 and a coherent-DMA option. — [VexiiRiscv LiteX doc](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Soc/litex.rst)
- **Author's opinion on TileLink vs AXI4.**
  - AXI4's same-ID ordering, read interleaving and separate AW/W channels add complexity to L2s and DRAM controllers. TileLink has no ordering between in-flight transactions.
  - He recommends 64-byte blocks everywhere and notes that CHI enforces 64-byte lines.
  
  — [VexiiRiscv docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
- **SpinalHDL coherent L2.** Each tag entry holds a valid bit, the tag, a dirty bit, a "trunk" (unique) flag and an owners bit-vector with one bit per coherent master. In other words, it is an inclusive L2 with a presence-bit directory in its tags. Defaults:
  - 8 "general slots" (MSHR-like), 2 of them reserved for upstream C-channel traffic;
  - 8 probe slots and 4 A-channel buffers;
  - a 2-line victim buffer;
  - 1 bank, with dual-port RAMs.
  
  A separate data-less "Hub" variant with sets/ways parameters also exists. — [SpinalHDL coherent Cache](https://github.com/SpinalHDL/SpinalHDL/blob/dev/lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Cache.scala), [Hub](https://github.com/SpinalHDL/SpinalHDL/blob/dev/lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Hub.scala)
- **NaxRiscv funding goal.** The NLnet-funded NaxRiscv work aimed to implement "memory coherency, multicore support and a L2 cache". — [NLnet](https://nlnet.nl/project/NaxRiscv/)
- **Chipyard.** In Chipyard, VexiiRiscv provides cache-coherent TileLink L1 D-caches. — [Chipyard docs](https://chipyard.readthedocs.io/en/main/Generators/VexiiRiscv.html)
- **Efinix Sapphire RV64.** The FPGA-vendor RISC-V SoC documentation describes the L2 as the "central coherency point (directory)". — [Efinix docs](https://www.efinixinc.com/docs-html/rv64-sapphire-ds/topics/riscv-sapphire-rv64-mcd.html)

#### Muntjac (lowRISC/Cambridge, OSCAR workshop, June 2022)
- **Coherence.** The D-cache speaks TL-C. A broadcaster keeps L1s coherent in simple designs, and a reference directory-based L2 (64 KiB, 4-way, TL-C on both sides) is provided.
- **Atomics.** An AMO ALU sits in the D-cache. Forward progress is ensured by locking lines for 16 cycles after a refill.
- **Single-core Kintex-7 results.** With FPU: 17,420 LUTs and 6,683 registers at 89 MHz. Without FPU: 9,902 LUTs at 97 MHz. Performance: 2.17 DMIPS/MHz and 3.01 CoreMark/MHz.

— [Muntjac, arXiv 2206.06769](https://arxiv.org/abs/2206.06769)

#### AMBA ACE / ACE-Lite / CHI and the Zynq UltraScale+ PS
- **ACE channels and states.** ACE adds the snoop channels AC (request), CR (response) and CD (data) to AXI. Its five line states map onto MOESI as listed in the Culsans entry above. — [Culsans paper](https://arxiv.org/abs/2407.19895)
- **SharedDirty transitions.** When another master issues a ReadShared to a UniqueDirty line, the snooped master can either move to SharedDirty (requester gets SharedClean) or pass the dirty data along (requester gets SharedDirty). Not all implementations handle SharedDirty. A write to a shared line uses CleanUnique to invalidate the other copies. — [Arm community forum](https://community.arm.com/support-forums/f/architectures-and-processors-forum/49242/some-question-about-ace)
- **Zynq UltraScale+ PS ports available to the PL.**

  | Port | Coherency | Widths | FIFO |
  |---|---|---|---|
  | HP0–3 | Non-coherent | 32/64/128-bit | AFI |
  | HPC0–1 | "I/O coherent with CCI", no L2 allocation | 32/64/128-bit | AFI |
  | ACP | I/O coherent with A53 L2 allocation ("legacy") | not stated | none |
  | ACE | Two-way coherent | not stated | none |
  | LPD | Non-coherent | 32/64/128-bit | AFI |

  — [AMD PG201 v3.4](https://docs.amd.com/r/3.4-English/pg201-zynq-ultrascale-plus-processing-system/Slave-Interface), [AMD UG1273 comparison table](https://docs.amd.com/r/2025.1-English/ug1273-versal-acap-design/AMBA-Specification-Interfaces)

### Inferences
- **Classification of the surveyed designs** (synthesized from the findings above):

  | Design | L1 states | Coherence mechanism | L2 inclusion | Scale |
  |---|---|---|---|---|
  | Culsans | MOESI (ACE) | Broadcast snoop through a central CCU; LLC outside the protocol | n/a (LLC not coherent) | 2–4 cores |
  | OpenC910 | MESI at L1, MOESI at L2 | Central snoop buffer in the CIU | Inclusive L2 (commercial C910) | 2 (open), 4 (commercial) |
  | rocket InclusiveCache, SpinalHDL coherent Cache, CoupledL2 | TL-C (MESI-like) | Presence-bit directory in the L2 tags | Inclusive (CoupledL2: client bits; inclusion policy not verified) | small to mid |
  | OpenPiton P-Mesh | MESI | Distributed directory in the L2 | Inclusive | manycore |
  | BedRock | MOESIF family | Standalone duplicate-tag directory | Non-inclusive, memory-side L2 | 4–32 cores |

- **What the Culsans numbers mean.** The +15.8% says more about removing an extra cache level and write-through traffic (OpenPiton's L1.5 path) than about snooping vs directory as such. The benchmarks with high memory-operation and stall ratios (OCEAN, LU-NC) gained most. FFT and RADIX gained nothing, because their stalls are compute-bound.
- **TileLink as an architectural template.** For a clean-room design, adopting the *public* TL-C message semantics and concurrency rules as the on-chip protocol is low-risk. The rules for GrantAck, ReleaseAck and the probe-while-acquiring cases are written down, deadlock freedom has been argued, and it maps naturally onto an L2 serialization point. Only the TileLink and AMBA specs and the papers should be relied on. The open RTL inspected here (rocket, SpinalHDL, XiangShan) was used only to extract parameter values for these notes.
- **Owned state: probably not worth it at L1.** With an on-chip inclusive L2, dirty sharing can be absorbed by the L2: on a downgrade the L2 takes ProbeAckData and keeps the line dirty. MESI at L1 plus a dirty bit at L2 (C910 style: L1 MESI, L2 MOESI) is simpler and costs little at 2–4 cores.

### Gaps
- **CHI.** I could not verify the CHI cache-state list (e.g., the unique-clean-empty and unique-dirty-partial states) or the CHI snoop-filter details from a primary source. The Arm documentation pages did not render, and the search budget was exhausted.
- **XiangShan.** CoupledL2's inclusion policy for L1I vs L1D and the real Kunminghu L2 sizing (slices, ways, capacity, prefetchers) are unverified. The design-doc L2 chapter URL I tried returned 404.
- **OpenC910 internals.** The Chinese text of the C910 user manual could not be extracted (missing GB1 character maps). The CIU snoop-buffer organization and the race handling are therefore unknown beyond the ASCII fragments.
- **FPGA resource numbers.** Culsans gives no FPGA LUT/FF or Fmax numbers. Its area figures are ASIC only.
- **LiteX L2 internals.** I did not establish which SpinalHDL module (the inclusive Cache or the data-less Hub) the LiteX VexiiRiscv/NaxRiscv integration uses by default, or its L2 hit latency or area.
- **IEEE 10361010.** The title and authors of the TileLink model-checking paper could not be retrieved; see Q4.

---

## 2. Best-fit coherence architecture for exactly 2 cores (expandable to 4) on a small FPGA

### Takeaway
The recommended design is an inclusive, banked, shared L2 that is the single serialization point, with a per-line presence vector plus a unique/dirty flag stored in its tag array. This is the pattern used by rocket InclusiveCache, the SpinalHDL coherent Cache and CoupledL2.
- **L1D:** write-back MESI (silent E→M).
- **Messaging:** TL-C-style transactions (Acquire/Grant/GrantAck, Release/ReleaseAck, Probe/ProbeAck).
- **Probes:** targeted using the presence bits, never broadcast.
- **Back-invalidation:** handled naturally on L2 eviction.

At 2–4 cores this costs 2–8 bits per L2 line. It avoids the probe-bandwidth problem of broadcast snooping with two OoO cores that each have many outstanding misses, and it scales to 4 cores without changing the protocol. Instruction-cache coherence can start with FENCE.I invalidation and later grow, through the same presence bits, into Ziccid-style coherent I-caches.

### Cited Findings
- **Directory vs snooping trade-offs reported by projects.**
  - The Culsans authors argue a distributed directory is "overkill" for 2–4-core clusters and built a snoop CCU instead. — [Culsans paper](https://arxiv.org/abs/2407.19895)
  - BedRock's authors argue the opposite trade-off for 4–32 cores and remove transient states through directory serialization. — [BedRock paper](https://ar5iv.arxiv.org/html/2211.06390)
  - Culsans' snooping is capped at 4 cores, whereas BP-BedRock scales to 16–32. — [BP-BedRock dissertation](https://arxiv.org/abs/2505.00962)
- **Directory-in-L2-tags implementations.**
  - InclusiveCache keeps a complete directory in its tags. — [BP-BedRock dissertation](https://arxiv.org/abs/2505.00962)
  - The SpinalHDL coherent Cache keeps an owners bit-vector and a trunk flag per line. — [SpinalHDL Cache.scala](https://github.com/SpinalHDL/SpinalHDL/blob/dev/lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Cache.scala)
  - CoupledL2 keeps a one-bit-per-client presence vector per line. — [CoupledL2 Directory.scala](https://github.com/OpenXiangShan/CoupledL2/blob/master/src/main/scala/coupledL2/Directory.scala)
- **Races the protocol must handle.** Each of these is spelled out in the TL-C rules:
  - probe arriving while the master's own Acquire is outstanding;
  - voluntary Release crossing a Probe (ProbeAck held until ReleaseAck);
  - Grant/Probe ordering closed by GrantAck;
  - write-upgrade under a read miss (distinct transaction IDs).
  
  — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **Serialization mechanisms in practice.**
  - Culsans uses an associative collision-checker table for same-line requests, and gives L1 snoop handling priority just below the miss handler. — [Culsans paper](https://arxiv.org/abs/2407.19895)
  - BedRock uses per-way-group pending bits plus speculative bits for speculative memory reads. — [BedRock paper](https://ar5iv.arxiv.org/html/2211.06390)
  - VexiiRiscv's L1 interface allows a probe to fail, after which it must be replayed. — [VexiiRiscv docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
- **OpenPiton's simplifications.** Silent eviction of clean lines and no acks for dirty writebacks both rely on NoCs with point-to-point ordering. — [BP-BedRock dissertation](https://arxiv.org/abs/2505.00962)
- **I-cache coherence options from the ISA manual.**
  - FENCE.I can be implemented by flushing the I-cache and fetch pipeline, by snooping the I-cache (or D-cache) on misses, or by using an inclusive unified private L2 that invalidates I-cache lines on local stores. If the I- and D-caches are kept coherent, only the fetch pipeline needs flushing.
  - Linux removed user-level FENCE.I in favour of a syscall.
  
  — [RISC-V ISA manual snapshot 2026-10-08](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Ziccid (version 1.0 in the 2026-10-08 manual snapshot).**
  - It requires that stores eventually become visible to *all* harts' instruction fetches without FENCE.I, and that fetches appear in program order. Its stated intent is to speed up JIT compilation on multiprocessors.
  - Keeping the I-caches coherent with the data side "suffices" for the eventuality property.
  - An instruction buffer filled out of program order (e.g., fetching down a predicted path after an I-cache miss) can break the in-order property. The fix is to buffer in order, or to make the coherent I-cache inclusive of the buffer.
  - Ziccid depends on Ziccif.
  
  — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **I-cache coherence in existing designs.** Culsans makes coherent I-fetch an RTL option. — [Culsans paper](https://arxiv.org/abs/2407.19895) C910 has a CSR bit that makes I-cache misses snoop the D-cache. — [OpenC910 doc](https://github.com/XUANTIE-RV/openc910/tree/main/doc)
- **Miss-handling resources in reference designs.**
  - Rocket InclusiveCache: 2 + max(2, ceil(round trip / beats)) MSHRs per bank. — [InclusiveCache](https://github.com/chipsalliance/rocket-chip-inclusive-cache)
  - CoupledL2: 16 MSHRs by default. — [CoupledL2 L2Param](https://github.com/OpenXiangShan/CoupledL2/blob/master/src/main/scala/coupledL2/L2Param.scala)
  - SpinalHDL L2: 8 general slots. — [SpinalHDL Cache.scala](https://github.com/SpinalHDL/SpinalHDL/blob/dev/lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Cache.scala)
  - C910 L1D: 8 line-fill buffers. C910 CIU: 2 × 24-entry request queues. — [Chips and Cheese](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
  - VexiiRiscv: L1D refill/writeback slots default to 1 each, and the quad-core performance tests used 4 + 4. — [VexiiRiscv docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
- **Multi-copy atomicity constrains the protocol and any future SMT.** Both RVWMO and RVTSO are "multi-copy atomic (or other-multi-copy-atomic)":
  - A hart may forward from its *own* store buffer.
  - A hart may not forward from a neighbouring hart's private store buffer (unless no new illegal behaviour becomes visible).
  - A coherence protocol may not forward a value from one hart to another until the protocol has invalidated all older copies held by other caches.
  
  — [RISC-V ISA manual snapshot, RVWMO explanatory appendix](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)

### Inferences
- **Proposed baseline protocol: 2 cores, scalable to 4.**
  1. **L1D.** Write-back, 64 B lines, MESI with silent E→M. Grant E when the L2 presence vector shows no other holder, which avoids an upgrade miss on private data.
  2. **L2 metadata per line.** Valid, tag, dirty, a "unique-holder" flag, and a presence vector of one bit per L1D, plus optionally one per L1I. That is 2 bits for 2 cores and 8 bits for 4 cores with separate I and D tracking.
  3. **No O state in the L1s.** On a read hit to a line held M by the other core, the L2 probes it "to Shared" and collects the data. The L2 copy becomes dirty and both L1s end in S.
  4. **One serialization point per bank.** The L2 MSHR address match blocks a second transaction to the same line until GrantAck. This is the TileLink rule and serves the same purpose as Culsans' collision checker and BedRock's pending bits.
  5. **L1 obligations.** The L1 answers probes even with its own Acquire outstanding, and holds a ProbeAck until the ReleaseAck for a crossing writeback. The L2 merges a crossing Release into the pending probe flow.
- **Why not broadcast for 2 OoO cores.** With 8 or more outstanding L1D misses per core plus prefetches, broadcast probes would steal L1 tag bandwidth from the other core's load pipeline on every miss. A presence vector filters almost all probes, because most lines are private. Culsans could accept broadcast partly because CVA6 has little memory-level parallelism, as its authors note. This is an inference; no paper quantifies it on FPGA.
- **Inclusion victims.** An inclusive L2 must back-invalidate L1 copies on eviction. Mitigations:
  - make the L2 at least 8× the total L1D capacity (e.g., 512 KiB L2 vs 2 × 32 KiB L1D);
  - make replacement presence-aware, preferring victims with an empty presence vector;
  - keep a small victim buffer (the SpinalHDL default is 2 lines).
- **Scaling to 4 cores.** The presence-vector width grows from 2 to 4 (or to 8 with I and D separated). The protocol does not change, the crossbar grows, and the L2 should go to 2–4 banks. Beyond about 8 cores, coarse vectors or a BedRock-style standalone directory become attractive. The dissertation shows such designs reaching 16–32 cores.
- **SMT/CMT hooks.** Track presence per physical L1, not per hart. Keep LR reservations per hart. Never forward store data between SMT threads' store-buffer entries before the store is globally visible, because multi-copy atomicity requires that. Probes or invalidations that hit a speculatively executed load of *any* thread on that core must trigger the same load-replay check (see Q3).
- **Instruction caches.**
  - *Phase 1:* the I-cache is not coherent and FENCE.I invalidates it. Linux then needs SBI remote FENCE.I for cross-hart code modification.
  - *Phase 2:* add an L1I presence bit at the L2 so stores invalidate stale I-cache lines (Ziccid). Keep the fetch buffer in program order, or make it covered by the coherent I-cache.

### Gaps
- No published FPGA measurement compares broadcast snooping with a presence-bit directory for exactly two OoO cores. The Culsans comparison mixes cache-hierarchy changes into the result.
- I found no published LUT/FF breakdown of InclusiveCache, the SpinalHDL coherent L2 or Culsans on UltraScale+ that would let the directory logic be costed separately from the data path.

---

## 3. RISC-V memory-model requirements a multicore OoO implementation must meet

### Takeaway
RVWMO is a weak but multi-copy-atomic model with 13 preserved-program-order rules and three axioms: Load Value, Atomicity and Progress. An OoO core with SWMR coherence (single writer, multiple readers) satisfies it if it:
- preserves same-address load-load order (replay on invalidation);
- never makes stores visible before commit;
- honours FENCE, aq/rl and dependency rules;
- implements constrained LR/SC loops with a livelock-free eventuality guarantee, typically by holding unique L1 permission for a bounded window;
- does not forward results of AMOs or SCs to younger loads early.

FENCE.I and SFENCE.VMA are local-only. Cross-hart instruction and TLB coherence go through IPIs or SBI RFENCE (optionally Svinval), and DMA coherence uses Zicbom and Svpbmt.

### Cited Findings
- **Preserved program order, conditions.** PPO applies when a precedes b in program order, both access regular main memory (not I/O), and any of the rules below holds. AMOs count as both loads and stores. — [RISC-V ISA manual snapshot 2026-10-08, RVWMO chapter](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **PPO rules.**
  - *Overlapping-address orderings (rules 1–3):*
    1. b is a store to an address that overlaps a.
    2. a and b are loads of the same byte with no store to it in between, and they return values written by different stores (same-address load-load ordering).
    3. a is an AMO or SC whose value a later load b returns.
  - *Explicit synchronization (rules 4–8):* a FENCE, an acquire annotation on a, a release annotation on b, two RCsc annotations, or an LR/SC pair.
  - *Syntactic dependencies (rules 9–11):* address, data, or control dependency (for stores only).
  - *Pipeline dependencies (rules 12–13).*
  
  — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Axioms.**
  - *Load Value:* a load returns the latest of the stores that precede it either in global memory order or in program order. This permits store-buffer forwarding.
  - *Atomicity:* no store from another hart may intervene between a paired LR and SC.
  - *Progress:* no memory operation may be preceded in global memory order by an infinite sequence of other operations.
  
  — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Multi-copy atomicity.** RVWMO and RVTSO are multi-copy atomic: own-store forwarding is allowed, but no early inter-hart forwarding. The appendix includes a "store buffer forwarding" litmus test whose weak outcome is permitted. — [RISC-V ISA manual snapshot, appendix](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Ztso (v1.0).** RVTSO makes every load acquire-RCpc, every store release-RCpc, and every AMO acquire- and release-RCsc. That makes all PPO rules except 4–7 redundant, and no memory operation may be reordered past an AMO. Vector memory instructions also follow RVTSO at instruction level. Binaries built for Ztso should be flagged so that non-Ztso platforms can refuse them. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **FENCE.TSO.** It orders loads before all later operations and stores before stores. Implementing it as FENCE RW,RW is correct. It is not optional: its encoding sits inside the standard FENCE encoding. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **FENCE.I (Zifencei 2.0).** It synchronizes stores and instruction fetch on the local hart only. In the Ziccid operational model, FENCE.I is defined as two sequential steps: make all older explicit accesses globally visible, then flush the instruction buffer. That is enough to provide pre-Ziccid FENCE.I semantics for cacheable, coherent regions. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Cross-hart code modification (with or without Ziccid).** To make a store visible to another hart's fetches immediately, software can execute FENCE W,O and then send an IPI asking the remote hart to execute FENCE.I. Alternatively, it can execute FENCE W,W and write a flag; on seeing the flag, the remote hart executes FENCE.I. In neither case does the remote hart need a data fence. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **SFENCE.VMA.** It orders the local hart's earlier visible stores before its later implicit page-table references, and invalidates local translation caches, scoped by rs1 (virtual address) and rs2 (ASID). It is local only. The manual describes TLB shootdown as: data fence, IPI, remote SFENCE.VMA in the handler, then signal completion. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Svinval.** It splits SFENCE.VMA into SFENCE.W.INVAL, then a batch of SINVAL.VMA, then SFENCE.INVAL.IR, so many invalidations can be batched behind a single ordering pair. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **SBI v3.0 RFENCE extension (EID "RFNC", replacing the legacy EIDs 0x05–0x07).** It provides remote FENCE.I, remote SFENCE.VMA (optionally with ASID), and the HFENCE variants, all addressed by hart mask. A range with start and size both 0, or size 2^XLEN−1, means the whole address space. — [SBI v3.0](https://github.com/riscv-non-isa/riscv-sbi-doc/releases/tag/v3.0)
- **Constrained LR/SC loops (Zalrsc).**
  - The loop is at most 16 instructions placed sequentially in memory.
  - Between LR and SC only base I/E (or compressed C/Zcb) instructions are allowed, excluding loads, stores, backward jumps, taken backward branches, JALR, FENCE and SYSTEM.
  - The retry code may branch backwards.
  - The SC must match the address and size of the latest LR.
  - The region must have the eventuality property.
  - The loop is limited to 64 contiguous bytes so that I-cache and TLB associativity are not over-constrained. Inner loads and stores are banned so that simple private-cache reservation tracking stays possible.
  
  — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Eventuality guarantee.** For a hart in a constrained loop, one of these must eventually happen:
  - the hart or another hart performs a successful SC to the reservation set;
  - another hart or device stores or performs an AMO to the reservation set;
  - the hart exits the loop;
  - the hart traps.
  
  The guarantee is livelock freedom, not starvation freedom (earlier spec versions required starvation freedom). Loads and LRs from other harts, "possibly within the same core", cannot impede progress indefinitely. Neither can evictions caused by another hart sharing a cache, nor misses from speculative execution. The spec adds that reservations are "typically" tracked independently of shared-cache evictions. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Reservation set rules.** The reservation set may be arbitrarily large. An SC must fail if a store from another hart to the set can be observed between the LR and the SC. Unconstrained LR/SC sequences may fail always. Za64rs requires reservation sets to be contiguous, naturally aligned and at most 64 bytes. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **CMOs and LR/SC.** A cache-block management or zero instruction from another hart to the reservation set counts as a progress event. This accommodates protocols that cannot tell CMO invalidations from store invalidations. A CMO may make a constrained loop fail periodically, but prefetch CMOs do not affect the guarantee. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **PMA levels for atomics.**
  - Reservability: RsrvNone, RsrvNonEventual or RsrvEventual; RsrvEventual is recommended for main memory.
  - AMOs: AMONone, AMOSwap, AMOLogical or AMOArithmetic, plus AMOCASW/D/Q levels for Zacas.
  - Profile extensions on coherent cacheable main memory: Ziccrse mandates RsrvEventual, Ziccamoa mandates AMOArithmetic, and Ziccamoc mandates AMOCASQ.
  
  — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Newer atomics-related extensions.** Zalasr (load-acquire and store-release instructions), Zacas (compare-and-swap), Zabha (byte and halfword AMOs) and Zawrs (wait-on-reservation-set) all appear at version 1.0. The manual notes that implementing a C++ seq_cst load as LR.aq can slow concurrent loads because of the LR/SC eventuality guarantee, and that Zalasr avoids this. — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **How open designs bound LR/SC forward progress.**
  - Rocket holds the reservation for up to 80 cycles, then backs off for 3. — [rocket-chip RocketCore.scala](https://github.com/chipsalliance/rocket-chip/blob/master/src/main/scala/rocket/RocketCore.scala)
  - VexiiRiscv locks the line for 32 cycles and toggles the reservation. — [VexiiRiscv docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
  - Muntjac locks lines for 16 cycles after a refill. — [Muntjac](https://arxiv.org/abs/2206.06769)
  - BedRock requests write permission at the LR and performs L1 atomics after a write-permission fill. "L2 atomics" first invalidate all L1 copies. — [BedRock paper](https://ar5iv.arxiv.org/html/2211.06390)
  - BedRock's canonical model runs atomics to uncacheable memory at the LLC/memory, and atomics to cacheable memory either there or in the cache controller. The cache needs write permission and then an uninterruptible read-modify-write. — [BP-BedRock dissertation](https://arxiv.org/abs/2505.00962)
- **Far-atomic building blocks.**
  - PULP's AXI adapters implement LR/SC reservations (encoded as AXI exclusive accesses) and all AMOs (encoded as AXI5 atomic transactions) in front of the memory slave, adhering to RVWMO. — [axi_riscv_atomics](https://github.com/pulp-platform/axi_riscv_atomics)
  - TileLink TL-UH carries Arithmetic and Logical atomics to the slave. — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)
- **Zicbom.**
  - CBO.INVAL deallocates all copies up to the point common to the non-coherent agents.
  - CBO.CLEAN writes back a copy modified since the last CMO, to the point common to all agents.
  - CBO.FLUSH is a clean followed by an invalidate.
  
  — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)
- **Svpbmt.**
  - The PTE bits 62–61 encode PMA = 0, NC = 1 (non-cacheable, idempotent, RVWMO) and IO = 2 (non-cacheable, non-idempotent, strongly ordered).
  - Mixing *cacheable and non-cacheable* aliases of the same location can lose coherence. The fix is FENCE IORW,IORW, then CBO.FLUSH of the location, then another fence (the specific fence after CBO.FLUSH was cut off in the extracted text).
  - Mixing NC and IO only weakens ordering. A FENCE IORW,IORW between such accesses suffices.
  
  — [RISC-V ISA manual snapshot](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-1b9ca13-2026-10-08)

### Inferences
- **OoO core checklist derived from the rules above.**
  1. **Same-address load-load order (rule 2).** Loads may execute out of order, but when a probe or invalidation (or an L1 eviction) hits a line that a performed-but-uncommitted load read, every younger load to that line must be replayed, unless the older loads to the same bytes are already ordered. This is the standard "load-queue snoop" mechanism, and it is also what enables an optional Ztso mode.
  2. **Stores drain only after commit** (rules 11 and 13). Drain in order or coalesce: RVWMO allows same-hart store-store reordering to different addresses, but FENCE W,W and release semantics require ordered drain at those points.
  3. **FENCE R/W→R/W.** Simplest is to stall younger memory operations until the store buffer drains. A faster option is to speculate past the fence and squash on a conflicting probe (TSO-style speculation).
  4. **No early forwarding from AMO or SC entries to younger loads** (rule 3). Execute AMOs, LR and SC non-speculatively at the head of the ROB, with aq/rl acting as one-sided fences.
  5. **LR/SC.** At the LR, acquire unique permission and then delay or NACK incoming probes for a bounded window: 16 instructions, no inner memory operations and few branches suggest that tens of cycles suffice (Rocket uses 80, VexiiRiscv 32, Muntjac 16). Use the reservation granule = 64 B line (Za64rs). Add back-off or toggling so that a spinning LR cannot monopolise the line.
  6. **AMOs.** Do near AMOs in the L1D with unique permission for cacheable memory. That is cheapest at 2–4 cores and needs no L2 ALU. Far atomics at the L2 (TL-UH-style Arithmetic and Logical) are optional, useful for uncached or IO regions and for highly contended counters.
- **TLB shootdown.** Make SFENCE.VMA cheap: flush the TLB and the page-walk cache, and keep the PTW reading through the coherent L1D/L2. Linux on SBI uses the RFENCE path (IPIs through M-mode), so IPI latency matters. Svinval is a cheap later addition that lets the kernel batch invalidations.
- **Ztso.** It is a plausible configurable mode for the OoO core: it reuses the load-replay logic plus in-order store drain. It cannot be the default, because non-Ztso binaries do not need it and it costs memory-level parallelism.
- **DMA coherence on the KV260.**
  - PL DMA masters, e.g. a PL Ethernet MAC, should attach to the RISC-V L2 as uncached clients with TL-UH-like puts and gets, so they are coherent automatically, like VexiiRiscv's coherent-DMA option.
  - PS-side masters that reach DDR directly (A53 Linux, PS DMA/USB/SD) are *not* coherent with the soft L2 when using HP ports. Shared buffers then need Zicbom maintenance down to DDR, which includes the L2, or NC (Svpbmt) mappings.

### Gaps
- The extracted spec text did not include the final fence of the Svpbmt cacheability-change sequence. It should be checked in the HTML manual.
- I did not verify the status of Linux kernel support for Ztso binaries, Zicbom-based non-coherent DMA on RISC-V, or Svinval as of 2026-10.
- I did not check whether Ziccid is formally ratified, as opposed to merely listed at v1.0 in the development snapshot.

---

## 4. Verification methods and what open-source projects actually used

### Takeaway
Use layered verification:
- **Protocol level:** model-check the protocol (Murphi-family tools, used by BedRock for MESI; TL-C has also been model-checked in the literature).
- **RTL fuzzing:** random-traffic generators with per-channel protocol assertions and coverage (Muntjac, Culsans CITS, XiangShan TL-Test).
- **Consistency oracle:** trace-based consistency checking (axe, used by Rocket Chip, BERI and a BlackParrot fork).
- **Litmus tests:** the litmus-tests-riscv suite of 7,000+ tests, checked against herd/rmem model results on simulation and on the FPGA.
- **System tests:** booting SMP Linux and running Splash-3/PARSEC.

### Cited Findings
- **The litmus-tests-riscv suite.**
  - More than 7,000 litmus tests, used by the RISC-V Memory Model Task Group. — [RVWMO explanatory appendix (docs.riscv.org)](https://docs.riscv.org/reference/isa/unpriv/mm-eplan.html)
  - Most were generated with diy; they run in herd (axiomatic) and rmem (operational) models and on hardware via the litmus tool. The repo includes a Makefile for hardware runs, stored model results, and a pointer to the herd RISC-V cat model. The tests were produced by Shaked Flur and Luc Maranget. — [litmus-tests-riscv README](https://github.com/litmus-tests/litmus-tests-riscv)
- **What the postconditions mean.** Litmus postconditions mark weak behaviours that may or may not be allowed. They are not the specification. — [RVWMO explanatory appendix](https://docs.riscv.org/reference/isa/unpriv/mm-eplan.html)
- **axe.**
  - A black-box checker: given a trace of memory requests and responses, it decides whether the trace is valid under a chosen consistency model, and is designed to be the oracle of an automated test framework.
  - It has been used with Rocket Chip (traces from the RTL groundtest framework) and with Cambridge BERI (BlueCheck testbench), and found serious bugs.
  
  — [axe README](https://github.com/CTSRD-CHERI/axe), [FMCAD 2016 paper](https://www.cl.cam.ac.uk/~swm11/research/papers/fmcad2016-coherency-checker.pdf)
- **Why non-blocking caches need an oracle.** A TSO-forbidden pattern still appeared on Rocket Chip because its L1 cache is non-blocking, which motivated checking against models weaker than TSO. — [FMCAD 2016 slides](https://fmcad.forsyte.at/FMCAD16/slides/s7t4.pdf)
- **BlackParrot.** BlackParrot maintains an axe fork. — [black-parrot/axe](https://github.com/black-parrot/axe)
- **Protocol model checking in projects.**
  - BedRock's MESI protocol was verified with CMurphi for eight caches and one directory, a single block and unordered networks. Hardware was validated by booting Linux and running Splash-3 on the FPGA. — [BedRock paper](https://ar5iv.arxiv.org/html/2211.06390)
  - An IEEE paper models SiFive's TL-C specification for both inclusive and non-inclusive policies (title and authors not retrieved). — [IEEE Xplore 10361010](https://ieeexplore.ieee.org/document/10361010)
- **Muntjac.** riscv-tests; riscv-dv random instruction generation; booting Debian and running PARSEC; and, for the TileLink IP, an assertion suite, functional coverpoints and a custom random traffic generator. No formal methods or litmus tests are mentioned. — [Muntjac](https://arxiv.org/abs/2206.06769)
- **Culsans.** A two-layer integration test suite (CITS), sanity and regression tests, and Linux images on Genesys2. — [Culsans README](https://github.com/pulp-platform/culsans)
- **XiangShan.** It uses difftest co-simulation, and CoupledL2 carries a TL-Test version pin. — [XiangShan README](https://github.com/OpenXiangShan/XiangShan), [CoupledL2 repo](https://github.com/OpenXiangShan/CoupledL2)
- **TileLink deadlock rules.** Should a system deadlock, the rules make it clear which component is faulty. This is useful for writing per-agent assertions. — [TileLink 1.8.1](https://sifive.cdn.prismic.io/sifive/7bef6f5c-ed3a-4712-866a-1a2e0c6b7b13_tilelink_spec_1.8.1.pdf)

### Inferences
- **Recommended stack for this project, given a clean-room RTL.**
  1. **Protocol model first.** Write a Murphi/Rumur (or TLA+) model of the L1/L2 protocol for 2 caches, extended to 3–4, with 1–2 addresses, an unordered network and crossing Release/Probe. This mirrors BedRock's approach, and the TL-C rules give the invariants to check.
  2. **Agent-level assertions** on every channel: the TL-C "must not issue X while Y is pending" rules, credit and ID uniqueness, and SWMR checks against a shadow directory.
  3. **Random traffic generator plus reference memory model** at the L2 boundary, i.e. two or more fake L1 agents issuing Acquires, Releases and probes with random delays. Then swap in the real L1s.
  4. **Whole-SoC trace capture with axe** (WMO/TSO models) under random multi-threaded programs.
  5. **litmus-tests-riscv on the KV260 build**, with results compared against the stored herd/rmem allowed sets. Forbidden outcomes must never appear, and seeing *allowed* weak outcomes shows that the OoO machinery is actually stressed.
  6. **System tests:** SMP Linux boot, LTP/stress-ng, Splash-3/PARSEC. Hammer constrained LR/SC loops from both harts with interfering stores to test forward progress.

### Gaps
- I could not retrieve the title, authors, tool or bugs found for the IEEE TileLink model-checking paper.
- I did not verify whether rocket-chip's own TileLink fuzzer and RAM-model checker are still maintained, or whether the herd7 RISC-V model in herdtools7 matches the 2026 manual.
- I found no published evidence that Culsans, VexiiRiscv or OpenC910 were run against litmus-tests-riscv on hardware.

---

## 5. FPGA-friendly shared L2 on the XCK26 and its connection to the Zynq UltraScale+ PS DDR

### Takeaway
The XCK26 has 64 UltraRAMs (288 Kb each, 72-bit wide with ECC) and 144 BRAM36s. Two sizes fit comfortably:
- a **512 KiB** shared L2 (16 URAMs for data, about 7–8 BRAM36s for tags and directory), or
- a **1 MiB** L2 (32 URAMs).

Recommended structure: 2 line-interleaved banks with 8–12 MSHRs per bank, sized to cover the PL→DDR round trip, plus an L1D stride prefetcher. Refill and writeback go through one non-coherent 128-bit HP port per bank. Use HPC, ACP or ACE only if the soft cores must share cached data coherently with the A53 cluster. The PS memory is 4 GB of 64-bit DDR4 at 2400 Mb/s, about 19.2 GB/s peak.

### Cited Findings
- **XCK26 programmable-logic resources (DS987 v1.2, 15 Mar 2022).**

  | Resource | Count |
  |---|---|
  | System logic cells | 256,200 |
  | CLB LUTs | 117,120 |
  | CLB flip-flops | 234,240 |
  | Distributed RAM | 3.5 Mb |
  | 36 Kb block RAMs | 144 (5.1 Mb) |
  | UltraRAM blocks (288 Kb dual-port, 72-bit wide, with error correction) | 64 |
  | DSP slices | 1,248 |

  — [K26 SOM data sheet DS987 v1.2 (mirror)](https://www.sundance.com/wp-content/uploads/docs/k26-som-Data-Sheet.pdf)
- **SOM memory.** "4 GB 64-bit wide, 2400 Mb/s" DDR4. — [DS987 v1.2](https://www.sundance.com/wp-content/uploads/docs/k26-som-Data-Sheet.pdf)
- **PS block diagram.** It shows S_AXI_HPC0/1_FPD, S_AXI_HP0–3_FPD, S_AXI_ACP_FPD, S_AXI_ACE_FPD and S_AXI_LPD as PL-to-PS ports. — [DS987 v1.2](https://www.sundance.com/wp-content/uploads/docs/k26-som-Data-Sheet.pdf)
- **Port coherency classes.** HP0–3 are non-coherent and 32/64/128-bit. HPC0–1 are I/O coherent with the CCI and do not allocate in the A53 L2. ACP is I/O coherent with L2 allocation. ACE is two-way coherent. — [PG201 v3.4](https://docs.amd.com/r/3.4-English/pg201-zynq-ultrascale-plus-processing-system/Slave-Interface)
- **HP-port tuning.** For HP-port traffic shaping, AMD recommends a 128-bit AXI width and burst length 16 for best performance. QoS and the number of outstanding transactions per port are the main controls when PL masters compete with the PS for DDR. — [AMD wiki: Traffic Shaping of HP Ports](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/688128001/Traffic+Shaping+of+HP+Ports+on+Zynq+UltraScale)
- **Coherency default.** As of tool release 2017.4, Zynq UltraScale+ defaulted to software-managed coherency, so hardware coherency for HPC must be enabled explicitly. — [AMD wiki: Zynq UltraScale+ MPSoC Cache Coherency](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18842098/Zynq+UltraScale+MPSoC+Cache+Coherency)
- **Reference FPGA L2 configuration.** VexiiRiscv on LiteX: quad-core at 200 MHz with a 512 KB shared L2 on a 128-bit bus. The RPT prefetcher raised BIOS read bandwidth from 204 to 791 MiB/s. The author advises 64-byte blocks throughout, matching DDR3/4/5 native bursts, and says DMA should not reuse IDs or assume ordering between in-flight transactions. — [VexiiRiscv docs](https://github.com/SpinalHDL/VexiiRiscv-RTD/blob/master/source/VexiiRiscv/Memory/index.rst)
- **Reference ASIC L2 (C910 on TH1520).** 1 MB, 16-way, 2 banks interleaved on PA bit 6, inclusive, ECC, 60 cycles at 1.85 GHz. One core reads just over 10 GB/s, and four cores read 12.6 GB/s. — [Chips and Cheese](https://chipsandcheese.com/p/alibabat-heads-xuantie-c910)
- **MSHR and buffer sizing rules.** These are given under Q1 and Q2: InclusiveCache's round-trip formula (default 40 cycles), CoupledL2's 16 MSHRs and DRRIP, and the SpinalHDL L2's 8 slots, 8 probe slots and 2-line victim buffer. — [InclusiveCache](https://github.com/chipsalliance/rocket-chip-inclusive-cache), [CoupledL2 L2Param](https://github.com/OpenXiangShan/CoupledL2/blob/master/src/main/scala/coupledL2/L2Param.scala), [SpinalHDL Cache](https://github.com/SpinalHDL/SpinalHDL/blob/dev/lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Cache.scala)
- **L2 prefetch in references.** The C910 L2 supports data prefetch. — [OpenC910 datasheet](https://github.com/XUANTIE-RV/openc910/blob/main/doc/openc910_datasheet.pdf) CoupledL2 carries prefetch-source metadata per line and a configurable prefetcher list. — [CoupledL2 Directory/L2Param](https://github.com/OpenXiangShan/CoupledL2/blob/master/src/main/scala/coupledL2/L2Param.scala)

### Inferences
- **URAM arithmetic.** 288 Kb = 4,096 × 72 bits. Using 64 data bits per row (the other 8 for ECC) gives 32 KiB of protected data per URAM, so the 64 URAMs hold at most 2 MiB.
  - **512 KiB:** 16 URAMs. Four URAMs side by side give a 256-bit (32 B) row, so a 64 B line takes 2 beats. Two banks of 8 URAMs (4 wide × 2 deep) give 256 KiB each, interleaved on PA bit 6, the same scheme as C910.
  - **1 MiB:** 32 URAMs (half the device's URAM). This leaves URAM free for a large L1D or BTB/TAGE tables only if those use BRAM.
- **Tag and directory arithmetic.** For 512 KiB, 8-way, 64 B lines: 8,192 lines in 1,024 sets. Assuming a 40-bit PA:
  - per way: 24-bit tag + valid + dirty + unique + 2–8 presence bits, about 29–35 bits;
  - per set: about 240–290 bits including PLRU;
  - storage: about 7–8 BRAM36s in 1K×36 or 512×72 mode (around 5% of the 144).
  
  For 1 MiB, 16-way, the tags take about 13–16 BRAM36s. The tags stay in BRAM (wide, low latency, parallel way compare) and the data in URAM.
- **Pipeline and latency estimate (not measured).**
  - The tag read (1 BRAM cycle plus compare) can overlap or precede a 2–3-cycle registered URAM read.
  - ECC correction is optional: URAM's built-in ECC adds a stage if enabled.
  - Add crossbar or arbitration (1–2 cycles) and return to the L1.
  - A sequential tag-then-data L2 hit of about 8–12 cycles at a 200–250 MHz L2 clock is plausible. Reading tags and data in parallel saves 1–2 cycles but costs reading all ways of URAM data, which is impractical. Prefer sequential tag-then-data with way prediction off.
- **MSHRs per bank (InclusiveCache rule applied).** 2 + ceil(R / 4) for a 128-bit port, i.e. 4 beats per 64 B line, where R is the L2-clock round trip to PS DDR. For example, R = 40 cycles gives 12 MSHRs per bank and R = 24 cycles gives 8. The real R must be measured (see Gaps). Two OoO cores with 8–16 L1 MSHRs each plus prefetches justify about 16–24 L2 MSHRs in total across 2 banks.
- **Bandwidth.**
  - One 128-bit HP port at 250 MHz carries 4 GB/s (3.2 GB/s at 200 MHz).
  - Two HP ports, one per L2 bank, reach 6.4–8 GB/s, still below the 19.2 GB/s DDR4-2400 x64 peak that is shared with the A53 Linux.
  - Use BL16 at 128-bit (= 256 B bursts) only for prefetch streams, and keep demand misses at 64 B (BL4) for latency.
  - Set HP QoS so the soft cores are not starved by the PS.
- **Port choice.**
  - **Plain HP:** the soft cores own their coherence domain, with the RISC-V L2 as the point of coherence. Reserve a DDR region for the RISC-V Linux.
  - **HPC:** only if the soft L2 must snoop-safely share buffers with the A53 caches. It adds CCI latency and does not help soft-core-to-soft-core coherence.
  - **ACE:** would let the soft L2 be a full ACE master in the A53 domain, a large complexity cost that is not needed for an isolated RISC-V SMP.
- **Prefetching to help beat NaxRiscv IPC.** Begin with an L1D stride (RPT-style) prefetcher, given VexiiRiscv's measured 3.9× bandwidth gain on sequential reads. Add an L2 next-line or stream prefetcher that trains on L2 misses and has its own MSHR quota (e.g., 25% of slots) so it cannot starve demand misses. Mark prefetched lines (as CoupledL2 does with its prefetch bit) to measure accuracy and throttle.
- **Clock domains.** Running the L2 and cores on one clock and the HP ports through the PS AFI FIFOs avoids an extra asynchronous crossing in the soft logic, because the HP ports themselves accept a PL clock. This depends on PS port clock limits that I did not verify.

### Gaps
- I found no published measurement of idle PL→PS-DDR read latency through HP or HPC ports on Zynq UltraScale+. It should be measured on the KV260, e.g. with a bare-metal AXI timer read loop, before fixing MSHR counts.
- I did not verify URAM read latency at the target Fmax, with and without output registers, ECC and cascade (UG573 was not retrieved), nor the maximum PL-side clock for HP/HPC ports (UG1085 was not retrieved).
- I did not verify the DDR4 speed the KV260 platform actually configures. DS987 states 2400 Mb/s for the SOM memory.
- I found no source quantifying the L2-hit-latency vs IPC sensitivity for NaxRiscv/VexiiRiscv-class cores on FPGA. That is needed to justify the 512 KiB vs 1 MiB choice beyond resource fit.
