# sc3 on the board: stage C at 100 MHz, against sc2's 70 MHz (2026-10-17)

**Package:** `sc3-smt2-c2-100` from the SoC track; bitstream sha256 `e5b0f1be…`. Build facts in [`summary.txt`](summary.txt), the SoC track's steps in [`package_README.txt`](package_README.txt).
- **Tree:** main `5172c6a`: stage C merged, and DR-151's 1 GiB memory region.
- **Design:** two `smt2` cores (harts 0 and 2) at **100 MHz** (1200 MHz VCO / 12), the virtio window and the host DMA port, the commit trace on, no debug counters. WNS +0.347 ns, WHS +0.010 ns; 113,014 LUTs (96.5%).
- **Software:** the device trees are sc2's (nothing in them depends on the core clock). `tanager-host` `a88547b` (`52329089…`).
- **How it ran:** the app `tanager-sc3`, with Linux's fan control throughout (15/255, 33–34 °C).

## Step 1: Buildroot over virtio: pass

[`step1_run1.txt`](step1_run1.txt), console [`linux_shell_step1.txt`](linux_shell_step1.txt).
- **The disk:** `--blk` a 16 MiB random image, `--rng`. `virtio_blk virtio0: [vda] 32768 512-byte logical blocks`; `md5sum /dev/vda` = `c7490057fc67ad922cd990ba18cb3fa4`, the host's.
- **The RNG:** `/dev/hwrng` gives random bytes; `virtio1` interrupts 72.
- **The run:** login at 9 s, power-off at 23 s, `boot exit 0`.
- **dma status:** "1339 line reads, 2098819 line writes (one per burst within a line, an 8-byte store is one); 0 write bursts dropped".

## 70 against 100 MHz on the same Debian

`runs/bench_both.sh` ([`bench_both.txt`](bench_both.txt)) ran `runs/sc_bench.sh` on sc2, then sc3, back to back.
- **What is the same in both:** sc2netc's frozen Debian image (gcc and sysbench installed) reset before each run, `tanager-host` `52329089`, bridged, and [`../runs/bench_cmds.txt`](../runs/bench_cmds.txt).
- **What the commands do:**
  - wait for the IPv4 lease and for NTP sync;
  - `systemd-analyze`;
  - gcc builds and runs the loop;
  - sysbench;
  - ping;
  - a 64 MiB file from an HTTP server on the A53 through `br0` (`bash /dev/tcp`, the sha256 checked);
  - `apt-get download` of the 112 MB kernel package from Debian's mirror.
- **The consoles:** [`linux_shell_bench_sc2-70b.txt`](linux_shell_bench_sc2-70b.txt), [`linux_shell_bench_sc3-100b.txt`](linux_shell_bench_sc3-100b.txt).

| | sc2, 70 MHz | sc3, 100 MHz | 100/70 |
|---|---|---|---|
| Autologin (host clock) | 276 s | 191 s | 1.45× |
| `systemd-analyze` | 1 min 44.5 s + 2 min 32.4 s = 4 min 16.9 s | 1 min 11.8 s + 1 min 43.0 s = 2 min 54.8 s | 1.47× |
| `gcc -O2 t.c` | 14.06 s (CPU 11.65 s) | 10.74 s (CPU 8.23 s) | 1.31× (CPU 1.42×) |
| `./t`, 100 M iterations | 5.379 s | 3.744 s | 1.44× |
| sysbench cpu, 1 thread | 27.01 events/s | 38.96 | 1.44× |
| sysbench cpu, 2 threads | 54.58 events/s | 78.97 | 1.45× |
| sysbench memory | 41.43 MiB/s | 60.72 MiB/s | 1.47× |
| sysbench threads, 2 threads | 352 | 514 | 1.46× |
| `ping -s 1400` to the A53 | 1.321 ms average | 1.016 ms | |
| 64 MiB from the A53 (LAN, sha256 OK) | 9.72 s, 6.9 MB/s | 6.78 s, 9.9 MB/s | 1.43× |
| `apt-get download`, 112 MB (internet) | 1362 kB/s | **623 kB/s** | **0.46×** |

**Reading:**
- **On the board, everything scales by about the clock ratio (1.43×).** The CPU, the memory, the boot, and the network to the A53 (9.9 MB/s at 100 MHz). The gcc build scales less in wall time (1.31×) because it reads gcc's files from the virtio disk the first time.
- **The internet download was the exception here, and the TCP look did not reproduce it.**
  - Both sc3 runs gave 632 and 623 kB/s. Three sc2 runs gave 1.26–1.37 MB/s, the last one minutes before sc3's, with the same `tanager-host`.
  - At 100 MHz apt's `http` method used 62 s of CPU over 198 s, so the guest waited for packets. At 70 MHz it is CPU-bound (90 s over 112 s).
  - Dropped frames are the same (9 against 10).
  - In the later TCP look (below), the same download at 100 MHz ran at 1811 kB/s, 1.41× the 70 MHz run's, with TCP clean at both clocks. The slow runs were most likely the internet path or the mirror at that time.
- **The first sc3 bench** ([`bench_sc3-100.txt`](bench_sc3-100.txt)) ran with an older `tanager-host`, and timesyncd stepped the clock during `./t`, so its `time` was void. The table is from the clean back-to-back pair.

## Step 3: two-core lockstep

`runs/lockstep.sh` with p0f's 1 GHz-timebase 768 MiB tree (main has no `--freeze-time` yet; it comes with the SoC track's MR4), checker `694aff2`, `--harts=4` ([`ls_run1.txt`](ls_run1.txt), [`ls_sc3-tb1g.log`](ls_sc3-tb1g.log), [`ls_console_sc3-tb1g.txt`](ls_console_sc3-tb1g.txt)).

**Pass:** `PASS after 409133336 records (409098612 retired, 14550 traps, 20174 interrupts, 0 writebacks) in 4777.7 s, 85634 records/s`, with `967 loads read bytes another hart's recent write had replaced; 0 atomics read past a store`. Boot to the root shell and power-off, checker exit 0. Main's tree at 100 MHz (stage C, DR-151) matches Spike through a whole two-core Linux boot.

## The workload set (DR-141) at 100 MHz: pass, and the scores

[`chain_sc3.txt`](chain_sc3.txt) (the run log), consoles [`sc3_boot1.txt`](sc3_boot1.txt), [`sc3_boot2.txt`](sc3_boot2.txt), [`sc3_boot3.txt`](sc3_boot3.txt): `runs/bench.sh` with `BOOTS=3`.
- **What ran:**
  - the verification track's dr141-linux `fw_jump.bin` and bench `Image` (`7b4e2412…`, `edfd4c5f…`), as for p0f;
  - on p0f's bench device tree (`217a907c…`: harts 0 and 2, 1 GiB, the PMU map, `tanager.bench=1`). Nothing in it depends on the core clock.
- **Every boot passes:**
  - `TANAGER-BOOT-OK` and `TGLB-BEGIN … harts=2` at 6 s;
  - 54 of 54 measurement lines, CoreMark validated 6 times, `TGLB-END status=0`;
  - the power-off 323–326 s after the load (p0f at 70 MHz: 436 s).
- **Against p0f** (70 MHz, p0's tree, one boot), compared on the 5950X with `tests/bench/linux/tglb_compare.py`: [`cmp_cycles.md`](cmp_cycles.md), [`cmp_instret.md`](cmp_instret.md), [`cmp_ns.md`](cmp_ns.md).
  - **Cycles per operation: about 1% fewer in the CPU-bound tests.** CoreMark A −0.9%, B −1.0%, Dhrystone −1.0%, gzip −1.8%, sha256sum −0.9%, syscall −1.3%, forkexec −2.2%.
    - Instructions per operation fall by 0.5–1.7% in the same tests.
    - This is the timer tick: it costs about the same instructions per tick, ticks come at a fixed rate in real time, and at 100 MHz an operation lasts 30% less real time. The core does the same work per cycle.
  - **Memory-bound tests:**
    - memcpy 1 MiB +5.8% cycles. DRAM latency counted in core cycles grows with the core clock: the injector's native read latency is 25.7 cycles at 100 MHz against 21.4 at 70 MHz, that is 257 ns against 306 ns.
    - memset 1 MiB −10.3% (spread 4.2%).
  - **Time per operation:** −29% to −31% in the CPU-bound tests (the clock alone gives −30%). memcpy 1 MiB −25.9%, memset 1 MiB −37.2%. Linux reaches `/init` in 1.289 s against 1.728 s.

**The scores** (medians: sc3 9 runs over 3 boots, p0f 3 runs over 1 boot; flags from `tests/bench/linux/Makefile`):

| | p0f, 70 MHz | sc3, 100 MHz |
|---|---|---|
| CoreMark A (`-O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las`), per MHz | 2.745 | 2.769 |
| CoreMark A, iterations/s, one core | 192.2 | 276.9 |
| CoreMark B (`-O3 -funroll-loops`), per MHz | 2.269 | 2.292 |
| CoreMark B, iterations/s, one core | 158.9 | 229.2 |
| Dhrystone 2.1 (`-O3 -fno-common -fno-inline`), DMIPS/MHz | 1.392 | 1.406 |
| DMIPS (Dhrystones/s ÷ 1757) | 97.4 | 140.6 |
| CoreMark A, two copies at once, one per hart (below) | | 273.6 + 273.6 = **547.2** iterations/s (1.98× one copy) |

- **Run length:** each CoreMark run in the set lasts 14.5 s at 100 MHz (4,000 iterations), more than CoreMark's 10 s minimum.
- **Not certified scores:** these are our own builds and runs, not submitted to EEMBC.

## Two CoreMark copies at once, one per hart

`runs/coremark_pair.sh` with [`../runs/coremark_pair_cmds.txt`](../runs/coremark_pair_cmds.txt): the record is [`linux_shell_cmpair_sc3c.txt`](linux_shell_cmpair_sc3c.txt) ([`cmpair_sc3c.txt`](cmpair_sc3c.txt)).
- **The setup:** the same bench `Image`, booted on the bench tree without `tanager.bench=1` (`bench-manual-h02.dtb`, `59613a13…`; source [`bench-manual-h02.dts`](bench-manual-h02.dts)), so a shell starts instead of the set.
- **Pinning without `taskset`.** The Buildroot image has no `taskset` (BusyBox's applet is not built), and its kernel has no cpusets.
  - Each `coremark-a` pins itself, with `sched_setaffinity`, to the hart it first measures on (`tglb_pin` in `tests/bench/linux/tglb.h`).
  - The shell started both copies at once and read where they ran at 4 and 10 s: one on CPU 1 (hart 2, `Cpus_allowed_list` 1) and one on CPU 0 (hart 0, `Cpus_allowed_list` 0). `/proc/cpuinfo` maps CPU 0 to hart 0 and CPU 1 to hart 2.

| | Iterations/s | Total time | |
|---|---|---|---|
| One copy alone | 276.72 | 14.46 s | Correct operation validated |
| Two at once: the copy on hart 2 | 273.61 | 14.62 s | Correct operation validated |
| Two at once: the copy on hart 0 | 273.63 | 14.62 s | Correct operation validated |
| The pair | **547.24** | | 1.98× one copy |

- **Each copy runs 1.1% slower than alone.** The shared L2 and DRAM path, and the shell's work on CPU 0, are the candidates. CoreMark's data fits in the L1.
- **Use CoreMark's own figures for the pair, not the TGLB cycle counts.**
  - CoreMark times itself with `CLOCK_MONOTONIC`, so its iterations/s are sound.
  - The TGLB lines read the per-hart `mcycle` and `minstret`, which both copies share.
  - The second copy starts about 54 ms after the first, and its counts stop when the first copy exits (the first copy's perf events held the counters). So its cycle count falls about 54 ms short: 1,456.6 M against 1,461.9 M from its time.
- **An earlier pass** ([`linux_shell_cmpair_sc3b.txt`](linux_shell_cmpair_sc3b.txt)) read the placement every second from the shell on CPU 0.
  - The copy sharing CPU 0 with that loop made 260.4 iterations/s (the pair 534.0).
  - It also ran 0.73 s past the other copy, so its counts fell 0.79 s short, which fits the same 54 ms start offset.
  - The record pass reads the placement only twice.

## The TCP look at the internet download (for the SoC track)

`runs/tcp_both.sh` runs `runs/sc_tcp.sh` with [`../runs/tcp_cmds.txt`](../runs/tcp_cmds.txt) on sc2 (70 MHz), then sc3 (100 MHz), back to back.
- **The consoles:** [`linux_shell_tcp_sc2-70.txt`](linux_shell_tcp_sc2-70.txt), [`linux_shell_tcp_sc3-100.txt`](linux_shell_tcp_sc3-100.txt).
- **The A53's side:** `ip -s link` of `tanager0` and `br0`, in [`chain_sc3.txt`](chain_sc3.txt).
- **The setup is the bench's:** the frozen image reset, bridged, `tanager-host` `52329089`.
- **What the commands capture:** `ss -ti` every 5 s during the 112 MB `apt-get download`, then `nstat` and `ip -s link`.

| | sc2, 70 MHz | sc3, 100 MHz |
|---|---|---|
| `apt-get download`, 112 MB | 1 min 27 s, 1287 kB/s | 1 min 2 s, **1811 kB/s** (1.41×) |
| `time`: real, user, sys | 117.2, 90.7, 22.1 s | 82.7, 62.3, 18.3 s |
| RTT (`ss`): smoothed, minimum | 15.4 ms, 14.2 ms | 14.8 ms, 12.5 ms |
| Retransmits, timeouts, out-of-order, receive-queue and backlog drops (`nstat`) | all 0 | all 0 |
| Guest `eth0` RX packets, dropped | 78,538, 0 | 79,268, 0 |
| A53 `tanager0` TX packets, dropped | 78,548, 0 | 79,278, 0 |
| Segments in: on the wire (`ss` `segs_in`), as TCP saw them after GRO (`TcpInSegs`) | 76,116, 10,289 | 79,252, 7,912 |
| Segments out (ACKs) | 1,850 | 3,448 |

**So:**
- **The slow download did not come back.** This time 100 MHz ran 1.41× faster than 70 MHz, the clock ratio, and the guest was CPU-bound at both clocks (user + sys is 96–97% of real).
- **TCP is clean at both clocks:** no loss, no retransmits, no out-of-order segments, no drops at either end of the virtio link.
- **The two slow runs at 100 MHz** (623 and 632 kB/s) used the same 62 s of user CPU as this fast run, but over 198 s, so the packets came slower. That points to the internet path or the mirror at that time (`deb.debian.org` is a CDN), not to the core or the virtio link.
- **Gaps in the capture:**
  - `sysctl` printed "command not found", so the congestion-control lines are missing. The image does have it (procps, as `/usr/sbin/sysctl`), but `/usr/sbin` isn't on the `tanager` user's PATH (the SoC track). `ss` shows cubic, window scale 9 and 7.
  - Since then, the bench's download step captures the same way: `ss -ti` every 5 s while the download runs, then `nstat` and `ip -s link` ([`../runs/bench_cmds.txt`](../runs/bench_cmds.txt)). A slow run now shows at once whether it is the path.
