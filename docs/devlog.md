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
| 10-14 03:20 | **The build host ran out of memory.** Two full-device Vivado runs plus the nightly budget synthesis (a parent and six child Vivado processes) took about 33 of WSL's 39 GB, and SSH and every session stalled for about 10 minutes. The budget run and the soak were stopped; Vivado now declares its memory and waits for room in a budget (DR-106). |
| 10-14 03:30–04:01 | **A second stall, 31 minutes.** A core-track synthesis started at 03:30 with seven parallel worker processes, about 10 GB in all. Its branch did not have the new admission yet, so it ran beside two full-device spikes runs. After about 19 minutes of thrashing, the kernel killed one of those (`s6_smt2w3t_93_180`) at 03:51; SSH came back at 04:01. **Now:** the memory guard runs on the build host (DR-107), and the admission counts a slot held by an older script as 10 GB (DR-109). |
| 10-14 04:40 | Soak memory gate merged; the soak has run 44,160 programs with no failures. |
| 10-14 05:07 | **FP back end merged** (`tg_fprf`, `tg_fp_exec`, `tg_fcsr`). Its interface was agreed directly between the FPU and core tracks (DR-111). `tg_fp_exec` is 8,293 LUTs at smt2 and meets 200 MHz by +0.02 ns. Its long smt2 run covered 7.2M random operations with 99K flushes, and each of three deliberately broken copies of the RTL was caught. The FPU's LUT pass moved cost into flip-flops and DSPs, so those lines were raised (DR-110). |
| 10-14 05:40 | **AR-5, first fill result at 180 MHz:** v2 with wakeup tags closes at 94.2% fill (110.3K LUTs, +0.049 ns). The free synthesis settings, a kept hierarchy plus `AreaOptimized_high`, bring the smt2 scheduler to 4,750 LUTs, 47% below the old one. The directive alone fails timing by 0.265 ns. The primitive check now accepts a range, because synthesis leaves unread primitives that `opt_design` removes. |
| 10-14 06:24 | **F and D run in the core (M3).** The FPU and core tracks wired P4 together in about an hour, working from the interface they had agreed directly. In lockstep with Spike, in all four configurations: ACT4 rv64imafdc 895/895, riscv-tests 284/284 and random rv64gc programs. The FPU's assertions caught two core-side bugs during integration: an FP→int op with `rd` = x0 had no LLT column, and `misa.F/D` were read-only. **Area:** the core's no-IPC pass took `st` from 88K to 45.1K LUTs, and AR-1 to 44.4K; with F/D the `st` core is 56.5K, of which P4 is 7.9K. The soak now runs rv64gc. |
| 10-14 07:10 | **v1 closes 180 MHz at 93.4% fill with wakeup tags** (109.4K LUTs, +0.137 ns); without tags the same fill did not finish routing in 2 hours. The Vivado admission becomes a fair queue (DR-115) after the core's and FPU's jobs waited 35 to 50 minutes behind back-to-back launches. |
| 10-14 07:45 | **AR-7: v1 does not fit yet.** The measured RTL puts v1 at ≈155.7K LUTs against 103K (200 MHz) and 110.3K (180 MHz); see §2.3. The gap is implementation, so D18 step 1 continues (AR-8). `tg_fp_exec` closes 200 MHz at default effort when floorplanned into two clock regions (DR-119). |
| 10-14 08:50 | **The core's second no-IPC pass:** `smt2` 62.5K → about 55.3K LUTs (LSU/MMU 22.3K → 14.4K), `st` 56.5K → 50.8K. v1 falls from about 155.7K to about 141.3K, 38.3K over at 200 MHz and 31.1K at 180 MHz. One lever, sharing the walker's PMP checker with STA, changed cycles and went to the reserve (DR-122). The step-1 work is now split by file ownership: the core takes LSU/MMU, rename and ROB/CSRs; the FPU agent takes P4 and the integer execute units. |
| 10-14 10:15–11:40 | **The FPGA-friendly program starts (DR-123, DR-125)**, after the user pointed at RSD-style FPGA-native rewrites.<br>**Rules:** every decision now records its pros and cons (DR-124). Rewrites happen now for finished units, and new RTL is written FPGA-friendly from the start.<br>**Also in this stretch:**<br>• WSL went from 40 to 56 GB with a 46-second restart; the Vivado budget is now 34 GB.<br>• The user decided the licence (Solderpad 2.1 for hardware, Apache-2.0 for software) and kept the name Tanager.<br>• The user set the board plan (DR-126): the KV260 hangs off the laptop, with stages A to D ending in dual boot and an ARM handover.<br>• The spikes track built LUTRAM CAM, multi-write LUTRAM, SRL FIFO and DSP comparator primitives in about 15 minutes.<br>**The core's third pass:** `st` 52,024 → 46,132 LUTs and `smt2` 49,022 against its 46,120 budget, all under the new settings. It is cycle-identical to main. A rough v1 is now about 129K. |
| 10-14 11:40–13:50 | **Verification and tools:**<br>• `make cycle-identical` (verification) compares commit-trace and TileLink hashes on 796 programs, and BOOT=N extends it over a Linux boot on the whole SoC. Planted changes are caught. A TLB gap, where no program filled a TLB, was found and closed with `tlb_stress`.<br>• Vivado jobs now report their measured peaks, and the build host runs 6 slots within 40 GB. The peak log showed some jobs under-declaring (8–9 GB used against 4–6 declared); they were fixed.<br>**The SoC merge (cfaa9c9):** lossless commit-trace streaming to DDR, a boot test (OpenSBI on 1×1, 2×1 and 2×2), the PMOD console option, and a stage C/D design draft. The L2 same-set rule was reverted to the reserve: it added bubbles.<br>**The decision register:** every entry now carries pros and cons (DR-124 backfill).<br>**The refit:** v1 is about 127.0K, 24.0K over 103,040 and 15.4K over at 180 MHz.<br>**The board:** reached over the laptop's shared Ethernet. Its SMMU has no driver on this image. The user asked for fan control on every experiment (DR-129); Linux drives the fan with TTC0 channel 2 through EMIO to A12. |
| 10-14 14:10–14:40 | **Spike S1 on the board (M0 complete).** The bitstream routes Linux's fan PWM, and the fan stayed at 15/255.<br>• **Latency:** an idle 64-byte read takes 36.8 cycles (184 ns) at 200 MHz, against the plan's 30–60 cycle native bracket and its 90/120 sizing points.<br>• **Bandwidth:** 3.2 GB/s per HP port, 6.35 GB/s for two.<br>• **No DECERR.** The `mem=3G` carve-out is verified, and the SMMU is moot on this image (DR-102, DR-132).<br>**Two traps found and fixed:** an overlay clock request of 99,999,001 Hz rounded the PL clock down a divider step, to 181.8 MHz; and a test stream overwrote the latency chase's own pointers, which showed up as DECERRs.<br>**Also in this stretch:**<br>• the licence files went in (Solderpad 2.1 and Apache-2.0, copyright Tianjian Huang; DR-130);<br>• the shared FPGA primitives were priced (T2 LUTRAM live-value table, 4–7× fewer LUTs; a LUTRAM CAM is no LUT win for the TLBs);<br>• the core moved its counters into DSPs (R1). |
| 10-14 14:40–16:45 | **Stage B, first half, on the board:** the SoC track's traffic-generator bitstream passed bring-up steps 1–5.<br>• It loads through xmutil with Linux's fan control.<br>• The port widths check out.<br>• The memory path ran 14M lines with 0 errors, at native latency and at 250 injected cycles.<br>• The RISC-V console comes out on the user's PMOD UART (COM5).<br>**The board session hung the board once.** It ran `tanager-host` after the default app was back, and an unanswered PL read locked the ARM; the user power-cycled it. The lesson: never touch the PL address space unless our design is loaded. tanager-host is to enforce that itself.<br>**Bugs it found for the SoC track:** tanager-host ignored options after the command, and the injector's native-latency average reads about 0.1 cycles.<br>**Also merged:**<br>• the FPU's no-IPC pass (P4 −129, execute −52);<br>• the uncore's crossbar cut (−249);<br>• verification's coverage measurement: random programs never ran under address translation; now a third do, and LSU coverage went from 88% to 98%.<br>**The core's FPGA-friendly pass** brings `smt2` to 45,992 LUTs, under its 46,120 budget (on its branch, MR pending).<br>**Decisions:** DR-133, execute's operand ports in UltraRAM, gated. |
| 10-14 16:45–18:45 | **Linux boots on the Tanager core on the KV260.**<br>• The SoC track's first M4 bitstream (one real `st` core at 60 MHz, SoC 20435b1) ran the SoC test program to PASS, with the console on the host bridge and the PMOD UART.<br>• OpenSBI 1.9 and Linux 6.18.56 booted to TANAGER-BOOT-OK 8 s after the load at native latency. At 250 injected read cycles they booted to a root shell (uname, cpuinfo: rv64imafdc with Zba/Zbb/Zbs/Sstc, Sv39, 1 GiB) and a clean poweroff. Native latency while Linux ran averaged 19.8 cycles (max 54) at 60 MHz.<br>• Four board findings were fixed in `tanager-host` and the RTL along the way: options after the command, a guard that refuses to touch the PL unless the Tanager overlay is loaded (an unanswered PL read had hung the ARM), the injector's latency sum, and a console drain before `run` stops.<br>**Area:** smt2-study corrected hart 1 in RAM form from ≈2.4K to ≈4.4K per core, adding the PMP descriptor select, so v1 is ≈119.9K, not ≈115.2K. The SoC track's uncore plan became DR-136: about 140 DSPs as registered selects and 2 RAMB18, est. −4.0K, cycle-identical. Block RAM doesn't pay for the uncore's shallow, 128–320-bit buffers.<br>**Incident:** spikes' DR-133 gate-3 full-chip run exited with rc=1 five minutes after it started. The track reported it as under way, and its run directory, log included, was deleted. The coordinator found it from the peaks log.<br>**Learned:** a long run's report needs a liveness check, and a failed run must keep its log. |
| 10-14 18:45–20:05 | **Merges:**<br>• the SoC's M4 sources, as the board ran them (9be0707);<br>• the core's two FPGA-friendly passes (7d60948: st 42,607, smt2 45,055);<br>• the FPU's round 3, with DR-133's UltraRAM operand switch built and off by default (3121edd);<br>• smt2-study's refit: v1 ≈118.6K with hart 1 in RAM form, +15.5K over 103,040 and +6.9K at 180 MHz.<br>Each merge passed lint, regress and `make cycle-identical` in st and smt2.<br>**Timing:** the SoC's 100 MHz M4 build misses by 3.761 ns on two cross-unit path families inside the core, 35–38 levels and about 13.5 ns. Per-unit runs cannot see them. The core track now owns a whole-core 200 MHz timing run, and any cut that moves a cycle goes to the user (DR-135).<br>**M4's other open criterion:** the verification track took FPGA lockstep, an A53 checker on the DDR trace ring, which had no owner.<br>**Incidents:**<br>• Spikes' gate-3 failure came from the spike modules overwriting the production units in the read-all-RTL flow. Failed runs now keep their logs. The re-run synthesised the two real cores in 48 minutes.<br>• The core track sat at a tool-approval prompt from 18:04 to 20:01 while it showed as running. The coordinator first read that as working, until the transcript showed an open tool call with no child processes. The user approved it.<br>• An orphaned waiting loop of the core track's (`pgrep -f` matching its own command line) had looped for 6 hours.<br>**Learned:** "running" is not "working". Check a quiet session's transcript tail and its processes. Wait on jobs by pid, not by `pgrep -f` on their own text. |
| 10-14 20:05–22:00 | **FPGA lockstep passes on the KV260 (M4).** The verification track built the A53 checker in about an hour: Spike as a library, plus the simulation checker's rules. The board session ran it in five steps:<br>1. offline on the A53, at about 141K records a second, catching a planted fault at exactly record 100,000;<br>2. the board's first commit trace;<br>3. a live pipe;<br>4. **Linux to a root shell and poweroff, with all 335,786,888 records checked and none differing**;<br>5. the same boot at 250 injected cycles, which runs next.<br>The first Linux attempt stopped on bytes past the device tree that nothing had written: stale DDR on the board, zeros in Spike's memory. `tanager-host load` now zeroes the window.<br>**Merges:**<br>• the uncore's DSP register slices (DR-136: −1.3K LUTs, −2.8K FFs);<br>• the FPU's P4 step 6;<br>• gate 3, which rejected DR-133: every URAM is in one column, about 5 ns of wire from the issue logic;<br>• two refits (v1 ≈117.2K);<br>• the clock sweep and one-stage ablation.<br>**The ablation:** one more cycle costs 8% of suite IPC in the integer wakeup loop and 1.9% at load-to-use (5–6% on CoreMark). It costs under 1% at completion, the mispredict redirect or the L2 hit, and nothing for exception reporting.<br>**Decisions:** the user asked whether 200 MHz is right, given NaxRiscv's 135–150 MHz; measurements across 150–200 MHz are under way. DR-137: the clock is the user's call. DR-138: clean-sheet uncore; no reading of other projects' source.<br>**Learned:** a full chip finds what out-of-context runs cannot: wire to fixed columns, and paths that cross units. |
| 10-14 22:00 – 10-15 01:30 | **FPGA lockstep is complete:** the 250-cycle boot was checked too (355,612,637 records, no mismatch). Merged: the verification track's checker work and the board session's logs.<br>**The clock question (the user):** is 200 MHz right when NaxRiscv does 135–150? Three measurements answered it.<br>• **Fill test:** 93.4% closes 200 MHz (109.4K LUTs, up from S6's 88%). 98.3% closes 150 and 170 MHz, where the device's placement is the limit, not timing.<br>• **Model sweep:** performance follows the clock (−8.9% at 180 MHz, −21% at 150). v1 stays 1.7–2.3× NaxRiscv's suite performance.<br>• **The core track's sorting:** the whole `st` core alone reaches about 83 MHz at 36.5% fill. Every deep family is true, 10.5–12 ns and 65–75% wire, so it needs the same fixes at any clock: the LSU address-stage split, decode, rename, atomics, and floorplanning. The measured cut costs are 0 to +0.4% cycles.<br>• **Recommendation:** no clock decision yet. The user keeps the clock (DR-137).<br>**User decisions:**<br>• DR-138: clean-sheet uncore. The user offered to let the tracks learn from LiteX's source, then withdrew it before anyone read it.<br>• DR-139: PMP sharing adopted (−0.83K per core, about 0 cycles), superseding DR-122.<br>• The user's five uncore ideas: decoupled boundaries with local flow control, plus zero-latency registered decode, go to the tracks. The MMIO split later; the non-blocking memory path is already built.<br>**Operations:** the live Vivado budget went 44 → 46 → 50 GB. The fair queue admits strictly in order, so a 12–20 GB job at the head left 10–14 GB idle while eight jobs waited. Memory allowed more; the worst case is about 47–49 of WSL's 54 GB.<br>**Learned:**<br>• A quiet "running" session may never have read its messages. The core track's long turn held about ten coordinator messages for hours, so priorities now go out as one consolidated message when it idles.<br>• Area rewrites that move state into LUTRAM confine it to SLICEM columns, which stretches the units. Watch the wire. |

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

| Stage | v1 dual-core | Ceiling |
|---|---|---|
| Projected before recovery | 119–123K | about 103K at 200 MHz (88%) |
| Projected with the planned levers | 99–110K | |
| Projected with wakeup tags | 92–104K | |
| **Measured RTL, after the area pass and F/D (AR-7, 10-14)** | **≈155.7K (133% of the device)** | 103K at 200 MHz; 110.3K at 180 MHz (AR-5) |
| **Measured RTL after three no-IPC passes and the first FPGA-friendly rewrites (AR-8, 10-14 17:21)** | **≈119.9K with hart 1 in RAM form (102% of the device)** | 103.0K at 200 MHz; 111.6K at 180 MHz |

**What the measurement showed.** The projection put v1 at 92–104K. The real RTL comes to about 156K.
- **The core:** `st` is 56.5K against 38.2K, and `smt2` 62.5K against 46.1K. Every unit except the issue queues and the front end is over budget: LSU/MMU +13.8K, rename +4.3K, ROB/CSRs +3.2K.
- **The uncore:** 22.3K against 10.8K. The crossbar is +4.4K, trace +2.9K and the host bridge +1.7K.
- **The other levers are small by comparison:**
  - D18's later steps: 180 MHz gives 7.2K, and the IPC-costing reserve about 2.2K per SoC.
  - Wakeup tags saved 3.4K in the scheduler harness but only 0.7K in the real `st` core.

**Lesson.** The lever study ranked the last few percent. Only per-unit budgets reported from real RTL show whether a design fits, and the budgets were set from estimates that the RTL overran almost everywhere. Ranking levers should wait for real numbers.

**What happens now (AR-8).** D18 step 1, no-IPC implementation work, continues unit by unit against the per-unit budgets. It had to find about 45–53K. By 17:21 it had found about 36K, leaving ≈16.9K at 200 MHz (≈8.3K at 180 MHz). More than half of that is in the uncore, whose DSP pass (DR-136) is next. A single SMT2 core (≈89K with the uncore) fits today, and so does M4's single core.

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
- **Use the 32-thread host:** `-j16` per track, 3 Vivado slots, Verilator threads for long simulations, and a nice-19 soak. That sizing came from the thread count, and it was wrong; see the next point.
- **Memory, not threads, limits the build host.** WSL has 39 GB. Three Vivado slots plus a budget run's six child processes used it all.
  - **Why it hurts so much:** the kernel's OOM killer acts only after minutes of thrashing, and SSH and every agent session stall meanwhile.
  - **Now:**
    - Vivado jobs declare their memory, children included, and wait for room in a 24 GB budget;
    - Verilator builds at `-j8`;
    - the soak pauses under 12 GB available;
    - a memory guard stops the newest heavy job under 3 GB available.
  - **The user's call:** giving WSL more of the host's 64 GB (DR-108).
- **A queue needs an order, not just a limit.** The first admission let waiters poll every 15 s. A track that launched jobs back to back took every freed slot, and other tracks' jobs waited 35–50 minutes. Fixed with a fair queue (DR-115).
- **A tool fix on main protects nothing until each track merges it.** Tracks run tools from their own branches, and the spikes track from snapshots taken when each run starts. The second stall came from a track that had not merged the new admission yet. The memory guard runs from the main checkout, so it covers every job whatever its branch.

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
- Raised the build host's parallelism (3 Vivado slots, `-j16`) from its thread count, without a memory model. The host ran out of memory.
- `pkill -f` again: the command that stopped the budget synthesis also killed the nightly runner that had started it.
- Changed the Vivado admission on main without having the tracks merge it before their next heavy job. The core track's next synthesis ran under the old rules and stalled the host for 31 minutes.
