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
| 10-15 01:30–13:00 | **The clock question measured, and timing made the priority.**<br>• **Fill test complete (spikes-2):** 150, 160, 170 and 180 MHz close at 99.3% fill (≈116.3K LUTs, the device's limit); 200 MHz closes 93.4% (≈94% for real paths). v1 refits at ≈115.7K, so it fits at 150–180 MHz and is 4–6K over at 200 MHz.<br>• **Decisions (the user):**<br>&nbsp;&nbsp;– DR-140: the core's timing cuts: #1, #3, #6 and #7 hardwired; #2, #4 and #5 compile-time switches verified as two profiles, default and fallback; #2 kept on for now.<br>&nbsp;&nbsp;– DR-141: Linux is the reference workload.<br>&nbsp;&nbsp;– DR-142: timing first, fitting second.<br>• **Merged, all cycle-identical:**<br>&nbsp;&nbsp;– soc-2: the L2 bank's S2 restructure (−2.125 → −0.638 ns), the per-site DSP default, and uncore item 2;<br>&nbsp;&nbsp;– core-2: fn4's three restructures;<br>&nbsp;&nbsp;– fpu-2: P4 steps 7–8, Execute's base multiplexer, the LSU store-data capture (whole-core family −5.68 → −3.97 ns, +110 LUTs) and the FMA's special result in E1;<br>&nbsp;&nbsp;– verif-2: the profile builds and the Linux workload set.<br>• **The board ran the three profiles under Linux** (DR-141): the cuts cost 1–2.4% on copy-, page-walk- and syscall-heavy tests, up to 10× what the suite showed; #2 alone costs syscalls 3.4%.<br>• **Learned:**<br>&nbsp;&nbsp;– The suite and the early boot under-count what timing cuts cost Linux; only the board's workload set showed it.<br>&nbsp;&nbsp;– The Vivado queue lets the owner holding the fewest slots go first, so a 20 GB job can hold the line while a 12 GB job behind it would fit (about 15 minutes lost; no backfill by design). |
| 10-15 13:00 – 10-16 12:40 | **The full chip measured, and the target reset to 125 / 100 MHz.**<br>• **Full chip (spikes-2, spikes.md §8.3–8.6):** at a 200 MHz constraint v1 reached 67 MHz (G4); placing the L2 banks in pblocks fixed a bank the placer had split across the device (G4-FP); with the day's timing work, 77 MHz (G4 refresh). At a 125 MHz constraint: 82 MHz on the fn7-era core without hart 1's area (G5), and **about 94 MHz on core-2's fn10 core with hart 1's area as filler at 96.1% fill (about 98 MHz without it; G5R)**. The cores' DTLB → LSU paths (24–29 levels, 60–70% wire) set the clock; the uncore would pass 100 MHz. G5R at 100 MHz is running.<br>• **The model (smt2-study, merged c64cc3c):** as built, with one L1D miss in flight, v1 loses to NaxRiscv on memory work at every clock; with four misses in flight it leads at 100 MHz and above (1.13× on the suite at 100 MHz, 1.36× at 125, one thread).<br>• **Decisions (the user):**<br>&nbsp;&nbsp;– DR-140 addition: the cut that marks a store complete, and its replay, a cycle later in the ROB (#2) goes off by default; it cost syscalls 3.4% on the board.<br>&nbsp;&nbsp;– DR-143: the L2's AR register slice and one-hot MSHR way select, on by default.<br>&nbsp;&nbsp;– DR-144: the walker start for the ROB head becomes a build switch: the late TLB lookup from a register by default (about 0 LUTs), a second TLB lookup in the fallback (cycle-exact, +194 LUTs per core).<br>&nbsp;&nbsp;– DR-145: the target becomes 125 MHz preferred, 100 MHz minimum, for 2 cores × SMT2; study first, and every resulting change is the user's.<br>&nbsp;&nbsp;– DR-146: the timer interrupt path registered, the commit trace a build switch (off saves 1,420 LUTs per core), and the uncore's slice parameters plumbed to the top.<br>• **Merged:** core-2's fn5–fn8 timing restructures; soc-2's uncore passing 200 MHz out of context, the 125 MHz clock generator and the DR-143 / DR-146 slices; verif-2's boot check by profile, the boot from a tree, the automatic harness choice, the synthesis-view lint, the trace switch and the shared toolchains (0bc6007); the model study.<br>• **Learned:**<br>&nbsp;&nbsp;– A track whose checkout is on the laptop ran simulations there twice. All compute goes to the build host, and every brief to a laptop-based track says so.<br>&nbsp;&nbsp;– The full chip runs about 4 ns slower than a core alone; deep core paths, not the uncore, set the clock. Fill is a timing lever too: 92% → 98% fill cost about 17 MHz in G5.<br>&nbsp;&nbsp;– The L1D's one miss at a time, not the clock, decides whether v1 beats NaxRiscv on memory work.<br>&nbsp;&nbsp;– A shared resource whose requesters ask at different pipeline times needs a fairness rule: in the model, one thread's load misses starved the other's store drain for good. |
| 10-16 12:40–16:10 | **The study decided: 115 MHz, a 4-miss data cache, and the board as a standard SBC.**<br>• **Measured:** the smt2 core alone meets 125 MHz out of context (core-2's 4101948: +0.028 ns, cycle-free, +368 LUTs). The full chip on that core with hart 1's area (G6, spikes-2) reaches about 104 MHz, so the 100 MHz minimum is met. It places at 110.5K LUTs in the performance build, and its 20 worst paths are all in the LSU, mostly wire. core-2's query of G6: cycle-free fixes reach about 108–110 MHz; 115 MHz needs two small cuts and placement work.<br>• **Decisions (the user):**<br>&nbsp;&nbsp;– DR-147: the board becomes a standard RISC-V SBC (OpenSBI, U-Boot, Debian 13's own kernel and modules), board stages C then D now. Boot-firmware changes, SD repartitioning and the A53 OS changes the stages need are approved in advance; fan control at all times.<br>&nbsp;&nbsp;– DR-148: v1's target is 115 MHz; 125 MHz is dropped.<br>&nbsp;&nbsp;– DR-149: the L1D keeps 4 misses in flight, after the timing work and before M7.<br>• **Merged:** fpu-2's FMA count, fetch override fix and DR-144's walker-start switch (fallback identical; default boot −0.007% / +0.001%); soc-2's L2 write-enable fix and two-hart device tree with the stage C and D plans; verif-2's shared toolchains, Debian kernel check and checker for external writes; fpu-2's divider and F2 fixes; core-2's fn9–fn10 (8d22ddc); the model study.<br>• **Board:** Phase 0 passed (fan, carve-out, the PMOD console, both QSPI slots good). The A53's kernel is held after Ubuntu updated it unattended. A two-core 70 MHz platform bitstream is building. Debian 13's riscv64 kernel covers stage C as shipped. Stage D needs our own SD, USB, PS UART and fan modules plus coherent DMA (D-c), so the fan becomes a full PL regulator.<br>• **Learned:**<br>&nbsp;&nbsp;– At 125 MHz in the full chip, wire is 60–90% of the worst paths, so removing logic levels gains only 0.3–1.0 ns each, and stages or placement do the rest.<br>&nbsp;&nbsp;– In the model, the blocking L1D, not the clock, decides how v1 compares with NaxRiscv. Say "speed at the same clock" when quoting such gains.<br>&nbsp;&nbsp;– A board's base OS can change under you between power-ups: unattended upgrades moved the A53's kernel. Hold it during long stages.<br>&nbsp;&nbsp;– Repeated approval prompts from a track came from `rm -rf` on its own snapshot folders. |
| 10-16 16:10 – 10-17 00:40 | **Board first (DR-150), and the two-core hang traced to a synthesis-only bug.**<br>• **The user set P0** (DR-150): two cores running Linux on the board; timing and the 4-miss L1D yield to the board path.<br>• **The board:**<br>&nbsp;&nbsp;– The first two-core build (p0, two smt2 cores at 70 MHz) hung at OpenSBI's boot lottery.<br>&nbsp;&nbsp;– verif-2 and core-2 found a real two-core livelock (a probe right after a Grant stealing the line before the store or AMO used it; LR/SC loops hung 3–6 in 10). It was fixed and merged (537f23b), but it wasn't the board's hang.<br>&nbsp;&nbsp;– p0d2 (with the fix and debug counters) hung the same way, with no D$ traffic at all.<br>&nbsp;&nbsp;– The one-core build c1s hung too, and its lockstep trace was wrong at the 7th instruction.<br>&nbsp;&nbsp;– core-2 found the cause: in tg_rename, `.pop(rn_fire)` inside a generate block came before rn_fire's declaration. Verilator resolved it to the later declaration; Vivado made an undriven implicit 1-bit net (Synth 8-11241 / 8-605, logged only as INFO and WARNING). So no free list advanced, and every allocation from a bank got the same physical register. It came in with fn6 (0c4b011, 10-15 04:31), after the last tree that booted. The fix is 24ada50.<br>• **Merged:** verif-2's coherence suite and the --probe-grant repro (7f63aa5); core-2's forward-progress fix (537f23b); the board session's logs and diagnostics (9d50b57).<br>• **Infrastructure:**<br>&nbsp;&nbsp;– Windows on the 5950X crashed (bugcheck 0x154, 20:18) and took WSL down. All runs were lost and restarted board-first. The Vivado budget went to 44 GB to leave Windows headroom. C: was at 11–13 GB.<br>&nbsp;&nbsp;– The board build didn't fit with trace and counters (118.3K LUTs synthesized): the board flow used Vivado's Default synthesis while every area number used AreaOptimized_high. build.tcl now defaults to AreaOptimized_high.<br>&nbsp;&nbsp;– The user approved Debian root-filesystem tools on the 5950X.<br>• **Learned:**<br>&nbsp;&nbsp;– A name used before its declaration in a generate block passes Verilator, lint and every simulation, and silently miscompiles in Vivado. Guard: `default_nettype none`, and fail every Vivado flow on Synth 8-11241 under rtl/. soc-2's debug hookup had the same class (dbg_sel, dbg_val).<br>&nbsp;&nbsp;– The board found in one day what months of simulation would not: a one-core trace on hardware, checked by lockstep, pointed straight at the bug.<br>&nbsp;&nbsp;– Every synthesized core since fn6 had its free-list pop tied off. G4-refresh through G6 and the budget LUTs since then are likely optimistic around rename, so they get re-measured on the fixed tree.<br>&nbsp;&nbsp;– Build the board with the same synthesis settings as the area budget, or the budget lies. |
| 10-17 00:40–01:35 | **Two-core Linux boots on the KV260 (P0, DR-150).** p0f: two smt2 cores (harts 0 and 2) at 70 MHz, tree aae33dc with the rn_fire fix.<br>• **Boot:** OpenSBI reports "Platform HART Count : 2"; Linux prints "smp: Brought up 1 node, 2 CPUs", then TANAGER-BOOT-OK. The login prompt comes 6 s after the load, with no warnings, RCU stalls or oopses.<br>• **SMP test:** two busy loops in parallel take the same 48 s as one. User time shows on both CPUs, and IPIs flow both ways (rescheduling 59 / 38, function calls 247 / 674). Poweroff reaches the host.<br>• **Coherence traffic:** about 0.5M probes, 0 L2 errors; DRAM reads average 21.7 cycles, maximum 61.<br>• **Merged on the way:** the rename fix (159eb8e), spikes-2's G5 to G6 and their implicit-net check (15284d7).<br>• **Next:** the Linux workload set on two cores, then two-core lockstep; stage C (virtio, U-Boot, Debian 13).<br>• **Learned:** a one-core hardware trace checked by lockstep found in an hour what the two-core runs couldn't: the first wrong value, seven instructions in. |
| 10-17 01:35–03:05 | **Two cores pass the Linux workload set and two-core lockstep's first 426M records.**<br>• **Workload set on p0f:** 54/54 measurements, CoreMark validated 6/6, clean power-off. Against DR-141's one st core at 60 MHz: the same instructions per operation (within 1%), cycles per operation mostly within ±2%, 13–21% less time per operation (mostly the clock); Linux reaches /init in 1.73 s against 2.47 s. A second core costs the single-thread set nothing visible.<br>• **Two-core lockstep:** no mismatch in 425,955,311 records, through OpenSBI's two-hart boot and Linux's SMP bring-up (10,976 interrupts). Linux can't finish booting under the checker: trace back-pressure slows each hart to about 47k instructions/s while the timer runs in real time, so both harts loop in the tick catch-up. That's the checker's clock, not the cores. The fix is to freeze the timer during trace stalls (soc-2, verif-2), or a 1 GHz timebase in a lockstep device tree. The L2 logged 5,928 error events under lockstep and none in the plain boot; soc-2 to identify.<br>• **5950X maintenance (the user delegated it):** C: had fallen to 8.3 GB. The WSL disk was compacted (109 → 95 GB, C: 15 GB free), and WSL restarted with WSLg off (its weston had been crashing about every 100 s) and memory capped at 50 GB (Windows keeps 14 GB of 64). The Vivado budget is 40 GB.<br>• **Merged:** spikes-2's implicit-net check (15284d7, 29648e9). In check: core-2's remaining forward-reference fixes and the budget-flow guard. |
| 10-17 03:05–03:20 | **Debian 13 boots on two Tanager cores on the KV260 (board stage C, DR-147).** sc2 is p0f's tree plus the forwarded virtio window and the coherent host DMA port.<br>• **The path, all standard:** OpenSBI, then U-Boot 2026.07 (its first run on hardware), extlinux from the virtio disk, then Debian's own kernel package 6.12.111+deb13-riscv64 (SMP), systemd, and a serial autologin 240 s after the load.<br>• **In the shell:** debian_version 13.7, nproc 2, root on vda1 (8 GiB). `systemctl is-system-running` reports running, with no failed units. Startup took 1 min 41 s (kernel) + 2 min 1 s (userspace) at 70 MHz. `sudo poweroff` is clean.<br>• **Buildroot over virtio:** the 16 MiB disk's md5 matches the host's, and virtio-rng serves /dev/hwrng.<br>• **Open:** the L2 logged 68 error events in the Debian run (none in lighter runs, 5,928 under lockstep), for soc-2 to identify. tanager-host's `load` doesn't release the uncore as its README says, so the `dma check` step couldn't run. Next in stage C: networking (virtio-net, bridged), then the RISC-V's own SD partition.<br>• **Learned:** the user's "standard SBC" principle paid off at once. Debian's stock kernel, U-Boot's generic flow and virtio needed no Tanager-specific kernel code. |
| 10-17 03:20–04:40 | **Two-core Linux passes FPGA lockstep from first instruction to power-off; DR-150's run list is complete on p0f.**<br>• **The checker's verdict:** "PASS after 408432254 records (408397820 retired, 14594 traps, 19840 interrupts)" in 4,596 s at about 89k records/s. The run covered OpenSBI's two-hart boot, Linux's SMP bring-up, TANAGER-BOOT-OK, the login prompt, a root shell and "reboot: Power down", with no RCU stalls. The checker also accepted 947 loads that read bytes another hart had just replaced and 3 atomics read past a store, all within its window (legal interleavings).<br>• **How:** a lockstep device tree claims a 1 GHz timebase against the 10 MHz timer, so kernel time runs 100× slower and the tick keeps up with the trace-stalled cores. soc-2's p0g adds `--freeze-time` as the proper fix.<br>• **The L2 error events** come only with the commit trace on (about 6,000 in a traced boot's first seconds, none with it off). They point at the trace path, not the cores; p0g's capture names them.<br>• **DR-150's list on p0f:** plain boot ✓, SMP test ✓, workload set ✓ (54/54, CoreMark 6/6), two-core lockstep ✓. Debian 13 boots on sc2 (stage C).<br>• **Alongside:** core-2's 4-miss L1D (DR-149, a switch) passes every functional test: the regressions, two-core coherence, a probe at every GrantAck, 100/100 miss-burst programs. Its speed against one MSHR is being measured. G7, the first 115 MHz full chip on the fixed rename, is routing. |
| 10-17 04:40–06:55 | **Debian on the network; lockstep on the normal clock; the first honest 115 MHz number.**<br>• **Stage C networking (DR-147):** virtio-net comes up as eth0 in Debian 13 on two Tanager cores. Step 1 was a host-only TAP. Then a bridge (br0 over the A53's eth0, in-memory NetworkManager connections under a checkpoint with a 180 s rollback): the RISC-V took 192.168.137.64 by DHCP from the laptop's connection sharing, resolves and syncs time, and `apt-get update` fetched 16.5 MB from Debian's mirror. br0 stays in-memory and is brought up by the stage C run script; stage D replaces it.<br>• **Lockstep on the normal device tree (p0g):** with soc-2's `--freeze-time` (the RISC-V timer pauses while trace back-pressure stalls the cores), two-core Linux passes from reset to power-off: 395,612,106 records, 0 mismatches, /init at 0.368 s kernel time as in a plain boot. The 1 GHz timebase workaround is retired.<br>• **The L2 error events were wrong-path loads past RAM** (the PMA region was 2 GiB on a 1 GiB board). DR-151 shrinks the region to 1 GiB (in soc-2's MR1).<br>• **G7 on main 82463e2** (the fixed rename, before fn11), 115.315 MHz with hart 1's filler: −0.622 ns, about 107.6 MHz. 110,504 LUTs placed (94.4%); 2,296 failing endpoints, all but 6 in the cores. This is the first full-chip timing without the rn_fire bug. The runs with fn11, and with fn11 plus the LSU placement, are queued.<br>• **Merged:** core-2's fn11 (b3d920d): the 115 MHz cycle-free fixes plus cuts #10 and #11, costing −0.035 % to +0.087 % on the suites; the boot slightly faster.<br>• **DR-149's 4-miss L1D:** +668 LUTs and +476 FFs per core (st), against a +450–600 LUT estimate; timing and speed runs going. |
| 10-17 06:55–08:45 | **Stage C is on main; the 115 MHz picture is in; the lint now reads the RTL as Vivado does.**<br>• **Merged, each cycle-identical to its base in st and smt2 with the 20.09M-cycle Linux boot:**<br>&nbsp;&nbsp;– soc-2's MR1 (28f47f4): DR-151's 1 GiB memory region, the L2 bank's and crossbar's forward-reference fixes, and board builds that synthesize with AreaOptimized_high and fail on implicit, undriven or forward-referenced nets.<br>&nbsp;&nbsp;– fpu-2's G8 (689376f): cycle-free fixes in fetch, decode and the LSU for the 115 MHz paths. Its QUEUE_DECODE switch (the instruction queue's decode bits, +324 LUTs per core, 19 → 12 logic levels on queue → rename) stays off; it goes to the user only if G8's full chip shows the queue paths failing.<br>&nbsp;&nbsp;– verif-2 (2a7337f): `make lint-all` adds Vivado's own reading of the RTL (xvlog, and synth_design -rtl of kv260_top and tg_core in st and smt2), failing on the rn_fire class; build support for DC_MSHRS and QUEUE_DECODE; the simulation memory at 1 GiB.<br>&nbsp;&nbsp;– spikes-2's G7 (360cd65): main reaches about 107.6 MHz at 115.315; fn11 about 105.4 MHz with half the failing endpoints and 39% less total negative slack (the WNS difference is within the measured 0.37 ns placement noise); the LSU-beside-D$ pblocks lose 0.85 ns and are dropped. 115 MHz needs another 0.6–0.8 ns, mostly wire: the D$ write enables, DTLB → replay, the LSU → the ROB's write enables, and the L2's internal paths.<br>&nbsp;&nbsp;– soc-2's MR2 (b871c94): the board debug counters and the cores' debug words, both off by default.<br>&nbsp;&nbsp;– soc-2's MR3 (5172c6a), **stage C:** the coherent host DMA port and the forwarded virtio window (both off by default), tanager-host's virtio-blk, virtio-rng and virtio-net back-ends, M_AXI_HPM1_FPD in the block design, U-Boot 2026.07 in S-mode and the keyring-verified Debian 13 image builder.<br>• **Next:** soc-2's 100 MHz stage C board build (sc3_100) from 5172c6a; G8's full chip at 115 MHz (two placements); core-2's fn12 on G7's four core families and soc-2's uncore set; DR-149's speed run.<br>• **Board:** Debian's apt downloads drop part-way (two tries lost libmariadb3 and sysbench); the third try retries each file 5 times.<br>• **5950X:** C: fell to 6.4 GB free, with the WSL image at 103.2 GB for 88 GB of files: it grew 8 GB in 5.5 hours of builds after the 03:00 compaction. Compacted again at 08:34 (image 91.4 GB, C: 18.4 GB free). That killed three jobs under 15 minutes old (spikes-2's G8 synthesis, core-2's DR-149 speed run, soc-2's sc3_100); their tracks restart them. The tracks were asked to delete stale run directories (soc-2's alone hold 12 GB).<br>• **Learned:**<br>&nbsp;&nbsp;– When a merge request changes the testbench's ports, the identity check's newer harness can't build the base's boot (PINNOTFOUND, a missing parameter). Run the base's own boot testbench (HARNESS=own, BOOT_TREE=base).<br>&nbsp;&nbsp;– The WSL image grows with every build's writes, not with what is kept: ext4 takes fresh blocks and deletes return nothing to Windows. Under full build load it grows about 1.5 GB an hour, and the root is already mounted with discard, so trimming gains nothing. C: needs a compaction about every 6–8 hours, best while the running jobs are young, or a second drive for WSL. |

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
