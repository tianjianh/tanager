# D4 modes: the boot mode record and the mode check

The KV260 boots in one of two modes ([soc-d4-modes.md](../../docs/spec/soc-d4-modes.md), DR-172). The A53's U-Boot
chooses at every boot from a record in the SD card's sector 2047, in the gap before `p1`. ARM mode (Ubuntu) is the
default and every fallback.

| File | What |
|---|---|
| `tanager-mode` | the record's tool, for Ubuntu and the RISC-V's Debian: `status`, `arm`, `riscv`, `confirm`, `clear`. It refuses any disk but the SD card |
| `ubootenv.d-tanager-mode` | the mode check, a flash-kernel hook: `/etc/flash-kernel/ubootenv.d/tanager-mode`, put in at the top of `boot.scr.uimg` |
| `riscv-stub.cmd` | step 4's `p1:/tanager/riscv.scr`: says it ran, and returns |
| `riscv.cmd` | steps 5 and 6's `riscv.scr`: the bitstream, the PL clock, the fabric widths, a `pl_resetn0` pulse, the host bridge, SD1's tap delays, the DRAM window and `BOARD_CTRL`, the images, the release, the A53's park in OCM. Any failure before the release returns, and Ubuntu boots |
| `rvtest/` | step 5's test image in U-Boot's place (S-mode at `0x8020_0000`): hello on COM5 and UART1, then SBI SRST (OpenSBI's syscon-reboot: `RESET_CTRL`), then `RESET_CTRL` itself, then a request for the PMOD break. `make -C sw/d4mode/rvtest`; on QEMU it runs through to SRST |
| `install.sh` | installs the tool, the hook and `p1:/tanager/` on Ubuntu, keeping `boot.scr.uimg` and `image.fit` as `*.tanager-pre`; `--undo` takes the hook out |
| `tanager-mode-confirm.service`, `debian_install.sh` | Debian's unit for RISC-V mode (trial back to 0 on a clean shutdown) and its installer, run in p3's Debian; `--undo` |
| `build.sh` | the package: `riscv.scr` by mkimage, and the files above |
| `hook_qtest.sh` | the hook run by U-Boot's hush on QEMU against an SD image, five records, and `riscv.cmd` dry (board addresses in RAM, board-only commands stubbed): to the park, out without our design, out without the L2. All must pass before the board |

**The record:** `TANAGERM`, then the mode (`a` or `r`), then the trial flag (`0` or `1`), then `\n`, then zeros to 512 bytes.
- The hook takes RISC-V mode only for `r` with trial `0`. It writes trial `1` first, then sources `p1:/tanager/riscv.scr`.
- Anything else boots Ubuntu: no record, an invalid one, `a`, or `r` with trial `1` (the last RISC-V boot never confirmed).
- If `riscv.scr` returns, Ubuntu boots too.
- Debian's unit sets trial back to `0` on each clean shutdown. So only an unclean end of RISC-V mode (a hang and the PMOD reset hook, a crash, a power loss) boots ARM next.

## Step 4 on the board (ARM mode; nothing starts the RISC-V)

Build: `bash sw/build_uboot.sh` (for mkimage), `bash sw/d4mode/build.sh <dir>` (the stub as `riscv.scr`), then `bash sw/d4mode/hook_qtest.sh <dir>`.

On the A53's Ubuntu, with the package directory copied over. The A53's U-Boot console is COM7 (UART1):
1. `sudo bash install.sh`. It prints that the hook is in `boot.scr.uimg`, lists `/boot/firmware/tanager/`, and shows the record (`none`). If the hook doesn't reach the script verbatim, it puts the kept script back and fails.
2. `sudo reboot`: COM7 shows `tanager-mode: ARM mode` before the kernel; Ubuntu comes up as before.
3. An invalid record:
   - `printf 'TANAGERMx9\n' | sudo dd of=/dev/mmcblk1 bs=512 seek=2047 count=1 conv=sync,notrunc,fsync`
   - `sudo reboot`: ARM mode again.
4. The RISC-V path with the stub:
   - `sudo tanager-mode riscv`, then `sudo reboot`.
   - COM7 shows `riscv, trial 0: writing trial 1`, the stub's line, and `the RISC-V did not start; booting Ubuntu`. Ubuntu comes up.
   - `sudo tanager-mode status` shows riscv with trial 1: U-Boot wrote it.
5. `sudo reboot`: ARM mode (trial 1). Then `sudo tanager-mode arm`.

**Undo:** `sudo bash install.sh --undo`. It removes the hook and regenerates the script. The tool, `p1:/tanager/` and the `*.tanager-pre` copies stay; they do nothing without the hook.

**If the boot script ever breaks:** at U-Boot's prompt on COM7:

```
load mmc 1:1 0x20000000 boot.scr.uimg.tanager-pre; source 0x20000000
```

That boots Ubuntu; then run the undo.

## Step 5 on the board: RISC-V mode, bare metal

The package is `bash sw/d4mode/build.sh <dir> sw/d4mode/riscv.cmd <the step 1 bitstream> <OpenSBI fw_jump.bin> <rvtest.bin> <the tree>`. The tree is `make -C sw/dts CORES=2 THREADS=2 RUN_THREADS=1 MEM=0x40000000 UART1=1 SD1=1 BOARD_RESET=1`. It needs step 4's hook in place and the record at arm.

1. **Install:** `sudo cp tanager/* /boot/firmware/tanager/ && sync`. This replaces the stub with the real `riscv.scr`, next to `tanager.bit.bin`, `fw_jump.bin`, `payload.bin` (the test image) and `tanager.dtb`. Check them against SHA256SUMS.
2. **Loggers:** log COM7 (UART1) throughout: the A53's U-Boot, then OpenSBI and the test image (the RISC-V mode tree's stdout is UART1). Log COM5 too, where the test image prints as well. COM5's USB-UART drops out at the PL load, so the test image says hello again after 10 s.
3. `sudo tanager-mode riscv`, `sync`, `sudo reboot`. On COM7, in order:
   1. `tanager-mode: riscv, trial 0: writing trial 1, then tanager/riscv.scr`
   2. `tanager: RISC-V mode from mmc 1:1`
   3. the bitstream's load
   4. `tanager: the host bridge answers`
   5. SD1's taps (`md`)
   6. the images' loads and copies
   7. `tanager: the RISC-V runs, its console on COM5 and UART1; this A53 parks`
   8. OpenSBI's banner
   9. the test image's hello, twice, then `SBI system reset, cold reboot`

   The board resets, and the A53's U-Boot shows `tanager-mode: ARM mode` (trial 1). Ubuntu boots: **pass**. After that, `sudo tanager-mode status` says riscv, trial 1; then run `sudo tanager-mode arm`.
4. **If `riscv.scr` stops before the release:** the hook prints `the RISC-V did not start; booting Ubuntu`, and Ubuntu boots with trial 1. The COM7 log shows the last command, and that is the report.
5. **If the test image runs but the board doesn't reset:** it prints its fallbacks, then asks for the PMOD break every 5 s. `riscv.scr` armed the hook (BOARD_CTRL 3), so a 4 s break on COM5 resets the board into ARM mode. Report which line it reached. If neither COM7 nor the break gets anywhere within 10 minutes, the board needs the user's power cycle.

## Step 6 on the board: RISC-V mode with Debian

The package is step 5's with U-Boot d4 (`bash sw/build_uboot.sh d4`) as `payload.bin`. Its tree adds `UART1_STDOUT=0`: the stdout path on the PL UART. With UART1 as stdout, Debian's plain `earlycon` (the extlinux append's) found no console, since Debian's kernel has no Cadence UART built in. The first try (on d4s1) showed nothing after `Starting kernel`: Linux had panicked at 2.2 s, on M6's micro-BTB bug (core-2's fix, MR c261c1f). It needs step 4's hook in place and the record at arm.

1. **Debian's side, in stage C** (Debian from `p3` under `tanager-host`, as the stress runs):
   - Copy this package into Debian and run `sudo bash debian_install.sh`. It prints `active` (the confirm unit), then the tool's refusal of the virtio disk, which is right in stage C. Then it prints extlinux's `root=`, which must be `LABEL=tanager-root` (not `/dev/vda`).
   - Shut Debian down cleanly, then check `p3`.
2. **`p1`**, in Ubuntu: `sudo cp tanager/* /boot/firmware/tanager/ && sync`, then check against SHA256SUMS. This puts U-Boot d4 in `payload.bin`; the other files are step 5's.
3. **Loggers:**
   - COM7 (UART1): the A53's U-Boot up to the park, then Debian's ttyPS0 getty.
   - COM5 (the PL UART): OpenSBI, U-Boot d4, then Debian's kernel console (ttyS0, with the early console from the first line) and its autologin.
4. `sudo tanager-mode riscv`, `sync`, `sudo reboot`.
   - COM7 shows step 5's lines up to the park.
   - COM5 then shows, in order:
     1. OpenSBI;
     2. U-Boot 2026.07 (`MMC: mmc@ff170000: 0`);
     3. `sysboot mmc 0:3`, extlinux's menu, then the kernel and initrd read by PIO (about 13 s at 5.7 MB/s);
     4. `Starting kernel`;
     5. Debian's boot and its autologin.
   - COM7 gets a login prompt (ttyPS0) once the Cadence UART module loads.

   Check in Debian:
   - `lsblk` and `findmnt /`: the root is `/dev/mmcblk0p3`;
   - `cat /proc/cmdline`;
   - `dmesg | grep -i -e mmc -e sdhci`;
   - the read rate, `sudo dd if=/dev/mmcblk0p3 of=/dev/null bs=1M count=256 iflag=direct`, against stage C's;
   - `systemctl is-active tanager-mode-confirm`;
   - `sudo tanager-mode status`: riscv, trial 1 (U-Boot wrote it).
5. `sudo reboot` in Debian. The unit sets trial 0, the reboot resets the board, and RISC-V mode comes back with Debian: **confirmed**.
6. `sudo tanager-mode arm`, `sudo reboot`: Ubuntu.
7. Optional, the unconfirmed end:
   - `tanager-mode riscv` and a reboot into Debian, then a 4 s break on COM5.
   - The board resets into Ubuntu (trial 1). Then `sudo tanager-mode arm`.

**If U-Boot d4 can't read the card,** it stops at its prompt on COM5, where `mmc list`, `mmc info` and `mmc part` help. Then a 4 s break on COM5 resets into ARM mode.

**If Debian's kernel can't find its root,** the initramfs shell comes up on COM5 (dmesg there). Then `poweroff -f` (a reset, through `RESET_CTRL`) or the break gives ARM mode.

**U-Boot's hush:** an apostrophe inside double quotes is a syntax error, after which U-Boot crashes (the QEMU test found it). No string in these scripts has one.
