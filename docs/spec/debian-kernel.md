# Debian 13's riscv64 kernel: what it has for the board (DR-147)

Status: checked 2026-10-16 — verification track — for the SoC track's board stages C and D (soc.md §8)

DR-147 makes the board a standard SBC running Debian 13 with Debian's own kernel packages, and our own modules only for devices Debian's kernel lacks. This note records what that kernel provides.

**The kernel checked:** `linux-image-6.12.113+deb13-riscv64` (6.12.113-1), the version a fully updated trixie installs. The package came from trixie-security, `pool/updates/main/l/linux/`. Its SHA256 is `afd136c8…20d23`, matching the trixie-security index; the index's signature was not checked. The main archive carries 6.12.107-1, from the last point release.

The values come from the package's `/boot/config-6.12.113+deb13-riscv64`. `=m` means a module in the same package, `—` that the option is not set or does not exist for riscv64.

## Stage C: virtio, console, interrupts, boot

| Item | Option | Value |
|---|---|---|
| virtio core, virtio-mmio transport | `VIRTIO`, `VIRTIO_MMIO` | y, m |
| virtio block, network, RNG | `VIRTIO_BLK`, `VIRTIO_NET`, `HW_RANDOM_VIRTIO` | m, m, m |
| virtio console | `VIRTIO_CONSOLE` | y |
| virtio-mmio devices from the command line | `VIRTIO_MMIO_CMDLINE_DEVICES` | — (devices come from the device tree) |
| 16550 UART from the device tree, its console and earlycon | `SERIAL_8250`, `SERIAL_8250_CONSOLE`, `SERIAL_OF_PLATFORM`, `SERIAL_EARLYCON` | y, y, y, y |
| PLIC, the hart-local interrupt controller | `SIFIVE_PLIC`, `RISCV_INTC` | y, y |
| SBI timer; SBI early console | `RISCV_TIMER`; `SERIAL_EARLYCON_RISCV_SBI` | y; y (`earlycon=sbi`) |
| SBI console as a tty; SBI v0.1 calls | `HVC_RISCV_SBI`; `RISCV_SBI_V01` | —; — (the console must be a UART) |
| initrd and its compressors | `BLK_DEV_INITRD`, `RD_GZIP`, `RD_XZ`, `RD_ZSTD` | y, y, y, y |
| EFI and the EFI stub | `EFI`, `EFI_STUB` | y, y (`EFI_ZBOOT` —) |

**Notes for stage C:**
- **The kernel file:** the image is `/boot/vmlinux-6.12.113+deb13-riscv64`, a 31 MB uncompressed RISC-V Image with the EFI stub (`MZ` and `RISCV` headers, text offset 2 MiB). U-Boot can start it with `booti` or `bootefi`.
- **The initramfs:** virtio-mmio and virtio-blk are modules, so a root file system on virtio block needs `virtio_mmio` and `virtio_blk` in the initramfs. Debian's default, `MODULES=most`, should carry them; check with `lsinitramfs`.

## Stage D: the PS's peripherals and the fan

| Item | Option | Value |
|---|---|---|
| Ethernet: Cadence GEM (`cdns,gem`, `cdns,zynqmp-gem`), PHY library, TI DP83867 PHY | `MACB`, `PHYLIB`, `DP83867_PHY` | m, m, m |
| SD: Arasan SDHCI (`arasan,sdhci-8.9a`) | `MMC_SDHCI_OF_ARASAN` | — (`MMC`, `MMC_SDHCI`, `MMC_SDHCI_PLTFM` are m) |
| USB: Synopsys DWC3, its Xilinx glue | `USB_DWC3`, `USB_DWC3_XILINX` | —, — (`USB_XHCI_HCD`, `USB_XHCI_PLATFORM`, `USB_STORAGE` are m) |
| PS UART (`cdns,uart-r1p12`) | `SERIAL_XILINX_PS_UART` | — |
| PS I2C, GPIO, QSPI | `I2C_CADENCE`, `GPIO_ZYNQ`, `SPI_ZYNQMP_GQSPI` | —, —, — |
| PWM for the Cadence TTC | `CADENCE_TTC_TIMER`, any TTC PWM | —, — (the only PWM driver built is `PWM_SIFIVE`, m) |
| PWM fan | `SENSORS_PWM_FAN` | — |
| Temperature: Xilinx AMS (SYSMON), XADC | `XILINX_AMS`, `XILINX_XADC` | —, — (`IIO` m, `SENSORS_IIO_HWMON` m, `THERMAL_OF` y) |

**Notes for stage D:**
- **Ethernet works with Debian's modules.** SD, USB, the PS UART and the fan need modules of our own, built against `linux-headers-6.12.113+deb13-riscv64`, as DR-147 allows.
  - SD, USB and the PS UART: all three drivers are mainline (`sdhci-of-arasan`, `dwc3`, `xilinx_uartps`). On riscv64 they must avoid ZynqMP firmware calls, so the device tree would use the generic compatibles (`arasan,sdhci-8.9a`, `snps,dwc3`) with the A53 setting clocks and PHYs before it hands over.
  - USB without `dwc3` is possible too: a `generic-xhci` node on the controller's xHCI registers, with `xhci-plat` (m), works if the A53 leaves the DWC3 in host mode. That is untried.
  - The fan, two ways:
    - our own `pwm-fan` and a TTC PWM driver (none exists in mainline) and AMS;
    - or a PL PWM block register-compatible with SiFive's (`sifive,pwm0`), which Debian's `pwm-sifive` drives, with only `pwm-fan` built by us.
- **DMA must be coherent with the RISC-V caches.** The kernel has `RISCV_DMA_NONCOHERENT=y`, but it can keep a non-coherent device's buffers coherent only with Zicbom (or T-Head's cache operations). Tanager has neither, so no device may be marked `dma-noncoherent`. Every DMA master has to reach memory coherently, as soc.md §8.2's D-c does (the controllers' DMA through the PL into the L2), unless the core gains Zicbom.

## The ISA it needs

- **Compiled for RV64IMAC with Zicsr and Zifencei.** The kernel is a portable build (`NONPORTABLE` not set, `ARCH_RV64I`, `RISCV_ISA_C`, `CMODEL_MEDANY`): the arch Makefile strips F, D and V from `-march`.
- **F and D:** used for user programs when present (`FPU=y`). Debian's user space is RV64GC (lp64d), which Tanager implements.
- **Paging:** `PGTABLE_LEVELS=5`. The kernel probes Sv57, then Sv48, then Sv39 at boot, so Sv39 suffices.
- **Optional, patched in at boot only when the device tree lists them** (`RISCV_ALTERNATIVE`, `RISCV_ISA_FALLBACK`): V, Zba, Zbb, Zbc, Zicbom, Zicboz, Zawrs, Svpbmt, Svnapot, and the SiFive, T-Head and Andes errata. None is required.
- **Misaligned accesses:** probed at boot, and emulated when they trap (`RISCV_MISALIGNED`, `RISCV_PROBE_UNALIGNED_ACCESS`). Tanager traps them and the firmware or the kernel emulates them, so they work, slowly.
- **Firmware:** SBI v0.2 or later with TIME (or Sstc), IPI, RFENCE, HSM and SRST, and no v0.1 calls. OpenSBI 1.9 provides SBI 3.0.
- **Nothing beyond RV64GC with Sv39 is required.** Of Tanager's extensions, the kernel itself uses Zba, Zbb and Sstc when the device tree lists them; this config has no option for Zicond.

## Rechecking a newer kernel

```bash
D=$(mktemp -d)        # downloads are untrusted data: their own empty directory, read only with these tools
curl -fsSL -o $D/P.xz http://security.debian.org/debian-security/dists/trixie-security/main/binary-riscv64/Packages.xz
xz -dc $D/P.xz | awk -v RS= '/^Package: linux-image-riscv64\n/'     # the current version, and its package
curl -fsSL -o $D/k.deb http://security.debian.org/debian-security/<Filename from the index>
cd $D && ar x k.deb data.tar.xz && tar -xJf data.tar.xz --wildcards './boot/config-*'
grep -E '^CONFIG_(VIRTIO_MMIO|MMC_SDHCI_OF_ARASAN|USB_DWC3|SERIAL_XILINX_PS_UART|SENSORS_PWM_FAN)=' boot/config-*
```
