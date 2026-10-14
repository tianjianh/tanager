# Tanager decision register

**What is in it.** Every decision, approved or rejected, with its date, who made it and its basis.
- Plan §13 holds the headline decisions (D1–D18).
- The [feature ledger](perf/feature_ledger.md) holds each feature's and size's evidence.
- This register holds the rest, and points to both.
- The coordinator maintains it. Tracks report the decisions they make in their merge requests (conventions §10).

**Status:**

| Status | Meaning |
|---|---|
| **approved** | decided and in force |
| **rejected** | considered and turned down |
| **option** | kept on file, not adopted |
| **reserve** | a ranked fallback, used only if needed |
| **parked** | not pursued now |
| **pending** | awaiting a decision |
| **superseded** | replaced by a later decision |

**By:**

| By | Meaning |
|---|---|
| **user** | the user decided |
| **coord** | the coordinator, within the user's rules (plan defaults, D18, the acceptance rule) |
| **track** | a track's technical choice, accepted by the coordinator |
| **rule** | the plan's acceptance rule, applied to measurements or the model |

Dates are 2026, US Pacific.

## 1. Project, roadmap and scope

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-001 | 10-12 | Clean-sheet design. Reuse nothing; never read another core's RTL or the user's other RISC-V projects. | approved | user | plan §2.3 |
| DR-002 | 10-12 | Goal: an out-of-order RV64 dual-core that runs Linux on the KV260, beats NaxRiscv's IPC, has 2-wide decode in v1, and has SMT/CMT hooks | approved | user | brief; plan §1 |
| DR-003 | 10-13 | Stay on the KV260 (XCK26). **A larger FPGA is rejected** as a fallback; the area-recovery levers close the gap instead. | approved | user | D14, plan §8.5 |
| DR-004 | 10-12 | Latency points native, 90, 120 (decision point) and 250 cycles; the acceptance rule (IPC gain ≥ LUT share) | approved | user | D10 |
| DR-005 | 10-13 | The M1 parameter freeze | approved | user | D12; ledger |
| DR-006 | 10-13 | CoreMark target: ≥ 1.21× the NaxRiscv control on identical binaries, per flag set. **Rejected:** 6.0 on rv64gc at 2-wide (it moves to 3-wide), and the pair-decode fusion route. | approved | user | D11 |
| DR-007 | 10-13 | v1 is finished at 2-wide. Everything width-dependent is a parameter, and a 3-wide build is kept working. **Rejected:** hand-written 2-wide logic. | approved | user | D13 |
| DR-008 | 10-13 | Roadmap: v1 = SMT2 2-wide, then v2 = 3-wide on the SMT2 core, both on the KV260 | approved | user | D14 |
| DR-009 | 10-13 | SMT2 configuration: ROB 80 in static halves, LQ 24, SQ 20, 24 LLTs, 75% issue-queue caps, ICOUNT fetch. **Rejected:** ROB 64. **Option:** a shared window. | approved | user | D15, plan §6.5 |
| DR-010 | 10-13 | The first release is the SMT2 dual-core; single-thread (ST) is the bring-up stage. **Rejected:** releasing ST first. | approved | user | D16 |
| DR-011 | 10-13 | LUT utilisation may go up to 90%, with the actual limit set by the S6 fill test | approved | user | plan §8.5; S6 result in DR-087 |
| DR-012 | 10-13 | Defer the area-recovery study until 3-wide cannot fit | superseded | user | triggered by S6 (DR-073) |
| DR-013 | 10-12 | HDL: SystemVerilog-2017. **Rejected:** SpinalHDL, Chisel. | approved | coord (plan default; the user did not object) | D1 |
| DR-014 | 10-12 | The A53 cluster acts as host | approved | coord (plan default) | D2 |
| DR-015 | 10-12 | Vivado 2025.2, frozen | approved | coord (plan default) | D3 |
| DR-016 | 10-12 | v1 ISA: RV64GC + Sv39 + the §4.1 extensions; no RVA23 | approved | coord (plan default) | D4 |
| DR-017 | 10-12 | L2: 1 MiB in UltraRAM, with 512 KiB as the fallback | approved | coord (plan default) | D5 |
| DR-018 | — | Licence: Apache-2.0 or Solderpad 2.1 | pending | user | D7 |
| DR-019 | — | Name "Tanager" (a working name) | pending | user | D9 |
| DR-020 | 10-13 | F and D are in v1, and the M1 study was re-checked with the FPU | approved | user | plan §4.12 |

## 2. Process and organisation

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-021 | 10-13 | Agent-built schedule: Linux on the board in about 4–6 weeks, v1 in about 3 months. **Rejected:** the human-team estimate of 2.5–3.5 years. | approved | user | D8, plan §11 |
| DR-022 | 10-13 | Parallel tracks (core, FPU, SoC, verification, spikes), each in its own worktree; the coordinator merges into main | approved | user | conventions §7, §10 |
| DR-023 | 10-13 | A local git repository with a commit per step; nothing pushed to any remote | approved | user | conventions §10 |
| DR-024 | 10-13 | Interfaces first: `interfaces.md` and `conventions.md` before the tracks start | approved | coord | devlog §6 |
| DR-025 | 10-14 | Run all five tracks after the usage-limit reset. **Rejected:** fewer tracks. | approved | user | — |
| DR-026 | 10-14 | Reactivate the FPU agent and split F/D work: the FPU agent builds `tg_fprf`, `tg_fp_exec` and `tg_fcsr`, and the core track integrates them | approved | user, coord | devlog §6 |
| DR-027 | 10-14 | Merge the exact commit a track requests. Run the full regression and every area's tests on the merged main. | approved | coord | devlog §4 (merge breaks) |
| DR-028 | 10-14 | A coordination loop in the coordinator's session, about every 25 minutes | approved | user, coord | — |
| DR-029 | 10-14 | Document as we go: `devlog.md` and this register; merge requests end with a `Learned:` line; area documents keep a "History and lessons" section | approved | user | conventions §10 |
| DR-030 | 10-14 | The soak service must never block main development | approved | user | verification.md |
| DR-031 | 10-13 | End-of-turn reports are the reliable channel from the build host, because direct messages there are unreliable | approved | coord | devlog §5 |

## 3. Platform, tools and infrastructure

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-032 | 10-12 | GCC 15 for every build, host and target; WSL Ubuntu 24.04. The first tool build used GCC 13 by mistake and was rebuilt. | approved | user | conventions §1 |
| DR-033 | 10-13 | Build host: the 5950X (`ssh home-wsl`), where the track sessions run. **Rejected:** the laptop as build host (8 threads). | approved | user | conventions §9 |
| DR-034 | 10-13 | Minimal command-line Vivado install: ML Standard, Kria devices only | approved | user | tools/vivado/README.md |
| DR-035 | 10-13 | Tool pins: Verilator 5.052, Spike, riscv-tests, riscv-arch-test (ACT4), TestFloat, Sail 0.15 | approved | coord | tools/versions.sh |
| DR-036 | 10-13 | Disk limits: WSL ≤ 95 GB, host ≥ 15 GB free, per-track budgets, ccache capped at 1 GB | approved | coord | conventions §9 |
| DR-037 | 10-13 | Passwordless sudo on the 5950X. The user set it up; the coordinator would not change a security setting itself. | approved | user | — |
| DR-038 | 10-14 | Use the build host fully: `-j16` per track, 3 Vivado slots (at most 2 full-device), Verilator threads for long simulations, a nice-19 soak | superseded in part (DR-106: memory, not threads, sets the limits) | user, coord | conventions §9 |
| DR-039 | 10-14 | Delete Vivado's simulator libraries (`data/xsim`, `data/secureip`; 7.5 GB) after testing synthesis, implementation and the KV260 block design without them | approved | user | devlog §5 |
| DR-040 | 10-14 | Archive Vivado's `gnu/` and `Vitis/ide` to E: (tested the same way) | approved | user | E:\tanager-archive\README.txt |
| DR-041 | 10-14 | **Rejected:** a build or worktree virtual disk on E:. It is a USB flash stick whose 4 KiB writes average 138 ms with stalls of seconds; it is for cold storage only. | rejected | coord (the user offered it) | devlog §5 |
| DR-042 | 10-14 | Compact the WSL disk with the self-service script when C: is short and the tracks are idle | approved | user | C:\WSL\tg_compact.ps1 |
| DR-043 | 10-13 | **Rejected:** a sparse WSL virtual disk, which needs `--allow-unsafe` and carries a corruption risk | rejected | coord | — |
| DR-044 | 10-13 | KV260 setup deferred until bring-up needs it (S1 and M4) | pending | user | fpga/kv260/README.md |
| DR-106 | 10-14 | Memory sets the build host's limits, after it ran out at 03:20. **The rules:** Vivado jobs declare their memory, children included, and are admitted within a 24 GB budget across 2 slots; Vivado runs with `oom_score_adj` 800; Verilator builds use at most `-j8` and long simulations `--threads 4`; the soak pauses under 12 GB available. **Supersedes:** DR-038's 3 slots and `-j16`. | approved | coord | conventions §9; devlog §5 |
| DR-107 | 10-14 | A memory guard in user space (`tools/memguard.sh`): under 3 GB available it stops the newest heavy job, the soak first, and logs it, before the kernel thrashes. A system early-OOM daemon (earlyoom, systemd-oomd) stays the user's option: it is a system setting. | approved | coord | conventions §9 |
| DR-108 | 10-14 | Give WSL 56 GB of the 5950X's 64 GB (it has about 40 GB), then raise the Vivado budget to about 34 GB with 3 slots | pending | user | — |
| DR-109 | 10-14 | After the second stall: the admission counts a slot held by an older `vivado_run.sh` as 10 GB, and tracks merge main before their next heavy job whenever a shared tool changes | approved | coord | conventions §9; devlog §5 |
| DR-115 | 10-14 | Vivado admission becomes a fair queue: tickets, with the waiting job whose owner holds the fewest slots going first, and the head holding the admission lock. **Why:** waiters polled every 15 s and lost freed slots to back-to-back launches. The core's run waited 35 minutes and the FPU's 50. **Also:** 3 slots on the build host, since the 24 GB declared budget is the binding limit. | approved | coord (core track's request) | conventions §9 |

## 4. Core microarchitecture and interfaces

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-045 | 10-13 | Core ports: a TileLink TL-C subset (`l1i`, `l1d`, `mmio`), 128-bit beats, PA_W = 34 | approved | coord | interfaces.md §2 |
| DR-046 | 10-13 | Commit trace with deferred-writeback records | approved | coord | interfaces.md §5 |
| DR-047 | 10-13 | The checker adopts the RTL's SC outcome | approved | coord (verification's request) | interfaces v1.1 |
| DR-048 | 10-13 | `trace_stall_i` back-pressure, with HEADROOM = 2 × COMMIT_WIDTH + LLT_ENTRIES | approved | coord (SoC's proposal) | interfaces v1.3 |
| DR-049 | 10-13 | Scheduler: DUP_SEL + EARLY_W, the guard for stale dependencies, and MX in the SMT2 builds | approved | track (S2) | plan §4.6 |
| DR-050 | 10-14 | MX in every configuration: without it, ST missed in the full chip (−0.041 ns at 75.6% fill) | approved | coord | S6 |
| DR-051 | 10-13 | **Rejected:** the phase-bit stale-dependency scheme. It deadlocks when a pooled LLT is reused. | rejected | track (S2) | spikes.md |
| DR-052 | 10-13 | **Rejected:** PRE_RDY (−0.363 ns) and ISS_REG (no gain) | rejected | track (S2) | spikes.md |
| DR-053 | 10-14 | Wakeup tags (AR-1): 16 tags replace the ROB columns. Measured: v1 scheduler 8,895 → 5,506 LUTs. | approved | coord (D18 step 1) | plan §4.6 |
| DR-054 | 10-13 | min/max/minu/maxu on the 2-cycle path | approved | coord | S3 |
| DR-055 | 10-13 | Binary-encoded operand selects; keep the WB bypass level. **Rejected:** R8 (no timing gain). | approved | track (S3) | spikes.md |
| DR-056 | 10-13 | 3 ALUs by bank replication (+1.25K). **Rejected:** R11 port sharing (worse timing, −1.7% single thread). | approved | coord | S3; area study |
| DR-057 | 10-13 | 3-cycle load-to-use; keep the DTLB lookup in M1 shallow | approved | track (S4) | plan §8.1 |
| DR-058 | 10-13 | LUTRAM micro-BTB. **Rejected:** the flip-flop fallback (3.6K LUTs, worse slack). | approved | track (S5) | plan §8.1 |
| DR-059 | 10-14 | Core area pass before F/D integration | approved | coord (the core track's question) | D18 |
| DR-060 | 10-14 | M3 switches on by default once the regression passes in all four configurations | approved | coord | — |
| DR-061 | 10-14 | Core area fixes: PMP results cached in the TLB; D$ state and rename maps in LUTRAM; 22-bit TLB PPN; physical-address-only LSU queues; I$ valid bits in LUTRAM | approved (in progress) | coord, track | devlog §2.2 |
| DR-062 | 10-14 | `medeleg` bit 19 writable, matching Spike with Zicntr | approved | track | core spec |
| DR-063 | 10-12 | Misaligned accesses trap (OpenSBI emulates them); the `ma_data` tests are excluded | approved | coord (plan) | plan §4.1 |
| DR-064 | 10-14 | Fix from the SoC track's boot test: an I$ refill clears the victim's valid bit when the refill starts | approved | track | core history |

## 5. FPU

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-065 | 10-13 | FMA at 5 cycles. **Rejected:** a 4-cycle FMA, which misses by 1.88 ns. | approved | track | fpu.md |
| DR-066 | 10-13 | Keep Goldschmidt divide/sqrt (D17), although it fails the acceptance rule at its measured cost. Radix-4 is the area fallback. | approved | user | plan §4.12 |
| DR-067 | 10-13 | R5: FP→FP and integer→FP conversions on the FMA (at most −0.09% IPC; −612 LUTs) | approved | coord | plan §4.12 |
| DR-068 | 10-14 | The FPU's no-IPC LUT pass: 7,010 → 5,889 LUTs | approved | track | fpu.md |
| DR-069 | 10-14 | R4 (integer divide on the Goldschmidt unit): −0.15 to −0.4K net | parked | coord | fpu.md |
| DR-070 | 10-14 | The seed table moves to `tg_rom`, so the primitive check counts it | approved | coord | — |
| DR-071 | 10-13 | F/D integration moves into M3. **Rejected:** a soft-float (lp64) board image for M4. | approved | coord | plan §11 |
| DR-072 | 10-13 | **Rejected in M1:** a second FMA pipe, radix-16 divide, a 14-bit seed | rejected | rule | ledger |
| DR-110 | 10-14 | Raise the FPU's flip-flop line to 4,100 (from 3,450) and its DSP line to 35 (from 32). The LUT pass moved cost into flip-flops (3,733) and DSPs (35). Neither binds: the device has 234K flip-flops and 1,248 DSPs, and D18 favours trading LUTs for them. | approved | coord | budgets.md; fpga/budget/budgets.tsv |
| DR-111 | 10-14 | The FP back end's interface with the core, agreed between the FPU and core tracks:<br>• the core instantiates `tg_fp_exec`, with a single F0 writer;<br>• `fmisc_block` in IQ-FP;<br>• wakeup tags as columns below `NCOL − LLT_ENTRIES`;<br>• tag release by `cmp_wid`;<br>• the B1 head held until `fpi_ready`;<br>• no bypass into the integer source;<br>• FP loads written from the load result register. | approved | track | fpu.md |

## 6. Area recovery

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-073 | 10-13 | Start the area-recovery study now; its trigger was met | approved | user | plan §8.5 |
| DR-074 | 10-13 | D18 priority. IPC first: (1) no-IPC tricks, (2) a clock down to about 180 MHz, (3) only then IPC-costing cuts. Sharing and reduced function count as step 3 even at ≈0% cost. | approved | user | D18 |
| DR-075 | 10-14 | AR-1, wakeup tags | approved | coord | DR-053 |
| DR-076 | 10-14 | AR-2, R9 (strict store forwarding) and R10 (shared checkpoints): ≈0% IPC, but they share or reduce function | reserve (first) | coord (D18) | ledger |
| DR-077 | 10-14 | AR-3: v1 keeps its D15 structures and uses no IPC-costing lever | approved | coord | area_recovery.md |
| DR-078 | 10-14 | The v1 window step: ROB 96, LQ 32, SQ 24; +1.84% throughput for ≈0.7K LUTs per core | option (not adopted) | user | ledger |
| DR-079 | 10-14 | AR-4, v2 re-plan: wakeup tags, 180–190 MHz; R11 and R13 dropped | approved (direction) | coord | plan §8.5 |
| DR-080 | 10-14 | AR-5: a fill test at 180–190 MHz for v1 and v2 | approved (running) | coord | S6 |
| DR-081 | 10-14 | AR-6, reserve order. v1: R9, R10, FP queue 8, LD queue 4, radix-4. v2: radix-4, then 8-row ALU queues. | reserve | coord | plan §8.5 |
| DR-082 | 10-14 | AR-7: re-measure the real RTL after the core's area pass, before any IPC-costing lever | approved | coord | plan §8.5 |
| DR-083 | 10-14 | **Rejected by the rule:** R8, R11, R13, readiness banked by thread, ALU queues 10 → 8 (v1), the LQ/SQ/STA/LLT cuts, and ROB 64 with wakeup tags | rejected | rule | area_recovery.md |
| DR-084 | 10-14 | v2 levers R12 (asymmetric third decoder) and a completion buffer of 8 | reserve (v2) | coord (D18) | ledger |
| DR-085 | 10-13 | L2 MSHRs stay at 24 per bank; fewer would cost IPC | approved | coord (D18) | — |

## 7. Timing and implementation

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-086 | 10-13 | `tg_ram_lut` maps to explicit RAM64M8/RAM32M16 under synthesis, because inference was not deterministic | approved | track | spikes.md |
| DR-087 | 10-13 | Utilisation: plan with 85%, ceiling 88–90% (S6: v1 holds 200 MHz from 79% to 88%) | approved | coord | plan §8.5 |
| DR-088 | 10-13 | A primitive-count check after every synthesis | approved | track | tools/tcl/tg_prim_check.tcl |
| DR-089 | 10-13 | Out-of-context runs are constrained next to the clock source (pblock); margins under 0.3 ns count as placement noise | approved | track | spikes.md |
| DR-090 | 10-13 | Per-unit LUT budgets with a nightly synthesis check | approved | coord, track | budgets.md |
| DR-091 | 10-13 | `tg_fifo` stores entries in LUTRAM by default | approved | track | — |
| DR-092 | 10-13 | Accept 180–190 MHz for v2 rather than cutting IPC | approved (direction) | user (D18) | plan §8.5 |
| DR-112 | 10-14 | The scheduler keeps `EARLY_W` = 24 at 200 MHz. `EARLY_W` = 8 saves 147 LUTs and 720 flip-flops at smt2, but cuts slack from +0.392 to +0.162 ns and moves the worst path back onto the wakeup loop. It is kept as an option for a 180 MHz core only. | option | coord (spikes' recommendation) | area_synth.md |
| DR-113 | 10-14 | Synthesis settings for the core: keep the hierarchy, plus `AreaOptimized_high`. **Rejected:** the directive without the kept hierarchy, which failed timing by 0.265 ns. | approved | track | area_synth.md §3.1 |
| DR-114 | 10-14 | `tg_fp_exec` closes 200 MHz with the Explore implementation directives: +0.020 ns at smt2, +0.039 ns at st. Default effort missed by 0.145 ns inside the FMA's E2 stage. | approved | track | fpu.md |

## 8. Verification

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-093 | 10-13 | Spike lockstep from the first commit, proven Spike against Spike with fault injection | approved | track | verification.md |
| DR-094 | 10-13 | A sim-only test core to exercise the harness | approved | track | verification.md |
| DR-095 | 10-13 | ACT4 with Sail 0.15; Ruby and Python dependencies approved for download | approved | coord | verification.md |
| DR-096 | 10-13 | A constrained-random generator, including 3-instruction groups for width 3 | approved | track | verification.md |
| DR-097 | 10-14 | A continuous soak at nice 19 that never gates merges | approved | user, coord | verification.md §4.4 |

## 9. SoC, board and software

| # | Date | Decision | Status | By | Basis |
|---|---|---|---|---|---|
| DR-098 | 10-13 | A single-agent L2 for M4; the coherent L2 at M8 | approved | track (plan) | soc.md |
| DR-099 | 10-13 | Software pins: OpenSBI 1.9, Linux 6.18.56, Buildroot 2026.08, Bootlin riscv64-lp64d GCC 15 external toolchain | approved | track, coord | sw/versions.sh |
| DR-100 | 10-13 | `tanager-host`: a static aarch64 binary (Bootlin musl, GCC 15) | approved | coord | soc.md |
| DR-101 | 10-13 | Prove the software on QEMU first, with a QEMU-compatible device tree | approved | coord | soc.md |
| DR-102 | 10-13 | RISC-V DRAM carve-out with `mem=3G` by default; spike S1 confirms it, and the SMMU bypass | pending (board) | track | fpga/kv260/README.md |
| DR-103 | 10-14 | Trace streaming on S_AXI_HP3_FPD | approved | track | soc.md |
| DR-104 | 10-14 | The initramfs is not compressed in RTL boots, which saves inflating 7 MB | approved | track | — |
| DR-105 | 10-14 | Hold the KV260 bitstream with the real core until the core's area pass lands | approved | coord | — |

## 10. M1-era feature decisions

Kept in the [feature ledger](perf/feature_ledger.md) and plan Appendix C, with their evidence:
- **Removed from v1:** fusion, SFB predication, jump folding, the wait table, branch-first select.
- The frozen sizes.
- Exceptions E1–E5.
- Adoption A1 (Goldschmidt).
