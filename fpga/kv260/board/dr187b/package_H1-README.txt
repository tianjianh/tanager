dr187b-riscv: DR-187's temporary four-hart bring-up bitstream (soc-2), RISC-V mode only, at 80 MHz. Four harts: two
smt2 cores with two threads each, hart 1 on in both. The product target stays 100 MHz (DR-177); this build gives up
the clock for a first look at Linux on four harts on the board.
Built from 21085fa9 (main a6ff993d with build.tcl's placement option and tg_clkgen's 80 MHz fix) as a release build
(TG_RELEASE=1, DR-180): smt2, two cores, 80 MHz, the PMOD console, the host DMA port, the PS window, the fan's PL
regulator, g4_uncore's floorplan (DR-181), DR-186's slices off, the ACLINT's output registers, place_design AltSpreadLogic_high,
with defines TG_HART1=1 TG_COMMIT_TRACE=0 and the UltraRAM register file (TG_URF=1, DR-174) with clk2x at 160 MHz. M7's step 7 isn't in it.
Timing: WNS=1.076 WHS=0.010; 113168 LUTs placed (96.63%), at the plain 12.5 ns (DR-160's 1.0 ns of place-and-route uncertainty is taken back for the report).

Only the cores' clock changes. mtime still counts at 10 MHz (the ACLINT's accumulator, from the core clock's rate) and
the console's 16550 still sees its 3.6864 MHz reference (emulated from the core clock), so the device trees, OpenSBI,
U-Boot and Linux are the same files as at 100 MHz. CPU-bound figures (boot times, CoreMark, memgap's loops) should come
out at about 0.8 times d4r2's per second, the same per MHz.

A release build has no virtio window, no console through the host and no latency injectors. So stage C under
tanager-host doesn't apply to this bitstream (tanager-host run --pty refuses it). It runs in RISC-V mode, as d4r2 does.

p1:/tanager/ (as sw/d4mode/install.sh puts it):
- tanager.bit.bin: the bitstream;
- fw_jump.bin: OpenSBI, b0094d23..., as the board has run since sc3;
- payload.bin: U-Boot d4;
- tanager.dtb: the four-hart RISC-V mode tree for a release build (tanager-kv260-riscv-rel.dtb, sw/dts board-trees.sh
  2). It has UART1 off the stdout path, SD1, the board's reset and GEM3, and the PLIC's M contexts absent;
- tanager-h01.dtb: the same for one core's two harts (0 and 1). Core 1's harts start too, find themselves outside the
  tree and wait in OpenSBI's WFI loop;
- riscv.scr and riscv.cmd, as d4r2's.

Boot steps: two harts first, then four (the M7 plan: "Linux on the two harts of one core, then on four"):
1. Copy tanager-h01.dtb over tanager.dtb on p1 (keep the four-hart one aside), then `tanager-mode riscv` and reboot.
   OpenSBI should print "Platform HART Count : 2", Linux "smp: Brought up 1 node, 2 CPUs", and nproc should be 2.
2. Put the four-hart tanager.dtb back. Expect "Platform HART Count : 4", "smp: Brought up 1 node, 4 CPUs", nproc 4,
   and harts 0 to 3 in /proc/cpuinfo.
3. Hart stop and start (OpenSBI's HSM): three rounds of echo 0 | sudo tee /sys/devices/system/cpu/cpu{1,2,3}/online,
   then echo 1 into each. /sys/devices/system/cpu/online should return to 0-3 with nothing failed.
4. As for d4r2: the stress, then memgap and the DR-141 set (at 80 MHz: compare per MHz).
A break on COM5 or a confirmed reboot takes the board back to Ubuntu, as with d4r2.
