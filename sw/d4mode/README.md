# D4 modes: the boot mode record and the mode check

The KV260 boots in one of two modes ([soc-d4-modes.md](../../docs/spec/soc-d4-modes.md), DR-172). The A53's U-Boot
chooses at every boot from a record in the SD card's sector 2047, in the gap before `p1`. ARM mode (Ubuntu) is the
default and every fallback.

| File | What |
|---|---|
| `tanager-mode` | the record's tool, for Ubuntu and the RISC-V's Debian: `status`, `arm`, `riscv`, `confirm`, `clear`. It refuses any disk but the SD card |
| `ubootenv.d-tanager-mode` | the mode check, a flash-kernel hook: `/etc/flash-kernel/ubootenv.d/tanager-mode`, put in at the top of `boot.scr.uimg` |
| `riscv-stub.cmd` | step 4's `p1:/tanager/riscv.scr`: says it ran, and returns |
| `riscv.cmd` | steps 5 and 6's `riscv.scr`: the bitstream, the PL clock, the fabric widths, a `pl_resetn0` pulse, the host bridge, SD1's tap delays, GEM3's PHY out of reset (D5), the DRAM window and `BOARD_CTRL`, the images, the release, the A53's park in OCM. Any failure before the release returns, and Ubuntu boots |
| `rvtest/` | step 5's test image in U-Boot's place (S-mode at `0x8020_0000`): hello on COM5 and UART1, then SBI SRST (OpenSBI's syscon-reboot: `RESET_CTRL`), then `RESET_CTRL` itself, then a request for the PMOD break. `make -C sw/d4mode/rvtest`; on QEMU it runs through to SRST |
| `install.sh` | installs the tool, the hook and `p1:/tanager/` on Ubuntu, keeping `boot.scr.uimg` and `image.fit` as `*.tanager-pre`; `--undo` takes the hook out |
| `tanager-mode-confirm.service`, `debian_install.sh` | Debian's unit for RISC-V mode (trial back to 0 on a clean shutdown) and its installer, run in p3's Debian; `--undo` |
| `build.sh` | the package: `riscv.scr` by mkimage, and the files above |
| `hook_qtest.sh` | the hook run by U-Boot's hush on QEMU against an SD image, five records, and `riscv.cmd` dry (board addresses in RAM, board-only commands stubbed): to the park, out without our design, out without the L2. All must pass before the board |
| `memgap.c`, `ps-memregs` | RISC-V mode's memory gap ([soc-d4-modes.md](../../docs/spec/soc-d4-modes.md)): `memgap` measures the clock read, the memory path and the coherence path on the RISC-V's Debian, in either mode; `ps-memregs` reads the PS's settings on that path on Ubuntu (below) |

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

## D5 step 2 on the board: Ethernet in RISC-V mode

The plan is [soc-d5-gem3.md](../../docs/spec/soc-d5-gem3.md). The package is step 6's with two files changed:
- `riscv.scr`: it takes GEM3's PHY out of reset before the park;
- `tanager.dtb`: `ETH=1`, with the board's MAC (the A53's `eth0`'s).

The bitstream, OpenSBI and U-Boot d4 are step 6's, and Debian needs nothing new.

1. **`p1`:** `sudo cp tanager/* /boot/firmware/tanager/ && sync`, then check against SHA256SUMS.
2. **Loggers:** COM5 and COM7 as for step 6. The laptop's Ethernet adapter stays connected (the link partner, and DHCP from its connection sharing).
3. `sudo tanager-mode riscv`, `sync`, `sudo reboot`. COM5 shows Debian's boot, now with:
   - `macb ff0e0000.ethernet eth0: Cadence GEM rev … (00:0a:35:2a:df:d8)`;
   - the DP83867 at address 1;
   - `eth0: Link is Up - 1Gbps/Full`;
   - networkd's DHCP lease.
4. **Checks in Debian** (COM5):
   - `ip -br addr`: eth0 up with an address from the laptop, likely the A53's usual one, since the MAC is the same;
   - `cat /sys/class/net/eth0/speed`: 1000;
   - `ping -c 5` the laptop's address;
   - `sudo dmesg | grep -i -e macb -e dp83867 -e eth0`.
5. **From the laptop:**
   - SSH into the RISC-V's Debian over Ethernet.
   - Throughput: `scp` a 100 MB file each way (made with `dd if=/dev/urandom`), and `apt-get update` in Debian. Note the rates, against stage C's virtio-net (1.3 MB/s, guest-bound).
6. **The reboot** comes back to RISC-V mode with the network. Then `sudo tanager-mode arm` and a reboot give Ubuntu, with its own Ethernet as before.

**Ethernet plays no part in booting.** Without it Debian runs anyway, and the dmesg lines say where it stopped:
- no macb probe: the tree;
- no PHY found: its reset or MDIO;
- no link: the delays or the partner;
- no lease: networkd.

`tanager-mode arm` and a reboot, or the break, gives Ubuntu.

**U-Boot's hush:** an apostrophe inside double quotes is a syntax error, after which U-Boot crashes (the QEMU test found it). No string in these scripts has one.

## SD1's interrupt in RISC-V mode: the capture (s19b boot 1, 10-20)

In s19 segment b's first boot, every SD1 request timed out with its completion pending in SD1, while the UART's
interrupts still reached the same hart: the PLIC stopped delivering source 21. `sd1-irq-probe` reads, at the next
time it happens, what decides between the explanations, and then tries the one fix that tells them apart.

- **What it reads:**
  - the PLIC's view of source 21: pending, priority, the enables and thresholds of Linux's two contexts (1: hart 0, 5: hart 2);
  - SD1's interrupt status and enables, which give its line;
  - mmc0's count in `/proc/interrupts`.
- **What it writes:** a complete for 21 on context 1. It never reads a claim register, since a read there claims.
- **Reading the result:**

  | SD1's line | Pending bit 21 | Enable bit 21 (context 1) | Meaning |
  |---|---|---|---|
  | high | 0 | 1 | Source 21 was claimed and never completed. If mmc0's count rises after the kick and the I/O comes back, that's confirmed. |
  | high | 1 | 0 | The enable was lost. |
  | high | 1 | 1, with priority 1 and threshold 0 | The PLIC asserts the interrupt and the hart doesn't take it. |
- **Install, on the RISC-V's Debian (or chrooted into p3 from Ubuntu):**
  - `install -m 755 sd1-irq-probe /usr/local/sbin/`
  - `install -m 755 sd1-irq-probe.hook /etc/initramfs-tools/hooks/sd1-irq-probe`
  - `install -m 755 sd1-irq-probe.init-top /etc/initramfs-tools/scripts/init-top/sd1-irq-probe`
  - then `update-initramfs -u`
- **Kernel command line:** `iomem=relaxed`, in case Debian's `IO_STRICT_DEVMEM` keeps `/dev/mem` off the regions the drivers hold. u-boot-menu writes extlinux's `append` (`sw/build_debian.sh`), so:
  - **Change:** in `/etc/default/u-boot`, set `U_BOOT_PARAMETERS="console=ttyS0,115200 earlycon rw iomem=relaxed"`, then run `u-boot-update`.
  - **Undo:** remove `iomem=relaxed` from that line, then run `u-boot-update`.
- **The SD stress:** `sudo sd-read-stress [seconds]` (default 600) reads the card from both CPUs at once, as the boot's udev probes did.
  - It makes direct reads at random sectors, 4 KiB to 1 MiB, with a `blkid` probe of p3 every 25 reads. It is read only.
  - It prints a line per CPU every 100 reads, and stops on a `dd` failure or an mmc0 timeout.
  - Run it with `sd1-irq-probe watch &`.
- **Before relying on it:** check `busybox devmem` (the applet) and `sd1-irq-probe dump` once by hand.
- **When it runs:** the initramfs starts `watch` before the root's mount. It writes to the console and to `/run/sd1-irq-probe.log`, and stops once the real root is up. After boot, for an SD stress, `sd1-irq-probe watch &` does the same.
- **The board's watch since boot 28** ([`fpga/kv260/board/runs/sd1-irq-probe.init-top`](../../fpga/kv260/board/runs/sd1-irq-probe.init-top), the board session's): the same watch, chrooted in a RAM root of its own (`/sd1ram`, with a static busybox). It runs from the initramfs through shutdown, and `sd1-irq-watch.service` is disabled. Stop it with `sudo pkill -f "^/bin/sh /sd1-irq-probe watch"`; it comes back at the next boot.

## RISC-V mode's memory gap: the check (after s21)

sysbench memory ran about 12.7% slower in RISC-V mode than in stage C on d4r2. Nothing the two modes program differs
on the memory path or the clock's ([soc-d4-modes.md](../../docs/spec/soc-d4-modes.md)). These two tools find where
the time goes.

- **`memgap`, on the RISC-V's Debian, in both modes:**
  - Build it there: `gcc -O2 -pthread -o memgap memgap.c`.
  - Stop the watch, in each mode after each boot: `sudo pkill -f "^/bin/sh /sd1-irq-probe watch"` (the board's RAM-root watch, above).
  - Run it three times: `./memgap > memgap_<mode>_<n>.txt`, about a minute each.
  - It prints `MEMGAP <test> <value> <unit>` lines, and the `MEMGAP-IDLE-*` lines of its first 10 s (`-i`): each CPU's time by kind, and interrupts per line. Diff the two modes.
- **sysbench, to split its test:** add `--memory-scope=local` (no shared block) and `--threads=1` (no second core) to the 1 KiB and 1 MiB runs.
- **`ps-memregs`, on Ubuntu:**
  - In ARM mode before any overlay: `sudo sh ps-memregs > memregs_arm.txt`. These are the boot firmware's values, which RISC-V mode keeps; `riscv.scr` changes only `PL0_REF_CTRL` and the FPD `AFI_FS`.
  - In stage C, with the RISC-V running a 1 MiB test (`sysbench memory --memory-block-size=1M --time=60 run`): `sudo sh ps-memregs --bridge > memregs_stagec.txt`. `--bridge` adds the host bridge's registers and its native DDR read latency over 1 s.
  - **Only with a Tanager bitstream loaded:** without one, a read of the bridge hangs the A53.
  - A register this Linux may not read prints `refused`. Diff the two files.

