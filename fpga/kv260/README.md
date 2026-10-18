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

**The uncore's build switches** (DR-146): `build.tcl` passes each of these, when set, to `kv260_top`, and lists the ones set in `summary.txt` (`uncore=`). Unset keeps the default; their effects are in [docs/spec/soc.md](../../docs/spec/soc.md) §Reserve levers.

| Variable | Meaning | Default |
|---|---|---|
| `TG_UNCORE_DSP` | which register slices keep their data in DSPs, one bit per site (hex) | `0x8403080000` |
| `TG_L2_DATA_LAT` | the L2 data array's read latency, 2 and up; 0 picks by the clock | 0: 4 above 150 MHz, else 2 |
| `TG_AR_SLICE` | the AR slices at the L2 banks (0 or 1) | 1 |
| `TG_B_SLICE`, `TG_D_SLICE`, `TG_W_SLICE` | the banks' B, D, and AW and W slices (0 or 1 each) | 0 |
| `TG_XBAR_IN_SLICE` | the core-side request slices, a bit per channel (0–15: caches' A, MMIO A, l1d C, l1d E) | 0 |
| `TG_XBAR_SLICE`, `TG_MEM_SLICE` | the crossbar's own slices and the memory ports' AXI slices (0 or 1 each) | 1 |
| `TG_DEBUG_CNT` | the board debug counters, read with `tanager-host dbg` ([uncore.md](../../docs/spec/uncore.md) §Board debug counters) | 0 |
| `TG_VIRTIO_WINDOW` | the forwarded virtio window, served by `tanager-host` (stage C, [soc.md](../../docs/spec/soc.md) §8.1; `CAPS[2]`) | 0 |
| `TG_HOST_DMA` | the coherent host DMA port on `M_AXI_HPM1_FPD`, 2 GiB at `0x5_0000_0000` (stage C, [soc.md](../../docs/spec/soc.md) §8.1; `CAPS[8]`). Without it HPM1 still answers: reads `DECERR`, writes dropped | 0 |
| `TG_FAN_PL` | the fan's PL regulator (stage D's D2, [soc.md](../../docs/spec/soc.md) §8.2): `fan_en_b` runs at the larger of a curve of the PL SYSMON's temperature (15/255 at 35 °C to 255/255 at 45 °C) and the A53's TTC duty. 0 routes the TTC waveform alone (DR-129). With 1, the A53's PL temperature channel reads invalid while the bitstream is loaded (the A53 OS change log below) | 1 |
| `TG_PS_WINDOW` | the PS window: the PS's peripheral registers at `0xFE00_0000`–`0xFFFF_FFFF` through `S_AXI_LPD`, and their interrupts on PLIC 20–24 (stage D's D1, [soc.md](../../docs/spec/soc.md) §8.2). A define, because the cores' PMA sees the region. The block design has the port and the interrupts in every build, idle without it | 0 |

**Placement and routing at a tighter clock:** `TG_PR_UNC` (ns, default 1.0; 0 turns it off) is setup uncertainty on the core clock from placement through routing, taken back before the reports. So `summary.txt` and the reports give the slack at the real period (DR-154, the coordinator, 10-17). At a plain 100 MHz target the placer under-works the cores, and spikes-2's headroom baseline closed with +1.065 ns this way. `summary.txt` records it (`pr_unc=`).

**Synthesis directive:** `TG_SYNTH_DIRECTIVE` (default `AreaOptimized_high` since 10-16, DR-150; `Default` gives the earlier builds' flow). The two-core `smt2` build with the commit trace no longer fit under `Default` (118.3K LUTs after synthesis, 101%); spikes' full-chip fits and the area numbers already use `AreaOptimized_high`. `summary.txt` records it (`synth=`).

**Synthesis check:** the build fails when synthesis reports an implicit, undriven or forward-referenced net in our own RTL (Synth 8-11241, 8-605, 8-8895, 8-6901, 8-3848); `vivado.log` then names them. Messages about Xilinx's generated IP pass.

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
3. **Fabric widths.** `FROMHOST` (`0x68`/`0x6C`) is a 64-bit pair: a low-half write waits in a shadow register and lands together with the high half, so write both, low half first: `sudo tanager-host poke 0x68 0x12345678; sudo tanager-host poke 0x6c 0x9abcdef0; sudo tanager-host peek 0x68; sudo tanager-host peek 0x6c` [reads back `0x12345678` and `0x9abcdef0`; a garbled value means the AXI width (overlay `afi0`) is wrong]. Clear it afterwards (`poke 0x68 0; poke 0x6c 0`). The other 64-bit pairs (`DRAM_BASE`, `DRAM_SIZE`, `BOOT_ENTRY`, `DTB_ADDR`) behave the same way.
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
| OS | Ubuntu 24.04.2 LTS for Kria (image of 2025-04-23). The kernel was `6.8.0-1015-xilinx` at setup and `6.8.0-1036-xilinx` from 2026-10-16. Unattended upgrades installed the newer one, and `flash-kernel` kept the command line. It also has no MMU-500 driver (`# CONFIG_ARM_SMMU is not set`), and the SMMU node is still disabled. |
| Boot firmware slots (QSPI) | `xmutil bootfw_status` (2026-10-16): A and B both bootable, A requested and last booted. Both hold `K26-BootFW-01.02-06140626` (`XilinxSom_QspiImage-k26-v2.1-06140636`), so B is a known-good fallback. |
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
  - **The PL regulator** (stage D's D2, 2026-10-17; `TG_FAN_PL=1`, the default): A12 carries the larger of the A53's duty and a curve of the PL die's temperature, so the fan never runs slower than the A53 asks. A disabled TTC (pwm1 = 0) idles low and so runs the fan full. Its SYSMONE4 takes the PL SYSMON from the PS: the A53's PL temperature channel reads invalid while such a bitstream is loaded, and `tanager-host fan` shows the PL die instead.
  - **The rule:** a bitstream that ties `fan_en_b` low runs the fan at full speed, which the user does not allow (2026-10-14). Every Tanager and spike design routes `emio_ttc0_wave_o[2]` to A12, unchanged or through D2's PL regulator (below), with PS8 `PSU__TTC0__WAVEOUT__ENABLE {1}` and `PSU__TTC0__WAVEOUT__IO {EMIO}`. A design that doesn't is not loaded.
- **Network.**
  - ICS's DHCP stopped answering once: nothing listened on UDP 67, although the sharing service was running. Restarting ICS on the laptop fixed it.
  - Without DHCP, the board still answers on its IPv6 link-local address, `fe80::48ff:2967:7216:51ee`, on the laptop's Ethernet.
- **Clock.** The board shows a wrong date until NTP reaches it through the laptop's connection sharing.

### A53 OS changes (change log)

The user approved the A53 OS changes that stages C and D need (DR-147, 2026-10-16): packages, a network bridge and boot settings, and on 2026-10-17 the SD card's repartitioning. Each change is listed here with how to undo it.
- **Rules:** the laptop's SSH path to the board is never cut. Network changes are applied so that they revert on their own if contact is lost (`netplan try`, or a timed rollback).
- **Kernel updates** happen only when we choose, after re-running the power-up checks: boot, command line, `k26-starter-kits` plus `fancontrol`, and disk.

| Date | Change | Why | Undo |
|---|---|---|---|
| 2026-10-16 | `sudo apt-mark hold linux-xilinx linux-image-xilinx linux-headers-xilinx linux-image-6.8.0-1036-xilinx linux-modules-6.8.0-1036-xilinx linux-headers-6.8.0-1036-xilinx linux-xilinx-headers-6.8.0-1036 flash-kernel` | Unattended upgrades replaced the kernel (1015 → 1036) while the board was off. The hold keeps the A53's kernel and boot script fixed through stages C and D. Userland security updates continue. | `sudo apt-mark unhold` with the same list; check with `apt-mark showhold` |
| 2026-10-17 | **With the D2 regulator loaded, the A53's PL temperature channel reads invalid; the PS channel and `fancontrol` are unaffected.** Nothing on the A53 changed. The regulator's SYSMONE4 is in every Tanager bitstream built with `TG_FAN_PL=1`, the default, and it takes the PL SYSMON from the PS. `AMS_PL_CSTS` bit 0 reads 0 and the AMS reads the PL channels as 0, so hwmon's `temp3` shows −280.2 °C. `xmutil platformstats`' PL readings are invalid as well. (The board, d2, 10-17.) | Stage D's D2 (DR-147 F-a, DR-150). The coordinator kept it (option (a), 10-17): `fancontrol` regulates on `temp1`, the PS sensor, and in stage D the A53 parks. `tanager-host fan` shows the PL die in 0.5 °C steps. | Load a bitstream without the regulator (`TG_FAN_PL=0`, or the default PL app): the channel reads again from that load. |
| 2026-10-17 | A bridge `br0` over `eth0`, **in memory only**: NetworkManager connections `tg-br0` (bridge, `eth0`'s MAC `00:0a:35:2a:df:d8`, DHCP client ID `mac`, STP off) and `tg-br0-eth0` (eth0 as its port), both `save no`. [`board/runs/net_bridge_up.sh`](board/runs/net_bridge_up.sh), run detached under a NetworkManager checkpoint (180 s rollback), then confirmed from a fresh SSH session ([`net_bridge_confirm.sh`](board/runs/net_bridge_confirm.sh)). The laptop's lease came back the same (192.168.137.177); SSH dropped for about 7 s. | Stage C's network: the RISC-V's virtio-net TAP (`tanager-host --net tanager0 --net-bridge br0`) joins the laptop's link and takes its own lease. | [`board/runs/net_bridge_down.sh`](board/runs/net_bridge_down.sh) (deletes both connections and brings back "Wired connection 1", under a checkpoint again). A reboot or a NetworkManager restart also undoes it, since nothing was saved. |
| 2026-10-17 | **Deleted the Debian images on the A53:** `~/tanager/sc2/`, `sc2net/` and `sc2netc/tanager-trixie.img*`, `httpd/blob64`, `stress_src`. The root went from 8.0 GB to 3.3 GB used. Before deleting, the gcc/sysbench image's sha256 (`d72f3872…`) was checked against the laptop backup's. | To fit the A53's root in 6 GiB (below). | Restore from the laptop: `C:\KV260-backup\2026-10-17\` (`SHA256SUMS`), which holds the gcc/sysbench image and the SoC track's three Debian packages. |
| 2026-10-17 | **cloud-init's root growing turned off:** `/etc/cloud/cloud.cfg.d/99-tanager-root-size.cfg` with `growpart: {mode: 'off'}` and `resize_rootfs: false`. Checked with `cloud-init single --name growpart` and `--name resizefs`, and again at the next boots. | **Ubuntu's cloud-init regrows the root on every boot, so a shrink must disable it first.** `growpart` and `resizefs` run with "frequency always". They undid the first shrink 16 s into the boot, extending p2 to the end of the card and growing the filesystem online, with no data lost. Now they also keep p2 from growing into p3. | Delete the file. With p3 present, growpart has no free space to take. |
| 2026-10-17 | **The SD card repartitioned for the RISC-V** (the user's decision, DR-147). p2 (`writable`, the A53's root) went from 13.6 GiB to **6 GiB**: sectors 2,099,200–14,682,111, a 1,572,864-block filesystem. **p3** is new: sectors 14,682,112–30,535,679, 15,853,568 sectors (7,741 MiB), type 83, for the RISC-V's root (`LABEL=tanager-root`). How it was done:<br>• a one-shot initramfs step, [`board/runs/tg-shrink-root.premount`](board/runs/tg-shrink-root.premount) with its [`.hook`](board/runs/tg-shrink-root.hook), armed by `tg-shrink-root.go` on p1. It ran twice: the first shrink was undone by cloud-init (above);<br>• then an online `resize2fs` of p2, and `sfdisk --force --no-reread --append` for p3, which also told the kernel (a following `partx -a` then reports "error adding partition 3", which is harmless);<br>• the hook and script were removed and `update-initramfs -u` run. The initramfs again has the same 2,509 files as before.<br>Records in [`board/sdcard/`](board/sdcard/). Afterwards the step's leftovers on p1 were deleted (the coordinator): `image.fit.pre-shrink`, its two logs (kept in `board/sdcard/`), and flash-kernel's `image.fit.bak`. p1 keeps `image.fit`, the original `image.fit.orig`, and the boot scripts. | The RISC-V's own partition (DR-147). Stage C serves it whole as the virtio disk (`tanager-host --blk /dev/mmcblk1p3`); in stage D it is the RISC-V's mmcblk root. | `sudo sfdisk --delete /dev/mmcblk1 3`, then `echo ",+" \| sudo sfdisk -N 2 --force --no-reread /dev/mmcblk1`, then `sudo resize2fs /dev/mmcblk1p2` (online). If the kernel still shows the old p2 size, reboot first. |

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

**What the steps above needed on `tanager-host` `5048957`.** All of these are fixed in `c44622c`, and the board confirms it ([`board/stage_b_steps_c44622c.log`](board/stage_b_steps_c44622c.log)): the README's own forms pass, `inj --inj-rd 250` sets 250, and `run --timeout 5` stops at 5 s.
- **Options before the command.**
  - `tanager-host` parses its options with `getopt_long("+vh")`, which stops at the first word that is not an option. So `inj --inj-rd 250` and `run --timeout 5` silently ignore their options: the injector stayed at 0, and `run` never timed out.
  - The forms that work are `tanager-host --inj-rd 250 inj`, `--stats inj` and `--timeout 5 run`.
  - Step 6's `boot --fw … --kernel … --dtb …` and step 7's `run --trace FILE` are affected the same way.
- **Step 3's check:** `poke 0x68` alone reads back 0. `FROMHOST` is a 64-bit pair, and its low half lands only when the high half is written, so write `0x6c` too, or use a 32-bit register.
- **The injector's native latency:** `info` reports avg 0.1–0.2 cycles over 20–40 M reads, with a max of 98–102. The cause is an RTL width bug: every read in flight when the 16-bit time counter wrapped corrupted the sum. The traffic-generator bitstream still has it (with the new `tanager-host`: avg 142.0, max 108). The M4 bitstream has the fix (below).

**Never read the host window without the design.**
- With `k26-starter-kits` (or nothing) in the PL, nothing answers at `0xA000_0000`, and a `tanager-host` read hangs the A53 until a power cycle. This happened once, from a status command after the automatic restore.
- `tg.sh` now refuses every `tanager-host` call unless `xmutil listapps` shows `tanager` in the slot.
- `tanager-host` itself (`c44622c`) now refuses before any MMIO unless `/sys/firmware/devicetree/base/axi/tanager@a0000000` (or `/amba/…`) exists, and `--force` overrides. On the board, with the default app loaded, it refused with the message and exit 2. That test used `--regs 0xff0a0000`, a PS GPIO block, so a failed guard could not have hung the board.

### The core: M4 first light and Linux (2026-10-15)

The board track then took steps 6 and 7 on the SoC track's first core bitstream.
- **Build:** one `st` core at 60 MHz (commit `20435b1`), with the PMOD console and the fan routing. WNS is +0.153 ns; at 100 MHz it misses by 3.8 ns inside the core. Bitstream sha256 `2f71d6ce…`.
- **App:** loaded as the dfx-mgr app `tanager-m4`, with `TG_APP=tanager-m4 TG_DIR=~/tanager/m4 board/tg.sh`.

| Step | Result |
|---|---|
| 6. First light | `load --fw soc_test.bin --kernel /dev/null --dtb /dev/null`, then `run --timeout 10`, gives `tanager soc test: hart 0, dtb 0000000082200000`, `aclint ok`, `memory ok`, `one hart: coherence skipped`, then `tohost 0x1: PASS` ([log](board/m4_firstlight.log)). |
| 7. Linux, native latency | OpenSBI v1.9 ("Tanager on KV260", rv64imafdcb, Sv39), then Linux 6.18.56-tanager with 1 GiB. Init at 2.1 s of kernel time. `TANAGER-BOOT-OK 6.18.56-tanager harts=1` came **8 s after the load**, the 21 MB image copy included ([log](board/m4_linux_boot.log)). |
| 7. Linux, 250 injected read cycles | The login prompt came 14 s after the load (init at 4.0 s). Root logged in on the console and ran `uname -a`, `/proc/cpuinfo`, `/proc/meminfo` and `uptime`. Then `poweroff`, and `tanager-host` reported `RISC-V requested power-off`, 31 s after the load ([log](board/m4_linux_shell_inj250.log)). |

- **What Linux reports:** `isa: rv64imafdc_zicntr_zicond_zicsr_zifencei_zaamo_zalrsc_zca_zcd_zba_zbb_zbs_sstc`, `mmu: sv39`, `uarch: tanager,tanager`. MemTotal is 1,016,492 kB.
- **The injector, read while Linux ran:** 1.53 M reads, native latency **avg 19.8, max 54 cycles** at 60 MHz (330 ns on average). That is from the L2's request to its response, through the window and the PS port. It is consistent with spike S1's 184 ns at the PS port, once the uncore path, the PL-PS crossing at 60 MHz and the line's last beat are added.
- **The PMOD console** (COM5, 115200 8N1) carried both boots and the whole session: 22,403 bytes. The only bad byte is described next.
- **The console tail:** first light's last line first showed as `PAS` on both consoles, because `run` wrote `CTRL = 3` as soon as `tohost` arrived, while the UART was still sending. `tanager-host` `c68bc6e` drains the console until it has been quiet for 20 ms (0.5 s at most) before it resets. On the board, both consoles now end in `PASS` ([log](board/m4_firstlight_c68bc6e.log)).
- **M4's exit criteria** (plan §11):
  - **Linux boots at 0 and 250 injected cycles:** met, at 60 MHz.
  - **Linux at ≥ 100 MHz:** waits for the core's timing.
  - **FPGA lockstep:** waits for step 8, the commit trace.

### FPGA lockstep (2026-10-15)

The verification track's checker, `tanager-lockstep`, checks every commit record of the core against Spike, which runs the same images from the same boot ROM. The board track ran its RUNBOOK on the M4 bitstream:
- **Package:** verification track `c166794`, the 768 MiB device tree, and later its zero-padded copy.
- **How:** `board/tg.sh ls-soc` and `ls-linux`, with `tanager-host` `231fab53` (`--lossless --trace-log2 16`, the trace through a FIFO in `~/tanager/lockstep`).
- **Zeroing:** the RISC-V window was zeroed before each Linux run with `board/tg_zero` (768 MiB in 1.3 s).
- **Logs:** in [`board/lockstep/`](board/lockstep/).

| Run | Result |
|---|---|
| 1. Offline on the A53, simulation traces | SoC test: PASS, 230,255 records. A planted fault is caught at exactly record 100,000 (exit 2). OpenSBI: PASS, 3,087,220 records in 21.8 s. **The A53 checks 141 k records/s** (the 5950X 1.9 M/s). |
| 2. The board's first commit trace (SoC test, to a file) | 4,435,137 records written, no AXI error; checked offline: **PASS** |
| 3. SoC test, live through the FIFO | **PASS**, 334,491 records |
| 4. Linux, native latency, live | **PASS after 335,786,888 records** (335,761,726 retired, 12,658 traps, 12,504 interrupts), 97.9 k records/s. `TANAGER-BOOT-OK` at 2,336 s (unchecked: 8 s); login prompt 2,396 s; root shell 2,493 s; `poweroff` reported to the host at 3,435 s. |
| 5. Linux, 250 injected read cycles, live | **PASS after 355,612,637 records** (355,584,782 retired, 12,810 traps, 15,045 interrupts), 97.6 k records/s. `TANAGER-BOOT-OK` at 2,491 s (unchecked: login in 14 s); root shell 2,664 s; `poweroff` at 3,646 s. |

- **The first live Linux try stopped, on a gap in the test setup, not in the core.**
  - **The stop:** at record 8,204,496 ([report](board/lockstep/ls_linux0_attempt1.log)), Linux's crc32 over its device tree read offset 0x90a. That is past the 2,087-byte file, in free space OpenSBI added for its reserved-memory nodes and never wrote. On the board, that space held old DDR data (0x40); in Spike it holds 0.
  - **The fixes:** zeroing the window fixed it. The verification track has since supplied a zero-padded device tree (64 KiB), and `tanager-host` `6466df0` zeroes the window itself whenever `--trace` is given.
- **Each Linux run logs one RCU stall report** in early init (289 s and 307 s of kernel time). The RUNBOOK expects it: the RISC-V timer keeps counting while the checker holds the core. Nothing else in the logs: no oops and no lockup.
- **M4's exit criteria** (plan §11): FPGA lockstep, and Linux at 0 and 250 injected cycles, are now met, at 60 MHz. What remains is Linux at ≥ 100 MHz.
- **`tanager-host` `6466df0` on the board** (sha256 `47552f27…`), after the Linux runs:
  - **Zero-on-load:** `--trace` now zeroes the window itself: "zeroed the RISC-V window: 768 MiB in 1.0 s", or 1020 MiB in 1.4 s with `--trace-log2 16`. Steps 2 and 3 pass with it and without `tg_zero` ([log](board/lockstep/ls_soc_6466df0.txt)).
  - **The failure path, live:** with a fault planted at record 100,000, the checker stops with `MISMATCH at record 100000 … x11` (exit 2). `tanager-host` then reports "trace consumer stopped" and exits 4, without stalling ([log](board/lockstep/ls_plant100000_6466df0.txt)).
- **A gap in the checker's `--plant` self-test** ([notes](board/lockstep/plant_selftest.txt)):
  - **What happens:** `--plant=1000` puts the fault in the board trace's record 1,001, which is an MMIO load: the SoC test polling the real UART's transmit-ready bit. The checker takes MMIO load values from the RTL, so it passes the run.
  - **Not a checker fault:** the same plant stops correctly on the simulation trace, and at record 100,000 on the board trace.
  - **Fixed** in the verification track's `98a05ff` (checker sha256 `d0cfb7b0…`): `--plant` now corrupts only values the checker compares. On the board, `--plant=1000` plants in record 1,002, "x15 of `andi a5, a5, 32` at 0x80000034", the instruction after the UART poll. The checker stops there (exit 2), and `tanager-host` exits 4 ([log](board/lockstep/ls_plant1000_98a05ff.txt)).

### Two cores and Debian 13 (2026-10-16/17, DR-150 and DR-147)

The board track ran the SoC track's two-core and stage C bitstreams. Each run's README has the details.

**The two-core hang:** p0, p0d2, c1s and st2.
- **The symptom:** every build after `3eed95f` hung before OpenSBI printed, with one or two cores, `smt2` or `st` ([p0](board/p0/README.md), [p0d2](board/p0d2/README.md), [c1s](board/c1s/README.md), [st2](board/st2/README.md)).
- **What the checker found:** on c1s's 20-record trace it stopped at the 7th instruction, where `mv s1, a1` read another register's value.
- **The control:** the M4 bitstream on the same board passed ([control](board/ctl-m4/README.md)), which pinned the fault to the RTL.
- **The cause:** Vivado's logs had `rn_fire` (rename's pop to the free lists) as an undriven implicit net. It was used in generate blocks before its declaration; Verilator resolves it, Vivado follows the standard. Fixed in the core track's `24ada50`, and `build.tcl` now fails on implicit nets.

**P0, two cores boot Linux** ([p0f](board/p0f/README.md)): two `smt2` cores (harts 0 and 2) at 70 MHz.
- **Boot:** "smp: Brought up 1 node, 2 CPUs", with the login prompt 6 s after the load.
- **SMP test:** two busy loops in parallel take as long as one.
- **The workload set:** 54/54 measurements, CoreMark 6/6.
- **Lockstep:** two-core Linux passes the checker from boot to power-off: 408,432,254 records, 14,594 traps, 19,840 interrupts.
  - **What it took:** a device tree that tells Linux the timer runs at 1 GHz. On the real 10 MHz clock the first run had no mismatch in 425,955,311 records, but the boot could not finish. The timer counts in real time while trace backpressure throttles the cores, so the periodic tick's catch-up loop never ends.
  - **The proper fix:** the SoC track's `--freeze-time`, which holds the timer while the trace stalls the cores. With it, [p0g](board/p0g/README.md) passes on the normal 10 MHz tree: 395,612,106 records from boot to power-off, with kernel timestamps as in an unchecked boot.
- **The L2 error events** of traced and busy runs are speculative line fills beyond the 1 GiB DRAM window, which it refuses: refusals × 4 beats = the events. They are harmless. DR-151 shrinks the core's memory region to the real 1 GiB.

**Stage C, Debian 13 through U-Boot** ([sc2](board/sc2/README.md)): two `smt2` cores with the virtio window and the host DMA port.
- **Buildroot:** virtio-blk (the md5 matches the host's) and virtio-rng work.
- **Debian:** U-Boot 2026.07 loads Debian's own kernel `6.12.111+deb13-riscv64` from a virtio-blk disk image.
  - systemd reaches `multi-user.target` with no failed units, in 3 min 42 s, with `nproc` 2.
  - `sudo poweroff` ends it cleanly.
- **The network** ([sc2net](board/sc2net/README.md)): virtio-net on a TAP that `tanager-host` serves, bridged into the A53's `br0` (in memory, under a NetworkManager checkpoint).
  - Debian takes its own lease from the laptop's connection sharing, syncs its clock, resolves names, and reaches Debian's mirror (`apt-get update`).
  - virtio-net carries 1.3 MB/s (a 112 MB download), limited by the guest at 70 MHz, not by the link ([A/B](board/sc2netc/README.md)).

**100 MHz** ([sc3](board/sc3/README.md)): main's tree (stage C, DR-151) at 100 MHz.
- **Debian:** about 1.45× the 70 MHz results on the same image: the boot, gcc, sysbench and the LAN transfer.
- **Lockstep:** two-core Linux passes the checker from boot to power-off (409,133,336 records).
- **DR-141's set:** 3 boots out of 3 pass.
  - CoreMark: 2.769 per MHz, 276.9 iterations/s per core, and 547.2 for two copies at once, one per hart.
  - Dhrystone: 140.6 DMIPS.

**The RISC-V's own partition** ([sdcard](board/sdcard/README.md)): the SD card has a p3 of 7,741 MiB for the RISC-V. The A53's root shrank to 6 GiB.
- **The boot:** sc3 boots Debian 13 from p3, served whole (`tanager-host --blk /dev/mmcblk1p3`). The SoC track's U-Boot finds extlinux on the whole disk, and the root is `/dev/vda`.
- **The check:** a 64 MiB write survives a clean power-off, and p3 checks clean on the A53.
