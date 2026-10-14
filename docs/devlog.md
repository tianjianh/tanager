# Tanager development log and lessons

**Maintained by** the coordinator. Each round adds what changed, what was measured and what was learned. Detailed history stays with each area:

| Area | Detailed history |
|---|---|
| Spikes | [perf/spikes.md](perf/spikes.md) |
| Area study | [perf/area_recovery.md](perf/area_recovery.md) |
| Budgets | [perf/budgets.md](perf/budgets.md) |
| FPU | [spec/fpu.md](spec/fpu.md) |
| Verification | [spec/verification.md](spec/verification.md) |
| Core | `spec/core-*.md` |
| SoC | [spec/soc.md](spec/soc.md) |
| Decisions | [architecture_plan.md](architecture_plan.md) §13 |
| Features | [perf/feature_ledger.md](perf/feature_ledger.md) |

Times are US Pacific.

## 1. Timeline

| When | What |
|---|---|
| 10-13 11:24 | Repository created: plan draft 0.4, M1 model (`tgsim`), tool pins. The schedule is re-estimated for agent-built work: Linux on the board in about 4–6 weeks, v1 in about 3 months. |
| 10-13 11:38 | M0 foundation: `rtl/common` (configuration packages, TileLink, FPU, trace and map types, memory wrappers), core and FPU port stubs, `interfaces.md`, `conventions.md`. Lint passes in all four configurations; Vivado elaborates. |
| 10-13 12:00–15:30 | Build host set up: the 5950X (`ssh home-wsl`), GCC 15, tools, minimal Vivado. The first five sessions failed to start because the folder was not trusted; they restarted on the 5950X. |
| 10-13 15:38 | Five tracks start in parallel: core, FPU, SoC, verification, spikes. |
| 10-13 16:18 | Verification harness and Spike lockstep merged, proven before any core existed. S3 (register file, bypass, ALU loop) closes 200 MHz. |
| 10-13 17:09–17:35 | Snapshots, random generator, Sail 0.15. S2 scheduler options (DUP_SEL, EARLY_W, MX). **FPU complete** and verified (TestFloat, about 2.7 billion results). S5 front end closes 200 MHz at widths 2 and 3. |
| 10-13 18:07 | D17: the user keeps the Goldschmidt divider despite its measured cost. R5 adopted. |
| 10-13 ~19:00–20:20 | Disk emergency (C: at 1 GB free). The account's usage limit stopped every session until 20:20. |
| 10-13 20:32 | S2–S6 final: every protected loop closes 200 MHz; v1 holds 200 MHz up to 88% fill. Measured v1 fit: 119–123K LUTs before recovery. |
| 10-13 21:04 | D18 (user): IPC first. No-IPC tricks first, then a clock down to about 180 MHz, then IPC-costing cuts. The area study starts. |
| 10-13 21:25–21:28 | Interfaces v1.3 (`trace_stall_i`). F/D integration moves into M3, which drops the soft-float userland. **Uncore merged:** KV260 bitstream at 100 MHz with stub cores; OpenSBI and Linux on QEMU. |
| 10-14 ~01:25 | **M2 done:** the out-of-order core passes in lockstep in all four configurations, at CoreMark 3.04 / 2.88 CM/MHz. M3 features are built behind switches. The core's first synthesis: **88K LUTs against a 38.2K budget.** |
| 10-14 01:34–01:44 | Area study, model side, done. AR-1 (wakeup tags) adopted. |
| 10-14 02:18 | Verification fixes and the soak service; FPU LUT pass merged (FPU 5,889 LUTs). |
| 10-14 02:00–03:00 | Vivado trimmed on the build host (47 → 33 GB); unused folders archived to E:. |
| 10-14 03:10 | **AR-1 measured:** v1 scheduler 8,895 → 5,506 LUTs (−38%), with better slack. |

**Pace.** About 16 hours of wall-clock time took the project from an empty repository to:
- M0, except S1, which needs the board;
- M2;
- most of M3's features;
- a finished FPU;
- the uncore and the KV260 flow;
- Linux on QEMU;
- the full verification stack.

The plan's first agent-built estimate put M2 at about 2 weeks in. What actually sets the pace is tool runtime, disk, account usage limits, and work that needs a person (board, AMD login, sudo, folder trust), not writing RTL.

## 2. The area story (LUTs)

### 2.1 Where the estimates went wrong

| Unit | Plan (draft 0.4) | First measurement | Ratio |
|---|---|---|---|
| Register file and bypass (S3) | 2.0K (register file) | 2.0K (register file) | 1.0 |
| Issue queues and wakeup, v1 | 2.9K | 8.9K (with MX, needed for timing) | 3.1 |
| FPU | 4.7K | 7.6K (Goldschmidt) | 1.6 |
| Core, `st`, M3 features on, no FPU | 38.2K (budget) | 88K | 2.3 |
| v1 dual-core before recovery | ≈105K | 119–123K | 1.15 |

**Lessons:**
- **Datapath estimates held; control-heavy ones did not.** Wide multiplexers, CAMs, readiness matrices and state machines came out at 1.6–3× the estimate. A first-cut RTL written for simulation adds another 2× on top.
- **Measure before trusting a budget.** The nightly per-unit synthesis ([budgets.md](perf/budgets.md)) now does that every day.

### 2.2 What we did, and what each step bought

**Scheduler (per core, v1):**

| Step | LUTs | Notes |
|---|---|---|
| Plan structure | — | Missed 200 MHz at v1 by 0.10 ns (S2). |
| + DUP_SEL and EARLY_W | — | Enough for ST, not for SMT2. |
| + MX (matrix wakeup for in-queue 1-cycle producers) | 8.9K | Required for timing at SMT2, and later for every configuration (S6). |
| + **wakeup tags** (AR-1) | **5.5K** | −38%, and the slack improved. |

How wakeup tags came about:
- The model's dependency census showed that, once MX existed, **no row ever waited on a ROB column for a 1-cycle producer**: 0 of 453M sources.
- So the 80 ROB columns were dead weight. 16 tags for the multi-cycle producers replace them, with 0.00% IPC change.
- **Lesson:** after a timing fix changes what a structure must do, re-derive the structure, and instrument the model to count what it really does.

**FPU:**

| Step | LUTs | Notes |
|---|---|---|
| As built | 7.6K | Goldschmidt is 1.4K more than the plan's +0.2K, so it fails the acceptance rule (+2.4% IPC for 3.7% of LUTs). The user kept it (D17); radix-4 is the fallback. |
| R5 (conversions on the FMA) | 7.0K | −612 LUTs, at most −0.09% IPC. |
| No-IPC LUT pass (packing, encodings, DSP use, sharing; no latency change) | **5.9K** | −16%, under the 6.8K budget. |

Rejected:
- a 4-cycle FMA, which misses timing by 1.88 ns;
- R4 (integer divide on the Goldschmidt unit), only −0.15 to −0.4K net.

**Core (in progress).** The first synthesis is 88K: 82.5K in the spikes' breakdown, against a 38.2K budget.

| Overrun | LUTs | Fix |
|---|---|---|
| PMP checkers | 21.8K | cache PMP results in the TLB; full checks only on refills and bare-mode accesses |
| D$ state in flip-flops | 16.6K | LUTRAM or BRAM |
| Rename tables in flip-flops | 13.4K | multi-ported LUTRAM with versioned checkpoints (R3) |
| TLB CAMs with a 44-bit PPN | 8.3K | 22-bit PPN (PA_W = 34) |
| LSU queues holding virtual and physical addresses | 6.9K | physical address only; the virtual address in cold storage |

- **Done so far:** I$ valid bits in LUTRAM.
- **The lesson for new RTL:** write area-aware from the first commit. Memories go through the wrappers, fields are sized to their real width, and checks are cached rather than repeated on every access. The plan already listed these as free levers; the first cut skipped them to reach M2 quickly.

**What was rejected, and why** (D18 and the reverse acceptance rule):
- **R8:** saves 51–305 LUTs with no timing gain.
- **R11:** −1.7% single thread, and worse timing.
- **R13:** −1.5% single thread.
- **Readiness banked by thread:** −2.6% throughput.
- **ALU queues 10 → 8:** −2.6% throughput at v1.
- **R9 and R10:** about 0% in the model, but held as the first reserve, because D18 puts sharing and reduced function last.
- **The bigger v1 window** (+1.8% throughput for about 0.7K per core): an option, not adopted (user).

### 2.3 Where v1 stands

| Stage | v1 dual-core | Ceiling at 200 MHz |
|---|---|---|
| Before recovery | 119–123K | about 103K (88%) |
| With the planned levers | 99–110K | |
| With wakeup tags | 92–104K | |

The real numbers come after the core's area pass (AR-7). No IPC-costing lever is chosen before then.

## 3. Timing story

- **Every protected loop closes 200 MHz** (S2–S5) once given the right structure:
  - MX for wakeup → select;
  - min/max moved to the 2-cycle path;
  - binary operand selects;
  - the DTLB lookup in M1 kept shallow.
- **The fill test (S6):** v1 holds 200 MHz from 79% to 88% fill with no trend. What limits it is the protected loops, not routing congestion.
- **v2 (3-wide SMT2):** reaches 191 MHz at 89%, so it is planned at 180–190 MHz. At 190 MHz it still beats v1 at 200 MHz by 15.6% in throughput.

**Method lessons:**
- Out-of-context runs left unconstrained scattered across the die and lost up to 1.2 ns. Constrain them next to the clock source (pblocks).
- Treat margins under about 0.3 ns as placement noise.
- An early "R8 fails timing" verdict turned out to be placement, not logic.

## 4. Verification story

**What worked:**
- **The checker was proven before the core existed.** Spike was replayed against itself with fault injection: 326 riscv-tests passed and all 270 injected faults were caught. A sim-only test core then exercised the harness end to end.
- **Random programs catch what riscv-tests miss.** Two bugs were planted in the test core:

  | Planted bug | Random programs | riscv-tests |
  |---|---|---|
  | Eviction sends wrong data in its last beat | 200/200 seeds caught it | 0 caught it |
  | SRAIW ignores shift-amount bit 4 | 199/200 caught it | one test caught it |

- **The core reached M2** in lockstep in all four configurations. With the M3 switches on: riscv-tests 280/280, ACT4 rv64imac 355/355, random programs pass.
- **Soak:** 18,880 random programs on 2026-10-14 with no failures (st and st_w3; memory stress, interrupts, trace back-pressure).

**What broke:**
- **Integration breaks happen at merges.** One track added a port and another kept a conditional hookup, so the test core lost the port and a testbench connected it twice. Main stayed green only for the default build. **Lesson:** run the full regression and every area's unit tests on the merged main, not only on the branches.
- **The phase-bit stale-dependency scheme deadlocks** when a pooled LLT is reused while a row still waits on its first instance. The random test caught it before it reached the core.
- **The SoC's boot simulation found a core bug:** an I$ refill must clear the victim's valid bit when the refill starts. The core track fixed it.

## 5. Infrastructure and operations lessons

**Tools:**
- **Vivado inference is not deterministic.** A 7-read LUTRAM mapped to 63 RAM64M8 plus 7 RAM64X1D, and Vivado silently dropped read ports (64 → 55 RAM64M8). **Fixes:**
  - explicit primitives in `tg_ram_lut`;
  - a primitive-count check after every synthesis.
- **XPM pitfall:** XPM parameters such as MEMORY_PRIMITIVE must be untyped string literals, because a SystemVerilog `string` fails XPM's integer comparisons.
- **Vivado install:** the minimal command-line install (Vivado ML Standard, Kria devices only) still took 47 GB. On the build host it was trimmed to 33 GB after checking that synthesis, implementation and the KV260 block design don't need these:
  - the simulator libraries, deleted;
  - the bundled toolchains, archived;
  - the Vitis IDE, archived.

**Disk and storage:**
- **A WSL disk image grows and never shrinks.** C: fell to 1 GB free. **What we did:**
  - limits on WSL usage and on host free space;
  - per-track disk budgets;
  - a 1 GB ccache cap;
  - a self-service compaction script (shutdown, `diskpart` compact, automatic restart).
- **E: is a USB flash stick:** 48 MB/s sequential, but 4 KiB random writes average 138 ms, with stalls of seconds. Cold storage only; never build trees.

**Machine and account:**
- **The account usage limit stops every session at once.** Fewer idle sessions, standby for finished tracks, and restarts after each reset. The user upgraded the plan on 10-14.
- **Use the 32-thread host:** `-j16` per track, 3 Vivado slots, Verilator threads for long simulations, and a nice-19 soak.

**Sessions and messaging:**
- **Sessions on the build host often can't message the coordinator on the laptop;** the coordinator's messages do reach them. End-of-turn reports are the reliable channel, and the coordinator now checks in every 20–30 minutes.
- **New sessions need folder trust once.** The first five sessions failed until the folder was trusted.

## 6. Process lessons

- **Interfaces first, then parallel tracks.** The M0 contracts (ports, TileLink, the trace format, the FPU interface) let five tracks build at once. Most cross-track friction came from interface additions made later (`trace_stall_i`, the SC rule), not from the first contracts.
- **Split work by file ownership.** F/D is split so the FPU agent builds `rtl/core/fpu/*` while the core track does its area pass, with an agreed interface between them.
- **Area decisions follow D18:**
  1. no-IPC tricks;
  2. a lower clock;
  3. IPC-costing cuts, ranked by IPC lost per LUT and taken only after re-measuring.
  A lever counts as "free" only if it keeps the function; a free-but-reduced lever goes to the head of the reserve.
- **Merge discipline:**
  - merge the exact commit the track requested;
  - test the merged result;
  - record measured results in the plan the same day.

**The coordinator's own mistakes, for the record:**
- The first tool build used GCC 13 instead of GCC 15; rebuilt.
- `pkill -f` matched its own command line twice, and a monitor loop matched itself.
- An `&&` before a backgrounded `nohup` held the user's SSH session open.
- An implementation smoke test used a combinational module with no clock port.
