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

## Step 2 of the boot-time modes: the board's reset path: pass (2026-10-19)

The SoC track's package `d4s1-smt2-c2-100` ([`package_d4s1_README.txt`](package_d4s1_README.txt); tarball `65304389…`, bitstream `2fee4000…`, its `tanager-host` `bd3f9233…`). It is m6's configuration plus step 1's PL changes:
- **BOARD_CTRL**, host register `0x1404`:
  - bit 0: the fan regulator ignores the A53's PWM;
  - bit 1: the PS window passes CRL_APB `RESET_CTRL`, and the PMOD reset hook is armed;
  - bits 3:2: the hook's write status.
- **The PMOD reset hook:** a break of 2.7 to 10.7 s on COM5 makes the PS window write `SOFT_RESET`.

Both tests run in ARM mode under `tanager-host`, and nothing in the boot path changes.

**How:**
- [`../runs/d4m_step2.sh`](../runs/d4m_step2.sh) on the board, after s7 stopped and p3 checked clean.
- The laptop's [`serial_break.ps1`](serial_break.ps1) for 2(b). The laptop has no Python, so the script holds .NET's `SerialPort.BreakState`, which uses the same Windows call as pyserial's `send_break`.
- **Records:**
  - Every call's output: [`step2_run.txt`](step2_run.txt).
  - The A53's console on COM7 through both resets: [`uart_COM7_step2.txt`](uart_COM7_step2.txt).
- **The app:** installed as `tanager-d4s1` (`tg.sh stage`; the installed `tanager-host` is unchanged, `5232908…`).

**Before the tests (12:10 UTC):**
- `RESET_REASON` read `0x00000021`.
- d4s1 loaded with the fan fine.
- `info` showed smt2, two cores at 100 MHz, and no commit trace.
- `BOARD_CTRL` read 0.

**The fan bit** (the README's optional step 3). I set the A53's PWM to 64 rather than 255, with `fancontrol` stopped, so the fan never ran at full speed.

| BOARD_CTRL | The A53's PWM | The fan's duty |
|---|---|---|
| 0 | 63/255 | **63/255** (the larger of the two) |
| 1 | 64/255 | **15/255** (the PL curve's alone) |
| 0 | 64/255 | **64/255** |

- **Pass:** with bit 0 set, the A53's PWM doesn't reach the fan.
- `fancontrol` was restarted (active, 15/255).
- `tanager-host fan`'s text still says "the larger of the curve's and the A53's" when bit 0 is set. That's only the wording.

**2(a), the RISC-V's write: pass.**
- **First try:** the README's `load --fw ps_reset.bin --kernel /dev/null --dtb /dev/null` failed in this `tanager-host` ("/dev/null: No error information"), before any reset or run.
- **Second try:** the package's `Image` and virtio tree filled the two unused slots. `ps_reset.bin` runs first and never reaches them.
- **`run` at 12:11:41.077:** the program printed `RESET_CTRL 00000000, read in 00000004 ticks of 10 MHz; writing SOFT_RESET in 1 s`, on both the SSH stream and COM5.
- **The reset:** SSH was cut at 12:11:47. COM7 shows the reset:
  - the FSBL's `MultiBootOffset: 0x40` and `Reset Mode : System Reset`;
  - U-Boot's `Reset reason: SOFT`;
  - Ubuntu's login.
- **Back:** the A53 ran from 12:11:57, and SSH answered at 12:12:57.
  - The last boot's journal ends at 12:11:40, with no shutdown record.
  - `fancontrol` was active, and `k26-starter-kits` was loaded.
  - `RESET_REASON` read `0x00000021` again.

**2(b), the PMOD reset hook: pass.**
- **Armed at 12:13:58:** d4s1 was loaded again, then `poke 0x010 1` (the uncore out of reset, the cores held), `poke 0x1404 2` (it read back `0x2`) and `sync`.
- **The break:** the COM5 logger stopped, then a break on COM5 from 12:14:08.873 to 12:14:11.884 (3.011 s).
- **The reset:** the A53 ran from 12:14:26. That's about 14 s after the break's end, the time the FSBL and U-Boot take, so the board reset as the break ended.
- **COM7:** the same banner again (`Reset Mode : System Reset`, `Reset reason: SOFT`).
- **Back:**
  - The last boot's journal ends at 12:13:57, with no shutdown record.
  - `fancontrol` was active, and `k26-starter-kits` was loaded.
  - `RESET_REASON` read `0x00000021` before and after.

**Item 4, read-only probes for step 5** (12:10, `k26-starter-kits` loaded):

| Register | Value | Meaning |
|---|---|---|
| FPD SWDT `ZMR` (`0xFD4D0000`) | `0x000001C2` | Bit 0 (the enable) clear: not running. |
| FPD SWDT `CCR` (`0xFD4D0004`) | `0x00003FFC` | |
| LPD SWDT `ZMR` (`0xFF150000`) | `0x000001C2` | Bit 0 clear: not running. |
| LPD SWDT `CCR` (`0xFF150004`) | `0x00000953` | |
| `AFI_FS` (`0xFD615000`) | `0x00000800` | |
| IOU_SLCR SD `ITAPDLY` (`0xFF180314`) | `0x012A0000` | SD1's input tap, as Linux set it. |
| IOU_SLCR SD `OTAPDLYSEL` (`0xFF180318`) | `0x00050000` | SD1's output tap. |

- **Linux:** two `cdns_wdt` watchdogs, both `inactive`. The device tree has both enabled (`watchdog@fd4d0000` and `watchdog@ff150000`).
- **The first 8 watchdog strings in mtd5:** `xwdtps.c`, `XFSBL_ERROR_SYSTEM_WDT_RESET`, `WDT initialization failed`, `fpd_wdt`, `lpd_wdt`, `swdt0_clk`, `swdt0_rst`, `swdt1_clk`.

**Seen on COM7:**
- **U-Boot's environment:** U-Boot prints `Loading Environment from nowhere... OK`. It has no environment storage at all, which matches step 0's blank flash partitions. So the mode record on the card is the only place for state.
- **The `soft` bit:** after both resets, the FSBL reports `Reset Mode : System Reset` and U-Boot `Reset reason: SOFT`. A power-up's banner hasn't been logged yet, so the Image Selector guess (step 0) still stands unconfirmed.

**For the plan** (the SoC track decides):
- The README's `/dev/null` slots need a fix in either the README or `tanager-host`.
- Both reset paths that RISC-V mode relies on work in the bitstream:
  - Debian's reboot through the PS window;
  - the hook for a hung RISC-V.
- **Afterwards:** s8, d2 from p3, from 12:16:44 UTC.

## Step 4 of the boot-time modes: the mode check in the A53's boot script: pass (2026-10-19)

The SoC track's package `d4m-step4` ([`package_d4m_step4_README.md`](package_d4m_step4_README.md); tarball `cc593776…`; SHA256SUMS all OK).

**What it adds:**
- **The mode record** is in the card's sector 2047, before p1: `TANAGERM`, the mode (`a` or `r`), the trial flag (`0` or `1`), `\n`, then zeros.
- **The check** is a flash-kernel hook, `/etc/flash-kernel/ubootenv.d/tanager-mode`, at the top of `boot.scr.uimg`:
  - Only `r` with trial `0` takes the RISC-V path. That path writes trial `1` back, then sources `p1:/tanager/riscv.scr`.
  - Anything else boots Ubuntu, and so does `riscv.scr` returning.
- **In step 4, `riscv.scr` is a stub** that only prints and returns. Nothing starts the RISC-V, and no PL load is involved.

**How:**
- s8 was stopped after its first pass, and p3 checked clean.
- Then [`../runs/d4m_step4.sh`](../runs/d4m_step4.sh) ran on the board, with `sudo systemctl reboot` from the laptop between its parts.
- **Records:**
  - Every call's output: [`step4_run.txt`](step4_run.txt).
  - COM7, the A53's console, logged read-only through all four boots: [`uart_COM7_step4.txt`](uart_COM7_step4.txt).
- The change log has the change and its undo.

**The install** (12:23 UTC): `install.sh` exited 0, and the hook reached the script verbatim.
- `boot.scr.uimg` and `image.fit` were kept as `*.tanager-pre` (the 10-17 files, `5cb30737…` and `9b046e37…`).
- The new `boot.scr.uimg` (9,238 bytes) is the kept script plus the hook's 16 lines, at the template's `@@UBOOT_ENV_EXTRA@@`. Nothing else changed.
- The new `image.fit` differs from the kept one in 3 bytes, its creation time (`dumpimage -l`). So it has the same kernel, initrd and trees.
- flash-kernel printed "Couldn't find DTB on the following paths", which is harmless: the FIT carries the trees.
- flash-kernel also rotated its own `*.bak` copies, which now hold the 10-17 files. A `.bak` lasts only until the next flash-kernel run, as step 0 suspected.

**The four boots.** COM7's lines come after U-Boot's `Found U-Boot script /boot.scr.uimg`. Every boot reached Ubuntu's login with `fancontrol` active and `k26-starter-kits` loaded, and SSH answered about 80 s after the reboot.

| Boot | The record before | COM7 (U-Boot) | The record after |
|---|---|---|---|
| 1 | none (zeros) | `MMC read: dev # 1, block # 2047, count 1 ... 1 blocks read: OK`, then `tanager-mode: ARM mode` | none |
| 2 | `TANAGERMx9`, the README's invalid record | `tanager-mode: ARM mode` | `TANAGERMx9`, untouched |
| 3 | `TANAGERMr0` (`tanager-mode riscv`) | `tanager-mode: riscv, trial 0: writing trial 1, then tanager/riscv.scr`, `MMC write: dev # 1, block # 2047, count 1 ... 1 blocks written: OK`, `463 bytes read`, `tanager riscv.scr: the step 4 stub, returning to Ubuntu`, `tanager-mode: the RISC-V did not start; booting Ubuntu`, then `Loading image.fit` | `TANAGERMr1`: U-Boot wrote it |
| 4 | `TANAGERMr1` | `tanager-mode: ARM mode` | `TANAGERMr1`; then `tanager-mode arm` made it `TANAGERMa0` |

**Left in place:** the hook, the tool, `p1:/tanager/` with the stub, and the record saying arm. Every boot is ARM mode until steps 5 and 6 replace the stub and set the record.

**Seen in passing:** each reboot's shutdown prints `systemd-shutdown[1]: Failed to set timeout to 10min: Invalid argument`. That's systemd's reboot watchdog (`RebootWatchdogSec`), which the Cadence watchdog's driver refuses. The system reset resets both watchdogs anyway, and item 4 found both off.

**Afterwards:** s9, d2 from p3, from 12:31:05 UTC.

## Step 5 of the boot-time modes: RISC-V mode, bare metal: pass (2026-10-19)

The SoC track's package `d4m-step5` ([`package_d4m_step5_README.md`](package_d4m_step5_README.md); tarball `e6a61ce6…`; SHA256SUMS all OK). It is the first boot in which the A53 parks and the RISC-V runs alone. The hook, the tool and `install.sh` are step 4's.

**p1's `tanager/` now holds:**
- the real `riscv.scr` (`40c270a0…`, from `riscv.cmd`), which does the following, in order:
  1. writes the park loop into OCM;
  2. loads the bitstream;
  3. sets the PL clock (IOPLL/10) and the fabric widths, and pulses `pl_resetn0`;
  4. checks that the host bridge answers;
  5. sets SD1's taps;
  6. sets the DRAM window (`0x8_4000_0000`, 1 GiB) and `BOARD_CTRL` 3;
  7. copies the images into the carve-out;
  8. releases the uncore, then the cores;
  9. parks the A53 with `go 0xfffc0000`;
- `tanager.bit.bin`: d4s1, the same as step 2's (`2fee4000…`);
- `fw_jump.bin`: OpenSBI (`b0094d23…`);
- `payload.bin`: the bare-metal test image;
- `tanager.dtb`: the RISC-V mode tree, with UART1 as stdout, SD1 and the reboot through `RESET_CTRL`.

**How:**
- s9 was stopped, and p3 checked clean.
- [`../runs/d4m_step5.sh`](../runs/d4m_step5.sh) ran `precheck`, `install` and `riscv`. The laptop then rebooted the A53, and `post` ran after the board came back.
- COM7 and COM5 were logged through the run: [`uart_COM7_step5.txt`](uart_COM7_step5.txt), [`uart_COM5_step5.txt`](uart_COM5_step5.txt). Every call's output is in [`step5_run.txt`](step5_run.txt).

**The precheck** (12:50 UTC, under Linux, with d4s1 loaded by `xmutil`). These are the values `riscv.scr` writes or expects before its first read of the PL:

| What | With `k26-starter-kits` | With d4s1 | What `riscv.scr` does |
|---|---|---|---|
| CRL_APB `PL0_REF_CTRL` | `0x00010A00` (CLKACT off) | `0x01010A00` | writes `0x01010A00` |
| FPD_SLCR `AFI_FS` | `0x00000800` | `0x00000800` | sets bits 11:8 to `0x8` |
| Host bridge ID (`0xA000_0000`) | (not read) | `0x54474E52` | checks for `0x54474E52` |

They match. A wrong PL clock or bus width here could have hung the A53 on its first read of the PL, which only a power cycle fixes.

**The run** (the reboot at 12:51:24 UTC). COM7 showed every line the README lists, in order:
- **The hook:** `MMC read … block # 2047`, `tanager-mode: riscv, trial 0: writing trial 1, then tanager/riscv.scr`, `MMC write … 1 blocks written: OK`.
- **`riscv.scr`:**
  - `tanager: RISC-V mode from mmc 1:1`;
  - the bitstream: `7797692 bytes read in 592 ms`. U-Boot's `fpga load` prints nothing when it succeeds;
  - `tanager: the host bridge answers`;
  - SD1's taps: `ff180314: 012a0000 00050000`;
  - the three images (277,856, 1,452 and 3,719 bytes);
  - `tanager: the RISC-V runs, its console on COM5 and UART1; this A53 parks`, then U-Boot's `## Starting application at 0xFFFC0000 ...`.
- **OpenSBI v1.9 on UART1, now the RISC-V's:**
  - `Platform Name: Tanager on KV260`, 2 harts (`Domain0 HARTs 0x0*,0x2*`);
  - the timer `aclint-mtimer @ 10000000Hz`, the console `cadence_uart`;
  - `Platform Reboot Device: syscon-reboot`;
  - `Region02 0xff5e0218-0xff5e021f` (`RESET_CTRL`) and `Region03 0xff010000-0xff010fff` (UART1), both open to S-mode;
  - `Boot HART ISA Extensions: sstc,zicntr,sdtrig,f,d`, `PMP Count 16`;
  - next: `0x80200000` in S-mode, tree at `0x82200000`.
- **The test image:**
  - `tanager D4 step 5: RISC-V mode, bare metal, hart 0000000000000000, tree at 0000000082200000` and `UART1: this line is on COM7 too`, then the same two lines 10 s later. They appeared on both COM7 and COM5, and COM5 logged no dropout;
  - then `SBI system reset, cold reboot: the board should reset, then boot Ubuntu (trial 1)`.
- **The board reset:** the FSBL showed `Reset Mode : System Reset`, U-Boot `Reset reason: SOFT` and `tanager-mode: ARM mode`, and Ubuntu booted.

**After:**
- Ubuntu ran from 12:52:08, 44 s after the reboot command, so the whole RISC-V mode episode took less than that.
- `tanager-mode status`: `riscv, trial 1: the last RISC-V boot never confirmed, so the next boot is ARM`. Then `tanager-mode arm`.
- `fancontrol` was active (15/255), and `k26-starter-kits` was loaded.
- `RESET_REASON` read `0x00000021`. The previous Linux had shut down cleanly at 12:51:28.

**Afterwards:** s10, d2 from p3, from 12:53:29 UTC.

**For the record:** OpenSBI's `PMP Count 16` shows that d4s1 (e8345f3) predates the 8-entry PMP (9db66da). A lockstep run on a bitstream like it would take `--pmp=16` (verif-2). d4s1 has no commit trace anyway.

## Step 6 of the boot-time modes, first attempt: Debian's kernel silent after U-Boot d4; the break recovers (2026-10-19)

The SoC track's package `d4m-step6` ([`package_d4m_step6_README.md`](package_d4m_step6_README.md); tarball `2316a567…`; SHA256SUMS all OK). It is step 5's with U-Boot d4 as `payload.bin` (`459992b8…`), which boots Debian from p3 through SD1 with extlinux, and Debian's side: `tanager-mode` and the confirm unit, which sets trial back to 0 on each clean shutdown.

**How:** [`../runs/d4m_step6.sh`](../runs/d4m_step6.sh), after s10 stopped. Records: [`step6_run.txt`](step6_run.txt); the stage C console [`linux_shell_step6_debian.txt`](linux_shell_step6_debian.txt); COM7 and COM5 through the RISC-V mode boot: [`uart_COM7_step6.txt`](uart_COM7_step6.txt), [`uart_COM5_step6.txt`](uart_COM5_step6.txt).

**Debian's side, in stage C on d2** (13:00 to 13:04 UTC): pass.
- `debian_install.sh` exited 0. The unit is enabled and active.
- The tool refused the virtio disk ("the root file system (/dev/vda) is on no partitioned disk"), which is right in stage C.
- extlinux's `root=` is `LABEL=tanager-root` (all four entries).
- **Stage C's read rate:** `dd if=/dev/vda bs=1M count=256 iflag=direct` gave 256 MiB in 18.078 s, **14.8 MB/s**.
- The shutdown was clean, and p3 checked clean.

**p1:** `payload.bin` is U-Boot d4, and the rest is step 5's (SHA256SUMS OK).

**RISC-V mode** (the record at riscv, reboot at 13:05:51): **the kernel stopped before its console came up.**
- **COM7 up to U-Boot d4:** step 5's lines, unchanged up to the park (the payload is now 1,301,584 bytes), then OpenSBI v1.9.
- **U-Boot d4** (`U-Boot 2026.07`, `DRAM: 1 GiB`, `MMC: mmc@ff170000: 0`, `Loading Environment from nowhere`, a 2 s autoboot):
  - read `/boot/extlinux/extlinux.conf` and chose entry 1 (6.12.113);
  - read `vmlinux` and `initrd.img` through SD1;
  - printed `append: root=LABEL=tanager-root console=ttyS0,115200 earlycon rw`;
  - printed `Moving Image from 0x84000000 to 0x80200000`, loaded the tree to `0xbde7f000`, then `Starting kernel ...`.
- **Then nothing**, on COM7 or COM5, for 10 minutes. One CR on COM5 at 13:17:09 got no answer in 20 s.
- **The break** (4.012 s on COM5, 13:17:48 to 13:17:52) reset the board, as riscv.scr's `BOARD_CTRL` 3 armed it to:
  - the FSBL showed `System Reset`, U-Boot `Reset reason: SOFT` and `tanager-mode: ARM mode` (trial 1);
  - Ubuntu was back 68 s after the break, with `fancontrol` and `k26-starter-kits`;
  - the record went back to arm.
- **p3 afterwards, read-only:** the kernel never mounted it.
  - The state is clean, with no `needs_recovery` flag. The append's `rw` would have left that flag after a reset.
  - The last mount is stage C's initramfs mount, at 63 s of uptime.
  - The systemd journal's newest boot is the stage C install boot.
- **A lead** (the SoC track's to judge): the device tree's own bootargs point an early console at the PL's 16550 (COM5): `earlycon=uart8250,mmio,0x10000000`. But extlinux's `append` replaces those bootargs, and it has plain `earlycon`, which goes to stdout-path instead. In this tree stdout-path is UART1, a Cadence UART that Debian's riscv64 kernel has no built-in driver for (part A had to build it by DKMS). So no early console exists. ttyS0 comes up only when the 8250 driver probes, about 22 s in under stage C, and any hang before then is silent.

**The recovery path held:** the PMOD break reset the board out of a silent RISC-V mode into ARM mode, with nobody at the board.

**Afterwards:** s11, d2 from p3, from 13:20:32 UTC. The record is at arm. Steps 4 to 6's files stay in place for the next attempt.

## Step 6's diagnostic: Linux panics on d4s1 (m6's configuration), in RISC-V mode and in stage C alike (2026-10-19)

The SoC track asked for a by-hand boot at U-Boot d4's prompt. It had two candidates:
- (a) an early kernel hang with the RISC-V mode tree's new nodes;
- (b) images corrupted by U-Boot d4's PIO loads.

**Records:**
- [`step6_diag_run.txt`](step6_diag_run.txt);
- COM7 for both by-hand boots: [`uart_COM7_step6diag.txt`](uart_COM7_step6diag.txt);
- the kernel's console: [`uart_COM5_step6diag2_230400.txt`](uart_COM5_step6diag2_230400.txt);
- the split test's console: [`linux_shell_stagec_d4s1.txt`](linux_shell_stagec_d4s1.txt).

**Laptop tools:**
- [`serial_expect2.ps1`](serial_expect2.ps1): D3's scripted session with paced typing. A match consumes only the text up to its end, and a timeout ends the steps.
- [`serial_log3.ps1`](serial_log3.ps1): the reopening logger with a baud option.
- [`com7_uboot_d4_steps.txt`](com7_uboot_d4_steps.txt): the U-Boot lines. The script first waits for U-Boot d4's own banner, so the A53's U-Boot countdown is never touched.

**The images are intact, so not (b):**

| | On p3 (gzip's CRC32, read-only) | Loaded by U-Boot d4 through SD1 |
|---|---|---|
| `vmlinux-6.12.113+deb13-riscv64` (31,166,464 bytes) | `439ad054` | `439ad054`, read in 5,242 ms (5.7 MiB/s) |
| `initrd.img-6.12.113+deb13-riscv64` (42,091,488 bytes) | `e9fd3a54` | `e9fd3a54`, read in 7,090 ms (5.7 MiB/s) |

U-Boot d4's `mmc info` reports SD High Speed (50 MHz), 4-bit, 14.6 GiB.

**The kernel panics 2.16 s in:**
- **The first by-hand boot's earlycon was garbled.** `earlycon=uart8250,mmio,0x10000000,115200n8` gives no clock, so the kernel assumes 1.8432 MHz and sets divisor 1. The 16550 runs at 3.6864 MHz, so that is 230400 baud.
- **The second by-hand boot** was identical, with COM5 logged at 230400. It reads cleanly:
  - SBI v3.0, IPIs through SBI;
  - `smp: Brought up 1 node, 2 CPUs` at 0.24 s;
  - then, at 2.157 s, `Unable to handle kernel paging request at virtual address ffffff9e3fdc7b18`;
  - a store page fault on CPU 0 in `handle_IPI` → `generic_smp_call_function_single_interrupt` → `__flush_smp_call_function_queue`;
  - `epc ffffffff8009ee16` (`record_print_text+0x15a`), `ra ffffffff8006062e` (`sched_ttwu_pending+0x68`);
  - `Kernel panic - not syncing: Fatal exception in interrupt`.
- **That explains the first attempt's silence.** The panic halts the kernel before the 8250 console comes up, and plain `earlycon` has no early console in this tree.

**The split: the same panic in stage C on d4s1, so not (a) either.**
- One ordinary stage C boot on d4s1, mode `stagec_d4s1` of [`../runs/d4m_step6.sh`](../runs/d4m_step6.sh):
  - `BOARD_CTRL` 0;
  - its package's virtio tree, OpenSBI and U-Boot;
  - Debian from p3 over virtio, as in every stress run.
- It panicked at 2.489 s at the same `epc` and `ra`, with the bad address `ffffff9e3fdf0b18`.
- The pointer is corrupted the same way in both runs: the top byte is `9e` where the linear map's is `d6`, so bits 35 and 38 are flipped.
- tg.sh ended the run after its 600 s login wait, and `k26-starter-kits` was back at 13:50:52.

**d2 runs the same kernel cleanly with the same CPU setup.** d2's stage C (s7, 76 clean passes) and d4s1's stage C print identical CPU lines:
- 2 harts (`0x0*,0x2*`);
- `rv64imafdcb`, extensions `sstc,zicntr,sdtrig,f,d`, PMP 16;
- the same percpu layout, `2 CPUs`.

So the only difference is the bitstream. **m6's configuration (e8345f3) panics Linux about 2.2 to 2.5 s into every boot:** three boots, three panics. d2 has about 700 clean stress passes with the same kernel, initrd and tree. This is for the core and SoC tracks to find.

**What D4 has shown so far:**
- RISC-V mode's machinery works up to Debian's kernel: the A53's U-Boot, the park, OpenSBI, U-Boot d4, and extlinux and the images read through SD1.
- The PMOD break recovered the board from a halted RISC-V Linux three times (13:17, 13:32 and 13:37 UTC), with Ubuntu back in 68 to 80 s and p3 never touched.

**Afterwards:** s12, d2 from p3, from 13:51:18 UTC. The record is at arm.
