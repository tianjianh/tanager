# D5: GEM3 Ethernet owned by the RISC-V in RISC-V mode (plan)

For the coordinator, before any change (soc-2, 10-19). After D4 (DR-172, [soc-d4-modes.md](soc-d4-modes.md)), the RISC-V's Debian gets the board's Ethernet port in RISC-V mode, with Debian's own drivers: `macb` (the Cadence GEM), `dp83867` (the PHY) and `phylink`. Debian's riscv64 kernel has all three as modules.

## What the board has

From the A53's live tree (`fpga/kv260/board/d4/fdt-live.dtb`):
- **GEM3:** at `0xFF0E0000`, `xlnx,zynqmp-gem`, `phy-mode = "rgmii-id"`.
  - Two queue interrupts on one line (SPI 63).
  - Clocks `pclk`, `hclk`, `tx_clk`, `rx_clk`, and `tsu_clk` (assigned 250 MHz).
- **The PHY:** a TI DP83867 at MDIO address 1, on GEM3's own MDIO bus.
  - Properties: `ti,rx-internal-delay = <8>`, `ti,tx-internal-delay = <10>`, `ti,fifo-depth = <1>`, `ti,dp83867-rxctrl-strap-quirk`.
  - Its reset is MIO38, active low (100 µs asserted, 280 µs to wait after).

## What D5 needs, and what it doesn't

- **No PL change, no board build:**
  - The PS window already passes GEM3's 64 KiB (D1).
  - GEM3's PS-to-PL interrupt already reaches PLIC source 22 (D1).
  - Its DMA reaches the RISC-V's RAM the way SD1's does (D4 step 6: "ADMA 64-bit"): bus address `0x5_0000_0000` + offset through HPM1 and the host DMA port, coherent with the L2, by the tree's `dma-ranges`.
- **The RISC-V mode tree** (`sw/dts`, a new `ETH=1`, on top of `UART1=1 UART1_STDOUT=0 SD1=1 BOARD_RESET=1`). GEM3 goes under the same `ps-dma-bus` as SD1, with:
  - `xlnx,zynqmp-gem` and `rgmii-id`;
  - `interrupts = <22>, <22>`: macb asks for one interrupt per queue, and GEM3 has two;
  - fixed clocks at the rates step 0 reads (`pclk` sets the MDIO clock divider; `tx_clk` 125 MHz; `tsu_clk` 250 MHz);
  - no `resets` and no `power-domains`: macb's ZynqMP setup then calls nothing outside the GEM, as SD1's driver doesn't;
  - an `mdio` node with the DP83867 and its properties, without `reset-gpios`;
  - `local-mac-address`, the A53's own `eth0` address. The two modes never run together, so the DHCP server gives the RISC-V the board's usual lease.
- **The PHY's reset:** `riscv.scr` drives MIO38 high before the park, through GPIO bank 1 bit 12.
  - Registers: `DIRM_1 0xFF0A0244`, `OEN_1 0xFF0A0248`, `MASK_DATA_1_LSW 0xFF0A0008 = 0xEFFF1000`.
  - That is the same kind of write as `pl_resetn0`'s, which works (step 5).
  - Linux on the RISC-V can't reach the PS GPIO (it isn't in the PS window), so the tree has no PHY reset.
- **Debian:** no change. `macb`, `dp83867` and `phylink` are Debian modules, loaded by udev from the tree's compatibles. networkd's `80-tanager.network` already runs DHCP on any Ethernet interface (`Type=ether`), so stage C's network setup serves here too. sshd is installed, with the board session's key.
- **ARM mode:** unchanged. Only the RISC-V mode tree and `riscv.scr`, both under `p1:/tanager/`, change.

## The one limitation: 1 Gb/s only

On ZynqMP, GEM3's RGMII transmit clock comes from the PS (CRL_APB `GEM3_REF_CTRL`): 125 MHz at 1 Gb/s, 25 MHz at 100 Mb/s, 2.5 MHz at 10 Mb/s. macb retunes it through the clock framework when the link speed changes. On the RISC-V that clock is a fixed one at the rate the boot firmware set, so:
- At 1 Gb/s it is right. clk_set_rate to the same rate is a no-op.
- At 100 or 10 Mb/s, macb warns ("unable to generate target frequency") and transmit would fail.

So D5 needs a gigabit link partner. Step 0 reads the link speed under Ubuntu. Lifting the limit would take a clock driver that writes `GEM3_REF_CTRL` through the PS window. That is not in Debian's kernel, so it would be another out-of-tree module, the user's call as in DR-168. It's not planned.

## Steps

| # | Step | Test |
|---|---|---|
| 0 | Read-only probes in ARM mode (the board session) | `ip link show eth0` (the MAC), `ethtool eth0` (speed, duplex: it must be 1000/Full). The clock rates of GEM3's five clocks and `lpd_lsbus` (`/sys/kernel/debug/clk/clk_summary`). `tanager-host psrd`: CRL_APB `GEM3_REF_CTRL` (`0xFF5E005C`) and `RST_LPD_IOU0` (`0xFF5E0230`, GEM3 out of reset), IOU_SLCR `MIO_PIN_38` (`0xFF180098`, GPIO). `busybox devmem`: GPIO bank 1's `DATA_1_RO` (`0xFF0A0064`) and GEM3's `DCFG6` (`0xFF0E0294`, 64-bit DMA) |
| 1 | The tree (`ETH=1`) and `riscv.scr`'s PHY release; unit check | dtc builds it, and every existing tree is byte-identical. `sw/d4mode/hook_qtest.sh`'s dry run covers the new `riscv.scr` lines. **Done (10-19):** `ETH=1 ETH_MAC=…`, GEM3 under `ps-dma-bus` (interrupts `<22>, <22>`), `gem3_ref` at 124,999,998 Hz and `gem_tsu` at 249,999,997 Hz (IOPLL / 8 and / 4, to be checked against step 0); `riscv.scr` pulses MIO38 low for 10 ms; 6 existing trees byte-identical, `hook_qtest.sh` 8 of 8 |
| 2 | RISC-V mode with Debian, as D4's step 6 with the new tree and `riscv.scr` | On COM5: `macb ff0e0000.ethernet eth0: Cadence GEM rev ...`, the DP83867 found at address 1, "Link is Up - 1Gbps/Full", a DHCP lease. Then from the laptop: ping and SSH into the RISC-V's Debian over Ethernet. Throughput: `scp` of a 100 MB file both ways and `apt-get update`, against stage C's virtio-net (1.3 MB/s, guest-bound). The reboot and the return to ARM mode as in D4 |

Every failure ends as in D4: Ethernet plays no part in booting. Debian comes up without a network, and the console on COM5 shows why. `tanager-mode arm` and a reboot, or the break, gives Ubuntu.

## What stays from D4

All of it: the mode record, the hook, `riscv.scr` (one block added), U-Boot d4, Debian's confirm unit, the PMOD break, the d4s2 bitstream (until the final D4 build from main).
