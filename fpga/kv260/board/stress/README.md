# The two-core stress (board track, 2026-10-17)

The coordinator asked for it while soc-2's 100 MHz package waits: a long run on sc2 (two `smt2` cores, 70 MHz) under Debian 13, ahead of M8's 72-hour stress.

**The guest's loop** ([`stress.sh`](stress.sh); copied into the Debian image's `~/stress`). Each pass checks every result against x86's (the 5950X, the same sources and flags):
- **`gcc -O2` builds [`t.c`](t.c) and runs it:** it must print `5007905533300608`.
- **[`mt.c`](mt.c):** two threads on one cache line, 4,000,000 atomic adds and 400,000 mutex-held adds. It must print `mt ok 4000000 400000`. The line moves between the two cores' caches on every access.
- **A 9-file project ([`proj/`](proj/)):** compiled two files at a time (`xargs -P 2`, as `make -j2` would; `make` is not in the image) and linked. It must print `135808003256614222`.
- **`sysbench`:** cpu, memory and threads on two threads, 30 s each.
- **Kernel messages:** new lines that mean trouble (oops, BUG, panic, RCU stalls, lockups, hung tasks) fail the pass.

One line per pass: `STRESS pass N ok=… fails=… …`. Typing `q` on the console stops the loop after the current pass.

**The host side:**
- [`../runs/sc2_stress.sh`](../runs/sc2_stress.sh) boots it with no network.
- [`../runs/stress_monitor.sh`](../runs/stress_monitor.sh) logs, every 30 min, the last pass, the failure counts, the L2 error events, the injector and the fan.
- A watcher on the laptop stops the run (with `q`) when the 100 MHz package appears.

**Run s1** stopped after pass 1, which found that `make` is not installed (`ERR 127`); the `t` and `mt` results were right. Fixed with `xargs -P 2`.

**Run s2** started 17:37 (board time). Passes 1–2 were clean: 146–147 s each; sysbench cpu 53.8 events/s, memory 67.2 MiB/s, threads about 1,035 events.

**Result of run s2: 25 of 25 passes clean, 66 minutes of two-core load** ([`stress_s2.txt`](stress_s2.txt), monitor [`stress_monitor_s2.txt`](stress_monitor_s2.txt), console [`linux_shell_stress_s2.txt`](linux_shell_stress_s2.txt)).
- **Every result matched x86:** `t`, `mt` (exact atomic and mutex counts every pass), and the project. There were no `STRESS FAIL` or `STRESS DMESG` lines, and no oops, BUG, panic, RCU stall, lockup or hung task.
- **Steady numbers:**
  - sysbench cpu on 2 threads: average 53.95 events/s (53.79–54.67);
  - memory on 2 threads: 67.32 MiB/s;
  - threads: 1,036 events per 30 s;
  - 145–147 s per pass; load average about 1.9.
- **The L2 error events stayed at 16 all run:** DR-151's refused fills, since sc2 predates the memory-region change.
- **Fan:** 15/255 at 33–34 °C throughout.
- **How it ended:** stopped cleanly with `q` at 18:44 when soc-2's sc3 package appeared, as planned. The guest finished pass 25 and powered off (`boot exit 0`, power-off at 4,013 s).
- **For the SoC track:** the injector's native-latency average reads 21.5 cycles after 164 M reads and 6.0 after 277 M. 277 M × 21.5 is more than 2³², so the latency sum probably wraps at 32 bits.

## Run s3: sc3 (100 MHz) from the RISC-V's own partition, toward M8's 72-hour gate

**Setup:** [`../runs/sc3_stress.sh`](../runs/sc3_stress.sh) boots Debian on sc3 from p3 (`--blk /dev/mmcblk1p3`, the SoC track's sdpart `u-boot.bin`, no network). It runs the same `~/stress/stress.sh` (copied into p3 from this directory) for up to 72 h, with the 30-minute monitor.
- **Start:** 22:48 board time, 2026-10-17. Login came at 191 s.
- **Pass 1:** clean in 129 s. sysbench on two threads gave cpu 78.81 events/s, memory 98.23 MiB/s and threads 1,517 events, each about 1.46× run s2's at 70 MHz, the clock ratio.
- **The rules if it fails** (the coordinator): keep the console and dmesg, stop cleanly, and report the pass number and the first error line to the coordinator and the verification track.

**How it ended: a mains power cut, not a failure.** 70 of 70 passes were clean over 2 h 36 min of two-core load ([`linux_shell_stress_s3.txt`](linux_shell_stress_s3.txt), monitor [`stress_monitor_s3.txt`](stress_monitor_s3.txt), run log [`stress_s3.txt`](stress_s3.txt)).
- **Steady numbers:**
  - 128.3 s per pass (128–129 s);
  - sysbench on two threads: cpu 78.80 events/s (74.69–79.60), memory 98.18 MiB/s, threads 1,519 events;
  - no `STRESS FAIL` or `STRESS DMESG` line, no oops, BUG, panic, RCU stall, lockup or hung task;
  - fan 15/255 at 33–35 °C.
- **The stop:** at 01:24 UTC the board lost power.
  - The laptop's battery log shows AC off from 01:24:08 to 01:24:15; the KV260 has no battery; the laptop's Wi-Fi reconnected about 40 s later.
  - Pass 70 had printed at 01:23:23, and pass 71 was due at about 01:25:31.
  - The A53 came back on its own: no shutdown record, and its journal simply stops, at 01:21:18, before the cut.
  - The A53's root mounted cleanly. p3 was left with `needs_recovery`; `e2fsck -p` replayed its journal, and `e2fsck -fn` then passed clean.
- **So:** no Tanager or A53 fault. The 72-hour gate needs a fresh run.

## Run s4: sc3 from p3 again, stopped for D2's bitstream

**Setup:** the same as s3. Start 02:40:56 UTC, 2026-10-18. Pass 1 was clean in 129 s.

**Result: 88 of 88 passes clean over 3 h 14 min** ([`linux_shell_stress_s4.txt`](linux_shell_stress_s4.txt), monitor [`stress_monitor_s4.txt`](stress_monitor_s4.txt), run log [`stress_s4.txt`](stress_s4.txt)).
- **Steady numbers:** 128.3 s per pass; sysbench on two threads: cpu 78.78 events/s, memory 98.10 MiB/s, threads 1,511 events.
- **No trouble:** no `STRESS FAIL` or `STRESS DMESG` line, and no oops, BUG, panic, RCU stall, lockup or hung task.
- **The fan:** 15/255 at 33–35 °C. It rose to 43/255 once when the PS reached 36 °C, which is fancontrol's curve.
- **How it ended:** stopped on purpose with `q` at 05:52:51 for the SoC track's D2 bitstream (the coordinator: stage D before the 72-hour gate, which belongs to the final design, M8). The guest finished pass 88 ("STRESS stop after pass 88, fails=0") and powered off (`boot exit 0`).
- **Together with s3:** 158 clean passes, about 5 h 50 min, at 100 MHz from p3, with no fault in the cores, the SoC or Linux.
