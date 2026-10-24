# The four-hart 100 MHz preview on the board: u100 (2026-10-23)

**What it is:** four-hart Linux at the product's 100 MHz, which the coordinator asked for. The package is soc-2's `u100-riscv` (tarball `7f4c6b7a…`, bitstream `f8037f92…`; [`package_H1-README.txt`](package_H1-README.txt), [`package_SHA256SUMS`](package_SHA256SUMS)).
- **The build:** spikes-2's near-final product build from snapshot ca66235f (main e88f2b98 with DR-183, soc-2's registered head MMIO check, and core-2's LSU branch and rt_q B), as a release build.
  - Two `smt2` cores with hart 1 on, the URF with clk2x at 200 MHz, the PMOD console and the fan's PL regulator.
  - The first build to close 100 MHz: WNS +0.257 ns, 111,359 LUTs.
  - It's a preview: not all its branches are on main yet.
- **New on hardware:** DR-183's PMP checks at TLB fill.
- **Unchanged against dr187b:** OpenSBI, U-Boot d4, the two trees and Debian's kernel. Only the bitstream and the clock change.

**How:**
- **Staged first:** the soak on dr187b was stopped at a round's end, and dr187b's p1 files kept in `tanager-dr187b-80/` ([`stage.txt`](stage.txt)).
- **The install:** after soc-2's go, once its simulated switch-on boots had passed under lockstep. Only the package's `p1:/tanager/` files went in; its tool and hook are byte for byte the installed ones ([`install.txt`](install.txt), the change log in [`../../README.md`](../../README.md)).
- **soc-2's steps:**
  1. the four-hart tree first;
  2. `hart_check.sh`, with memgap's `-c` on each pair;
  3. three rounds of hart stop and start;
  4. the stress, then the baseline's set, and memgap with `-c 0,2` beside `-c 0,1`.
- **For the coordinator's boot times:** one boot on the one-core two-hart tree, then the four-hart tree again.
- **Every console is logged** with UTC line stamps ([`uart_COM5_boot1.txt`](uart_COM5_boot1.txt), [`uart_COM5_stress.txt`](uart_COM5_stress.txt) with its start and stop sessions, [`uart_COM5_boots2.txt`](uart_COM5_boots2.txt), [`uart_COM7.txt`](uart_COM7.txt); [`timeline.txt`](timeline.txt)).

## The results: every step passed, and no access fault anywhere

**No access fault, oops, panic, OpenSBI trap line, SIGSEGV or SIGBUS** in any console log or kernel log: three boots, the checks, the stress, the set and the memgap runs. That is what DR-183's checks at TLB fill would show if they refused a valid access.

| | Four harts (two boots) | One core, two harts | d4r2, two cores (baseline) | dr187b, four harts, 80 MHz |
|---|---|---|---|---|
| OpenSBI / Linux | HART Count 4; 4 CPUs; siblings 0-1 and 2-3 | HART Count 2; 2 CPUs | 2 CPUs | 4 CPUs |
| `Starting kernel`, from the reset | 31.8 s | 31.7 s | 32.1 s | 34.0 s |
| **`Run /init`**, from the reset | **52.3 and 52.1 s** | 54.6 s | 52.7 s | 59.3 s |
| `Run /init`, the kernel's clock | 18.52 and 18.31 s | 20.80 s | 18.65 s | 22.89 s |
| The root mounted (kernel's clock) | 47.98 and 48.28 s | 58.78 s | 48.71 s | 62.40 s |
| **The login**, from the reset | **154.4 and 156.0 s** | 201.4 s | 160.5 s | 190.4 s |
| systemd-analyze | 51.2 s + 68.0 s = 119.2 s | 62.1 s + 104.1 s = 166.2 s | 124.8 s | 152.3 s |
| `hart_check.sh` | 0 fails ([`hartcheck_h0123.txt`](hartcheck_h0123.txt)) | 0 fails ([`hartcheck_h01.txt`](hartcheck_h01.txt)) | 0 fails | 0 fails |

- **Each hart alone:** CoreMark A validated on every hart, at 453–455 iterations/s on four harts and 450–454 on one core. That is d4r2's 4.55 per MHz. `t` printed the right sum on every hart (2.93–2.94 s).
- **Pairs** (`mt` on every pair; memgap given each pair with `-c`): one core's two harts pass a line in 1,213–1,219 ns (121 cycles), two cores in 1,961–1,972 ns (196–197 cycles).
- **All four at once:** the project builds in 10.66 s and sysbench cpu gives 126.3 events/s on four threads, 1.25–1.28× dr187b's, as the clock predicts.
- **Hart stop and start** ([`hsm_rounds.txt`](hsm_rounds.txt)): in three rounds, CPUs 1–3 went off (online `0`) and came back (`0-3`), with `t` right on all four after.
- **The stress:** 10 of 10 passes clean (`STRESS stop after pass 10, fails=0`), at 113–116 s per pass, d4r2's 114 s. Its two-thread sysbench figures swing with Linux's placement of the two threads, as on dr187b.

## Per MHz and per second

**The DR-141 set** (one run on four harts, [`set_h0123.txt`](set_h0123.txt); cycles per operation against d4r2's baseline, [`cmp_u100_cycles.md`](cmp_u100_cycles.md), [`cmp_u100_instret.md`](cmp_u100_instret.md)):

| Test | u100, 100 MHz | dr187b, 80 MHz | Spread (d4r2) |
|---|---|---|---|
| CoreMark A / B | +0.3% / −0.5% | +0.7% / +0.5% | 0.2% / 0.4% |
| Dhrystone | −0.7% | −0.2% | 0.5% |
| syscall, memcpy and memset of 64 B and 4 KiB, sha256sum | −0.5% to +0.3% | +0.1% to +1.4% | 0.2–1.8% |
| memcpy 1 MiB | **−10.5%** | −11.3% | 0.1% |
| tmpfs read / write | −5.2% / −5.1% | −4.8% / −5.9% | 0.7% |
| TLB walk | **−16.8%** | −19.6% | 0.1% |
| fork+exec / gzip | −3.5% / −2.7% | −2.4% / −1.7% | 1.3% / 0.4% |
| memset 1 MiB | −3.2% | +1.1% | 0.3% |
| pipe | +2.0% | −1.8% | 2.0% |
| **page fault** (2 MiB huge pages cleared) | **+8.8%** | +4.1% | 0.5% |

- At the same 100 MHz as d4r2, the memory-heavy rows are faster: memcpy 1 MiB, tmpfs, TLB walk and fork+exec. So these gains are the design's, not dr187b's lower clock.
- **The page-fault test is the one row that got worse:** +8.8% against a 0.5% spread, with dr187b at +4.1%. This build has DR-183's PMP checks at TLB fill; the row is for soc-2 to look at.

**Per second against d4r2, at the same clock:**
- `./t` 2.87 s (+0.3%);
- sysbench cpu 47.07 events/s on one thread and 94.48 on two (+0.1% each);
- sysbench memory 83.59 MiB/s on one thread (−0.7%).
- The two-thread memory and threads tests, unpinned, came out low again, as two threads can land on one core.

**memgap** (three runs each of main 4fe536ec's build with `-c`, against dr187b's runs of the same build; in cycles):

| | u100, two cores (`-c 0,2`) | dr187b, two cores | u100, one core (`-c 0,1`) | dr187b, one core |
|---|---|---|---|---|
| pingpong | 196 | 198 | 121 | 123 |
| ev1 | 543 | 546 | 542 | 544 |
| ev2local | 581 (+7.1% over ev1) | 586 (+7.4%) | 846 (+56%) | 854 (+57%) |
| ev2shared | 864 | 888 | 845 | 855 |

- Across cores, ev2local is d4r2's (+7.8% over ev1 there).
- **Against d4r2 with one binary:** memgap's older build, the one d4r2's baseline used, run once on u100 ([`memgap_u100_pre-c.txt`](memgap_u100_pre-c.txt)), compared at the same 100 MHz.
  - **The same:** `clock` 985.5 ns, `rdtime` 204.8 ns, wr1k 460.0 MiB/s, wr1m 180.2 MiB/s and ev1 5,408 ns, against d4r2's 985.1, 204.7, 460.5, 180.8 and 5,409.
  - **Faster:** DDR reads, rd16m 159.0 MiB/s against 140.1 (+13.5%); DDR latency, chase64m 593 ns against 696 (−15%); the L2 chase, 413.5 ns against 432.4 (−4%).
  - **Slower:** DDR write streaming, wr16m 156.3 MiB/s against 182.4 (−14%). It's the second row for soc-2, beside the page-fault test.
  - That build pins its two-thread tests to CPUs 0 and 1, one core here, so its two-thread rows don't compare.

## The four-hart soak on u100: 33 rounds, one refused remote fence

The four-hart soak ([`../runs/soak4.sh`](../runs/soak4.sh), as on dr187b) ran on u100 in its own folder (`~/soak4-u100`), with the laptop's stamped loggers and a watch every 10 minutes ([`soak4.log`](soak4.log)).
- **The run:** 08:11 to 14:03 UTC on 10-23, about 5 h 50 min in three runs. It was restarted twice to fix its checks, then stopped for soc-2's OpenSBI fix.
- **33 rounds:** 106 stress passes, 106 DR-141 sets, 33 `hart_check`s and 33 rounds of hart stop and start passed, with COM5 quiet between the boots.
- **One event:** the refused remote fence below, in the first run's round 5. The 27 rounds after the restarts were clean.

**One refused remote fence, in round 5's hart stop (09:02 UTC)** ([`soak4.log`](soak4.log), [`soak_r5_E_hsm.txt`](soak_r5_E_hsm.txt); the same line on COM5 at 09:01:59.557, [`uart_COM5_boots2.txt`](uart_COM5_boots2.txt)):

    [ 3188.384705] CPU3: off
    [ 3188.393451] __sbi_rfence_v02_call: hbase = [1] hmask = [0x5] failed (error [-22])

- **What it is** (soc-2's reading, 10-23):
  - Linux keeps a CPU it has taken offline in each mm's cpumask (riscv with ASIDs), so a remote TLB flush shortly after a stop can still name the stopped hart. Here, 9 ms after hart 3 stopped, Linux asked OpenSBI to fence harts 1 and 3 (hbase 1, hmask 0x5).
  - OpenSBI 1.9 (`lib/sbi/sbi_ipi.c`, `sbi_ipi_send_many`) checks every hart in the mask against those it can interrupt: started, suspended or resuming. If any is missing, it returns `SBI_ERR_INVALID_PARAM` (Linux's −22, `EINVAL`) before sending any IPI.
- **So no hart in that call got the fence.**
  - For the stopped hart 3 that's harmless, since Linux flushes its TLB when it comes back online.
  - But the online hart 1 missed its fence too, and Linux prints the error without retrying. The risk is a stale translation on an online hart, for that mm's range, during the offline window.
  - The soak's self-checks saw no wrong result: the round came back to `0-3`, `t` was right on every CPU, and later rounds were clean.
- **Not a hardware fault:** OpenSBI refused on the hart's HSM state alone, and the IPI path was never used.
- **Exposure:** only around hart stop (hotplug); in steady operation no hart stops. It came once in 9 rounds of hart stop and start on u100 (3 in the bring-up, 6 in the soak), and never in dr187b's 60.
- **The fix** (the coordinator, 10-23): our own OpenSBI patch before M8's 72-hour run.
  - It fences the interruptible harts in the mask, skips stopped ones, and doesn't fail the call for them, as older OpenSBI did.
  - `fw_jump.bin` gets re-pinned in the same MR, with a hotplug soak round on the board.
- **Until then, this line in a hotplug round is expected.** The soak logs it as a known note, not a FAIL; a data error in the same window still counts as a failure.
- **The checks:** the soak's own kernel check didn't watch for SBI errors; `hsm_rounds.sh` caught the line. Then `hart_check.sh`, which read the whole boot's log, failed on it in round 6.
  - Both are fixed: the soak watches for SBI and HSM errors except this known line, and `hart_check.sh` reads only its own step's lines there.
  - The soak restarted at 09:14 UTC after 6 rounds, then again with the known-line note.

## soc-2's OpenSBI fence fix (tg1) on u100: no failed fence in 36 rounds of hart stop and start

**What it is:** OpenSBI 1.9 with Tanager's patch set tg1 (soc-2's commit fad99ab8; [`tg1_package_README.txt`](tg1_package_README.txt)). A remote fence or IPI whose mask names a stopped hart now reaches the started harts and succeeds, where 1.9 failed the whole call. A hart that doesn't exist is still an error.

**The install** ([`tg1_install.txt`](tg1_install.txt), the change log in [`../../README.md`](../../README.md)):
- after soc-2's go, its simulated four-hart Linux boot under lockstep having passed;
- only `p1:/tanager/fw_jump.bin` changed, to `62349a65…`; the old one is kept as `fw_jump.bin.b0094d23`.

**The round:**
- **The boot:** the four-hart tree came up clean, with OpenSBI v1.9, HART Count 4 and `/init` at 18.58 s. Hart 0 won the boot lottery this time.
- **30 rounds of hart stop and start, 8 s apart, with the stress running beside them** ([`../runs/hsm_stress.sh`](../runs/hsm_stress.sh), [`tg1_hsm_stress.txt`](tg1_hsm_stress.txt)):
  - all 30 came back to `0-3` with no trouble lines;
  - 7 stress passes ran beside them, with no failure;
  - **0 failed remote fences.**
  - The window's one other kernel line was a one-time `hrtimer: interrupt took 11940800 ns`: one timer interrupt handled 12 ms late while harts stopped and started under load.
- **`hart_check.sh` after it, 0 fails** ([`tg1_hartcheck.txt`](tg1_hartcheck.txt)): CoreMark validated and `t` right on all four harts, `mt` on all six pairs, and pingpong 1,216–1,225 ns on one core and 1,963–1,968 ns across cores.
- **The soak, its hotplug rounds included,** from 14:29 to 16:17 UTC ([`tg1_soak4.log`](tg1_soak4.log)):
  - 10 rounds in two runs: 33 stress passes, 33 DR-141 sets, 10 rounds of hart stop and start and 9 `hart_check`s passed, with **no failed remote fence**;
  - it stopped for rc2 ([`../rc2/README.md`](../rc2/README.md)), which carries tg1 too;
  - its one FAIL was CoreMark's 10 s rule inside `hart_check` (round 4, hart 3 alone, after a slow calibration; the CRCs were right). `hart_check.sh` now treats that as a note, as the soak's DR-141 check does, and the soak was restarted with it.
- **In all:** 40 rounds of hart stop and start with no failed fence on u100, against 1.9's one in its first 9; rc2 added 33 more. No oops, data error or trap line.

## The rc3 swap's measurements, u100's side (10-23, 20:33 to 20:53 UTC)

The coordinator's and soc-2's checks for rc3, run on u100 first so rc3 has something to compare with. u100 has the four-hart tree and tg1, with nothing else running.

**The two store-heavy DR-141 rows, pinned** ([`../runs/store_rows.sh`](../runs/store_rows.sh); [`store_rows.txt`](store_rows.txt) with CPUs 0 and 2, then [`store_rows_4cpu.txt`](store_rows_4cpu.txt) with all four). Each cell is the median cycles per operation of five runs in one process:

| | CPU 0 | CPU 1 | CPU 2 | CPU 3 |
|---|---|---|---|---|
| memset 1 MiB, first pass | 572,473 | | **533,780** | |
| memset 1 MiB, second pass | 566,200 | 572,862 | 572,071 | 563,792 |
| page fault, first pass | 4,983 | | 4,979 | |
| page fault, second pass | 5,019 | 4,994 | 4,980 | 4,945 |

- **memset 1 MiB's speed depends on the process, not the CPU.** CPU 2 ran at 534k in the first pass and 572k in the second.
  - 12 more processes on CPU 2 ([`../runs/memset_procs.sh`](../runs/memset_procs.sh), [`memset_procs.txt`](memset_procs.txt)) gave medians of 556,387 to 571,623.
  - That held with THP at `always` (8 processes) and at `never` (4). Each process's AnonHugePages was 0 kB, so the 1 MiB buffer never sits in a 2 MiB page.
  - Of the 18 processes, one ran at 534k and 17 at 556k–573k. u100's own DR-141 set (534,552) caught the fast case.
- **The page-fault test is steady:** 4,945–5,019 on every CPU, and u100's set had 4,964.
- **The idle board's interrupts** over 10 s: the timer 76–162 per CPU, mmc0 213 (CPU 0 only), IPIs 5–28 per CPU.
- **rc2's two rows, settled from its soak** ([`../rc2/soak_store_rows.txt`](../rc2/soak_store_rows.txt), [`../runs/soak_rows.sh`](../runs/soak_rows.sh)):
  - Every soak round kept its three DR-141 sets, and both rows sit within 1% of u100's in the pinned steps.
  - So rc2's +9.3% and +4.7% were its one set's luck, not step 7 ([`../rc2/README.md`](../rc2/README.md)).

**soc-2's sibling check** ([`../runs/sibling_check.sh`](../runs/sibling_check.sh); [`sibling_check.txt`](sibling_check.txt), [`sibling_check_2.txt`](sibling_check_2.txt)):
- memgap ran on CPU 0, with its thread sibling (CPU 1, idle) online and then offline, three runs each.
- The whole check ran twice, so the states went online, offline, online, offline.

| CPU 1 | wr1m (MiB/s) | wr16m (MiB/s) |
|---|---|---|
| online | 162.8–170.2, mean 165.4 | 148.6–153.0, mean 150.8 |
| offline | 175.1–180.3, mean 177.1 | 157.6–159.9, mean 158.7 |
| offline against online | +7.1% | +5.3% |

- **An idle sibling that is online costs a thread 5–7% of its write rate.** The effect followed the sibling's state both times, so it isn't drift.
- **The pages aren't it:** the 16 MiB buffer had 14,336 kB in 2 MiB pages in every run, in both states.
- **The sibling isn't the whole gap:** with it offline, wr16m stays 13% below d4r2's 182.

**memcal, bare metal** ([`../runs/memcal_release.sh`](../runs/memcal_release.sh) `u100`, records in [`../memcal/`](../memcal/)):
- verif-2's `memcal-big.bin` ran twice on u100's bitstream (`f8037f92…`), through tanager-host in ARM mode.
- u100 is a release build, so its lines came out on COM5 (`memcal_u100_1.txt`, `memcal_u100_2.txt`, `run_memcal_u100.txt`).
- The new dfx-mgr app `tanager-u100` is in the change log.
- The table gives cycles per test. d4r1's and d4r2's columns are the means of their two runs of 10-21, which agreed within 0.3%.

| | d4r1 | d4r2 | u100, run 1 | u100, run 2 | u100 against d4r2 |
|---|---|---|---|---|---|
| memset-16M (64 MiB) | 39,639,313 | 33,980,355 | 40,234,836 | 40,228,205 | **+18.4%** |
| memcpy-8M (32 MiB) | 24,850,115 | 24,804,166 | 23,461,665 | 23,501,902 | −5.3% |
| memset-1M (32 MiB) | 16,515,490 | 16,515,472 | 15,729,121 | 13,697,176 | −4.8%, −17.1% |
| memcpy-1M (32 MiB) | 24,802,790 | 24,788,030 | 23,499,195 | 23,491,976 | −5.2% |
| read-8M | 2,031,954 | 2,033,657 | 1,585,179 | 1,582,072 | −22.1% |
| chase-4M | 5,164,753 | 5,164,740 | 4,186,778 | 4,186,242 | −18.9% |

- **The 16 MiB write gap is in the hardware.**
  - With no Linux, u100's memset-16M takes 18.4% more cycles than d4r2's.
  - At 100 MHz that is 159.1 MiB/s against d4r2's 188.3. Linux's wr16m with the sibling offline agrees (158.7).
- **It is d4r1's figure:** u100 is 1.5% above d4r1's 161.5 MiB/s. Whatever made d4r2's 16 MiB memset 14% faster than d4r1's (10-21) isn't in u100. For soc-2.
- **Every other row is faster on u100:**
  - reads use 22% fewer cycles and the pointer chase 19% fewer;
  - both copies use 5% fewer.
- **memset-1M moved by 15% between u100's two runs.** d4r1's and d4r2's four runs agree to 0.001%. This row fits in the L2, and it is the only one that moved.

**soc-2's write-stream probe: at full speed u100 is at its slowest** (10-23, 23:33 UTC):
- **What it is:** soc-2's `wsd.bin` (sha256 `ae231676…`; its source `wsd.c` is beside it in soc-2's tree on home-wsl).
  - Hart 0 writes 16 MiB in 64-byte lines of eight `sd`, with k turns of an idle counted loop after each line. It prints the cycles per line for each k.
  - The other harts wait in WFI.
- **How it ran:** as memcal did (`memcal_release.sh` with `wsd.bin`), twice on u100's bitstream and twice on d4r2's.
  - d4r2's is the dfx-mgr app `tanager-d4r2`, the same `33e29f3d…` as p1's kept image, so nothing new was installed.
  - Records: `../memcal/wsd_*.txt` and `run_wsd.txt`.
- The table gives cycles per line; each image's two runs agree within 0.2%.

| k | 0 | 4 | 8 | 12 | 16 | 24 | 32 | 48 |
|---|---|---|---|---|---|---|---|---|
| u100 | **38.3** | **29.9** | 32.7 | 39.5 | 46.4 | 61.2 | 78.5 | 127.5 |
| d4r2 | **32.0** | 33.7 | 34.6 | 40.0 | 46.6 | 61.2 | 78.5 | 127.5 |
| soc-2's model for u100 | 30.1 | 30.8 | 32.7 | 39.4 | 46.4 | | | |

- **On u100, a slower issue makes the stream faster.**
  - Four idle turns per line take it from 38.3 to 29.9 cycles per line, that is from 159 to 204 MiB/s at 100 MHz.
  - So back-to-back lines cost u100 28% more than lines four turns apart. By the probe's own reading (`wsd.c`), the memory side reacts to the request pattern.
- **d4r2 has no such penalty:** its k = 0 is its best (32.0 cycles, 190 MiB/s), and a gap only adds time.
- **So u100's 16 MiB gap is the full-speed case alone:**
  - at full speed, 38.3 against 32.0 cycles (+19.5%; memcal's memset-16M gave +18.4%);
  - with a four-turn gap, u100 beats d4r2's best by 7%.
- **soc-2's model** matches u100 from k = 4 to 16, within 3%. It misses k = 0: 30.1 predicted, 38.3 measured.
- **From k = 24 the two images agree to the cycle,** so the idle loop sets the pace there.

## Since then

The board moved on to rc2 on 10-23 at 16:20 UTC ([`../rc2/README.md`](../rc2/README.md)).
- rc2's soak lost SD1's interrupt, and u100 came back on p1 at 20:17 UTC.
- u100 ran the rc3 swap's measurements above.
- **The soak from 21:03 UTC** ([`soak4_u100b.log`](soak4_u100b.log)) was stopped at a step boundary at 23:29 UTC, for soc-2's probe.
  - It had passed 14 rounds and round 15's first two steps: 44 stress passes, 44 DR-141 sets, 14 `hart_check`s and 14 rounds of hart stop and start.
  - 0 fails. Its 5 notes were CoreMark's timing rule, with the CRCs right.
  - No trouble line in the kernel log.
- **The soak restarted on u100 at 23:52 UTC** (`soak4-u100c`), after the probe, while rc3 builds.

The kept images:
- **u100 is kept on p1** in `tanager-u100/`, with tg1's `fw_jump.bin` and `fw_jump.bin.b0094d23`. To bring it back, in ARM mode: `FH_BACKUP=tanager-u100 bash ~/tanager/runs/fh_p1.sh back`.
- **The older kept images:** dr187b in `tanager-dr187b-80/`, and the two-core 100 MHz image in `tanager-d4r2-100/`. Both still hold `fw_jump.bin` `b0094d23…`.
