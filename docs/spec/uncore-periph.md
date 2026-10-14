# MMIO peripherals (`tg_aclint`, `tg_plic`, `tg_uart`, `tg_bootrom`)

Status: draft — soc track — 2026-10-13

## Common interface

ACLINT, PLIC, UART and the host-control block sit behind the device bus (`tg_tl_dev`, [uncore.md](uncore.md)). Each takes one register access at a time:

| Signal | Meaning |
|---|---|
| `req_valid` | an access this cycle (the device is selected by address) |
| `req_addr` | byte offset inside the device's window |
| `req_we`, `req_wdata[63:0]`, `req_be[7:0]` | write data and byte strobes, in address lanes |
| `req_size` | log2 bytes (0 … 3) |
| `rsp_rdata[63:0]`, `rsp_err` | valid in the cycle after `req_valid` |

Registers are naturally aligned. A register narrower than the access returns zero in the other bytes. Writes honour the byte strobes, so 32-bit software (RV32-style `mtime` accesses) works. `rsp_err` (→ `denied`) is used only for accesses outside a device's implemented registers when the device's spec calls them errors; otherwise reserved space reads 0 and ignores writes, as the PLIC and ACLINT specs allow.

---

## ACLINT (`tg_aclint`)

### Purpose
Machine software interrupts and the machine timer for every hart, at `ACLINT_BASE` (`0x0200_0000`, 64 KiB), in the legacy CLINT-compatible layout (plan §5.4). The device tree calls it `riscv,clint0`, which OpenSBI's MSWI and MTIMER drivers accept. It also broadcasts `mtime` to the cores (interfaces.md §3).

### Interface
Device-bus port; `irq_msi_o[NUM_HARTS]`, `irq_mti_o[NUM_HARTS]`, `mtime_o[63:0]`. Hart index = `mhartid`.

### Behaviour
| Offset | Register | Notes |
|---|---|---|
| `0x0000 + 4h` | `msip[h]` | bit 0 RW, other bits 0; `irq_msi_o[h] = msip[h]` |
| `0x4000 + 8h` | `mtimecmp[h]` | 64-bit RW, reset all ones |
| `0xBFF8` | `mtime` | 64-bit RW, reset 0 |

- **Tick:** `mtime` increments at `TIMEBASE_HZ` (10 MHz, `tg_map_pkg`) from `clk`, by a phase accumulator: `acc += TIMEBASE_HZ` every cycle; on `acc ≥ CLK_HZ`, `acc -= CLK_HZ` and `mtime++`. The average rate is exact for any `CLK_HZ ≥ TIMEBASE_HZ`; jitter is one `clk` period.
- **Outputs:** `irq_mti_o[h] = (mtime ≥ mtimecmp[h])`, registered. A write to `mtime` or `mtimecmp` takes effect on the next compare.
- **Width:** harts beyond `NUM_HARTS` read 0 and ignore writes.

### Parameters
`N_HARTS` (= `NUM_HARTS`), `CLK_HZ` (SoC parameter: the core clock, from `tanager_soc`).

### Timing and area
`N_HARTS` 64-bit comparators and one 64-bit incrementer. About 400 LUTs and 400 FFs at 4 harts. Everything is registered.

### Verification
`tests/unit/aclint`: tick rate over 10⁶ cycles (exact count), compare and interrupt timing, 32- and 64-bit accesses, the msip bits, writes to `mtime`.

### Provenance
RISC-V ACLINT specification v1.0 (MSWI and MTIMER devices, CLINT-compatible layout). Implemented as written.

---

## PLIC (`tg_plic`)

### Purpose
The platform-level interrupt controller at `PLIC_BASE` (`0x0C00_0000`, 64 MiB), compatible `riscv,plic0`. Each hart has two contexts: context `2h` (M-mode) drives `irq_mei[h]` and `2h+1` (S-mode) drives `irq_sei[h]` (interfaces.md §3, plan §5.4).

### Interface
Device-bus port; `src_i[N_SRC-1:1]`; `irq_o[N_CTX]` with `N_CTX = 2 × NUM_HARTS`.

### Behaviour
| Offset | Register |
|---|---|
| `0x000000 + 4s` | priority of source `s` (`PRIO_W` = 3 bits; 0 = never) |
| `0x001000` | pending bits, sources 0 … 31 (read-only) |
| `0x002000 + 0x80·c` | enable bits of context `c`, sources 0 … 31 (bit 0 reads 0) |
| `0x200000 + 0x1000·c` | priority threshold of context `c` |
| `0x200004 + 0x1000·c` | claim (read) / complete (write) of context `c` |

- **Gateways:** one per source.
  - **Level sources:** a source with its line high, not pending and not in service becomes pending.
  - **Edge sources** (parameter mask `EDGE_SRC`; the `merr` lines) become pending on a rising edge.
- **Claim:**
  - A claim read returns the pending, enabled source with the highest priority above the context's threshold; ties go to the lowest ID. It clears that source's pending bit and marks it in service.
  - It returns 0 when there is none.
- **Complete:** a write of source ID `s` ends `s`'s service if `s` is enabled for that context; otherwise it is ignored (PLIC spec). A level source still high becomes pending again.
- **Outputs:** `irq_o[c]` = some pending, enabled source with priority above the threshold, registered.

### Parameters
`N_SRC` = 32 (`riscv,ndev` = 31), `PRIO_W` = 3, `N_CTX` = 2 × `NUM_HARTS`, `EDGE_SRC`.

### Timing and area
- Per context: a 31-way maximum over priorities (5 levels of compare and select).
- The interrupt outputs are computed from registered state and registered. A claim computes the maximum for the one context being read, in the cycle of the access.
- About 1.5K LUTs at 8 contexts.

### Verification
`tests/unit/plic`: random source activity, priorities, thresholds and enables against a reference model of the PLIC spec, checking every claim value, the `irq_o` levels, completion and re-pending of level sources, and edge capture.

### Provenance
RISC-V Platform-Level Interrupt Controller Specification v1.0.0 (register map, gateways, claim and complete). Implemented as written.

---

## UART (`tg_uart`)

### Purpose
A 16550A-compatible UART at `UART_BASE` (`0x1000_0000`), compatible `ns16550a`, `reg-shift = 0`, byte registers (plan §5.4). It is the console of OpenSBI and Linux. Its byte streams connect to the host bridge, which bridges them to a pty on the A53 (plan §7.3). A serial pin pair (Pmod) is a later option.

### Interface
- Device-bus port and `irq_o` (PLIC source 10).
- TX stream to the host (`tx_valid`, `tx_ready`, `tx_byte`) and RX stream from the host (`rx_valid`, `rx_ready`, `rx_byte`).

### Behaviour
- **Registers** (offset; DLAB = `LCR[7]`):

  | Offset | Read | Write |
  |---|---|---|
  | 0 | RBR (DLAB 0) / DLL (DLAB 1) | THR (DLAB 0) / DLL (DLAB 1) |
  | 1 | IER (DLAB 0) / DLM (DLAB 1) | same |
  | 2 | IIR | FCR |
  | 3 | LCR | LCR |
  | 4 | MCR | MCR |
  | 5 | LSR | — |
  | 6 | MSR | — |
  | 7 | SCR | SCR |

- **FIFOs:** 16-byte TX and RX FIFOs. `FCR[0]` enables FIFO mode (IIR[7:6] = 11). `FCR[1]` and `FCR[2]` reset the FIFOs. `FCR[7:6]` sets the RX trigger level (1, 4, 8, 14 bytes).
- **Transmit:** THR writes go to the TX FIFO, which drains into the host TX stream. In this build that happens as fast as the stream accepts: the line is virtual, so the divisor and `LCR` framing bits are stored but do not pace the console.
  - LSR.THRE = TX FIFO empty; LSR.TEMT = TX FIFO empty and no byte in transfer.
- **Receive:** bytes from the host RX stream enter the RX FIFO while it has room, so it never overruns. LSR.DR = RX FIFO not empty.
- **Interrupts** (IIR priority order, IIR[0] = 0 when one is pending):
  1. receiver line status (011): never raised here;
  2. received data available (010): the RX level reaches the trigger, and ERBFI is set;
  3. character timeout (110): the RX FIFO is non-empty, below the trigger, with no push or pop for `RX_TIMEOUT` cycles (default the time of 4 characters at the programmed divisor and `clock-frequency`, floor 1024 cycles), and ERBFI is set. A read of RBR clears it.
  4. transmitter holding register empty (001):
     - **Raised** when the TX FIFO becomes empty, or ETBEI goes 0 → 1 while it is empty, with ETBEI set.
     - **Cleared** by an IIR read that reports it, or by a THR write.
  5. modem status (000): never raised.
- **Interrupt line:** `irq_o` = an interrupt is pending. `MCR.OUT2` is stored but does not gate it, matching what OpenSBI and Linux expect of `ns16550a` on non-PC platforms.
- **Modem lines:**
  - MSR reports CTS, DSR and DCD asserted.
  - In loopback (`MCR[4]`), THR bytes go to the RX FIFO instead of the host, and MSR reflects MCR. Linux's 8250 probe and self-test use loopback.

### Parameters
`FIFO_DEPTH` = 16; `CLK_HZ` and `REF_HZ` = 3 686 400 (the `clock-frequency` in the device tree) for `RX_TIMEOUT`.

### Timing and area
About 400 LUTs, FIFOs in LUTRAM, all outputs registered.

### Verification
`tests/unit/uart`:
- register reset values and DLAB banking;
- FIFO order and resets;
- every interrupt source's set and clear rules, including THRE re-arming on ETBEI;
- the character timeout;
- loopback;
- streaming 10⁴ random bytes each way with random stream back-pressure.

### Provenance
TI/National PC16550D datasheet (register map, FIFO and interrupt behaviour). Implemented as written, except the transmitter is not paced by the divisor (virtual line, noted above).

---

## Boot ROM (`tg_bootrom`)

### Purpose
4 KiB of read-only code at `BOOTROM_BASE` (`0x1000`), where every hart starts (`boot_addr_i`, interfaces.md §1). Its program implements plan §5.4 / §7.2:
1. Set `a0 = mhartid`.
2. Load `a1` (DTB address) and the entry address from the host-control block ([host.md](host.md)). Their reset values are `0x8220_0000` and `0x8000_0000`.
3. Jump to the entry.

### Interface
A TL-UL target port. `Get` of any size ≤ 6 returns `AccessAckData`:
- from `l1i`: line refills of 4 beats;
- from `mmio`: data loads ≤ 8 bytes.

`Put` returns `AccessAck` with `denied = 1`.

### Behaviour
- **Contents:** a constant table generated from `sw/bootrom/bootrom.S` by `sw/bootrom/Makefile`, which writes `rtl/uncore/bootrom/tg_bootrom_img.svh` (committed; `make -C sw/bootrom check` verifies it is current).
- **Unused space:** reads 0.
- **Responses:** a response beat is ready one cycle after the request is accepted. A 4-beat response streams at one beat per cycle, under D back-pressure.

### Timing and area
A LUT ROM: the program is a few dozen words, and the zero remainder costs nothing. Under 100 LUTs.

### Verification
`tests/unit/bootrom`: every size and offset of `Get` against the image file, back-pressure, `Put` denied. The program itself is checked in the SoC simulation and on QEMU-equivalent register values ([soc.md](soc.md)).

### Provenance
Plan §5.4 and §7.2 (boot contract). The SBI/OpenSBI `fw_jump` convention (`a0` = hart ID, `a1` = FDT) is from the OpenSBI documentation.

---

No other core's or SoC's RTL was read for these units.
