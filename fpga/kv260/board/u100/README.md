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

## The board now: the four-hart soak on u100

The board is on u100 with the four-hart tree. The four-hart soak ([`../runs/soak4.sh`](../runs/soak4.sh), as on dr187b) runs there in its own folder (`~/soak4-u100`), with the laptop's stamped loggers and a 12-hour watch.

**One refused remote fence, in round 5's hart stop (09:02 UTC)** ([`soak4_first.log`](soak4_first.log), [`soak_r5_E_hsm.txt`](soak_r5_E_hsm.txt); the same line on COM5 at 09:01:59.557, [`uart_COM5_boots2.txt`](uart_COM5_boots2.txt)):

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
  - The soak restarted at 09:14 UTC after 6 rounds, then again with the known-line note. dr187b stays on p1 in `tanager-dr187b-80/` and the two-core 100 MHz image in `tanager-d4r2-100/`. To go back to dr187b, in ARM mode: `FH_BACKUP=tanager-dr187b-80 bash ~/tanager/runs/fh_p1.sh back`.
