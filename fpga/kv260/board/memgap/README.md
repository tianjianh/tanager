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
