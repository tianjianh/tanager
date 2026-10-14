# Spike S1: PL → PS DDR latency and bandwidth on the KV260

S1 measures what the L2 will see when it misses: the latency and bandwidth of the PS DDR4 through the S_AXI_HP ports, from the programmable logic, at the 200 MHz core clock (plan §2.1, §5.5). The result sets the KV260's native latency point (plan §2.5); it does not change any size.

## What is in this directory

| Path | What it is |
|---|---|
| `rtl/tg_s1_engine.sv` | One measurement engine: an AXI4 master (128-bit, 49-bit addresses, 6-bit IDs) that issues pointer-chase reads, or read or write streams with up to 32 outstanding bursts. It keeps per-transaction latency, a 256-bin histogram, cycles and bytes. |
| `rtl/tg_s1_top.sv`, `rtl/tg_s1_bd.v` | Two engines (on HP1 and HP2) and their AXI4-Lite registers at `0xA000_0000`. `tg_s1_bd.v` is the Verilog wrapper the block design instantiates; it also drives the KV260 fan pin from the PS timer's PWM (DR-129). |
| `build.tcl` | Builds the bitstream. It creates the block design: the PS with the KV260 SOM preset, `pl_clk0` 100 MHz → MMCM → 200 MHz for HPM0 (128-bit, SmartConnect to AXI-Lite), HP1 and HP2 (128-bit). |
| `tg_s1.xdc` | The fan pin (A12, LVCMOS33). The timer, channel and polarity are in `tools/tcl/tg_kv260_fan.tcl`, shared with the SoC build. |
| `overlay/tg_s1.dtso`, `overlay/shell.json` | Device-tree overlay and app description for `xmutil`. The overlay sets the AXI port widths (AFI registers) and `pl_clk0`. |
| `sw/tg_s1.c`, `sw/Makefile` | The A53 program. It allocates 2 MiB hugepages, finds their physical addresses, writes a random pointer chase, cleans the caches, then runs the tests below. |
| `sim/tb_s1.sv` | Simulation of the PL side against AXI memory models. It passes: chase order, both engines streaming at once, writes. |

## Tests the program runs

1. **Idle latency.** One read in flight, each address taken from the data of the previous read (64-byte reads): within one 2 MiB page, then over the whole buffer, then with 16-byte reads, then on HP2.
2. **Read bandwidth.** Sequential bursts of 64 B and 256 B, with 1–32 outstanding; then random 64 B reads.
3. **Write bandwidth.** 64 B and 256 B bursts, 16 outstanding.
4. **Both ports at once.** HP1 and HP2 together.
5. **Loaded latency.** The chase on HP1 while HP2 streams reads, then writes; then while four A53 threads run `memcpy`.

Latency is in core cycles (5 ns), from the read-address handshake to the first data beat at the PL port. That is the L2's view of a DRAM access.

## Building the bitstream (on the build host)

```bash
source tools/env.sh
tools/vivado_run.sh $TANAGER_BUILD/track-spikes-72f833/s1_build fpga/spikes/s1/build.tcl $PWD
```

The run takes about 10 minutes. It writes `tg_s1.bit.bin`, `tg_s1.dtbo`, `shell.json`, `address_map.txt` and the timing and utilisation reports into that directory. The current build meets 200 MHz with +0.513 ns of slack, in 4,081 LUTs, 5,133 flip-flops and one block-RAM tile; its reports are in [`results/s1_build`](../results/s1_build). The three files the board needs stay in `/home/w/tanager-build/track-spikes-72f833/s1_build/` until the board run is done.

## Running it on the board: what you do

### What you need

- The KV260 Starter Kit and its 12 V power supply.
- A microSD card of 16 GB or more.
- An Ethernet cable from the KV260 to the router your PC is on. The board needs the internet once, to install a compiler.
- A micro-USB cable for the serial console (recommended for the first boot).

### One-off setup

1. **Write the Ubuntu image to the microSD card.** Use Ubuntu Desktop 22.04 LTS for Kria from [ubuntu.com/download/amd](https://ubuntu.com/download/amd), file `iot-limerick-kria-classic-desktop-2204-20240304-165.img.xz` ([direct link](https://people.canonical.com/~platform/images/xilinx/kria-ubuntu-22.04/iot-limerick-kria-classic-desktop-2204-20240304-165.img.xz)). The file is several GB. Drive C: has no room for it at the moment, so download it to another drive. Write it with balenaEtcher, which takes the `.img.xz` file directly.
2. **Connect** the Ethernet cable and the micro-USB cable, insert the card and power on. The micro-USB port gives four serial ports on the PC; the console is the second one, at 115200 baud, 8N1, no flow control (PuTTY or Tera Term on Windows).
3. **If Ubuntu does not start** (the console stops before the Ubuntu messages, or the board resets in a loop), the SOM's boot firmware is older than 2022.1, which Ubuntu 22.04 needs. Update it once:
   - Download the newest Kria K26 starter-kit `BOOT.BIN` from the AMD wiki page "Kria SOM Boot Firmware Update" (it needs a free AMD account).
   - Connect the KV260's Ethernet port straight to the PC, and give the PC's Ethernet adapter the fixed address 192.168.0.5, mask 255.255.255.0.
   - Hold the FWUEN button while you power the board on. Open `http://192.168.0.111` in Firefox or Chrome, upload `BOOT.BIN` to image A, and make it the image to boot. Then power-cycle the board.
4. **Log in** as `ubuntu`, password `ubuntu`. Ubuntu asks for a new password at once.
5. **Find the board's address:** `hostname -I`. The examples below write it as `KV260_IP`. Check from the build host (WSL) that `ping KV260_IP` answers.
6. **Install the compiler on the board:**
   ```bash
   sudo apt update && sudo apt install -y build-essential
   ```
7. **Check the boot firmware is kept** (only if you did step 3): `sudo xmutil bootfw_update -v`.

### Each run

1. **Copy the files** from the build host (WSL), replacing `KV260_IP`. The second path is the spikes branch's copy; after the merge, `~/tanager/fpga/spikes/s1/sw` holds the same files.
   ```bash
   B=/home/w/tanager-build/track-spikes-72f833/s1_build
   S=/home/w/tanager/.claude/worktrees/track-spikes-72f833/fpga/spikes/s1/sw
   ssh ubuntu@KV260_IP mkdir -p tg-s1
   scp $B/tg_s1.bit.bin $B/tg_s1.dtbo $B/shell.json $S/tg_s1.c $S/Makefile ubuntu@KV260_IP:tg-s1/
   ```
2. **Install the design as a PL app** (on the board):
   ```bash
   sudo mkdir -p /lib/firmware/xilinx/tg-s1
   sudo cp ~/tg-s1/tg_s1.bit.bin ~/tg-s1/tg_s1.dtbo ~/tg-s1/shell.json /lib/firmware/xilinx/tg-s1/
   sudo xmutil listapps
   ```
   `tg-s1` must be in the list. If it is not, run `sudo systemctl restart dfx-mgr` and list again.
3. **Load it:**
   ```bash
   sudo xmutil unloadapp
   sudo xmutil loadapp tg-s1
   ```
   **Check the fan** right after loading. The fan stays under Linux's control: the design routes the PS timer's PWM to the fan-enable pin (A12) as the default design does, and the overlay leaves the pwm-fan node alone, so the speed follows the temperature (fancontrol: 15/255 at 35 °C, full at 45 °C), not full speed. If the fan stops, run `sudo xmutil unloadapp` at once and tell the spikes track.
4. **Build and run the program:**
   ```bash
   cd ~/tg-s1 && make && sudo ./tg_s1 | tee s1_results.txt
   ```
   With no compiler on the board, use the static binary built on the build host instead (`make -C fpga/spikes/s1/sw cross`, the toolchain that builds tanager-host): copy `tg_s1.aarch64` and run `sudo ./tg_s1.aarch64 | tee s1_results.txt`. `./tg_s1.aarch64 --x` prints the usage line without touching the hardware.
   It takes about a minute. It first checks the engines' ID register (`0x71530001`) and stops with a message if it reads anything else. **Run it only after step 3 has worked:** with no design in the PL, nothing answers at the engines' address and the read can hang the board (power-cycle to recover). Options:
   - `--quick` runs a tenth of the samples.
   - `--mb N` sets the buffer size; the default is 256 MiB of 2 MiB hugepages, which the program reserves itself.
   - `--base ADDR` sets the engines' address, if `address_map.txt` shows something other than `0xA0000000`.
5. **Send back** `s1_results.txt` and the output of:
   ```bash
   dmesg | tail -50
   cat /proc/cmdline
   ls /sys/kernel/iommu_groups/
   ```
   To copy the results to the build host: `scp ubuntu@KV260_IP:tg-s1/s1_results.txt .`
6. **Restore the board's default app** if you use it for other things:
   ```bash
   sudo xmutil unloadapp && sudo xmutil loadapp k26-starter-kits
   ```

## If something goes wrong

| Symptom | Likely cause | What to try |
|---|---|---|
| `ID 0x...` instead of `0x71530001`, or the board hangs at the first register read | Design not loaded, or HPM0 width not applied | Power-cycle if it hangs; `xmutil listapps` (the active app has a non-negative slot); `dmesg` for fpga-manager and afi messages |
| `DECERR` responses | The SMMU blocks PL masters, or the address is outside DDR, or the test's own write stream overwrote the chase's pointers (fixed 2026-10-14: the streams use the last hugepage) | Send the `iommu_groups` listing. The fix is booting with `arm-smmu.disable_bypass=0` or an SMMU-bypass device-tree entry; the plan's carve-out checks start here |
| Hugepage allocation fails | Memory fragmented | `echo 140 \| sudo tee /proc/sys/vm/nr_hugepages` just after boot, or `--mb 64` |
| Timeouts | An engine waits for a response that never comes | Send `dmesg`. It points to the PS port or SMMU setup |

## What the results feed

- **The native latency point** (plan §2.5, §10.1). `tgsim` brackets it at 30 and 60 cycles until S1 replaces the bracket.
- **The KV260 latency injector's base value** (§5.6). The injector adds the target latency minus this native latency.
- **The PS port bandwidth limit.** It shows whether two HP ports cover the L2's streaming (§5.1, E4).
- **The open items of §5.5 S1.** The carve-out method (here: hugepages, no carve-out needed for measurement) and SMMU bypass (the DECERR check).

## Results on the board (2026-10-14)

The board track ran S1 on our KV260 (setup in [fpga/kv260/README.md](../../kv260/README.md#the-board)):
- **Software:** Ubuntu 24.04.2 for Kria, kernel 6.8.0-1015-xilinx, with `mem=3G arm-smmu.disable_bypass=0`.
- **Build:** the fan-routed one (DR-129; bitstream sha256 `fdb8ab2c…`), loaded with `xmutil` as app `tg-s1`. The fan stayed under Linux's control.
- **Records:** the raw output, the two patches below and the run script are in [results/s1_board](../results/s1_board).

**Two fixes went into the run.** The patches as run are in `results/s1_board/`. The spikes track committed both in `ef87de3`. That commit also makes `tg_s1` convert cycles with its measured clock, and warn when the clock is more than 3% off nominal. The board now runs that build (`tg_s1` sha256 `976e2351…`; overlay `99aa4dad…`, the same overlay as the run).
- **The PL clock** (`s1_pl_clock.patch`).
  - **The cause:** the overlay asked for 99,999,001 Hz, Vivado's 99.999 MHz. The board's IOPLL runs at 999,999,990 Hz. ÷10 gives 99,999,999 Hz, just above the request, so the kernel rounded down to ÷11 = 90.9 MHz.
  - **The effect:** the engines ran at 181.8 MHz in the first run. The program's own wall-clock estimate printed 181.7 MHz.
  - **The fix:** asking for 100,000,000 Hz gives ÷10 and 200.0 MHz after the MMCM (199.4 MHz measured).
  - fpga/kv260's overlay already asks for 100,000,000.
- **The loaded-latency chase** (`s1_loaded_chase.patch`).
  - **The cause:** the HP2 write stream wrote into hugepage 1, which held part of the chase.
  - **The effect:** the chase then followed overwritten pointers to unmapped addresses. About two DECERRs per read showed up in the "HP2 writing" and "A53 memcpy" tests.
  - **The fix:** the streams now use the last hugepage, which the chase leaves out.

| Test (200 MHz, 5 ns per cycle, 200,000 samples) | Result |
|---|---|
| Idle latency: dependent 64 B reads, HP1, within 2 MiB | min 29, **avg 36.7**, p50 37, p90 37, p99 107, max 126 cycles (avg 183 ns) |
| The same over the whole 256 MiB / with 16 B reads / on HP2 | avg 36.8 / 36.7 / 36.8 cycles; p99 105–107 |
| Sequential reads, one port, 64 B bursts, by reads outstanding | 1: 0.36 GB/s (30.5 cycles each); 4: 1.43; 8: 2.82; 16: 3.10; 32: **3.20 GB/s** (16.0 B/cycle) |
| The same with 256 B bursts | 1: 1.06; 2: 2.12; 4: 3.08; 8 or more: **3.20 GB/s** |
| Random 64 B reads within 2 MiB | 8: 2.29; 16: 2.99; 32: 3.01 GB/s |
| Writes, 64 B or 256 B bursts, 16 outstanding | 3.20 GB/s |
| Both ports reading at once | 3.18 + 3.18 = **6.35 GB/s** |
| Chase while HP2 reads at 3.2 GB/s | avg 36.9, p90 37, p99 107, max 148 cycles |
| Chase while HP2 writes at 3.2 GB/s | avg 37.7, p90 41, p99 111, max 156 cycles |
| Chase while 4 A53 threads copy memory | avg 36.8, p90 37, p99 99, max 122 cycles |

- **Errors:** no response errors in any test. The kernel logged no SMMU, AXI or FPGA-manager errors.
- **Coverage:** the hugepages spanned PA `0x340_0000`–`0x8_2B80_0000` in the first run and `0x8_2B80_0000`–`0x8_3BE0_0000` in the second, so both ports reached both DDR banks.
- **First run, 181.8 MHz, before the fixes** (`s1_results_181mhz.txt`): idle avg 34.0 cycles = 187 ns, and 16 B/cycle = 2.9 GB/s per port. That agrees with the 200 MHz run once converted to nanoseconds.

**What it means for the plan.**
- **The native latency point** (§2.5, §10.1).
  - **The number:** about 37 cycles at 200 MHz (184 ns) idle at the PL port. The minimum is 29; the p99 is about 105, probably from refresh and page conflicts.
  - **Row hits:** sequential reads with one outstanding take 30.5 cycles.
  - **Against the model:** `tgsim`'s bracket of 30 and 60 cycles has the KV260 near its low end.
  - **The L2's view** adds the uncore path (window and injector); bring-up step 4 of fpga/kv260 measures it.
- **The injector's base** (§5.6): the injector adds the target latency minus this native latency, about 37 cycles.
- **Port bandwidth** (§5.1, E4).
  - **The limit:** each HP port is limited by its PL side, 16 B per cycle or 3.2 GB/s at 200 MHz, not by the DDR. Two ports together reach 6.35 GB/s.
  - **What saturates a port:** about 16 64 B lines in flight; 8 give 88%. With 256 B bursts, 4–8 in flight.
  - **For the L2:** a port delivers at most one 64 B line every 4 cycles, and only with about 16 misses in flight on that port.
- **Loaded latency:**
  - a saturated neighbouring port adds 0.2 cycles on average when it reads and 1.0 when it writes (p90 37 → 41);
  - four A53 cores copying memory add nothing measurable.
- **DR-102, the verdict:**
  - **Carve-out: confirmed.** With `mem=3G`, Linux RAM ends at `0x8_3FFF_FFFF`, and `/dev/mem` maps `0x8_4000_0000` but refuses Linux RAM. S1 itself measures in hugepages and does not use the carve-out.
  - **SMMU bypass: not needed on this image.** The kernel has no MMU-500 driver and the device tree disables the SMMU. Both ports reached both DDR banks at full bandwidth with no DECERR. `arm-smmu.disable_bypass=0` stays on the command line as a harmless guard.
