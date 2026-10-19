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

**Extras from the SoC track's resent list** (read at 18:11 in Ubuntu):
- GPIO `DIRM_1` and `OEN_1` (`0xFF0A0244`, `0xFF0A0248`) are both `0x00041000`: MIO38 (bit 12) is an enabled output under Linux.
- GEM3 `DCFG1` (`0xFF0E0280`) is `0x0450011C`.
- Ubuntu's dmesg: `macb ff0e0000.ethernet eth0: Cadence GEM rev 0x50070106 … (00:0a:35:2a:df:d8)`, the `TI DP83867` at address 1, `Link is Up - 1Gbps/Full`.

## Step 2, first attempt: a 1 Gb/s link, but no frames either way; GEM3's clocks as U-Boot leaves them (2026-10-19)

**The package:** the SoC track's `d5-step2` ([`package_d5_step2_README.md`](package_d5_step2_README.md); tarball `bef9a5e6…`). It is step 6's package on d4s2, with two changes:
- `riscv.scr` (`1c76ec0c…`) takes the PHY out of reset: MIO38 low for 10 ms, then high;
- `tanager.dtb` (`45ba89a9…`) has `ETH=1`: GEM3, its DP83867, and the A53's MAC.

**How:**
- p1 installed ([`step2a_run.txt`](step2a_run.txt)). For the planned SSH test, the laptop's board key went into p3's `/home/tanager/.ssh/authorized_keys` (see the change log).
- The record set to riscv, a reboot at 18:12:07 UTC.
- Records: COM5 ([`uart_COM5_step2a.txt`](uart_COM5_step2a.txt), every session in order) and the A53's U-Boot on COM7 ([`uart_COM7_step2a_uboot.txt`](uart_COM7_step2a_uboot.txt)).

**What came up:**
- At 34.6 s: `macb ff0e0000.ethernet eth0: Cadence GEM rev 0x50070106 at 0xff0e0000 irq 13 (00:0a:35:2a:df:d8)`.
- At 128 s: `PHY [ff0e0000.ethernet-ffffffff:01] driver [TI DP83867] (irq=POLL)`, `rgmii-id`.
- At 131 s: **`eth0: Link is Up - 1Gbps/Full - flow control off`**.
- Debian logged in at 18:15:11. So the GEM's registers, its interrupt, MDIO and the PHY all work.

**What didn't:**
- eth0 got no IPv4 address, only `fe80::20a:35ff:fe2a:dfd8/64`. networkd stayed `degraded (configuring)`, and `ping` said "Network is unreachable".
- **Linux's counters:** RX 0 packets and 0 errors of every kind (CRC, frame, length, FIFO, missed); TX 47 packets, 0 errors. eth0's interrupt fired once per transmit completion (23 at the time).
- **The laptop's adapter** (Realtek USB GbE at 1 Gb/s, `192.168.137.1`) received **0 bytes, 0 discarded, 0 errors** while the board sent 13 frames (`networkctl reconfigure eth0`). Nothing usable reached the wire.
- Debian has neither ethtool nor busybox, so GEM3's own counters couldn't be read there.
- **The trees agree on the PHY:** GEM3's and the DP83867's nodes (delays 8 and 10, FIFO depth 1, the RX_CTRL strap quirk, `rgmii-id`) match the A53's live tree. The RISC-V tree leaves out `pinctrl`, `resets`, `power-domains` and the assigned clock rate, and gives hclk, tx_clk and rx_clk one fixed 125 MHz clock.

**The cause: GEM3's clocks.** I stopped the A53's U-Boot at its prompt on COM7 in ARM mode, the state `riscv.scr` runs in and hands to the RISC-V, and read:

| Register | U-Boot | Ubuntu (step 0) |
|---|---|---|
| CRL_APB `GEM3_REF_CTRL` (`0xFF5E005C`) | **`0x02011800`**: CLKACT 1, **RX_CLKACT 0**, **DIVISOR0 24** (IOPLL / 24 = 41.7 MHz) | `0x06010800`: RX_CLKACT 1, DIVISOR0 8 (125 MHz) |
| CRL_APB `RST_LPD_IOU0` (`0xFF5E0230`) | `0x00000007` (GEM3 out of reset) | the same |
| IOU_SLCR `GEM_CLK_CTRL` (`0xFF180308`) | `0x00000000` | |
| IOU_SLCR `MIO_PIN_64`–`75` | `0x00000002` each (GEM3) | |
| IOU_SLCR `MIO_PIN_76`, `77` | `0x000000C0` (MDIO) | |
| IOU_SLCR `GEM_CTRL` (`0xFF180360`) | `0x00000000` | |

So in RISC-V mode, GEM3's receive clock is gated off, and its RGMII transmit clock runs at 41.7 MHz instead of 1 Gb/s's 125 MHz. In ARM mode, Linux's clock framework sets 125 MHz and ungates RX when macb probes (Ubuntu reads `0x06010800` again after this boot). The A53's U-Boot does the same only if it starts its own network.

**The fix** (sent to the SoC track): `riscv.scr` writes `GEM3_REF_CTRL = 0x06010800` before the park, beside its `PL0_REF_CTRL` write, and checks it.

**Back to ARM mode:** `tanager-mode arm` and Debian's reboot. Ubuntu is up, and s17 (d4s2 in stage C) runs while the fix comes.
