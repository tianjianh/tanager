# rc2 on the board: the near-final release preview at 100 MHz, with M7's step 7 (2026-10-23)

**What it is:** soc-2's `rc2u100-riscv` (tarball `0390785b…`, bitstream `0516f960…`; [`package_H1-README.txt`](package_H1-README.txt), [`package_SHA256SUMS`](package_SHA256SUMS)), the first board image with M7's step 7, the two threads' throughput step.
- **The build:** spikes-2's snapshot 9dbbad72 of main, with:
  - DR-183's PMP checks at TLB fill on by default;
  - fpu-2's step-7 cut;
  - core-2's marg3 and CoRR snoop marking;
  - soc-2's checker requests from registers.
- **The form:** a release build like u100, with WNS +0.296 ns and 112,360 LUTs.
- **What changes against u100:** only the bitstream. It carries OpenSBI with tg1 (`fw_jump.bin` `62349a65…`), which u100 had already been switched to; the trees, U-Boot d4 and the kernel are the same.
- **A known gap:** core-2's FENCE.I sweep fix is not in it. In simulation the four-hart litmus aborts on fence.i batches, so programs that write code and run it were to be watched.

**How:**
- **The install, after soc-2's go** ([`install.txt`](install.txt), the change log in [`../../README.md`](../../README.md)): u100's p1 files went to `tanager-u100/` (dr187b stays in `tanager-dr187b-80/`), then rc2's `p1:/tanager/` files went in.
- **The steps, in this order:**
  1. the four-hart tree, and `hart_check.sh`;
  2. three rounds of hart stop and start, the stress 10 of 10, then 30 rounds of hart stop and start under the stress ([`../runs/hsm_stress.sh`](../runs/hsm_stress.sh)), which tests tg1;
  3. the baseline's set, memgap with `-c 0,2` and `-c 0,1`, and soc-2's two checks ([`../runs/ddr_write2.sh`](../runs/ddr_write2.sh));
  4. one boot on the one-core two-hart tree, then the four-hart tree again for the soak.
- **The logs:** every console is logged with UTC line stamps ([`uart_COM5_boot1.txt`](uart_COM5_boot1.txt), whose part from 16:21 UTC is rc2's; [`uart_COM5_stress.txt`](uart_COM5_stress.txt) with its start and stop; [`uart_COM5_boots2.txt`](uart_COM5_boots2.txt); [`uart_COM7.txt`](uart_COM7.txt); [`timeline.txt`](timeline.txt)).

## The results: every step passed, with no fault

**No SIGILL, SIGSEGV, SIGBUS, oops, panic, access fault, trap line or failed remote fence** in rc2's console and kernel logs, across:
- three boots;
- the checks, the stress and the 30 hotplug rounds beside it;
- the set, with thousands of program starts through the dynamic loader;
- the memgap runs.

The FENCE.I gap didn't show in this workload.

| | Four harts (two boots) | One core, two harts | u100, four harts |
|---|---|---|---|
| OpenSBI / Linux | HART Count 4; 4 CPUs; siblings 0-1 and 2-3 | HART Count 2; 2 CPUs | the same |
| **`Run /init`**, from the reset | **53.0 and 52.2 s** | 54.7 s | 52.3 and 52.1 s |
| `Run /init`, the kernel's clock | 19.17 and 18.39 s | 20.92 s | 18.52 and 18.31 s |
| The root mounted (kernel's clock) | 50.54 s (first boot) | 58.91 s | 47.98 and 48.28 s |
| **The login**, from the reset | **156.6 and 155.8 s** | 202.6 s | 154.4 and 156.0 s |
| `hart_check.sh` | 0 fails ([`hartcheck_h0123.txt`](hartcheck_h0123.txt)) | 0 fails ([`hartcheck_h01.txt`](hartcheck_h01.txt)) | 0 fails |

- **Each hart:** CoreMark A validated on every hart (448.7–453.7 iterations/s), and `t` right on every hart (2.93–2.95 s).
- **Pairs:** `mt` was right on every pair. The pingpong is 1,216–1,219 ns on one core and 1,967–1,969 ns across cores, u100's.
- **Hart stop and start** ([`hsm_rounds.txt`](hsm_rounds.txt)): three rounds back to `0-3`, `t` right after, no trouble line.
- **The stress:** 10 of 10 passes clean (`STRESS stop after pass 10, fails=0`), at 113–117 s each.
- **tg1 under the stress** ([`hsm_stress.txt`](hsm_stress.txt)): 30 rounds of hart stop and start, 8 s apart, all back to `0-3`. The 7 stress passes beside them were clean, with **0 failed remote fences** and no other kernel line.

## Per MHz: rc2 is u100 (its two slow store rows were one set's luck)

**The DR-141 set** ([`set_h0123.txt`](set_h0123.txt); cycles per operation against d4r2's baseline, [`cmp_rc2_cycles.md`](cmp_rc2_cycles.md), [`cmp_rc2_instret.md`](cmp_rc2_instret.md)):

| Test | rc2 | u100 | Spread (d4r2) |
|---|---|---|---|
| CoreMark A / B | +1.3% / −0.3% | +0.3% / −0.5% | 0.2% / 0.4% |
| Dhrystone | −0.6% | −0.7% | 0.5% |
| memcpy 1 MiB | −10.4% | −10.5% | 0.1% |
| TLB walk | −16.6% | −16.8% | 0.1% |
| **memset 1 MiB** | **+5.8%** | −3.2% | 0.3% |
| pipe | +3.9% | +2.0% | 2.0% |
| **page fault** (2 MiB huge pages cleared) | **+13.9%** | +8.8% | 0.5% |

- Against u100 directly, every other row is within 1.2%: CoreMark A +1.0%, B +0.2%, Dhrystone +0.1%, and syscall, fork+exec, the 64 B and 4 KiB copies, tmpfs, gzip and sha256sum.
- **Two store-heavy rows looked slower against u100,** both beyond the 0.3–0.5% spread: memset 1 MiB +9.3% and the page-fault test +4.7%.
  - **Later (10-23): they aren't.** Every soak round kept its three DR-141 sets ([`soak_store_rows.txt`](soak_store_rows.txt), [`../runs/soak_rows.sh`](../runs/soak_rows.sh)).
  - With the same pinning, rc2's medians match u100's within 1% (cycles per operation, and the number of sets):

    | | rc2 | u100, OpenSBI 1.9 | u100, tg1 |
    |---|---|---|---|
    | memset 1 MiB, the set on CPUs 2–3 beside the stress | 579,089 (16) | 578,632 (15) | 579,596 (7) |
    | memset 1 MiB, the set on CPUs 0–1 | 579,896 (16) | 580,562 (15) | 579,853 (7) |
    | page fault, the set on CPUs 2–3 | 4,897 | 4,933 | 4,970 |
    | page fault, the set on CPUs 0–1 | 4,930 | 4,956 | 4,985 |

  - In the unpinned step rc2 was faster (memset 582k against 617k and 626k).
  - memset 1 MiB's speed moves from process to process, between about 534k and 573k on an idle u100 ([`../u100/README.md`](../u100/README.md)). A single set, like rc2's DR-141 set at the top of this section, can land anywhere in that range.
- **Per second at the same clock,** rc2 matches d4r2 and u100: `./t` 2.88 s, sysbench cpu 47.06 and 94.50 events/s, memory 84.03 and 145.68 MiB/s.

**memgap** (main 4fe536ec's build with `-c`, three runs each; in ns):

| | rc2, two cores (`-c 0,2`) | u100, two cores | rc2, one core (`-c 0,1`) | u100, one core |
|---|---|---|---|---|
| pingpong | 1,962.6 | 1,957.1 | 1,211.0 | 1,210.9 |
| ev1 | 5,417.9 | 5,430.1 | 5,418.5 | 5,415.4 |
| ev2local | 5,805.1 (+7.1% over ev1) | 5,813.5 | 8,429.3 | 8,461.2 |
| ev2shared | 8,651.8 | 8,639.9 | 8,429.9 | 8,448.1 |

With the older build (one run, [`memgap_rc2_pre-c.txt`](memgap_rc2_pre-c.txt)), rc2 reads `rdtime` 204.7 ns, wr1k 460.5 MiB/s, wr1m 180.2, wr16m 156.3, ev1 5,418 ns: u100's.

## soc-2's two checks: the harts are symmetric, and DDR writes don't saturate

[`ddr_write2.txt`](ddr_write2.txt):
- **memgap's single-thread rows on each CPU** (`taskset -c 0` to `3`) agree within run-to-run noise:
  - wr1k 345.9–347.2 MiB/s, wr16m 155.4–156.2, rd16m 162.5–163.2;
  - `rdtime` 214.9–215.4 ns, chase16k 31.0–31.1 ns, chase64m 593–597 ns, ev1 5,409–5,437 ns.
  - The exceptions: `clock` read 1,059 ns on CPU 2 against 986–990 on the others in that run, and chase256k 411–427 ns, which moves with page placement.
- **DDR writes, each thread on its own 16 MiB buffer** (sysbench memory, writes, local scope):

  | | MiB/s | Against one thread |
  |---|---|---|
  | One thread (CPU 0) | 159.6 | 1× |
  | Two threads on two cores (CPUs 0 and 2) | 331.1 | 2.07× |
  | Two threads on one core (CPUs 0 and 1) | 178.4 | 1.12× |

- **memgap's wr16m agrees:** 155.9 MiB/s alone on CPU 0, and 155.9 + 157.2 = 313.1 MiB/s with two processes at once on CPUs 0 and 2.
- **So DDR writes don't saturate at one thread's rate.** Two cores write twice as much, and the DDR controller takes 331 MiB/s.
  - The per-thread figure (about 156 MiB/s, against d4r2's 182 with one binary) is a limit inside each core's write path.
  - It isn't the PS DDR controller: one core's two threads share that limit (1.12×).

## The soak: SD1's interrupt lost after 15 hotplug rounds (20:07 UTC), and u100 back

The four-hart soak ([`soak4.log`](soak4.log)) ran on rc2 from 17:30 UTC on its second four-hart boot.
- **It passed 15 rounds:** 47 stress passes, 47 DR-141 sets, 15 `hart_check`s and 15 rounds of hart stop and start. Its 7 notes were CoreMark's timing rule.
- **Then, 27 s into round 16's step C** (the stress and the DR-141 set, both unpinned), the SD card's interrupt stopped arriving. This was 4.6 min after round 15's hart stop and start.

**What the board showed** ([`uart_COM5_boots2.txt`](uart_COM5_boots2.txt), [`sd1_event_dmesg.txt`](sd1_event_dmesg.txt), [`sd1_event_irq.txt`](sd1_event_irq.txt), [`sd1_event_interrupts.txt`](sd1_event_interrupts.txt)):
- **The first line:** `mmc0: Timeout waiting for hardware interrupt` at 9532.03 s (20:07:01 UTC), then the same every 10 s: 41 times by the reset, with one `Timeout waiting for hardware cmd interrupt`.
- **The first register dump:**
  - `Int stat: 0x00000002` (Transfer Complete pending) with `Int enab` and `Sig enab` both `0x03ff008b`, so SD1 was raising its interrupt.
  - Later dumps add the error bits as the driver retries (`Int stat: 0x01018002`).
- **The interrupt never reached Linux:**
  - `mmc0` (PLIC source 21, IRQ 14) stayed at 50,361 on CPU0 over 12 s while the driver timed out.
  - Its affinity was 0-3 with effective CPU0, all four CPUs were online, and the timer interrupts kept counting on every CPU.
- **Blocked tasks:** `jbd2/mmcblk0p3`, `systemd-journal`, kworkers, `tg-lbench` and `bash` were reported blocked for more than 120 s (10 such reports). The I/O to the root never came back.
- **What it looks like:** DR-176's lost SD1 interrupt (d4r1, a PLIC claim read twice by a replayed MMIO read), fixed in d4r2. u100 and dr187b never showed it, in 99 soak rounds (dr187b 56, u100 43) and 136 rounds of hart stop and start (dr187b 59, u100 77) between them. rc2 adds step 7, core-2's marg3 and CoRR snoop marking, and soc-2's checker requests from registers.
- **For soc-2 and core-2,** together with the kernel log and the console.

**The way back** (the coordinator's instruction: if rc2 destabilizes, back to u100):
1. **Saved first:** the soak log, the kernel log and `/proc/interrupts`, read over SSH while the shell still answered from the page cache.
2. **The reset:** sysrq's immediate reboot at 20:15 UTC, because a clean reboot would hang syncing the card. The unconfirmed RISC-V boot then fell back to ARM mode (`tanager-mode: ARM mode`), as DR-172 designs.
3. **u100's files back on p1:** `FH_BACKUP=tanager-u100 bash ~/tanager/runs/fh_p1.sh back`, logged in the change log.
4. **u100 booted** with four harts at 20:17 UTC. The initramfs replayed the root's journal (`tanager-root: recovering journal`), with no ext4 or I/O error after, and `hart_check.sh` gave 0 fails ([`u100_back_hartcheck.txt`](u100_back_hartcheck.txt)).

## The board now

u100 with the four-hart tree and tg1.
- **It ran the rc3 swap's measurements** ([`../u100/README.md`](../u100/README.md)): the store rows pinned, soc-2's sibling check, and memcal in ARM mode.
- **It soaks from 21:03 UTC** (`soak4-u100b`) while rc3 builds.

rc2's package stays on the A53 (`~/tanager/rc2u100-riscv-pkg/`) for a rerun:
- **rc2 again,** in ARM mode: `FH_BACKUP=tanager-u100 bash ~/tanager/runs/fh_p1.sh install ~/tanager/rc2u100-riscv-pkg/rc2u100-riscv`;
- **dr187b:** `FH_BACKUP=tanager-dr187b-80 bash ~/tanager/runs/fh_p1.sh back`;
- **the two-core 100 MHz image:** `bash ~/tanager/runs/fh_p1.sh back`.
