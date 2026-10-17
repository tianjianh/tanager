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
- **The internet download is the exception, and it repeats.**
  - Both sc3 runs gave 632 and 623 kB/s. Three sc2 runs gave 1.26–1.37 MB/s, the last one minutes before sc3's, with the same `tanager-host`.
  - At 100 MHz apt's `http` method used 62 s of CPU over 198 s, so the guest waits for packets. At 70 MHz it is CPU-bound (90 s over 112 s).
  - Dropped frames are the same (9 against 10).
  - Something in TCP over the long path at 100 MHz (window, ACK pacing or timers) is the open question; `ss -ti` during the download is the next measurement.
- **The first sc3 bench** ([`bench_sc3-100.txt`](bench_sc3-100.txt)) ran with an older `tanager-host`, and timesyncd stepped the clock during `./t`, so its `time` was void. The table is from the clean back-to-back pair.

## Step 3: two-core lockstep

`runs/lockstep.sh` with p0f's 1 GHz-timebase 768 MiB tree (main has no `--freeze-time` yet; it comes with the SoC track's MR4), checker `694aff2`, `--harts=4` ([`ls_run1.txt`](ls_run1.txt), [`ls_sc3-tb1g.log`](ls_sc3-tb1g.log), [`ls_console_sc3-tb1g.txt`](ls_console_sc3-tb1g.txt)).

**Pass:** `PASS after 409133336 records (409098612 retired, 14550 traps, 20174 interrupts, 0 writebacks) in 4777.7 s, 85634 records/s`, with `967 loads read bytes another hart's recent write had replaced; 0 atomics read past a store`. Boot to the root shell and power-off, checker exit 0. Main's tree at 100 MHz (stage C, DR-151) matches Spike through a whole two-core Linux boot.
