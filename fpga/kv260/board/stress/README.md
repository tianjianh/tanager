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
  - **s16 in all:** 9 of 9 passes clean in RISC-V mode, at 116.7 s per pass.
- **s17 (d4s2, stage C):** from 18:18 UTC (the A53's clock, then 7 minutes behind the laptop's), while the SoC track fixes D5's `riscv.scr`.
- **s17 (d4s2, stage C):** 6 of 6 passes clean at 115 s per pass (cpu 93.9, memory 114.8, threads 2,325).
  - The first `q` was lost: it reached the console before the stress loop had started.
  - A second `q` stopped it at 18:40 for D5's step 2 ("STRESS stop after pass 6, fails=0").
  - Its stage C logs stay on the A53 until the next ARM-mode window.
- **s16, segment c (RISC-V mode, now with Ethernet up):** the stress from 19:02:42 UTC. The guest's clock is NTP-synced now (`STRESS start 2026-10-19T18:59:16Z`).
