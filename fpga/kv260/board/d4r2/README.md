# d4r2 with the PMP tree fix: the Linux baseline in RISC-V mode (2026-10-21)

**What it is:** the reference the next product bitstream (the second thread in hardware) is compared against, as the coordinator asked on 10-21. It covers the boot timeline to `/init` and to the login, the DR-141 set, the sc3/d4 workload and memgap: three boots, each running the whole set once, with nothing else running.

**The configuration.** The next bitstream changes only the bitstream; everything else here stays.
- **The bitstream:** d4r2 (`33e29f3d…`, main ef44e5b7): d4r1 plus DR-176's SD1 fix, the I$ next-line prefetch, `STORE_PF_MAX` 3 and M7's step 1. Two `smt2` cores (harts 0 and 2) at 100 MHz.
- **RISC-V mode (DR-172):**
  - The A53 runs the mode hook and `riscv.scr`, then parks.
  - The RISC-V runs OpenSBI v1.9, U-Boot 2026.07, and Debian 13's own kernel `6.12.113+deb13-riscv64`, with its root on p3 through SD1.
  - `BOARD_CTRL` 3: the fan regulator on, the PMOD hook armed.
- **The tree:** soc-2's PMP fix (main 3912dcd3, `tanager.dtb` `9b1fb7ef…`). OpenSBI's banner on every boot: `Domain0 Region03 : 0x00000000ff5e0000-0x00000000ff5e0fff`, so every PMP region is a page or larger ([`../memgap/README.md`](../memgap/README.md)).
- **No network:** the laptop's ICS serves no DHCP. SSH went over the RISC-V's IPv6 link-local address, and the guest has no NTP; no figure here uses its clock.

**How:**
- [`../runs/baseline_boots.sh`](../runs/baseline_boots.sh) ran boots 1 to 3 from the laptop, 17:43 to 18:50 UTC. For each boot it does the following:
  1. Debian's reboot (the confirm unit keeps RISC-V mode), then the autologin on COM5;
  2. a wait for systemd's `running`, then for `systemd-tmpfiles-clean.timer` (15–16 min after boot), the only timer due in that window, so that nothing else runs during the set;
  3. [`../runs/baseline_set.sh`](../runs/baseline_set.sh) N over SSH, as root.
- `baseline_set.sh` runs once per boot, in this order:
  1. **The timeline:** the kernel's `Run /init`, `systemd-analyze`, the ttyS0 getty's start and multi-user's.
  2. **Main's DR-141 set** (`tg-lbench.sh 1`): the OS tests, then CoreMark A and B, Dhrystone and their rv64imafd forms. The programs were built from main (GCC 15.3) and are kept in `~/baseline/bin` on p3 with their sha256s ([`baseline_bin.sha256`](baseline_bin.sha256)).
  3. **The sc3/d4 workload** ([`../runs/bench_cmds.txt`](../runs/bench_cmds.txt)) without its network steps: `gcc -O2` builds `t.c` and runs it; the stress's 9-file project builds two files at a time; sysbench cpu on 1 and 2 threads, memory (1 KiB blocks) on 1 and 2 threads, and threads on 2.
  4. **soc-2's memgap**, once.
- **The serial logs:** the laptop's COM5 and COM7 loggers stamp each line with UTC ([`../runs/serial_log_ts.ps1`](../runs/serial_log_ts.ps1)), and [`../runs/boot_timeline.sh`](../runs/boot_timeline.sh) reads each boot's timeline from them.
- **The tables:** [`../runs/baseline_summary.sh`](../runs/baseline_summary.sh), and for the DR-141 set main's `tests/bench/linux/tglb_compare.py`, run on the build host.

**Records:**
- [`baseline_boot_1.txt`](baseline_boot_1.txt), [`baseline_boot_2.txt`](baseline_boot_2.txt), [`baseline_boot_3.txt`](baseline_boot_3.txt): each boot's set, as `baseline_set.sh` printed it. [`driver.txt`](driver.txt): the driver's lines.
- [`uart_COM5_baseline.txt`](uart_COM5_baseline.txt), [`uart_COM7_baseline.txt`](uart_COM7_baseline.txt): the stamped consoles, from the switch to RISC-V mode (17:36 UTC) to the end.
- [`timeline.txt`](timeline.txt): `boot_timeline.sh`'s lines. Its boot 1 is the switch from ARM mode (Ubuntu's reboot); its boots 2–4 are the baseline's 1–3.
- [`summary.md`](summary.md): `baseline_summary.sh`'s table.
- The DR-141 set: [`cmp_cycles.md`](cmp_cycles.md), [`cmp_instret.md`](cmp_instret.md), [`cmp_ns.md`](cmp_ns.md); against d4r1, for context only: [`cmp_d4r1_cycles.md`](cmp_d4r1_cycles.md), [`cmp_d4r1_instret.md`](cmp_d4r1_instret.md).
- [`journal_check.txt`](journal_check.txt): each boot's journal during its set.
- [`baseline_bin.sha256`](baseline_bin.sha256): the programs, built from main 62d045ea with `BRIDGE=1` (their sources last changed in f4562fd9).

**Every boot passed:** 21 measurement lines, CoreMark validated four times, `TGLB-END status=0`; `t` printed `5007905533300608` and the project `135808003256614222`.
- **Nothing else ran:** the CPUs were 99.7–99.9% idle in memgap's 10 s idle check.
- **The journals during the sets** show only the sets' own SSH and sudo lines, and the driver's next reboot timer at the end. Boot 2's hourly cron (an empty `cron.hourly`) ran 2 s before its set.

## The boot timeline

Seconds from the reset (the old kernel's `reboot: Restarting system` on COM5), from the stamped consoles:

| Milestone | Boot 1 | Boot 2 | Boot 3 | Mean |
|---|---|---|---|---|
| The A53's U-Boot (COM7) | 1.3 | 1.2 | 1.2 | 1.2 |
| The mode hook: `riscv, trial 0: writing trial 1` | 7.8 | 7.8 | 7.8 | 7.8 |
| `riscv.scr` parks the A53; OpenSBI starts on COM5 within 0.1 s | 11.8 | 11.8 | 11.8 | 11.8 |
| The RISC-V's U-Boot (2026.07) | 12.1 | 12.1 | 12.1 | 12.1 |
| `Starting kernel ...` | 32.1 | 32.1 | 32.1 | 32.1 |
| **`Run /init`** | 52.8 | 52.7 | 52.7 | **52.7** |
| The root mounted (`mmcblk0p3`, r/w) | 82.9 | 82.5 | 83.0 | 82.8 |
| **The autologin on ttyS0** | 161.0 | 160.0 | 160.6 | **160.5** |

- **The kernel's own stamps:**
  - `Run /init` at 18.68, 18.65 and 18.58 s (median 18.65 s, spread 0.5%);
  - the root mounted at 48.77, 48.45 and 48.90 s.
- **systemd-analyze:** 52.0 s (the kernel, with the initramfs) + 72.9 s (userspace) = 124.8 s. The ttyS0 getty is active at 123.3 s and multi-user at 124.8 s.
- **Debian's shutdown before the reset:** 13.4 s from wall's `The system will reboot now!` to the reset (13.5, 13.5 and 13.3 s). So a reboot takes 174 s to the next login.
- **Where the time goes:**
  - 12 s on the A53: the FSBL, its U-Boot, the hook, and `riscv.scr` with the bitstream, the PS set-up and the images;
  - 20 s in the RISC-V's U-Boot: extlinux, with the kernel and the initrd read through SD1;
  - 20.6 s from `Starting kernel` to `/init` (the kernel's clock reads 18.65 s there);
  - 30 s in the initramfs to the root;
  - 78 s of systemd to the login.
- **Against d4s2's first Debian boots in RISC-V mode** (10-19, the same kernel, the old tree, [`../d4/README.md`](../d4/README.md)):
  - then: `Run /init` at 19.8 s and the root at 50.1 s (kernel stamps), and the autologin under 3 minutes after the reboot;
  - now: 18.65 s (−5.8%), 48.7 s (−2.8%) and 174 s.
- The switch from ARM mode before boot 1 (Ubuntu's reboot) gave the same timeline within 2 s: `/init` at 53.0 s and the login at 162.2 s.

## The DR-141 set

The median of the three boots for each test, with the spread over the boots ((max − min) / median):

| Test | Cycles per op | Instructions per op | Spread (cycles) |
|---|---|---|---|
| CoreMark A | 220,006 | 340,900 | 0.2% |
| CoreMark B | 233,169 | 345,503 | 0.4% |
| Dhrystone | 205.5 | 324.9 | 0.5% |
| CoreMark A, rv64imafd | 219,649 | 341,005 | 0.9% |
| CoreMark B, rv64imafd | 230,379 | 345,241 | 0.3% |
| Dhrystone, rv64imafd | 204.6 | 324.7 | 0.2% |
| fork+exec (`/bin/true`) | 2,199,575 | 1,204,384 | 1.3% |
| syscall (`getpid`) | 620 | 452 | 1.8% |
| memcpy 64 B | 65.77 | 90.25 | 0.2% |
| memset 64 B | 34.92 | 45.69 | 0.2% |
| memcpy 4 KiB | 1,027 | 1,938 | 0.9% |
| memset 4 KiB | 699 | 691 | 1.1% |
| memcpy 1 MiB | 821,482 | 490,245 | 0.1% |
| memset 1 MiB | 552,413 | 174,667 | 0.3% |
| pipe, 64 KiB | 201,360 | 82,972 | 2.0% |
| tmpfs write, 64 KiB | 200,055 | 110,983 | 0.7% |
| tmpfs read, 64 KiB | 67,394 | 31,876 | 0.7% |
| page fault | 4,563 | 1,353 | 0.5% |
| TLB walk | 64.57 | 4.16 | 0.1% |
| gzip | 1,447,350,891 | 1,041,481,351 | 0.4% |
| sha256sum | 167,731,698 | 302,761,511 | 0.7% |

**The scores** (CoreMark/MHz = 10⁶ / cycles per iteration; DMIPS/MHz = 10⁶ / (cycles per Dhrystone × 1757); our own builds and runs, not submitted to EEMBC):

| | Per MHz | At 100 MHz | IPC | d4r1, stage C (10-19) | sc3, stage C (10-17) |
|---|---|---|---|---|---|
| CoreMark A | **4.55** | 454.5 iterations/s | 1.55 | 4.60 (IPC 1.56) | 2.77 |
| CoreMark B | **4.29** | 428.9 iterations/s | 1.48 | 4.36 (1.50) | 2.29 |
| Dhrystone | **2.77** DMIPS/MHz | 277 DMIPS | 1.58 | 2.82 (1.60) | 1.41 |
| CoreMark A, rv64imafd | 4.55 | 455.3 | 1.55 | | |
| CoreMark B, rv64imafd | 4.34 | 434.1 | 1.50 | | |
| Dhrystone, rv64imafd | 2.78 | 278 DMIPS | 1.59 | | |

**Against d4r1's set in stage C** (10-19, [`../d4r1/README.md`](../d4r1/README.md)): context, not a comparison of the two bitstreams.
- **CoreMark A, B and Dhrystone take 1.3%, 1.7% and 1.8% more cycles**, with 0.5–0.6% more instructions, so IPC is 0.8–1.3% lower.
  - The instruction counts differ because the programs come from another build (GCC 15.3 here).
  - The gap also crosses a bitstream (d4r1 to d4r2), a mode, and a kernel with its own timer rate, so this set can't split it.
- **The OS rows differ by much more, in both directions** (syscall +46%, tmpfs write +109%, pipe +64%, page fault −18%, TLB walk −43%). They reflect Debian's kernel and programs, not the bitstream:
  - **syscall:** 87% more instructions per `getpid` in Debian's kernel.
  - **gzip and sha256sum:** Debian's programs here, busybox's there (+16.7% and −11.0% instructions).
  - **page fault and TLB walk:** Debian's kernel gives the 64 MiB buffers transparent huge pages (THP is `always`). The page-fault test takes 33 faults for its 16,384 pages, against 16,384 under the bench kernel, and the TLB walk test walks 2 MiB pages, so both rows measure huge pages here.
- So the OS rows compare only with another run on this kernel: the next bitstream's.

## The sc3/d4 workload

| | Boot 1 | Boot 2 | Boot 3 | Mean | Spread | sc3, stage C (10-17) | s23, this configuration (10-21) |
|---|---|---|---|---|---|---|---|
| `gcc -O2 t.c`, wall time | 7.13 s | 7.12 | 7.14 | **7.13 s** | 0.3% | 10.74 s | |
| `gcc -O2 t.c`, CPU (user + sys) | 4.78 s | 4.74 | 4.79 | 4.77 s | 1.0% | 8.23 s | |
| `./t`, 100 M iterations | 2.87 s | 2.86 | 2.86 | **2.86 s** | 0.6% | 3.74 s | |
| The 9-file project, two at a time, wall time | 11.82 s | 11.83 | 11.81 | **11.82 s** | 0.2% | | |
| The 9-file project, CPU | 19.20 s | 19.22 | 19.18 | 19.20 s | 0.2% | | |
| sysbench cpu, 1 thread | 46.93 events/s | 47.04 | 47.08 | **47.02** | 0.3% | 38.96 | |
| sysbench cpu, 2 threads | 94.43 events/s | 94.39 | 94.40 | **94.41** | 0.0% | 78.97 | 93.81 |
| sysbench memory (1 KiB), 1 thread | 83.99 MiB/s | 84.18 | 84.47 | **84.21** | 0.6% | 60.72 | |
| sysbench memory (1 KiB), 2 threads | 145.54 MiB/s | 146.10 | 145.76 | **145.80** | 0.4% | | 146.23 |
| sysbench threads, 2 threads, 10 s | 780 events | 782 | 780 | **780.7** | 0.3% | 514 | 774 (2,323 in 30 s) |

- **Against sc3** (stage C on 10-17: the older core at the same 100 MHz, sc2netc's Debian over virtio, [`../sc3/README.md`](../sc3/README.md)):
  - `./t` runs 1.31× faster, sysbench cpu 1.20–1.21×, memory 1.39× and threads 1.52×;
  - gcc runs 1.51× faster in wall time and 1.73× in CPU time. It reads its files from SD1 here and from virtio there.
- **Against s23** (this configuration under the two-core stress, with 30 s runs, [`../stress/README.md`](../stress/README.md)): within 0.6%, 0.3% and 0.8%.
- **Against memgap's sysbench run on the fixed tree** ([`../memgap/sysbench_pmpfix.txt`](../memgap/sysbench_pmpfix.txt)): 146.11 MiB/s on two threads and 83.68 on one.

## memgap

The mean of the three boots, against the fixed tree's first measurement and stage C's (each three runs on one boot, [`../memgap/README.md`](../memgap/README.md)):

| Test | Stage C | The fixed tree, first | **This baseline** | Spread over the 3 boots |
|---|---|---|---|---|
| clock (`clock_gettime`) | 984.4 ns | 1,003 ns | **985.1 ns** | 0.1% |
| rdtime | 204.6 ns | 204.7 ns | **204.7 ns** | 0.1% |
| wr1k (L1 stores) | 461.1 MiB/s | 460.9 | **460.5** | 0.2% |
| wr1m | 181.5 MiB/s | 181.4 | **180.8** | 0.3% |
| wr16m | 181.9 MiB/s | 182.5 | **182.4** | 0.2% |
| rd16m | 140.4 MiB/s | 140.6 | **140.1** | 1.1% |
| chase16k | 31.03 ns | 31.00 | **31.43** | 2.2% |
| chase256k | 432.0 ns | 433.0 | **432.4** (boots 2 and 3; boot 1 469.3) | 8.4% |
| chase64m | 696.8 ns | 696.3 | **695.9** | 0.1% |
| pingpong | 2,218 ns | 2,205 | **2,210** | 1.5% |
| ev1 (sysbench's event, one thread) | 5,411 ns | 5,411 | **5,409** | 0.1% |
| ev2local | 5,832 ns | 5,842 | **5,832** | 0.1% |
| ev2shared | 11,148 ns | 11,154 | **11,097** | 0.6% |

- **The PMP fix holds on fresh boots:** every figure matches stage C's within 1.3%, except chase256k on boot 1.
- **chase256k on boot 1 (469.3 ns) is the baseline's one outlier.**
  - It is 8.5% above the other two boots and above all nine earlier runs (431.7–438.7 ns over three boots and three modes). It's the pointer chase that should stay in the L2.
  - memgap runs last in the set, after gcc and sysbench have churned memory, so its buffer gets different physical pages on each boot. A placement that puts more of the buffer's lines in some L2 sets than they have ways would send some loads to DDR: 14% of loads at chase64m's 696 ns would give 469 ns.
  - That is the likely reading, not a measured one. For the next bitstream, compare chase256k's median, or run memgap more than once per boot.

## What the next bitstream is compared on

- **The same set, run the same way.** Keep `~/baseline/` on p3 as it is, and run the two stamped loggers on COM5 and COM7. Then:
  1. `bash runs/baseline_boots.sh <COM5 log> <out dir> 1 3`, from the laptop;
  2. `runs/boot_timeline.sh <COM5 log> <COM7 log>` and `runs/baseline_summary.sh <out dir>/baseline_boot_*.txt`;
  3. `tglb_compare.py base=<these three> new=<those three>`, per metric, on the build host.
- **What counts as a change:** a difference larger than the row's spread here.
  - Most rows spread under 1%.
  - fork+exec, syscall, memset 4 KiB, pipe, rd16m, chase16k and pingpong spread 1.1–2.2%, and the systemd times 0.8–1.3%.
  - For chase256k, use the median.
- **With the second thread in hardware, Linux will see four harts.** The set's thread counts are fixed at one and two, so its two-thread rows will also show where the scheduler puts two threads: on one core or on two. Four-thread runs would be an addition, not part of this baseline.

**The board now:** RISC-V mode on d4r2 with the fixed tree, with Debian idle and the fan regulator on (`BOARD_CTRL` 3). The laptop's stamped loggers keep running on COM5 and COM7 until about 05:30 UTC on 10-22, so any reset while it idles is on record.

**Before the baseline:** the board had reset twice while it idled after s23, both times at the laptop's wake from hibernation ([`../stress/README.md`](../stress/README.md)). The mode record went back to riscv from Ubuntu at 17:36 UTC, and the switch boot came up as above.
