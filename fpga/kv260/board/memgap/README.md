# RISC-V mode's memory gap on d4r2: soc-2's memgap in both modes (10-21)

**Why:** s21 showed sysbench memory (1 KiB blocks) 12.7% lower in RISC-V mode than in stage C on the same bitstream (d4r2), with the probe's watch in both runs. soc-2's `memgap` (sw/d4mode/memgap.c, main a39d7609) and `ps-memregs` find where the time goes ([`../../../../docs/spec/soc-d4-modes.md`](../../../../docs/spec/soc-d4-modes.md), "RISC-V mode's memory gap").

**How:**
- One bitstream for both modes: d4r2 (`33e29f3d…`). One memgap binary, built in stage C's Debian on p3.
- The probe's watch was stopped in both modes, so nothing else ran.
- **ARM mode, 08:08 UTC 10-21:** `ps-memregs` on Ubuntu with `k26-starter-kits` loaded, before any Tanager load → [`memregs_arm.txt`](memregs_arm.txt).
- **Stage C, 08:14–08:22 UTC:** [`../runs/memgap_stagec.sh`](../runs/memgap_stagec.sh) `tanager-d4r2`. The guest ran [`../runs/memgap_set.sh`](../runs/memgap_set.sh) `stagec`: memgap three times, the sysbench set, then a 60 s 1 MiB run while the A53 ran `ps-memregs --bridge` → [`memgap_stagec_1..3.txt`](memgap_stagec_1.txt), [`sysbench_stagec.txt`](sysbench_stagec.txt), [`memregs_stagec.txt`](memregs_stagec.txt).
- **RISC-V mode, 08:33–08:41 UTC:** the same set over SSH (IPv6 link-local; the laptop's ICS served no DHCP) → [`memgap_riscv_1..3.txt`](memgap_riscv_1.txt), [`sysbench_riscv.txt`](sysbench_riscv.txt).

**memgap, the mean of three runs per mode** (the runs agree within about 1%, rd16m within 4%):

| Test | Stage C | RISC-V mode | Change |
|---|---|---|---|
| clock (`clock_gettime`, the vDSO) | 984.4 ns | 1,078.4 ns | **+9.5%** |
| rdtime (the time CSR alone) | 204.6 ns | 225.3 ns | **+10.1%** |
| wr1k (a 1 KiB buffer, 8-byte stores: L1) | 461.1 MiB/s | 352.2 MiB/s | **−23.6%** |
| wr1m (the L2 and DDR) | 181.5 MiB/s | 182.7 MiB/s | +0.7% |
| wr16m (DDR write streaming) | 181.9 MiB/s | 182.2 MiB/s | +0.2% |
| rd16m (DDR read streaming) | 140.4 MiB/s | 132.2 MiB/s | −5.8% |
| chase16k (L1 latency) | 31.0 ns | 31.4 ns | +1.3% |
| chase256k (L2 latency) | 432.0 ns | 438.4 ns | +1.5% |
| chase64m (DDR latency) | 696.8 ns | 698.5 ns | +0.2% |
| pingpong (a coherence round trip) | 2,217.5 ns | 2,297.3 ns | +3.6% |
| ev1 (sysbench's event, one thread) | 5,410.7 ns | 6,368.9 ns | **+17.7%** |
| ev2local | 5,831.6 ns | 6,813.8 ns | +16.8% |
| ev2shared (sysbench's default) | 11,148.2 ns | 14,598.0 ns | **+30.9%** |

**sysbench memory, 20 s each:**

| Run | Stage C | RISC-V mode | Change |
|---|---|---|---|
| 1 KiB, 2 threads, global | 144.45 MiB/s | 126.08 MiB/s | −12.7% |
| 1 KiB, 2 threads, local | 167.21 | 156.05 | −6.7% |
| 1 KiB, 1 thread | 84.55 | 77.94 | −7.8% |
| 1 MiB, 2 threads, global | 344.73 | 335.61 | −2.6% |
| 1 MiB, 2 threads, local | 331.77 | 336.34 | +1.4% |
| 1 MiB, 1 thread | 180.81 | 178.79 | −1.1% |

**What it says** (soc-2's reading table, and one row the table doesn't have):
- **The DDR path is the same in both modes.** wr1m, wr16m and chase64m agree within 0.7%. rd16m reads 5.8% lower, but its RISC-V runs spread 130–135 MiB/s.
  - The PS registers on the memory path match too: only `AFI_FS` differs from ARM mode, and `riscv.scr` writes stage C's value.
  - Stage C's DRAM window is also at `0x8_4000_0000`.
  - The host bridge reads DDR natively in 27.1 cycles, measured during the 60 s run.
- **The time path is slower in RISC-V mode:** a bare `rdtime` costs 10% more, and `clock_gettime` 9.5% more.
- **A plain L1 store loop is 23.6% slower in RISC-V mode (wr1k).** No clock read, no memory path, no other load: RISC-V mode's idle lines show *less* CPU time and fewer interrupts than stage C's. This row isn't in soc-2's table.
- **The event's cost adds up from those two.** ev1 rises 958 ns. Three clock reads at +94 ns give +282 ns, and the 1 KiB block at wr1k's rates gives +655 ns, so +937 ns, 98% of it.
  - About 70% of sysbench's per-event gap is the slower store loop and 30% the slower clock read.
  - ev2shared adds the shared block's coherence (pingpong +3.6%).
- So the gap is in the core's own work, not in the memory system: a store-heavy loop and the time CSR both run slower in RISC-V mode on the same bitstream.
- **What differs between the two modes on one bitstream,** for soc-2 to weigh:
  - `BOARD_CTRL` is 3 in RISC-V mode (the fan bit, `RESET_CTRL` in the PS window, the PMOD hook) and 0 in stage C.
  - The OpenSBI builds differ: RISC-V mode's `fw_jump.bin` `b0094d23…` against stage C's from the d4r1 package.
  - The trees differ (`tanager.dtb` against the virtio tree).
  - The idle SMT threads (harts 1 and 3) may be parked differently.

## The fix: soc-2's PMP tree (main 3912dcd3), 10-21

**soc-2's diagnosis:** RISC-V mode's tree gave the reset syscon only RESET_CTRL's 4 bytes, so OpenSBI added an 8-byte PMP region (`Domain0 Region02 : 0xff5e0218-0xff5e021f`).
- Any region smaller than a page clears the core's "every 4K page is PMP-homogeneous" flag (tg_csr's `pmp_al`). Then no 4K page caches its PMP result in the TLB, and every store and fetch redirect takes the extra PMP check.
- Stage C's tree has no region below a page.
- **The fix** is the tree alone: the syscon spans the page (syscon@ff5e0000, reboot and poweroff at offset 0x218).

**On the board:** `d4r2-riscv-pmpfix` (`951b1c71…`), its `tanager.dtb` (`9b1fb7ef…`) on p1, the old tree kept as `tanager.dtb.pre-pmpfix`. Logged with its undo.

**The four checks, all passed:**
1. **OpenSBI's banner:** `Domain0 Region03 : 0x00000000ff5e0000-0x00000000ff5e0fff M: (I,R,W) S/U: (R,W)`. Every region is now a page or larger.
2. **memgap, three runs, nothing else running:**

   | Test | Stage C | RISC-V mode, old tree | RISC-V mode, fixed tree |
   |---|---|---|---|
   | wr1k | 461.1 MiB/s | 352.2 (−23.6%) | **460.9 (−0.0%)** |
   | rdtime | 204.6 ns | 225.3 (+10.1%) | **204.7 (+0.0%)** |
   | clock | 984.4 ns | 1,078.4 (+9.5%) | **1,002.9 (+1.9%;** 986 and 990 in two runs, 1,032 in one) |
   | ev1 | 5,410.7 ns | 6,368.9 (+17.7%) | **5,411.5 (+0.0%)** |
   | ev2local | 5,831.6 ns | 6,813.8 (+16.8%) | **5,841.7 (+0.2%)** |
   | ev2shared | 11,148.2 ns | 14,598.0 (+30.9%) | **11,153.9 (+0.1%)** |
   | pingpong | 2,217.5 ns | 2,297.3 (+3.6%) | **2,204.6 (−0.6%)** |
   | rd16m | 140.4 MiB/s | 132.2 (−5.8%) | **140.6 (+0.1%)** |
   | wr1m, wr16m, chase16k/256k/64m | — | within 1.5% | **within 0.3%** |

3. **sysbench memory, 1 KiB on two threads:** 146.11 MiB/s, against stage C's 144.45 and the old tree's 126.08. The rest of the set is within 1–2% of stage C ([`sysbench_pmpfix.txt`](sysbench_pmpfix.txt)).
4. **`reboot` and `poweroff` still reset the board** through RESET_CTRL at its new offset. `reboot: Restarting system` and `reboot: Power down` were each followed by a fresh boot back into RISC-V mode ([`../stress/uart_COM5_pmpfix_boots.txt`](../stress/uart_COM5_pmpfix_boots.txt)).

**So RISC-V mode's memory gap is closed.** Once the tree stops making a sub-page PMP region, the core runs at stage C's speed on the same bitstream.
