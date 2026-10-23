u100-riscv: a four-hart preview bitstream at 100 MHz (soc-2 packaging spikes-2's near-final preview build, 10-22),
RISC-V mode only. Four harts: two smt2 cores with two threads each, hart 1 on in both. It is a preview from branches
not all on main yet; the release image is built from main once everything lands. Keep dr187b (80 MHz) as the
fallback.
Built from ca66235f564b: spikes-2's snapshot of main e88f2b98 with DR-183 (PMP checks at TLB fill, on: TG_PMP_FILL=1),
soc-2's registered head MMIO check (6da660ec), core-2's LSU branch and rt_q B (spikes 8.18, 56f36bc4), as a release
build (TG_RELEASE=1, DR-180): smt2, two cores, 100 MHz, the PMOD console, the host DMA port, the PS window, the fan's
PL regulator, g4_uncore's floorplan (DR-181), DR-186's slices off, place_design AltSpreadLogic_high, with defines TG_HART1=1 TG_PMP_FILL=1 TG_COMMIT_TRACE=0 and
the UltraRAM register file (TG_URF=1, DR-174) with clk2x at 200 MHz.
Timing: WNS=0.257 WHS=0.010; 111359 LUTs placed (95.08%), at the plain 10 ns (DR-160's 1.0 ns of place-and-route uncertainty is taken back for the report).

Only the bitstream changes against dr187b. mtime still counts at 10 MHz (the ACLINT's accumulator, from the core
clock's rate) and the console's 16550 still sees its 3.6864 MHz reference (emulated from the core clock), so the
device trees, OpenSBI, U-Boot and Linux are the same files as dr187b's. CPU-bound figures should come out at d4r2's
per second, 1.25 times dr187b's.

New on the board: DR-183's PMP checks at TLB fill. Translated S/U accesses use the TLB's cached result alone, and one
shared checker per core serves M-mode, bare accesses, page-table reads and split pages. It passed in simulation under
lockstep (regress, the directed tests, the Linux boot), but this is its first run on hardware. A wrong result would
show as an access fault on a valid access: a kernel oops or panic naming a load, store or instruction access fault,
OpenSBI trap lines, or user programs dying with SIGSEGV or SIGBUS. Save the console log of every boot.

A release build has no virtio window, no console through the host and no latency injectors. So stage C under
tanager-host doesn't apply to this bitstream (tanager-host run --pty refuses it). It runs in RISC-V mode, as dr187b
does.

p1:/tanager/ (as sw/d4mode/install.sh puts it):
- tanager.bit.bin: the bitstream;
- fw_jump.bin: OpenSBI, b0094d23..., as the board has run since sc3;
- payload.bin: U-Boot d4;
- tanager.dtb: the four-hart RISC-V mode tree for a release build (tanager-kv260-riscv-rel.dtb, sw/dts board-trees.sh
  2). It has UART1 off the stdout path, SD1, the board's reset and GEM3, and the PLIC's M contexts absent;
- tanager-h01.dtb: the same for one core's two harts (0 and 1), as a fallback tree;
- riscv.scr and riscv.cmd, as dr187b's.

Install: as dr187b's, keeping dr187b's p1:/tanager/ files aside for the switch back (and the two-core 100 MHz d4r2
image as it is), with the install logged next to its undo.

Steps:
1. The four-hart tree (tanager.dtb). Expect "Platform HART Count : 4", "smp: Brought up 1 node, 4 CPUs", nproc 4,
   siblings 0-1 and 2-3, and no access faults in the log. If it doesn't boot, try tanager-h01.dtb once, then go back
   to dr187b and send the console log.
2. hart_check.sh (CoreMark on every hart, the atomics test on every pair, memgap's pingpong with -c on each pair).
3. Three rounds of hart stop and start, as for dr187b.
4. The stress, then the baseline's set; compare per MHz with dr187b and d4r2. memgap: run -c 0,2 (two cores) beside
   -c 0,1 (one core).
A break on COM5 or a confirmed reboot takes the board back to Ubuntu, as with dr187b.
