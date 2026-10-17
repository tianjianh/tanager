# DR-150 P0: two cores boot Linux on the KV260 (p0f, 2026-10-17)

**Package:** `p0f-smt2-c2-70` from the SoC track; bitstream sha256 `14833883…`; `tanager-host` `9774b126…`. Hashes in [`SHA256SUMS`](SHA256SUMS), build facts in [`summary.txt`](summary.txt), the SoC track's notes in [`package_README.txt`](package_README.txt).
- **Tree:** `aae33dcaa7cc` = soc-2's `038b30b` (main `537f23b` with core-2's `a0631fb`, plus soc-2's branch) + core-2's `24ada50`.
  - `24ada50` declares `rn_fire` before the free lists that take it ([st2](../st2/README.md) has the cause).
  - `038b30b` does the same for the debug counters' select, and `build.tcl` now fails a build whose synthesis reports an implicit net in our RTL.
- **Design:** two v1 `smt2` cores, one thread each (harts 0 and 2), at 70 MHz; commit trace and debug counters on; `AreaOptimized_high`; WNS +1.869 ns, WHS +0.010 ns.
- **Images:** p0's `fw_jump.bin` and `Image`. Device trees for harts 0 and 2: `tanager-kv260.dtb` (1 GiB, p0's), `-768m` (lockstep) and `-bench` (the PMU map, `tanager.bench=1`).
- **How it ran:** the app `tanager-p0f`, with the scripts in [`../runs/`](../runs/), and Linux's fan control throughout (15/255, 32–34 °C). The board went back to `k26-starter-kits` after each run.

## 1. Plain boot and the SMP test: pass

[`shell_run1.txt`](shell_run1.txt) and the console [`linux_shell_run1.txt`](linux_shell_run1.txt): `runs/plain.sh` (`tg.sh shell`, `DBG=1`, the commands in [`../runs/smp_cmds.txt`](../runs/smp_cmds.txt)).
- **OpenSBI:** "Platform HART Count : 2", "Domain0 HARTs : 0x0*,0x2*".
- **Linux:** "smp: Brought up 1 node, 2 CPUs" at 0.15 s; `TANAGER-BOOT-OK 6.18.56-tanager harts=2`. No warnings, RCU stalls or oopses.
- **Timing:** the login prompt 6 s after the load; the commands done at 108 s; the power-off reached the host at 113 s (`boot exit 0`).
- **`/proc/cpuinfo`:** processor 0 is hart 0 and processor 1 is hart 2, both `rv64imafdc_zicntr_zicond_zicsr_zifencei_zaamo_zalrsc_zca_zcd_zba_zbb_zbs_sstc`, `sv39`.
- **Both CPUs work in parallel:**
  - One shell busy loop (100,000 iterations) takes 48 s; two at once take 48 s.
  - `/proc/stat` user ticks: cpu0 9,620, cpu1 4,805.
  - Timer interrupts: 932 and 990.
  - IPIs both ways: rescheduling 59 and 38, function call 247 and 674.
- **The debug counters after the boot.** All the coherence channels carried traffic; L2 errors 0; levels `0x00044555`, nothing stalled:

  | Counter | bank 0 | bank 1 | core 0 L1D | core 1 L1D |
  |---|---|---|---|---|
  | A (requests) | 54,609,171 in | 51,502,896 in | 3,354,395 out | 1,988,329 out |
  | B (probes) | 194,258 out | 296,635 out | 223,710 in | 267,183 in |
  | C (probe acks, releases) | 6,996,381 in | 6,627,720 in | 9,024,431 out | 4,599,670 out |
  | D (beats) | 221,084,584 out | 208,320,005 out | 16,578,553 in | 9,748,664 in |
  | E (GrantAck) | 2,783,849 in | 2,558,875 in | 3,354,395 out | 1,988,329 out |
  | misses = AXI reads = fills | 854,182 | 847,234 | | |

- **The injector** (a second `tanager-host` while Linux ran): 1,701,411 reads, native latency average 21.7, maximum 61 cycles.

## 2. The workload set on two cores: pass

[`bench_run1.txt`](bench_run1.txt) and the console [`p0f_boot1.txt`](p0f_boot1.txt): `runs/bench.sh`, one boot of the verification track's DR-141 set (dr141-linux's `fw_jump.bin` and bench `Image`) on p0f's bench device tree.
- **Every check passes:**
  - `TANAGER-BOOT-OK` and `TGLB-BEGIN … harts=2` at 8 s;
  - 54 of 54 measurement lines; CoreMark validated 6 times;
  - `TGLB-END status=0`, then the power-off, 436 s after the load.
- **One false CHECK line:** `perf_events=4` is two events per hart. `tg.sh`'s check expected one hart's 2, and now scales with `harts`.
- **Against DR-141's `st` core** (`3eed95f`, one core at 60 MHz, 3 boots of the `default` profile). The comparison was made on the 5950X with `tests/bench/linux/tglb_compare.py`: [`cmp_cycles.md`](cmp_cycles.md), [`cmp_instret.md`](cmp_instret.md), [`cmp_ns.md`](cmp_ns.md).
  - **Instructions per operation:** the same within 1% (forkexec −3.3%). The set runs the same work on one thread.
  - **Cycles per operation:** within ±2% for most tests. Faster: forkexec −7.5%, syscall −7.7%, memcpy-1 MiB −6.8%. Slower: memset-1 MiB +4.8% (spread 2.9%).
  - **Time per operation:** 13–21% shorter, mostly from the clock (70 against 60 MHz is −14.3%). Linux reaches `/init` in 1.73 s against 2.47 s.
  - **Not an IPC verdict:** the trees differ by the core track's fn6–fn8 and DR-144 work, and the core is `smt2` (one thread used) against `st`, with a second core sharing the L2. It shows that two cores cost the single-thread set nothing visible.
