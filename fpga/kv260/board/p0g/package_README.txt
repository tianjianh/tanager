p0g: p0f's two-core platform with an L2 error capture, the timer freeze and core-2's debug words (DR-150).

Tree a39b13f826f2 (refs/soc-tmp/p0g; the same tree as soc-2's branch at 5b518c2): main 82463e2 with core-2's
73e88bd, soc-2's branch (stage C RTL, off here) and verif-2's c665894. Build: kv260_top, smt2, 2 cores (harts 0
and 2), 70 MHz, the commit trace on, TG_DEBUG_CNT=1 (counters, capture, core debug words), AreaOptimized_high,
PMOD console, fan per DR-129. No virtio window or DMA port (p0f's configuration).
Timing at 70 MHz: WNS +1.760 ns, WHS +0.010 ns (routed; summary.txt); 112,168 synthesis LUTs (95.8%); TG_CHECK clean, with Synth 8-6901 now checked too.

What's new against p0f:
1. The first L2 error, whole, and the first refused DRAM burst: `sudo ./tanager-host dbg` (during the run, or
   `run --dbg`, which prints it before the exit's hold) ends with
     DRAM window refusals    N reads, M writes
     first L2 error: bank b, <kind>, line 0x... (address 0x...); C <opcode> <param> from source 0x...;
       directory hit|miss: valid v dirty d tip t pres 0x..; MSHR m          (kinds 1-3; kinds 4-5: AXI resp, ID)
     first refused burst: a read|write at 0x...
   The kinds: 1 a Release or ProbeAck for a line not held, 2 a ProbeAck no probing MSHR waits for, 3 a victim
   still held after its probes, 4 a write response error, 5 a fill read error. The capture holds the first error
   until the uncore's next reset.
2. The timer freeze: `run --freeze-time` holds mtime while the trace stalls the cores (CTRL.TFREEZE), so Linux
   under the checker sees time pass with its instructions. Use the plain 768m DTB (10 MHz timebase) with it.
3. core-2's debug words: `dbg` prints each core's status and its first dispatch and commit groups.

Files: fw_jump.bin, Image (Buildroot), tanager-kv260.dtb (1 GiB), tanager-kv260-768m.dtb, tanager-kv260-bench.dtb
(harts 0 and 2, as p0f's), tanager-host (soc-2 c2cc421: --freeze-time, --dbg, the capture decode, the dma fix, --net).

Runs, in order:
  a. The traced boot that made the errors (your C1), then read the capture:
       sudo ./tanager-host boot --fw fw_jump.bin --kernel Image --dtb tanager-kv260-768m.dtb --trace /dev/null \
         --trace-log2 16 --trace-wrap --dbg            (or read `sudo ./tanager-host dbg` from a second shell)
     Send me the whole dbg output: the error's kind, line, C message and directory state go to core-2 too.
  b. The plain boot (no trace) as a control: the capture should say no L2 error.
  c. Two-core lockstep with --freeze-time and the plain 768m DTB, to Linux's shell if it gets there.
What simulation already says (this tree, a traced two-core boot with the trace stalling the cores as on the board, 60M cycles, still in OpenSBI): L2 error events 6008, your C1's number exactly; refused DRAM reads 1502 (x 4 fill beats = 6008); the first error kind 5, a fill read error (SLVERR); the first refused read at 0xF273A280. So the events are line fetches the window refused, beyond the 1 GiB window but inside the core's 2 GiB memory PMA, made by instructions that never committed (lockstep found no mismatch, and a committed one would trap). Run a. should show the same on the board.
