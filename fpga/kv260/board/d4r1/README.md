# The final D4 bitstream under Linux: DR-141's set on d4r1 (2026-10-19)

**The bitstream:** d4r1 (`5067cd1b…`, main `c072fff`), soc-2's release build. It is M6 with:
- core-2's micro-BTB fix;
- FENCE.I by generation;
- the store prefetch (`STORE_PF`);
- PMP with 8 entries;
- D4's step 1.

It has d2's configuration: smt2, two cores of two threads, 100 MHz. It has no commit trace. 106,000 LUTs are placed (90.51%), at WNS +0.777 ns.

**What it adds to d4s2** (`03171ea+c261c1f`, M6's first Linux measurement, [`../d4s2/README.md`](../d4s2/README.md); the same build options, no trace, `AreaOptimized_high`). Both pieces come from DR-171:
- **The store ownership prefetch:** when a store's address resolves, the D$ asks for the line with write permission at once, through its existing miss entries. A store that misses then no longer holds a full store queue (and rename behind it) while it waits for its line.
- **FENCE.I by generation:** each I$ line carries a 2-bit generation in place of its valid bit. FENCE.I steps the generation and a background sweep clears the stale lines, so fetch restarts at once instead of after a 64-cycle sweep.
- **PMP-8:** entries 8–15 read zero. Linux doesn't use PMP, so this doesn't change the measurement.

**The comparisons:**
- d4s2, for the two DR-171 pieces under Linux;
- d2 (`36bae1fc…`, [`../d2-reg/README.md`](../d2-reg/README.md)), the pre-M6 base.

All three run the same clock (100 MHz), harts (2), kernel, image and tree. Each ran as the app (`tanager-d4r1` here), with `fancontrol` running and `BOARD_CTRL` 0.

**How:**
- [`../runs/bench_fan.sh`](../runs/bench_fan.sh) `tanager-d4r1 ~/tanager/d4r1-smt2-c2-100 d4r1`: `bench.sh`'s 3 boots, with the fan sampled every 30 s.
- The verification track's dr141-linux `fw_jump.bin` and bench `Image` (kernel 6.18.56-tanager), on p0f's bench tree.
- Compared on the build host (w-x299) with `tests/bench/linux/tglb_compare.py` from main.

**Records:**
- [`bench_d4r1.txt`](bench_d4r1.txt);
- the consoles [`d4r1_boot1.txt`](d4r1_boot1.txt), [`d4r1_boot2.txt`](d4r1_boot2.txt), [`d4r1_boot3.txt`](d4r1_boot3.txt);
- against d2 and d4s2: [`cmp3_cycles.md`](cmp3_cycles.md), [`cmp3_instret.md`](cmp3_instret.md), [`cmp3_ns.md`](cmp3_ns.md);
- against d4s2 alone: [`cmp2_cycles.md`](cmp2_cycles.md), [`cmp2_instret.md`](cmp2_instret.md), [`cmp2_ns.md`](cmp2_ns.md);
- [`fan_bench_d4r1.txt`](fan_bench_d4r1.txt).

**Every boot passes:** 54 of 54 measurement lines, CoreMark validated 6 times, `TGLB-END status=0`. Each boot took 241–244 s, against 246–247 s on d4s2 and 309–310 s on d2.

**Cycles per operation** (the median of 9 runs per bitstream; a change inside the spread is not a finding):

| Test | d2 | d4s2 (against d2) | d4r1 (against d2) | **d4r1 against d4s2** | Spread |
|---|---|---|---|---|---|
| CoreMark A | 361,162 | 216,938 (−39.9%) | 217,268 (−39.8%) | +0.2% | 0.5% |
| CoreMark B | 436,527 | 229,159 (−47.5%) | 229,231 (−47.5%) | +0.0% | 0.4% |
| Dhrystone | 405 | 202 (−50.1%) | 202 (−50.1%) | −0.1% | 0.4% |
| fork+exec | 2,770,574 | 2,069,659 (−25.3%) | 2,029,862 (−26.7%) | **−1.9%** | 0.9% |
| syscall | 502 | 426 (−15.1%) | 426 (−15.2%) | −0.1% | 0.3% |
| page fault | 9,108 | 7,702 (−15.4%) | 5,538 (−39.2%) | **−28.1%** | 2.9% |
| TLB walk | 115 | 113 (−1.1%) | 113 (−1.1%) | +0.1% | 0.8% |
| memcpy 64 B | 81.09 | 64.83 (−20.1%) | 64.84 (−20.0%) | +0.0% | 0.2% |
| memset 64 B | 61.76 | 34.46 (−44.2%) | 34.45 (−44.2%) | −0.0% | 0.3% |
| memcpy 4 KiB | 1,198 | 1,009 (−15.8%) | 1,009 (−15.8%) | +0.0% | 0.5% |
| memset 4 KiB | 722 | 687 (−4.8%) | 687 (−4.7%) | +0.1% | 0.8% |
| memcpy 1 MiB | 1,406,383 | 1,235,609 (−12.1%) | 809,078 (−42.5%) | **−34.5%** | 1.3% |
| memset 1 MiB | 758,908 | 806,316 (+6.2%) | 572,324 (−24.6%) | **−29.0%** | 20.6% |
| tmpfs write | 154,678 | 118,635 (−23.3%) | 95,774 (−38.1%) | **−19.3%** | 3.1% |
| tmpfs read | 128,385 | 71,559 (−44.3%) | 68,322 (−46.8%) | **−4.5%** | 0.7% |
| pipe | 181,315 | 126,582 (−30.2%) | 122,663 (−32.3%) | −3.1% (inside the spread) | 23.5% |
| gzip | 1,591,146,548 | 1,250,270,695 (−21.4%) | 1,250,170,461 (−21.4%) | −0.0% | 0.5% |
| sha256sum | 217,090,578 | 181,946,287 (−16.2%) | 181,869,633 (−16.2%) | −0.0% | 0.1% |

The spread column is the pair's; the d2 columns come from `cmp3_cycles.md`, whose spread includes d2's.

**Instructions per operation match d4s2's within 0.0–1.4%.** The largest differences are memset 1 MiB (−1.4%) and memcpy 1 MiB (−0.9%): fewer timer ticks land in a shorter operation. So the changes above are IPC.

**Linux reaches `/init` in 0.831 s:** −10.5% against d4s2 (0.929 s) and −29.6% against d2 (1.181 s), with a 0.4% spread over the three boots.

**What the two pieces do under Linux:**
- **Store-bound kernel work gains a lot:**
  - page faults (the kernel clears each new page): −28.1%;
  - memcpy and memset over 1 MiB: −34.5% and −29.0%;
  - tmpfs writes: −19.3%;
  - fork+exec: −1.9%;
  - the boot to `/init`: −10.5%.

  These are the stores DR-171's profile found holding rename ("a full store queue holds rename on 12.7% of cycles while one missing store waits for its line").
- **Compute that stays in the caches doesn't move:** CoreMark, Dhrystone, gzip, sha256sum, the 64 B and 4 KiB copies, and syscalls are unchanged within 0.2%.
- **This set can't split the two pieces,** since both changed at once.
  - smt2-study's whole-boot simulation gives the store prefetch +6.2% and FENCE.I by generation +0.29%. So most of the gains here are likely the store prefetch's; FENCE.I's share is likely a part of fork+exec's −1.9%, where exec loads code and flushes the I$.
  - A split on the board needs a build with one switch off.
- **For DR-171's open question** ("steady-state Linux on the board decides the default"): on this set the store prefetch costs nothing on any row and gains 19–35% on the store-bound ones. That supports keeping it on by default.

**Per MHz** (CoreMark/MHz = 10⁶ / cycles per iteration; DMIPS/MHz = 10⁶ / (cycles per Dhrystone × 1757)):

| | d2 | d4s2 | **d4r1** | Measured IPC, d4r1 |
|---|---|---|---|---|
| CoreMark A | 2.77 | 4.61 | **4.60** | 1.56 |
| CoreMark B | 2.29 | 4.36 | **4.36** | 1.50 |
| Dhrystone | 1.41 DMIPS/MHz | 2.82 DMIPS/MHz | **2.82 DMIPS/MHz** | 1.60 |

**The fan during the set** (`fancontrol` running): 24 samples. PL die 33.9–34.9 °C, duty 15–42/255. The A53's AMS read 33–36 °C.

**Debian 13 under the two-core stress, stage C (s18, [`../stress/README.md`](../stress/README.md)).** This is d4r1's first Debian boot, from p3, as the standing rule asks before RISC-V mode depends on a new bitstream. Both passes were clean, against d4s2 on the same stress (s17, 6 passes):

| | d4s2 (s17) | d4r1 (s18) | Change |
|---|---|---|---|
| Pass | 115.2 s | 114.5 s | −0.6% |
| sysbench cpu, 2 threads | 93.88 events/s | 94.16 events/s | +0.3% |
| **sysbench memory, 2 threads** | 114.81 MiB/s | **138.30 MiB/s** | **+20.5%** |
| sysbench threads, 2 threads | 2,325 events | 2,342 events | +0.7% |

- sysbench's memory test writes (its default), so this fits the store prefetch's gains in the set above.
- cpu and threads don't move, like CoreMark and Dhrystone.

**Then:** the 24-hour soak in RISC-V mode on `d4r1-riscv` ([`../stress/README.md`](../stress/README.md)).
