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

## Per MHz against d4r2: the same core, and one uncore difference

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
| **memgap pingpong** | 1,655.6 ns | 1,324.5 | 2,210 | **−40%: 132 cycles against 221** |
| **memgap ev2local** (two threads, own blocks) | 10,702 ns | 8,562 | 5,832 | **+47%** |
| memgap ev2shared (two threads, one block) | 10,751 ns | 8,601 | 11,097 | −22.5% |

[`pinned_h0123.txt`](pinned_h0123.txt) holds the pinned runs. `gcc` and the project aren't compared: this boot ran the stress first, so gcc's files were already cached, where the baseline's boots were fresh.

**What it says:**
- **The core is d4r2's per MHz.** CoreMark, Dhrystone, one-thread sysbench, memgap's one-thread tests and two threads on two cores all agree within about 1.4%, so turning on hart 1 costs a lone thread nothing.
- **Two harts on one core** give 1.34× one thread on sysbench cpu and 1.05× on its memory test. The threads test drops to 0.56× of two cores.
- **The uncore moves coherence differently:**
  - A shared line's round trip (pingpong) takes 132 cycles against 221, for every pair, whether on one core or across cores.
  - But two threads working on their own blocks (ev2local) take as long as on one shared block, 56–58% above one thread, and the same pinned to one core or to two. On d4r2, ev2local was only 8% above ev1.
  - sysbench's memory test on two threads uses one shared buffer (its default scope), like ev2shared, and it matches d4r2 per MHz (+1.2% on two cores). Its local-scope form wasn't run. Why two threads on their own blocks now interfere is soc-2's to read.
- **Linux's placement matters on four harts:** two threads land on one core or on two, which is why the stress's two-thread figures swing. Two-thread comparisons need pinning.
- **OpenSBI boots on hart 1** on both trees (its lottery), so Linux's cpu0 is hart 1.

**The board now:** RISC-V mode on dr187b with the four-hart tree, idle, with the fan's PL regulator on (`BOARD_CTRL` 3). The laptop's stamped loggers run on COM5 and COM7. To go back to the two-core 100 MHz image, in ARM mode: `bash ~/tanager/runs/fh_p1.sh back`.
