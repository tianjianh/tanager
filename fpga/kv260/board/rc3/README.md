# rc3 on the board: the release candidate at 100 MHz (2026-10-24)

**What it is:** soc-2's `rc3u095r-riscv`, the release candidate on main's RTL (tarball `8e53c0b8…`, bitstream `2a47608a…`; [`package_H1-README.txt`](package_H1-README.txt), [`package_SHA256SUMS`](package_SHA256SUMS)).
- **The build:** spikes-2's rc3_u095r from a1589f00, a snapshot of coord/rc3 (234fc366, main's RTL). It has:
  - M7's step 7 with fpu-2's timing cut;
  - DR-183's PMP checks at TLB fill, with soc-2's checker registers;
  - core-2's marg3;
  - the FENCE.I sweep fix (679ceb2c);
  - CoRR snoop marking with its device-load fix (b51bbbf6, b30b57b3).
- **The form:** a release build like u100 and rc2. Two `smt2` cores with hart 1 on, at 100 MHz, the UltraRAM register file with `clk2x` at 200 MHz. WNS +0.748 ns, WHS +0.006 ns, 112,806 LUTs (96.32%).
- **Against rc2 and u100, only the bitstream changes** (and `riscv.scr`'s mkimage header). OpenSBI with tg1, the trees, U-Boot d4 and the kernel are the same files.
- **New against rc2:**
  - CoRR's device-load fix, for rc2's lost SD1 interrupt;
  - the FENCE.I sweep fix, which closes rc2's known gap.

**How:**
- **u100's soak** stopped at a step boundary at 01:37 UTC ([`../u100/README.md`](../u100/README.md)).
- **The install** ran in ARM mode at 01:41 UTC, after soc-2's go ([`install.txt`](install.txt), the change log in [`../../README.md`](../../README.md)). u100 stays in p1's `tanager-u100/`, and dr187b behind it.
- **The bare-metal checks came first,** on the same ARM-mode round trip: memcal and soc-2's write-stream probe on rc3's bitstream ([`../runs/rc3_bare.sh`](../runs/rc3_bare.sh), under `systemd-run` so the A53's network gaps couldn't end it). The coordinator's list had memcal after the Linux checks; running it here saved a round trip.
- **Then RISC-V mode,** with soc-2's steps (H1-README): the four-hart tree, `hart_check.sh`, the hotplug rounds, the stress, the set, memgap and soc-2's checks, then M8's 72-hour stress.
- **The logs:** every console is logged with UTC line stamps. [`timeline.txt`](timeline.txt) is the boot's timeline.

## The results

**The four-hart boot** (01:48 UTC; [`timeline.txt`](timeline.txt)):
- OpenSBI `Platform HART Count : 4`, `smp: Brought up 1 node, 4 CPUs`, nproc 4, siblings 0-1 and 2-3.
- From Ubuntu's reboot: OpenSBI at 11.9 s, `/init` at 51.9 s (the kernel's clock 18.11 s), the root at 81.7 s and the login at 154.2 s. That is u100's: `/init` at 52.1–52.3 s, the login at 154.4–156.0 s.
- No trouble line in the kernel log.

**`hart_check.sh`, 0 fails** ([`hartcheck_h0123.txt`](hartcheck_h0123.txt)):
- CoreMark A validated on every hart (450.4–453.9 iterations/s), and `t` right on every hart (2.93–2.95 s).
- `mt` right on all six pairs, and `proj` four at a time in 10.78 s.
- The pingpong is 1,218.5 and 1,223.6 ns on one core, and 1,961.5–1,972.1 ns across cores, u100's.

**Hart stop and start** ([`hsm_rounds.txt`](hsm_rounds.txt)): three rounds back to `0-3`, `t` right on every CPU after, no trouble line and no remote-fence line.

**Hart stop and start under the stress** ([`../runs/hsm_stress.sh`](../runs/hsm_stress.sh) `30 8`, [`hsm_stress.txt`](hsm_stress.txt)):
- 30 rounds, 8 s apart, all back to `0-3`;
- the 7 stress passes beside them were clean;
- **0 failed remote fences**, and no other kernel line.

**The stress, 10 of 10** on COM5's console ([`uart_COM5_stress.txt`](uart_COM5_stress.txt), with its start and stop): `STRESS stop after pass 10, fails=0`, at 113–119 s a pass.

**The DR-141 set** ([`set_h0123.txt`](set_h0123.txt); cycles per operation against d4r2's baseline, [`cmp_rc3_cycles.md`](cmp_rc3_cycles.md), [`cmp_rc3_instret.md`](cmp_rc3_instret.md)):
- CoreMark validated in all four of its runs (A, B and their rv64imafd builds), and `TGLB-END status=0`.
- **Against u100, the rows match:** CoreMark A +0.3%, B +0.3%, Dhrystone +0.1%. The copies, the TLB walk, tmpfs, gzip and sha256sum are within 0.9%, and the page-fault test is +0.3% (4,981 against 4,964).
- **Three rows differ by more than 1%:** pipe +3.1% (its spread is 2.0%), fork+exec +1.3% (spread 1.3%) and memset 1 MiB +8.3%.
  - memset 1 MiB's one set (578,779) lands in the range a single process can give, as rc2's did.
  - The pinned rows below compare it properly, and the soak's sets will settle it.

**memgap** (main 4fe536ec's build with `-c`, three runs each, in ns; `memgap_rc3_c0*_*.txt`):

| | rc3, two cores (`-c 0,2`) | u100, two cores | rc3, one core (`-c 0,1`) | u100, one core |
|---|---|---|---|---|
| pingpong | 1,958.4 | 1,957.1 | 1,211.4 | 1,210.9 |
| ev1 | 5,417.8 | 5,430.1 | 5,413.9 | 5,415.4 |
| ev2local | 5,811.1 | 5,813.5 | 8,432.9 | 8,461.2 |
| ev2shared | 8,619.7 | 8,639.9 | 8,421.0 | 8,448.1 |

**soc-2's checks, as on u100** (board MR38):
- **The store rows pinned** ([`store_rows_4cpu.txt`](store_rows_4cpu.txt)):
  - memset 1 MiB medians are 564,856, 575,807, 568,304 and 573,707 on CPUs 0–3, against u100's 566,200, 572,862, 572,071 and 563,792;
  - the page-fault test is 4,969–4,995, against u100's 4,945–5,019.
- **memset 1 MiB, process by process** ([`memset_procs.txt`](memset_procs.txt)): 12 processes on CPU 2 had medians of 567,319 to 582,495, against u100's 556,387 to 571,623, so about 1.6% higher.
  - Again no 2 MiB pages, with THP at `always` or `never`.
  - These ran after rc3's stress and hotplug runs, and the row depends on where pages land. The soak's pinned sets will compare it with u100's under the same conditions ([`../runs/soak_rows.sh`](../runs/soak_rows.sh)).
- **The sibling check** ([`sibling_check.txt`](sibling_check.txt)):
  - with CPU 1 online, wr16m 149.6–150.6 MiB/s (u100 148.6–153.0);
  - with it offline, 157.8–158.1 (u100 157.6–159.9).
  - So the idle sibling costs 5.3% on rc3 too.

## M8's 72-hour stress

The four-hart soak ([`../runs/soak4.sh`](../runs/soak4.sh)) runs in `~/soak4-rc3` from 02:43 UTC on 10-24, to about 02:43 UTC on 10-27.
- **Each round:** the stress beside a DR-141 set three times (pinned both ways, then unpinned), then `hart_check.sh`, then a round of hart stop and start. The kernel's log is checked after each step.
- **The FAIL rules:** any of the stress's or the set's own failures, a CRC error, or a kernel line from the soak's list.
  - The list adds SD1's `mmc0: Timeout waiting` for rc3, from soc-2's watch list.
  - CoreMark's 10 s timing rule stays a note.
- **The laptop's watch** reads the soak's log every 10 minutes for 74 hours, and COM5 for trouble or a reset, SIGILL, SIGSEGV and SD1 timeouts included.
- **The loggers:** COM5 and COM7 were logged with UTC stamps for the whole run.

**Stopped at the user's request after 2 h 43 min** ([`soak4_rc3.log`](soak4_rc3.log)): the user travels, and the laptop goes too.
- **The tally,** from 02:43 to 05:26 UTC on 10-24:
  - 16 rounds, 48 stress passes, 48 DR-141 sets, 16 `hart_check`s and 16 rounds of hart stop and start;
  - 64 kernel checks passed, **0 FAIL**;
  - its one note was CoreMark's timing rule, with the CRCs right.
- **No trouble anywhere:** none in the kernel log at the stop, and none on COM5 for the whole run (no SD1 timeout, SIGILL, SIGSEGV, oops or reset).
- **The stop:** a step boundary (`SOAK4-END after round 16`), then the watcher and the loggers stopped cleanly.
- **M8's 72-hour gate stays open.** The 72-hour run restarts on rc3 when the user is back and says so.

## The board now

Idle in ARM mode, left so while the laptop is away:
- **The mode record says `arm`.** Ubuntu is up with k26-starter-kits loaded and fancontrol running the fan.
- **Nothing runs:** no `tanager-host`, `tg.sh` or test, so nothing can read the PL while the laptop is gone.
- **The A53's network** keeps its link-local address since 05:29 UTC (the change log; [`../a53net/link_local.txt`](../a53net/link_local.txt)).
- **p1:/tanager/ holds rc3.** To boot it, in ARM mode: `bash ~/tanager/runs/fh_p1.sh riscv`, then a reboot.
- **u100 is kept** in `tanager-u100/`, and dr187b and the two-core d4r2 image behind it.

**Bare metal, in ARM mode** (records in [`../memcal/`](../memcal/): `memcal_rc3_*.txt`, `wsd_rc3_*.txt`, `run_rc3.txt`):
- **memcal is u100's, as soc-2 expected.** memset-16M took 40,270,386 and 40,257,053 cycles, against u100's 40,231,520 (+0.08%): 159.0 MiB/s, against d4r2's 188.3. Every other row is within 0.2% of u100's.
- **memset-1M gave u100's two values in the same order:** 15,728,983 on the first run after the load, then 13,697,183. Its 15% spread follows the run order, not chance.
- **soc-2's write-stream probe gave u100's curve** within 0.2%, in cycles per 64-byte line:

| k | 0 | 4 | 8 | 12 | 16 | 24 | 32 | 48 |
|---|---|---|---|---|---|---|---|---|
| rc3 (two runs) | 38.3, 38.4 | 29.9, 29.9 | 32.7, 32.7 | 39.5, 39.5 | 46.4, 46.4 | 61.2 | 78.5 | 127.5 |
| u100 | 38.3 | 29.9 | 32.7 | 39.5 | 46.4 | 61.2 | 78.5 | 127.5 |
| d4r2 | 32.0 | 33.7 | 34.6 | 40.0 | 46.6 | 61.2 | 78.5 | 127.5 |

- So rc3 keeps u100's full-speed write penalty: soc-2's L2 pacing fix isn't in it.
