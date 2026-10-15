# Host interface (`tg_host_bridge`, `tg_hostctl`) and `tanager-host`

Status: draft — soc track — 2026-10-13

## Purpose

The A53 cluster runs Linux and acts as host (plan D2, §7.2):
- it loads images into the carve-out;
- it holds and releases the RISC-V reset;
- it bridges the console to a pty;
- it sets the latency injector;
- later, it streams the commit trace and serves virtio.

The PL side of that is the **host bridge**:
- a 32-bit AXI4-Lite slave on `clk_host`, reached from `M_AXI_HPM0_FPD`;
- **host control** (`tg_hostctl`), the RISC-V-visible register block at `HOSTCTL_BASE` (`0x1000_1000`) on `clk`;
- the clock-domain crossings between the two. This is the SoC's only crossing (interfaces.md §6).

## Interface

| Port | Domain | Contents |
|---|---|---|
| AXI4-Lite slave | `clk_host` | 32-bit data, 16-bit byte address (64 KiB window); `kv260_top` converts the PS's AXI4 with `tg_axi4_to_axil` |
| `host_irq_o` | `clk_host` | level to `pl_ps_irq0`: any enabled host interrupt source |
| device-bus port | `clk` | `tg_hostctl`, through `tg_tl_dev` |
| control outputs | `clk` | `core_rst_o`, `uncore_rst_o`, the DRAM window, boot entry, DTB address, injector configuration |
| status inputs | `clk` | L2 init done, injector statistics |
| UART streams | `clk` | TX bytes from `tg_uart`, RX bytes to it |
| `mbox_irq_o` | `clk` | PLIC source 11 |

## Host register map (A53 view, byte offsets in the HPM0 window)

| Offset | Name | Access | Reset | Meaning |
|---|---|---|---|---|
| `0x000` | `ID` | RO | `0x5447_4E52` | "TNGR" |
| `0x004` | `VERSION` | RO | | `[31:24]` major, `[23:16]` minor, `[15:12]` cores, `[11:8]` threads per core, `[7:0]` configuration (0 st, 1 smt2, 2 st_w3, 3 smt2_w3) |
| `0x008` | `CLK_HZ` | RO | | `clk_core` frequency |
| `0x00C` | `CAPS` | RO | | `[0]` L2, `[1]` latency injector, `[3]` commit-trace streaming, `[7:4]` memory ports |
| `0x010` | `CTRL` | RW | `0x3` (FPGA) | `[0]` hold cores in reset; `[1]` hold the uncore (L2, interconnect, devices, injector) in reset; `[2]` console lossless (0: TX bytes are dropped while the host FIFO is full, so the console never stalls the RISC-V side) |
| `0x014` | `STATUS` | RO | | `[0]` cores in reset; `[1]` uncore in reset; `[2]` L2 initialised; `[3]` power request pending |
| `0x018` | `POWER` | RO, W1C | 0 | `[31]` request pending; `[15:0]` value the RISC-V side wrote (`0x5555` power-off, `0x7777` reboot, `0x3333 \| code << 16` failure). A write with bit 31 set clears it |
| `0x020`/`0x024` | `DRAM_BASE` lo/hi | RW | 0 | carve-out start in PS address space |
| `0x028`/`0x02C` | `DRAM_SIZE` lo/hi | RW | 0 | carve-out bytes, a multiple of 64; 0 denies all RISC-V memory accesses |
| `0x030`/`0x034` | `BOOT_ENTRY` lo/hi | RW | `0x8000_0000` | where the boot ROM jumps |
| `0x038`/`0x03C` | `DTB_ADDR` lo/hi | RW | `0x8220_0000` | `a1` at entry |
| `0x040` | `INJ_RD_DELAY` | RW | 0 | injector read delay, cycles (0 … 1023) |
| `0x044` | `INJ_WR_DELAY` | RW | 0 | write-response delay |
| `0x048` | `INJ_CTRL` | RW | 0 | `[0]` mode (0 from issue, 1 additive); `[24:16]` bandwidth rate (0 = no cap) |
| `0x050` | `INJ_RD_COUNT` | RO | | reads completed, both ports (for the native-latency average) |
| `0x054` | `INJ_RD_LATSUM` | RO | | sum of native read latencies, cycles (low 32 bits) |
| `0x058` | `INJ_RD_LATMAX` | RO | | maximum native read latency |
| `0x060`/`0x064` | `TOHOST` lo/hi | RO | 0 | last value the RISC-V side wrote (bare-metal test status) |
| `0x068`/`0x06C` | `FROMHOST` lo/hi | RW | 0 | value the RISC-V side reads |
| `0x070` | `MBOX_IN` | RO, W1C | 0 | `[0]` RISC-V rang the host doorbell |
| `0x074` | `MBOX_OUT` | WO | | write 1: ring the RISC-V doorbell (PLIC source 11) |
| `0x080` | `IRQ_STATUS` | RO | | `[0]` console bytes waiting, `[1]` `MBOX_IN`, `[2]` power request, `[3]` `TOHOST` written |
| `0x084` | `IRQ_ENABLE` | RW | 0 | mask for `host_irq_o` |
| `0x088` | `TOHOST_SEQ` | RO | 0 | count of `TOHOST` writes (wraps) |
| `0x0C0` | `TG_CTRL` | RW | 0 | `[0]` run the traffic generators (bring-up builds, [soc.md](soc.md) §2.3) |
| `0x0C4` | `TG_BASE` | RW | `0x200_0000` | first line of the test region (physical address ÷ 64); core c uses the c-th region of `TG_LINES` lines |
| `0x0C8` | `TG_LINES` | RW | 16384 | lines per generator (1 MiB, twice the L2) |
| `0x0D0` | `TG_OPS` | RO | | lines checked, all generators |
| `0x0D4` | `TG_ERRS` | RO | | mismatches, all generators |
| `0x0D8` | `TG_ERR_LINE` | RO | | line of the most recent mismatch |
| `0x0DC` | `TG_PASS` | RO | | completed passes of generator 0 |
| `0x100` | `UART_TX` | RO | | pop one console byte: `[8]` valid, `[7:0]` byte |
| `0x104` | `UART_TX_LEVEL` | RO | | bytes waiting (FIFO of 2048) |
| `0x108` | `UART_RX` | WO | | push one byte to the console input |
| `0x10C` | `UART_RX_SPACE` | RO | | free entries (FIFO of 512) |
| `0x1000`–`0x1048` | `TRS_*` | | | commit-trace streaming into a DDR ring: control, triggers, ring base and size, read and write pointers, status ([uncore-trace.md](uncore-trace.md) §Host registers) |

A 64-bit pair is written low half first. The low half waits in a shadow register shared by all pairs and lands with the high half's write, so reading it back before then returns the old value. The bridge transfers configuration to `clk` after each write to the high half, or to any 32-bit-only register.

## RISC-V register map (`tg_hostctl`, offsets from `0x1000_1000`)

| Offset | Name | Access | Meaning |
|---|---|---|---|
| `0x000` | `ID` | RO | `0x4C54_4348_5254_4E47` ("TNGRHCTL") |
| `0x008` | `BOOT_ENTRY` | RO | from the host |
| `0x010` | `DTB_ADDR` | RO | from the host |
| `0x020` | `POWER` | WO | the device tree's `syscon-poweroff` / `syscon-reboot` register (values as `POWER` above); OpenSBI's SRST and Linux reach it |
| `0x028` | `TOHOST` | RW | 64-bit; a write is reported to the host |
| `0x030` | `FROMHOST` | RO | 64-bit, from the host |
| `0x038` | `DOORBELL` | WO | any write rings the host (`MBOX_IN`) |
| `0x040` | `MBOX_PENDING` | RO, W1C | `[0]` the host rang (drives PLIC source 11); write 1 to clear |

## Commit trace

`tg_trace_stream` (core domain) writes every core's commit records, with none lost, into a ring in DDR over its own PS port. It stalls the cores through `trace_stall_i` when it falls behind ([uncore-trace.md](uncore-trace.md)). The host reads the records directly from DDR; the `TRS_*` registers control it.
- **Record format** (64 bytes in DDR; bytes 0–39 are the 320-bit record): `[31:0]` header, `[63:32]` insn, `[127:64]` pc, `[191:128]` value (rd value; the cause for traps and interrupts; the value of a writeback), `[255:192]` address (store vaddr; tval for traps), `[319:256]` store data, `[351:320]` the low 32 bits of the core-clock cycle count at capture, `[511:352]` zero.
  - **Header fields:** `[1:0]` kind (0 retire, 1 trap, 2 interrupt, 3 deferred writeback), `[3:2]` hart, `[5:4]` priv, `[6]` rvc, `[7]` rd_we, `[8]` rd_fp, `[13:9]` rd, `[14]` rd_deferred, `[19:15]` wb_tag, `[20]` mem_st, `[22:21]` mem_size, `[23]` mmio_ld, `[24]` nondet.

## Behaviour

- **Resets.** `CTRL[1]` (uncore) and `CTRL[0]` (cores) are synchronised into `clk` (`xpm_cdc_sync_rst`, or a 3-flop synchroniser in simulation) and ORed with the SoC reset. The cores' reset is also asserted whenever the uncore's is. On the FPGA both reset to 1. The simulation top sets the reset values by parameter, so a testbench can run without a host.
- **Configuration crossing.** All host-written configuration (DRAM window, boot entry, DTB, injector, `FROMHOST`, `CTRL[2]`) is one vector, copied to `clk` by `xpm_cdc_handshake` after each update. It is quasi-static by contract: the DRAM window is changed only while the uncore is in reset.
- **Status crossing.** Statistics, `TOHOST`, the power request and the init flag cross back the same way, continuously.
- **Streams.** Console bytes cross in asynchronous FIFOs (`xpm_fifo_async`: 2048 bytes RISC-V → host, 512 host → RISC-V). Doorbells and power requests cross as pulses (`xpm_cdc_pulse`).
- **Simulation equivalents.** The `xpm_*` primitives are used under `SYNTHESIS`. The simulation models (`rtl/uncore/lib/tg_cdc_*`) have the same ports and conservative latencies.

### Loading sequence (what `tanager-host` does)
1. Write `CTRL = 0x3`: hold cores and uncore in reset. The L2 forgets everything without writing back.
2. Set `DRAM_BASE` and `DRAM_SIZE`. Copy the images into the carve-out through an uncached mapping:
   - `fw_jump.bin` at `+0`;
   - `Image` at `+0x20_0000`;
   - the DTB at `+0x220_0000` ([soc.md](soc.md) §3).
3. Set `BOOT_ENTRY`, `DTB_ADDR` and the injector. Write `CTRL = 0x1`: release the uncore. Poll `STATUS[2]` (L2 initialised).
4. Write `CTRL = 0x0`: release the cores. Bridge the console: pop `UART_TX` to the pty, push pty input to `UART_RX`. Watch `POWER` and `TOHOST`.

Hold the cores alone (`CTRL = 0x1`) only while they are quiet, as between steps 3 and 4. The uncore does not drain a core's TileLink transactions when its reset rises, so a core held in the middle of one leaves the L2 waiting for a `GrantAck` or for the rest of a `ReleaseData` burst. To stop a running system, hold both (`CTRL = 0x3`).

## `tanager-host` (A53 program)

`sw/host/`: a single static aarch64 binary (C, built with GCC 15 from an external toolchain, sw/versions.sh). It runs as root on the KV260's Linux.

| Command | Action |
|---|---|
| `tanager-host info` | print `ID`, `VERSION`, `CLK_HZ`, `CAPS`, `STATUS` |
| `tanager-host load --fw F --kernel K --dtb D [--base A --size S] [--zero]` | steps 1–3 of the loading sequence. `--zero`, implied by `--trace`, first zeroes the RISC-V window (not the trace ring above it), so a lockstep checker whose memory starts at zero sees the same bytes |
| `tanager-host run [--console] [--timeout T] [--inj-rd N --inj-wr N --inj-mode M --inj-bw R]` | step 4: release reset, bridge the console to a pty (or stdio), exit on a power request or `TOHOST`, with its value, and hold everything (`CTRL = 0x3`). Before it holds everything, it drains the console until the UART has been quiet for 20 ms, or for 0.5 s at most, so the RISC-V's last line is not cut off. A system that already runs (after `tg start`) keeps running; `run` only attaches the console |
| `tanager-host boot …` | load, then run |
| `tanager-host reset` | hold cores and uncore in reset |
| `tanager-host inj [--rd N] [--wr N] [--mode M] [--bw R] [--stats]` | change or read the injector |
| `tanager-host tg start [LINES] [--base A --size S]` | traffic-generator bitstreams ([soc.md](soc.md) §2.3): steps 1–3 without images (hold everything, set the window, release the uncore, wait for the L2), then `TG_LINES`, `TG_CTRL = 1`, `CTRL = 0x0` |
| `tanager-host tg stop`, `tg status` | stop the generators; print passes, operations, errors and the first failing line |
| `tanager-host peek/poke <off> [val]` | raw register access (bring-up) |

- **Access paths:**
  - **Registers:** `mmap` of `/dev/mem` at the HPM0 window (default `0xA000_0000`, option `--regs`).
  - **Guard:** before it maps the window, `tanager-host` checks that the overlay's node (`/axi/tanager@a0000000` for the default window) is in the live device tree, which holds only while the Tanager bitstream is loaded. A PL read that nothing answers hangs the ARM until a power cycle; the board session hung the board this way on 2026-10-14. `--force` skips the check.
  - **Options** may come before or after the command.
  - **`--trace -`** (FPGA lockstep: `tanager-host boot ... --lossless --trace - | tanager-lockstep ...`, the verification track's checker): stdout carries only the 64-byte records; the console and every message go to stderr or the pty. Each poll copies at most 4,096 records, so the console, `POWER` and `TOHOST` stay serviced while the reader lags; a reader that falls behind fills the pipe, `TRS_RP` stops advancing and the cores stall (lossless). If the reader exits, the write fails (SIGPIPE is ignored), and `run` ends as for a power-off: it drains the console, holds everything and exits 4, "trace consumer stopped".
  - **Carve-out:** `/dev/mem` with `O_SYNC`. The carve-out is reserved from A53 Linux by the board's boot setup ([soc.md](soc.md) §7).
- **Bitstream:** loaded beforehand as the PL app `tanager` with `xmutil` ([soc.md](soc.md) §7, `fpga/kv260/README.md`).
- **M4 additions:** trace streaming to the lockstep checker, and the latency sweep commands.

## Parameters

| Parameter | Meaning |
|---|---|
| `CORE_RST_INIT`, `UNCORE_RST_INIT` | `CTRL` reset values (FPGA 1/1; simulation 0/0) |
| `CLK_HZ` | reported in `CLK_HZ` |
| FIFO depths | console 2048 / 512 |

## Timing and area

- The AXI4-Lite side runs at 100 MHz with registered decode.
- **Crossings:** about 400 flip-flops of handshake registers; 1 BRAM18 per console FIFO, or LUTRAM.
- **Total:** about 1K LUTs.

## Verification

- **`tests/unit/host_bridge`:** AXI4-Lite accesses from a testbench on an unrelated `clk_host` (different frequency and phase):
  - register reset values and read/write;
  - the configuration and status crossings (values arrive intact, with no torn multi-bit updates);
  - reset sequencing;
  - console bytes in both directions under back-pressure, and drop mode;
  - doorbells, `TOHOST` and power requests, interrupt status and masking.
- **SoC simulation:** a testbench drives the host port the way `tanager-host` does ([soc.md](soc.md)).
- **On the board:** `tanager-host info`, `peek`/`poke` and a console loopback are the first bring-up checks.

## History and lessons

- **Estimate:** about 1K LUTs.
- **First measurement:** 1,222 LUTs and 3,023 FFs of crossing registers (first traffic-generator build). Inside the uncore budget unit it was 3,335 LUTs and 5,971 FFs at smt2. Most of that was the trace ring's 320-bit record readback, the read multiplexer over it, and the status crossing (about 2.7K of the FFs).
- **Trace streaming** moved the records to DDR, which the host reads directly. The `TRACE_*` registers became the `TRS_*` control registers, and the host bridge fell to 1,667 LUTs.
- **Lessons:**
  - **Wide data has no place on the AXI4-Lite side.** Records or buffers read through 32-bit registers cost LUTs and crossing flip-flops for every bit. A shared-memory ring that the A53 reads costs neither.
  - **Every multi-bit value crosses through one handshake mirror** (XPM), so the CDC report has no unsafe endpoints. The crossing count grew from 525 to 629 safe endpoints with the `TRS_*` registers.

## Provenance

- AXI4-Lite per ARM IHI 0022.
- The crossings use AMD's XPM CDC macros (UG974), which are allowed vendor primitives (plan §2.3).
- The power-request values follow QEMU's documented `sifive,test0` finisher device, so the two device trees can share them ([soc.md](soc.md) §6).
- No other core's or SoC's RTL was read for this unit.
