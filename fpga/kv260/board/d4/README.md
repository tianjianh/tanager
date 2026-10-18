# Stage D's D4: the read-only probes for the A53's handover (2026-10-18)

The SoC track's probes for D4 (the A53 hands the board's peripherals to the RISC-V; [`soc.md`](../../../../docs/spec/soc.md) §8.2), all read-only on the A53. The raw output is [`d4_probe.txt`](d4_probe.txt); the A53's live device tree (`/sys/firmware/fdt`, the tree the kernel booted with) is [`fdt-live.dtb`](fdt-live.dtb) (`94ddd8c0…`).
- **kexec:** the kernel `6.8.0-1036-xilinx` has `KEXEC`, `KEXEC_FILE`, `KEXEC_SIG`, `KEXEC_IMAGE_VERIFY_SIG` and `CRASH_DUMP` built in.
  - There is no `KEXEC_SIG_FORCE`, and `LOCK_DOWN_KERNEL_FORCE_NONE`; lockdown reads `[none]`.
  - `/boot/vmlinuz` is gzip-compressed (59,585,024 bytes unpacked).
  - `kexec-tools` was then installed (the change log, 2026-10-18).
- **SD1** (`mmc1`, `ff170000`): 50 MHz, 4-bit, SD high-speed, 3.3 V signalling; an SDHC card from 05/2022; ADMA 64-bit.
- **Drivers:** `MACB`, `DP83867_PHY`, `SENSORS_PWM_FAN`, `PWM_CADENCE`, `OF_OVERLAY`, `UIO` and the ZynqMP power domains are built in; `UIO_PDRV_GENIRQ` and `PWM_XILINX` are modules.
- **Userland:** `busybox` (static and initramfs) and `openssh-server`; no dropbear.
- **Power:**
  - PM API v1.1, and no init-finalize line in dmesg.
  - The power domains of every device in use are on.
  - `RST_LPD_IOU2` `0x000103AA`. The reference clocks of SDIO1, UART0 and UART1 (`0x01010600`, `0x01001800`, `0x01010A00`) all have CLKACT set.
