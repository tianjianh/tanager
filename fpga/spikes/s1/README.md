# Spike S1: PL → PS DDR latency and bandwidth on the KV260

S1 measures what the L2 will see when it misses: the latency and bandwidth of the PS DDR4 through the S_AXI_HP ports, from the programmable logic, at the 200 MHz core clock (plan §2.1, §5.5). The result sets the KV260's native latency point (plan §2.5); it does not change any size.

## What is in this directory

| Path | What it is |
|---|---|
| `rtl/tg_s1_engine.sv` | One measurement engine: an AXI4 master (128-bit, 49-bit addresses, 6-bit IDs) that issues pointer-chase reads, or read or write streams with up to 32 outstanding bursts. It keeps per-transaction latency, a 256-bin histogram, cycles and bytes. |
| `rtl/tg_s1_top.sv`, `rtl/tg_s1_bd.v` | Two engines (on HP1 and HP2), their AXI4-Lite registers at `0xA000_0000`, and the KV260 fan held on. `tg_s1_bd.v` is the Verilog wrapper the block design instantiates. |
| `build.tcl` | Builds the bitstream. It creates the block design: the PS with the KV260 SOM preset, `pl_clk0` 100 MHz → MMCM → 200 MHz for HPM0 (128-bit, SmartConnect to AXI-Lite), HP1 and HP2 (128-bit). |
| `tg_s1.xdc` | The fan pin (A12, LVCMOS33). |
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
tools/vivado_run.sh $TANAGER_BUILD/track-spikes-72f833/s1_build fpga/spikes/s1/build.tcl $PWD
```

The output, in that directory, is `tg_s1.bit.bin`, `tg_s1.dtbo`, `shell.json`, `address_map.txt` and the timing and utilisation reports. The run takes about 20 minutes.

## Running it on the board: what you do

The board needs the standard Kria Ubuntu image (22.04 or 24.04 for Kria), booted, with network access from the build host. Steps 1–3 are one-off.

1. **Install the tools on the board:**
   ```bash
   sudo apt install -y build-essential
   ```
2. **Copy the files from the build host to the board** (replace `kv260` with the board's address):
   ```bash
   B=~/tanager-build/track-spikes-72f833/s1_build
   ssh ubuntu@kv260 mkdir -p tg-s1
   scp $B/tg_s1.bit.bin $B/tg_s1.dtbo $B/shell.json ~/tanager/fpga/spikes/s1/sw/tg_s1.c ~/tanager/fpga/spikes/s1/sw/Makefile ubuntu@kv260:tg-s1/
   ```
3. **Install the PL app on the board:**
   ```bash
   sudo mkdir -p /lib/firmware/xilinx/tg-s1
   sudo cp ~/tg-s1/tg_s1.bit.bin ~/tg-s1/tg_s1.dtbo ~/tg-s1/shell.json /lib/firmware/xilinx/tg-s1/
   ```
4. **Load the design.** `xmutil listapps` must show `tg-s1`.
   ```bash
   sudo xmutil unloadapp
   sudo xmutil loadapp tg-s1
   ```
   **Check that the fan is spinning** right after loading. The design drives the fan-enable pin (A12) low, which should turn the fan on. If the fan stops, run `sudo xmutil unloadapp` at once and tell the spikes track.
5. **Build and run the program:**
   ```bash
   cd ~/tg-s1 && make && sudo ./tg_s1 | tee s1_results.txt
   ```
   It takes about a minute. `--quick` runs a tenth of the samples. `--mb N` sets the buffer size; the default is 256 MiB of hugepages.
6. **Send back** `s1_results.txt`, and the output of these:
   ```bash
   dmesg | tail -50
   cat /proc/cmdline
   ls /sys/kernel/iommu_groups/
   ```
7. **Restore the board's default app** if you use it for other things:
   ```bash
   sudo xmutil unloadapp && sudo xmutil loadapp k26-starter-kits
   ```

## If something goes wrong

| Symptom | Likely cause | What to try |
|---|---|---|
| `ID 0x...` instead of `0x71530001` | Design not loaded, or HPM0 width not applied | `xmutil listapps`; `dmesg` for fpga-manager and afi messages |
| `DECERR` responses | The SMMU blocks PL masters, or the address is outside DDR | Send the `iommu_groups` listing. The fix is booting with `arm-smmu.disable_bypass=0` or an SMMU-bypass device-tree entry; the plan's carve-out checks start here |
| Hugepage allocation fails | Memory fragmented | `echo 140 \| sudo tee /proc/sys/vm/nr_hugepages` just after boot, or `--mb 64` |
| Timeouts | An engine waits for a response that never comes | Send `dmesg`. It points to the PS port or SMMU setup |

## What the results feed

- **The native latency point** (plan §2.5, §10.1). `tgsim` brackets it at 30 and 60 cycles until S1 replaces the bracket.
- **The KV260 latency injector's base value** (§5.6). The injector adds the target latency minus this native latency.
- **The PS port bandwidth limit.** It shows whether two HP ports cover the L2's streaming (§5.1, E4).
- **The open items of §5.5 S1.** The carve-out method (here: hugepages, no carve-out needed for measurement) and SMMU bypass (the DECERR check).
