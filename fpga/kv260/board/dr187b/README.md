# DR-187's four-hart bring-up on the board: dr187b at 80 MHz, two harts then four (2026-10-22)

**What it is:** the first look at Linux on four harts on the board, which the user approved.
- **The package:** soc-2's `dr187b-riscv` (tarball `a46e6aee…`, bitstream `71c82c6b…`; [`package_H1-README.txt`](package_H1-README.txt), [`package_SHA256SUMS`](package_SHA256SUMS)).
- **The build:** main a6ff993d as a release build. It has two `smt2` cores with hart 1 on, so four harts, the URF with clk2x at 160 MHz, the PMOD console and the fan's PL regulator, with WNS +1.076 ns.
- **The clock:** 80 MHz, because the chip doesn't close 100 MHz yet. The product target stays 100 MHz (DR-177).
- **No stage C:** a release build has no virtio window or host console, so it runs in RISC-V mode only.
- **Unchanged:** OpenSBI (`b0094d23…`), U-Boot d4, Debian's kernel `6.12.113+deb13-riscv64` and p3's root. mtime still counts at 10 MHz.

**How:**
- **The install, in ARM mode** ([`../runs/fh_p1.sh`](../runs/fh_p1.sh), [`install.txt`](install.txt), the change log in [`../../README.md`](../../README.md)):
  - the package's `tanager/` files went onto p1 after its SHA256SUMS check;
  - its tool and boot hook are byte for byte the installed ones, so its `install.sh` (which also re-runs flash-kernel) wasn't needed;
  - the two-core 100 MHz image stays in p1's `tanager-d4r2-100/` (`fh_p1.sh back` restores it).
- **soc-2's four steps:**
  1. the one-core two-hart tree (`tanager-h01.dtb`) as `tanager.dtb`;
  2. the four-hart tree;
  3. three rounds of hart stop and start;
  4. d4r2's stress, then the baseline's set ([`../runs/baseline_set.sh`](../runs/baseline_set.sh): the DR-141 set, the sc3/d4 workload and memgap), compared per MHz with the d4r2 baseline ([`../d4r2/README.md`](../d4r2/README.md)).
- **After each boot, [`../runs/hart_check.sh`](../runs/hart_check.sh):** the board has no lockstep checker, so wrong results must show up in self-checking work:
  - CoreMark (it validates its own CRCs) and `t.c`'s known sum on each hart alone;
  - the stress's `mt.c` (atomic and mutex-held adds on one cache line) on every pair of harts, with memgap's pingpong;
  - the 9-file project built on all harts at once;
  - the kernel's log.
- **The serial logs:** the laptop's COM5 and COM7 loggers stamp every line with UTC ([`uart_COM5_boots.txt`](uart_COM5_boots.txt), [`uart_COM7_boots.txt`](uart_COM7_boots.txt), [`uart_COM5_stress.txt`](uart_COM5_stress.txt) and its start and stop sessions). [`timeline.txt`](timeline.txt) is `boot_timeline.sh`'s view of them. Its boots 1, 3 and 5 are the 100 MHz health check, step 1 and step 2; 2 and 4 are reboots into ARM mode.

## The results: every step passed, with no errors

| | Step 1: one core, two harts | Step 2: four harts | d4r2, two cores, 100 MHz (baseline) |
|---|---|---|---|
| OpenSBI | `Platform HART Count : 2` | `Platform HART Count : 4` | 2 |
| Linux | `smp: Brought up 1 node, 2 CPUs`; nproc 2 | `smp: Brought up 1 node, 4 CPUs`; nproc 4 | 2 CPUs |
| Harts (Linux CPU = hart) | cpu0 = 1, cpu1 = 0: thread siblings | cpu0 = 1, cpu1 = 0, cpu2 = 2, cpu3 = 3; siblings 0-1 and 2-3 | 0 and 2 |
| `Starting kernel`, from the reset | 33.9 s | 34.0 s | 32.1 s |
| **`Run /init`**, from the reset | **62.7 s** | **59.3 s** | 52.7 s |
| `Run /init`, the kernel's own clock | 26.49 s | 22.89 s | 18.65 s |
| The root mounted (kernel's clock) | 74.30 s | 62.40 s | 48.71 s |
| **The login**, from the reset | **247.1 s** | **190.4 s** | 160.5 s |
| systemd-analyze | 78.4 s + 130.0 s = 208.4 s | 66.5 s + 85.7 s = 152.3 s | 52.0 s + 72.9 s = 124.8 s |
| `hart_check.sh` | 0 fails ([`hartcheck_h01.txt`](hartcheck_h01.txt)) | 0 fails ([`hartcheck_h0123.txt`](hartcheck_h0123.txt)) | 0 fails (10-22) |
| Kernel trouble lines | none | none | none |

- **Each hart alone:** CoreMark A validated on every hart, at 354–357 iterations/s on step 1 and 356–361 on step 2. `t` printed the right sum on every hart (3.68–3.73 s).
- **Pairs:** `mt` was right on every pair: one pair on step 1, all six on step 2, on one core and across cores.
- **Step 3, hart stop and start** ([`hsm_rounds.txt`](hsm_rounds.txt)): in three rounds, CPUs 1–3 went offline (online `0`) and came back (`0-3`). `t` was right on all four CPUs after the rounds, and the kernel logged only `CPUn: off`.
- **Step 4, the stress** (d4r2's two-core loop, [`uart_COM5_stress.txt`](uart_COM5_stress.txt)): 10 of 10 passes clean (`STRESS stop after pass 10, fails=0`), at 119–124 s per pass against d4r2's 114 s at 100 MHz.
  - Its two-thread sysbench figures swing between passes (cpu 53–75 events/s, memory 74–119 MiB/s), with Linux putting the two threads on one core or on two. See the pinned runs below.
- **Boot time per MHz** (the kernel's stamps × 0.8):
  - four harts: `/init` at 18.3 s and the root at 49.9 s, against d4r2's 18.65 and 48.7 (−1.8% and +2.5%);
  - one core: 21.2 s and 59.4 s (+14% and +22%). Its two CPUs share one core, where d4r2's two harts had a core each.
  - The firmware's 12 s on the A53 doesn't scale with the clock.

## Per MHz against d4r2: the same core, and coherence across cores as d4r2's or a little faster

**The DR-141 set** (one run on the four-hart boot, [`set_h0123.txt`](set_h0123.txt); cycles per operation, [`cmp_d4r2_cycles.md`](cmp_d4r2_cycles.md), [`cmp_d4r2_instret.md`](cmp_d4r2_instret.md)):
- **The same per MHz:**
  - CoreMark A +0.7%, B +0.5%, Dhrystone −0.2%, and their rv64imafd forms +0.7%, +0.1% and −0.1%;
  - syscall +0.8%; memcpy and memset of 64 B and 4 KiB +0.1 to +1.4%; sha256sum +0.3%; pipe −1.8% (inside its 2.0% spread).
- **Fewer cycles where memory dominates,** whose speed in ns doesn't change with the core clock:
  - memcpy 1 MiB −11.3%, TLB walk −19.6%;
  - tmpfs read −4.8% and write −5.9%, fork+exec −2.4%, gzip −1.7%.
- **More cycles:** the page-fault test +4.1% (it clears 2 MiB huge pages) and memset 1 MiB +1.1%.

**The workload and memgap** (×1.25 for rates and ×0.8 for times, so that they read as d4r2's 100 MHz figures):

| | dr187b, 80 MHz | As at 100 MHz | d4r2's baseline | Per MHz |
|---|---|---|---|---|
| `./t` | 3.62 s | 2.90 s | 2.86 s | +1.4% |
| sysbench cpu, 1 thread | 37.40 events/s | 46.75 | 47.02 | −0.6% |
| sysbench memory, 1 thread | 67.37 MiB/s | 84.21 | 84.21 | 0.0% |
| sysbench cpu, 2 threads, **pinned to two cores** | 75.09 | 93.86 | 94.41 | −0.6% |
| sysbench memory, 2 threads, pinned to two cores | 118.07 | 147.6 | 145.80 | +1.2% |
| sysbench threads, 2 threads, pinned to two cores | 619 | 774 | 780.7 | −0.9% |
| sysbench cpu, 2 threads, **pinned to one core** | 50.11 | 62.6 | | 1.34× one thread |
| sysbench memory, 2 threads, pinned to one core | 71.01 | 88.8 | | 1.05× one thread |
| sysbench threads, 2 threads, pinned to one core | 348 | 435 | | 0.56× two cores |
| memgap clock / rdtime | 1,245.5 / 257.5 ns | 996.4 / 206.0 | 985.1 / 204.7 | +1.1% / +0.6% |
| memgap wr1k (L1 stores) | 366.5 MiB/s | 458.1 | 460.5 | −0.5% |
| memgap wr16m (DDR writes) | 136.8 MiB/s | 171.0 | 182.4 | −6.3% |
| memgap rd16m (DDR reads) | 139.4 MiB/s | 174.3 | 140.1 | the same per second |
| memgap chase16k / chase256k | 39.2 / 520.1 ns | 31.4 / 416.1 | 31.43 / 432.4 | −0.2% / −3.8% |
| memgap chase64m (DDR) | 710.1 ns | | 695.9 | +2.0% per second |
| memgap ev1 (one thread) | 6,782.8 ns | 5,426 | 5,409 | +0.3% |
| **memgap pingpong, two cores** (`-c 0,2`) | 2,476.8 ns | 1,981 | 2,210 | **198 cycles against 221** (see the rebuild below) |
| **memgap ev2local, two cores** (own blocks) | 7,326 ns | 5,861 | 5,832 | **+0.5%**; +7.4% over ev1, d4r2 +7.8% |
| memgap ev2shared, two cores (one block) | 11,093 ns | 8,875 | 11,097 | −20% |
| memgap pingpong, one core (`-c 0,1`) | 1,537 ns | 1,230 | | 123 cycles |
| memgap ev2local, one core | 10,678 ns | 8,542 | | +57% over ev1: two harts sharing one core |

- The two-core and one-core memgap rows are three runs each with soc-2's memgap from main 4fe536ec, which takes `-c A,B` ([`memgap_dr187b_c02_1.txt`](memgap_dr187b_c02_1.txt) and the rest).
- The other memgap rows are the set's run, with the build d4r2's figures came from.
- [`pinned_h0123.txt`](pinned_h0123.txt) holds the pinned sysbench runs.
- `gcc` and the project aren't compared: this boot ran the stress first, so gcc's files were already cached, where the baseline's boots were fresh.

**What it says:**
- **The core is d4r2's per MHz.** CoreMark, Dhrystone, one-thread sysbench, memgap's one-thread tests and two threads on two cores all agree within about 1.4%, so turning on hart 1 costs a lone thread nothing.
- **Two harts on one core** give 1.34× one thread on sysbench cpu and 1.05× on its memory test. The threads test drops to 0.56× of two cores.
- **Across cores, coherence is d4r2's or a little faster.**
  - Two threads on their own blocks (ev2local) cost 7.4% over one thread, as on d4r2 (7.8%).
  - A shared line's round trip takes 198 cycles against 221, and the shared-block event 20% fewer cycles.
- **Correction (10-22): the first version of this page reported a cross-core "interference" that wasn't there.**
  - memgap pinned its two threads to CPUs 0 and 1 whatever `taskset` said, and on the four-hart tree those are one core's two harts. So every two-thread memgap figure here before the fix measured one core, the old "pinned to two cores" included.
  - So did `hart_check.sh`'s pingpong for every pair: the same 1,651–1,662 ns, which was one core's round trip ([`hartcheck_h0123.txt`](hartcheck_h0123.txt)). Its `mt` results stand, since `mt` doesn't pin itself.
  - The 56–58% was two harts sharing one core, which the one-core rows above show. The coordinator caught it.
  - soc-2's memgap (main 4fe536ec) takes `-c A,B` and names each CPU's thread siblings; `hart_check.sh` now passes the pair.
- **The rebuild moved two memgap figures, so comparisons need one binary on both sides** ([`memgap_percpu.txt`](memgap_percpu.txt), [`memgap_disasm.txt`](memgap_disasm.txt)):
  - Main's memgap, rebuilt on the board, reads wr1k 25% lower (276 against 366 MiB/s) and `rdtime` 5% higher, on every CPU alike, while `clock` and ev1 don't move.
  - The two builds have the same instructions, 20 bytes apart: the store loop now crosses an 8-byte boundary (0x177c–0x1783, against 0x1768–0x176f) and takes 2.2 cycles a store against 1.67. That's a front-end alignment effect worth knowing for the core.
  - The one-core pingpong also moved 7% between the builds (132 to 123 cycles). So the cross-core round trip's gain over d4r2's 221 cycles, measured with the new build, is somewhere between about 4% and 10%.
- **Linux's placement matters on four harts:** two threads land on one core or on two, which is why the stress's two-thread figures swing. Two-thread comparisons need pinning.
- **OpenSBI boots on hart 1** on both trees (its lottery), so Linux's cpu0 is hart 1.

## The four-hart soak: 11 hours, 56 rounds, no failure (10-22 to 10-23)

The coordinator asked for hours under load on all four harts, built from the scripts in use: [`../runs/soak4.sh`](../runs/soak4.sh), run on the board as a systemd-run unit, with the laptop's stamped loggers on COM5 and COM7 and a watch every 10 minutes ([`soak4.log`](soak4.log)).
- **Each round:**
  - A: one stress pass pinned to core 0 (CPUs 0 and 1), while the DR-141 set runs pinned to core 1 (CPUs 2 and 3);
  - B: the same with the cores swapped;
  - C: the same, both unpinned;
  - D: `hart_check.sh` (every hart, every pair, all four);
  - E: one round of hart stop and start.
  - Every step's kernel lines are checked for trouble.
- **The run:** from 19:15:30 UTC on 10-22 to 06:29 UTC on 10-23, 11 h 14 min, stopped at a round's end for the next bitstream:
  - 56 rounds: 168 stress passes, 168 DR-141 sets, 56 `hart_check`s and 56 rounds of hart stop and start, all passing;
  - 224 kernel checks clean, and no line on COM5 between the boots;
  - 0 FAIL lines. The board stayed up for 12 h 18 min with all four CPUs online.
- **CoreMark's 10 s rule:** 21 of the 168 DR-141 sets had a CoreMark run that finished in under 10 s, mostly in the unpinned step (16 of 56 rounds, against 3 and 2 in the pinned ones).
  - CoreMark sizes its run from a short calibration. Beside the stress, the calibration can run slowly and pick too few iterations, for example 3,000 iterations in 8.9 s.
  - The CRCs stayed right (seed `0xe9f5`, list `0xe714`, matrix `0x1fd7`, state `0x8e3a`), so this is CoreMark's timing rule, not a wrong result.
  - The soak's first two starts counted it as a FAIL; the check was fixed and the soak restarted. A CRC error would still count as one.
- **The memgap correction came mid-soak:** the soak was stopped at a step's end for it, and restarted with `hart_check.sh`'s memgap given each pair with `-c`.

**The board now:** ARM mode, with dr187b's image kept on p1 in `tanager-dr187b-80/` for the four-hart 100 MHz preview's fallback, and the two-core 100 MHz image in `tanager-d4r2-100/`. To bring a kept image back, in ARM mode: `FH_BACKUP=<folder> bash ~/tanager/runs/fh_p1.sh back`.
