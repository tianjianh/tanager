# Stage D's D0 probes on sc3 (2026-10-17)

**What D0 is:** cheap board probes before any stage D RTL ([`soc.md`](../../../../docs/spec/soc.md) §8.2, "Order of work"). One answer could change D-c, the plan that has the PS's controllers (SD, GEM, USB) reach the RISC-V's memory through the host DMA port.
- **Tools:** the SoC track's package `d0-probes-20261017` ([`package_README.txt`](package_README.txt)): sc3's `tanager-host` plus `dma adma` and `psrd` (`5bdd24e3…`).
- **The coordinator's conditions, all kept:**
  - sc3 loaded for every `tanager-host` call;
  - read-only on PS state, except the ADMA copies, which stay inside the RISC-V's carve-out;
  - fan control with the A53's `fancontrol` throughout (pwm 15/255, 33–35 °C).
- **Files:**
  - [`d0_part1.txt`](d0_part1.txt): the A53's read-only facts;
  - [`d0_run.txt`](d0_run.txt): the register reads and the ADMA probe, from [`../runs/d0_run.sh`](../runs/d0_run.sh);
  - [`d0_run1_refused.txt`](d0_run1_refused.txt): the first try, which `tanager-host` refused safely (below).

## Part 1: what the A53's boot leaves (read-only)

| Block | State |
|---|---|
| **SMMU** | `iommu@fd800000` (`arm,mmu-500`) is `disabled` in the live tree. No IOMMU groups, `/sys/class/iommu` empty, no `arm_smmu` module. The kernel prints "Default domain type: Translated", but no IOMMU registers; the command line has `arm-smmu.disable_bypass=0`. **No PS master is translated:** the ADMA reached physical addresses. |
| **UART** | UART0 (`ff000000`) disabled, clock off. UART1 (`ff010000`) okay: the A53's console, 100 MHz, interrupt 54 in use. |
| **TTC** | TTC0 (`ff110000`) okay: the fan's PWM, `pwm-fan` `pwms = <&ttc0 2 40000 1>` (25 kHz). **TTC1 (`ff120000`) is disabled**, with no interrupt in use; TTC2 and TTC3 are disabled too. They are clocked by `lpd_lsbus` (100 MHz, on). |
| **SD** | **SD0 (`ff160000`, the eMMC) disabled, and there is no `mmcblk0`: no eMMC.** SD1 (`ff170000`) okay: the card (`mmc1`, type SD), 166.7 MHz. |
| **GEM3** | `ff0e0000` okay, `rgmii-id`, 125 MHz (TSU 250 MHz), interrupt 95. **PHY:** `ethernet-phy@1`, so MDIO address 1, `ethernet-phy-id2000.a231` (DP83867). Reset `<&gpio 38 active-low>` (MIO38), assert 100 µs, deassert 280 µs. `ti,rx-internal-delay` 8, `ti,tx-internal-delay` 10, `ti,fifo-depth` 1, `ti,dp83867-rxctrl-strap-quirk`. |
| **USB0** | `ff9d0000` (`xlnx,zynqmp-dwc3`) okay, reset `<&modepin 1 active-low>` (zynqmp-firmware's mode-pin GPIO). dwc3 at `fe200000`: bus clock 250 MHz, ref 20 MHz, interrupt 97. **USB5744 hub:** `hub@1` (`usb424,2744`) and `hub@2` (`usb424,5744`), reset `<&gpio 44 active-low>` (MIO44); its I2C side `usb-hub@2d` on `i2c@ff030000`. USB1 is disabled. |
| **ADMA** | 8 channels (`ffa80000`–`ffaf0000`), bound to `xilinx-zynqmp-dma`, runtime-suspended. Their power domain is off and `adma_ref` (500 MHz) is gated while idle. No ADMA interrupt is in use. |
| **Interrupts in use** | UART1 54, SPI1 52, I2C1 50, QSPI 47, GEM3 95, USB0 97, SD1 81, DisplayPort's DMA 154 and display 151. |

**PS registers** (`tanager-host psrd`, sc3 loaded):

| Register | Value | Meaning |
|---|---|---|
| CRL_APB `RST_LPD_TOP` (`0xFF5E023C`) | `0x00000A93` | **Bit 19, AFI FM6's reset, is clear: S_AXI_LPD's AFI is out of reset**, which D1 needs. The set bits are 0, 1 and 4 (by UG1087: the RPU's two cores and its power gating) and 7, 9 and 11 (USB1's core, hibernation and APB resets; USB1 is unused). USB0's bits 6, 8 and 10 are clear. |
| LPD XPPU `CTRL` (`0xFF980000`) | bus error | The XPPU's registers refuse a non-secure reader such as the A53's Linux, so its enable bit can't be read from here. `psrd` caught the refusal. |
| AFI FM6 `RDCTRL` (`0xFF9B0000`) | `0x000003B0` | The register's reset value. **FABRIC_WIDTH [1:0] = 0, i.e. 128-bit.** sc3 doesn't use S_AXI_LPD, and its overlay doesn't set FM6. |
| AFI FM6 `WRCTRL` (`0xFF9B0014`) | `0x000003B0` | The same. |

- **The order:** `RST_LPD_TOP` was read first, and the AFI's registers only after it showed the AFI out of reset.
- **For D1:** its overlay's AFI node must set FM6's read and write width to the port's width (for a 32-bit port, `[1:0] = 2`).

## Part 2: the ADMA probe: an LPD master reaches the host DMA port

**The setup:**
- sc3 loaded, then `tanager-host load` (sc3's images; the cores held), so the RISC-V's RAM window is set;
- ADMA channel 8 kept powered for the probe (`power/control` `on`, `runtime_status` `active`), and set back to `auto` afterwards.

`tanager-host dma adma` (defaults: channel `0xFFAF0000`, 4 KiB, the RAM's last MiB):

| Copy | Result |
|---|---|
| DDR `0x8_7FF0_1000` → HPM1 `0x5_3FF0_0000` (RISC-V `0xBFF0_0000`) | **ok**: ISR `0x404` (done and descriptor done, no error bits), 17 µs, 0 words wrong. The port wrote 64 lines (4 KiB). |
| HPM1 `0x5_3FF0_0000` → DDR `0x8_7FF0_2000` | **ok**: ISR `0x404`, 11 µs, 0 words wrong. The port read 64 lines; 0 write bursts dropped; channel `STATUS` 0. |

- **The port's totals** (`dma status`): 576 line writes and 576 line reads. That is the ADMA's 64 of each, plus the A53's own 512 of each (8-byte stores and loads through HPM1 to clear and compare the target).
- **Afterwards:** dmesg had nothing about DMA, the SMMU or bus errors, and `k26-starter-kits` came back.

**So D-c's premise holds:** an LPD master (the ADMA, like the IOU's SD, GEM and USB controllers) writes and reads the RISC-V's memory through HPM1 and the host DMA port, at physical addresses, with the AFI and the port as sc3 leaves them.

**Not covered here:** soc.md's second half of D0.1, "a RISC-V program that held the line in its cache must read the new bytes". The package's probe keeps the cores held. In simulation, the coherence suite's `dma` mode covers external writes against the cores' caches.

**The first try** ([`d0_run1_refused.txt`](d0_run1_refused.txt)):
- I had skipped the package's `tanager-host load` step, so the RAM-size register still read 0.
- `dma adma` then refused ("OFF + 3 * BYTES is beyond the RISC-V's RAM (0x0)") before touching the channel.
- Nothing was copied (the port's counters were 0), and the channel went back to `auto`.
