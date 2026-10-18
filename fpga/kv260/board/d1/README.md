# Stage D's first milestone D1 on the board: the RISC-V reaches the PS's peripherals: pass (2026-10-17)

**What D1 is:** the first step of stage D ([`soc.md`](../../../../docs/spec/soc.md) §8.2). The RISC-V reads and writes the PS's peripheral registers through the PS window (an AXI4-Lite master into S_AXI_LPD), with their interrupts on PLIC 20–24. No handover: the A53's Linux keeps running.

**The package:** `d1-smt2-c2-100` from the SoC track, commit `a4bc643` ([`package_README.txt`](package_README.txt), [`summary.txt`](summary.txt), [`SHA256SUMS`](SHA256SUMS)).
- **The bitstream** (`17d00488…`): sc3's configuration (two `smt2` cores at 100 MHz, the virtio window and the host DMA port, the trace, the PMOD console, the fan per DR-129) plus `TG_PS_WINDOW=1`.
  - WNS +0.650 ns, with a 1.0 ns place-and-route uncertainty; 110,980 LUTs (94.8%).
- **The tools:** `tanager-host` `5bdd24e3…` (as D0's); `ps_d1.bin`, the bare-metal test.
- **How it ran:** the app `tanager-d1`, [`../runs/d1_run.sh`](../runs/d1_run.sh). Every `tanager-host` call checks first that the app holds the PL. Fan control stayed with the A53's `fancontrol` (pwm 15/255, 31–33 °C).
- **The coordinator's conditions (DR-158), all kept:**
  - only blocks D0 found clocked;
  - the interrupt test on a block the A53 doesn't use (TTC1);
  - UART1, the A53's console: only its status and FIFO are touched;
  - the fan stays with the A53.

## Step 0: read-only pre-checks ([`d1_pre.txt`](d1_pre.txt), and again in [`d1_test.txt`](d1_test.txt))

| Register | Value | Meaning |
|---|---|---|
| AFI FM6 `RDCTRL` / `WRCTRL` (`0xFF9B0000` / `0xFF9B0014`) | `0x000003B0` each | FABRIC_WIDTH [1:0] = 0, 128-bit, as the overlay sets it |
| CRL_APB `RST_LPD_IOU2` (`0xFF5E0238`) | `0x000103AA` | **TTC1's reset (bit 12) is clear.** The set bits, 1, 3, 5, 7, 8, 9 and 16, are UART0, SPI0, SD0, CAN0, CAN1, I2C0 and NAND, none of which the A53 uses. Every block D0 found in use reads clear: QSPI 0, UART1 2, SPI1 4, SD1 6, I2C1 10, TTC0 11, the watchdog 15, the ADMA 17, GPIO 18. TTC2 and TTC3 are clear too. |

- **The decode:** UG1087's field layout as I recall it. AMD's online pages render in the browser and could not be fetched. The live value fits that layout bit for bit against the blocks Linux uses and doesn't.

## Step 1: `ps_d1` ([`d1_test.txt`](d1_test.txt))

`tanager-host load --fw ps_d1.bin --kernel /dev/null --dtb /dev/null`, then `tanager-host run --timeout 10`. The RISC-V's console:

```
tanager D1: the PS window
UART1 SR 0000000a
UART1: line written
IOU_SLCR MIO_PIN_36 000000c0, SD_ITAPDLY 012a0000, SD_OTAPDLYSEL 00050000
TTC1: interrupt after 00000335 ticks of 10 MHz, ISR 00000001
denied: TTC0 and UART0 fault
D1 PASS

[tanager-host] tohost 0x1: PASS
```

**On the A53's own serial console** (COM7, [`uart_COM7_d1.txt`](uart_COM7_d1.txt)), between the overlay's load and unload messages:

```
[tanager RISC-V] hello from the RISC-V, through the PS window
```

- **TTC1's interrupt** reached the RISC-V through the PS-to-PL line and the PLIC after 821 ticks of the 10 MHz timer (82 µs).
- **The window's allow-list** refused TTC0 (the fan's) and UART0 with a fault, as designed.

## Step 2: the A53 is unaffected

- **dmesg:** no new line between the test's start and its end (no SError, no UART error).
- **UART1's driver** (`/proc/tty/driver/xuartps`): `tx:49 rx:0` before and after, with no error counts. The RISC-V's line went straight into the FIFO.
- **The console:** `serial-getty@ttyPS1` is active before and after.
- **The fan:** `fancontrol` active, pwm 15/255 throughout. Then `k26-starter-kits` came back.

**So D1's milestone is met on the board:**
- the RISC-V reads and writes the PS's peripherals (UART1, IOU_SLCR, TTC1) through S_AXI_LPD;
- it takes a PS peripheral's interrupt;
- the window refuses what it must;
- the A53's Linux, its console and the fan carry on undisturbed.
