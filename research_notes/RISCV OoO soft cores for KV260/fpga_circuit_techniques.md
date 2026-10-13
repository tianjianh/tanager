# FPGA circuit-level techniques for out-of-order core building blocks (AMD/Xilinx UltraScale+, Kria KV260 / XCK26)

Conventions used below: every measured number carries its device, speed grade and tool where the source gives them. "Inferences" holds my own estimates and recommendations, derived from the cited primitive costs; these are not measurements. Search-engine budget ran out partway through the task, so several original papers (Seznec MICRO'02, Goshima MICRO'01, Sassone ISCA'07, Store Sets, SVW, NoSQ, FPnew, HardFloat) are described through FPGA papers that implement or summarize them. See the Gaps sections.

## 1. Multiported register files / RAMs (replication, banking, LVT, XOR, I-LVT, write specialization, clustering, UltraScale+ LUTRAM primitives) and the realistic cost of a 96–128 x 64-bit PRF with 6–8R / 3–4W

### Takeaway
On UltraScale+, extra read ports are cheap because the octal-port LUTRAM primitives give 1 write port plus 7 independent read ports per SLICEM. Every extra write port, though, replicates the whole storage. For a 96–128-entry x 64-bit PRF with 6–8 read and 3–4 write ports, rename-assisted write specialization (one LUTRAM bank per write port, no LVT) costs about 1.2–3K LUTs. A LUTRAM Live-Value-Table design costs about 3.3–7.7K LUTs and keeps full flexibility. Flip-flop, XOR-on-LUTRAM, BRAM-LVT/XOR and multipumped designs are all worse at this size (my estimates; table in Inferences).

### Cited Findings
**Platform baseline (applies to all sections)**
- The KV260's K26 SOM uses the XCK26-SFVC784-2LV, which has a -2 speed grade and is an LV device running at VCCINT = 0.72 V. It has 117,120 CLB LUTs, 234,240 CLB FFs, 3.5 Mb of distributed RAM, 144 x 36 Kb block RAMs (5.1 Mb), 64 UltraRAM blocks (288 Kb, 72-bit wide, with ECC) and 1,248 DSP slices (27x18 signed multiplier with a 48-bit adder/accumulator) — [K26 SOM data sheet DS987 v1.2](https://www.sundance.com/wp-content/uploads/docs/k26-som-Data-Sheet.pdf)
- BRAM timing, Zynq UltraScale+, 0.72 V, -2 column (the KV260 grade): Fmax is 585 MHz in WRITE_FIRST/NO_CHANGE and 510 MHz in READ_FIRST (also 510 MHz for ECC without pipeline). Clock-to-out is 1.46 ns without the output register and 0.42 ns with it. For comparison, -2 at 0.85 V gives 738/637 MHz and -1 at 0.72 V gives 516/460 MHz — [DS925 Block RAM switching](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Block-RAM-and-FIFO-Switching-Characteristics)

**UltraScale+ distributed-RAM (LUTRAM) primitives**
- A SLICEM has 8 LUTs and holds up to 512 bits of distributed RAM. Writes are synchronous and reads are asynchronous (a same-slice FF can register them). All LUTRAMs in a SLICEM share one write address, driven from the H-LUT inputs, and the write clock comes from a dedicated SLICEM input (LCLK) — [UG574 Distributed RAM](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Distributed-RAM-SLICEM-Only)
- UG574 lists these SLICEM configurations: single-port 32x1–16, dual-port 32x1–8, quad-port 32x1–4, simple-dual-port 32x1–14; single-port 64x1–8, dual-port 64x1–4, quad-port 64x1–2, octal-port 64x1 (8 LUTs, one per read port), simple-dual-port 64x1–7 (1 write + 7 read); single-port 128x1–4, dual-port 128x2, quad-port 128x1; single-port 256x1–2, dual-port 256x1; single-port 512x1 — [UG574 Distributed RAM](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Distributed-RAM-SLICEM-Only)
- RAM32M16 is 32 deep with eight 2-bit ports (A–H). It has one write port addressed by ADDRH. Ports A–G are 7 independent read-only 2-bit ports with their own 5-bit addresses, and port H reads at the write address. Reads are asynchronous, and the primitive maps to eight LUT6s in a single CLB — [UG974 RAM32M16](https://docs.amd.com/r/en-US/ug974-vivado-ultrascale-libraries/RAM32M16)
- RAM64M8 is 64 deep x 1 bit per port. It has one 8-bit write port, seven independent 1-bit read ports plus the port at the write address, asynchronous reads, and fits in one CLB — [UG974 RAM64M8](https://docs.amd.com/r/en-US/ug974-vivado-ultrascale-libraries/RAM64M8) (as summarized in search results)
- Per the UG974 template comments, RAM64X1D (64x1 dual-port) maps to two LUT6s, RAM128X1S to two and RAM256X1S to four — [UG974 RAM64X1D](https://docs.amd.com/r/2025.2-English/ug974-vivado-ultrascale-libraries/RAM64X1D); [UG974 RAM128X1S](https://docs.amd.com/r/en-US/ug974-vivado-ultrascale-libraries/RAM128X1S); [UG974 RAM256X1S](https://docs.amd.com/r/en-US/ug974-vivado-ultrascale-libraries/RAM256X1S) (template notes as summarized in search results)
- The CLB wide muxes (F7MUX x4, F8MUX x2, F9MUX x1) let one CLB build eight 4:1 muxes (one LUT each), four 8:1 (two LUTs each), two 16:1 (four LUTs each) or one 32:1 (eight LUTs) — [UG574 Multiplexers](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Multiplexers)

**Conventional techniques and the LVT and XOR designs (LaForest & Steffan; LaForest et al.)**
- **Replication** adds read ports but supports only one shared write port. **Banking** adds ports, but each port reaches only its own bank. **Multipumping** clocks the memory internally at a multiple of the external clock, and external Fmax degrades quickly as ports are added — [LaForest et al., TRETS 2014](https://people.csail.mit.edu/ml/pubs/trets_multiport.pdf)
- **LVT:** each write port owns a bank, and each bank is replicated once per read port, so the design needs m x n BRAMs for mW/nR. A narrow table of log2(m) bits per entry, built in logic with all m write and n read ports, steers each read port's output mux to the most recently written bank. The LVT plus the output muxes form the critical path, and both grow with depth. Adding forwarding around the BRAMs raised usable Stratix IV M9K Fmax from 375 to 550 MHz — [TRETS 2014](https://people.csail.mit.edu/ml/pubs/trets_multiport.pdf)
- **XOR:** the design needs m(m−1+n) BRAMs. Each write XORs the new data with the old contents at that address in the other m−1 banks, and a read XORs the values from all banks. Because every write must first read, writes internally take two cycles. The design hides this with registered write address/data and forwarding — [TRETS 2014](https://people.csail.mit.edu/ml/pubs/trets_multiport.pdf); original: [LaForest et al., FPGA 2012](https://people.csail.mit.edu/ml/pubs/fpga12_xor.pdf)
- Altera results (Stratix IV EP4SE530H40C2, fastest grade; Quartus 12.0; 32-bit wide; 2W/4R, 4W/8R and 8W/16R; depths 2–8192; mean of 10 seeds):
  - Pure-logic designs have the best Fmax below 64 entries.
  - For 2W/4R up to 128 entries, LVT has better Fmax and area than XOR. XOR wins beyond 256 entries: at 8192 entries the 2W/4R XOR design is 51% of the LVT area but uses 25% more BRAMs.
  - LVT always uses the fewest BRAMs.
  - Going from 2W/4R to 4W/8R quadruples the resources.
  - [TRETS 2014](https://people.csail.mit.edu/ml/pubs/trets_multiport.pdf)
- Xilinx results (Virtex-6 XC6VHX380T, fastest grade; ISE 14.1; read-first BRAM limited to 525 MHz):
  - For 2W/4R, the delay-optimal design changes from pure-logic to LVT at depth 32 and from LVT to XOR at 1024.
  - For 4W/8R, the crossovers are 16 and 512.
  - For 8W/16R, LVT gives way to XOR at 256.
  - On Xilinx, XOR almost always uses the fewest slices, and LVT always the fewest BRAMs.
  - [TRETS 2014](https://people.csail.mit.edu/ml/pubs/trets_multiport.pdf)
- The original LVT paper reports a 256-location, 32-bit, 12-port memory at 281 MHz on Stratix III, about 43% faster than a pure-logic version — [LaForest & Steffan, FPGA 2010](https://www.eecg.utoronto.ca/~steffan/papers/laforest_fpga10.pdf) (abstract-level claim from search results; full text not re-read)

**Invalidation-based LVT (Abdelhadi & Lemieux)**
- The I-LVT moves the LVT itself into SRAM/BRAM. On each write it reads the bank IDs stored in the other banks (feedback), embeds the new writer's ID, and rewrites only its own bank. A read then reads all banks and recovers the latest writer's ID. Two encodings exist: binary, which embeds the ID with XOR, and one-hot ("thermometer"), which uses mutually exclusive invalidation and has a shorter feedback path. The design needs bypassing for read-after-write — [Abdelhadi & Lemieux, FPGA 2014](https://people.ece.ubc.ca/lemieux/publications/abdelhadi-fpga2014.pdf)
- Results on Stratix V 5SGXMA5N1F45C1 (Quartus II; 2–4 write ports, 3–6 read ports, 16K–32K lines, 8–32-bit width; timing at 0.9 V, 0 °C):
  - The one-hot I-LVT raised Fmax by 38% on average (up to 76%) over XOR.
  - The best I-LVT used 19% fewer BRAMs than XOR on average (up to 44%).
  - I-LVT needed only 12.5% more BRAMs than a register-based LVT at 32-bit width, while XOR needed up to 100% more.
  - A register-based LVT's FF count grows with depth, and some deep configurations failed to fit.
  - Binary coding uses the fewest BRAMs above 3 write ports.
  - [Abdelhadi & Lemieux, FPGA 2014](https://people.ece.ubc.ca/lemieux/publications/abdelhadi-fpga2014.pdf)
- A follow-up adds "switched" ports: a group of write ports can trade places with read ports dynamically, cutting BRAM use when port demand alternates. It is released as open-source Verilog — [Abdelhadi & Lemieux, TRETS 2016](https://people.ece.ubc.ca/lemieux/publications/abdelhadi-trets2016.pdf) (from search-result summary)

**FPGA vs custom CMOS cost of multiporting**
- On Stratix III vs CACTI 65 nm (256x32 memories), FPGA bit-density is worse by 2.8x for 2r1w (replication), 12x for a 4r2w LVT and 179x for a 4r2w register-based memory. Delay is worse by 7.6x, 9x and 15x respectively — [Wong PhD thesis §3.4.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

**Register write specialization / rename-assisted banking on an FPGA OoO core**
- Wong's 2-issue x86 OoO soft core removes multi-write-port register files by giving each execution unit its own PRF bank. The renamer keeps one free pool per bank and always allocates a destination from the bank of the unit that will produce it. The costs are wider physical register numbers (2 extra bits for 3 units), several free lists, and binding each µop to an execution unit at rename (no later load balancing). Wong describes this as an LVT whose function is merged into the renamer and consulted many cycles before the data access — [Wong thesis §7.2.1](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- Measured (Stratix IV, Quartus): the resulting integer RF has 7 read and 3 write ports, 32-bit. Register files plus bypassing reach 260 MHz in 2,413 ALMs, of which RF RAM is 1,168 ALMs and forwarding/muxing 1,245 ALMs. The writeback cycle needs forwarding because Stratix IV MLAB LUTRAM cannot write and then read new data at the same location in the same cycle — [Wong thesis §10.1.3, §10.2.1, Table 10.6](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- An earlier VLIW soft core avoided an LVT through compile-time register renaming that prevents write-bank conflicts, at the cost of more physical than architectural registers (Anjam et al., FPT 2010, as cited by) — [TRETS 2014 related work](https://people.csail.mit.edu/ml/pubs/trets_multiport.pdf)

**OoO soft cores that adopted these techniques**
- RSD (Zynq XC7Z020-CLG484-1, Synplify Premier) implements the PRF, rename map table, ready-bit table, wakeup allocation table, destination RAM, IQ payload RAM, ROB execution state and the LSU's "SDA" structure with I-LVT. The PRF and IQ free lists and the ROB metadata use plain banked RAM. Converting from FFs+logic cut whole-core LUTs from 28,166 to 15,379 (−45%) and FFs from 13,511 to 8,584 (−36%), and Fmax rose from 89.8 to 95.3 MHz. The authors note that no synthesis tool builds such multiport RAMs automatically — [Mashimo et al., RSD, FPT 2019](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- NaxRiscv (the IPC target to beat) gives each write port its own bank. Every read port reads all banks and selects one using an LVT that is itself built XOR-style in distributed RAM. An ASIC variant uses latches — [NaxRiscv docs, Backend/Register file](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html). Its HDL framework lists an "automated multiport memory transformation" — [NaxRiscv docs index](https://spinalhdl.github.io/NaxRiscv-Rtd/main/index.html)

### Inferences
**(a) Cost per bit for one 1-write / n-read LUTRAM bank (UltraScale+).** LUT counts for RAM32M, RAM64M, quad-port 128x1, RAM128X1D and RAM256X1D are derived from the 512-bit/SLICEM capacity and port counts in UG574; RAM32M16 and RAM64M8 counts are quoted above.

| Depth | Cheapest build | LUTs/bit, up to 7 independent reads | LUTs/bit, 8 reads |
|---|---|---|---|
| 32 | RAM32M16 (2 bits per 8 LUTs) | 4 | 6 (+RAM32M) |
| 64 | RAM64M8 | 8 | 10 (+RAM64X1D) |
| 96 | RAM64M8 + half of RAM32M16 | 12 | about 16 |
| 128 | 2 x RAM64M8, with the 2:1 depth mux folded into the next mux | 16 | 20 (+RAM128X1D) |

**(b) PRF estimates.** Storage plus read/select muxes only. Bypass network, pipeline registers and routing slack are excluded. Not timing-closed.

| Technique | 128x64, 8R/4W | 96x64, 6R/3W | Notes |
|---|---|---|---|
| Flip-flops + muxes | about 25–26K LUT + 8.2K FF | about 16K LUT + 6.1K FF | Read: 128:1 mux ≈33 LUT/bit/port (32:1 = 8 LUT per UG574). Prohibitive (about 22% of XCK26 LUTs per core). |
| LVT with LUTRAM banks (LVT in FFs or as XOR-LUTRAM like NaxRiscv) | about 6.5–7.7K LUT (≈5.1K in SLICEMs), ≤0.3K FF | about 3.3–4.1K LUT | Banks 4x64x20 = 5,120. Output 8:1 mux 2 LUT/bit/port ≈ 1,024. LVT 0.3–1.5K. Full flexibility. |
| XOR on LUTRAM | about 8.5K LUT (≈7.2K SLICEM) + ~0.3K FF | about 4.0K LUT | Each bank needs m−1+n = 11 (or 8) reads. Adds a cycle of internal write latency and forwarding. Worse than LVT at this depth. |
| BRAM LVT (m x n) | 32 BRAM36 + ~1.5–2.5K LUT | 18 BRAM36 | 22% of the device's BRAM per core. Synchronous read adds a stage. Clock-to-out is 1.46 ns without the output register. |
| BRAM XOR (m(m−1+n)) | 44 BRAM36 | 24 BRAM36 | Not sensible at depth 128. |
| Write-specialized banks (one per write port, rename-assisted) | 4x32: about 2.0K LUT, ≈0 FF. 4x64 (256 regs, less bank-imbalance stall): about 3.1K LUT | 3x32: about 1.15K LUT. 3x64: about 1.9K LUT | Final 4:1 or 3:1 bank mux is 1 LUT/bit/port. No LVT. Needs per-bank free lists and FU binding at rename. |
| Hybrid: 2 clusters x 2 write ports (LVT inside each cluster) | about 3.5K LUT | n/a | Keeps load balancing between the two ALUs of a cluster. |

**(c) Recommendations.**
- Use write-specialized LUTRAM banks for the integer PRF: one bank per write port (e.g., ALU0, ALU1, LSU-load, MUL/DIV/CSR), with per-bank free lists and steering at rename.
  - Size each bank generously (48–64 entries per bank). LUTRAM depth is cheap, and generous banks offset the bank-imbalance stalls that write specialization causes.
  - Keep a LUTRAM LVT (FF-based or XOR-LUTRAM) as the fallback if rename-time FU binding hurts IPC.
- Avoid FF-based PRFs (RSD measured −45% LUTs from moving to multiport-RAM structures) and BRAM-based PRFs (BRAMs are better spent on caches and predictors).
- Avoid multipumping at a 250–300 MHz core clock. It would need BRAMs at 500–600 MHz, against limits of 510 MHz (READ_FIRST) and 585 MHz (WRITE_FIRST) at -2/0.72 V.
- **Packing constraint:** all LUTRAMs in a SLICEM share one write address, so each write-port bank occupies whole SLICEMs. XCK26's 3.5 Mb of distributed RAM corresponds to roughly 55–57K SLICEM LUTs (3.5 Mb / 64 bits per LUT). A dual-core with integer and FP PRFs, RATs, free lists, ROB fields and queues should still fit, but SLICEM placement density, not LUT count, may become the limiter.
- LUTRAM reads are asynchronous: address → LUT (+F7/F8) → bank mux → register is about 2–3 LUT levels. The read stage should therefore not be the critical path. Plan for a writeback-cycle bypass, because a write lands at the clock edge.
- **Clustering** (e.g., two 2-ALU clusters, each with its own register-file copy and with cross-cluster writes delayed a cycle) mainly reduces bypass-network fan-in and routing on an FPGA. It does not reduce write-port cost unless combined with banking.

### Gaps
- I found no measured Fmax/LUT numbers for a 64-bit, 6–8R/3–4W PRF on any Xilinx LUTRAM fabric, let alone UltraScale+. All PRF numbers above are my structural estimates. LaForest's and Abdelhadi's measurements are 32-bit and mostly BRAM-based on Altera parts. The Virtex-6 numeric table (TRETS 2014, Fig. 8) is an image and could not be extracted.
- I could not retrieve the original Seznec/Toullec/Rochecouste MICRO 2002 paper (search budget exhausted; DBLP blocked the fetch), so its bank-imbalance IPC numbers are unavailable. The FPGA applicability is evidenced by Wong's implementation, which applies the same idea at rename. The IPC cost of rename-time bank binding for RV64 workloads remains unquantified.
- LUT counts for RAM64M8 (beyond "one CLB / 8 LUTs, one per read port"), RAM32M, RAM64M, quad-port 128x1, RAM128X1D and RAM256X1D were derived, not quoted.

## 2. Issue queue / scheduler circuits (CAM vs dependency matrix, age matrix, select, single-cycle wakeup-select at 200–300 MHz, speculative load wakeup, replay)

### Takeaway
On FPGAs without wired-OR or CAM cells:
- Matrix wakeup (dependencies tracked by queue position) is faster than tag-CAM wakeup up to about 20–24 entries per queue.
- Fusing select into wakeup in a compacting, age-ordered matrix let Wong build about 40-entry single-issue and 16–32-entry 4-way distributed schedulers with back-to-back dependent issue at 240–325 MHz (Stratix IV C2).
- For loads, speculative wakeup plus a FIFO replay queue in LUTRAM (RSD) is the most FPGA-efficient replay scheme.

### Cited Findings
**Design priorities (Wong et al., FCCM 2016)**
- Losing back-to-back dependent issue costs roughly 10% IPC.
- Oldest-first selection beats random selection by over 15% IPC for large schedulers, though little for small ones.
- Schedulers below 16 entries lose significant IPC in a 64-entry-ROB machine.
- [Wong, Betz & Rose, FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)

**Circuits evaluated (Stratix IV EP4SGX70 C2, fastest grade; Quartus 15.0; mean of 100 seeds)**
- **Compacting CAM:** 3 tag bits compared per 6-LUT. Compaction uses a radix-6 sparse Han-Carlson prefix-OR, and selection uses a radix-4 priority mux built from 7-input ALM functions.
- **Non-compacting matrix:** an N-wide NOR over the dependency row, logic depth log6(2N). Age-based select uses an age matrix stored as a half (triangular) matrix.
- **Fused-logic matrix (new):** entries are compacted so position equals age. Select and wakeup merge into one 1-bit priority mux per row plus a 2-bit outstanding-dependency counter. Grant logic moves off the critical loop. A popcount preprocessing step is critical but can be pipelined outside the loop.
- [FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)

**Results (same conditions)**
- The largest scheduler that fits a 4.2 ns (240 MHz) cycle:

| Scheduler type | Max entries at 240 MHz |
|---|---|
| Compacting CAM | about 20 |
| Age-matrix | 22 |
| Fused-logic matrix | 42 |
| Position-based (random-select) matrix | 44 |

- Below 20 entries, both matrix types are faster than CAM at similar area. CAM is faster than matrix only beyond 24 entries.
- Fused-logic is about 20% faster at 22–36 entries (twice the capacity at 240 MHz).
- A 10-entry random-select matrix reached 434 MHz at 0.81 IPC.
- Compacted-matrix proposals from the literature map poorly to FPGAs because they put large muxes in the wakeup-select loop.
- Fmax was about 60% higher than Aasaraai & Moshovos's earlier schedulers of the same size.
- [FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)
- Background (custom CMOS): the original matrix scheduler (Goshima et al., MICRO 2001) used over 4x the wakeup-array area of CAM for 48 entries, in exchange for halving wakeup delay. On an FPGA, without wired-OR, the gains are smaller — [FCCM 2016](https://www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf)

**Multi-issue (Wong thesis, Stratix IV, median of 50 seeds)**
- Dual issue gives about 70% more IPC than single issue but needs about 4x the scheduler entries.
- Wong's 4-way distributed (one queue per execution unit) compacting-matrix scheduler reaches 325–280 MHz at 16–32 total entries, using 1,750–3,750 ALMs.
  - 17 entries: 0.83 IPC at 324 MHz. 32 entries: 0.95 IPC at 279 MHz (x86 workloads).
  - The 32-entry split is 10/10/7/5 across branch-complex/ALU/AGU/store, whose utilizations are 17/35/37/11%.
  - A large part of the area goes to mapping up to 16 source operands per cycle to producer entries.
- Unified schedulers are slower because every pick-1 select searches the whole pool.
- [Wong thesis §9.7](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

**Small single-issue schedulers (Aasaraai & Moshovos, FPT 2010, Stratix III)**
- For a single-issue OoO soft core, the best performance came from a 4-entry CAM scheduler with age-based selection and back-to-back issue: 164 ALUTs, 303 MHz combined with the renamer — [Aasaraai & Moshovos, FPT 2010](https://www.eecg.utoronto.ca/~moshovos/research/sch.pdf)

**RSD (XC7Z020-1, Synplify)**
- Uses matrix wakeup with random (position) select. A wakeup allocation table (RAM) maps each logical register to the IQ ID of its youngest producer. A ready-bit table and a destination RAM translate IQ IDs back to physical registers. The select-wakeup loop is the IQ critical path.
- Standalone IQ circuits reached about 128/120/107 MHz at 16/24/32 entries (IQ-based replay) and 124/123/106 MHz (replay-queue).
- [RSD, FPT 2019](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Speculative scheduling.** Consumers of a load issue assuming an L1 hit, saving 2 cycles of load-to-use. Simulated gains are up to 26.8% IPC (8.9% average) on SPECint 2006/2017. Two replay designs were compared:
  - **IQ-based replay:** keeps issued instructions in the IQ and shadow-copies the matrix columns for recovery.
  - **Replay-queue (RQ):** issued instructions leave the IQ immediately. Mis-speculated "waves" of same-cycle issues go into a FIFO with per-instruction replay bits and a latency counter that preserves relative issue timing. The FIFO maps onto distributed RAM, minimum 32 entries.
  - The RQ design used up to 2.2x fewer LUTs and gave higher DMIPS (188.6 vs 181.7 at a 16-entry IQ, +3.7%).
  - [RSD, FPT 2019](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)

**NaxRiscv's documented issue queue**
- A unified queue arranged as decode-width columns x rows. Each push fills a row, and the queue shifts by one row per push without compressing holes.
- Dependencies are stored in a half matrix (not a CAM), and wakeup uses ROB IDs. The older instruction wins selection.
- The docs suggest about 32 slots as a practical timing limit.
- Its data cache gives 3-cycle load-to-use through a speculative cache-hit predictor.
- Baseline to beat: the documented RV64 configuration (2 int/shift/branch units + 1 load/store/mul/div/CSR unit) on Artix-7 speed grade 3 reaches 137 MHz with 17.9K LUT, 12.5K FF, 12 BRAM and 16 DSP, scoring 2.94 DMIPS/MHz and 4.94 CoreMark/MHz — [NaxRiscv docs, Performance and Area](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)
- [NaxRiscv docs, Frontend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html); [NaxRiscv docs, Introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)

**Memory-side replay (Wong)**
- Wong's memory pipeline uses its own 8-entry replay scheduler (375 ALMs, Stratix IV) for loads that hit failure conditions — [Wong thesis Table 12.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

### Inferences
- **Speed class of the target.** The KV260's -2/0.72 V fabric is roughly in the same speed class as the fastest Stratix IV used by Wong: BRAM limits are 585 MHz (DS925) vs 550 MHz for Stratix IV M9K (TRETS 2014). So Wong's 280–325 MHz results for 8–10-entry-per-port matrix schedulers are a reasonable upper bound for KV260. Expect 250–300 MHz back-to-back wakeup-select for queues of 8–16 entries per issue port. For unified 32+ entry queues with oldest-first select, about 200–240 MHz is more realistic.
- **7-input functions on UltraScale+.** Wong's fused select-wakeup relies on Altera 7-input ALM functions. On UltraScale+ the closest equivalents are two LUT6s combined by an F7MUX, and 8:1/16:1 priority muxes from F7/F8 muxes. UG574 confirms the mux sizes but not arbitrary 7-input functions. The radix-4 priority-mux structure should map with about 1 LUT level per 4 entries.
- **Recommended for a 2-decode, 4–5 issue-port RV64 core (to beat NaxRiscv's ~32-slot unified queue):**
  - Per-class queues: 2 x ALU at 12–16 entries, 1 x LSU at 12–16, 1 x MUL/DIV/FP at 8–12.
  - Matrix wakeup indexed by queue slot or ROB ID, with a WAT-like table mapping registers to producer slots.
  - Age order via compaction or row-shift.
  - Speculative load wakeup with a LUTRAM replay FIFO.
  - Total about 2–4K LUTs (scaling from Wong's 1,750–3,750 ALMs at 16–32 entries).
- **Load-latency speculation.** Commit to a fixed L1-hit latency, e.g., 3 cycles like NaxRiscv. If a hit/miss predictor is used, keep it small and outside the wakeup loop.

### Gaps
- No UltraScale+ measurements of CAM, matrix or fused-logic schedulers were found.
- The Sassone et al. ISCA 2007 age-matrix paper and the Goshima MICRO 2001 paper were not fetched; their content here comes from Wong's summaries.
- Pick-2 (two grants per cycle from one queue) costs on FPGA were not found.

## 3. Register renaming (RAM vs CAM RAT, checkpoints, free lists, branch masks, recovery)

### Takeaway
RAM-based RATs beat CAM RATs on FPGA. Copy-free checkpointing with BRAM/LUTRAM tables (CFC) used 6.4–7.5x fewer LUTs and ran faster. The cheapest recovery, used by both Wong and NaxRiscv, reverts to a committed map table. That defers rename recovery until the mispredicted branch commits, which Wong measured at about 2.3% of cycles (4.2 clocks per flush). 6–8 branch checkpoints would cover 88–97% of cycles.

### Cited Findings
- **CFC (Aasaraai & Moshovos, FPL 2009; Altera Quartus II 8.1; 64 physical registers; single-issue).** The RAT is stored as C+1 BRAM tables (C checkpoints plus a committed table). A small LUT-based "dirty flag array" records which table holds each architectural register's latest mapping. Taking or restoring a checkpoint therefore needs no copying. The rename is pipelined into 2 stages, and the extra stage's IPC penalty was negligible — [CFC, FPL 2009](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- CFC results, LUTs / MHz:

| Platform, checkpoints | CFC | RAT-in-RAM (RATRAM) | RAT-as-CAM (RATCAM) |
|---|---|---|---|
| Stratix III, 8 | 996 LUT + 6 BRAM / 220 MHz | 7,082 / 196 | 2,327 / 105 |
| Stratix III, 4 | 399 / 292 | 3,002 / 195 | 1,802 / 133 |
| Cyclone II, 8 | 964 / 104 | 6,368 / 82 | 3,631 / 71 |

  Overall, CFC used 7.5x–6.4x fewer LUTs and was at least 10% faster. Recovery by walking the ROB is slow (proportional to the number of wrong-path instructions), whereas checkpoints have fixed latency — [CFC, FPL 2009](https://www.eecg.utoronto.ca/~moshovos/research/cfc09.pdf)
- **Wong's 2-wide x86 renamer (Stratix IV).** Two pipeline stages run at 317 MHz (median of 31 seeds) in 1,892 ALMs and 2,747 registers. Free lists (two-enqueue/two-dequeue queues in small MLABs) take 398 ALMs. Recovery copies a committed mapping table, not checkpoints.
  - 82% of cycles have 5 or fewer branches in flight; 6 checkpoints would cover 88% of cycles and 8 would cover 97%.
  - Rename stalls waiting for the mispredicted branch to commit cost 2.3% of cycles (4.2 clocks per flush).
  - Branches execute in order in that design.
  - [Wong thesis §7.2.2, §7.4, Table 7.1](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **NaxRiscv.** The free list is a circular buffer of free physical register indices in distributed RAM. The RAT uses three structures: a speculative map and a committed map, both in distributed RAM, plus a register-based "location" bit per architectural register choosing between them. On a misprediction the location bits are cleared to revert instantly to the committed map. A physical-register-to-ROB-ID table plus per-ROB-ID busy bits drive wakeup. Reschedules (mispredictions or traps) are recorded by oldest ROB ID and applied by the commit logic — [NaxRiscv docs, Frontend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/frontend/index.html); [NaxRiscv docs, Backend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html)
- **RSD.** The rename map table is an I-LVT multiport RAM, and the PRF free list is a banked RAM queue (bank conflicts cannot occur in a queue) — [RSD, FPT 2019](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)

### Inferences
- **RV64 RAT size.** The integer RAT is 32 x 7 bits for 128 physical registers; a FP RAT is similar. 2-wide rename needs about 4 source reads, 2 old-destination reads and 2 writes. As an XOR or LVT LUTRAM structure at depth 32 (RAM32M16-class), it costs on the order of 100–300 LUTs per RAT.
- **Checkpoint cost.** A full snapshot of the int+FP RAT is about 450 bits. Eight flip-flop snapshots cost about 3.6K FFs plus about 1K LUTs of restore muxing; a CFC-style copy-free LUTRAM organization costs far fewer LUTs.
- **Recommendation to beat NaxRiscv.** NaxRiscv's documented recovery is tied to commit. Add 4–8 branch checkpoints so a mispredicted branch restores the RAT and free-list head when it resolves at execute, and keep the committed map for exceptions and checkpoint overflow. Wong's measurement (about 4 cycles per flush) suggests a modest but real IPC gain. The gain grows if branches resolve out of order and the ROB is deeper.
- **Branch masks/tags.** One bit per checkpoint per in-flight entry in the IQ, LSQ and ROB (e.g., 8 FFs per entry) supports selective squash. The kill logic is an N-input AND/compare per entry, small next to the queues themselves. Not measured anywhere I found.
- **Free lists** are naturally LUTRAM FIFOs (NaxRiscv, RSD, Wong). With write-specialized PRF banks (§1), use one FIFO per bank; checkpoints then save one head pointer per bank.

### Gaps
- I found no FPGA measurements of branch-mask/tag squash logic, of checkpoint counts beyond 4/8 in CFC, or of ROB-walk recovery.
- CFC's numbers are for a single-issue 32-bit design on older Altera parts. No 2-wide RV64 UltraScale+ renamer numbers were found.

## 4. Reorder buffer and commit (LUTRAM banked by writer)

### Takeaway
Most ROB fields are written in order at dispatch and read in order at commit, so they map to bank-interleaved LUTRAM with no conflicts. Only the out-of-order "completed/exception" status needs multi-writer storage: an I-LVT in RSD, or simply a flip-flop bit-vector. Commit latency matters only through flush latency: about 1% IPC per extra commit cycle.

### Cited Findings
- **RSD.** Most of the ROB is a queue (allocated at rename, freed at commit), so its metadata uses banked RAM. Only the execution-status part, written by out-of-order completion, uses a true multiport (I-LVT) RAM.
- **Prior banked-ROB design (Rosière et al.).** It used a small conflict queue to delay conflicting writes and lost performance relative to a true multiport ROB.
- [RSD, FPT 2019](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Wong (x86, 2-wide commit).**
  - Each extra commit-pipeline cycle costs about 1% IPC for the first few cycles, growing to 11% at 10 extra cycles, because commit latency only lengthens flush/recovery.
  - 98% of pipeline flushes come from branch mispredictions.
  - Schedulers must be emptied of wrong-path instructions instantly on a flush.
  - The commit unit was not implemented in hardware.
  - [Wong thesis §8.3–8.5](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **NaxRiscv.** Commit waits for the oldest instruction to complete and then applies any pending reschedule (jump or trap), which is tracked by the oldest ROB ID — [NaxRiscv docs, Backend](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/backend/index.html)

### Inferences
- **Organization for a 2-wide RV64 core with a 64–128-entry ROB:**
  - Dispatch-time fields (arch rd, new and old physical rd, FTQ/PC index, type bits; about 30–60 bits) go into 2 LUTRAM banks interleaved by entry parity, one per dispatch slot. Each bank has 1 write port and 1–2 read ports (commit, plus an optional ROB-walk port), giving about 0.3–0.6K LUTs total.
  - Completion bits are a 64–128-bit FF vector set by one-hot decode from each writeback port, about 0.2K LUTs.
  - Exception or mispredict payloads come only from the branch unit and LSU: a few single-writer LUTRAM banks.
- The ROB is therefore cheap on FPGA. Spend the budget on the scheduler, LSQ and predictor instead.
- Commit logic can be pipelined 1–2 stages at little IPC cost, per Wong's 1%/cycle figure, provided branch recovery does not wait for commit (§3).

### Gaps
- I found no measured LUT/Fmax data for a complete FPGA ROB/commit unit. Wong did not build one, and RSD reports only whole-core numbers.

## 5. Load/store queues, store-to-load forwarding, violation detection and memory dependence prediction

### Takeaway
LQ/SQ CAMs are the most FPGA-hostile OoO structure.
- At 64 entries, Wong measured a CAM LSQ at 186 MHz vs 328 MHz for CAM-free NoSQ, with almost the same IPC.
- At 16 entries, CAMs are area-competitive but about 30% slower.
- Dropping the store queue (OPA-style) costs up to 40% IPC.
- A 16-entry CAM LSQ plus a tiny PC-indexed "wait" predictor (RSD and Wong style) is the low-risk choice. Store Sets or NoSQ are upgrades.

### Cited Findings
**Memory-execution schemes compared (Wong thesis, Stratix IV, 2-issue x86 model; 256 predictor entries; 64 LQ and 64 SQ entries)**

| Scheme | Area (equiv. ALUTs incl. 8–16 M9K) | Fmax | µPC |
|---|---|---|---|
| Cache + TLB only (reference) | 1,029 | 395 MHz | — |
| In-order memory execution | 1,230 | 397 MHz | 0.86 |
| CAM-based LSQ | 7,715 | 186 MHz | 1.21 |
| SQIP | 4,568 | 324 MHz | 1.13 |
| NoSQ | 3,356 | 328 MHz | 1.19 |

- CAM-based out-of-order memory execution gives about 40% more µPC than in-order.
- NoSQ uses less area than the CAM LSQ above 16 entries, and SQIP above 32 entries.
- In frequency, the CAM scheme falls behind beyond about 4 entries.
- At 64 entries, in-order memory execution has 21% higher Fmax but 40% lower IPC.
- Predictor tables degrade frequency and area above 512 entries.
- [Wong thesis §11.3–11.4, Table 11.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

**How SQIP and NoSQ work (as implemented by Wong)**
- **SQIP** predicts whether a load depends on a store, and which SQ entry it forwards from. This lets the SQ live in RAM. Correctness comes from in-order re-execution filtered by a store-vulnerability-window (SVW) check. Predictor lookup takes 2 stages at rename; SVW filtering and re-execution take 3 stages each; training takes 4 cycles.
- **NoSQ** goes further: it renames store→load dependences through the register file (speculative memory bypassing), so the load path becomes cache + TLB only. Wong used a single 2-way associative predictor, a "significant hardware saving" over the original.
- [Wong thesis §11.1.5–11.1.6](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

**Wong's built memory system (CAM-based for lower risk; Stratix IV fastest grade)**
- 16-entry SQ: 1,113 ALMs. 16-entry LQ: 528 ALMs. 8-entry replay scheduler: 375 ALMs.
- The whole memory system (including L1s, L2, TLBs and coherence) runs at 200 MHz.
- At 16 entries the CAM scheme was expected to match re-execution schemes in area but be about 30% slower.
- Dependence prediction is a 32-entry direct-mapped, tagged, PC-indexed table. A hit makes the load replay and wait for earlier stores.
- [Wong thesis §12.5, Table 12.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

**RSD (XC7Z020-1)**
- Loads search older address-generated stores in the 16-entry STQ CAM for forwarding. Stores search younger completed loads in the 16-entry LDQ CAM to detect ordering violations, then replay the offending loads and their dependents.
- The memory dependence predictor is a PC-indexed 1-bit vector, set on a violation. A predicted load waits in the IQ until all older stores have issued, enforced through the matrix wakeup like a register dependence.
- The STQ CAM and the gshare predictor are RSD's critical paths (core at about 95 MHz).
- An STQ-less design (as in OPA) loses up to 40% IPC (16% average) on SPECint 2006/2017 in simulation.
- RSD's MDP uses 2 BRAMs.
- [RSD, FPT 2019](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)

**CAM cost on FPGA (Wong, Stratix III)**
- Soft-logic binary CAMs are 100–210x less dense than custom CAMs, but only about 14x slower.
- Most of the inefficiency comes from FF storage, not the match logic.
- BRAM-based CAMs are 2.4x denser but need 2-cycle writes, which rules them out for schedulers and L1 tags.
- [Wong thesis §3.4.4](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

**NaxRiscv's documented LSU**
- Loads check older stores and can bypass store data, and stores check younger loads. No memory dependence predictor is documented — [NaxRiscv docs, Introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)

### Inferences
- **Recommended first design.** 16-entry LQ and 16-entry SQ CAMs.
  - Compare page-offset bits (12 bits) in the issue cycle and confirm full physical-address match one stage later.
  - Use one-hot age masks with a priority select for the youngest older store.
  - Forward only on full containment and replay otherwise.
  - Estimated cost is about 1.5–2.5K LUTs for an RV64 SQ (64-bit data with byte masks) and about 0.6–1K for the LQ. This scales from Wong's 32-bit x86 numbers.
- **Memory dependence prediction.** Start with the cheap RSD- or Wong-style wait predictor (32–1K entries in LUTRAM/BRAM).
  - Upgrade to Store Sets: an SSIT of about 1–4K entries x 6–8-bit set IDs in one BRAM, plus an LFST of about 32–64 entries in LUTRAM. The predicted dependence is injected as a matrix-wakeup edge, as RSD does.
  - This lets loads wait only for their predicted store instead of all older stores. That is a plausible IPC lever over NaxRiscv, which documents no MDP.
- **CAM-free SQIP/NoSQ.** Worth revisiting only if LQ/SQ must grow beyond about 32 entries, given Wong's area and Fmax crossovers. They add re-execution at commit, which needs an extra cache read port or bandwidth.

### Gaps
- I could not fetch the original Store Sets (Chrysos & Emer, ISCA 1998), SVW (Roth, ISCA 2005) or NoSQ (Sha, Martin & Roth, MICRO 2006) papers. They are described here via Wong's FPGA implementations and RSD.
- No FPGA cost data exists for a real Store Sets implementation.
- No RV64 or UltraScale+ LSQ measurements were found.

## 6. Branch predictors and decoupled front-ends on FPGA (TAGE in BRAM, BTB, gshare, perceptron, micro-BTB/next-line, fetch target queues)

### Takeaway
BRAM's synchronous read (1.46 ns clock-to-out at -2/0.72 V without an output register) makes any BRAM-resident BTB or TAGE a timing hazard in a single-cycle next-PC loop. The FPGA pattern that works is ahead-pipelining the BRAM predictor (RVCoreP), behind a small zero-bubble fetch-stage predictor that a later, more accurate predictor overrides (Wong's early/late design). I found no rigorous published FPGA TAGE implementation with area/Fmax data.

### Cited Findings
- **RVCoreP (Xilinx Artix-7, RV32I five-stage; speed grade not captured in my extraction).** Accessing a BTB in block RAM took about 2.54 ns on the fetch critical path, with one LUT at about 0.12 ns. The full prediction path was about 6.1 ns (165 MHz). The authors split it with two registers into a pipelined predictor that accesses the BTB/gshare one stage early (a "preIf" stage) — [Miyazaki et al., RVCoreP, IEICE 2020 / arXiv](https://arxiv.org/pdf/2002.03568)
- **RSD (XC7Z020-1).**
  - Uses gshare + RAS in 4 BRAMs (the MDP adds 2 more).
  - The global branch predictor is the critical path at about 95 MHz, as it also is in BOOM (71.7 MHz).
  - RSD fetches every cycle on predicted-taken branches. BOOM inserts a one-cycle bubble on every predicted-taken branch, which is one reason RSD has 1.9x BOOM's DMIPS/MHz.
  - [RSD, FPT 2019](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf)
- **Wong x86 front-end (simulated; predictor RTL not built).**
  - The **early** predictor works on 8-byte fetch blocks for zero-penalty taken branches: a 16K-entry, 4-way BTB with 2-bit counters in the BTB, a 16-entry RAS, and path history.
  - The **late** predictor sits at decode with a 512-entry BTB, 8K-entry direction table and 16-entry RAS, and overrides the early one.
  - An override costs a 7-cycle front-end bubble, partly hidden by a 32-entry µop queue.
  - IPC is 0.744 with both predictors, 0.722 without the late one, 0.698 without the early one (−6% despite fewer flushes) and 0.376 with none.
  - The block-level early predictor must also handle predicted-taken "branches" that decode as non-branches.
  - [Wong thesis §6.7, Tables 6.1–6.2](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- **NaxRiscv.** Uses BTB + gshare + RAS, with fetch-stage and decode-stage prediction and a jump/branch circular buffer — [NaxRiscv docs, Introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html); [NaxRiscv docs index](https://spinalhdl.github.io/NaxRiscv-Rtd/main/index.html)
- **Neural/path-based predictor on FPGA (Cadenas, Megson & Jones, FPT 2005).** Practical table sizes were limited to about 32–64 KB, mainly by the logic needed to maintain the tables. Prediction speed scaled well, and misprediction-recovery latency mattered more than prediction latency — [FPT 2005 record](https://reading-pure-test.eprints-hosting.org/14370/)
- **BATAGE on FPGA (Saveau, arXiv 2023).** A student RV32IM in-order core at 50 MHz on an Arty A7-100T put BATAGE in the fetch stage, because delaying predictions by a cycle was judged too slow. The number of tagged banks was limited by single-cycle access, and the author recommends pipelining TAGE into decode. Accuracy fell short of the published ~4 MPKI — [Saveau, arXiv 2312.10426](https://arxiv.org/pdf/2312.10426)
- **BRAM ports and timing.** At -2/0.72 V, BRAM runs at 585 MHz (WRITE_FIRST/NO_CHANGE) or 510 MHz (READ_FIRST), with 1.46 ns clock-to-out without the output register and 0.42 ns with it — [DS925 BRAM](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Block-RAM-and-FIFO-Switching-Characteristics)
- **Wu, Aasaraai & Moshovos, FPL 2013** ("Low-cost, high-performance branch predictors for soft processors") exists but its results could not be retrieved — [DBLP listing](https://dblp.dagstuhl.de/pid/95/1849.html)

### Inferences
- **Recommended KV260 front-end (to beat NaxRiscv's gshare):**
  - **Next-PC stage (cycle 0):** a 16–64-entry micro-BTB / next-line predictor in LUTRAM or FFs. Fully associative or small set-associative, with targets for taken branches and calls/returns, giving zero-bubble taken branches.
  - **Next stage:** BRAM-based main BTB plus a TAGE-class direction predictor, indexed one cycle ahead (from the previous fetch block's address and history, RVCoreP-style), with the BRAM output register enabled. It overrides the micro-BTB with a 1–2-cycle bubble.
  - **Decoupling:** an FTQ (8–16 entries, LUTRAM FIFO) between predictor and I-cache absorbs override bubbles. The FTQ also holds the PC and history snapshot for update and recovery, which keeps PCs out of the ROB.
- **TAGE sizing in BRAM.** A tagged table of 1K entries x about 15–17 bits (tag + 3-bit counter + 2-bit useful) fits one RAMB18. Each tagged table carries a 2K x 18 configuration in a RAMB36, plus a bimodal base.
  - 4–6 tagged tables plus a bimodal table therefore cost about 4–8 BRAM36 per core. Use one port for prediction reads and the other for update writes (true dual-port; READ_FIRST is limited to 510 MHz, WRITE_FIRST to 585 MHz).
  - For a 2-wide RVC fetch block, predict per fetch block (block-based TAGE with a per-slot or "first-taken" position) to avoid multiple lookups.
- **Hashing and history.** Folded-history XOR hashing is cheap in LUTs, but the index must be ready a cycle before the BRAM access, so precompute it in the previous cycle.
- **gshare.** A gshare-only design (NaxRiscv, RSD) is the baseline. A TAGE-like predictor at about 8–16 KB plus an ITTAGE-lite or RAS for indirects is the main IPC lever.

### Gaps
- No peer-reviewed FPGA TAGE, TAGE-SC-L or perceptron implementation with UltraScale+ Fmax/LUT/BRAM numbers was found; search budget ran out before targeted searches.
- No published FPGA micro-BTB or FTQ circuit costs were found. The Wu/Aasaraai/Moshovos FPL 2013 results are unknown.

## 7. L1 caches and L2 on FPGA (BRAM organizations, VIPT with 4 KiB pages, non-blocking/MSHRs, way prediction, URAM L2)

### Takeaway
With 4 KiB pages, a VIPT L1 is limited to 4 KiB per way. Conveniently, that equals the 32 Kb data capacity of one BRAM36, so a 32 KiB 8-way L1 is about 8 BRAM36 of data with LUTRAM tags.
- Non-blocking caches are worth about 1.3x (Wong, x86 SPECint2000).
- CAM-based MSHRs are slow on FPGA: NCOR's MSHR-less design ran at 329 vs 207 MHz.
- URAM (4K x 72, 500 MHz with output register at -2/0.72 V) is the natural L2 data store.

### Cited Findings
**Wong's L1 design (Stratix IV)**
- A VIPT cache that must behave like PIPT is limited to 4 KB per way (page size) unless alias-detection logic is added on misses. Wong chose an 8 KB, 2-way, 32-byte-line L1D and L1I.
- To serve loads, stores, 256-bit evictions and 256-bit fills without replication, the BRAMs run in simple-dual-port mode:
  - One port is shared by loads and evictions, and the other by stores and fills.
  - The lower and upper 16 bytes of alternating lines are swapped, so a fill/evict accesses both halves at one address while a load reads the same offset from both ways.
- Double-pumping the memory blocks was rejected for frequency and latency reasons.
- D-cache tags are replicated 3x (loads, stores, L2 snoops) and I-cache tags 2x.
- [Wong thesis §12.7.1](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

**Wong's measured memory system (Stratix IV fastest grade)**
- DCache: 1,513 ALMs + 8 M9K (1,743 equivalent ALMs). DTLB: 156 ALMs. 4-entry associatively searched L1 MSHR: 65 ALMs.
- L2: 484 ALMs of logic + 23 M9K + 14 M144K (4,882 equivalent ALMs). 8-entry L2 MSHR: 326 ALMs. This is my reading of the misaligned table; the row sums check out with the thesis's conversion of 28.7 ALM per M9K and 267 per M144K.
- The L2 has 32x the L1D capacity but less than 3x its area.
- Total: 9,080 ALMs, 39 M9K and 14 M144K (≈13,937 equivalent ALMs) at 200 MHz. The TLB+cache lookup takes 4.29 ns vs 6.0 ns on Nios II/f.
- Secondary misses to an in-flight line are replayed rather than merged into the MSHR.
- In simulation, the non-blocking cache gave 1.32x SPECint2000 over blocking, and adding an L2 gave a further 1.60x.
- [Wong thesis §12.5, §12.9, Table 12.3](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

**NCOR (Aasaraai & Moshovos, IJRC 2012, Stratix III)**
- A non-blocking cache for runahead execution that removes MSHRs. Pending-miss state lives in the cache-line frame (a pending bit), and secondary misses are dropped or replayed.
- A 4 KB NCOR runs at 329 MHz with 270 logic elements, and a 32 KB NCOR at 278 MHz with 269 LEs.
- A simplified conventional MSHR cache used about 3x the ALUTs and reached 207 MHz at 4 KB (NCOR is 58% faster). NCOR uses 1 more BRAM.
- [NCOR, IJRC 2012](https://www.eecg.utoronto.ca/~moshovos/research/NCOR.pdf)

**NaxRiscv**
- Its data cache is non-blocking with multiple refill and writeback slots, and has a 3-cycle load-to-use through a speculative hit predictor. It optionally has a coherent L2 over TileLink — [NaxRiscv docs, Introduction](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/introduction/index.html)

**URAM (UltraScale+ / XCK26)**
- Each block is 288 Kb, dual-port and 72 bits wide with ECC, and XCK26 has 64 of them — [K26 DS987](https://www.sundance.com/wp-content/uploads/docs/k26-som-Data-Sheet.pdf)
- Fmax at 0.72 V -2: 500 MHz with the output register (OREG), 404 MHz without the pipeline register, and 312 MHz with ECC but no pipeline register. At 0.85 V -2 the same figures are 600/500/400 MHz — [DS925 UltraRAM switching](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/UltraRAM-Switching-Characteristics)
- URAM288 supports cascade (with optional cascade registers), ECC with an extra output stage, and byte-write enables. URAM288_BASE omits cascade — [UG573 UltraRAM Primitives](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/UltraRAM-Primitives)

### Inferences
- **L1D at 32 KiB VIPT on RV64 (Sv39, 4 KiB pages):**
  - 8 ways x 4 KiB, 64-byte lines, 64 sets.
  - Data: 8 x BRAM36 in 512x72 simple-dual-port, one per way, giving an 8-way parallel read of 64 bits each. Tags: 64 x about 30 bits x 8 ways in LUTRAM, replicated for the load, store and probe ports.
  - The 8:1 way-select mux and tag compare dominate timing. Way prediction (MRU or PC-indexed) mainly helps by taking way-select off the load critical path, not by saving BRAM ports.
  - Alternatives: 16 KiB 4-way (4 BRAMs), or page coloring / alias detection to allow larger ways.
- **L1I** follows the same pattern, but fetch can use a wider BRAM port mode to read a whole fetch block.
- **MSHRs.** Use 4–8 MSHRs with a small LUT CAM (Wong measured 65 ALMs for 4) and replay secondary misses. Store pending-miss state in the line frame (NCOR-style) if more outstanding misses are wanted without a larger CAM.
- **Shared L2 for the dual-core in URAM:**
  - 512 KiB = 16 URAM: each URAM holds 4K x 64 data bits = 32 KiB. Four URAMs in parallel give 256-bit lines per cycle.
  - At the 0.72 V -2 limits (500 MHz with OREG), a 250–300 MHz core clock leaves room to double-pump the URAM or to use it as two independent half-rate banks. In practice, a 2–4-cycle L2 data latency with OREG enabled is the safe plan.
  - L2 tags fit in BRAM.
  - 64 URAMs (2.25 MB) would even allow 1 MiB+ L2 with leftover capacity for large predictor tables or a TLB.
- **Speculative load wakeup.** It needs a fixed L1 hit latency (e.g., 3 cycles: AGU → BRAM/TLB/tag → way-select/align). That is what NaxRiscv and RSD use.

### Gaps
- No FPGA way-prediction papers or measurements were found.
- I could not fetch UG573's BRAM-mode tables (403 on the mirror). The 512x72 SDP BRAM36 and 4K x 72 URAM geometries are standard, but here they are inferred from the 288 Kb / 72-bit URAM statement and general BRAM knowledge rather than quoted.
- No published UltraScale+ L1/L2 cache Fmax data for OoO soft cores was found.

## 8. Datapath timing on UltraScale+ (adders, bypass muxes, shifters, DSP48E2 multipliers, IEEE-754 double FMA/div/sqrt, iterative dividers)

### Takeaway
DSP blocks are plentiful on XCK26 (1,248) and fast (644 MHz fully pipelined at -2/0.72 V), so 64x64 multiply and double-precision FMA are bounded by latency, not area. AMD's FP IP needs 10 DSPs and about 1.7K LUTs for a double FMA. The integer critical paths are the bypass network plus ALU and the shifter: in Wong's FPGA OoO core, bypassing took about 20% of the cycle.

### Cited Findings
**Carry chain and muxes**
- Each slice has one 8-bit-tall dedicated carry chain (per-bit carry mux and XOR, lookahead). Chains cascade vertically from slice COUT to CIN, and a chain can be split into two 4-bit chains — [UG574 Carry Logic](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Carry-Logic)
- Wide-mux capacities per CLB: 4:1 per LUT, 8:1 per 2 LUTs, 16:1 per 4 LUTs, 32:1 per 8 LUTs — [UG574 Multiplexers](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Multiplexers)

**Adder, mux and ALU reference data (older devices)**
- Stratix III ripple-carry adders on hard carry chains: 32-bit at 593 MHz, 64-bit at 374 MHz, 108-bit at 242 MHz. That is 15–20x slower than high-performance custom adders but with only a 4.5–7x area ratio.
- Small FPGA muxes are 40–75x slower than custom pass-gate muxes (estimated). Wong estimates the mux area ratio at more than 100x and recommends minimizing mux-heavy structures.
- [Wong thesis §3.4.6–3.4.7, Table 3.8](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- Wong's execution units (Stratix IV; 32-bit x86; 4-way execution):
  - Simple ALU: add/sub 2.3 ns, bitwise 2.3 ns, shifter 2.9 ns, whole ALU above 3.4 ns.
  - Branch/complex ALU: 277 MHz, 1,651 ALMs. AGU: 258 MHz.
  - Register files + bypass: 260 MHz.
  - Combined: 239 MHz, 4,667 ALMs.
  - Bypassing covers about 9 operands with 43 tag comparators and takes about 20% of the critical path. Forwarding is ordered so late-arriving execution results pass through only the final small mux, while RF and writeback forwarding merge earlier.
  - [Wong thesis §10.2, Table 10.6](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)
- On Artix-7, one LUT costs about 0.12 ns — [RVCoreP](https://arxiv.org/pdf/2002.03568)

**DSP48E2 and multipliers**
- The DSP48E2 has a 27x18 signed multiplier with a 48-bit adder/accumulator — [K26 DS987](https://www.sundance.com/wp-content/uploads/docs/k26-som-Data-Sheet.pdf)
- DSP Fmax in the 0.72 V -2 column: 644 MHz with all registers, 453 MHz without ADREG (pre-adder path), 440 MHz without MREG, and 323 MHz with no pipeline registers. Column alignment is inferred from the five-column layout shared with the BRAM/URAM tables; a separate search summary independently gave 644 MHz for -2 at 0.72 V. Cascades crossing the clock-region center may run below spec at 0.72 V — [DS925 DSP48 switching](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/DSP48-Slice-Switching-Characteristics)
- AMD Floating-Point Operator, double precision, on Zynq UltraScale+ xczu9eg -1LV (0.72 V, -1; the closest listed part to the KV260's -2/0.72 V). Vivado 2025.1 default settings; latency not listed; 0 BRAM throughout:

| Operation (configuration) | LUTs | FFs | DSPs | Fmax |
|---|---|---|---|---|
| FMA | 1,671 | 2,591 | 10 | 575 MHz |
| Multiply, Full_Usage | 254 | 548 | 7 | 561 MHz |
| Multiply, Max_Usage | 219 | 534 | 8 | 635 MHz |
| Multiply, Medium_Usage | 298 | 607 | 6 | 561 MHz |
| Multiply, No_Usage | 2,232 | 2,441 | 0 | 457 MHz |
| Add/sub, Full_Usage | 692 | 865 | 3 | 554 MHz |
| Add/sub, no DSP | 653 | 1,090 | 0 | 628 MHz |
| Divide, full throughput | 3,245 | 5,993 | 0 | 495 MHz |
| Divide, iterative | 321 | 358 | 0 | 421 MHz |
| Square root, full throughput | 1,730 | 3,235 | 0 | 531 MHz |
| Square root, iterative | 204 | 379 | 0 | 546 MHz |

  For the iterative divide and square root, an unlabeled column shows 55 and 54 (likely cycles per result). Kintex US+ xcku11p -1 numbers for the same configurations are similar in LUT/DSP count but faster (e.g., FMA 739 MHz) — [AMD Floating-Point Operator resource utilization page](https://download.amd.com/docnav/documents/ip_attachments/floating-point.html)

**Integer dividers**
- Wong's radix-4 non-restoring integer divider (64/32, signed and unsigned, overflow detection; Stratix IV): 364 ALMs, 346 MHz, 18 cycles (52 ns). Alternatives in the same table:
  - OpenCores radix-2 restoring (32/32, multi-cycle): 103 ALMs, 306 MHz, 33 cycles (108 ns).
  - OpenCores radix-2 non-restoring (64/32, fully pipelined): 2,733 ALMs, 368 MHz, 33 cycles (90 ns).
  - Altera LPM_DIVIDE (64/32): 32-stage at 2,174–2,249 ALMs and 202–203 MHz; 16-stage at 2,075 ALMs and 113 MHz; 1-stage at 1,877 ALMs and 8.55 MHz.
  - These rows are my reading of a misaligned table, cross-checked against the text's statement that Wong's divider has 58% of the latency of the next-fastest design.
- Wong judged SRT-class algorithms more suitable for normalized FP division, and found IPC insensitive to further divider latency gains.
- [Wong thesis §10.2.2, Table 10.5](https://www.eecg.utoronto.ca/~jayar/pubs/theses/HWong/HenryWong.pdf)

### Inferences
- **64-bit integer add.** It occupies 8 slices of carry chain. Expect it to fit comfortably within a 3.3–4 ns cycle at -2/0.72 V when inputs come straight from registers. The real critical loop is operand bypass mux → adder → result bus → next operand mux. Budget about 20–30% of the cycle for bypass, as Wong measured, and keep the final forwarding mux 2–4 inputs wide using his "late result enters the last mux" ordering.
- **64-bit barrel shifter.** About 3 levels of 4:1 muxes (one LUT each), roughly 192–256 LUTs. Wong's 32-bit shifter was the slowest simple-ALU sub-unit, so consider a 2-cycle shifter or a dedicated shift pipe if it limits Fmax.
- **RV64 MUL/MULH*.** Tiling with 27x18 signed (26x17 unsigned) pieces suggests about 12 DSP48E2 for a 65x65 signed product (3 x 4 tiles); AMD's 53x53 FP multiply uses 6–8 DSPs plus LUTs, so 10–16 DSPs per integer multiplier is a safe estimate. With DSP pipeline registers enabled (644 MHz capable), 3–5 cycles of latency at 250–300 MHz is realistic. Two cores x (MUL + FMA) is about 50 DSPs, about 4% of XCK26.
- **FP unit.** AMD's IP shows double FMA at 10 DSPs, ~1.7K LUTs and ~2.6K FFs at over 570 MHz in its default (deep-pipeline) settings. A CPU-oriented 4–6-cycle FMA at 250–300 MHz should need similar DSPs and fewer FFs.
  - Before adopting vendor IP, check IEEE-754 completeness for RISC-V D: all 5 rounding modes, subnormals, the exception flags, and fused versus non-fused behavior.
  - A clean-room FMA designed around DSP48E2 tiles (≈10 DSPs) is the likely path.
- **Division and square root.** An iterative digit-recurrence unit (radix-4 SRT, about 30–60 cycles for 64-bit/double, a few hundred LUTs, 0 DSP) matches both Wong's integer result and AMD's iterative double divide/sqrt (321/204 LUTs, 0 DSP). Newton-Raphson or Goldschmidt would reuse the FMA's DSPs to cut latency to about 15–25 cycles, at the cost of FMA-port contention and complexity; that is my estimate, with no FPGA data found.

### Gaps
- No published UltraScale+ (any speed grade) delay or Fmax for a registered 64-bit adder, 64-bit barrel shifter or 64-bit bypass network was found. The DS925 web pages fetched do not include CLB/carry timing arcs.
- PG108's DSP count and latency for a 64x64 multiplier were not retrieved, so the 12-DSP figure is my tiling estimate.
- FPnew and Berkeley HardFloat FPGA resource/Fmax numbers were not found before the search budget ran out.
- The AMD FP IP page omits latency for its listed configurations.
- No FPGA measurements of radix-4 SRT for double precision, or of Newton-Raphson/Goldschmidt dividers, were found.
