# Tanager on the KV260: build and bring-up

Owner: SoC track. Design: [docs/spec/soc.md](../../docs/spec/soc.md), host interface: [docs/spec/host.md](../../docs/spec/host.md).

## Build the bitstream

Vivado runs only through `tools/vivado_run.sh` (conventions §9). From the repository root, after `source tools/env.sh && source sw/env.sh`:

```bash
TANAGER_VIVADO_MEM_GB=20 bash tools/vivado_run.sh $SOC_BUILD/vivado/st_trafgen_100 fpga/kv260/tcl/build.tcl $PWD st trafgen 100 2 bit
```

A full build declares 20 GB, about 1.2 × its measured peak (16.6 GB for the two-core traffic-generator build, IP generation's child processes included; `~/tanager-build/.locks/vivado_peaks.log`). `vivado_run.sh` admits jobs within the host's declared-memory budget. Out-of-context unit runs (`tcl/ooc_synth.tcl`) peak at 3.1–3.4 GB and declare 4.

### PMOD console (RISC-V UART on the PMOD connector)

`TG_PMOD_UART=1` in the build environment puts the RISC-V console on the KV260's PMOD connector (DR-126):

```bash
TG_PMOD_UART=1 TANAGER_VIVADO_MEM_GB=20 bash tools/vivado_run.sh $SOC_BUILD/vivado/st_core_100_pmod fpga/kv260/tcl/build.tcl $PWD st core 100 1 bit
```

- **Line:** 8N1, 3.3 V, at the 16550's divisor (115 200 baud once OpenSBI has programmed it, also the reset value). Set the terminal on the laptop to 115200 8N1, no flow control.
- **Pins:**

  | Port | Direction (FPGA) | Default pin | Connects to the module's |
  |---|---|---|---|
  | `pmod_uart_txd` | out | E10 (PMOD J2 pin 2) | RXD |
  | `pmod_uart_rxd` | in, pulled up | D10 (PMOD J2 pin 3) | TXD |

  - **Unconfirmed:** the J2 pin locations are the SOM240 3.3 V pins as the KV260 carrier's PMOD is generally documented; the local board files don't name the connector. Confirm them against the carrier's documentation and the module's pinout before connecting. Ground is J2 pin 5 or 11.
  - `TG_PMOD_TXD` and `TG_PMOD_RXD` override the pins without editing a file.
- **With the option off** (the default), `pmod_uart_txd` is high-impedance and nothing drives the connector.
- **Host copy:** with the option on, the host bridge still receives a copy of every character, so `tanager-host`'s console shows the output too. Input from either side reaches the RISC-V.

Arguments: configuration (`st`, `smt2`, `st_w3`, `smt2_w3`), core kind, core clock in MHz, number of cores, and the stage to stop at (`synth`, `impl` or `bit`).
- `core` builds the real `tg_core`. A bitstream with it waits for the core track's area work (the coordinator's call).
- `trafgen` puts traffic generators in the cores' place, for bring-up and uncore timing ([soc.md](../../docs/spec/soc.md) §2.3).

| Output (in the run directory) | Use |
|---|---|
| `tanager.bit.bin` | the bitstream for the Linux FPGA manager |
| `reports/summary.txt` | WNS/WHS and run time |
| `reports/timing_summary.rpt`, `utilization*.rpt`, `primitives.rpt`, `cdc.rpt`, `drc.rpt` | detail |

Checkpoints are not written. Delete the run directory once the reports are recorded.

The device-tree overlay that goes with the bitstream:

```bash
dtc -@ -W no-reg_format -W no-simple_bus_reg -I dts -O dtb -o tanager.dtbo fpga/kv260/dtbo/tanager.dtso
```

`tanager-host` for the A53 (static aarch64, musl):

```bash
make -C sw/host
```

## Board setup (one-time; needs a person)

1. **OS.** Write the standard Kria Ubuntu image (22.04 or 24.04 for Kria) to the SD card. Boot the KV260 and put it on the network. Install an SSH public key for the user that will run the tests. The user needs `sudo`.
2. **Carve-out for the RISC-V DRAM.** A53 Linux must not use the top 1 GiB of the high DDR bank (`0x8_4000_0000`–`0x8_7FFF_FFFF`), which is `tanager-host`'s default window. Add `mem=3G` to the kernel command line. The kernel then keeps the low 2 GiB and the first 1 GiB of the high bank.
   - **Ubuntu for Kria:** set `LINUX_KERNEL_CMDLINE` in `/etc/default/flash-kernel`, run `sudo flash-kernel`, reboot.
   - **Check:** `free -g` shows about 3 GiB; `grep System /proc/iomem` ends below `0x840000000`.
3. **SMMU bypass for the PL masters.** The HP ports pass through the SMMU. If Linux's SMMU driver rejects unknown stream IDs, the RISC-V memory accesses fault. Add `arm-smmu.disable_bypass=0` to the same command line. Spike S1 is to confirm whether this is needed (plan §5.5).
4. **Firmware files.** Copy `tanager.bit.bin` and `tanager.dtbo` to `/lib/firmware/` on the board. Copy `tanager-host` to `/usr/local/bin/`.
5. **Unload any accelerator** the Kria image loaded at boot: `sudo xmutil unloadapp`.

## Bring-up sequence

Each step's expected result is in brackets.

1. **Load the bitstream.** `sudo fpgautil -b tanager.bit.bin -o tanager.dtbo` [`fpgautil` reports success; `dmesg` shows the FPGA manager loading and the overlay applied].
2. **Host window.** `sudo tanager-host info` [ID `TNGR`, configuration, 100.0 MHz, cores and uncore in reset].
3. **Fabric widths and clock.** `sudo tanager-host poke 0x68 0x12345678; sudo tanager-host peek 0x68` [reads back `0x12345678`; a garbled value means the AXI width (overlay `afi0`) is wrong].
4. **Memory path, without a core** (traffic-generator bitstream): `sudo tanager-host tg start 16384`, wait a few seconds, `sudo tanager-host tg status` [passes counting up, errors 0]. Then `sudo tanager-host info` [injector reads > 0, native latency avg and max: the spike S1 number seen from the SoC].
   - **At 250 cycles:** `sudo tanager-host inj --inj-rd 250`, wait, `tg status` again [errors still 0].
5. **Console path.** The traffic generators print one `.` per pass on the UART: `sudo tanager-host run --timeout 5` [dots appear].
6. **Linux** (once the core exists, with F/D from M3; the lp64d image):
   ```bash
   sudo tanager-host boot --fw fw_jump.bin --kernel Image --dtb tanager-kv260.dtb
   ```
   [OpenSBI banner, Linux boot, `TANAGER-BOOT-OK`; Ctrl-A x leaves].
7. **Commit trace** (FPGA lockstep, docs/spec/uncore-trace.md): add `--trace FILE` to `run` or `boot`. Every commit record (64 bytes) goes to `FILE` while the run goes, and the cores slow to the stream's and the reader's pace. [`trace: N records written`, no AXI error].
   - **Ring placement:** the ring takes the top `64 B << --trace-log2` of the carve-out (default 256 MiB), and the RISC-V memory window shrinks by that much. Build the device tree for traced runs with `make -C sw/dts MEM=0x30000000` (768 MiB).
   - **Post-mortem:** `--trace-wrap --trace-stop PC --trace-post N` keeps the last records up to N after the first commit at `PC`, written to `FILE` at exit.
   - **Starting late:** `--trace-start PC` lets the run reach `PC` at full speed and traces from there.
   - **Status:** `sudo tanager-host trace status`.

## Pins and clocks

| Signal | Where | Notes |
|---|---|---|
| `fan_en_b` | A12 (`som240_1_c24`), LVCMOS33 | driven low: fan at full speed |
| `pl_clk0` | PS | 100 MHz (set by the overlay) → MMCM → `clk_core` (`CORE_MHZ`), `clk_host` (100 MHz) |
| `pl_ps_irq0[0]` | PS, GIC SPI 89 | host bridge interrupt (console, mailbox, power, tohost) |
