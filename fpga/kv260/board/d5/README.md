# D5: GEM3 Ethernet owned by the RISC-V in RISC-V mode (2026-10-19 on)

The SoC track's plan is `docs/spec/soc-d5-gem3.md` (soc-2's branch, 591a956). In RISC-V mode, the RISC-V's Debian takes the board's Ethernet port with Debian's own drivers (`macb`, `dp83867`, `phylink`). There is no PL change: only the RISC-V mode tree and `riscv.scr` change.

## Step 0: read-only probes in ARM mode: done (2026-10-19)

- **Run:** [`../runs/d5_step0.sh`](../runs/d5_step0.sh) in Ubuntu at 17:55 UTC, with `k26-starter-kits` loaded, between two segments of s16. Nothing was written.
- **Raw output:** [`step0_probe.txt`](step0_probe.txt).
- **PS register reads:** all five went through `busybox devmem`, not `tanager-host psrd` as the plan's row says. psrd first reads the PL host bridge's ID, and with no Tanager bitstream loaded that read hangs the board (the coordinator's correction).

**eth0:**
- `macb` on `ff0e0000.ethernet`, MAC `00:0a:35:2a:df:d8`, `192.168.137.177/24`.
- **The link is 1000 Mb/s, full duplex** (auto-negotiated, PHY at address 1). The link partner advertises 10/100 half and full, and 1000baseT/Full. D5 needs this, since the RISC-V's transmit clock is fixed at 125 MHz.

**The clocks** (`clk_summary`), with IOPLL at 999,999,990 Hz:

| GEM3's clock | The CCF's clock | Rate |
|---|---|---|
| `pclk` | `lpd_lsbus` | 99,999,999 Hz |
| `hclk` | `gem3_ref` (IOPLL / 8) | 124,999,999 Hz |
| `tx_clk` | `gem3_tx` | 124,999,999 Hz |
| `rx_clk` | `gem3_rx` | 0: a root clock, RGMII's RXC from the PHY |
| `tsu_clk` | `gem_tsu` (IOPLL / 4) | 249,999,998 Hz |

The SoC track's step 1 tree has 124,999,998 and 249,999,997 Hz. That's 1 Hz off each, from rounding IOPLL's rate.

**The PS registers:**

| Register | Value | Meaning |
|---|---|---|
| CRL_APB `GEM3_REF_CTRL` (`0xFF5E005C`) | `0x06010800` | CLKACT and RX_CLKACT set, DIVISOR1 1, DIVISOR0 8, SRCSEL IOPLL: 125 MHz |
| CRL_APB `RST_LPD_IOU0` (`0xFF5E0230`) | `0x00000007` | GEM0–2 held in reset; GEM3 (bit 3) out of reset |
| IOU_SLCR `MIO_PIN_38` (`0xFF180098`) | `0x00000000` | GPIO |
| GPIO `DATA_1_RO` (`0xFF0A0064`) | `0x000613C0` | Bank 1 bit 12 (MIO38) is 1: the PHY is out of reset |
| GEM3 `DCFG6` (`0xFF0E0294`) | `0x02D10002` | GEM3's design configuration (the plan reads it for 64-bit DMA) |
