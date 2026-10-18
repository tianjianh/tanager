# D4 run sheet: Debian from the KV260's SD card on the RISC-V (DR-164)

For the user, before D4's daytime run (soc-2, 10-18). The design and its conditions are in [soc.md](soc.md) §8.2 and DR-164; the board package's README has the exact commands.

## What happens

The A53's Ubuntu hands the SD card, UART1 and the fan over to the RISC-V by restarting once, with `kexec`, into its own kernel running from RAM. Then the RISC-V boots Debian natively from `p3` on the card.

- **Nothing in the boot path changes:** not QSPI, not U-Boot's environment, not `p1`. Any reset or power cycle boots normal Ubuntu.
- **The card:** `p2` (Ubuntu's root) is remounted read-only before the switch. The A53 never touches the card afterwards, and Debian mounts only `p3`.
- **The fan:** during the switch it runs at full speed. Afterwards D2's PL regulator governs it on the PL temperature.

## Before the day

1. `kexec-tools` installed on Ubuntu, with `LOAD_KEXEC=false`, so normal reboots stay normal. It's logged in the A53 OS change log, with `apt purge` as the undo.
2. Debian prepared in stage C: the SD controller's driver built by DKMS and put into Debian's initrd (see "Drivers" below for the user's choice). It changes only Debian on `p3`.

## The steps

| # | What (the board session) | What it watches | Undo | Only a power cycle gets back if… |
|---|---|---|---|---|
| 0 | Load d2 (`xmutil`); `tanager-host info` and `fan` | the PL temperature reading from D2's regulator (the handover refuses without it) | none needed | — |
| 1 | Build the handover initramfs from Ubuntu's own files (`mk_initramfs.sh`) | the file is made; nothing on the system changes | delete the file | — |
| 2 | **Dry run** (`handover.sh --dry`): stop `fancontrol` with pwm1 = 1, then kexec into the handover. No RISC-V. SSH drops for 1–2 minutes | SSH comes back as `root@kria`; the handover's log; SD1's and UART1's reset and clock registers equal Ubuntu's; the fan reading | `reboot -f` over SSH, to Ubuntu. If SSH never returns, the dry run reboots into Ubuntu by itself after 15 minutes | …SSH doesn't return and the automatic reboot doesn't come either (the handover kernel hung). Wait 20 minutes before power-cycling |
| 3 | Back in Ubuntu: copy Debian's kernel and initrd from `p3`, mounted read-only | the newest kernel and initrd pair | unmount | — |
| 4 | **The run** (`handover.sh` with the RISC-V's images): load them, stop `fancontrol` with pwm1 = 1, kexec | COM7: OpenSBI's banner, then Debian (its login on COM7 with the UART module, else on the PL console over SSH). Over SSH to the handover A53: its log and the RISC-V's console log. In Debian: the root on `mmcblk0p3`, the SD read rate against stage C's | `sudo poweroff` in Debian: the A53 reboots into Ubuntu by itself. Or over SSH to the handover A53: `pkill tanager-host`, same | …Debian's console and the handover's SSH are both unreachable. A power cycle then boots Ubuntu; `p3` may replay its journal at its next mount; `p1` and `p2` are untouched |
| 5 | In Ubuntu again | `uname -a`, `fancontrol` active, pwm1 | — | — |

- **If the card doesn't come up in Debian** (step 4: no `mmcblk0`, or errors while setting it up), nothing has been written to it. Debian stops at its initramfs shell (`rootwait`), where `poweroff -f` returns the A53 to Ubuntu. Then one retry with the fallback tree (plain `arasan,sdhci-8.9a`).
- **Time:** the dry run takes about 20 minutes, the run 30–45.

## Drivers: the user's call (the standard-SBC principle)

- **The gap:** Debian's riscv64 kernel (6.12) has no driver for the PS's SD controller (the Arasan SDHCI: `CONFIG_MMC_SDHCI_OF_ARASAN` is not set) or its UART (the Cadence UART: `CONFIG_SERIAL_XILINX_PS_UART` is not set).
- **`tanager-ps-dkms`** builds both from Debian's own `linux-source-6.12`, against Debian's own headers, and DKMS rebuilds them at each kernel update. The kernel stays Debian's; the two modules don't come from Debian's archive.
- **The UART module isn't needed.** Without it, Debian's console stays on the PL UART, through Debian's built-in 8250 driver. The board session reaches it through `tanager-host` on the handover A53 over SSH. COM7 still shows OpenSBI, which has its own Cadence driver. Debian's SBI console (`hvc_riscv_sbi`) isn't built: it needs `NONPORTABLE`.
- **The SD driver is needed:** there's no clean Debian-only way.
  - Debian's other SDHCI platform drivers expect other vendors' register layouts. `sdhci-of-dwcmshc` takes a vendor area from offset `0xE8` and writes through it; `sdhci-cadence` puts its registers at +`0x200`. Presenting the Arasan as one of them would be a hack.
  - Without `sdhci-of-arasan`, D4's native SD can't happen, and Debian stays on stage C's virtio disk.
  - The Debian route: Debian enables `CONFIG_MMC_SDHCI_OF_ARASAN=m` in its riscv64 kernel, a one-line config change a wishlist bug can ask for. Then the module is Debian's own in a later kernel.
- **The smallest non-Debian footprint:** one module, `sdhci-of-arasan`, built by DKMS from Debian's own sources, with the console on the PL UART. With the UART module as well, Debian's login is on COM7 too.
