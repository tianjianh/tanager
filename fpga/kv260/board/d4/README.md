# Stage D's D4: the probes, the RISC-V's Debian for D4, and the boot-time modes (2026-10-18 on)

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

## Part A's fix: the SD module loaded on demand, the ttyPS0 getty started by udev: pass (2026-10-19)

s6's boot showed part A's two side effects ([`../stress/README.md`](../stress/README.md), run s6):
- the initramfs loaded `sdhci_of_arasan` in every boot, which taints the kernel;
- the `dev-ttyPS0.device` job waited 1 min 31 s for a UART that stage C lacks.

The SoC track's fix is `stage_d_prep.sh --config-only` (5a74c34, `1a6c9ba5…`). It ran with [`../runs/d4_fixup.sh`](../runs/d4_fixup.sh) after s6 stopped:
- **`copy`:** the script was copied onto p3's `/root/stage-d` from the A53, with the RISC-V off. p3 checked clean.
- **`fix`:**
  - Stage C ran on d2 from p3, with no network: `sudo bash /root/stage-d/stage_d_prep.sh --config-only`. Its output is also in `/root/stage-d/fixup.log`.
  - Loaded at 09:00:50 UTC. The commands were done 1,083 s after the load, and the power-off came at 1,101 s (`boot exit 0`).
  - Log [`d4_fixup_fix.txt`](d4_fixup_fix.txt), console [`linux_shell_fixup.txt`](linux_shell_fixup.txt).
- **What changed in the RISC-V's Debian** (the change log has the undo):
  - The `sdhci-of-arasan` line is gone from `/etc/initramfs-tools/modules`.
  - A hook, `/etc/initramfs-tools/hooks/tanager-ps` (`manual_add_modules sdhci-of-arasan`), keeps the module in the initrd. There, udev loads it by modalias only when the tree has SD1.
  - The initrd was rebuilt, and still holds `sdhci-of-arasan`, `sdhci-pltfm`, `cqhci` and `mmc_block`.
  - `serial-getty@ttyPS0` is disabled. The udev rule `/etc/udev/rules.d/99-tanager-ttyps0.rules` starts it when ttyPS0 appears, and its autologin drop-in stays.
- **Result:** `stage_d_prep exit 0`. This boot still showed both effects, since it started from the old initrd.
- **Checked in the next boot, s7's** ([`../stress/README.md`](../stress/README.md)):
  - no line mentions sdhci or arasan, after "Loading essential drivers ... done." or anywhere else;
  - no taint line;
  - no ttyPS0 line or device job. The only "Expecting device" left is ttyS0's, the console itself (the PL's 16550), which every stage C boot shows;
  - pass 1 was clean in 128 s. The stress started at 194 s of the guest's uptime (s6: 202 s).

## Step 0 of the boot-time modes: read-only probes (2026-10-19)

D4 is re-planned as two modes chosen at boot (the SoC track's `docs/spec/soc-d4-modes.md`, f74ae00, DR-172). Step 0 asks what a mode check can use: the A53's QSPI U-Boot, its environment, the card and flash-kernel.
- **Run:** [`../runs/d4m_step0.sh`](../runs/d4m_step0.sh), alongside s7.
- **Raw output:** [`step0_probe.txt`](step0_probe.txt).
- Nothing was written, and nothing rebooted.

**The QSPI U-Boot:**
- **Version:** U-Boot 2023.01 (built 2024-05-10), boot firmware `K26-BootFW-01.02` (`XilinxSom_QspiImage-k26-v2.1-06140636`). Images A and B are the same build, and the board boots A (both requested and last booted).
- **Every command the plan names is in it**, found by its usage string: `fatwrite`, `fatload`, `fpga`, `zynqmp`, `mmc`, `itest`, `setexpr`, `go`, `sleep`, `source`, `load`, `mw`, `md`, `cmp`, `crc32`, `echo`, `exit` and `reset`.
  - Only 9 of the 18 show under their own names, so a list of names alone misses half.
  - A name can't appear as a string of its own when it's under 3 characters (`go`, `md`, `mw`), or when the linker stores it as the tail of a longer string (`load` inside `fatload`).
- **Subcommands:**
  - `zynqmp`: `mmio_read`, and `mmio_write address mask value`;
  - `mmc`: `write`;
  - `fpga`: `dump`, `info`, `load`, `loadb`, `loadbp` and `loadp`.
- **No bootcount:** no string holds "bootcount", "bootlimit" or "altbootcmd".
- **How:** the A53's Ubuntu has no binutils, so the script reads strings with `tr` and `awk`.

**The environment was never saved:**
- Both "U-Boot storage variables" partitions (mtd12, mtd13) are all 0xFF, so U-Boot runs its built-in default on every boot.
- `fw_printenv` (libubootenv-tool) fails ("Cannot initialize environment"), since there's no `/etc/fw_env.config`.
- **The default, read from the binary:**
  - `bootcmd` runs `som_cc_boot` on a starter kit. On the KV260 (`card1_name` `SCK-KV-G`), that sets `boot_targets` to `mmc1 usb0 usb1 usb2 usb3 pxe dhcp` and runs distro boot.
  - Distro boot finds `boot.scr.uimg` on the card's bootable partition (p1), and runs it with `source ${scriptaddr}`.
  - `scriptaddr` 0x20000000, `kernel_addr_r` 0x18000000, `fdt_addr_r` 0x40000000, `bootdelay` 2, `baudrate` 115200. There's no `loadaddr`.

**The card:**
- Sector 2047 is all zeros, and so is everything from sector 1 to 2047 (p1 starts at 2048).
- p1: 1009 MB FAT, 127 MB used, 883 MB free.

**flash-kernel:**
- **The entry:** the model, "ZynqMP KV260 revB", matches all.db's Kria entry (`ZynqMP *KV260*`):
  - method `generic`;
  - script template `bootscr.zynqmp.kria`;
  - output `/boot/firmware/boot.scr.uimg`;
  - FIT `/boot/firmware/image.fit`.
- **The template sits in `/etc/flash-kernel/bootscript/`, and is one of flash-kernel's conffiles.** This Ubuntu has no `/usr/share/flash-kernel/bootscript/`, so an override in `/etc/flash-kernel/bootscript/` would be an edit of the package's own file.
- **`boot.scr.uimg`** is the template with flash-kernel's substitutions: the command line `mem=3G arm-smmu.disable_bypass=0` (from `/etc/default/flash-kernel`), and two empty hooks.
- **The hooks:**
  - flash-kernel's README says files in `/etc/flash-kernel/ubootenv.d/` and `/etc/flash-kernel/preboot.d/` go in place of `@@UBOOT_ENV_EXTRA@@` and `@@UBOOT_PREBOOT_EXTRA@@`. Both directories exist and are empty.
  - In `bootscr.zynqmp.kria`, `@@UBOOT_ENV_EXTRA@@` is line 38, before the boot-target loop (line 45).
  - `@@UBOOT_PREBOOT_EXTRA@@` is line 148, inside the loop, before `image.fit` loads.
- **The template already loads a bitstream.** If p1 has `/system.bit`, every boot runs `load … 0x10000000 system.bit; fpga load 0 0x10000000 $filesize` (lines 53–56).
- **The kept scripts on p1:**
  - `boot.scr.uimg.bak` (2026-10-17) holds today's script text.
  - `boot.scr.uimg.orig` (2026-10-14) differs only in lacking `mem=3G arm-smmu.disable_bypass=0`.

**PS registers** (`tanager-host psrd`, `f515c0f6…`, with d2 holding the PL):

| Register | Value | Meaning (UG1087) |
|---|---|---|
| CRL_APB `RESET_CTRL` (`0xFF5E0218`) | `0x00000000` | No reset requested. |
| CRL_APB `BLOCKONLY_RST` (`0xFF5E021C`) | `0x00000000` | No debug-only reset requested. |
| CRL_APB `RESET_REASON` (`0xFF5E0220`) | `0x00000021` | **Bit 0 is `external_por`** (the PS_POR_B pin), and **bit 5 is `soft`** (a software system reset, through `RESET_CTRL`'s `soft_reset`). Only a power-on reset clears the register, and the A53 has run since 02:20:42 UTC, the user's power-up. So the soft reset came between the power-up and Linux. The likely cause is the Kria Image Selector's own reset into Image A; this isn't confirmed, since no U-Boot banner was logged. |
| CRL_APB `PL0_REF_CTRL` (`0xFF5E00C0`) | `0x01010A00` | `CLKACT` 1, `DIVISOR1` 1, `DIVISOR0` 10, `SRCSEL` 0 (IOPLL): 100 MHz, as tg.sh's `pl0_ref` reads (99,999,999 Hz). |

**For the plan** (the SoC track decides):
- **The mode check could be a file in `/etc/flash-kernel/ubootenv.d/`**, at the top of the script and before the boot loop, rather than an edited template.
  - It changes no conffile.
  - Its undo is the plan's own: delete the file and rerun flash-kernel.
  - An edited template would make dpkg ask about it at flash-kernel's next upgrade.
- **The RISC-V's bitstream must not be called `system.bit` on p1**, or ARM mode would load it too.
- **`RESET_REASON` can't tell a reset the RISC-V asks for from a power-up** if the Image Selector sets bit 5 on every boot. The mode record's trial flag does that job.
- **For the fallback that sources a kept script:**
  - `.orig` boots Ubuntu without `mem=3G` and the SMMU option;
  - `.bak` holds today's text, but flash-kernel may rewrite it;
  - a copy under its own name, made before the first change to p1, is the safest.
