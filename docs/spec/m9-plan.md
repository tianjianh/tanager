# M9 plan: hardening and the v1 release

Status: draft — fpu-2 (for the coordinator) — 2026-10-23

## Purpose
M9's row in the plan (architecture_plan.md §11) reads "Sscofpmf/perf, Svpbmt, Zicbo*, misaligned hardware, store sets,
indirect predictor, virtio-net, debug module with OpenOCD, documentation", closing with the v1 release: the SMT2
dual-core, 2 cores × 2 harts. This plan takes each item in turn and gives:
- what it is in hardware;
- what Debian 13's kernel (6.12) and userland do with it, or lose without it;
- its cost per chip and its timing risk at our fill;
- its value under Linux;
- whether it can sit behind a switch, and what it depends on.

A recommendation follows: what M9 builds and in what order, what waits for v2, and the area that pays for it.

**The constraints:**
- **The chip is full.** The release chip rc2 is 112,360 LUTs (95.9%) and closes 100 MHz by only +0.296 / +0.188 ns
  in its two placements (devlog, rc2). The last placed report uses every CLB (hp1f: 14,640 of 14,640). Placement noise
  at this fill is ±0.3–0.6 ns. So every LUT M9 adds needs a source, and anything on a near-critical family is a risk.
- **DR-147:** a standard SBC running Debian's own kernel, with no kernel patches. Nothing below needs a patch: Debian's
  6.12 is built portable and detects every optional extension at run time from the device tree.
- **DR-154:** the coordinator decides trades under 1% performance and 1,200 LUTs a chip; larger ones go to the user.
  They are marked **[user]** below.
- **DR-138:** the Linux, OpenSBI and OpenOCD facts here come from published specifications and documentation only
  (Sources). No other project's RTL or source was read.

## Summary
| Item | Today | Linux 6.12 with it | LUTs a chip (estimate) | Timing risk | Recommendation |
|---|---|---|---|---|---|
| Sscofpmf + HPM counters | mcycle/minstret only | `perf record` sampling, per-event `perf stat` | 0.7–1.4K, +32 DSPs | low | **M9**, behind a switch; [user] if over 1.2K |
| Svpbmt | PBMT bits fault | nothing functional (coherent DMA, PMA devices); RVA22S64 conformance | 0.3–0.6K | low–medium | v2 |
| Zicbom | cbo.* illegal | nothing (all DMA coherent) | 0.6–1.0K | medium | v2 |
| Zicboz | cbo.* illegal | faster page zeroing in the kernel | 0.8–1.6K | medium | measure first; v1.x if clear_page matters |
| Zicbop | hints run as no-ops | nothing (6.12 has no Zicbop support) | 0 as now | — | nothing to build |
| Misaligned hardware | traps, OpenSBI emulates | rare in Debian (0 in smt2-study's 49 programs) | 1.6–3.0K | high | v2 [user]; count on the board first |
| Store sets | replay on violation | ≤ 0.08% of the boot; a 16-entry load-wait table +0.58% on the suite (Dhrystone +4.7%) | 0.1–0.3K (wait table); 1.2–2.0K (full) | medium | wait table: M9 candidate, the coordinator's call; full store sets v2 [user] |
| Indirect predictor | 64-entry micro-BTB | interpreters +47–98%, the suite +0.20% (smt2-study); the boot to measure | 0.2K + 2 BRAM | medium | **M9**: the 256-entry path table |
| virtio-net | stage C (development) | product uses GEM3 with Debian's `macb` | 0 | — | done; document |
| Debug module + OpenOCD | absent | halt, step, registers, memory over JTAG | 1.5–2.5K | low–medium | **M9**, development builds only [user] |
| Documentation | narrative README only | — | 0 | — | **M9** |
| Hardening found on the way | | | 0 | — | **M9**: trigger CSRs, device-tree ISA string |

## 1. Sscofpmf and performance counters
- **Hardware.**
  - Zihpm counters `mhpmcounter3`–`N` (with their user aliases), each selected by `mhpmevent3`–`N`.
  - Sscofpmf adds an overflow bit (OF) and per-mode inhibit bits (MINH, SINH, UINH) to each `mhpmevent`, `scountovf`
    (S-mode's copy of the OF bits) and the local counter-overflow interrupt LCOFI (mip/mie bit 13, delegable to S).
  - The fixed `mcycle`/`minstret` never overflow-interrupt, so sampling uses the programmable counters only.
- **Today:**
  - Only `mcycle` and `minstret` exist, per hart, as DSP48E2 pairs (`tg_dsp_ctr`, tg_csr.sv). The `mhpm*` CSRs read 0
    (core-priv.md).
  - On the board OpenSBI reports "MHPM Info: 0". Linux prints "16 firmware and 2 hardware counters" and "Perf
    sampling/filtering is not supported as sscof extension is not available" (fpga/kv260/board/dr187b).
- **Linux 6.12 (Debian sets `RISCV_PMU_SBI=y`, `PERF_EVENTS=y`):**
  - The driver reaches the counters through the SBI PMU extension. With programmable counters and an event map,
    `perf stat` counts each mapped event. Without Sscofpmf, mode modifiers are only hints and `perf record` cannot
    sample hardware events (it falls back to timer-based `cpu-clock`). With Sscofpmf, sampling and mode filtering work.
  - OpenSBI needs the device tree's `riscv,pmu` node (`riscv,event-to-mhpmevent`, `riscv,event-to-mhpmcounters`,
    optionally raw events) or it leaves the PMU extension off. The SBI cycles and instructions events must also map
    to programmable counters, or the default `perf record` (cycles) gets no samples.
  - The SBI firmware counters already work today; they count OpenSBI's misaligned-access emulations, among others
    (§5).
  - Debian's default `perf_event_paranoid` is 3 (`SECURITY_PERF_EVENTS_RESTRICT`), so unprivileged perf needs a
    sysctl.
- **Userland:** `perf` (stat, record, report) for users and for us. Profiling the board today needs simulation binds
  (perfmodel/scripts/rtlprof). There is no hwprobe key for Sscofpmf.
- **The proposal:** 4 programmable counters a hart, with about 12 events:
  - cycles and instructions retired (for sampling);
  - branch mispredicts;
  - I$, D$ and L2 misses;
  - ITLB and DTLB misses;
  - load replays;
  - rename and dispatch stall cycles;
  - plus mode inhibit, OF, LCOFI and scountovf.
  - Each event is a registered pulse per hart. Shared units (D$, L2) attribute by the requesting thread.
- **Cost (from tg_csr):**
  - The counters reuse `tg_dsp_ctr`: 16 counters, 32 DSPs (about 1,090 are free).
  - LUTs:
    - each counter's event select and inhibit, about 10 LUTs (160 a chip);
    - the CSR read multiplexer for 8 more counter and 8 event CSRs a core (the larger part, 200–400 a core);
    - OF, LCOFI and scountovf (about 40 a core);
    - event wiring.
  - About 0.7–1.4K LUTs and 300 FFs a chip. The upper end crosses DR-154's 1,200: **[user]** if the prototype measures
    over it.
- **Timing risk:** low. The counters are DSPs, events are registered, and CSR reads are serialised.
- **Switch:** yes (`TG_HPM` 0: the counters read 0, as now).
- **Depends on:** the device tree's `riscv,pmu` node and `sscofpmf` in `riscv,isa-extensions` (soc-2's trees), and
  OpenSBI's PMU support (present).
- **Value:** developer tooling, not function. It is mandatory in RVA23S64 (Sscofpmf) and RVA22U64 (Zihpm).

## 2. Svpbmt
- **Hardware:** leaf PTE bits 62:61 select PMA (0), NC (1, non-cacheable, idempotent) or IO (2, non-cacheable,
  strongly ordered). M-mode enables it with `menvcfg.PBMTE`.
- **Today:** tg_ptw faults on any of PTE bits 63:54. The uncore reserves an uncached route for it (uncore.md: "L2 bank
  (uncached access: Svpbmt NC/IO, M9)").
- **Linux 6.12** (Debian sets `RISCV_ISA_SVPBMT=y`, detected from `svpbmt` in the device tree):
  - It is used for non-cached and write-combining mappings: device ioremaps, and uncached remaps of DMA buffers on
    non-coherent systems.
  - Without it the PMAs decide alone, and write-combining is unavailable.
  - Our DMA is coherent (the host DMA port enters the L2; debian-kernel.md: no device may be `dma-noncoherent`), and
    devices are typed by address. So **Linux gains nothing functional**.
  - It is mandatory in RVA22S64 and RVA23S64.
- **Hardware form:**
  - The walker accepts PBMT with PBMTE. The ITLB and DTLB entries carry 2 bits.
  - The LSU sends IO (and NC, correct but slower) through the existing MMIO path, non-speculative at the ROB head.
  - Fetch from NC/IO pages faults or fetches uncached (Linux never executes from them).
- **Cost:** about 150–300 LUTs a core (0.3–0.6K a chip).
- **Timing risk:** low–medium. The PBMT bits join the DTLB attribute output into the LSU's device decision, one LUT on
  the LSU's near-critical families.
- **Switch:** yes.
- **Recommendation:** v2, or when conformance to RVA22S64 becomes a goal.

## 3. Zicbom, Zicboz, Zicbop
- **Hardware:** `cbo.clean/flush/inval` (Zicbom), `cbo.zero` (Zicboz) and `prefetch.i/r/w` (Zicbop, encoded as ORI
  with rd = x0, a HINT). menvcfg/senvcfg's CBIE/CBCFE/CBZE enable them below M. The block size is 64 B (Zic64b).
- **Today:** decode makes MISC-MEM with funct3 above 1 illegal, so every cbo.* traps. Prefetch hints run as ALU no-ops.
  The L2 already accepts `AcquirePerm NtoT`, "whole-line write without reading (Zicboz, later)" (interfaces.md).
- **Zicbom.**
  - Linux uses it only for non-coherent DMA (`RISCV_ISA_ZICBOM`), and ours is coherent.
  - soc.md's DMA option D-a would need it, but D-c, coherent through the L2, is the one in use.
  - Cost about 300–500 LUTs a core: cbo.clean/flush through the D$'s writeback and probe path.
  - **Recommendation:** v2.
- **Zicboz.**
  - Linux 6.12 uses `cbo.zero` for faster page zeroing (`RISCV_ISA_ZICBOZ`, Debian on; `riscv,cboz-block-size` in the
    device tree). hwprobe reports it to userland, but glibc (2.41 in trixie) has no `cbo.zero` memset.
  - The gain is the kernel's page zeroing:
    - a write-allocating store miss reads each line from DDR before overwriting it;
    - `cbo.zero` takes the line without reading it (AcquirePerm NtoT) and writes 64 zero bytes.
  - Hardware form: an SQ entry marked "zero line", drained as a whole-line write. A younger load to that line waits for
    the drain or forwards zeros.
  - Cost about 400–800 LUTs a core (0.8–1.6K a chip, borderline **[user]**). Timing risk medium: the SQ's forwarding
    gains a case.
  - **Recommendation:** measure first how many cycles the boot spends zeroing pages (an rtlprof bind or tgsim); v1.x if
    it is over about 1%.
- **Zicbop.** Linux 6.12 has no Zicbop support (it arrives in 6.16), and Debian's binaries never emit `prefetch.*`.
  Our no-op execution is already correct. **Nothing to build;** real prefetches are v2.

## 4. Misaligned loads and stores (hardware)
- **Spec:** an execution environment may support misaligned accesses in hardware, by an invisible trap, or by raising
  an exception. Zicclsm (RVA20/22/23U64) requires them to work on cacheable memory but warns they "might execute
  extremely slowly". Zama16b (atomicity within 16 B) is only a development option.
- **Today:** they trap (DR-063), and OpenSBI emulates them. Debian's 6.12 cannot ask firmware for delegation (that is
  SBI 3.0 FWFT, Linux 6.16), so emulation happens invisibly in M-mode. The kernel's boot probe reports misaligned
  accesses as slow.
- **What Debian's binaries do:**
  - Debian's gcc-14 is built for rv64gc with the default tune, which turns on `-mstrict-align`: unaligned copies and
    packed fields compile to byte loads.
  - glibc 2.41 picks its alignment-ignorant memcpy only when hwprobe reports FAST.
  - So **Debian rarely misaligns**: what remains comes from undefined-behaviour casts, hand-written assembly and JITs.
- **Hardware form** (the plan's "hardware split within a line in v1.x"):
  - loads read a 16-byte window (two adjacent words of one line) and rotate it into the result;
  - stores carry a 16-byte mask and write two words;
  - forwarding compares widen to 16 bytes;
  - line-crossing accesses still trap.
- **Cost:** about 800–1,500 LUTs a core (1.6–3.0K a chip), **[user]**. **Timing risk high:** the load alignment sits on
  the LSU's load-to-use loop, and the LSU families are among the chip's worst.
- **Switch:** yes.
- **smt2-study (area_recovery §7.11):** 0 misaligned loads or stores in 49 programs (91.6M instructions; the counter
  checked on a known-count kernel). GCC splits any misaligned access it can see, so traps come only from hidden
  misalignment: casts, packed structures, network headers.
- **Recommendation:** v2. First count the emulations on the board, which costs nothing: `perf stat` with OpenSBI's
  firmware events for misaligned loads and stores, over a Debian boot and a workload, at about 200–400 cycles each.
  Build it only if the count matters.

## 5. Store sets (memory dependence prediction)
- **Hardware:** a store-set table (per load PC, the set it belongs to) and a last-store table (per set, the youngest
  in-flight store). A load predicted to depend on a store waits for it.
- **Today:**
  - Loads run ahead of older stores whose address is unknown. A store's address search marks the oldest younger load
    that already read for replay, and the core flushes at commit (core-lsu.md).
  - `STA_BASE` (DR-169) issues a store's address on its base alone, so most addresses are known early.
- **Measured (area_recovery.md):** "Ordering replays cost 0.09% of the boot's cycles" (1,158 replays from 35 load PCs).
  "DTLB retries cost 30 times as much" (2.31–2.45%). So the predictor is parked.
- **smt2-study (tgsim, area_recovery §7.11; 30 and 120 cycles agree within 0.2 points):**

  | Program | Ordering flushes / 1K | Cycles a flush | 16-entry load-wait table | Perfect store sets (bound) |
  |---|---|---|---|---|
  | dhrystone | 1.13 | 27 | +4.70% | +5.32% |
  | embench sglib-combined | 1.57 | 18 | +2.89% | +3.45% |
  | coremark A | 0.04 | 26 | +0.16% | +0.18% |
  | **the suite's score** | 0.13 over all | | **+0.58%** | +0.66% |

  - The other 30 programs and the 16 working-set kernels have under 0.005 flushes per 1K and gain under 0.05%.
  - The boot's bound stays the RTL's 0.07 replays per 1K, 0.08% of its cycles.
- **So most of the suite's gain is in a 16-entry load-wait table:** a load PC that caused an ordering flush waits for
  the older stores' addresses.
  - It costs about 50–150 LUTs a core (smt2-study's desk estimate, 0.1–0.3K a chip), against 600–1,000 a core for full
    store sets.
  - It is a benchmark gain (Dhrystone, sglib), not a Linux one.
- **Timing risk:** medium. Load issue gains a wait condition on the LSU's near-critical families.
- **Recommendation:**
  - The load-wait table is under DR-154's lines (the coordinator's call): an M9 candidate after §1 and §6 if the area
    allows.
  - Full store sets: v2 **[user]**.

## 6. Indirect-target predictor
- **Today:**
  - A JALR that is not a return is predicted only by the 64-entry, 2-way micro-BTB (119 LUTs, 64 LUTRAM a core).
  - Returns use the 32-entry stacks (two a core), and conditional branches TAGE-lite (5 RAMB36 a core).
- **Linux users of indirect jumps:**
  - glibc's IFUNC stubs (every string function through the PLT);
  - C++ virtual calls;
  - jump tables;
  - interpreters' dispatch loops: Python, Perl and shell, i.e. apt and Debian's maintainer scripts.
- **smt2-study (tgsim, area_recovery §7.11), IPC against today's 64-entry micro-BTB:**

  | Config | The suite's score (33 programs) | 42 pairs WS at 30 / 120 / 250 | Switch interpreter | Threaded interpreter |
  |---|---|---|---|---|
  | (a) micro-BTB 128 | −0.11% | −0.09 / +0.04 / +0.04% | 0 | 0 |
  | **(b) 256-entry table, path (PC xor the last 4 indirect targets)** | **+0.20%** (wikisort +4.4%, cubic +1.4%, CoreMark A +0.8%) | +0.00 / +0.02 / +0.02% | **+98%** | **+47%** |
  | 256-entry table, block history | +0.19% | — | +4.2% | +0.04% |
  | (a) and (b) | +0.07% | — | +98% | +47% |

  - **Interpreters:** today the micro-BTB mispredicts 97% of a switch interpreter's dispatches and 58% of threaded
    code's, at 14–17 cycles each. The path table removes 82% and 67% of them.
  - That is an upper end, since the kernel is a regular 34-bytecode loop.
  - The pairs have almost no indirect jumps (0.06 per 1K).
- **(c) DR-159's block BTB:** CoreMark +2.2%, the suite unchanged, about 0.6K LUTs a core.
- **The boot (to measure in M9):** the RTL boot profile counts 6.5 mispredicts per 1K (about 5% of the first 20M
  cycles, 9 cycles each), but not their kind.
  - Method: mark the non-return JALR mispredict flushes in the profile's bind, with a shadow 256-entry path table
    updated at commit, as §6.11's shadow micro-BTBs were.
  - Bound meanwhile: about +0.4% of the boot for each tenth of its mispredicts the table fixes.
- **Cost of (b):** one RAMB36 a core (256 × tag + target fits; 23 are free) and about 100 LUTs (smt2-study's desk
  estimate), i.e. about 0.2K LUTs and 2 BRAM a chip. As LUTRAM, about 400 a core.
- **Timing risk medium:** fetch's next-PC families (rt_q, qs_q) are near the chip's top. A late F2 override, as TAGE's,
  keeps the table off F1's loop.
- **Switch:** yes.
- **Recommendation:** M9 builds (b), the 256-entry path table, in its BRAM form, as an F2 override behind a switch.
  - Debian runs interpreters (apt's Python, Perl and shell maintainer scripts), and there (b) roughly halves or better
    the dispatch cost.
  - (a) drops out (−0.11%).
  - The boot's share is measured in M9, before the switch defaults on.

## 7. virtio-net
- **Today it is done, in two forms:**
  - **Development builds (stage C):** a virtio-mmio window serves console, block, network and rng, with back-ends in
    `tanager-host` on the A53 (the network on a TAP bridge, 9.9–11 MB/s). DR-180 took the window out of release builds
    (480 LUTs).
  - **The product (RISC-V mode):** Debian's own `macb` driver runs the PS's GEM3 Ethernet (D5). That fits DR-147
    better than virtio: a standard driver, no host program.
- **Linux 6.12:** `VIRTIO_MMIO=m` and `VIRTIO_NET=m`; the devices come from the device tree (`virtio,mmio`).
- **Recommendation:** nothing to build. Document both forms. The open SBC gap is USB (D6, `dwc3` through DKMS, soc
  track), which is outside M9's row.

## 8. Debug module with OpenOCD
- **Hardware:**
  - **Sdext per hart:** debug mode, `dcsr`, `dpc`, `dscratch0/1`, `dret`, single step (`dcsr.step`) and
    `dcsr.ebreakm/s/u`.
  - **The Debug Module (Debug spec 0.13.2, with 1.0 forwards-compatible):** `dmcontrol`, `dmstatus`, `hartinfo`,
    `abstractcs`, `command`, `data0`–`1`, halt/resume per hart and `haltsum`, Access Register for the GPRs, and a small
    program buffer (2 words).
  - **The DTM:** a JTAG TAP with `dtmcs` and `dmi`. The plan (§7.4) has the A53 bit-bang it over AXI GPIO, with
    OpenOCD running `remote_bitbang`. Alternatively, BSCANE2 exposes it on the board's own JTAG (OpenOCD's
    `riscv set_ir`, or its BSCAN tunnel).
- **Sdtrig (hardware breakpoints and watchpoints)** is optional. GDB's software breakpoints (`ebreak`) and stepping
  need only Sdext.
- **Today:**
  - Absent. The core's `debug_req_i` is tied to 0, and the debug window at `0x1100_0000` answers denied "until M9"
    (uncore.md).
  - The trigger CSRs read 0 and ignore writes, and OpenSBI takes that for one trigger: it reports `sdtrig`, "Debug
    Triggers: 1 triggers" and the SBI `dbtr` extension (fpga/kv260/board/d4r2). That is a bug to fix regardless (§10).
- **An out-of-order core halts like an interrupt:** the halt request is taken at commit, the window flushes, and the
  hart parks in the DM's ROM. Abstract register access runs through the program buffer or a direct GPR read port.
- **Cost:**
  - DM: 600–1,000 LUTs.
  - DTM: 150–250.
  - Sdext CSRs: about 100 FFs and 50 LUTs a hart.
  - Debug entry and exit in the commit and trap logic: 150–300 a core.
  - Total about 1.5–2.5K LUTs a chip, **[user]**.
- **Timing risk:** low–medium; debug entry joins the trap path at commit.
- **Switch:** yes, **development builds only** (as the virtio window, DR-180), so the release chip doesn't pay. The
  development builds need the room checked: they also carry stage C's windows.
- **Value:**
  - Halting a hung board, reading PCs, registers and memory, and stepping, with GDB on the A53.
  - Today's tools are strong already: the commit trace with the A53's lockstep, and `TG_DEBUG_CNT`.
  - So this is a development convenience, not a release function.
- **Recommendation:** M9, development builds only, if the user takes the area there. Sdtrig waits for v2.

## 9. Documentation (v1)
- **Today:** README.md is a 52-line status narrative. Build references exist (fpga/kv260/README.md, sw/README.md), but
  there is no guide for a user.
- **M9 writes:**
  - **A user guide:** the KV260 in RISC-V mode (flashing the boot image, booting Debian 13, the console, SD, Ethernet),
    and the host tools.
  - **Release notes:**
    - the ISA string and the extensions as the device tree lists them;
    - the devices;
    - performance: CoreMark, the boot time, the pair figures;
    - known gaps: USB, misaligned accesses emulated, no hardware perf events unless §1 lands.
  - **The switch catalog for a bigger chip** (area_switches.md exists; link it).
  - **The clean-room provenance statement**, with the specs and papers cited across docs/spec.
  - **Errata.**
- **Cost:** none in LUTs, about 2–3 days.

## 10. Hardening found on the way (no LUTs)
- **The trigger CSRs (core track):** make `tselect`/`tdata*`/`tinfo` follow the spec's "no triggers" form, or trap as
  unimplemented, so OpenSBI stops reporting `sdtrig` and the SBI `dbtr` extension.
- **The device tree's ISA string (soc track, with core).**
  - The board's trees list `rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond_sstc`.
  - core-priv.md's target adds `zicntr`, `zihpm`, `zihintpause`, `svinval`, `zkt` and `za64rs`. Check each against the
    RTL, and list what holds:
    - `zicntr`, `zihpm` (zero counters are allowed) and `za64rs` look free.
    - `svinval` is implemented as serialising instructions, so a kernel that batches `sinval.vma` could run slower than
      with one `sfence.vma`. Measure before listing it.
    - `zkt` is a timing claim that needs an audit.
- **Misaligned-access counts on the board** (§4) and **page-zeroing cycles** (§3): measurements that decide v1.x items.

## Recommendation
**M9 builds, in this order:**
1. **The free hardening (§10) and the documentation (§9).** No area, no timing risk; they are what the v1 release
   needs most.
2. **Sscofpmf with 4 counters a hart (§1),** behind `TG_HPM`. Build it as a prototype and measure it out of context.
   The coordinator's call if it stays under 1,200 LUTs a chip, else the user's. It gives the board `perf record`, and
   us profiling without simulation binds.
3. **The indirect-target predictor (§6):** the 256-entry path table (interpreters +47–98%, the suite +0.20%), one BRAM36
   a core, behind a switch. The boot's share is measured before the default flips.
4. **The debug module (§8),** in development builds only. [user]: about 1.5–2.5K LUTs there, nothing in the release.
5. **If the area allows: the 16-entry load-wait table (§5).** The suite +0.58% (Dhrystone +4.7%) for 0.1–0.3K; the
   coordinator's call.

**v2 (or when a measurement asks for it):**
- Svpbmt: conformance only.
- Zicbom: unused with coherent DMA.
- Real Zicbop prefetches.
- Misaligned hardware [user]: rare in Debian, high timing risk; count first.
- Full store sets [user]: the load-wait table takes most of the suite's gain, and the boot's bound is 0.08%.
- Sdtrig.
- Zicboz: v1.x if page zeroing shows over about 1% of the boot.

**The area plan.** M9's release-chip additions are §1 (0.7–1.4K) and §6 (about 0.2K and 2 BRAM), with §5's wait table
(0.1–0.3K) if taken: about 0.9–1.9K LUTs a chip. They are paid by:

| Source | LUTs a chip | Cost | Owner |
|---|---|---|---|
| The divide/sqrt's remaining fabric arithmetic in DSP tiles: F2's pack adders (63 and 31 bits) in DSP ALUs, and the S2 and F1 shifts' fine levels | −0.3 to −0.5K | none (same cycles); the shifts carry a timing risk | fpu |
| Unary ops on ALU1 only (DR-185's reserve) | −0.36K | ≤ 0.04% | fpu/core |
| CSR enables into cold LUTRAM (spikes §8.18) | −0.2K | none | core |
| Fetch's next-PC select (spikes §8.18) | −0.4 to −0.6K | none | core |
| Hart 0 merged alone (reserve) | −0.23K | none | core |
| The DMA port through a core's crossbar port (held) | −0.2 to −0.3K | none | soc |
| The L2's same-set rule (soc.md's reserve levers; reverted in fc1031e) | −0.52K | ≈ 0: 4 bubbles in the boot's first 60M cycles | soc |

- **Correction (10-23):** this draft first listed the divide/sqrt's operand formation in the DSPs' input selects and P4's
  bypass selects at −0.6 to −1.2K a chip, from the area pass's early estimates.
  - The RTL already has both selects as one encoded 4:1 per bit (fpga_friendly.md T7): the ring's x1/y1/x2/y2, RF's
    rf_val and EX0's bypass. A DSP's A/D split with INMODE still takes one LUT a bit, so neither saves anything.
  - What remains is the fpu row above, about −0.3 to −0.5K.
- The fpu row and the unary-ops move together give −0.66 to −0.86K, about M9's low end (0.9K). The core and soc rows
  cover the rest: §1's high end needs about two of them, decided by their owners.
- Taking the sources before the additions keeps the chip's fill at or below rc2's 95.9%. The timing margin, not the
  LUT count, is the binding limit.
- The debug module lives in development builds, which need their own room check.

## Pending
- **smt2-study's tgsim numbers are in** (area_recovery §7.11; perfmodel/results/m9_plan.json; scripts/m9_plan.py;
  claude/tgsim-rtl-cal 547b024a).
- **To measure in M9, on the RTL boot profile or the board:**
  - the share of the boot's mispredicts that are non-return indirect jumps, with a shadow path table (§6);
  - an interpreter loop (Perl, or a maintainer script);
  - misaligned emulations through OpenSBI's firmware events (Debian's 6.12), or `perf stat -e alignment-faults` where
    the kernel takes the traps (§4);
  - the boot's page-zeroing cycles (§3).

## Sources (published documentation only; DR-138)
- **The RISC-V ISA manual,** privileged and unprivileged (Sscofpmf, Smcntrpmf, Svpbmt, the CMO extensions, Zama16b,
  misaligned accesses): https://github.com/riscv/riscv-isa-manual
- **The RISC-V profiles** (RVA22, RVA23): https://github.com/riscv/riscv-profiles/releases
- **The ratified extensions list:** https://riscv.atlassian.net/wiki/spaces/HOME/pages/16154732/Ratified+Extensions
- **The CMO specification:** https://github.com/riscvarchive/riscv-CMOs
- **The SBI specification** (the PMU extension): https://github.com/riscv-non-isa/riscv-sbi-doc
- **The RISC-V Debug specification 1.0:** https://github.com/riscv/riscv-debug-spec/releases/tag/1.0
- **Linux 6.12's documentation** (hwprobe, sysctl, kernel parameters):
  https://www.kernel.org/doc/html/v6.12/arch/riscv/hwprobe.html ;
  https://www.kernel.org/doc/html/v6.12/admin-guide/sysctl/kernel.html
- **The device-tree bindings** (`riscv,pmu`, RISC-V extensions and CPUs, `virtio,mmio`), Linux v6.12's
  Documentation/devicetree/bindings.
- **Kconfig help texts:** https://cateee.net/lkddb/
- **Debian's kernel configuration** from `linux-headers-6.12.113+deb13-riscv64` (trixie):
  https://packages.debian.org/trixie/riscv64/linux-headers-6.12.113+deb13-riscv64
- **LWN** on the RISC-V PMU, Svpbmt, misaligned accesses and FWFT: https://lwn.net/Articles/885574/ ,
  https://lwn.net/Articles/877051/ , https://lwn.net/Articles/936302/ , https://lwn.net/Articles/1022382/
- **OpenSBI's documentation** (`pmu_support.md`, `platform_requirements.md`):
  https://github.com/riscv-software-src/opensbi/tree/master/docs
- **OpenOCD's documentation** (RISC-V commands): https://openocd.org/doc/html/Architecture-and-Core-Commands.html
- **AMD UG974,** BSCANE2: https://docs.amd.com/r/en-US/ug974-vivado-ultrascale-libraries/BSCANE2
- **The virtio 1.2 specification:** https://docs.oasis-open.org/virtio/virtio/v1.2/cs01/virtio-v1.2-cs01.html
- **GCC 14's RISC-V options:** https://gcc.gnu.org/onlinedocs/gcc-14.2.0/gcc/RISC-V-Options.html
- **glibc's NEWS:** https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=NEWS;hb=HEAD
- **Debian's RISC-V port and trixie's release notes:** https://wiki.debian.org/RISC-V ;
  https://www.debian.org/releases/trixie/release-notes/whats-new.en.html
- **smt2-study's tgsim runs:** docs/perf/area_recovery.md §7.11 (claude/tgsim-rtl-cal 547b024a).
- **In this repository:**
  - architecture_plan.md §7.4 and §11;
  - decisions.md (DR-063, DR-138, DR-147, DR-154, DR-159, DR-169, DR-180, DR-185);
  - core-priv.md, core-lsu.md, core-pipeline.md, uncore.md, interfaces.md, soc.md, debian-kernel.md;
  - area_recovery.md;
  - area_switches.md;
  - the board logs under fpga/kv260/board/;
  - the devlog's rc2 entry.
