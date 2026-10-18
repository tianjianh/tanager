# Stage D's D2 on the board: the fan's PL regulator, and DR-156's confirmation (2026-10-18)

**The package:** `d2-smt2-c2-100` from the SoC track, commit `e65db3a` on main `646722b` ([`package_README.txt`](package_README.txt), [`summary.txt`](summary.txt), [`SHA256SUMS`](SHA256SUMS)).
- **The bitstream** (`36bae1fc…`): D1's configuration (sc3's, plus the PS window) with the fan's PL regulator (DR-147 option F-a) and DR-156's L1D, four misses in flight. It doesn't have the speculative load wakeup (`ce47115`), so the only change to the cores against sc3 is DR-156.
  - WNS +0.505 ns; 112,446 LUTs (96.0%).
- **The tools:** `tanager-host` `f515c0f6…`, the D2 probes' build plus `fan`.
- **How it ran:** the app `tanager-d2`, [`../runs/d2_run.sh`](../runs/d2_run.sh) (`ref12`, `alone`, `bench`), every `tanager-host` call guarded on the app.
- **The regulator:** `fan_en_b` carries a 24.4 kHz PWM at the larger of two duties:
  - fancontrol's curve on the PL SYSMON's die temperature;
  - the A53's TTC duty (its `pwm1`).

## Steps 0–2: the reference, the load, the regulator beside fancontrol ([`d2_ref12.txt`](d2_ref12.txt))

- **Step 0, a fresh sc3 load:** PS SYSMON `0x9E30`, PL SYSMON `0x9D78` (34.0 °C). The PL SYSMON's configuration and sequence registers are all 0, as after any of our loads.
- **Step 1, d2 loaded:**
  - `fan: PL die 33.9 C, duty 15/255 (the larger of the curve's and the A53's), the A53's PWM 14/255`;
  - no new dmesg line;
  - `info`: `smt2`, 2 × 2, 100 MHz.
- **Step 2, six readings 10 s apart:** PL die 33.9–34.4 °C (about 1 °C below the PS's `temp1`), duty 15/255, the A53's PWM 14–15 against `pwm1` 15. As designed.
- **One finding: with d2 loaded, the A53 can no longer read the PL SYSMON.**
  - Through the AMS, its temperature reads 0 (it was `0x9D78` on sc3), and the A53's hwmon `temp3` (the PL channel) shows −280.2 °C.
  - `AMS_PL_CSTS` reads 0 with d2 and 1 with sc3; `AMS_PS_CSTS` is `0x08010000` with both ([`ams_csts.txt`](ams_csts.txt)).
  - The SoC track's reading: instantiating SYSMONE4 hands the PL SYSMON's register port to the fabric.
  - `fancontrol` is unaffected: it follows `temp1`, the PS SYSMON. The regulator's own reading is live.
  - It contradicts "the A53 sees nothing new". The SoC track is taking two options to the coordinator: keep it and document it, or read the PS SYSMON through S_AXI_LPD instead, with no SYSMONE4.

## Step 3: the regulator alone (DR-147's D2 check, approved by the coordinator with guards)

**The guards:** fancontrol stopped for at most 5 minutes, sampled every 30 s; fancontrol restarts at once above 50 °C, or if the regulator's duty reads 0. The board was idle.

- **First try, `pwm1` written 0** ([`d2_alone_pwm0.txt`](d2_alone_pwm0.txt)):
  - With the PWM disabled, the TTC output idles low. The regulator read that as the A53 asking 255/255, so the duty was 255 and **the fan ran at full speed for 5 minutes**. temp1 fell from 34.5 to 31.4 °C.
  - The package's README says to write 1 in that case, and my script lacked that fallback: my miss.
  - The script now writes 1, and aborts if the A53's PWM reads 128 or more.
- **Second try, `pwm1` written 1** ([`d2_alone_pwm1.txt`](d2_alone_pwm1.txt)): **pass.**
  - The A53's PWM read 0/255. The duty was 15/255, the curve's minimum, in all 10 samples over 5 minutes.
  - PL die 32.9–34.4 °C, temp1 33.4–36.4 °C, steady; no guard fired.
  - fancontrol was restarted at 06:17:20, and the A53's PWM read 15/255 again.

## Step 4: DR-141's set on d2, against sc3 (DR-156's confirmation)

[`d2_bench_run.txt`](d2_bench_run.txt); consoles [`d2_boot1.txt`](d2_boot1.txt), [`d2_boot2.txt`](d2_boot2.txt), [`d2_boot3.txt`](d2_boot3.txt). The verification track's dr141-linux `fw_jump.bin` and bench `Image` on p0f's bench tree, as for sc3.
- **Every boot passes:** `TANAGER-BOOT-OK` at 4–5 s, 54 of 54 measurement lines, CoreMark validated 6 times, `TGLB-END status=0`, the power-off at 309–310 s (sc3: 323–326 s).
- **Against sc3** (one miss, the same clock, harts and kernel), compared on the 5950X with `tglb_compare.py`: [`cmp_cycles.md`](cmp_cycles.md), [`cmp_instret.md`](cmp_instret.md), [`cmp_ns.md`](cmp_ns.md).

| Test | sc3 cycles/op | d2 (change) | Spread |
|---|---|---|---|
| memcpy 1 MiB | 2,264,615 | 1,406,383 (**−37.9%**) | 1.7% |
| tmpfs write | 205,281 | 154,678 (**−24.7%**) | 3.1% |
| pipe | 220,426 | 181,315 (−17.7%) | 14.4% |
| tmpfs read | 148,820 | 128,385 (**−13.7%**) | 0.8% |
| gzip | 1,827,357,496 | 1,591,146,548 (**−12.9%**) | 0.3% |
| memset 1 MiB | 867,092 | 758,908 (−12.5%) | 20.5% |
| TLB walk | 127 | 115 (−9.9%) | 0.7% |
| fork+exec | 2,927,093 | 2,770,574 (−5.3%) | 1.0% |
| page fault | 9,609 | 9,108 (−5.2%) | 2.0% |
| sha256sum | 218,097,522 | 217,090,578 (−0.5%) | 0.2% |
| syscall, memcpy/memset 64 B and 4 KiB | | ±0.2% | |
| CoreMark A, CoreMark B, Dhrystone | 361,131 / 436,348 / 405 | +0.0% each | ≤0.2% |

- **Instructions per operation** match sc3's within the spread: the same kernel and clock. The memory-heavy tests drop by 0.1–2.6%, from fewer timer ticks per (shorter) operation.
- **Linux reaches `/init`** in 1.181 s against 1.289 s (−8.4%).
- **So DR-156 holds on the board:** four L1D misses in flight speed up the memory-heavy work (memcpy 1 MiB −38%, tmpfs −14% to −25%, gzip −13%) and leave everything that fits in the L1 (CoreMark, Dhrystone, sha256sum) unchanged.
- **The fan during the set** ([`fan_bench.txt`](fan_bench.txt), every 30 s, fancontrol running):
  - 30 samples, PL die 33.9–35.4 °C;
  - duty 15–38/255, never below the A53's PWM (0 of 30 samples);
  - the duty followed fancontrol's PWM, or the curve when that was higher.
