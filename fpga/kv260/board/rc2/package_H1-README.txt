rc2u100-riscv: the near-final release preview at 100 MHz, the first board image with M7's step 7 (soc-2 packaging
spikes-2's build, 10-23), RISC-V mode only. Four harts: two smt2 cores with two threads each, hart 1 on in both. It is a
preview from branches not all on main yet; the image of record is built from main once core-2's MRs land. Keep u100
(100 MHz, without step 7) as the fallback, and dr187b (80 MHz) behind it.
Built from 9dbbad723e3f: spikes-2's snapshot of main 28d28d8a (DR-183's PMP checks at TLB fill on by default, the head's
registered MMIO check, the checkers' M-mode registers) with fpu-2's step-7 cut (f1d79a86), soc-2's checker requests
from registers (02da289b), core-2's marg3 (813b6743) and CoRR snoop marking (b51bbbf6), as a release build
(TG_RELEASE=1, DR-180): smt2, two cores, 100 MHz, the PMOD console, the host DMA port, the PS window, the fan's PL
regulator, g4_uncore's floorplan (DR-181), DR-186's slices off, place_design AltSpreadLogic_high, with defines TG_HART1=1 TG_COMMIT_TRACE=0 and the UltraRAM register file (TG_URF=1, DR-174) with clk2x at 200 MHz.
Timing: WNS=0.296 WHS=0.010; 112360 LUTs placed (95.94%), at the plain 10 ns (DR-160's 1.0 ns of place-and-route uncertainty is taken back for the report).

New on the board:
- M7's step 7 (the two threads' throughput step) on the four harts.
- OpenSBI with Tanager's patch set tg1 (fw_jump.bin 62349a65..., soc.md §5): a remote fence or IPI whose hart mask
  names a stopped hart now reaches the started harts instead of failing the whole call, the u100 soak's
  "__sbi_rfence_v02_call ... failed (error [-22])". The hotplug rounds below test it too.
Known gap: core-2's FENCE.I sweep fix (icsweep 379ca1ef, tg_fetch) is not in this image. In simulation the four-hart
litmus aborts on its fence.i batches. Watch for programs that write code and run it (JITs, the dynamic loader's
first calls, gdb breakpoints) failing with SIGILL or SIGSEGV, or an oops after such work, and report them with the
console log.

Only the bitstream and fw_jump.bin change against u100. mtime still counts at 10 MHz and the console's 16550 still
sees its 3.6864 MHz reference, so the device trees, U-Boot and Linux are the same files as u100's.

A release build has no virtio window, no console through the host and no latency injectors: it runs in RISC-V mode
only, as u100 does.

p1:/tanager/ (as sw/d4mode/install.sh puts it):
- tanager.bit.bin: the bitstream;
- fw_jump.bin: OpenSBI 1.9 with patch set tg1, 62349a65...;
- payload.bin: U-Boot d4;
- tanager.dtb: the four-hart RISC-V mode tree for a release build (tanager-kv260-riscv-rel.dtb);
- tanager-h01.dtb: the same for one core's two harts (0 and 1), as a fallback tree;
- riscv.scr and riscv.cmd, as u100's.

Install: as u100's, keeping u100's p1:/tanager/ files aside for the switch back, with the install logged next to
its undo.

Steps:
1. The four-hart tree. Expect "Platform HART Count : 4", "smp: Brought up 1 node, 4 CPUs", nproc 4, siblings 0-1
   and 2-3. If it doesn't boot, try tanager-h01.dtb once, then go back to u100 and send the console log.
2. hart_check.sh (CoreMark on every hart, the atomics test on every pair, memgap's pingpong with -c on each pair).
3. Hotplug: three rounds of hart stop and start (hsm_rounds.sh), then the soak's hotplug rounds with the stress
   running. Expect no "__sbi_rfence_v02_call ... failed" line in dmesg.
4. The stress, then the baseline's set; compare per MHz with u100 and d4r2. memgap: -c 0,2 (two cores) beside
   -c 0,1 (one core), and the two checks queued for this image:
   - the single-thread rows on each CPU: taskset -c N memgap for N = 0 to 3;
   - two memgap processes at once, on CPUs 0 and 2, against one alone, for their wr16m (DDR write streaming from
     two cores, soc.md §8.5).
A break on COM5 or a confirmed reboot takes the board back to Ubuntu, as with u100.
