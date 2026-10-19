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

## Part A: the RISC-V's Debian prepared for D4: pass (2026-10-19)

The user's choice (DR-168): both modules, so Debian's login also comes on COM7. The run: [`../runs/d4_prepA.sh`](../runs/d4_prepA.sh) with [`../runs/d4_prepA_cmds.txt`](../runs/d4_prepA_cmds.txt); the log [`d4_prepA_run.txt`](d4_prepA_run.txt); the console [`linux_shell_prepA.txt`](linux_shell_prepA.txt).
- **How:**
  - the package's `debian/` copied onto p3 as `/root/stage-d`, from the A53 with the RISC-V off, then p3 checked clean;
  - stage C on d2 from p3, bridged;
  - in Debian, after the IPv4 lease: `sudo bash /root/stage-d/stage_d_prep.sh` (no `--sd-only`), its output also in `/root/stage-d/prep.log`.
- **Result:** `stage_d_prep exit 0`.
  - **apt:** 24 new packages, none removed, including `dkms` 3.2.2 and `linux-headers-6.12.113+deb13-riscv64` and `linux-source-6.12` 6.12.113-1 from trixie-security, matching the running kernel. The full list is in the change log.
  - **DKMS:** built and installed `sdhci-of-arasan.ko.xz` and `xilinx_uartps.ko.xz` in `/lib/modules/6.12.113+deb13-riscv64/updates/dkms/`, signed with a key it generated.
  - **The initrd** (42 MB) holds `sdhci-of-arasan`, `sdhci-pltfm`, `cqhci` and `mmc_block`. `vmlinux-6.12.113+deb13-riscv64` is unchanged.
- **The coordinator's checks, all good:**
  - `dkms status`: `tanager-ps` installed;
  - both modules' vermagic is `6.12.113+deb13-riscv64 SMP mod_unload modversions riscv`, the running kernel;
  - the initrd has `sdhci-of-arasan`;
  - `serial-getty@ttyPS0` is enabled, with `ExecStart=-/sbin/agetty --autologin tanager --keep-baud 115200 %I $TERM`;
  - neither module is loaded in stage C.
- **The run:** the power-off came 3,530 s after the load (`boot exit 0`), so the prep itself took about 50 minutes. Its `time` reads 548 min because the guest's clock jumped when NTP synced. p3 checked clean afterwards: 42,785 files, 2.1 GB used.
