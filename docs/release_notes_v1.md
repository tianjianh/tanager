# Tanager v1 release notes (draft)

*Draft for M9 (DR-190; [m9-plan.md](spec/m9-plan.md) §9), written on 2026-10-24.*
- **No v1 image exists yet.** v1 is a new build from main after M9.
- **Today's values** come from rc3u095r, the M8 release image of record ([fpga/kv260/board/rc3/](../fpga/kv260/board/rc3/README.md); [firmware_switches.md](spec/firmware_switches.md)), unless a row says otherwise.
- **TBD-v1** marks every figure the v1 image will change, with today's value beside it.
- **Sources:** each figure names where it was measured.

## What v1 is

- **The core:** a clean-room, 2-wide-decode, out-of-order RV64GC core with two hardware threads (SMT2) ([architecture_plan.md](architecture_plan.md); [provenance.md](provenance.md)).
- **The chip:** two cores, four harts, on the AMD Kria KV260 (XCK26) at 100 MHz (DR-152, DR-188).
- **The software:** Debian 13, on Debian's own riscv64 kernel package (6.12, unmodified; DR-147), booted by OpenSBI 1.9 with patch set tg1 and U-Boot 2026.07 ([firmware_switches.md](spec/firmware_switches.md)).
- **A release build** (DR-177, DR-180): `TG_RELEASE=1`. That sets no latency injectors, no virtio window and no commit trace, a PLIC with S-mode contexts only, and no host console. The four-hart product adds `TG_URF=1` and `TG_HART1=1` ([fpga/kv260/README.md](../fpga/kv260/README.md)).
- **The chip's fill and timing:** TBD-v1. Today, rc3: 112,806 LUTs (96.32% of the XCK26), WNS +0.748 ns, WHS +0.006 ns at 100 MHz ([rc3/README.md](../fpga/kv260/board/rc3/README.md); [spikes.md](perf/spikes.md)).

**What M9 adds before v1** ([m9-plan.md](spec/m9-plan.md), DR-190, DR-191), each of which changes the TBD-v1 figures below:
- the hardening that costs no LUTs. The trigger CSRs already take the specification's no-trigger form on main (b512ef98), so OpenSBI stops reporting `sdtrig` and `dbtr`;
- DR-191's structural fixes for the timing paths at 96% fill;
- Sscofpmf with four counters a hart, so `perf record` works (on main since 889c3b11, off by default: `TG_HPM`);
- a 256-entry indirect-target predictor ([area_recovery.md](perf/area_recovery.md) §7.11–§7.12);
- a 16-entry load-wait table (DR-190's addendum);
- a debug module for OpenOCD and GDB, in development builds only.

Also on main and off by default: the L2's write-back batching (`TG_L2_WB_PACE`). Its board sweep comes after M8's 72-hour stress ([firmware_switches.md](spec/firmware_switches.md)).

## The ISA

As the board's device tree lists it (`sw/dts/tanager.dtsi`, lines 62–94; the release tree `tanager-kv260-riscv-rel.dtb`, shipped as `tanager.dtb`):

| Property | Value |
|---|---|
| `riscv,isa` | **TBD-v1.** Today `"rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond_sstc"` |
| `riscv,isa-base` | `"rv64i"` |
| `riscv,isa-extensions` | **TBD-v1.** Today `"i", "m", "a", "f", "d", "c", "zicsr", "zifencei", "zba", "zbb", "zbs", "zicond", "sstc"` |
| `mmu-type` | `"riscv,sv39"` |
| `timebase-frequency` | 10,000,000 (10 MHz, exact for any core clock of 10 MHz or more) |
| CPUs | `compatible = "tanager,tanager", "riscv"`; four harts, two per core (`cpu-map`); a `riscv,cpu-intc` per hart |

- **Privilege modes:** M, S and U, with 8 PMP entries a hart ([core-priv.md](spec/core-priv.md)).
- **SBI:** 3.0, through OpenSBI 1.9 (`time`, `rfnc`, `ipi`, `base`, `hsm`, `srst`, `pmu`, `dbcn`, `fwft`, `legacy`, `sse`; rc3 also lists `dbtr`, which main has dropped) ([firmware_switches.md](spec/firmware_switches.md)).
- **What the board reports** (rc3, [uart_COM5_boot1.txt](../fpga/kv260/board/rc3/uart_COM5_boot1.txt)):
  - OpenSBI: `Boot HART Base ISA : rv64imafdcb`, extensions `sstc,zicntr,sdtrig,f,d`;
  - Linux: `riscv: base ISA extensions acdfim`;
  - Debian's `/proc/cpuinfo` (d4r2, the same tree family): `rv64imafdc_zicntr_zicond_zicsr_zifencei_zca_zcd_zba_zbb_zbs_sstc` ([hartcheck_d4r2_100.txt](../fpga/kv260/board/d4r2/hartcheck_d4r2_100.txt)).
- **Why the strings are TBD-v1:**
  - M9 §10 checks `zicntr`, `zihpm`, `za64rs`, `svinval`, `zkt` and `zihintpause` against the RTL, and lists what holds. `zicntr`, `zihpm` (zero counters are allowed) and `za64rs` look free; `svinval` waits for a measurement; `zkt` needs an audit. The worksheet: [m9-isa-check.md](spec/m9-isa-check.md).
  - `sscofpmf` joins, with a `riscv,pmu` node, if v1 builds `TG_HPM` ([m9-plan.md](spec/m9-plan.md) §1, §10).
- **Not met:** v1 does not meet RVA22S64 or RVA23S64 (DR-190).

## The devices

The release tree's nodes (`sw/dts/tanager.dtsi`, `sw/dts/tanager-kv260.dts`; `sw/dts/board-trees.sh`'s `riscv-rel` set):

| Device | `compatible` | Address | PLIC source | Notes |
|---|---|---|---|---|
| Memory | `memory@80000000` | 0x8000_0000, 1 GiB | — | The board's DDR, through two AXI masters on HP1 and HP2 into the carve-out at 0x8_4000_0000 ([soc.md](spec/soc.md)) |
| Shared L2 | (not in the tree) | — | — | 1 MiB of UltraRAM, two banks, coherent across the four harts ([l2.md](spec/l2.md)) |
| ACLINT (MSWI and MTIMER) | `riscv,clint0` | 0x0200_0000 | — | Software and timer interrupts per hart; `mtime` at 10 MHz ([uncore-periph.md](spec/uncore-periph.md)) |
| PLIC | `riscv,plic0`, `riscv,ndev = <31>` | 0x0C00_0000 | — | S-mode contexts only in a release build; priorities are 1 bit wide |
| Console UART | `ns16550a` | 0x1000_0000 | 10 | On the PMOD connector at 115200 baud; `clock-frequency = <3686400>`, emulated from the core clock |
| Host-control block | `tanager,hostctl`, `syscon` | 0x1000_1000 | 11 | Boot parameters, the mailbox, power requests ([host.md](spec/host.md)) |
| PS UART1 | `xlnx,zynqmp-uart`, `cdns,uart-r1p12` | 0xFF01_0000 | 20 | The board's USB serial port |
| SD card (PS SD1) | `xlnx,zynqmp-8.9a`, `arasan,sdhci-8.9a` | 0xFF17_0000 | 21 | 4-bit, 50 MHz, 3.3 V (`no-1-8-v`); the driver comes from the `tanager-ps-dkms` package, built from Debian's own `linux-source` (DR-168) |
| Gigabit Ethernet (PS GEM3) | `xlnx,zynqmp-gem`, `cdns,gem` | 0xFF0E_0000 | 22 | RGMII to the board's DP83867 PHY, 1 Gb/s only; Debian's own `macb` driver ([soc-d5-gem3.md](spec/soc-d5-gem3.md)) |
| Reset | `syscon` at 0xFF5E_0000, `syscon-reboot`, `syscon-poweroff` | 0xFF5E_0218 | — | The board's reset; the KV260 cannot power itself off, so power-off resets it |

How the board runs them (RISC-V mode, DR-172; [soc-d4-modes.md](spec/soc-d4-modes.md)):
- **At power-on:** the A53 loads the bitstream, sets the clocks and the PHY, copies the firmware and the tree, releases the cores, and parks.
- **After that:** the RISC-V drives the PS's controllers itself, through a window that passes only UART1, GEM3, TTC1, SD1, the I/O configuration block (read-only), USB0's controller, and the reset word. The PS's interrupts reach PLIC sources 20–24.
- **DMA:** the PS's DMA masters reach the RISC-V's memory coherently through the L2, so no device may be marked `dma-noncoherent` ([debian-kernel.md](spec/debian-kernel.md)).
- **The fan:** it is the PL's own regulator, 15/255 at or below 35 °C, linear to 255 at 45 °C ([firmware_switches.md](spec/firmware_switches.md)).
- **Recovery:** a break of 2.7–10.7 s on the PMOD console resets the board, for recovery ([soc-d4-modes.md](spec/soc-d4-modes.md)).

## Performance

**On the board.** rc3u095r at 100 MHz, four harts, Debian's `6.12.113+deb13-riscv64` kernel, GCC 15.3 static builds of our own; not submitted to EEMBC. CoreMark/MHz is 10⁶ / cycles per iteration, and DMIPS/MHz is 10⁶ / (cycles per Dhrystone × 1757) ([d4r2/README.md](../fpga/kv260/board/d4r2/README.md)).

| Figure | Value | Where measured |
|---|---|---|
| CoreMark, one hart, flags A (`-O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las`) | **TBD-v1.** Today 451.9 iterations/s = **4.52 CoreMark/MHz** (each hart alone: 450.4–453.9) | rc3: [set_h0123.txt](../fpga/kv260/board/rc3/set_h0123.txt), [hartcheck_h0123.txt](../fpga/kv260/board/rc3/hartcheck_h0123.txt) |
| CoreMark, one hart, flags B (`-O3 -funroll-loops`) | **TBD-v1.** Today 429.8 iterations/s = **4.30 CoreMark/MHz** | rc3: set_h0123.txt |
| CoreMark, a core's two harts together | **TBD-v1.** Not yet measured with CoreMark on the board; sysbench below | — |
| Dhrystone 2.1 (`-O3 -fno-inline`) | **TBD-v1.** Today 204.2 cycles a Dhrystone = **2.79 DMIPS/MHz** | rc3: set_h0123.txt |
| Boot, reset to `/init` | **TBD-v1.** Today 51.9 s (the kernel's clock: 18.11 s) | rc3: [README.md](../fpga/kv260/board/rc3/README.md), [timeline.txt](../fpga/kv260/board/rc3/timeline.txt) |
| Boot, reset to the login prompt | **TBD-v1.** Today 154.2 s | rc3: README.md |
| `systemd-analyze` | **TBD-v1.** Today 51.2 s (kernel) + 67.8 s (userspace) = 1 min 59.0 s | rc3: hartcheck_h0123.txt |
| Two harts on one core (SMT2): sysbench cpu | **TBD-v1.** Today 1.34× one thread; 1.05× on its memory test (dr187b, 80 MHz) | [dr187b/README.md](../fpga/kv260/board/dr187b/README.md) |
| Two cores: sysbench cpu, 2 threads against 1 | **TBD-v1.** Today 94.41 against 47.02 events/s, 2.01× (d4r2, two cores, one hart each) | [d4r2/README.md](../fpga/kv260/board/d4r2/README.md) |
| Four harts: sysbench cpu, 4 threads | **TBD-v1.** Today 126.30 events/s | rc3: hartcheck_h0123.txt; u100: [README.md](../fpga/kv260/board/u100/README.md) |
| DDR writes, two cores against one | **TBD-v1.** Today 331.1 MiB/s, 2.07×; one core's two threads 1.12× | [rc2/README.md](../fpga/kv260/board/rc2/README.md) |
| Cache-line ping-pong | **TBD-v1.** Today 1,218.5–1,223.6 ns within a core and 1,961.5–1,972.1 ns across cores (about 122 and 196 cycles) | rc3: README.md; u100: README.md |
| SD card, read | 14.9 MB/s | [soc-d4-modes.md](spec/soc-d4-modes.md) |
| Ethernet, scp (CPU-bound) | **TBD-v1.** Today 1.77 MB/s in, 2.09 MB/s out | [soc-d5-gem3.md](spec/soc-d5-gem3.md) |

**In RTL simulation** (the release core; [verification.md](spec/verification.md), [area_recovery.md](perf/area_recovery.md)):

| Figure | Value | Where measured |
|---|---|---|
| SMT2 throughput (M7's exit 2): two harts on one core, against one thread with the second off, 42 pairs | **TBD-v1.** Today 1.226 / 1.217 / 1.192× at 30 / 120 / 250 cycles of memory latency (memory pairs 1.248 / 1.214 / 1.177, compute 1.132 / 1.131 / 1.131, mixed 1.305 / 1.313 / 1.271); one thread alone loses +0.06 / +0.05 / +0.03% | verification.md §5 (main 002ea157); DR-189 |
| The Linux boot to `TANAGER-BOOT-OK`, the board's shape (two cores, a hart each, board timing) | **TBD-v1.** Today 163,751,223 cycles | area_recovery.md §7.12 (main c537b113) |
| CoreMark and Dhrystone, timed regions, rv64gc | **TBD-v1.** Today 4.48 (A) and 4.42 (B) CoreMark/MHz, 3.09 DMIPS/MHz (main, 2026-10-20) | [README.md](../README.md); [devlog.md](devlog.md) 10-20 |

**For context, earlier boards:**
- u100 (10-23, the first four-hart image at 100 MHz, DR-188): `/init` at 52.1–52.3 s and the login at 154.4–156.0 s.
- d4r2 (10-21, the first baseline on Debian's own kernel): CoreMark 4.55 (A) and 4.29 (B) per MHz, 2.77 DMIPS/MHz.
- Before M6 (d2, 10-17): 2.77, 2.29 and 1.41 ([d4r1/README.md](../fpga/kv260/board/d4r1/README.md)).

## Known gaps

**Not in v1** (DR-190; [m9-plan.md](spec/m9-plan.md)):
- **USB.** Debian's kernel has no DWC3 driver; `dwc3` comes back to the user's decision when stage D6 starts (DR-168). U-Boot reports no USB controllers.
- **Misaligned loads and stores trap, and the firmware emulates them** (OpenSBI, DR-063). They work, slowly. Hardware misaligned access is a v2 item and the user's decision (m9-plan §4).
- **Hardware performance events:** **TBD-v1.** Today none: OpenSBI reports `MHPM Info : 0`, the `mhpm*` counters read zero, and Linux says sampling is not supported because Sscofpmf is absent. The SBI's firmware counters work. Sscofpmf is on main, off by default (`TG_HPM`, about 870 LUTs a chip), and v1 includes it if M9's plan holds (m9-plan §1).
- **Svpbmt:** the PBMT bits fault (v2).
- **The cache-block extensions:** `cbo.*` is illegal (Zicbom, v2); Zicboz waits for a measurement of the boot's page zeroing (v1.x); Zicbop's hints run as no-ops.
- **Store sets** (after v1); v1 has the 16-entry load-wait table instead.
- **Debug:** no debug module in the release chip (development builds only), and no Sdtrig (v2).
- **virtio-net:** development builds only; the product's network is GEM3.
- **The RVA22S64 and RVA23S64 profiles:** not met.

**Limits of the board and the release build** ([soc.md](spec/soc.md) §2.5; [soc-d5-gem3.md](spec/soc-d5-gem3.md); [soc-d4-modes.md](spec/soc-d4-modes.md)):
- Ethernet runs at 1 Gb/s only.
- The RISC-V has no PS GPIO; the PHY is taken out of reset by `riscv.scr`.
- There is no real power-off: power-off resets the board.
- A release build cannot inject latency, run board lockstep, serve virtio or give a console through the host, or take machine-mode external interrupts.
- The SD card's module is out of tree (DKMS), so the kernel reports a taint.
- The A53's PL temperature channel reads invalid while a Tanager bitstream is loaded.
- Each hart has 8 PMP entries.

**In rc3, fixed or pending on main:**
- rc3 still reports `sdtrig`, one trigger and the SBI `dbtr` extension; the trigger CSRs' no-trigger form is on main (b512ef98).
- rc3 keeps the full-speed DDR write penalty; the L2's write-back batching is on main, off, for its board sweep.
- rc3's page-fault test is 9.2% slower than d4r2's ([cmp_rc3_cycles.md](../fpga/kv260/board/rc3/cmp_rc3_cycles.md)).

**Errata already fixed:**
- **Remote fences during hart hotplug:** upstream OpenSBI 1.9 failed a whole remote fence when one target hart was stopped. Patch set tg1 fixes it; the kept image `fw_jump.bin.b0094d23` is still affected ([fpga/kv260/README.md](../fpga/kv260/README.md)).
- **SD1's lost interrupt** (DR-176): a core race, fixed in d4r2, back in rc2 through the first form of CoRR's fix, and fixed again by b30b57b3, which rc3 has.
- **Same-address load order (CoRR, DR-176's addendum):** a hart's two loads of one address could see another hart's writes in the wrong order, which RVWMO forbids. d4r2, dr187b and u100 lack the fix. rc2's first form replayed device loads (SD1's lost interrupt, above). rc3 has the fix, b30b57b3; the four-hart litmus runs are in [verification.md](spec/verification.md).
- **FENCE.I against I$ refills:** an I$ refill during a FENCE.I's sweep lost its line, so code written and then run could execute stale instructions. That was rc2's known gap ([board/rc2/README.md](../fpga/kv260/board/rc2/README.md)). e407528c fixed it, and rc3 has it.
- **The micro-BTB's target check:** Linux found a micro-BTB bug when M6 first ran on the board (10-18). The target check in c261c1f fixed it; d4s2 and later images have it ([area_recovery.md](perf/area_recovery.md)). It prompted the long-boot lockstep check (DR-173).
- **Two-thread pair hangs (M7 step 7, DR-189):** with both harts of a core busy, some program pairs hung one thread. Step 7's bank rule (002ea157) fixed them. dr187b and u100 predate it; rc3 has it.

**The core, for firmware and OS developers** (v1 as on main; [core-pipeline.md](spec/core-pipeline.md), [core-lsu.md](spec/core-lsu.md), [core-mmu.md](spec/core-mmu.md), [core-priv.md](spec/core-priv.md)):
- **No mitigations for speculative side channels.**
  - Loads run ahead of older stores whose addresses are unknown; the 16-entry load-wait table is off by default.
  - Wrong-path branches train the predictors.
  - Speculative page walks read PTEs without searching the store queue.
  - A load that PMP denies never delivers its data to a register (#13's hold), but its miss may still refill the line. In rc3, which lacks #13, the denied load's dependants could read the value until the trap's flush.
  - A store's ownership prefetch doesn't wait for its PMP check.
- **What a core's two harts share:**
  - the I$;
  - the D$ and its miss entries;
  - both TLBs, whose entries are tagged by thread;
  - the micro-BTB, whose entries are tagged by thread but not by privilege or ASID, and survive a privilege change, a satp write and SFENCE.VMA;
  - TAGE's tables. The thread is folded into address bit 38, so one thread's blocks share entries with the other's at the address with bit 38 flipped, which in Sv39 is the other half of the address space;
  - one page walker and one PMP checker.

  Each hart has its own return-address stack, branch histories, load- and store-queue halves and LR reservation ([threading.md](spec/threading.md)). No control flushes the predictors. `mtgsmt.HART1_OFF` keeps hart 1 asleep (SMT off); the firmware leaves it at 0.
- **PMP:**
  - 8 entries a hart; entries 8–15 read zero.
  - Verdicts are cached in the TLB entries and, for bare S/U accesses, in a 4-entry region cache.
  - A PMP write flushes the writing hart's TLB entries, its walk in flight and the region cache. So the SFENCE.VMA the privileged spec asks for after a PMP write isn't needed here, though portable firmware runs it ([pmp-at-fill.md](spec/pmp-at-fill.md)).
  - Entry 0 comes out of reset allowing everything (NAPOT, RWX), as Spike's model does.
- **No ASIDs:** every SFENCE.VMA and SINVAL.VMA form flushes the hart's whole TLBs, and a satp write flushes them even with an unchanged value.
- **A store the uncore denies after it commits** (a `denied` Grant) can't raise a precise fault: it is dropped and counted.
- **A PTE in a device region** gives an access fault, where Spike would read the device.
- **LR/SC:** one reservation per hart, on its 64-byte line. Any trap or xRET clears it, and so does a store or an atomic's write to that line by the core's other hart.
- **WARL choices:** an MPP of 2 writes as U, medeleg bit 19 (hardware error) is writable but never raised, and a satp write with an unsupported MODE has no effect.
- **Zkt and divides:** divides aren't in Zkt's list. A divide's operand-dependent latency can delay a later instruction on ALU1 by a cycle ([m9-isa-check.md](spec/m9-isa-check.md)).

**Open before v1:**
- M8's 72-hour stress on the release image. It was stopped after 2 h 43 min with 0 failures, and restarts on the user's word ([rc3/README.md](../fpga/kv260/board/rc3/README.md)).
- M9's measurements: the misaligned-access count on the board, the boot's page-zeroing cycles ([m9-plan.md](spec/m9-plan.md), Pending).

## Switch catalogs

| Catalog | What it holds |
|---|---|
| [docs/spec/area_switches.md](spec/area_switches.md) | Every area measure taken to fit the XCK26, with what it saves, its cost, its switch and default, and the way back, as a checklist for a bigger chip; the KV260's platform tunings (the L2's write-back batching) |
| [docs/spec/firmware_switches.md](spec/firmware_switches.md) | Every setting below Debian: OpenSBI and patch set tg1, U-Boot, the device-tree switches, the kernel command line, the boot-mode record and `riscv.cmd`'s register writes, each with its value in the release image |
| [fpga/kv260/README.md](../fpga/kv260/README.md) | `build.tcl`'s `TG_*` variables: the fan, the uncore, release against development builds, the implementation flow's directives, the PMOD console |
| [sw/dts/Makefile](../sw/dts/Makefile), [sw/dts/board-trees.sh](../sw/dts/board-trees.sh) | The device-tree variables (`CORES`, `THREADS`, `RUN_THREADS`, `MEM`, `FPU`, `PMU`, `RELEASE`, `UART1`, `SD1`, `ETH` and the rest) and the board's trees |
| [sim/profile.mk](../sim/profile.mk) | The core's build profile: the timing cuts, `DC_MSHRS`, `SPEC_WAKE`, `STA_BASE`, `STORE_PF`, `PMP_ENTRIES`, `URF`, `SOLO_TID`, `SPLIT`, `HART1`, `PMP_FILL`, and the lint-only forms |
| [Makefile](../Makefile) | The top-level targets and lint variables (`LAT_INJ`, `RELEASE`, `XBAR_SLICE`, `MEM_SLICE`, `SYNTH`) |
| [perfmodel/README.md](../perfmodel/README.md) | The performance model's presets and switches, including the as-built RTL's parameters |
| [docs/spec/soc.md](spec/soc.md) §2.5 | The release and development builds, and the reserve levers |

## Provenance and licences

See [provenance.md](provenance.md).
- **Licences:** the hardware is under the Solderpad Hardware License 2.1 and the software and documentation under the Apache License 2.0, by path ([REUSE.toml](../REUSE.toml)).
- **Firmware:** the release builds OpenSBI (BSD-2-Clause) with one patch and U-Boot (GPL-2.0) configured only.
- **Kernel:** it runs Debian's own kernel unmodified.
