d2-smt2-c2-100: stage D's D2 (docs/spec/soc.md §8.2): the fan's PL regulator (DR-147 option F-a, DR-150), and
DR-156's board confirmation (the L1D keeps four misses in flight, the default since main 0003f3b; the
coordinator: run DR-141's set on this bitstream when the board has time). soc-2, branch
claude/track-soc-160053, commit e65db3a864ef (main 646722b merged). d1's configuration (sc3's: smt2, two cores,
100 MHz, the virtio window and the host DMA port, the trace, PMOD console; plus the PS window, idle unless the
RISC-V touches it), with the regulator and the four-miss L1D. Timing: WNS=0.505 WHS=0.010; pr_unc=1.0 ns; 112446 LUTs placed (96.01%).

The regulator: fan_en_b carries a 24.4 kHz PWM at the larger of two duties:
  - the curve of the PL SYSMON's die temperature, fancontrol's own: 15/255 at or below 35 C, then about
    15 + 24 x (T - 35), 255 from 45 C; a fall takes effect only 1 C under the level that set it;
  - the A53's duty: the low time of its TTC waveform (fancontrol's pwm1), as it reaches the fan today.
So while fancontrol runs, the fan runs as it asks or faster; with fancontrol stopped (or the A53 parked, as
from D3), the curve regulates alone. Full speed until the first reading (10 ms after the load) and whenever a
SYSMON read goes unanswered. The PL SYSMON is a SYSMONE4 with every INIT attribute zero, the state a load
already leaves it in (d2-probes, 10-17), so the A53's AMS readings see nothing new; fancontrol follows the PS
SYSMON anyway. The PL die runs about 1 C below the PS's sensor. Status: the host bridge's FAN register, read by
`tanager-host fan` (no lock: it can run beside a running tanager-host).

Files: tanager.bit.bin, tanager.dtbo (as d1's), shell.json, tanager-host (d2-probes' plus `fan`), ps_d1.bin (d1's test,
unchanged), tanager-kv260-bench.dtb (p0f's, 217a907c..., the one sc3's DR-141 runs used), and sc3's boot files
(fw_jump.bin, Image, the virtio DTBs) with sdpart's u-boot.bin, so stage C (Debian from p3) runs as on d1.

0. Reference, with the current app (sc3 or d1) still loaded, read-only:
     cat /sys/class/hwmon/hwmon*/pwm1 ; fancontrol's temp1_input (the AMS hwmon)
     sudo ./tanager-host psrd 0xFFA50800 ; sudo ./tanager-host psrd 0xFFA50C00      PS and PL SYSMON temperatures
     sudo ./tanager-host psrd 0xFFA50D00 5 ; sudo ./tanager-host psrd 0xFFA50D18 4  PL SYSMON configuration, sequence
1. Load d2 (xmutil, as usual). The fan runs full for a moment, then as before. If it stops or stays silent, or
   step 2 shows a duty below the A53's PWM, load sc3's app at once (its fan path is the A53's alone) and tell
   soc-2. Then: sudo ./tanager-host info ; dmesg | tail   (nothing new from the AMS or the fan).
2. With fancontrol running (it should change nothing at the board's 31-35 C):
     sudo ./tanager-host fan     a few times, 10 s apart, each beside cat .../pwm1 and the temp1 above
   Expected: "fan: PL die T C, duty D/255 (the larger of the curve's and the A53's), the A53's PWM P/255"
     - T within about 1.5 C of the PL SYSMON through the AMS (psrd 0xFFA50C00: code x 509.314 / 65536 - 280.231)
       and about 1 C below temp1; the display has 0.5 C steps;
     - P within 2 of pwm1 (0 or 255 at the ends);
     - D the larger of P and the curve at T (15 at or below 35 C).
   Then step 0's psrd lines again: the PL SYSMON's configuration and sequence words as in step 0 (0 after sc3's
   load), its temperature converting; the A53's hwmon still reads every channel.
3. The regulator alone (DR-147's D2 check: fancontrol stopped, at most 5 minutes; fancontrol's pwm-fan is
   hwmonN, the one with pwm1):
     sudo systemctl stop fancontrol ; echo 0 | sudo tee /sys/class/hwmon/hwmonN/pwm1
     for i in $(seq 10); do sudo ./tanager-host fan; cat /sys/class/hwmon/hwmon*/temp1_input; sleep 30; done
   Expected: the A53's PWM 0/255 and the duty the curve's (15/255 at or below 35 C; the fan slower but turning),
   the temperature steady. If the A53's PWM reads 255 instead (the TTC output idling low with the PWM disabled),
   write 1 instead of 0. If the temperature passes 50 C or the fan stops, start fancontrol at once.
     sudo systemctl start fancontrol ; sudo ./tanager-host fan     the A53's PWM back to pwm1
4. DR-156's confirmation, DR-141's set (with fancontrol running), as sc3's runs (fpga/kv260/board/sc3): the
   verification track's dr141-linux fw_jump.bin and bench Image (7b4e2412..., edfd4c5f...) on this directory's
   bench DTB:
     BOOTS=3 runs/bench.sh <the d2 app> <this directory> d2
   and in a second shell, for the heat (DR-147: the status word follows a stress run's heat):
     while sleep 30; do date +%T; sudo ./tanager-host fan; cat /sys/class/hwmon/hwmon*/temp1_input; done | tee fan_bench.txt
   Checks as sc3's: TANAGER-BOOT-OK, 54 of 54 measurement lines, CoreMark validated 6 times, TGLB-END
   status=0, power-off. Compare with sc3_boot1-3 (one miss, same clock and harts) with
   tests/bench/linux/tglb_compare.py: cycles, instructions and time per operation, and the boot to /init.
   Instructions per operation should match sc3's within the spread (the same kernel and clock); the cycles are
   DR-156's effect, if any: the memory-heavy tests (memcpy/memset 1 MiB, tmpfs, pagefault, forkexec, gzip) are
   where four misses can help; CoreMark, Dhrystone and sha256sum fit in the L1 and should not move.
5. Optional, cheap: d1's test on this bitstream (the PS window, unchanged):
     sudo ./tanager-host load --fw ps_d1.bin --kernel /dev/null --dtb /dev/null && sudo ./tanager-host run --timeout 10
   expecting D1 PASS as on d1; and stage C (Debian from p3) once, if the board has the time.
Send the raw outputs of 0-4 (fan_bench.txt included); soc-2 decodes them.
