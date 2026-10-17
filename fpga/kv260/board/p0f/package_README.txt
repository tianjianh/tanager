p0f: the two-core platform bitstream with the smt2 register-corruption fix (DR-147, DR-150 P0).

Tree aae33dcaa7cc = soc-2 038b30b (main 537f23b with core-2's a0631fb, + soc-2's branch) + core-2's 24ada50:
- 24ada50: tg_rename's rn_fire was used before its declaration, inside the free lists' generate blocks, so
  synthesis made it an implicit one-bit net per block (Vivado Synth 8-11241/8-605, reported only as INFO and
  WARNING) while Verilator found the later declaration. In hardware the free lists popped on the wrong
  condition and handed out live registers: the corruption p0's and c1s's traces show from OpenSBI's first
  instructions (add s1,a1 read t1's value; s0 and s2 read -1), and the lottery amoswap never issued.
- 038b30b: tg_uncore's dbg_sel/dbg_val had the same flaw (the debug counters' select and value); fixed, and
  build.tcl now fails any build whose synthesis reports an implicit net in our RTL. This build passed that check.
Build: kv260_top, smt2, 2 cores (one thread each: harts 0 and 2), 70 MHz, the commit trace on, TG_DEBUG_CNT=1,
AreaOptimized_high synthesis, PMOD console (H12/B10, 115200 8N1), fan per DR-129.
Timing at 70 MHz: WNS +1.869 ns, WHS +0.010 ns (routed; summary.txt).

Images: fw_jump.bin (OpenSBI), Image (Buildroot tanager_lp64d), as before.
Device trees (harts 0 and 2):
- tanager-kv260.dtb: 1 GiB (the same as p0's);
- tanager-kv260-768m.dtb: 768 MiB, for board lockstep;
- tanager-kv260-bench.dtb: 1 GiB, OpenSBI's riscv,pmu map, bootargs "console=ttyS0,115200 earlycon tanager.bench=1".
tanager-host: the soc track's newest (dbg, vq, dma).

Run:
  sudo cp tanager.bit.bin tanager.dtbo shell.json /lib/firmware/xilinx/tanager/
  sudo xmutil unloadapp && sudo xmutil loadapp tanager
  sudo ./tanager-host boot --fw fw_jump.bin --kernel Image --dtb tanager-kv260.dtb
Expected: "Platform HART Count : 2", "smp: Brought up 1 node, 2 CPUs", TANAGER-BOOT-OK. Then board lockstep
(768m, --lossless --trace, zeroed window) and the bench set (bench DTB, dr141-linux's bench Image).
If it hangs: `sudo ./tanager-host dbg` twice and a trace; p0fd (the same plus core-2's debug word) follows.
Simulation (where rn_fire always behaved) boots two smt2 cores of this design to "smp: Brought up 1 node, 2 CPUs" (31.4M cycles).
