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

**How it ended: a power transient on the board's supply, not a failure.** 70 of 70 passes were clean over 2 h 36 min of two-core load ([`linux_shell_stress_s3.txt`](linux_shell_stress_s3.txt), monitor [`stress_monitor_s3.txt`](stress_monitor_s3.txt), run log [`stress_s3.txt`](stress_s3.txt)).
- **Steady numbers:**
  - 128.3 s per pass (128–129 s);
  - sysbench on two threads: cpu 78.80 events/s (74.69–79.60), memory 98.18 MiB/s, threads 1,519 events;
  - no `STRESS FAIL` or `STRESS DMESG` line, no oops, BUG, panic, RCU stall, lockup or hung task;
  - fan 15/255 at 33–35 °C.
- **The stop:** at 01:24 UTC the board lost power for a moment.
  - The laptop's battery log shows its AC off from 01:24:08 to 01:24:15, i.e. its charger unplugged and plugged in again; the laptop's Wi-Fi reconnected about 40 s later.
  - **The cause (the user, 10-18):** the KV260 was powered through a USB-C-to-DC adapter, so plugging or unplugging the laptop's charger caused a transient on the board's supply that reset it. The board now has its own supply.
  - **For a future reset:** check the board's own supply and logs first; the laptop's power log no longer explains one. A UPS is optional.
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

## Run s5: d2 (DR-156's four-miss L1D, D2's fan regulator) from p3, overnight

**Setup:** [`../runs/stress_p3.sh`](../runs/stress_p3.sh) `tanager-d2 ~/tanager/d2pkg s5`: the same guest loop, on D2's bitstream, with the regulator's status in the 30-minute monitor. Start 08:23:37 UTC, 2026-10-18.

**Result: 321 of 321 passes clean over 11 h 31 min** ([`linux_shell_stress_s5.txt`](linux_shell_stress_s5.txt), monitor [`stress_monitor_s5.txt`](stress_monitor_s5.txt), run log [`stress_s5.txt`](stress_s5.txt)).
- **Steady numbers:** 127.3 s per pass (127–129 s; sc3's runs: 128.3 s); sysbench on two threads: cpu 78.80 events/s, memory 98.38 MiB/s, threads 1,516 events.
- **No trouble:** no `STRESS FAIL` or `STRESS DMESG` line, and no oops, BUG, panic, RCU stall, lockup or hung task.
- **The fan:** `fancontrol` at 15–17/255. The regulator's 23 samples: PL die 32.4–34.4 °C, duty 15–17/255, always the larger of its curve and the A53's PWM.
- **How it ended, and the gap:**
  - The last pass, 321, printed at 19:54:18 UTC (12:54 PDT). The A53's journal stops at 19:55:16, three seconds after an `eth0` link flap ("br0: port 1(eth0) entered disabled state", then "Link is Up"). There's no shutdown record: **the board was powered down at about 12:55 PDT (cause to confirm with the user**, who was taking things offline then).
  - The laptop's COM5 logger closed at 12:59:19 PDT ("The port is closed").
  - Nothing was seen until the user brought the board back at about 02:20 UTC on 10-19 (19:20 PDT): a gap of about 6 h 25 min, in which s5 did not run.
- **After the restart:**
  - the A53's root mounted cleanly;
  - p3 was left with `needs_recovery`: `e2fsck -p` replayed its journal, and `e2fsck -fn` passed clean;
  - `fancontrol` was active, and `k26-starter-kits` was loaded.
- **Altogether at 100 MHz from p3:** s3, s4 and s5 make 479 clean passes, about 17.4 hours of two-core load, without a fault in the cores, the SoC or Linux. The three stops were external: a supply transient, a planned stop, and the board powered down at 12:55 (cause to confirm with the user).

## Run s6: d2 from p3 again, after D4's part A

**Setup:** the same as s5, on p3 just after D4's part A ([`../d4/`](../d4/)): the first stage C boot with part A's DKMS modules, initrd and getty. Load 03:41:25 UTC, 2026-10-19. Pass 1 was clean in 128 s.

**Result: 147 of 147 passes clean over 5 h 18 min** ([`linux_shell_stress_s6.txt`](linux_shell_stress_s6.txt), monitor [`stress_monitor_s6.txt`](stress_monitor_s6.txt), run log [`stress_s6.txt`](stress_s6.txt)).
- **Steady numbers:** 127.4 s per pass (127–132 s); sysbench on two threads: cpu 78.87 events/s, memory 98.49 MiB/s, threads 1,518 events. The same as s5's.
- **No trouble:** no `STRESS FAIL` or `STRESS DMESG` line, and no oops, BUG, panic, RCU stall, lockup or hung task.
- **The fan:** `fancontrol` at 15–33/255 (the A53's AMS at 34–35 °C). The regulator's 11 samples: PL die 33.9–34.9 °C, duty 15–33/255.
- **Part A's two side effects showed on its console:**
  - `sdhci_of_arasan: module verification failed … tainting kernel` at 51.7 s: the initramfs loaded the module in every boot;
  - the `dev-ttyPS0.device` job waited 1 min 31 s for a UART that stage C doesn't have;
  - the SoC track's fix for both ran next ([`../d4/README.md`](../d4/README.md), part A's fix).
- **How it ended:** stopped on purpose with `q` just before 09:00 UTC, for the fix's boot. The guest finished pass 147 ("STRESS stop after pass 147, fails=0") and powered off (`boot exit 0`, 19,130 s after the load). `k26-starter-kits` was back at 09:00:19.

## Run s7: d2 from p3, the first stage C boot with part A's fix

**Setup:** the same as s6. Load 09:22:00 UTC, 2026-10-19. Its boot checked part A's fix ([`../d4/README.md`](../d4/README.md)): no sdhci or arasan line, no taint and no ttyPS0 job. Pass 1 was clean in 128 s.

**Result: 76 of 76 passes clean over 2 h 46 min** ([`linux_shell_stress_s7.txt`](linux_shell_stress_s7.txt), monitor [`stress_monitor_s7.txt`](stress_monitor_s7.txt), run log [`stress_s7.txt`](stress_s7.txt)).
- **Steady numbers:** 127.2 s per pass (127–128 s); sysbench on two threads: cpu 78.92 events/s, memory 98.48 MiB/s, threads 1,518 events.
- **No trouble:** no `STRESS FAIL` or `STRESS DMESG` line, and no oops, BUG, panic, RCU stall, lockup or hung task.
- **The fan:** `fancontrol` at 15–30/255 (the A53's AMS at 34–35 °C). The regulator's 6 samples: PL die 33.9–34.9 °C, duty 15–30/255.
- **How it ended:** stopped on purpose with `q` at 12:07:14 UTC, for D4's step 2. The guest finished pass 76 ("STRESS stop after pass 76, fails=0") and powered off (`boot exit 0`, 9,988 s after the load). `k26-starter-kits` was back at 12:08:32.
- **s3 to s7 together:** 702 clean passes (479 + 147 + 76), about 25 hours of two-core load at 100 MHz from p3, on sc3 and d2.

## Run s8: d2 from p3, one pass between D4's steps 2 and 4

Load 12:16:44 UTC, 2026-10-19. Pass 1 was clean in 127 s. Then the run was stopped with `q` for step 4, which reboots the A53: "STRESS stop after pass 1, fails=0", `boot exit 0`. `k26-starter-kits` was back at 12:22:45 ([`linux_shell_stress_s8.txt`](linux_shell_stress_s8.txt), monitor [`stress_monitor_s8.txt`](stress_monitor_s8.txt), run log [`stress_s8.txt`](stress_s8.txt)). The next run, s9, started after step 4, at 12:31:05.

## Run s9: d2 from p3, between D4's steps 4 and 5

Load 12:31:07 UTC, 2026-10-19: the first stage C boot after step 4's mode check went into the A53's boot script. **7 of 7 passes clean** ([`linux_shell_stress_s9.txt`](linux_shell_stress_s9.txt), monitor [`stress_monitor_s9.txt`](stress_monitor_s9.txt), run log [`stress_s9.txt`](stress_s9.txt)).
- **Numbers:** 127.4 s per pass. Memory 98.00 MiB/s on average, but pass 6 read 95.18. It ran while the laptop was copying step 5's package to the A53, and every pass was still `ok=1`.
- **The boot:** no sdhci, taint or ttyPS0 line, as in s7.
- **How it ended:** stopped with `q` at 12:48 for step 5: "STRESS stop after pass 7, fails=0", `boot exit 0`. `k26-starter-kits` was back at 12:49:56. The next run, s10, started after step 5, at 12:53:29.

## Runs s10 to s12: d2 from p3, around D4's step 6

- **s10:** load 12:53:29 UTC. Pass 1 was clean in 128 s. Then the run was stopped with `q` for step 6 ("STRESS stop after pass 1, fails=0", `boot exit 0`; [`linux_shell_stress_s10.txt`](linux_shell_stress_s10.txt), [`stress_monitor_s10.txt`](stress_monitor_s10.txt), [`stress_s10.txt`](stress_s10.txt)).
- **s11:** load 13:20:32, after step 6's first attempt. Pass 1 clean (127 s), then stopped with `q` at 13:26 for step 6's diagnostic ("STRESS stop after pass 1, fails=0"; [`linux_shell_stress_s11.txt`](linux_shell_stress_s11.txt), [`stress_monitor_s11.txt`](stress_monitor_s11.txt), [`stress_s11.txt`](stress_s11.txt)).
- **s12:** from 13:51:18, after the diagnostic found that d4s1 (m6's configuration) can't run Linux, which keeps the stress on d2.

## Runs s12 to s14: d2 and the fixed d4s2, around D4's step 6 pass

- **s12 (d2):** load 13:51:20 UTC. **28 of 28 passes clean** in about 1 h 4 min, at 127.4 s per pass (cpu 78.96 events/s, memory 98.52 MiB/s, threads 1,518 events). The regulator: PL die 34.4–34.9 °C. Stopped with `q` at 14:54 for d4s2 ([`linux_shell_stress_s12.txt`](linux_shell_stress_s12.txt), [`stress_monitor_s12.txt`](stress_monitor_s12.txt), [`stress_s12.txt`](stress_s12.txt)).
- **s13 (d4s2, M6's configuration with core-2's micro-BTB fix):** load 14:55:30 UTC, the first Linux on M6's configuration that doesn't panic. **15 of 15 passes clean** in 32 minutes ([`linux_shell_stress_s13.txt`](linux_shell_stress_s13.txt), [`stress_monitor_s13.txt`](stress_monitor_s13.txt), [`stress_s13.txt`](stress_s13.txt)).
  - **Faster than d2 on the same kernel, initrd, tree and load:** 115.0 s per pass against 127.4; cpu 93.83 events/s against 78.96 (+19%); memory 114.60 MiB/s against 98.52 (+16%); threads 2,323 events against 1,518 (+53%).
  - Its boot reached the stress at 142 s of uptime, against about 194 s on d2.
  - The regulator: PL die 34.4–34.9 °C, duty 15–25/255.
  - Stopped with `q` at 15:25 for step 6 ("STRESS stop after pass 15, fails=0").
- **s14 (d2):** load 15:42:19 UTC, after step 6 passed on d4s2. **41 of 41 passes clean** in about 1 h 31 min, at 127.2 s per pass (cpu 78.91, memory 98.46, threads 1,518). Stopped with `q` at 17:13 for M6's first Linux measurement ([`linux_shell_stress_s14.txt`](linux_shell_stress_s14.txt), [`stress_monitor_s14.txt`](stress_monitor_s14.txt), [`stress_s14.txt`](stress_s14.txt)).
- **s15 (d4s2):** the d4s2 soak, from 17:28:09 UTC, after DR-141's set on d4s2 ([`../d4s2/README.md`](../d4s2/README.md)).

## Runs s15 and s16: d4s2 in stage C, then the stress in RISC-V mode (the product mode)

- **s15 (d4s2, stage C):** load 17:28 UTC, after M6's measurement. Pass 1 was clean: 116 s; cpu 93.84 events/s, memory 114.25 MiB/s, threads 2,316 events. Then it was stopped with `q` at 17:31 for the stress in RISC-V mode. Its stage C logs stay on the A53 until the board is next in ARM mode.
- **s16 (d4s2, RISC-V mode):** the board as a standalone RISC-V computer. Debian 13 runs from the card through SD1, the A53 is parked, and there is no `tanager-host` (so no monitor, injector or fan readout; the PL regulator runs the fan on its own curve).
  - **How it's driven:** the laptop runs the guest's `~/stress/stress.sh` on COM5 (Debian's console, autologin), starting it with [`../runs/riscv_stress_start.txt`](../runs/riscv_stress_start.txt) and stopping it with [`../runs/riscv_stress_stop.txt`](../runs/riscv_stress_stop.txt) through `../d4/serial_expect2.ps1`. It logs COM5 and watches the log with [`../runs/riscv_stress_watch.sh`](../runs/riscv_stress_watch.sh), which stops on a failed pass, kernel trouble, or 12 minutes without a pass (the PMOD break is the way out of a hang).
  - **Segment a:** the record set to riscv, a reboot at 17:33:49 UTC, Debian up at 17:36:44, the stress from 17:40.
    - **7 of 7 passes clean.** 116.7 s per pass; sysbench on two threads: cpu 92.73 events/s, memory 111.81 MiB/s, threads 2,270 events.
    - Against stage C on the same bitstream (s13): 115.0 s, cpu 93.83, memory 114.60, threads 2,323. RISC-V mode runs about 1–2.5% slower so far; the steady comparison belongs to the final configuration's 24-hour soak.
    - Stopped with `q` at 17:53 for D5's step 0 in ARM mode (`STRESS stop after pass 7, fails=0`), with the record set to arm and Debian's reboot into Ubuntu.
    - Logs: [`uart_COM5_s16a_boot.txt`](uart_COM5_s16a_boot.txt), [`uart_COM5_s16a_start.txt`](uart_COM5_s16a_start.txt), [`uart_COM5_s16a.txt`](uart_COM5_s16a.txt), [`uart_COM5_s16a_stop.txt`](uart_COM5_s16a_stop.txt).
  - **The first start failed.** The shell's first prompt arrived just as the boot logger let go of COM5, and the CR then made a second one. `serial_expect2.ps1` consumed text only up to a match, so the second prompt satisfied the next expect early, and the stress command went out as typeahead and was lost.
    - The fix: `send` now clears what was received before it, so an expect sees only what comes after its send.
    - The second start ran cleanly.
  - **Segment b:** the record set to riscv, a reboot at 17:56:04, Debian up at 17:59:06, the stress from 17:59:31, until the SoC track's D5 step 2 package arrives.
  - **Both consoles work in RISC-V mode:** after the ttyPS0 drop-in fix, COM7 shows `Debian GNU/Linux 13 tanager ttyPS0` and the autologin.
  - **Segment b:** 2 of 2 passes clean (117 s each), stopped with `q` at 18:02 for D5's step 2 ([`uart_COM5_s16boot2.txt`](uart_COM5_s16boot2.txt), [`uart_COM5_s16b.txt`](uart_COM5_s16b.txt), [`uart_COM5_s16bstop.txt`](uart_COM5_s16bstop.txt), [`uart_COM5_s16bstop2.txt`](uart_COM5_s16bstop2.txt)).
    - **The stop needed a second try.** After `q` the shell printed two prompts, and the second arrived while `sudo tanager-mode arm` was being typed. So `sudo reboot` went out as typeahead, and sudo discarded it. The record was arm, but Debian kept running.
    - A second session sent the reboot. `serial_expect2.ps1` now drains the line for 0.7 s before each send, and it also no longer cuts a command at its first `|`: a step's text runs to the end of the line.
  - **Segments a and b together:** 9 of 9 passes clean, at 116.7 s per pass.
- **s17 (d4s2, stage C):** from 18:18 UTC (the A53's clock, then 7 minutes behind the laptop's), while the SoC track fixes D5's `riscv.scr`.
- **s17 (d4s2, stage C):** 6 of 6 passes clean at 115 s per pass (cpu 93.9, memory 114.8, threads 2,325).
  - The first `q` was lost: it reached the console before the stress loop had started.
  - A second `q` stopped it at 18:40 for D5's step 2 ("STRESS stop after pass 6, fails=0").
  - Logs, fetched in the next ARM-mode window: [`linux_shell_stress_s17.txt`](linux_shell_stress_s17.txt), monitor [`stress_monitor_s17.txt`](stress_monitor_s17.txt), run log [`stress_s17.txt`](stress_s17.txt). Over the six passes: 115.2 s, cpu 93.88 events/s, memory 114.81 MiB/s, threads 2,325 events.
- **s16, segment c (RISC-V mode, now with Ethernet up):** the stress from 19:02:42 UTC, after D5's step 2 pass.
  - **63 of 63 passes clean.** Stopped with `q` at 21:06 UTC for the final bitstream ("STRESS stop after pass 63, fails=0"). The record was set to arm, and Debian's reboot gave Ubuntu back at 21:08.
  - **The guest's clock was stepped during pass 1.** At boot it starts from the time `systemd-timesyncd` saved at the last shutdown (`System time advanced to timestamp on /var/lib/systemd/timesync/clock: ... 18:57:34 UTC`), so it ran 3.4 minutes behind (`STRESS start 2026-10-19T18:59:16Z`) until the first sync. Pass 1 reads 320 s on the guest's clock and 117 s by its uptime.
  - **Passes 2–4 overlapped the network check's two tries** (19:05 and 19:07, [`../d5/README.md`](../d5/README.md)): cpu 52–71 events/s, threads 706–2,298. They are left out of the steady numbers.
  - **Steady, over the other 60 passes** (pass 1's time left out): 116.6 s per pass (116–117), cpu 93.42 events/s, memory 112.34 MiB/s, threads 2,303 events.
  - **Against stage C on the same bitstream (s17):**
    - The pass is 1.2% longer.
    - cpu is 0.5% lower, memory 2.2% lower, and threads 0.9% lower.
    - Segment a's gaps (cpu 1.2%, memory 2.4%, threads 2.3%, over 7 passes) narrowed for cpu and threads; memory's stays at about 2%.
  - Logs: [`uart_COM5_s16c_boot.txt`](uart_COM5_s16c_boot.txt) (the boot, with D5's Ethernet), [`uart_COM5_s16c_start.txt`](uart_COM5_s16c_start.txt), [`uart_COM5_s16c.txt`](uart_COM5_s16c.txt), [`uart_COM5_s16c_stop.txt`](uart_COM5_s16c_stop.txt).
  - The numbers come from [`../runs/riscv_soak_report.sh`](../runs/riscv_soak_report.sh), written for the 24-hour soak. It times each pass by the guest's uptime as well as its clock, flags passes where the two disagree (a clock step), and leaves out the passes that a network check overlapped.
- **s16 in all:** 72 of 72 passes clean in RISC-V mode (segments a, b and c) on d4s2, about 2.4 hours under stress.

## Run s18: d4r1 in stage C, then the 24-hour soak in RISC-V mode (s19)

- **s18 (d4r1, stage C):** load 21:21:46 UTC. This is d4r1's first Debian boot (from p3, under `tanager-host`): the standing rule boots a new bitstream in stage C before RISC-V mode depends on it.
  - **2 of 2 passes clean:** 115 and 114 s; cpu 93.92 and 94.39 events/s, memory 137.99 and 138.61 MiB/s, threads 2,334 and 2,349 events.
  - **Memory is 20.5% above d4s2's** (s17: 114.81 MiB/s). sysbench's memory test writes, and d4r1 adds the store prefetch ([`../d4r1/README.md`](../d4r1/README.md)). cpu and threads moved by under 1%.
  - Stopped with `q` at 21:26 so the user could replug the laptop's Ethernet ("STRESS stop after pass 2, fails=0"). `k26-starter-kits` was back at 21:28:28.
  - Logs: [`linux_shell_stress_s18.txt`](linux_shell_stress_s18.txt), monitor [`stress_monitor_s18.txt`](stress_monitor_s18.txt), run log [`stress_s18.txt`](stress_s18.txt).
- **s19 (d4r1, RISC-V mode): the 24-hour soak.** The product mode on the final bitstream: Debian 13 from p3 through SD1, the A53 parked, Ethernet up (D5). The coordinator's plan, with the hourly network check.
  - **Install:** `d4r1-riscv` on p1 with [`../runs/d4m_step6.sh`](../runs/d4m_step6.sh) `install` (`K=~/tanager/d4r1-riscv-pkg/d4r1-riscv`). All six files match the package.
    - Against D5's files, only `tanager.bit.bin` changed (d4s2 to d4r1), and `riscv.scr`'s mkimage header (its timestamp and CRC). The script inside is byte-identical to D5's fixed one.
    - The tool and the hook match the package. The record was set to riscv at 21:29:33 UTC, and the A53 rebooted.
  - **The boot:**
    - COM7: the hook, `riscv.scr`, the host bridge, then the A53's park.
    - COM5: OpenSBI v1.9, U-Boot d4, then Debian 6.12.113. `/init` at 18.9 s, eth0 linked at 1 Gb/s at 128 s, the autologin by 21:32:44.
    - Over SSH by name: eth0 192.168.137.111/24 (DHCP), and timesyncd synced at 181 s up. So the stress started with the guest's clock right, within 1 s of the laptop's.
    - Logs: [`uart_COM5_s19_boot.txt`](uart_COM5_s19_boot.txt), [`uart_COM5_s19_start.txt`](uart_COM5_s19_start.txt).
  - **The stress from 21:33:48 UTC** (`STRESS start 2026-10-19T21:33:48Z up=211.12`), driven on COM5 as s16 was. The laptop logs COM5 and COM7 and runs [`../runs/riscv_stress_watch.sh`](../runs/riscv_stress_watch.sh).
  - **The network check:** [`../runs/riscv_net_check.sh`](../runs/riscv_net_check.sh) from 22:03:48 UTC, every hour, 24 checks.
    - It now keeps to a fixed hourly schedule: under the stress a check takes about 3 minutes, which had pushed each next check later.
    - It logs the guest's uptime around each check. [`../runs/riscv_soak_report.sh`](../runs/riscv_soak_report.sh) leaves the overlapped passes out of the steady numbers and lists the checks on their own.
  - **The end:** 24 hours at 21:33:48 UTC on 10-20, or the first failure. The report gives the stress's steady numbers and, separately, the network checks' count, failures and transfer-rate range.
  - **Segment a: 151 of 151 passes clean,** from 21:33:48 to 02:29:21 UTC (4.93 h of stress). A power event ended it: the user touched the board's supply.
    - **Steady, over 139 passes:** 115.9 s per pass (115–116), cpu 93.44 events/s, memory 131.86 MiB/s, threads 2,303 events. Twelve passes overlapped a network check and are left out.
    - **Network checks: 5 of 5 OK.** 0.51–0.59 MB/s up and 0.56–0.60 MB/s down, with matching checksums; `apt-get update` exit 0 every time.
    - Logs: [`uart_COM5_s19a.txt`](uart_COM5_s19a.txt), [`net_s19a.txt`](net_s19a.txt).
  - **The power event, about 02:29:30 UTC:**
    - COM5's last line is pass 151's, clean, and nothing came after it.
    - COM7 shows two boots about a minute apart, both ARM mode (the record had trial 1, an unconfirmed RISC-V boot). The second boot cut the first in U-Boot's `Loading image.fit`, where no software of ours runs and the PL is unconfigured. Ubuntu was up from 02:30:34.
    - **Both were most likely power-ups:** the user's account, a reset where no software of ours runs, and both U-Boots printing `Net: PHY reset timed out`. That line appears in only one earlier COM7 log, 10-14's first, which holds a power-up. It appears in none of the 32 other U-Boot boots logged since: reboots, OpenSBI's SRST, `RESET_CTRL` writes and the PMOD hook.
    - U-Boot's `Reset reason: SOFT` and `RESET_REASON` `0x21` can't tell the two apart: the Image Selector soft-resets into Image A on every power-up ([`../d4/README.md`](../d4/README.md)).
    - COM7's log so far: [`uart_COM7_s19_to_b.txt`](uart_COM7_s19_to_b.txt).
  - **p3 after the power loss:** `e2fsck -fn` from the A53 found `needs_recovery` (the journal unreplayed). `e2fsck -fp` replayed it ("recovering journal", exit 1: corrected), and `-fn` then found it clean.
  - **Segment b's first boot failed on SD1's interrupts.** The record was set to riscv again and the A53 rebooted at 02:36:37. This boot runs from the same p1 files and bitstream, and `riscv.scr`'s COM7 output (SD1's taps, GEM3's clocks) is identical to segment a's.
    - Debian's kernel found the card and read the partition table (`mmcblk0: p1 p2 p3` at 34.6 s).
    - From 45 s on, every SD1 request timed out after 10 s: `mmc0: Timeout waiting for hardware interrupt`, 36 times. Each register dump shows `Int stat` with transfer complete (bit 1) set and the interrupt enabled: the controller finished, but the interrupt never reached Linux.
    - Then `mmcblk0: recovery failed!` and two read I/O errors. There was no login after 7 minutes, since the initramfs's fsck of p3 was stuck.
    - **None of the 10 RISC-V-mode Debian boots logged before (D4 step 6 to s19's first) had a single one of these timeouts.**
    - **The way out:** a 4 s PMOD break at 02:44:09 reset the board into ARM mode (trial 1), and Ubuntu was up at 02:44:28 with p3 clean. The PMOD hook worked as DR-172 designed, with no one at the board.
    - Log: [`uart_COM5_s19b_boot1.txt`](uart_COM5_s19b_boot1.txt).
  - **The retry booted cleanly** (reboot 02:47:39): no timeout, p3 mounted at 49.6 s, eth0 at 1 Gb/s (DHCP 192.168.137.41), and the clock synced at 180 s. Log: [`uart_COM5_s19b_boot2.txt`](uart_COM5_s19b_boot2.txt).
    - So the lost interrupts came once, on the first RISC-V boot after the power-ups. It is an open item for the SoC track; the timeout log holds the register dumps.
  - **Segment b, from 02:51:46 UTC** (`STRESS start 2026-10-20T02:51:46Z up=204.54`, [`uart_COM5_s19b_start.txt`](uart_COM5_s19b_start.txt)).
    - It runs until segments a and b together reach 24 hours of stress: 21:56:13 UTC on 10-20.
    - Network checks: hourly from 03:21:46, 19 of them.
  - **The checks' accounting, fixed for segment b:**
    - SSH's handshake costs the guest several seconds of CPU before a check's first command reads its uptime. Pass 138 ended 2 s before check 5's recorded start and ran 124 s against 116.
    - `riscv_net_check.sh` now starts the span before the handshake: the uptime less the laptop's time for that first SSH command.
    - `riscv_soak_report.sh` widens each span by `MARGIN_S` (15 s) for older logs. That is why segment a's numbers above leave out 12 passes, not 10.
  - **Segment b: 12 of 12 passes clean,** from 02:51:46 to 03:15:20 UTC (0.39 h of stress). It was paused at a pass boundary ("STRESS stop after pass 12, fails=0") for the coordinator's hunt for the lost SD1 interrupt. Debian stayed up.
    - The passes ran at 116 s; cpu 93.5 events/s, memory 132 MiB/s, threads 2,300.
    - **Pass 7 slowed** as an overlapped network check would make it (cpu 49.36, memory 79.63, threads 618; then pass 8 ran 124 s), though no check was due until 03:21:46. Something on the guest ran then, between 03:03 and 03:05 UTC; its journal will say what.
    - Logs: [`uart_COM5_s19b.txt`](uart_COM5_s19b.txt), [`uart_COM5_s19b_pause.txt`](uart_COM5_s19b_pause.txt).
  - **Segments a and b together:** 163 of 163 passes clean, 5.32 h of stress.

## The hunt for SD1's lost interrupt (10-20)

**Why:** in s19 segment b's first boot, every SD1 request timed out with its completion pending ([s19](#run-s18-d4r1-in-stage-c-then-the-24-hour-soak-in-risc-v-mode-s19)). soc-2 found that the PLIC stopped delivering source 21 while SD1's line stayed high: either source 21 was claimed and never completed, or its enable bit was cleared. Their probe, `sw/d4mode/sd1-irq-probe` (0edfe93), tells which at the next occurrence. At the first mmc0 timeout it reads the PLIC's view of source 21 and SD1's registers, writes a complete for 21, and reads them again. The coordinator asked for about 30 RISC-V-mode boots, each with an SD read stress on both CPUs.

**The setup, in the RISC-V's Debian on p3** (logged with its undo in [`../README.md`](../README.md)'s change log):
- **busybox wasn't installed,** so `apt-get install busybox` added it (1.37.0, with `devmem`). With `BUSYBOX=auto` the initramfs now carries its applets.
- **The probe:** `/usr/local/sbin/sd1-irq-probe`, its initramfs hook and its init-top script, then `update-initramfs -u` (about 10 minutes at 100 MHz).
- **`iomem=relaxed`** goes in through u-boot-menu (`/etc/default/u-boot`, then `u-boot-update`). Debian's kernel has `IO_STRICT_DEVMEM`. Without the option, `/dev/mem` read the PLIC but refused SD1's registers (`mmap: Operation not permitted`).
- **The check by hand on boot 1:** `sd1-irq-probe dump` with `iomem=relaxed`:
  - PLIC: source 21 at priority 1, enabled on context 1 (hart 0, enables `0x00700400`) and not on context 5, both thresholds 0, nothing pending.
  - SD1: status 0, status and signal enables `0x03FF008B`, present `0x01F70000`; line 0.
  - All of mmc0's interrupts go to CPU 0.
  - `/proc/interrupts` shows "SiFive PLIC 21 Edge". With `riscv,plic0` the driver leaves the flow at fasteoi and never records a type, so the word "Edge" there means nothing.
- **The initramfs watch's noise:** it runs from before the root's mount. At the switch to the real root the initramfs's files go, so it prints `dmesg: not found` and `grep: not found` once and then exits, since its own file is gone too. That is harmless.

**How each boot runs** ([`../runs/sd1_probe_boots.sh`](../runs/sd1_probe_boots.sh), from the laptop, with COM5 logged throughout):
1. Debian's reboot. The confirm unit keeps RISC-V mode, so each boot goes through the A53's U-Boot, `riscv.scr` and the RISC-V.
2. The login on COM5.
3. Over SSH: the probe's watch, then [`../runs/sd_read_stress.sh`](../runs/sd_read_stress.sh) for 90 s. O_DIRECT readers run on both CPUs: CPU 0 at 4 KiB from the card's middle, CPU 1 at 64 KiB from its start. In boot 1, 512 KiB reads on CPU 1 starved the 4 KiB reader to 226 kB/s.
4. A tally line per boot: the login's time, SD1 timeouts in the boot and in the stress, mmc0's interrupt count, the readers' rates, and whether the probe fired.

The driver stops at a capture or at a boot with no login within 8 minutes. The PMOD break recovers a stuck boot.

**Boots 1–7 (03:39–04:16 UTC):** all clean. Each logged in about 190 s after the reboot, and no SD1 timeout came in the boot or in the 90 s stress.
- **The stress:** about 75,000 mmc0 interrupts per boot, all on CPU 0. The 4 KiB reader got 787–794 kB/s and the 64 KiB reader 12.2–12.4 MB/s.
- **Boot 1's** CPU 1 read at 512 KiB: 14.8 MB/s, with 226 kB/s left for the 4 KiB reader.

**Boot 7's shutdown lost SD1's interrupt again: the second occurrence, and the first at a shutdown.**
- **When:** the driver's reboot began at 04:16:46. At 272 s of boot 7's uptime, about 10 s into stopping the services, `mmc0: Timeout waiting for hardware interrupt` began: 46 timeouts, then read I/O errors on p3.
- **The shutdown stuck,** with the confirm unit's stop job running for its full 10 minutes. It did write trial 0: the board came back in RISC-V mode after the PMOD break (04:26:27), not in Ubuntu.
- **The probe missed it.** The driver had stopped the per-boot watch after the stress, and the initramfs's watch ends at the switch to the real root, so nothing was watching at the shutdown.
- **The fix:** `sd1-irq-watch.service` ([`../runs/sd1-irq-watch.service`](../runs/sd1-irq-watch.service)) runs the probe's watch from the root's mount through shutdown. With `DefaultDependencies=no` it stays out of shutdown's ordinary stop.
  - A copy in `/run` was tried first and can't run, since Debian mounts `/run` noexec. So it runs from the card; its commands repeat every 2 s and stay cached.
  - The driver no longer starts or stops a watch of its own.
- **Boot 9** (after the break, 04:28): no timeout; the initramfs's fsck recovered p3's journal. The service went in there, and boots 10–30 run with it.
- **Log:** [`uart_COM5_probe_boots1-8.txt`](uart_COM5_probe_boots1-8.txt) holds boots 1–8 in one capture; the tally gives each boot's offset in it.

**Boots 10–12 (04:35–04:55):** all clean, with the watch service active, each with about 74,000 mmc0 interrupts in the stress.
- **Boot 12's "no login" was COM5's, not the board's.** The laptop's CH340 dropped and reopened at 04:47:38, during the boot, and the login line was lost with it. Boot 12 was up and clean (0 timeouts), and its stress ran by hand.
- The driver now also takes the shell prompt as the login. In every boot's section the prompt first appears after the new boot, never between the reboot command and the restart.

**Boots 13–27 (04:56–06:15):** all clean, with the watch service active. Each logged in about 190 s after the reboot, and each stress drew 74,000–75,000 mmc0 interrupts with no timeout.

**Boot 28's stress lost SD1's interrupt: the third occurrence, and the first under the stress.**
- **When:** the stress started at about 155 s of uptime. The first `mmc0: Timeout waiting for hardware interrupt` came at 168.85 s, and there were 63 by 810 s.
- **The SDHCI dump matches s19 segment b's first boot:**
  - `Int stat` 0x00000002 (transfer complete), with the status and signal enables at 0x03ff008b;
  - `Slot int` 1, so SD1's line is high;
  - CMD18 (a multi-block read) with auto-CMD12, by ADMA.
- **Read live from COM5's autologin shell, with bash builtins only:**
  - mmc0's count stayed at 6,984 (a whole stress gives about 74,000).
  - ttyS0's count rose from 1,360 to 1,660 in 23 s. ttyS0 is PLIC source 10, delivered to the same hart 0 context.
  - So the PLIC still delivers to that context. It stopped delivering source 21 alone.
- **No capture:**
  - The watch service saw the timeout, but the capture's own commands (busybox, `cut`, `tee`) weren't cached, and loading them from the failing card hung.
  - Then SSH failed (`Connection reset`), systemd couldn't spawn anything (`Input/output error`), and even `sudo` failed to load. So no root read of the PLIC was possible.
  - A PMOD break at 06:35:26 gave Ubuntu (trial 1), and `e2fsck -fp` replayed p3's journal.
- **The probe now runs entirely from RAM:**
  - `sd1-irq-watch.service` mounts its own tmpfs (`/run` is noexec; this one isn't).
  - It copies in a static busybox and the probe, and runs the watch with only that directory on its `PATH`. The busybox is the binary from Debian's busybox-static 1.37.0-6+b9, extracted to `/usr/local/lib/sd1probe/` without installing the package.
  - Debian's packaged busybox is dynamic and needs libc and libresolv from the card. The static one runs in a chroot that holds no libraries.
  - A dump from the tmpfs works.

**Boot 29** (06:37, from Ubuntu, the stress by hand): clean, with 75,547 mmc0 interrupts.

**Boot 30** (06:46): clean, with 73,395 mmc0 interrupts.

**The tally, boots 1–30:**
- **28 boots had the 90 s stress.** Boot 8 was boot 7's stuck shutdown, and boot 9 came up after the break.
- **SD1's interrupt was lost twice:** in boot 7's shutdown, and in boot 28's stress at 168 s. Counting s19 segment b's first boot, that's 3 losses in 32 RISC-V-mode boots since the power event.
- **The probe captured neither.** The first time, no watch ran at the shutdown. The second time, the capture's commands loaded from the failing card. Both are fixed now: the watch runs from boot through shutdown, from its own tmpfs, with a static busybox. A dump from there works.
- **What is known** (boot 28, live):
  - The PLIC stopped delivering source 21 alone. mmc0's count froze at 6,984, while source 10 (ttyS0) kept reaching the same hart 0 context.
  - SD1 holds transfer complete pending and enabled, with its slot interrupt (the line) high, after a CMD18 multi-block read with auto-CMD12 by ADMA.
- **When the losses came:** at 45 s, 168 s and 272 s of uptime: early in a boot, just after the login, or at a shutdown.
  - None came during the 5.3 h of s19's segments a and b, or in the other 27 stresses.
  - Each stress drew about 74,000 mmc0 interrupts in 90 s.

**Then: s19 segment c** from 06:51:38 UTC (`STRESS start 2026-10-20T06:51:38Z up=305.93`), on boot 30, with the RAM-resident watch active.
- It runs until segments a, b and c together reach 24 h of stress: 01:32:31 UTC on 10-21.
- Network checks: 19, hourly from 07:21:38.
- The stress watcher now also stops at an mmc0 timeout or a probe capture.

**s19 segment c: 4 of 4 passes clean,** from 06:51:38 to 06:59:28 UTC (0.13 h of stress). The coordinator paused it for 30 more short boots ("STRESS stop after pass 4, fails=0").
- **The always-on watch costs the stress about 3.5%.** cpu ran 90.2–90.6 events/s, memory 128.1–128.3 MiB/s and threads 2,223–2,227, against 93.4, 131.9 and 2,303 in segments a and b without it.
  - Every 2 s the watch formats the kernel's whole log (`dmesg`) and greps it, which is a real load at 100 MHz.
  - Segment d's numbers will carry the same cost.
  - Waiting on `/dev/kmsg` instead would cost nothing between messages. That's for soc-2's probe.
- Logs: [`uart_COM5_s19c_start.txt`](uart_COM5_s19c_start.txt), [`uart_COM5_s19c.txt`](uart_COM5_s19c.txt), [`uart_COM5_s19c_pause.txt`](uart_COM5_s19c_pause.txt).
- **Segments a, b and c together:** 167 of 167 passes clean, 5.45 h of stress.

**Boots 31–60 (from 07:00 UTC; the coordinator: 30 more short boots, each with the stress and a shutdown, stopping at the first capture).**
- At 3 losses in 32 boots, 30 more have about a 94% chance of a loss.
- The driver now also stops at the probe's capture on COM5, before a login or after the stress. That covers a capture made in a shutdown, or when SSH is already gone.

**Boots 31–36 (07:00–07:31):** all clean with the RAM-resident watch. Each stress drew 73,700–74,400 mmc0 interrupts.

**Boot 37 lost SD1's interrupt: the fourth occurrence, early in the boot, and again with no capture.**
- **When:** boot 36's shutdown and reboot were clean. In boot 37 the root was mounted at 51.1 s, and systemd started at about 55 s. SD1's first timeout came at 66.2 s, so the stuck request was issued at about 56 s. There were 37 timeouts and read I/O errors from 260 s, and no login.
- **The gap:** the initramfs's watch ends at the switch to the real root (51 s). `sd1-irq-watch.service` waits for `local-fs.target`, which a failing card never reaches. Nothing watched from 51 s on.
- A PMOD break at 07:40:28 gave Ubuntu (trial 1).
- **The fix: one watch for the whole boot.**
  - The initramfs's init-top script ([`../runs/sd1-irq-probe.init-top`](../runs/sd1-irq-probe.init-top), with its hook [`../runs/sd1-irq-probe.hook`](../runs/sd1-irq-probe.hook)) builds a RAM root of its own, `/sd1ram`: a static busybox, the probe, and its own devtmpfs and proc. It runs the watch chrooted there.
  - At the switch to the real root, `/init` moves `/dev`, `/proc`, `/run` and `/sys` away, and run-init deletes the rootfs's files. A separate mount is neither moved nor deleted, so the watch keeps its commands, `/dev/mem`, `/dev/console` and `/proc` from before the root's mount through shutdown.
  - soc-2's own init-top watch had lost its commands at that switch, which is the `dmesg: not found` on every boot.
  - The systemd unit is disabled; one watch is enough.
  - The capture shows on COM5, and the driver reads it there.
- **Checked on boot 39** (07:57):
  - No `not found` at the switch.
  - The watch, PID 181 from the initramfs, still ran after the login, chrooted in `/sd1ram`.
- **The capture tested once.** A fake line went into the kernel log at 173.30 s (`board self-test, not a real timeout: mmc0: Timeout waiting for hardware interrupt.`).
  - The watch's capture came out on COM5 at 175.25 s: three dumps (175.25, 178.88 and 194.46 s) around the complete it writes for source 21 (at 175.33 s).
  - On a healthy system the complete did no harm: mmc0 kept counting, from 5,459 to 5,979.
  - The watch captures once, so the next boot gets a fresh one.
- **Boots 40–69:** the coordinator's 30 boots, now with the whole-boot watch, stopping at the first capture.

**Boots 40–54 (08:01–09:20):** all clean, with the whole-boot watch (one per boot). Each stress drew 73,000–75,300 mmc0 interrupts.

**The capture: boot 54's shutdown lost SD1's interrupt (the fifth occurrence), and the probe caught it.**
- **When:** the reboot after boot 54's stress began at about 271 s. The first timeout came at 302.77 s, `mmc0: Timeout waiting for hardware cmd interrupt` (CMD13, a status command, not a data transfer).
- **The capture, from COM5:**

  ```
  sd1-irq-probe 303.45 s
    PLIC: pending 0x00000000 (bit 21 = 0), priority 21 = 0x00000001
    PLIC: enables ctx 1 (hart 0 S) 0x00600400 (bit 21 = 1), ctx 5 (hart 2 S) 0x00000000 (bit 21 = 0)
    PLIC: thresholds ctx 1 0x00000000, ctx 5 0x00000000
    SD1: int status 0x00000001, status enable 0x03FF008B, signal enable 0x03FF008B, present 0x01F70000, slot int 0x10020001: line 1
     14:      75904          0  SiFive PLIC  21 Edge      mmc0
  sd1-irq-probe: complete 21 written to context 1 at 303.54 s
  ```

- **What it says:**
  - SD1's line is high: command complete is pending and enabled, and the slot interrupt is 1.
  - The PLIC shows source 21 not pending, while it is enabled on context 1 (hart 0, S-mode) at priority 1 and threshold 0.
  - In soc-2's table, that row means source 21 was claimed and never completed: its gateway waits for a completion and passes nothing on.
- **The complete brought it back.** Within 0.6 s of the probe's complete for 21 (303.54 s), the stuck shutdown went on: `Sending SIGTERM to remaining processes` at 304.08 s, the root remounted read-only at 304.96 s, and `reboot: Restarting system` at 305.21 s.
  - Boot 7's shutdown, in the same state without a complete, hung for 10 minutes with 46 timeouts.
  - The probe's 3 s and 15 s dumps never ran, since the reboot came first. So there's no mmc0 count after the complete, but the I/O plainly came back: boot 54's journal holds the timeout's register dump, written after it.
- **Context 1's enables** were `0x00600400` here, against `0x00700400` while the boot ran: source 20 was already released in the shutdown.
- **Sent at once** to soc-2 and the coordinator, as asked.
- **Boot 55** (the reboot's own): clean, with its watch running.
- Logs: [`uart_COM5_probe_boots38-55.txt`](uart_COM5_probe_boots38-55.txt) (boot 54 from offset 821841), the tally [`probe_tally.txt`](probe_tally.txt).

**The hunt's tally, boots 1–55:**
- Five losses of SD1's interrupt in 57 RISC-V-mode boots since the power event (counting s19 segment b's two):
  - s19 segment b's first boot at 45 s (early in the boot);
  - boot 7's shutdown at 272 s;
  - boot 28's stress at 168 s;
  - boot 37 at 56 s (early in the boot);
  - boot 54's shutdown at 303 s, the one captured.
- None came in 5.45 h of the soak's segments a to c, or in the other stresses.

**s19 segment d,** from 09:24:42 UTC (`STRESS start 2026-10-20T09:24:42Z up=216.28`, [`uart_COM5_s19d_start.txt`](uart_COM5_s19d_start.txt)), on boot 55, with its whole-boot watch armed.
- **Until:** segments a to d together reach 24 h of stress, at 03:57:45 UTC on 10-21.
- **Network checks:** 19, hourly from 09:54:42.
- **The stress watcher** stops at a failed pass, kernel trouble, an mmc0 timeout, a probe capture, or 12 minutes without a pass.
- **If SD1's interrupt is lost now,** the watch captures it once and writes the complete. That brought boot 54's shutdown back.
- **Segment d: 98 of 98 passes clean,** from 09:24:42 to 12:37:04 UTC (3.21 h of stress), with no SD1 timeout and no capture. It ended at a pass boundary for d4r2, the bitstream with the SD1 fix (DR-176). The record went to arm, and Debian's reboot gave Ubuntu.
  - **Steady over 92 passes** (6 overlapped a check): 116.4 s per pass, cpu 90.34 events/s, memory 127.83 MiB/s, threads 2,225 events. This is with the watch's cost, as in segment c.
  - **Network checks: 3 of 3 OK,** 0.49–0.55 MB/s up and 0.52–0.55 down, `apt-get update` exit 0.
  - Logs: [`uart_COM5_s19d.txt`](uart_COM5_s19d.txt), [`uart_COM5_s19d_stop.txt`](uart_COM5_s19d_stop.txt), [`net_s19d.txt`](net_s19d.txt).
- **s19 on d4r1 in all:**
  - 265 of 265 passes clean over 8.66 h of stress in four segments, and 8 of 8 network checks OK.
  - No SD1 loss came in the soak itself. All five losses came in boot transitions: early in a boot, after a login, or at a shutdown.
  - d4r2 replaces d4r1 for the 24 h soak.

## d4r2: the SD1 fix's check (10-20)

**The bitstream:** d4r2 (`33e29f3d…`), d4r1's recipe on main ef44e5b7, built by the coordinator. It holds:
- the SD1 fix (DR-176): the ROB could take an interrupt in the same cycle the LSU sent the head's MMIO read, so the PLIC's claim was read twice and source 21's claim was lost;
- the I$ next-line prefetch;
- three store prefetches;
- M7 step 1.

It meets 100 MHz at WNS +0.367 ns with 105,934 LUTs. The package is d4r1-riscv with only `tanager.bit.bin` changed; all 14 files check against SHA256SUMS on the board.

**s20 (d4r2, stage C,** under the standing rule for a new bitstream; load 12:39:02 UTC):
- **3 of 3 passes clean:** 114–115 s; cpu 90.93–91.12 events/s, memory 142.55–143.21 MiB/s, threads 2,251–2,263.
- **Against d4r1's s18:** memory is 3.3% higher (more store prefetches). cpu and threads are about 3.5% lower, the cost of the probe's watch, which now runs in stage C too (s18 predates it).
- The stage C app `tanager-d4r2` is d4r1's app files with d4r2's bitstream; the configuration is the same.
- Logs: [`linux_shell_stress_s20.txt`](linux_shell_stress_s20.txt), [`stress_monitor_s20.txt`](stress_monitor_s20.txt), [`stress_s20.txt`](stress_s20.txt).

**d4r2 on p1:** its `tanager.bit.bin` went in at 12:48 by `d4m_step6.sh install` (the other files are unchanged), and its hash was checked on the board. Logged with its undo. The probe's setup and the whole-boot watch stay.

**The 60 boots** (the coordinator: zero losses in 60 is the pass, under a 1% chance the bug remains at the old rate of about 1 in 11):
- Boot 0 came from Ubuntu at 12:48:36: clean, with the watch running.
- Boots 1–60 each have a login, the 90 s read stress, and a clean shutdown into the next.
- Reports go out every 20 boots, and at once on any capture.
- **Boots 1–20 (12:52–14:33 UTC): 20 of 20 clean.**
  - No SD1 timeout in any boot, stress or shutdown, and no capture.
  - Each logged in 191–196 s after the reboot, and each stress drew 74,000–75,200 mmc0 interrupts.
  - The tally: [`probe_tally_d4r2.txt`](probe_tally_d4r2.txt).
  - Boots 21–40 follow at once.
- **Boots 21–40 (14:38–16:15 UTC): 20 of 20 clean,** 40 of 40 so far.
  - No SD1 timeout in any boot, stress or shutdown, and no capture.
  - Each logged in 191–192 s after the reboot, and each stress drew 74,600–75,800 mmc0 interrupts.
  - Boots 41–60 follow at once.
- **Boots 41–60 (16:20–17:57 UTC): 20 of 20 clean.**
  - Each logged in 186–192 s after the reboot, and each stress drew 75,000–76,700 mmc0 interrupts.
- **The result: 60 of 60 clean, the pass.**
  - No SD1 timeout in any boot, stress or shutdown: the whole COM5 log of the count holds none, and no capture.
  - On d4r1 the same 60 boots would be expected to show about 5 losses (5 in 57). Zero in 60 leaves under a 1% chance that the bug remains at that rate.
  - Logs: [`uart_COM5_d4r2_boots.txt`](uart_COM5_d4r2_boots.txt) (boots 0–60), the tally [`probe_tally_d4r2.txt`](probe_tally_d4r2.txt).

## Run s21: the 24-hour soak in RISC-V mode on d4r2 (10-20 to 10-21)

- **The stress** from 17:58:22 UTC (`STRESS start 2026-10-20T17:58:22Z up=296.32`, [`uart_COM5_s21_start.txt`](uart_COM5_s21_start.txt)) on boot 60 of the count, with the whole-boot watch armed. The probe's setup stays on p3 until the coordinator calls the hunt done.
- **Network checks:** 24, hourly from 18:28:22.
- **The end:** 17:58:22 UTC on 10-21, or the first failure, SD1 timeout or capture.
- The stress numbers carry the watch's cost (about 3.5% on cpu and threads).

**s21's memory gap** (the coordinator asked for it to be split before anyone calls it a regression):
- **It holds.** Steady over passes 1–9: memory 124.71 MiB/s, against s20's 142.81 in stage C on the same bitstream: −12.7%. Both runs had the probe's watch.
- **The watch's share,** measured with a twin of its poll loop (the same static busybox and commands, chrooted in its RAM root) from 1488 to 2584 s of uptime, with the probe still armed:

  | | One loop (passes 1–9) | Two loops (passes 12–15, 18, 19) | One loop's cost |
  |---|---|---|---|
  | cpu | 90.44 | 87.30 | −3.5% |
  | memory | 124.71 | 121.11 | −2.9% |
  | threads | 2,223 | 2,145 | −3.5% |

  Passes 10, 11, 16, 17 and 20 are left out: they overlapped the start or end of the twin, the `clock_gettime` test, or the 18:28 network check.
- **The mode's share:** the watch costs about 3% in both modes and both runs had it, so the whole −12.7% is RISC-V mode against stage C.
  - d4r1's mode cost was 4.7% (s18 138.30 against s19 segment a 131.86, no watch). d4s2's was 2.2%. The gap grows with each faster core.
  - Against d4r1, with the watch taken out (÷0.971): d4r2 is 6.3% faster in stage C (about 147.1 against 138.3), but 2.6% slower in RISC-V mode (about 128.4 against 131.9).
- **The clock read in RISC-V mode,** under the stress ([`../runs/cg.c`](../runs/cg.c)): `clock_gettime` 1,096–1,149 ns a call, a bare `rdtime` 246–249 ns. Both OpenSBI banners show the same timer, `zicntr` and `sstc`, so neither mode traps on the read. These numbers mean something only beside stage C's under the same load, which comes after s21.
- **The two setups differ in the memory path.** RISC-V mode's window, set by `riscv.scr`, is 1 GiB at `0x8_4000_0000`, in the high DDR aperture. Stage C's is set by `tanager-host`.

**s21 at 6 hours (23:58 UTC):**
- **183 of 183 passes clean.** No failed pass, no FAIL/DMESG line, no SD1 timeout, no probe capture, no kernel trouble.
- **Steady over 161 passes:** 116.1 s per pass, cpu 90.35 events/s, memory 124.84 MiB/s, threads 2,226 events, with the watch's cost. 22 passes are left out: those overlapping the network checks, the `clock_gettime` test, and the twin loop's window (passes 10–20; [`s21_experiment_windows.txt`](s21_experiment_windows.txt)).
- **Network checks: 6 of 6 OK,** 0.47–0.57 MB/s up and 0.52–0.57 down, `apt-get update` exit 0 every time ([`net_s21.txt`](net_s21.txt)).

**Laptop outages in s21 (the laptop's, not the board's):**
- **01:27 UTC, 10-21: the app restarted on the laptop,** ahead of a full laptop shutdown the user is about to do. COM5 and COM7 logging, the stress watcher and the hourly check stopped with it.
  - COM5's last line is pass 229 at 27,210.80 s of uptime, at 01:26:58. Check 8, due at 01:28:22, was missed.
  - At 01:29 the board was still running: up 27,342.61 s (no reset since s21 began), the stress running, the watch armed, no SD1 timeout.
  - The laptop itself had not rebooted: up since 10-12.
  - **Correction:** the original loggers and the hourly check survived the app restart. They kept COM5 and COM7 and ran check 8 at 01:28:22, which pass 230 overlapped. Only their notifications to this session were lost, so a fresh watcher reads their log. Nothing was missed.
- **The coming full shutdown:** the coordinator has asked the user to keep the laptop off for at least 15 s and not to touch COM5's adapter. The CH340's line then stays low past the PMOD hook's 10.7 s ceiling, so it can't look like a reset request. After it, the board's uptime and the pass counter will show whether the board kept running.
- **About 01:32–01:35 UTC: the laptop's full shutdown and reboot** (it was up again at 01:35:05). Every laptop process died with it: the COM5 and COM7 loggers, the watcher, the hourly check and the timers.
  - COM5's last line before it was pass 231 at 27,457 s (01:31:04), and check 8 at 01:28:22 had passed.
  - **The board kept running.** COM5's first line after it, at 01:40:43, was pass 236 with `fails=0` at 28,049 s of uptime. Passes 232–235 ran unlogged, and the cumulative failure count shows them clean.
  - COM7's shell at 01:41:55 read 28,108 s of uptime: no reset since s21 began.
  - Logging restarted at 01:40 ([`uart_COM5_s21_part1.txt`](uart_COM5_s21_part1.txt) holds the part before).
  - **The board's network is down, on the laptop's side.** eth0 lost its link four times while the laptop rebooted (27,630–27,716 s). Its link came back at 1 Gb/s/Full, but it has no IPv4 address ([`uart_COM7_s21_net.txt`](uart_COM7_s21_net.txt)).
  - The laptop's connection sharing reports itself running, but nothing listens on UDP 67 (DHCP) or 53 (DNS), and the laptop's ARP entry for 192.168.137.6 stays "Incomplete". This is the known ICS fault after a reboot, and the user's restart of ICS fixes it.
  - The hourly checks resume once the lease is back; until then, the checks are what's missing.

**s21 ended at 08:03:44–08:04:00 UTC on 10-21 (01:04 PDT), by an external power cut.** The user interrupted the board's power supply ("I interrupted the board power supply seems, just let you know"). It was not a board fault.
- **When:**
  - COM5's last line is pass 432 (`fails=0`) at 51,018.75 s of uptime, at 08:03:44.
  - COM7 then shows a cold power-up: the FSBL, `Net: PHY reset timed out`, and `tanager-mode: ARM mode` (trial 1: the RISC-V boot was never confirmed). Ubuntu's kernel was 36 s in at 08:04:46 ([`uart_COM7_s21_cut.txt`](uart_COM7_s21_cut.txt)).
  - Ubuntu came up with `fancontrol` active and `k26-starter-kits` loaded. It has no IPv4 address while the laptop's ICS serves no DHCP; SSH works over its IPv6 link-local address. Its clock came back at 10-20 12:48 (no NTP).
- **s21's totals, 17:58:22 UTC 10-20 to the cut: 14.09 h of stress.**
  - 432 passes, all clean. 428 are logged; passes 232–235 ran during the laptop's reboot, and the cumulative count stayed at `fails=0` through pass 432.
  - No FAIL/DMESG line, no SD1 timeout, no probe capture, no kernel trouble.
  - Steady over 401 passes: 116.1 s per pass, cpu 90.31 events/s, memory 124.62 MiB/s, threads 2,221 events, with the watch's cost. 27 passes are left out for the network checks and the experiments; pass 236 is flagged only because its uptime span covers the unlogged passes.
  - Network checks: 8 of 8 OK, 0.47–0.57 MB/s up and 0.52–0.58 down, `apt-get update` exit 0 every time. Checks 9 on (from 02:28) never ran: the laptop's reboot left its ICS serving no DHCP, so the board had no lease.
- **The coordinator's call:** no restart of the 24 h soak on d4r2. The 60 of 60 boots and these 14 clean hours are enough for DR-176's fix. The next long stress comes with the product build that runs hart 1 (M8, 72 h).
- Logs: [`uart_COM5_s21_part1.txt`](uart_COM5_s21_part1.txt) (to pass 231), [`uart_COM5_s21_part2.txt`](uart_COM5_s21_part2.txt) (passes 236–432), [`net_s21.txt`](net_s21.txt).

## The SD1 hunt's set-up undone, and s22: d4r2 without the watch (10-21)

**The undo** ([`../runs/sd1_probe_undo.sh`](../runs/sd1_probe_undo.sh), [`../memgap/undo_run.txt`](../memgap/undo_run.txt); logged in the change log): the coordinator closed the hunt after d4r2's 60 boots.
- Removed: the probe, its initramfs hook and init-top script, the static busybox and soc-2's originals, the watch's unit and `sd_read_stress.sh`.
- `iomem=relaxed` is gone, busybox is purged, and the initramfs was rebuilt with no trace of the probe.
- **The boot after it was clean:** the kernel command line was `root=LABEL=tanager-root console=ttyS0,115200 earlycon rw`, nothing from the probe at the switch to the real root, no SD1 timeout.
- **OpenSBI's banner on that boot:** `Domain0 Region02 : 0x00000000ff5e0218-0x00000000ff5e021f M: (I,R,W) S/U: (R,W)`. This is the 8-byte PMP region soc-2 found behind RISC-V mode's memory gap: a region smaller than a page makes the core stop caching each 4K page's PMP result. Their test tree, `d4r2-riscv-pmpfix`, is checked and staged for when the coordinator schedules it.

**s22, the short stress without the watch** (d4r2, RISC-V mode, the old tree): from 08:59:06 UTC (`STRESS start 2026-10-21T08:34:27Z up=168.66`, [`uart_COM5_s22_start.txt`](uart_COM5_s22_start.txt)).
- The guest's clock runs about 25 minutes behind: with no DHCP from the laptop's ICS it has no NTP. It doesn't step during the run, so the pass times hold.
