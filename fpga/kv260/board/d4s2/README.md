# M6's first Linux measurement on the board: DR-141's set on d4s2 (2026-10-19)

**The bitstream:** d4s2 (`18f6310c…`, commit `03171ea+c261c1f`) is M6's configuration with core-2's micro-BTB fix, plus D4's step 1 changes, which are inert at `BOARD_CTRL` 0. M6 runs Linux on the board for the first time here. d4s1 (the same without the fix) panicked Linux ([`../d4/README.md`](../d4/README.md)).

**Why d4s2:** the coordinator asked for this measurement on d4s1, in a message that arrived after d4s1 was found to panic. d4s2 is the same configuration minus the bug.

**The comparison:** d2 (`36bae1fc…`, [`../d2-reg/README.md`](../d2-reg/README.md)), with the same clock (100 MHz), harts (2), kernel, image and tree. Both ran as the app, with `fancontrol` running and `BOARD_CTRL` 0.

**How:**
- [`../runs/bench_fan.sh`](../runs/bench_fan.sh) `tanager-d4s2 ~/tanager/d4s2-smt2-c2-100 d4s2`, which runs `bench.sh`'s 3 boots with the fan sampled every 30 s.
- The verification track's dr141-linux `fw_jump.bin` and bench `Image` (kernel 6.18.56-tanager) on p0f's bench tree (`217a907c…`, the same as d2's).
- Compared on the build host (w-x299) with `tests/bench/linux/tglb_compare.py`.

**Records:**
- [`bench_d4s2.txt`](bench_d4s2.txt);
- the consoles [`d4s2_boot1.txt`](d4s2_boot1.txt), [`d4s2_boot2.txt`](d4s2_boot2.txt), [`d4s2_boot3.txt`](d4s2_boot3.txt);
- [`cmp_cycles.md`](cmp_cycles.md), [`cmp_instret.md`](cmp_instret.md), [`cmp_ns.md`](cmp_ns.md);
- [`fan_bench_d4s2.txt`](fan_bench_d4s2.txt).

**Every boot passes:** `TANAGER-BOOT-OK` at 4 s, 54 of 54 measurement lines, CoreMark validated 6 times, `TGLB-END status=0`. Each boot took 246–247 s, against 309–310 s on d2.

**Against d2, cycles per operation** (the median of 9 runs per bitstream; a change inside the spread is not a finding):

| Test | d2 | d4s2 (change) | Spread |
|---|---|---|---|
| CoreMark A | 361,162 | 216,938 (**−39.9%**) | 0.5% |
| CoreMark B | 436,527 | 229,159 (**−47.5%**) | 0.3% |
| Dhrystone | 405 | 202 (**−50.1%**) | 0.4% |
| fork+exec | 2,770,574 | 2,069,659 (**−25.3%**) | 1.0% |
| syscall | 502 | 426 (−15.1%) | 0.8% |
| page fault | 9,108 | 7,702 (−15.4%) | 2.1% |
| TLB walk | 115 | 113 (−1.1%) | 0.7% |
| memcpy 64 B | 81.09 | 64.83 (−20.1%) | 0.1% |
| memset 64 B | 61.76 | 34.46 (−44.2%) | 0.3% |
| memcpy 4 KiB | 1,198 | 1,009 (−15.8%) | 0.5% |
| memset 4 KiB | 722 | 687 (−4.8%) | 1.0% |
| memcpy 1 MiB | 1,406,383 | 1,235,609 (−12.1%) | 1.6% |
| memset 1 MiB | 758,908 | 806,316 (+6.2%, inside the spread) | 20.6% |
| tmpfs write | 154,678 | 118,635 (−23.3%) | 3.1% |
| tmpfs read | 128,385 | 71,559 (**−44.3%**) | 0.7% |
| pipe | 181,315 | 126,582 (−30.2%) | 23.5% |
| gzip | 1,591,146,548 | 1,250,270,695 (−21.4%) | 0.3% |
| sha256sum | 217,090,578 | 181,946,287 (−16.2%) | 0.2% |

**Instructions per operation match d2's within 0.0–0.8%:** the same kernel and image, a little fewer from fewer timer ticks per shorter operation. So the changes above are IPC.

**Linux reaches `/init` in 0.929 s against 1.181 s (−21.3%).**

**Per MHz** (CoreMark/MHz = 10⁶ / cycles per iteration; DMIPS/MHz = 10⁶ / (cycles per Dhrystone × 1757)). The Linux columns are measured on the board; the last column is RTL simulation from main's devlog.

| | d2, Linux on the board | d4s2, Linux on the board | Measured IPC (d2 → d4s2) | M6 in RTL simulation (main, aae0503) |
|---|---|---|---|---|
| CoreMark A | 2.77 | **4.61** | 0.94 → 1.56 | 4.55 |
| CoreMark B | 2.29 | **4.36** | 0.79 → 1.50 | 4.27 |
| Dhrystone | 1.41 DMIPS/MHz | **2.82 DMIPS/MHz** | 0.80 → 1.60 | 3.08 (rv64gc) |

- **CoreMark** under Linux on the board is within 1.3–2.1% of M6's bare-metal RTL figures.
- **Dhrystone** is 8.5% below. The Linux set's Dhrystone is its own build and runs with Linux's timer ticks, so it isn't the same program as the RTL run. Matching it is the model and RTL tracks' business, not a finding of this run.

**The fan during the set** (fancontrol running): 25 samples. PL die 33.9–35.4 °C, duty 15–35/255. The A53's AMS read 34–35 °C.

**Then:** the soak s15, d4s2 in stage C from p3, from 17:28:09 UTC ([`../stress/README.md`](../stress/README.md)).
