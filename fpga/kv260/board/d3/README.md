# Stage D's D3 on the board: the RISC-V's console on the PS's UART1 (COM7): pass (2026-10-18)

**What D3 is** ([`soc.md`](../../../../docs/spec/soc.md) §8.2, DR-163): the RISC-V takes the PS's UART1 (the board's USB serial port, COM7 on the laptop) as its console, through D1's PS window, while the A53's Ubuntu keeps running.

**The package:** `d3-uart1` from the SoC track ([`package_README.txt`](package_README.txt), the corrected one, `d146c11`).
- **Contents:** Buildroot's stage D `Image` (the Cadence UART driver built in), OpenSBI 1.9's `fw_jump.bin` (`7b4e2412…`, dr141-linux's), `tanager-kv260-uart1.dtb` (UART1 as OpenSBI's console and a second kernel console, PLIC 20), and `tanager-kv260.dtb` (the same without UART1).
- **No new bitstream:** it runs on d2's (`tanager-d2`).
- **[`SHA256SUMS`](SHA256SUMS)** is the first package's. Only its README changed afterwards: `tanager-host` has no `--console` flag (stdio is its console by default), and the corrected README drops it.
- **How it ran:**
  - the A53 side over SSH: [`../runs/d3_run.sh`](../runs/d3_run.sh) (`pre`, `boot`, `post`; every `tanager-host` call guarded on the app; dead-man 40 min);
  - COM7 from the laptop: [`serial_expect.ps1`](serial_expect.ps1) with [`com7_steps.txt`](com7_steps.txt), which logs everything received, waits for the prompts, logs in as root (no password, our own test image), runs step 4 and powers off.
- **The coordinator's conditions (DR-163), all kept:**
  - run-time changes only on the A53: the getty masked with `--runtime`, `dmesg -n 1`;
  - SSH and `fancontrol` up throughout;
  - no A53 shutdown while the RISC-V owned UART1;
  - UART1 handed back as the last step.

| Step | Result ([`d3_pre.txt`](d3_pre.txt), [`d3_boot.txt`](d3_boot.txt), [`d3_post.txt`](d3_post.txt)) |
|---|---|
| 0 | d2 loaded (`smt2`, 2 × 2, 100 MHz, caps `0x12f`). Console level `4 4 1 7`; `serial-getty@ttyPS1` active. |
| 0, the comparison boot without UART1 ([`pl_console_nouart1.txt`](pl_console_nouart1.txt)) | Linux on the PL UART alone (`ttyS0`). `TANAGER-BOOT-OK 6.18.56-tanager harts=2`; root logged in; `/proc/consoles` shows only `ttyS0`; `reboot: Power down` at 9.0 s. |
| 1 | The getty masked (`/run/systemd/system/serial-getty@ttyPS1.service → /dev/null`), inactive. Nothing holds `ttyPS1`. Console level 1. |
| 3, on COM7 ([`uart_COM7_d3.txt`](uart_COM7_d3.txt)) | `OpenSBI v1.9`, "Platform Name: Tanager on KV260", "Platform Console Device: cadence_uart". Linux's `earlycon: cdns0 at MMIO 0x00000000ff010000`, then `ff010000.serial: ttyPS0 at MMIO 0xff010000 (irq = 13, base_baud = 6249999) is a xuartps`. `Run /init`, "Tanager Linux", `tanager login:`; root logged in. The log appears twice because the real console replays the boot console's buffer. |
| 3, on the PL console ([`pl_console_uart1.txt`](pl_console_uart1.txt)) | The kernel's log once the 8250 driver probes, `TANAGER-BOOT-OK … harts=2`, the PL UART's own login (`/dev/console` stays the PL UART). |
| 4, the RISC-V | On COM7: `/proc/consoles` lists `ttyS0` and `ttyPS0`; `uname -a`, `ls /`, commands typed and echoed. On the PL console, `/proc/interrupts`: **`13: 202 0 SiFive PLIC 20 Edge xuartps`**, i.e. UART1's interrupt on PLIC source 20, 202 by then (the PL UART: 57). |
| 4, the A53 | `fancontrol` active, `pwm1` 15/255; dmesg shows nothing new (only the overlay lines from loading d2). |
| 4, the end | `poweroff` typed on COM7: `reboot: Power down` at 67.4 s on both consoles; `tanager-host`: "RISC-V requested power-off". |
| 5 | The getty unmasked and started, console level `4 4 1 7` again, `k26-starter-kits` back. COM7 ([`uart_COM7_d3_post.txt`](uart_COM7_d3_post.txt)) shows "Ubuntu 24.04.2 LTS kria ttyPS1" and `kria login:`. |

- **A note on the README's step 4:** `grep -i -e ttyPS -e 20: /proc/interrupts` matches nothing. The Cadence driver names its interrupt `xuartps`, and the PLIC source number has no colon after it. Use `cat /proc/interrupts`.

**So D3 is met on the board:**
- OpenSBI and Linux on the RISC-V use the PS's UART1 as their console, through the PS window with its interrupt on PLIC 20, with a login and commands over the board's own USB serial port;
- the A53's Ubuntu kept running with SSH and `fancontrol`, and got its console back cleanly.
