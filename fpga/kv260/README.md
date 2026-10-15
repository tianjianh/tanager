# Tanager on the KV260: build and bring-up

Owner: SoC track. Design: [docs/spec/soc.md](../../docs/spec/soc.md), host interface: [docs/spec/host.md](../../docs/spec/host.md).

## Build the bitstream

Vivado runs only through `tools/vivado_run.sh` (conventions §9). From the repository root, after `source tools/env.sh && source sw/env.sh`:

```bash
TANAGER_VIVADO_MEM_GB=20 bash tools/vivado_run.sh $SOC_BUILD/vivado/st_trafgen_100 fpga/kv260/tcl/build.tcl $PWD st trafgen 100 2 bit
```

**From a snapshot.** A run that waits for a slot reads the tree only when it starts, so build a commit from a snapshot of it. `summary.txt` records the commit: from `TG_COMMIT`, or from git when the build runs in a checkout.

```bash
S=$SOC_BUILD/snap-build; rm -rf $S; mkdir -p $S; git archive HEAD | tar -x -C $S
TG_COMMIT=$(git rev-parse --short=12 HEAD) TANAGER_VIVADO_MEM_GB=20 bash tools/vivado_run.sh $SOC_BUILD/vivado/st_trafgen_100 $S/fpga/kv260/tcl/build.tcl $S st trafgen 100 2 bit
```

**The fan** (DR-129): every board bitstream leaves the fan to Linux, which regulates it through `fancontrol`: the AMS's temp1 drives pwm1, from 15/255 at 35 °C to 255 at 45 °C. A12 carries the PS TTC waveform Kria's own PL design uses, as read from the running board: TTC0 (`0xFF11_0000`) channel 2, 25 kHz, reaching A12 through EMIO `emio_ttc0_wave_o[2]`. The 25 kHz PWM is inverted in Linux's view; the routing itself is not. The facts live in `tools/tcl/tg_kv260_fan.tcl`, shared with spike S1. `build.tcl` sources it, and the variables override it:

| Variable | Meaning | Default |
|---|---|---|
| `TG_FAN_TTC` | the TTC (0–3) whose waveform outputs go to EMIO | 0 |
| `TG_FAN_WAVE` | which of its three waveform outputs (0–2) drives `fan_en_b` | 2 |
| `TG_FAN_INVERT` | 1 if `fan_en_b` is the waveform inverted | 0 |

The overlay must keep the board's `pwmfan` node; `tanager.dtso` only adds nodes.

A full build declares 20 GB, about 1.2 × its measured peak (16.6 GB for the two-core traffic-generator build, IP generation's child processes included; `~/tanager-build/.locks/vivado_peaks.log`). `vivado_run.sh` admits jobs within the host's declared-memory budget. Out-of-context unit runs (`tcl/ooc_synth.tcl`) peak at 3.1–3.4 GB and declare 4.

### PMOD console (RISC-V UART on the PMOD connector)

`TG_PMOD_UART=1` in the build environment puts the RISC-V console on the KV260's PMOD connector (DR-126):

```bash
TG_PMOD_UART=1 TANAGER_VIVADO_MEM_GB=20 bash tools/vivado_run.sh $SOC_BUILD/vivado/st_trafgen_100_pmod fpga/kv260/tcl/build.tcl $PWD st trafgen 100 2 bit
```

- **Line:** 8N1, 3.3 V, at the 16550's divisor (115 200 baud once OpenSBI has programmed it, also the reset value). Set the terminal on the laptop to 115200 8N1, no flow control.
- **Pins:**

  | Port | Direction (FPGA) | Pin | Connects to the module's |
  |---|---|---|---|
  | `pmod_uart_txd` | out | H12 (`som240_1_a17`, PMOD J2 pin 1) | RX |
  | `pmod_uart_rxd` | in, pulled up | B10 (`som240_1_b20`, PMOD J2 pin 2) | TX |

  - **The module:** the board's CH340 USB UART on J2, which is COM5 on the laptop.
  - **Source:** the board session read J2's numbering, and the user confirmed both pins on the board (2026-10-14; see [The board](#the-board), consoles). The Vivado board files (`kv260_som`, `kv260_carrier`) list the SOM240 pins but have no PMOD interface, so they cannot settle it. `xdc/kv260.xdc` holds the pins with the same note.
  - `TG_PMOD_TXD` and `TG_PMOD_RXD` override the pins without editing a file.
- **With the option off** (the default), `pmod_uart_txd` is high-impedance and nothing drives the connector.
- **Host copy:** with the option on, the host bridge still receives a copy of every character, so `tanager-host`'s console shows the output too. Input from either side reaches the RISC-V.

Arguments: configuration (`st`, `smt2`, `st_w3`, `smt2_w3`), core kind, core clock in MHz, number of cores, and the stage to stop at (`synth`, `impl` or `bit`).
- `core` builds the real `tg_core`. The M4 bitstream is one `st` core with the PMOD console, about 44K LUTs of core and 21K of uncore. At 100 MHz two cross-unit paths in the core miss by 3.8 ns ([results.md](results.md)), so the first one runs at 60 MHz (`st core 60 1 bit` with `TG_PMOD_UART=1`, `TANAGER_VIVADO_MEM_GB=22`).
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

### Board files

The board loads a build as the PL app `tanager` through dfx-mgr's `xmutil`, as for spike S1. The app is three files in `/lib/firmware/xilinx/tanager/`: `tanager.bit.bin`, `tanager.dtbo` and `shell.json` (`dtbo/shell.json`: a flat shell with one slot). `package.sh` puts them in one directory with `tanager-host`, the build's `summary.txt` and `SHA256SUMS`. The summary records the commit, the PMOD and fan options, the pins and the timing.

```bash
fpga/kv260/package.sh $SOC_BUILD/vivado/st_trafgen_100_pmod $SOC_BUILD/board/stage-b
```

For a core bitstream, name the images too: the first-light program (bring-up step 6), OpenSBI, the kernel, and a device tree for the bitstream's cores (`sw/dts`; one core here).

```bash
make -C sw/dts O=$SOC_BUILD/dts-c1 CORES=1
make -C tests/unit/soc prog
fpga/kv260/package.sh $SOC_BUILD/vivado/st_core_60_pmod $SOC_BUILD/board/m4 $SOC_BUILD/tests/soc_sw/soc_test.bin \
  $SOC_BUILD/opensbi/platform/generic/firmware/fw_jump.bin $SOC_BUILD/br-tanager_lp64d/images/Image $SOC_BUILD/dts-c1/tanager-kv260.dtb
```

## Board setup (one-time; needs a person)

1. **OS.** Write the standard Kria Ubuntu image (22.04 or 24.04 for Kria) to the SD card. Boot the KV260 and put it on the network. Install an SSH public key for the user that will run the tests. The user needs `sudo`.
2. **Carve-out for the RISC-V DRAM.** A53 Linux must not use the top 1 GiB of the high DDR bank (`0x8_4000_0000`–`0x8_7FFF_FFFF`), which is `tanager-host`'s default window. Add `mem=3G` to the kernel command line. The kernel then keeps the low 2 GiB and the first 1 GiB of the high bank.
   - **Ubuntu for Kria:** set `LINUX_KERNEL_CMDLINE` in `/etc/default/flash-kernel`, run `sudo flash-kernel`, reboot.
   - **Check:** `sudo grep System /proc/iomem` ends at `0x83fffffff` (root is needed; other users see zeros). The kernel's boot line reads `Memory: …/3145728K available`. `free -m` shows about 2,900 MiB, and `free -g` truncates that to 2.
3. **SMMU bypass for the PL masters.** The HP ports pass through the SMMU. If Linux's SMMU driver rejects unknown stream IDs, the RISC-V memory accesses fault. Add `arm-smmu.disable_bypass=0` to the same command line. Spike S1 is to confirm whether this is needed (plan §5.5).
   - On Ubuntu 24.04.2 for Kria the parameter is a no-op: the kernel has no driver for this SMMU and the device tree disables it (see [The board](#the-board)). It is kept as a guard.
4. **Install the PL app** (again for each new build). Copy the [board files](#board-files) to the board, then:
   ```bash
   sudo mkdir -p /lib/firmware/xilinx/tanager
   sudo cp tanager.bit.bin tanager.dtbo shell.json /lib/firmware/xilinx/tanager/
   sudo cp tanager-host /usr/local/bin/
   sudo xmutil listapps
   ```
   [`tanager` is in the list; if not, `sudo systemctl restart dfx-mgr` and list again].
   - `tanager-host` runs only while the `tanager` app is loaded: it looks for the overlay's node in the live device tree first, because a PL read that nothing answers hangs the board. Its options may come before or after the command.
5. **The default PL app.** The Kria image loads `k26-starter-kits` at boot. It routes Linux's fan PWM to the fan pin, and so does every Tanager bitstream (DR-129), so the fan follows the temperature with either loaded. When a run ends, reload the default app (`sudo xmutil unloadapp && sudo xmutil loadapp k26-starter-kits`), or let the board session's auto-restore timer do it (see [The board](#the-board), fan).

## Bring-up sequence

Each step's expected result is in brackets.

1. **Load the bitstream.** `sudo xmutil unloadapp && sudo xmutil loadapp tanager` [`xmutil` reports the app loaded; `dmesg` shows the FPGA manager loading `tanager.bit.bin` and the overlay applied; the fan keeps following the temperature, at 15/255 when cool, not full speed. If it stops or runs flat out, `sudo xmutil unloadapp` at once].
2. **Host window and clock.** `sudo tanager-host info` [ID `TNGR`, configuration, cores and uncore in reset; its 100.0 MHz is the design's `CLK_HZ` constant, not a measurement]. The PL clock as Linux set it: `sudo cat /sys/kernel/debug/clk/pl0_ref/clk_rate` [`99999999`; `90909090` means the overlay's request rounded down a divider step, as spike S1's once did].
3. **Fabric widths and clock.** `sudo tanager-host poke 0x68 0x12345678; sudo tanager-host peek 0x68` [reads back `0x12345678`; a garbled value means the AXI width (overlay `afi0`) is wrong].
4. **Memory path, without a core** (traffic-generator bitstream): `sudo tanager-host tg start 16384` [it prints the DRAM window it set, `0x840000000 + 0x40000000` by default], wait a few seconds, `sudo tanager-host tg status` [passes counting up, errors 0]. Then `sudo tanager-host info` [injector reads > 0, native latency avg and max: the spike S1 number seen from the SoC].
   - **At 250 cycles:** `sudo tanager-host inj --inj-rd 250`, wait, `tg status` again [errors still 0].
5. **Console path.** Each traffic generator prints one `.` per pass on the UART, or `E` after a pass with an error: `sudo tanager-host run --timeout 5` [dots appear; `run` attaches to the running generators, and holds everything when it exits].
   - **With the PMOD console** (`TG_PMOD_UART=1`): the same dots appear on COM5 at 115200 8N1 from the moment `tg start` runs, whether or not `tanager-host` reads the console. A clean line also rules out a `pl_clk0` that rounded down to 90.9 MHz: 9% slow garbles it.
   - A key pressed on COM5 reaches the RISC-V's UART; the generators ignore it.
6. **First light on the core** (core bitstream; steps 4 and 5 need the traffic-generator one): `sudo tanager-host load --fw soc_test.bin --kernel /dev/null --dtb /dev/null && sudo tanager-host run --timeout 10`.
   - [The console, and COM5 with the PMOD console, shows `tanager soc test: hart 0, dtb 0000000082200000`, `aclint ok`, `memory ok`, `one hart: coherence skipped` (with one core), `PASS`; `run` ends with `tohost 0x1: PASS`].
   - `soc_test.bin` comes from `make -C tests/unit/soc prog` (`tests/unit/soc/sw`). In simulation it takes 0.29 M cycles on one core (5 ms at 60 MHz). `tanager-host info` shows the core clock the bitstream was built for (60.0 MHz for the first M4 one).
7. **Linux** (once the core exists, with F/D from M3; the lp64d image):
   ```bash
   sudo tanager-host boot --fw fw_jump.bin --kernel Image --dtb tanager-kv260.dtb
   ```
   [OpenSBI banner, Linux boot, `TANAGER-BOOT-OK`; Ctrl-A x leaves].
8. **Commit trace** (FPGA lockstep, docs/spec/uncore-trace.md): add `--trace FILE` to `run` or `boot`. Every commit record (64 bytes) goes to `FILE` while the run goes, and the cores slow to the stream's and the reader's pace. [`trace: N records written`, no AXI error].
   - **Ring placement:** the ring takes the top `64 B << --trace-log2` of the carve-out (default 256 MiB), and the RISC-V memory window shrinks by that much. Build the device tree for traced runs with `make -C sw/dts MEM=0x30000000` (768 MiB).
   - **Post-mortem:** `--trace-wrap --trace-stop PC --trace-post N` keeps the last records up to N after the first commit at `PC`, written to `FILE` at exit.
   - **Starting late:** `--trace-start PC` lets the run reach `PC` at full speed and traces from there.
   - **Status:** `sudo tanager-host trace status`.

## Pins and clocks

| Signal | Where | Notes |
|---|---|---|
| `fan_en_b` | A12 (`som240_1_c24`), LVCMOS33 | the PS's TTC0 waveform 2 (`emio_ttc0_wave_o[2]`), uninverted: Linux's `pwm-fan` sets the speed (DR-129) |
| `pmod_uart_txd` | H12 (`som240_1_a17`, PMOD J2 pin 1), LVCMOS33 | the RISC-V UART's TX with `TG_PMOD_UART=1`, high-impedance otherwise |
| `pmod_uart_rxd` | B10 (`som240_1_b20`, PMOD J2 pin 2), LVCMOS33, pull-up | the RISC-V UART's RX with `TG_PMOD_UART=1` |
| `pl_clk0` | PS | 100 MHz, asked for as exactly 100,000,000 Hz by the overlay (the board's IOPLL makes 99,999,999 Hz; a request below that rounds down to 90.9 MHz) → MMCM → `clk_core` (`CORE_MHZ`), `clk_host` (100 MHz) |
| `pl_ps_irq0[0]` | PS, GIC SPI 89 | host bridge interrupt (console, mailbox, power, tohost) |

## The board

Our KV260, set up on 2026-10-14 by the board track (DR-126, stage A).

| Item | Value |
|---|---|
| Kit | KV260 Starter Kit: SOM SMK-K26-XCL2G rev 2 (XCK26), carrier SCK-KV-G rev 2 |
| Boot firmware (QSPI) | Kria 2023.2: FSBL and PMU firmware 2023.2, TF-A v2.8 (`xlnx_rebase_v2.8_2023.2`), U-Boot 2023.01 |
| OS | Ubuntu 24.04.2 LTS for Kria (image of 2025-04-23), kernel `6.8.0-1015-xilinx` |
| User | `ubuntu`, passwordless sudo (`/etc/sudoers.d/90-tanager`); host name `kria` |
| Network | a direct cable to the laptop's USB Ethernet adapter, with Windows connection sharing; DHCP lease `192.168.137.177` (`kria.mshome.net`) |
| SSH (from the laptop) | `ssh -F ~/.ssh/tanager_kv260.conf kv260` (key `~/.ssh/tanager_kv260_ed25519`) |
| Consoles (laptop COM ports, 115200 8N1) | **COM7:** the ARM console (`ttyPS1`).<br>**COM8:** the carrier's DisplayPort-to-HDMI bridge.<br>**COM5:** a CH340 USB UART on PMOD J2 for the RISC-V side. Its RX is on J2 pin 1, which is the FPGA's TX on H12 (`som240_1_a17`). Its TX is on J2 pin 2, the FPGA's RX on B10 (`som240_1_b20`). J2 is numbered odd/even: one row reads 11 9 7 5 3 1 from left to right, the other 12 10 8 6 4 2, so pins 1 and 2 face each other. The other signal pins are 3 = E10, 4 = E12, 5 = D10, 6 = D11, 7 = C11 and 8 = B11. The pins are 3.3 V only (LVCMOS33). |
| Kernel command line | `… cma=800M mem=3G arm-smmu.disable_bypass=0` |
| Linux RAM | `0x0`–`0x7FEF_FFFF` and `0x8_0000_0000`–`0x8_3FFF_FFFF`. The carve-out `0x8_4000_0000`–`0x8_7FFF_FFFF` is outside it; CMA is 800 MiB at `0x4460_0000` |
| Default PL app | `k26-starter-kits` (package `xlnx-default-bitstreams`), loaded by `dfx-mgr` at boot |

- **Command line.**
  - `flash-kernel` builds `bootargs` from `/etc/flash-kernel/bootscript/bootscr.zynqmp.kria`, then appends `LINUX_KERNEL_CMDLINE` from `/etc/default/flash-kernel`.
  - `sudo flash-kernel` rewrites `/boot/firmware/boot.scr.uimg` and `image.fit`. The originals are kept there as `*.orig`. If the board stops booting, rename them back from another computer; the partition is FAT.
  - Kernel updates rerun `flash-kernel`, which keeps the setting.
- **`/dev/mem`.** The kernel has `CONFIG_STRICT_DEVMEM`: it maps the carve-out, which is outside Linux RAM, and refuses Linux RAM. Checked at `0x8_4000_0000` and `0x8_3FFF_F000`. `tanager-host` needs `mem=3G` to reach the carve-out.
- **SMMU.** This kernel has no driver for the ZynqMP's MMU-500: `CONFIG_ARM_SMMU` is not set, only `ARM_SMMU_V3`.
  - The device tree's `/axi/iommu@fd800000` is `disabled`, and there are no IOMMU groups, so the PL's DDR accesses go untranslated.
  - The kernel accepts `arm-smmu.disable_bypass=0` silently, and it changes nothing. Spike S1's DECERR check is the test.
- **Fan: Linux runs it.**
  - **Control:** `fancontrol.service` reads `/etc/fancontrol` every 5 s and maps the AMS temperature (`temp1`) to `pwm1` of the `pwmfan` hwmon: 15/255 at 35 °C, rising to 255 at 45 °C.
  - **The PWM:** TTC0 (`0xFF11_0000`) channel 2, 25 kHz, inverted. In the device tree, `/pwm-fan` has `pwms = <&ttc0 2 40000 1>`.
  - **The route:** the PWM leaves the PS on EMIO (`emio_ttc0_wave_o[2]`). The PL design must carry it to A12 (`fan_en_b`, active low). `k26-starter-kits` does.
  - **The rule:** a bitstream that ties `fan_en_b` low runs the fan at full speed, which the user does not allow (2026-10-14). Every Tanager and spike design routes `emio_ttc0_wave_o[2]` to A12 unchanged, with PS8 `PSU__TTC0__WAVEOUT__ENABLE {1}` and `PSU__TTC0__WAVEOUT__IO {EMIO}`. A design that doesn't is not loaded.
- **Network.**
  - ICS's DHCP stopped answering once: nothing listened on UDP 67, although the sharing service was running. Restarting ICS on the laptop fixed it.
  - Without DHCP, the board still answers on its IPv6 link-local address, `fe80::48ff:2967:7216:51ee`, on the laptop's Ethernet.
- **Clock.** The board shows a wrong date until NTP reaches it through the laptop's connection sharing.

## Bring-up on the board (2026-10-14)

The board track ran bring-up steps 1–5 on [the board](#the-board) on 2026-10-14. All five pass.
- **Build:** the traffic-generator build: `st`, 2 generators, 100 MHz, commit `5048957`, PMOD console on H12/B10, fan TTC0 wave 2 → A12. Bitstream sha256 `5706b857…`, `tanager-host` `24da9717…`.
- **How:** [`board/tg.sh`](board/tg.sh) (`stage`, `load`, `steps`, `restore`), run as `ubuntu` on the board.
- **Logs:** [`board/stage_b_steps.log`](board/stage_b_steps.log), the passing run. [`board/stage_b_first.log`](board/stage_b_first.log), the first try, with the README's command forms. [`board/stage_b_console.log`](board/stage_b_console.log), a console diagnostic.

| Step | Result |
|---|---|
| 1. Load | `xmutil loadapp tanager` loads it in slot 0; the FPGA manager reports `operating`. `pl0_ref` reads 99,999,999 Hz. The fan stayed at 15/255 under `fancontrol`, and the user heard it stay quiet. |
| 2. `info` | v1.0, `st`, 2 cores × 1 thread, capabilities `0x2b`, everything in reset, window 0/0 |
| 3. Widths | `FROMHOST` as a 64-bit pair reads back `0x12345678`/`0x9abcdef0`. `TG_LINES` (32-bit) reads back `0x2468`. |
| 4. Memory path | `tg start` sets the window 0x840000000 + 0x40000000, and it reads back exactly. About 60 passes/s for generator 0. 14.4 M lines checked, **0 errors**. |
| 4, at 250 cycles | `INJ_RD` reads 250. Passes slow to about 13/s. 3.9 M lines checked, **0 errors**. |
| 5. Console | `run` showed 1,681 dots through `tanager-host` in its 5 s. COM5 (the PMOD UART) received 3,371 bytes over the session, all `.`, two per pass. `UART_TX_LEVEL` agrees with the passes. |

**What the steps above need on this build** (reported to the SoC track):
- **Options before the command.**
  - `tanager-host` parses its options with `getopt_long("+vh")`, which stops at the first word that is not an option. So `inj --inj-rd 250` and `run --timeout 5` silently ignore their options: the injector stayed at 0, and `run` never timed out.
  - The forms that work are `tanager-host --inj-rd 250 inj`, `--stats inj` and `--timeout 5 run`.
  - Step 6's `boot --fw … --kernel … --dtb …` and step 7's `run --trace FILE` are affected the same way.
- **Step 3's check:** `poke 0x68` alone reads back 0. `FROMHOST` is a 64-bit pair, and its low half lands only when the high half is written, so write `0x6c` too, or use a 32-bit register.
- **The injector's native latency:** `info` reports avg 0.1–0.2 cycles over 20–40 M reads, with a max of 98–102. The average is not plausible: spike S1 implies about 18 cycles at 100 MHz at the PS port, before the uncore's own path. `INJ_RD_LATSUM` or the count looks wrong, so step 4 does not yet give the SoC's native-latency number.

**Never read the host window without the design.**
- With `k26-starter-kits` (or nothing) in the PL, nothing answers at `0xA000_0000`, and a `tanager-host` read hangs the A53 until a power cycle. This happened once, from a status command after the automatic restore.
- `tg.sh` now refuses every `tanager-host` call unless `xmutil listapps` shows `tanager` in the slot.
- Proposed for `tanager-host` itself: refuse to start unless the overlay's `tanager@a0000000` node is present in the live device tree.
