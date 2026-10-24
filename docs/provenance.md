# Clean-room provenance statement (draft)

*Draft for the v1 release (DR-190; [m9-plan.md](spec/m9-plan.md) §9), written on 2026-10-24 by smt2-study for the coordinator. The release's provenance claim is the user's, since DR-138 is their rule. Everything here was compiled from this repository alone: no cited source file or page was opened to write it.*

This document has seven parts:
1. The rule, as DR-001, the plan, the conventions, DR-138 and DR-192 state it.
2. How the work kept it, and what the record says was read beyond papers, specifications and vendor documents.
3. A bibliography: every specification, paper, vendor document and other public document cited in `docs/` (the plan, `decisions.md`, the devlog, `docs/spec/` and `docs/perf/`), with where each is cited.
4. An audit of the literature review's links into other projects' source trees (2026-10-12).
5. The third-party firmware and software the release builds, with versions, our changes and licences.
6. Our own licences.
7. Open points for the user.

## 1. The rule

- **DR-001 (2026-10-12, the user):** "Clean-sheet design. Reuse nothing; never read another core's RTL or the user's other RISC-V projects."
- **The plan's clean-room policy** ([architecture_plan.md](architecture_plan.md) §2.3):
  1. All RTL is written by us from our own unit specifications in `docs/spec/`.
  2. Each spec records the source of every borrowed idea (paper, documentation or public spec).
  3. Nobody reads another core's RTL for the unit they are designing. Parameter values already extracted into the notes are facts and may be used.
  4. Public interface specs are implemented as written: the RISC-V ISA and privileged spec, Debug, PLIC, ACLINT, SBI, TileLink semantics, AXI4, virtio-mmio, and the 16550 register map.
  5. Third-party tools and software are used as-is: Spike, Sail, Verilator, GCC/LLVM, OpenSBI, Linux, TestFloat, OpenOCD.
  6. NaxRiscv runs unmodified, and only as a benchmark control.
  7. Vendor primitives and XPM memory macros are allowed.
- **The conventions** ([conventions.md](spec/conventions.md) §11): specs first; never read another core's RTL (NaxRiscv, BOOM, XiangShan, CVA6, Rocket, OpenC910 and so on) for a unit you are designing; published papers, public specifications and documentation are fine, and are cited in the unit spec; third-party tools are used as-is; third-party source is never copied into the repository, but fetched at build time.
- **DR-123 (2026-10-14):** ideas from published work such as RSD's papers are allowed; no other core's RTL.
- **DR-138 (2026-10-14, the user):** "no track reads other projects' RTL or source (LiteX, LiteDRAM, NaxRiscv's L2, PULP's AXI and the like), even to learn from it. Papers and the vendor's documentation are the only outside sources." Considered and declined: reading permissively licensed reference source without copying it.
  - From this date the rule covers every other project's source, not only cores' RTL and not only the unit being designed.
  - The devlog records that the user offered to let the tracks learn from LiteX's source, then withdrew the offer before anyone read it ([devlog.md](devlog.md), 10-14 22:00–10-15 01:30).
- **DR-192 (2026-10-23, the user): the rule's scope for firmware.**
  - The clean-room rule protects the CPU's own design: no other project's RTL or core source, papers and vendor documents only.
  - It does not cover the standard firmware we build and run. Reading OpenSBI's and U-Boot's code to build, configure or patch them is allowed; the OpenSBI patch tg1 was done that way.
  - Patches are minimal and spec-based, each recorded in [firmware_switches.md](spec/firmware_switches.md) with its basis and how to drop it. Offering one upstream needs the user's yes each time.
  - The hardware stays generic, so upstream firmware runs on it unmodified, and Linux stays Debian's own kernel with no patches (DR-147).

## 2. How the work kept it

- **Our own specifications first.** Every RTL unit is written from a spec in `docs/spec/`, and the specs carry a Provenance section naming their sources (§3 lists them).
- **Public interfaces as written:** the RISC-V ISA and privileged specifications, SBI, PLIC, ACLINT, Debug, TileLink, AXI4, virtio and the 16550 register map (plan §2.3, point 4).
- **Our own tools.** The performance model `tgsim` (`perfmodel/`) was written for this project: DR-001 meant writing our own simulator in place of the planned Spike-trace front end (plan §10.1 and Appendix C).
- **Third-party tools, used as-is** (`tools/versions.sh`; plan §2.3, point 5):
  - Verilator v5.052;
  - Spike (riscv-isa-sim, master of 2026-10-13, `f8a060b7`), the lockstep reference, linked as a library;
  - riscv-tests `7b68f7b9`, riscv-arch-test's act4 branch `729288a5` (ACT4) with the Sail RISC-V model 0.15 and the udb gem 0.1.17's binaries ([sw/versions.sh](../sw/versions.sh));
  - Berkeley SoftFloat 3 `a0c6494c` and TestFloat 3 `a9c849f1`;
  - litmus-tests-riscv at `08728ed`, used read-only as a test suite ([verification.md](spec/verification.md) §6.6);
  - AMD Vivado 2025.2;
  - the xPack `riscv-none-elf-gcc` 15.2.0-1 for bare-metal programs, and Bootlin's toolchains for Linux (§5).
- **Benchmarks, fetched at build time and never committed** (`perfmodel/scripts/fetch_deps.sh`; pins in `perfmodel/third_party/VERSIONS.txt`): CoreMark `1f483d5b` (EEMBC), Embench-IoT 1.0 (`0466a18e`), and netlib's Dhrystone 2.1 (`dhry-c`, sha256 `038a7e91…`).
- **NaxRiscv, the benchmark control:**
  - In `docs/` it enters through its published material:
    - its README and its Read the Docs pages (the RV64 Fmax of 137 MHz);
    - its published CoreMark, Dhrystone and Embench figures;
    - its issue #89;
    - its slides from RISC-V Week Paris (2022) and 37C3 (2023), which carry the facts at plan §0 (95, 98, 119), §4.9 (525), §4.14 (615) and Appendix A (1383, 1403);
    - the sources are plan §0, §4.14, §10.1–§10.2, [dse_report.md](perf/dse_report.md) §1–§3, [area_recovery.md](perf/area_recovery.md) §6.2, and §4 here, C1–C2.
  - The literature review also linked the source of NaxRiscv's L2 (SpinalHDL's coherent cache) and a README in its test tree (§4, A6 and B9).
  - The NaxRiscv-like control is a `tgsim` preset built from those published parameters.
  - Running its RTL as a control needs its sources downloaded, which needs the user's approval. That download has not happened (plan §10.1; DR-006).
- **The literature review (2026-10-12):**
  - It comprises [reports/RISCV OoO soft cores for KV260.md](../reports/RISCV%20OoO%20soft%20cores%20for%20KV260.md) and the ten notes behind it in `research_notes/RISCV OoO soft cores for KV260/`.
  - It gathered papers, specifications, vendor documents, articles, and other projects' published documentation and results.
  - Plan §2.3 (point 3) lets parameter values extracted into those notes be used as facts.
  - The notes and the report also link into other projects' source trees in places. §4 lists every such link, what was taken from it, and whether Tanager uses it.

**What the record says was read beyond papers, specifications and vendor documents.** This is listed here for the user's decision (§7), as the files state it:
- **Spike's sources, as the lockstep reference's behaviour:**
  - CSR WARL behaviour ([core-priv.md](spec/core-priv.md) Provenance, line 103: "Spike's CSR implementation was read as the reference model's behaviour (plan §2.3 allows reference models and tools)");
  - `walk()` and PMP matching ([core-mmu.md](spec/core-mmu.md) lines 22, 29 and Provenance line 123);
  - the CSR set "as Spike defines it" ([core-pipeline.md](spec/core-pipeline.md) §9.1, lines 445, 462; Provenance line 635);
  - Spike's public headers and sources for its library interface, and `csr_init.cc`, `csrs.cc` and `mmu.cc` for the ACT4 configurations' WARL choices ([verification.md](spec/verification.md) §10, lines 1322, 1325).
  - Spike is a tool used as-is under plan §2.3 (point 5). The specs read it as the reference's behaviour, so the lockstep compares, not as a design to copy. DR-138, which came after, names no exception for it.
- **ACT4's test environment and configuration files** (`tests/env/sail_macros.h`, the UDB configuration schema, Sail's reference configuration), to run the suite ([verification.md](spec/verification.md) §6.1 and §10, lines 1077, 1087, 1324).
- **For the board's processor side** ([soc.md](spec/soc.md) §7.1 and §8.2):
  - AMD's embeddedsw register headers `xfpd_slcr.h` and `xlpd_slcr.h` from the Vivado 2025.2 install (lines 263, 288);
  - AMD's `zynqmp_atb` Linux patch series as LWN carried it (lines 266–269, 277, 288);
  - the upstream ZynqMP and K26 device trees (lines 595–596).
- **Firmware and the operating system:**
  - OpenSBI's and U-Boot's code, to build, configure and patch them (DR-192). Before DR-192 (10-23), [pmp-at-fill.md](spec/pmp-at-fill.md) (10-21, lines 37–39, 76–82) already describes OpenSBI 1.9's internals (`ENF_PERMISSIONS`, `sbi_hart_pmp_fence()`, the Smepmp paths) without naming a source;
  - Linux's `head.S`, named as the basis for `scounteren` = 0x2 ([verification.md](spec/verification.md), line 808);
  - the KV260 stock image's device tree, for the fan's pin (DR-129);
  - Debian's own `linux-source`, which `tanager-ps-dkms` builds for the processor side's drivers (DR-168).
- **No line in the plan, `decisions.md`, the devlog, `docs/spec/` or `docs/perf/` says that another core's RTL was read.**

## 3. Bibliography

Each row is one outside document, with where `docs/` cites it.
- **Abbreviations:** AP is the plan, `architecture_plan.md`; DR-n is a row of `decisions.md`; DL is the devlog. Other files are named relative to `docs/`, with a line number and section.
- **Grouping:** the rows run from specifications to papers, benchmark documentation, vendor documents and other public documentation. Techniques the docs name without citing a source are listed after the papers.
- **Identifications:** where the docs give only an author or a name, the probable title is marked "(likely)". It comes from the docs' own wording; nothing was looked up.

### 3.1 Specifications

| Document | Cited at |
|---|---|
| **The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA**, version 20240411 (RV64IMAFDC, RVC, the F and D chapters, NaN-boxing, RVWMO, LR/SC forward progress); github.com/riscv/riscv-isa-manual | spec/fpu.md:17, 48, 60, 63, 163, 864 (Provenance); spec/interfaces.md:151, 154 (§4); spec/core-pipeline.md:622, 635 (§13, §15); spec/m7-smt2-plan.md:238–239 (§8); spec/m9-plan.md:395–396 (Sources), 118–119, 143–145; spec/verification.md:381, 1151, 1220, 1226, 1261, 1272 (RVWMO and LR/SC rules); AP §2.2 (171), §2.3 (188), §4.1 (323), §4.9 (529), §4.12 (560), §11 (1241); DR-192; DL 10-19 23:30, 10-21 03:00, 10-23 01:30 and 10:40 |
| **The RISC-V Instruction Set Manual, Volume II: Privileged Architecture**, version 1.13 (§3.7, physical memory protection and paging; the Sscofpmf, Smcntrpmf and Svpbmt chapters) | spec/core-priv.md:46, 102; spec/core-mmu.md:75, 122; spec/pmp-at-fill.md:32, 75 (§3.7); spec/interfaces.md:31; spec/core-pipeline.md:374, 635; spec/m7-smt2-plan.md:94, 238; spec/m9-plan.md:395–396 (Sources), 49–52, 96–97; spec/verification.md:1083, 1311, 1342; perf/area_synth.md:126, 127, 129 (§4); perf/area_recovery.md:2612 (§7.8), 2965 (§7.11); AP §2.2 (175–182), §2.3 (188), §4.1 (323, "privileged spec 1.13"); DR-146, DR-167, DR-192 |
| **The RISC-V extensions** named from the two manuals (Zicsr, Zifencei, Zicntr, Zihpm, Zba/Zbb/Zbs, Zicond, Zihintpause, Zkt, Za64rs, Zfhmin, Sstc, Svinval, Svpbmt, Svade, Svadu, Sv48/Sv57, Sscofpmf, V, H) | AP §1 (149–150), §2.2 (171), §4.1 (323–330), §10.1 (1156), §10.2 (1199), §11 (1266); DR-016, DR-047, DR-062, DR-190; spec/m9-plan.md §1–§4, §10; DL 10-14 16:45, 10-23 10:40 |
| **The RISC-V CMO specification** (Zicbom, Zicboz, Zicbop); github.com/riscvarchive/riscv-CMOs | spec/m9-plan.md:399 (Sources), 118–119 (§3) |
| **The RISC-V Profiles** (RVA20, RVA22, RVA23); github.com/riscv/riscv-profiles/releases | spec/m9-plan.md:397 (Sources), 35, 93, 106, 115, 144–145; AP §1 (149), §4.1 (328), §13 D4 (1331); DR-016, DR-190 |
| **The RISC-V ratified extensions list**; riscv.atlassian.net, page 16154732 | spec/m9-plan.md:398 (Sources) |
| **The RISC-V Supervisor Binary Interface specification**, v3.0 (TIME, IPI, RFENCE, HSM, PMU, FWFT, DBCN; the v0.2 and v0.1 legacy forms); github.com/riscv-non-isa/riscv-sbi-doc | spec/m7-smt2-plan.md:240 (§8, HSM); spec/m9-plan.md:400 (Sources), 59, 63, 65, 147; spec/soc.md:217, 237; spec/debian-kernel.md:22, 59; spec/verification.md:810, 1382; spec/firmware_switches.md:21; AP §2.2 (173), §2.3 (188), §5.2 (731), §5.3 (736, "SBI v3.0"), §6.5 (857), §7.2 (884); DR-190, DR-192 |
| **The RISC-V Debug Specification**, 0.13.2 and 1.0 (Sdext, Sdtrig, the debug module, the JTAG DTM, the trigger CSRs' no-trigger form); github.com/riscv/riscv-debug-spec/releases/tag/1.0 | spec/m9-plan.md:274, 276, 282–283, 323, 401 (Sources); spec/core-pipeline.md:460 (§9.1); spec/verification.md:422 (§3.9); perf/ledger_table.md:33; AP §2.3 (188), §7.4 (893), §11 (1266); DR-190 |
| **The RISC-V Platform-Level Interrupt Controller Specification**, v1.0.0 (`riscv,plic0`) | spec/uncore-periph.md:17, 82, 98, 101 (PLIC Provenance); spec/plic-claim-timeout.md:47–49; spec/soc.md:645 (§8.2); spec/verification.md:1087, 1310; AP §2.2 (172), §2.3 (188), §5.4 (745) |
| **The RISC-V ACLINT Specification**, v1.0 (MSWI, MTIMER, SSWI; the CLINT-compatible layout) | spec/uncore-periph.md:17, 55 (ACLINT Provenance); spec/verification.md:1311; AP §2.2 (172), §2.3 (188), §5.4 (744) |
| **SiFive TileLink Specification**, 1.8.1 (§2.2, §4.6, §8, §8.2, figures 8.4–8.6; TL-C, the channel-priority rule) | spec/interfaces.md:36 (§2); spec/uncore.md:82, 112, 158 (Provenance); spec/l2.md:72, 103, 133, 244, 293 (Provenance); spec/core-lsu.md:277 (Provenance); spec/verification.md:85, 103, 1320 (§10); AP §2.3 (188), §3.1 (272), §5.2 (729), §9 (1142); DR-024, DR-045, DR-149; DL 10-13 11:38 |
| **Arm AMBA AXI protocol specification**, ARM IHI 0022 (AXI4, AXI4-Lite) | spec/host.md:239 (Provenance); spec/uncore-mem.md:12, 76, 98, 113 (Provenance); spec/uncore-trace.md:156 (Provenance); spec/l2.md:252; spec/soc.md:331; AP §2.3 (188), §5.5 (755, 758); DR-136, DR-158 |
| **OASIS Virtual I/O Device (VIRTIO) Version 1.2**, cs01 (virtio-mmio); docs.oasis-open.org/virtio/virtio/v1.2/cs01/ | spec/host.md:143; spec/m9-plan.md:416 (Sources); AP §2.3 (188), §3.1 (265), §5.4 (748), §7.3 (888) |
| **Texas Instruments (National) PC16550D UART datasheet** (`ns16550a`'s register map) | spec/uncore-periph.md:108, 153, 188 (UART Provenance); AP §2.3 (188), §3.1 (264), §5.4 (746); DR-187 |
| **IEEE 754-2019**, floating-point arithmetic (§6.3, §7.4, §7.5), and IEEE 754-2008 | spec/fpu.md:62, 63, 65, 150, 865 (Provenance) |
| **IEEE 1800-2017**, SystemVerilog | spec/conventions.md:23 (§2); AP §2.4 (194), §13 D1 (1328); DR-013 |
| **Linux's device-tree bindings** (`Documentation/devicetree/bindings`, v6.12: `riscv,pmu`, RISC-V CPUs and extensions, `virtio,mmio`, `ns16550a`, `timebase-frequency`) | spec/m9-plan.md:405–406 (Sources), 62, 91, 128, 268; spec/soc.md:1052 (Provenance); AP §5.4 (743–746), §7.1 (877), §11 (1289), §12 (1315); DR-192 |
| **IEEE 1149.1 JTAG** (named only) | AP §3.1 (266), §7.4 (893); DR-190 |

### 3.2 Papers and books

| Document | Cited at |
|---|---|
| R. E. Goldschmidt, *Applications of Division by Convergence*, M.S. thesis, MIT, 1964 | spec/fpu.md:178, 866 (Provenance) |
| M. D. Ercegovac and T. Lang, *Digital Arithmetic*, Morgan Kaufmann, 2004 (chapters 5–8) | spec/fpu.md:178, 305, 867 (Provenance) |
| S. F. Oberman, the AMD-K7's floating-point division and square root, ARITH-14, 1999 | spec/fpu.md:181, 868 (Provenance) |
| P. Markstein, software division and square root with Goldschmidt's algorithms, RNC 6, 2004 | spec/fpu.md:235, 869 (Provenance) |
| D. Das Sarma and D. W. Matula, the accuracy of ROM reciprocal tables, IEEE Transactions on Computers 43(8), 1994 | spec/fpu.md:196, 870 (Provenance); perf/ledger_table.md:52 ("bipartite seed-table logic", named) |
| R. K. Montoye, E. Hokenek and S. L. Runyon, the IBM RISC System/6000 floating-point unit, IBM Journal of Research and Development 34(1), 1990 | spec/fpu.md:110, 871 (Provenance) |
| T. Lang and J. D. Bruguera, a reduced-latency floating-point fused multiply-add, IEEE Transactions on Computers 53(8), 2004 | spec/fpu.md:872 (Provenance) |
| V. G. Oklobdzija, a leading-zero detector, IEEE Transactions on VLSI Systems 2(1), 1994 | spec/fpu.md:873 (Provenance) |
| F. de Dinechin and B. Pasca, "Large multipliers with fewer DSP blocks", FPL 2009 | spec/fpu.md:875 (Provenance) |
| J. E. Smith and A. R. Pleszkun, 1988 (likely "Implementing precise interrupts in pipelined processors", IEEE Transactions on Computers) | spec/core-pipeline.md:632 (§15) |
| J. L. Hennessy and D. A. Patterson, *Computer Architecture: A Quantitative Approach*, 6th edition, chapter 3 | spec/core-pipeline.md:632 (§15); spec/core-lsu.md:276 (Provenance) |
| Seznec, Toullec and Rochecouste, MICRO 2002: register write specialisation (named in the literature review, which could not retrieve it) | spec/core-pipeline.md §15; AP §4.7 (492), Appendix A (1381, and its source list) |
| Henry Wong, FCCM 2016 (www.eecg.utoronto.ca/~jayar/pubs/wong/wongfccm16.pdf) and TRETS 2016 (…/wongtrets16.pdf), and his PhD thesis, University of Toronto, 2017 (…/theses/HWong/HenryWong.pdf): FPGA schedulers and a superscalar out-of-order x86 soft processor | spec/core-pipeline.md §15; AP §4.7 (492), Appendix A (1381, 1382, 1386, 1398, and its source list) |
| Goshima et al., MICRO 2001: the matrix scheduler (through Wong's summary; the review could not retrieve the original) | spec/core-pipeline.md §15 |
| G. Reinman, B. Calder and T. Austin, ISCA 1999 (likely "A scalable front-end architecture for fast instruction delivery"); fetch-directed prefetch | spec/core-pipeline.md:634 (§15); AP §4.2 (337); FDIP named at perf/dse_report.md:92, 378; perf/area_recovery.md §6.3, §6.7, §6.11 |
| LaForest et al., FPGA 2012: XOR-based multi-ported memories (people.csail.mit.edu/ml/pubs/fpga12_xor.pdf); LaForest and Steffan, FPGA 2010: the live-value table (www.eecg.utoronto.ca/~steffan/papers/laforest_fpga10.pdf); LaForest et al., TRETS 2014 (people.csail.mit.edu/ml/pubs/trets_multiport.pdf) | spec/core-pipeline.md §5.2, §15; perf/fpga_friendly.md (the rules, item 4); LVT and XOR forms named at perf/fpga_friendly.md §2–§4, perf/spikes.md:2697, perf/hart1_ram_form.md:36 |
| J. Cortadella and J. M. Llabería, IEEE Transactions on Computers, 1992 (likely the carry-free test of A + B = K) | spec/core-pipeline.md:125 (§3.4) |
| A. Moshovos et al., memory dependence speculation (likely ISCA 1997) | spec/core-lsu.md:276 (Provenance) |
| D. J. Sorin, M. D. Hill and D. A. Wood, *A Primer on Memory Consistency and Cache Coherence*, 2nd edition, 2020, chapter 8 | spec/l2.md:294 (Provenance) |
| D. M. Tullsen et al., "Exploiting choice: instruction fetch and issue on an implementable simultaneous multithreading processor", ISCA 1996 (ICOUNT) | spec/m7-smt2-plan.md:232–233 (§8); ICOUNT named at spec/m7-smt2-plan.md:14, 57, 95, 110, 112, 153, 186, 212, spec/threading.md:57, 71, spec/core-pipeline.md:143, perf/smt2_report.md (from §1.1 on), perf/smt2_tables.md:453, perf/budgets.md:68, perf/spikes.md:338 |
| S. E. Raasch and S. K. Reinhardt, resource partitioning in SMT processors, PACT 2003 | spec/m7-smt2-plan.md:234–235 (§8) |
| D. T. Marr et al., "Hyper-Threading Technology Architecture and Microarchitecture", Intel Technology Journal 6(1), 2002 | spec/m7-smt2-plan.md:90, 236–237 (§8); AP Appendix A (1402) |
| K. Luo et al. (likely "Balancing throughput and fairness in SMT processors", ISPASS 2001): the harmonic mean of per-thread speedups | perf/smt2_report.md:190 (§2.4) |
| Mashimo et al., "An Open Source FPGA-Optimized Out-of-Order RISC-V Soft Processor", ICFPT 2019, pp. 63–71 (RSD; www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT%2719.pdf) | perf/fpga_friendly.md (the rules, item 4); AP §4.7, Appendix A (1380, 1383, 1385, 1397, and its source list); DR-123; DL 10-14 10:15 |
| OPA, ORConf 2015 (github.com/terpstra/opa), as the RSD paper measures it | AP Appendix A (1397, and its source list) |
| Zhao et al., SonicBOOM, CARRV 2020 (carrv.github.io/2020/papers/CARRV2020_paper_15_Zhao.pdf); also the source of Rocket's blocking-eviction measurement | AP §4.3 (383), §4.11 (552), Appendix A (1384, 1385, 1387, 1398, and its source list) |
| Celio et al., arXiv 1607.02318 (2016): macro-op fusion | AP Appendix A (1388, and its source list) |
| SmolRV64: an independent design of 2026, described in its project's README (github.com/tommythorn/smolrv64); not a paper | AP §4.7 (492), Appendix A (1381, 1404, and its source list) |
| CVA6S+: the papers the review names as Tedeschi (arXiv 2505.03762) and Fu (arXiv 2505.24363, CF 2025) | AP Appendix A (1400, and its source list) |
| Chrysos and Emer, Store Sets, ISCA 1998 (acg.cis.upenn.edu/milom/cis501-Fall10/papers/store-sets.pdf) | spec/m9-plan.md (Sources); perf/area_recovery.md §7.11; AP Appendix A (1397, and its source list) |
| Seznec's limited-budget TAGE-SC-L entry to CBP-2016 (jilp.org/cbp2016/paper/AndreSeznecLimited.pdf) | spec/core-pipeline.md §15 |
| XiangShan's published papers and documentation (its FPGA prototype's latency injection) | spec/uncore-mem.md:76 (Provenance); AP §5.6 (772) |
| Pollack's rule | AP §2.5 (234) |
| Spectre variant 2 | AP §6.2 (792); perf/smt2_report.md:382 (§5) |

**Not in the literature review.** These papers are cited in `docs/` by author and venue only, and the review does not hold them either, so their titles above remain identifications from the docs' own wording:
- Smith and Pleszkun;
- Reinman et al.;
- Cortadella and Llabería;
- Moshovos et al. (core-lsu.md's background reference; the review's Moshovos papers are Aasaraai and Moshovos's FPGA work);
- Luo et al.

**Techniques named without a paper in `docs/` or the literature review:**
- TAGE itself. The specs cite Seznec's CBP-2016 TAGE-SC-L, but the original TAGE paper is not in the review. core-pipeline.md §3 points to `reports/m6-tage-design.md`, which is not in the repository.
- ITTAGE, which the review names only as a part of XiangShan.
- The load-wait table.
- gshare: perf/dse_tables.md:93, perf/ledger_table.md:3, 30.
- Weighted speedup: perf/smt2_report.md §1–§2.
- The R10K-style rename: AP Appendix B (1411).
- Others: radix-4 and radix-16 division, MESI, and the age matrix.

### 3.3 Benchmark documentation

| Document | Cited at |
|---|---|
| **EEMBC CoreMark** and its run and reporting rules (at least 10 seconds; the core files unmodified; the memory-to-core clock ratio reported) | AP §0 (109), §10.2 (1191–1197), Appendix B (1430); perf/dse_report.md:191–196, 253; spec/verification.md:555, 797 |
| **Dhrystone 2.1** and its ground rules (`-O3 -fno-inline`; DMIPS) | AP §0 (111), §10.2 (1201); perf/dse_report.md:119 |
| **Embench-IoT 1.0** (the suite and its score) | AP §0 (112), §10.2 (1201, 1208); perf/dse_report.md:39, 120, 131, 172, 183, 190; perf/dse_tables.md:270, 272; perf/area_recovery.md:636 |
| STREAM, SPEC CPU2017 (named, not used), lmbench, the 7-zip benchmark (named) | AP §10.2 (1202–1203); perf/dse_report.md:76, 121, 132, 493, 506; perf/feature_ledger.md:175; perf/smt2_report.md:754 |

### 3.4 Vendor documents

| Document | Cited at |
|---|---|
| **AMD UG573**, UltraScale Architecture Memory Resources (block RAM, UltraRAM port order) | spec/fpu.md:874 (Provenance); spec/core-pipeline.md:318, 319 (§7.1); perf/spikes.md:1204, 1221 (§8.14) |
| **AMD UG579**, UltraScale Architecture DSP Slice | spec/fpu.md:127, 874 (Provenance) |
| **AMD DS925**, Zynq UltraScale+ MPSoC Data Sheet: DC and AC Switching Characteristics | spec/fpu.md:874 (Provenance) |
| **AMD UG974**, UltraScale Architecture Libraries Guide (XPM CDC, BSCANE2); docs.amd.com | spec/host.md:240 (Provenance); spec/m9-plan.md:280, 415 (Sources) |
| **AMD UG1087**, Zynq UltraScale+ Devices Register Reference (`ERR_ATB_ISR`, `FPD_SLCR`) | spec/soc.md:264, 288 (§7.1) |
| The Zynq UltraScale+ technical reference manual, by name only (likely AMD UG1085) | spec/soc.md:439 (§8.2) |
| AMD's embeddedsw register headers `xfpd_slcr.h` and `xlpd_slcr.h` (the Vivado 2025.2 install) | spec/soc.md:263, 288 (§7.1) |
| AMD's Kria KV260 board files (Vivado 2025.2's board store, `xilinx.com:kv260_som:part0:1.4`) | spec/soc.md:81 (§2.2), 1053 (Provenance) |
| AMD's `zynq_ultra_ps_e` 3.5 IP and its address map (Vivado 2025.2) | spec/soc.md:419, 427, 581 (§8.2) |
| AMD's simulation models of DSP48E2, RAM64X8SW and URAM288_BASE (vendor library code) | perf/fpga_friendly.md:74, 175, 203, 216; perf/spikes.md:1204, 2742 |
| AMD Vivado's licensing (2025.2 free for the XCK26) and its EULA | AP §2.1 (167), §13 D3 (1330); DR-015, DR-034 |
| The KV260's stock image and Kria's default PL design (the fan's PWM pin; the SMMU disabled in its device tree) | DR-102, DR-129; AP §5.5 (757); DL 10-14 11:40, 14:10 |
| SiFive's published PWM register manual (only if a PWM is ever added) | spec/soc.md:487 (§8.2) |
| UltraScale+ primitives and XPM macros, named (RAM64M8, RAM32M16, SRL16E, DSP48E2, CARRY8, LUT6_2) | AP §2.1, §8.2–§8.5; perf/spikes.md, perf/fpga_friendly.md, perf/hart1_ram_form.md; DL §5 |

### 3.5 Articles and other public documentation

| Document | Cited at |
|---|---|
| Chips and Cheese, "Arm's Cortex A73: Resource Limits, What are Those?" (2024-07-18), and "Cortex A73's Not-So-Infinite Reordering Capacity" | AP Appendix B (1447, 1448); the Cortex-A73 and A72 facts at AP 69, §4.2 (334), §4.4 (410), §4.5 (416), §4.6 (452), §4.9 (536), Appendix A (1385, 1388, 1393–1395), Appendix B (1413–1425); spec/core-pipeline.md:633 |
| The Register, "Arm Cortex-A73" (2016-06-01) | AP Appendix B (1449) |
| risclite/SuperScalar-RISCV-CPU (SSRV) on GitHub and its design document `wiki/SSRV全解析.pdf` | AP Appendix B (1450), with what it says at §4.2 (342), §10.2 (1194), Appendix A (1396), Appendix B (1427–1434) |
| NaxRiscv's documentation and published results: its README, its Read the Docs pages (the Performance page), its published RV32 and RV64 figures, issue #89, and its slides (RISC-V Week Paris 2022; 37C3, 2023; on SpinalDoc, §4 C1–C2) | AP §0 (12, 52, 90–101, 107–119), §4.14 (596–615), §8.5 (1101), §10.1 (1165), §10.2 (1185), Appendix A (1383), Appendix B (1411, 1438); DR-006, DR-145, DR-152; DL 10-14 20:05, 22:00; perf/dse_report.md:31, 39, 135–196, 253, 273; perf/dse_tables.md:268, 272; perf/area_recovery.md:636–641, 702 |
| SCR1's published CoreMark flags (named) | AP §10.2 (1194) |
| Linux 6.12's documentation: RISC-V hwprobe, `admin-guide/sysctl/kernel`, the kernel parameters; kernel.org | spec/m9-plan.md:67–70, 129, 152, 402–404 (Sources) |
| Kconfig help texts, through LKDDb (cateee.net/lkddb) | spec/m9-plan.md:407 (Sources) |
| Debian 13's kernel configuration (`linux-headers-6.12.113+deb13-riscv64`; also 6.12.111) and the trixie-security archive's index | spec/m9-plan.md:408–409 (Sources); spec/debian-kernel.md:7, 9, 66, 68; spec/soc.md:563 |
| Debian's RISC-V wiki page and trixie's release notes | spec/m9-plan.md:419, 420 (Sources) |
| LWN, articles 885574, 877051, 936302 and 1022382 (the RISC-V PMU, Svpbmt, misaligned accesses, FWFT) | spec/m9-plan.md:410–411 (Sources) |
| LWN, article 1022531: AMD's `zynqmp_atb` patch series (May 2025), and a PYNQ forum thread | spec/soc.md:266–269, 277, 288 (§7.1) |
| The upstream ZynqMP and K26 device trees (`zynqmp-smk-k26-revA`) | spec/soc.md:595–596 (§8.2) |
| OpenSBI's documentation (`docs/pmu_support.md`, `docs/platform_requirements.md`; 1.9's generic platform and `fw_jump`) | spec/m9-plan.md:62–65, 91–92, 412–413 (Sources); spec/soc.md:1051 (Provenance); spec/uncore-periph.md:219 |
| OpenOCD's documentation (RISC-V commands); openocd.org | spec/m9-plan.md:279–281, 414 (Sources) |
| QEMU's RISC-V `virt` machine documentation (its memory map; `sifive,test0`) | spec/soc.md:245, 1046, 1054 (Provenance); spec/host.md:241 (Provenance); spec/uncore.md:44; DR-101; AP §11 (1289) |
| GCC 14.2's RISC-V options; gcc.gnu.org | spec/m9-plan.md:150, 417 (Sources) |
| glibc's NEWS; sourceware.org | spec/m9-plan.md:129, 152, 418 (Sources) |
| Spike's sources and headers, read as the lockstep reference's behaviour (§2) | spec/core-priv.md:103; spec/core-mmu.md:22, 29, 123; spec/core-pipeline.md:445, 462, 635; spec/verification.md:1322, 1325 |
| ACT4's environment and configurations (riscv-arch-test's act4 branch; Sail's reference configuration `sail-RVA20S64`) | spec/verification.md:1077, 1087, 1324 |
| riscv-tests' `tohost` and `fromhost` convention | spec/verification.md:1321 |
| litmus-tests-riscv (BSD-2-Clause) and herd's RISC-V model results | spec/m7-smt2-plan.md:187, 241; spec/verification.md:1245–1246, 1251–1274; DL 10-19 23:30 |
| Berkeley SoftFloat 3e and TestFloat 3e (J. R. Hauser), tools used as-is | spec/fpu.md:665, 876 (Provenance) |
| The licences: Solderpad Hardware License 2.1 (the SPDX list's text), Apache License 2.0 (apache.org's text), the REUSE specification; MIT considered and declined | spec/conventions.md:193–196 (§11); DR-018, DR-130, DR-138; AP §13 D7 (1334) |

**Named without a document:** Intel's E-core decode clusters (AP Appendix C; perf/dse_report.md:467), AMD's Bulldozer (AP §6.1), Intel's Hyper-Threading (AP Appendix A, beside Marr et al. above), and XiangShan's latency injection (AP §5.6).

## 4. Audit: the literature review's links into other projects' source trees

*Asked for by the coordinator on 2026-10-24, before the user rules on the wording (§7). Built only from our own files. No cited source file or page was opened, since that would itself break DR-138.*

**Scope:**
- every link into another project's repository tree in the ten notes of `research_notes/RISCV OoO soft cores for KV260/` and in the report built from them, `reports/RISCV OoO soft cores for KV260.md`, all of 2026-10-12;
- the link forms are GitHub `blob`, `tree` and `raw` links, `raw.githubusercontent.com`, GitHub API listings (`api.github.com`), one CDN mirror of a raw file, and one gitee repository.

**The count:**
- 70 distinct links. The report's 28 links all repeat the notes' links.
- The table has 68 rows, since Rocket's `RocketCore.scala` and `HellaCache.scala` each appear in both a blob and a raw form, and each pair gets one row.
- Repository front pages, issue trackers and commit pages are not counted. They point at a project, not into its tree. Among them is the rocket-chip-inclusive-cache link whose text says "Parameters.scala" (coherence_multicore.md lines 47, 288, 506).

**Kinds:**
- Repository: core or RTL source; a SoC generator or board support; documentation, slides or specifications; firmware or OS software.
- File: source code; a configuration or parameters file; a device tree; a directory or commit listing; documentation (a README, guide, manual, datasheet, slides or specification text).

**"Used by Tanager"** means the same fact or value appears in `docs/spec/`, `decisions.md` or the plan. A value that only coincides, where our files give its own basis, is marked as a coincidence.

**"Published equivalent"** names a paper, specification or vendor document that our own files cite for the same fact. A suggestion that is not in our files is marked so.

**Note names:**
- asic = `asic_ooo_cores.md`, coh = `coherence_multicore.md`, ipc = `ipc_levers_benchmarks.md`, kv = `kv260_platform.md`;
- lbc = `linux_baseline_cores.md`, lrv = `linux_requirements_verification.md`, mt = `multithreading_smt_cmt.md`, nax = `naxriscv_family.md`;
- R = the report.

### 4.1 What Tanager uses from these links

**From source code or configuration files of other cores and SoC generators:**

| Fact | Tanager text | From | Published equivalent |
|---|---|---|---|
| An 8-entry page-walk cache | Plan §4.10 (543) and §4.14 (614, basis "not modelled"), by way of lbc 299 and 416: "a PTE cache (Rocket has 8)". `core-mmu.md` line 80: `PWC_ENTRIES` is not used yet | Rocket's `RocketCore.scala` | **None in our files** |
| A 32-entry fully associative DTLB | Plan §4.10 (541), §4.14 (614, "not modelled"); built (core-mmu.md line 79) | Rocket's `RocketCore.scala` | Sá et al. (ar5iv 2302.02969) publish 32 entries as a CVA6 option (lbc 233–237) |
| A 2–4-line victim buffer at the L2 | Plan §5.1 (723), by way of R 315, which cites the 2-line default; the spec builds 4 (`N_WB`, l2.md) | SpinalHDL's coherent `Cache.scala`, the L2 of NaxRiscv and VexiiRiscv, which DR-138 names | **None in our files** |
| The L2 line's fields: tag, valid, dirty, a presence vector, a unique flag | l2.md (line 39) | SpinalHDL's `Cache.scala` and CoupledL2's `Directory.scala` (coh 303; R 296–299) | Credited by l2.md's Provenance to the TileLink specification and Sorin, Hill and Wood's *Primer* (chapter 8) |
| The 32 in "LR holds probes off for 32–64 cycles" | Plan §4.9 (534); the RTL holds 64 (core-lsu.md, line 171) | CVA5's `cva5_config.sv` (and VexiiRiscv's documentation) | VexiiRiscv's published documentation gives 32; Muntjac (arXiv 2206.06769) for bounded line locking (coh 197, 390) |
| The KV260's fan pin (A12) and PMOD pins (H12 for TXD, B10 for RXD), and the PL's clocks coming from the PS | soc.md lines 69, 78; plan §2.1 (166) | LiteX-boards' `xilinx_kv260.py` platform file | The fan pin: AMD's KV260 board files (soc.md line 1053) and the stock image's tree (DR-129). The clocks: AMD UG1085 v2.5 (kv 398). The PMOD pins: none, but [fpga/kv260/README.md](../fpga/kv260/README.md) (line 101) records them confirmed on the board |
| The PS's DDR range, `pl_clk0` at 100 MHz, UART1 at 115200 | soc.md lines 84, 253; firmware_switches.md line 78 (from the board) | LiteX-boards' `xilinx_kv260.py` target file | AMD DS987 v1.2 for the DDR4 and the console pins (kv 105, 163); the address ranges: none (suggestion, not in our files: UG1085's address map) |

**From OpenSBI's and Linux's source files** (software, which DR-192 has since covered for OpenSBI):
- **OpenSBI** (`sbi_domain.c`, `sbi_hart.c`, `sbi_hart_pmp.c`, `aclint_mtimer.c`):
  - The facts: the root domain's regions (firmware and the ACLINT M-only, the S/U catch-all last); PMP entries probed; one `sfence.vma` after programming; and the plan's PMP floor, "16 PMP CSRs with at least 8 working entries" (plan §2.2, 175).
  - Tanager's own evidence is OpenSBI's boot banner on the board (firmware_switches.md line 21; pmp-at-fill.md lines 42, 70, 82).
  - Published equivalent: the privileged specification's PMP rules, and its SFENCE.VMA rule (pmp-at-fill.md line 75).
- **Linux** (`arch/riscv/Kconfig`, `kernel/sbi.c`, `mm/init.c`, `drivers/clocksource/timer-riscv.c`, `drivers/irqchip/Kconfig`, `drivers/perf/riscv_pmu_sbi.c`):
  - The facts: what the kernel needs and does. A is required; misaligned accesses are probed and emulated; non-coherent DMA needs Zicbom; SBI 0.2 or later; the Sv57-to-Sv39 probe; the Sstc timer; the PLIC and INTC drivers; sampling needs Sscofpmf.
  - Tanager text: debian-kernel.md lines 20, 22, 50–59; plan §2.2 (171, 173, 182); m9-plan.md lines 56–57, 128; pmp-at-fill.md line 98; soc-d4-modes.md line 144.
  - Published equivalents for most of these:
    - Kconfig help texts (LKDDb) and Debian 13's kernel configuration (m9-plan.md Sources);
    - the SBI specification, the Supervisor-level ISA, the RVA profiles and LWN;
    - board logs.
  - The probe order and the timer driver's rating have none.
- **The KV260's own device-tree overlay in Linux** (`zynqmp-sck-kv-g-revB.dtso`):
  - The facts: UART1 on MIO 36–37, GEM3 with a DP83867 at MDIO address 1, SD1 without 1.8 V, the USB hub.
  - Tanager text: soc-d5-gem3.md lines 7–12; firmware_switches.md line 109; soc.md lines 593, 658; plan §2.1 (166).
  - Tanager also read the same facts from the A53's live tree on the board (soc-d5-gem3.md line 7).
  - Published equivalents: AMD UG1089 v1.3 and DS987 v1.2 (kv 75–105).

**From documentation kept inside other projects' repositories** (manuals, datasheets, slides, READMEs, specification texts):
- **"No Owned state in L1; the L2 absorbs dirty data on a downgrade"** (plan §5.2, 728): C910's split of MESI at L1 and MOESI at L2, from OpenC910's user manual (coh 149, 230; R 301). For the L2's MOESI, the published equivalents are the Xuantie-910 paper (ISCA 2020) and its Hot Chips 32 talk (asic 241–243). For the L1's MESI, none.
- **The SMT checklist's rules** (plan §6.3, 803 → threading.md):
  - The rules: every trap and xRET clears an LR reservation (core-priv.md line 76; DR-047); a sibling's stores clear it (threading.md line 15); the interrupts are per hart (interfaces.md lines 111–112); one `mtgsmt` a core (core-pipeline.md line 430).
  - Source: VeeR EH2's programmer's manual, through the notes' checklist (mt 457–466). None of it is attributed to VeeR in `docs/`.
  - Published equivalents: the A extension, the privileged specification, and the ACLINT specification for per-hart timers and IPIs.
- **NaxRiscv's slides** (SpinalDoc's RISC-V Week Paris 2022 and 37C3 decks):
  - The facts:
    - its 10-cycle mispredict penalty is a best case (plan §0, 95; §4.14, 615);
    - a predicted hit that misses flushes everything (plan §0, 98; Appendix A, 1383);
    - the page-offset-first store check (plan §4.9, 525, not attributed);
    - its dual-core Debian at 100 MHz (plan §0, 119);
    - a coherence bug after about 3.6 × 10¹¹ cycles (plan Appendix A, 1403).
  - The slides are published presentations. §2 and §3.5 list them with NaxRiscv's documentation.
- **VexiiRiscv's documentation sources** (`Memory/index.rst`, `Soc/litex.rst`):
  - The facts: the LR hold (above), near AMOs on a unique line (plan §5.3, 735; core-lsu.md lines 128–129), and a coherent DMA port on the L2 (plan §5.4, 752).
  - The same text is published as VexiiRiscv's Read the Docs pages (nax 459; R 195).
- **OpenSBI's documentation** (`docs/firmware/fw.md`, `docs/platform/generic.md`, `docs/platform_requirements.md`, `docs/pmu_support.md`):
  - The facts: `fw_jump`'s fixed hand-off (a0 = hart ID, a1 = the tree); the generic, device-tree-driven platform; the ISA floor and the time CSR; the `riscv,pmu` node.
  - Tanager text: firmware_switches.md lines 19, 21, 40–41; uncore-periph.md lines 24, 219; plan §2.2 (171, 173) and §5.4 (743); m9-plan.md lines 62–63.
  - Tanager cites OpenSBI's documentation itself (soc.md Provenance; m9-plan.md Sources).
- **Specification texts in their own repositories:**
  - ACLINT (`riscv-aclint.adoc`): per-hart `msip` and `mtimecmp`, a shared `mtime` (uncore-periph.md lines 24–34);
  - the Profiles (`profiles.adoc`, `rva23-profile.adoc`): plan §1 (149), §4.1 (324, 328); m9-plan.md lines 93, 106, 144–145;
  - Linux's CPU binding (`cpus.yaml`): firmware_switches.md line 44;
  - dt-schema's `reserved-memory.yaml` (`no-map`): soc.md line 253, pmp-at-fill.md line 43.
  - Each is the published specification itself, which Tanager cites as such (§3.1).

**Values that only coincide** (Tanager gives its own basis):
- XiangShan's MinimalConfig: ROB 48, 10-entry queues, LQ 24 and SQ 20, a 32 KiB 8-way L1D, 4 MSHRs. Ours come from the M1 sweep, the SMT2 study and DR-149.
- BOOM's MediumBoom sizes and FTQ 32.
- Rocket's 16 KiB 4-way fallback L1s and one MSHR.
- C910's 1 MiB L2 and 128-bit AXI, and C906's 32 KiB L1s and PMP 8/16.
- VexiiRiscv's 3.04 CoreMark/MHz against our M2 RTL's 3.04.

**Not used by Tanager:** the remaining links (the "No" rows below). They are about other projects' configurations, history, clocks, test setups and build systems, and nothing in `docs/` takes from them.

### 4.2 Every link

**A. Source and configuration files of cores, SoC generators and board support**

| # | Repository | File in the link | Kind | Cited at | What the note took | Used by Tanager | Published equivalent |
|---|---|---|---|---|---|---|---|
| A1 | chipsalliance/rocket-chip | `src/main/scala/rocket/RocketCore.scala` (blob and raw) | core RTL; source (its `RocketCoreParams`) | coh 49, 388; lbc 82, 243, 245, 352; R 321 | LR held up to 80 cycles, then 3 back; no fast byte loads; Sv39, 8 PMP, no L2 TLB, an 8-entry PTE cache, a 32-entry DTLB | **Yes:** the 8-entry page-walk cache and the 32-entry DTLB (§4.1). The LR hold: no (ours is 64, no back-off) | PTE cache: none. DTLB: Sá et al. Sv39 and PMP: the privileged spec 1.13 |
| A2 | chipsalliance/rocket-chip | `src/main/scala/rocket/HellaCache.scala` (blob and raw) | core RTL; source | coh 49; lbc 83, 243, 244, 352; R 91, 109 | The cache's comment on LR/SC loops; a 3-cycle block; D$ defaults: 16 KiB 4-way, random replacement, 1 MSHR, store-data 17, replay 16 | No. Coincidences: the 16 KiB 4-way fallback L1s (plan §4.11, 557), the one-MSHR switch (core-lsu.md) | The LR/SC rule: the ISA manual (coh 362–370). The rest: none |
| A3 | chipsalliance/rocket-chip | `src/main/scala/rocket/BTB.scala` (raw) | core RTL; source (defaults) | lbc 81, 352; R 91, 109 | 28-entry fully associative BTB, 6-entry RAS, 512-entry BHT; the BHT and RAS used only on a BTB hit | No (ours: a 64-entry micro-BTB, TAGE-lite, a 32-entry RAS; plan §4.14, 600) | None (suggestion, not in our files: the Rocket Chip Generator report, UCB/EECS-2016-17) |
| A4 | OpenXiangShan/CoupledL2 | `src/main/scala/coupledL2/Directory.scala` | core RTL; source | coh 138, 261 | Per-line state, a presence bit per client, alias, prefetch, accessed and ECC bits | The mechanism only (§4.1, the L2 line's fields); none of the extra bits | The *Primer* (l2.md); the BP-BedRock dissertation (arXiv 2505.00962) |
| A5 | OpenXiangShan/CoupledL2 | `src/main/scala/coupledL2/L2Param.scala` | core RTL; configuration | coh 139, 289, 506, 507 | Defaults: 4 ways × 128 sets, 16 MSHRs, DRRIP, 32-byte beats, optional CHI | No (ours: 1024 sets × 8 ways, 24 MSHRs a bank, tree PLRU, 128-bit beats) | None (suggestion, not in our files: Jaleel et al., ISCA 2010, for RRIP) |
| A6 | SpinalHDL/SpinalHDL | `lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Cache.scala` (dev) | RTL library (NaxRiscv's and VexiiRiscv's L2); source | coh 190, 260, 290, 506; R 315 | Per-line valid, tag, dirty, trunk and owners; 8 slots, 8 probe slots, 4 A buffers, a 2-line victim buffer | **Yes:** the victim buffer's "2–4 lines" and the line's fields (§4.1) | The fields: the *Primer*. The victim buffer: none |
| A7 | SpinalHDL/SpinalHDL | `lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Hub.scala` | RTL library; source | coh 190 | A data-less hub variant exists | No | None |
| A8 | openhwgroup/cva5 | `core/types_and_interfaces/cva5_config.sv` (raw) | core RTL; configuration | lbc 25, 201, 283, 294, 371 | Example configuration: 2-way 64-entry TLBs, a 32-cycle LR wait, an 8-word line reservation, 16 KiB 2-way caches, a 4-entry SQ | **Weakly:** the 32 of "32–64 cycles" (§4.1). The line-sized reservation is Za64rs (plan §4.1, 324) | Za64rs: the ISA manual. CVA5's design: its SFU thesis (lbc 111) |
| A9 | OpenXiangShan/XiangShan | `src/main/scala/top/Configs.scala` (raw) | core RTL; configuration | asic 212 | MinimalConfig: 6-wide, ROB 48, FTQ 8, 10-entry queues, LQ 24/SQ 20, a 32 KB 8-way D$, 4 MSHRs | Coincidences only (§4.1) | None |
| A10 | OpenXiangShan/XiangShan | `src/main/scala/xiangshan/mem/mdp` (GitHub API listing) | core RTL; directory listing | asic 201 (fact at 198) | From its file names: a store-set unit and a wait table | Not attributed; the same mechanisms (plan §4.9, 527; m9-plan.md §5) | Partly: "Microarchitecture Cliffs" (arXiv 2602.11580) on XiangShan's store sets (ipc 162) |
| A11 | OpenXiangShan/XiangShan | `src/main/scala/xiangshan/mem/lsqueue` (GitHub API listing) | core RTL; directory listing | asic 201 (fact at 199) | From its file names: a load queue split into virtual, RAR, RAW, replay and uncached queues | No | None |
| A12 | OpenXiangShan/XiangShan | `src/main/scala/xiangshan/backend/issue` (GitHub API listing) | core RTL; directory listing | asic 201 (fact at 200) | From its file names: issue queues with age detectors | No (plan Appendix A, 1382, credits Wong for age matrices) | None |
| A13 | riscv-boom/riscv-boom | `src/main/scala/v3/common/config-mixins.scala` (raw) | core RTL; configuration | asic 82, 87; R 65, 476 | Small to Giga: MediumBoom 2-wide, ROB 64, queues 12/20/16, PRF 80/64, LQ/SQ 16/16, FTQ 32, TAGE-L | Coincidences only (FTQ 32, plan §4.14, 599, basis E1; draft 0.3's ROB 64 and LQ/SQ 16) | None for the sizes (SonicBOOM, CARRV 2020, gives widths and TAGE) |
| A14 | riscv-boom/riscv-boom | `src/main/scala` (GitHub API listing) | core RTL; directory listing | asic 117 | v3 and v4 source trees side by side | No | None |
| A15 | riscv-boom/riscv-boom | `commits?path=src/main/scala/v4` (GitHub API commit list) | core RTL; commit list | asic 126, 720, 726 | v4's history, 2024–2026 | No | None |
| A16 | ucb-bar/chipyard | `fpga/src/main/scala/vcu118/Configs.scala` (raw) | SoC generator; configuration | asic 128, 502; used at R 65 without the link | BOOM's FPGA build is MegaBoomV3 at 50 MHz; Rocket at 100 MHz | No | None |
| A17 | ucb-bar/chipyard | `fpga/src/main/scala/arty100t/Configs.scala` (raw) | SoC generator; configuration | asic 503 | Rocket only, at 50 MHz | No | None |
| A18 | eugene-tarassov/vivado-risc-v | `board/rocket-freq` | SoC builds for Xilinx boards; configuration | kv 362, 401 | Per-board clocks: Rocket 100–160 MHz, BOOM 31.25–50 MHz | No | None |
| A19 | openhwgroup/cva6 | `corev_apu/fpga/constraints` (tree) | core RTL; constraint-file listing | kv 363 | Constraint files for six boards, none a Zynq UltraScale+ | No | None |
| A20 | litex-hub/litex-boards | `litex_boards/platforms/xilinx_kv260.py` | board support; source (pins) | kv 114, 400; R 373 | The part; the fan on A12; the PMOD's pins; no PL clock without the PS | **Yes** (§4.1) | AMD's board files, the stock image, UG1085, DS987; the PMOD pins: the board |
| A21 | litex-hub/litex-boards | `litex_boards/targets/xilinx_kv260.py` | board support; source | kv 163, 347, 400; R 382 | DDR4's ranges, `sys_clk` 100 MHz from the PS, UART1 at 115200; LiteX runs on the A53 | The same values, measured on the board (§4.1) | DS987 v1.2; the ranges: none |
| A22 | litex-hub/litex-boards | `litex_boards/targets/xilinx_zcu104.py` | board support; source | kv 349 | ZCU104's target: 125 MHz, PL-side DDR4, no PS | No | None |

**B. Documentation kept in core repositories**

| # | Repository | File in the link | Kind | Cited at | What the note took | Used by Tanager | Published equivalent |
|---|---|---|---|---|---|---|---|
| B1 | XUANTIE-RV/openc910 | `doc/openc910_datasheet.pdf` | core RTL; datasheet | coh 147, 507; R 285 | 2 cores, 12 stages, MOESI, a central snoop buffer, 64 KB L1s, a 1 MB 16-way L2, 128-bit AXI4 | Coincidences only (the 1 MiB L2, plan §5.1, basis E3; 128-bit AXI from the HP port) | Xuantie-910, ISCA 2020; Hot Chips 32 (asic 221–243) |
| B2 | XUANTIE-RV/openc910 | `doc/` (tree; its user manual) | core RTL; manual | coh 153, 286; R 301 | MESI at L1, MOESI at L2; the coherence unit; the INSDE bit | **Yes:** no Owned state in L1 (§4.1) | The L2's MOESI: ISCA 2020, Hot Chips 32. The L1's MESI: none |
| B3 | XUANTIE-RV/openc910 | `README.md` (raw) | core RTL; README | asic 272, 531 | What the repository holds; no FPGA flow | No | — |
| B4 | XUANTIE-RV/openc910 | the repository (GitHub API metadata) | core RTL; metadata | asic 272, 752 | Apache-2.0; created 2021, last pushed 2024 | No | — |
| B5 | XUANTIE-RV/openc906 | `doc/` (tree; its user manual) | core RTL; manual | lbc 271 | Sv39, a 128-entry jTLB, 32 KB L1s, a 16 Kb BHT, 128-bit AXI4, PMP 8/16 | Coincidences only | None |
| B6 | black-parrot/black-parrot | `docs/bedrock_guide.md` | core RTL; guide | coh 52 | BedRock's directory protocol family | No (ours is MESI) | The BedRock paper (arXiv 2211.06390) |
| B7 | chipsalliance/Cores-VeeR-EH2 | `docs/RISC-V_VeeR_EH2_PRM.pdf` (raw) | core RTL; programmer's manual | mt 250, 262, 290, 429; R 100, 115, 245 | Reservation clearing (SC, a sibling's store, a trap, mret); per-thread and per-core CSRs; per-thread interrupt pins | **Yes, unattributed,** through the SMT checklist (§4.1) | The A extension; the privileged spec; the ACLINT spec |
| B8 | openhwgroup/cva6 | `verif/README.md` | core RTL; README | lrv 592 | Its riscv-dv verification setup | No | None |
| B9 | SpinalHDL/NaxRiscv | `src/test/cpp/naxriscv/README.md` (raw) | core RTL; README | lrv 164, 547, 696; R 428 | Its Verilator Linux run loads `fw_jump`, the tree and the kernel directly; a 30-minute regression; Verilator 4.228 | No (Tanager's direct load and its Spike-as-a-library lockstep are not attributed to it) | NaxRiscv's Read the Docs simulation page (lrv 546) |
| B10 | riscv-boom/riscv-boom | `README.md` (raw) | core RTL; README | asic 127 | SonicBOOM's 6.2 CoreMark/MHz | No (the plan uses the paper's figures) | SonicBOOM, CARRV 2020 |
| B11 | OpenXiangShan/XiangShan | `README.md` via cdn.jsdelivr.net (branch kunminghu-v3) | core RTL; README | asic 219, 736 | Which XiangShan generations are maintained | No | — |
| B12 | SpinalHDL/VexiiRiscv | `doc/litex/debian` (tree) | core RTL; documentation folder | nax 483 | LiteX's Debian variant: 2 CPUs, coherent DMA, a 256 KB L2 | No | VexiiRiscv's Read the Docs LiteX page (coh 178) |

**C. Documentation, slides and specification repositories**

| # | Repository | File in the link | Kind | Cited at | What the note took | Used by Tanager | Published equivalent |
|---|---|---|---|---|---|---|---|
| C1 | SpinalHDL/SpinalDoc | `presentation/en/nax_040522/slides_nax_040522.pdf` | slides (RISC-V Week Paris, 2022) | nax 61, 88, 112, 138, 140, 195, 201, 220, 275–277, 348, 352; R 3, 17, 21 | NaxRiscv's 2022 configuration; a 10-cycle best-case mispredict; a full flush on a wrong hit guess; a two-pass store check; clocks and scores | **Yes** (§4.1) | It is a published presentation; the sizes are also on NaxRiscv's Read the Docs pages |
| C2 | SpinalHDL/SpinalDoc | `presentation/en/37c3_271223/37c3_271223.pdf` | slides (37C3, 2023) | nax 283, 359, 569, 576; R 285, 294 | Dual-core RV64GC Debian at 100 MHz; a coherence bug after about an hour | **Yes:** plan §0 (119), Appendix A (1403) | Itself |
| C3 | SpinalHDL/SpinalDoc | `presentation/en/coscup_2024/coscup_2024.pdf` | slides (COSCUP 2024) | nax 479 | Four VexiiRiscv cores, a 256 KB L2, about 65K LUTs at 100 MHz | No | Itself |
| C4 | SpinalHDL/SpinalDoc | `presentation/en/orconf_2024/orconf_2024.pdf` | slides (ORConf 2024) | nax 477, 519; R 98 | Four VexiiRiscv cores on an Efinix Ti375; 3.04 CoreMark/MHz | No (the 3.04 coincides with our M2 RTL) | Itself |
| C5 | SpinalHDL/SpinalDoc | `presentation/en/riscv_sc_2024/riscv_sc_2024.odp` | slides (2024) | nax 337, 477, 587; R 285, 489 | Why VexiiRiscv; quad-core Debian at 200 MHz; an inclusive MESI L2 | No | Itself |
| C6 | SpinalHDL/VexiiRiscv-RTD | `source/VexiiRiscv/Memory/index.rst` | documentation source | coh 168–170, 177, 183, 272, 292, 389, 504; R 321 | MESI by permission; near AMOs on a unique line; a 32-cycle LR lock with toggling; slot counts | **Mechanisms:** the LR hold, near AMOs (§4.1) | The same page as published (nax 459; R 195); Muntjac (arXiv 2206.06769) |
| C7 | SpinalHDL/VexiiRiscv-RTD | `source/VexiiRiscv/Soc/litex.rst` | documentation source | coh 178 | LiteX's dual-core Debian SoCs with a coherent DMA option | **The mechanism, unattributed:** a coherent DMA port on the L2 (plan §5.4, 752) | NaxRiscv's 37C3 slides; its Read the Docs hardware page |
| C8 | riscv/riscv-aclint | `riscv-aclint.adoc` | specification | mt 226, 427; R 242 | Per-hart `mtimecmp` and `msip`, a shared `mtime` | **Yes** (uncore-periph.md; m7-smt2-plan.md line 41) | The ACLINT specification v1.0, which Tanager cites |
| C9 | riscv/riscv-profiles | `src/profiles.adoc` | specification | lrv 38, 239, 242, 243, 348, 349, 429 | RVA20 and RVA22's sets; Zicclsm; Zkt | **Yes** (plan §4.1; m9-plan.md lines 106, 144) | The ratified Profiles (m9-plan.md Sources) |
| C10 | riscv/riscv-profiles | `src/rva23-profile.adoc` | specification | lrv 247, 327, 348, 349 | What RVA23U64 and S64 add | **Yes** (plan §1, 149; m9-plan.md lines 93, 145) | The RVA23 profile 1.0 |
| C11 | devicetree-org/dt-schema | `dtschema/schemas/reserved-memory/reserved-memory.yaml` | binding schema | kv 286; R 378 | `no-map` reserved regions | **Yes** (soc.md line 253; pmp-at-fill.md line 43) | Linux's boot requirements, partly (lrv 48); suggestion, not in our files: the Devicetree Specification |

**D. Firmware, operating-system and build-system repositories**

| # | Repository | File in the link | Kind | Cited at | What the note took | Used by Tanager | Published equivalent |
|---|---|---|---|---|---|---|---|
| D1 | riscv-software-src/opensbi | `docs/domain_support.md` (raw) | firmware; documentation | lrv 129 | Domain regions may overlap; the smallest wins | Partly (pmp-at-fill.md line 70, the ordering's effect) | None for the rule |
| D2 | riscv-software-src/opensbi | `docs/firmware/fw.md` (raw) | firmware; documentation | lrv 158, 470 | `fw_jump`'s fixed next stage; a0 = hart ID, a1 = the tree; `FW_TEXT_START` | **Yes** (firmware_switches.md line 19; uncore-periph.md line 219) | OpenSBI's documentation, which Tanager cites; Linux's RISC-V boot requirements (lrv 41–46) |
| D3 | riscv-software-src/opensbi | `docs/firmware/fw_dynamic.md` (raw) | firmware; documentation | lrv 158 | `fw_dynamic`'s run-time information in a2 | No (`FW_DYNAMIC=n`) | — |
| D4 | riscv-software-src/opensbi | `docs/platform/generic.md` (raw) | firmware; documentation | lrv 82; R 400 | The generic platform is driven by the device tree | **Yes** (firmware_switches.md lines 19, 21; uncore-periph.md line 24; plan §2.2, 173) | OpenSBI's documentation (soc.md Provenance) |
| D5 | riscv-software-src/opensbi | `docs/platform_requirements.md` (raw) | firmware; documentation | lrv 104, 271, 472; R 407 | The ISA floor; the time CSR optional (emulated if absent) | **Yes** (plan §2.2, 171; pmp-at-fill.md line 118; soc-d4-modes.md lines 138, 144) | Cited by Tanager itself (m9-plan.md Sources) |
| D6 | riscv-software-src/opensbi | `docs/pmu_support.md` (raw) | firmware; documentation | lrv 332 | The SBI PMU needs a `riscv,pmu` node | **Yes** (m9-plan.md lines 62–63; firmware_switches.md lines 40–41) | Cited by Tanager itself; the `riscv,pmu` binding |
| D7 | riscv-software-src/opensbi | `lib/sbi/sbi_domain.c` (raw) | firmware; source | lrv 125 | The root domain's regions | **Yes,** as the board's boot log shows them (firmware_switches.md line 21; pmp-at-fill.md line 42) | None (suggestion, not in our files: domain_support.md's root-domain section) |
| D8 | riscv-software-src/opensbi | `lib/sbi/sbi_hart.c` (raw) | firmware; source | lrv 112, 121, 325, 332, 340, 442, 467; R 408 | Boot-time probes: the PMP count, grain and address bits, `menvcfg`, writable counters | Partly (core-mmu.md line 51, the PMP count probed; m9-plan.md line 56) | The privileged spec's PMP rules |
| D9 | riscv-software-src/opensbi | `lib/sbi/sbi_hart_pmp.c` (raw) | firmware; source | lrv 131, 448; R 404 | One entry per region; "insufficient PMP entries"; one `sfence.vma` | **Yes** (pmp-at-fill.md line 82; firmware_switches.md line 21; plan §2.2, 175) | The privileged spec §3.7, for the fence |
| D10 | riscv-software-src/opensbi | `lib/utils/timer/aclint_mtimer.c` (raw) | firmware; source | lrv 130 | The timer's registers as M-only regions | **Yes** (firmware_switches.md line 21; soc.md line 190) | None |
| D11 | torvalds/linux | `Documentation/devicetree/bindings/riscv/cpus.yaml` (raw) | OS; binding schema | lrv 76 | The CPU node's properties | **Yes** (firmware_switches.md line 44; soc.md lines 177, 1052) | The binding itself, which Tanager cites (m9-plan.md Sources) |
| D12 | torvalds/linux | `arch/riscv/Kconfig` (raw) | OS; build configuration | lrv 53, 58, 61, 62, 66, 67, 267, 309, 355; R 402 | A required; FPU and C optional; misaligned accesses emulated; Zicbom and Zicboz uses | **Yes** (debian-kernel.md lines 50, 54, 58; m9-plan.md line 128; plan §2.2, 171) | Kconfig help texts (LKDDb) and Debian's configuration (m9-plan.md Sources) |
| D13 | torvalds/linux | `arch/riscv/kernel/cpufeature.c` (raw) | OS; source | lrv 68, 269, 321, 339 | How the kernel parses the tree's ISA properties | No | — |
| D14 | torvalds/linux | `arch/riscv/kernel/sbi.c` (raw) | OS; source | lrv 88 | The SBI extensions it probes; v0.1 only with its option | **Yes** (debian-kernel.md lines 22, 59; plan §2.2, 173) | The SBI specification; RISC-V BRS 1.0 (lrv 95–100) |
| D15 | torvalds/linux | `arch/riscv/mm/context.c` (raw) | OS; source | lrv 408; R 409 | The ASID allocator's threshold | No (plan's 16 ASID bits rest on the note's advice and C910's paper) | The Supervisor-level ISA; ISCA 2020 for C910's 16-bit ASID |
| D16 | torvalds/linux | `arch/riscv/mm/init.c` (raw) | OS; source | lrv 47, 404, 468; R 397 | The Sv57, Sv48, Sv39 probe; `satp` must ignore unsupported modes | **Yes** (debian-kernel.md line 56; plan §2.2, 182) | The rule: the Supervisor-level ISA (lrv 403). The order: none |
| D17 | torvalds/linux | `drivers/clocksource/timer-riscv.c` (raw) | OS; source | lrv 151, 324; R 415 | Sstc's compare written directly; the vDSO's time | **Yes,** from board logs (pmp-at-fill.md line 98; soc-d4-modes.md line 144) | Sstc in the privileged spec; BRS |
| D18 | torvalds/linux | `drivers/irqchip/Kconfig` (raw) | OS; build configuration | lrv 155 | The mainline interrupt controllers | Partly (debian-kernel.md line 20) | Debian's configuration; the bindings; the PLIC spec |
| D19 | torvalds/linux | `drivers/perf/riscv_pmu_sbi.c` (raw) | OS; source | lrv 328; R 416 | Sampling needs Sscofpmf; `perf_user_access` | **Yes** (plan §4.1, 326; m9-plan.md lines 56–57, from the board's log; verification.md line 808) | Sscofpmf in the privileged manual; the SBI PMU; LWN 885574 |
| D20 | torvalds/linux | `arch/arm64/boot/dts/xilinx/zynqmp-sck-kv-g-revB.dtso` | OS; device tree | kv 93, 104; R 373 | The KV260's PS peripherals: UART1's pins, GEM3's PHY at MDIO 1, SD1 without 1.8 V, the USB hub | **Yes,** and read again from the board's live tree (§4.1) | AMD UG1089 v1.3, DS987 v1.2; the PHY address: none |
| D21 | buildroot/buildroot | `arch/Config.in.riscv` (raw) | build system; configuration | lrv 172, 268 | The ABIs and their needs | No | — |
| D22 | riscv-software-src/riscv-pk | `machine/` (tree) | firmware; source listing | lrv 270 | The Berkeley Boot Loader's emulation sources | No | — |
| D23 | XS-GEM5 (gitee, mingyuncode) | the repository | simulator | ipc 450 | Said to be calibrated against Kunminghu | No | arXiv 2602.11580 (ipc 446–449) |

### 4.3 Notes on the report

- **Citations that don't match the notes:**
  - R 400 cites OpenSBI's `generic.md` for the boot hand-off; the notes take it from Linux's boot requirements and OpenSBI's `fw.md`.
  - R 404 cites `sbi_hart_pmp.c` for the timer's M-only regions; the notes take that from `aclint_mtimer.c`.
  - R 407's vDSO clause comes from `timer-riscv.c`, not from `platform_requirements.md`.
- **Facts whose only source in the notes is a link into a source tree:**
  - "MegaBoom at 50 MHz on VCU118" (R 65), from Chipyard's configuration (A16), which the report does not link;
  - XiangShan's store sets with a wait table and its split RAR and RAW queues (R 67, 79), from the directory listings A10–A11;
  - CoupledL2's directory in its tags (R 282), from A4.

  Tanager uses none of these three.

## 5. Third-party firmware and software the release builds

The release image of record is rc3u095r's `p1:/tanager/` (the M8 release image, 10-23; [firmware_switches.md](spec/firmware_switches.md)). It holds `fw_jump.bin` `62349a65…`, `payload.bin` `459992b8…`, `tanager.dtb` `18afd230…` and `tanager-h01.dtb` `15cd197c…`.
- **Pins and checks:** versions are pinned in [sw/versions.sh](../sw/versions.sh), with SHA-256 sums recorded at the first download and checked on every fetch (`sw/sha256sums`).
- **Third-party source** is fetched at build time and never committed (conventions §11).
- **Licences:** each one below is as the project's own licence files state it. Every one was read on the build host on 2026-10-24:
  - **OpenSBI, U-Boot and Buildroot:** in their fetched trees (DR-192 covers reading OpenSBI and U-Boot);
  - **Linux:** the kernel's `COPYING`, in the Linux 6.18.56 tarball;
  - **The Bootlin toolchains:** their `summary.csv`, which is Buildroot's licence record of each package and names its licence files;
  - **The xPack toolchain:** its `distro-info/licenses/` folders.
  - **Still to read:** only Debian's own copyright file for the board's kernel package, which is not on the build host (§7).

| Component | Version | Our changes | Licence | Where |
|---|---|---|---|---|
| **OpenSBI** | 1.9 (released 2026-07-01) | **Patch set tg1:** one patch, `sw/buildroot/patches/opensbi/0001-lib-sbi_ipi-skip-harts-that-cannot-take-an-IPI.patch`. Remote fences and S-mode IPIs skip the domain's harts that cannot take an IPI (stopped, starting, stopping), instead of failing the whole call. It was written from the SBI specification and the behaviour seen on the board. The build is upstream's `generic` platform with `fw_jump` and no Tanager Kconfig fragment | BSD-2-Clause (its `COPYING.BSD`) | `sw/build_opensbi.sh`; firmware_switches.md §OpenSBI; soc.md §5; DR-099, DR-147, DR-192 |
| **U-Boot** | 2026.07 | **None in the code:** configured only, `sw/uboot/tanager.config` over `qemu-riscv64_smode_defconfig`. It runs in S-mode after OpenSBI's `fw_jump` | GPL-2.0; most of it also under any later version, with per-file exceptions (its `Licenses/README`) | `sw/build_uboot.sh`; firmware_switches.md §U-Boot; DR-147, DR-192 |
| **Linux, on the board** | Debian 13's own riscv64 kernel package (6.12) | **None** (DR-147). `tanager-ps-dkms` builds the processor side's missing drivers from Debian's own `linux-source` (DR-168) | The kernel's: `GPL-2.0 WITH Linux-syscall-note`, the GPL version 2 only (its `COPYING`, read in 6.18.56's tarball). Debian's copyright file for the package, `/usr/share/doc/linux-image-6.12.113+deb13-riscv64/copyright`, is to read on the board | `sw/build_debian.sh`; debian-kernel.md |
| **Linux, in simulation** | 6.18.56 (longterm, released 2026-10-11), with Buildroot | None | `GPL-2.0 WITH Linux-syscall-note` (its `COPYING`) | `sw/build_linux.sh`; DR-099 |
| **Buildroot** | 2026.08 (stable, released 2026-09-04) | Our defconfigs (`sw/buildroot`) | GPL-2.0-or-later, with the exceptions its `COPYING` lists | DR-099 |
| **Debian 13 (trixie)** | snapshot.debian.org 20261015T000000Z | Unmodified packages; the image is assembled by `sw/build_debian.sh` | Each package's own (Debian's free-software guidelines) | DR-147, DR-168 |
| **Bootlin toolchain, riscv64** | `riscv64-lp64d--glibc--stable-2026.08-1`: GCC 15.3.0, glibc 2.44, binutils 2.45.1, kernel headers 5.10.269 | None | From its `summary.csv`:<br>• GCC's target libraries: `GPL-3.0-with-GCC-exception` (`COPYING.RUNTIME`); the compiler itself: GPL-2.0, GPL-3.0, LGPL-2.1, LGPL-3.0;<br>• glibc: GPL-2.0+ for its programs; LGPL-2.1+, BSD-2-Clause, BSD-3-Clause and other permissive licences for the library;<br>• binutils: GPL-3.0+, GPL-2.0+, LGPL-2.1+;<br>• the kernel headers: GPL-2.0 | DR-099 |
| **Bootlin toolchain, aarch64** (for `tanager-host`, the A53 program) | `aarch64--musl--stable-2026.08-1`: GCC 15.3.0, binutils 2.45.1, musl 1.2.6 | None | From its `summary.csv`:<br>• musl: MIT (`COPYRIGHT`);<br>• GCC, binutils and the kernel headers as above | `sw/versions.sh` |
| **xPack GNU RISC-V toolchain** | `riscv-none-elf-gcc` 15.2.0-1: GCC 15.2.0, binutils 2.45, newlib 4.5.0 | None | From its `distro-info/licenses/`:<br>• GCC: the GPL version 3 (`COPYING3`) with the GCC Runtime Library Exception 3.1 (`COPYING.RUNTIME`);<br>• binutils: the GPL version 3 (`COPYING3`);<br>• newlib: a collection of licences from its several sources (`COPYING.NEWLIB`) | `tools/versions.sh`; plan Appendix C |

What is ours, under our licences (§6):
- the device trees (`sw/dts`);
- the boot ROM (`sw/bootrom`);
- U-Boot's configuration fragment and the boot script (`sw/d4mode`);
- `tanager-host`;
- the Debian image's own scripts and the DKMS package's build files.

The A53's own boot firmware is not changed: the QSPI keeps `K26-BootFW-01.02` in both slots (firmware_switches.md).

## 6. Our own licences

- **The split** (DR-018, DR-130; [REUSE.toml](../REUSE.toml); [LICENSE](../LICENSE)): hardware is under the Solderpad Hardware License 2.1; software and documentation are under the Apache License 2.0. Licensing is by path through `REUSE.toml`.
  - **Hardware** means the RTL, the FPGA design and build files, constraints, the PL's device-tree overlays and the HDL test benches.
  - **Software** means host software, scripts, tools, models, tests in C, C++, Python and assembly, and documentation.
- **Vivado's reports** kept under `fpga/**/results/` carry AMD's notices and are not licensed by the project (`LicenseRef-Vivado-Generated-Report`).
- **Third-party source is never in the repository:** benchmarks, firmware, the kernel and the tools are fetched at build time (conventions §11).

## 7. Open points for the user

1. **The literature review's links into other projects' source trees (§4).**
   - The 10-12 notes link 70 times into other projects' trees, as plan §2.3 then allowed for parameter values. DR-138 ended any reading of other projects' source two days later.
   - Of the facts taken from source or configuration files, Tanager uses five from cores and SoC generators, and the board pins from LiteX's KV260 files (§4.1).
   - Two of them have no published equivalent in our files:
     - Rocket's 8-entry page-walk cache (plan §4.10, not built yet);
     - the "2–4-line" L2 victim buffer, from SpinalHDL's cache, which is NaxRiscv's L2, the very L2 DR-138 names.
   - The others are published as well, coincide with values our own studies chose, or were measured on the board. OpenSBI's and Linux's source files are firmware and the operating system, not a CPU's design.
   - The statement's wording of this is the user's to decide. One way to clean it is to re-derive the two from a published source or from our own model before the release, and record their basis in the plan.
2. **Spike's sources, read as the lockstep reference's behaviour (§2).** Plan §2.3 treats Spike as a tool used as-is, and the specs read its CSR, walk and PMP code so that the lockstep compares. Whether the published claim names this as an exception to DR-138, as DR-192 does for firmware, is the user's to decide.
3. **The processor side's and the firmware's sources (§2).**
   - AMD's embeddedsw headers, AMD's `zynqmp_atb` patch series as LWN carried it, and the upstream ZynqMP device trees, all read for the board's PS registers. They are vendor material, and none describes the CPU, but the patch series and the device trees are Linux source.
   - pmp-at-fill.md (10-21) describes OpenSBI's internals two days before DR-192 allowed reading OpenSBI's code.
   - verification.md names Linux's `head.S`.
4. **Licences, confirmed.** §5's licences were read from each project's own licence files on the build host (2026-10-24). The one left is Debian's copyright file for the board's kernel package, to read on the board.
5. **Citations, completed from the literature review (2026-10-24).** The places that cite papers by name now carry the review's references:
   - plan Appendix A, which has a source list;
   - core-pipeline.md §15;
   - fpga_friendly.md;
   - m9-plan.md's Sources;
   - area_recovery.md §7.11.
   The review does not hold these, so they stay identifications: Smith and Pleszkun; Reinman et al.; Cortadella and Llabería; Moshovos et al.; Luo et al.; the original TAGE paper; ITTAGE; the load-wait table (§3.2). core-pipeline.md's `reports/m6-tage-design.md` is not in the repository.
