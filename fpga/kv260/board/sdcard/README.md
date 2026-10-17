# The SD card: a partition for the RISC-V (DR-147, 2026-10-17)

**The user's decision:** the A53 uses a few GB at most, so its root shrinks and the rest of the card becomes the RISC-V's own partition. Stage C serves that partition whole as the virtio disk; in stage D it is the RISC-V's mmcblk root.

**The card before:** 16 GB (30,535,680 sectors, 14.56 GiB), msdos table, no free space.

**The card after:**

| Partition | Sectors | Size | What |
|---|---|---|---|
| p1 | 2,048–2,099,199 | 1 GiB | FAT `system-boot`: `image.fit`, `boot.scr.uimg`. Unchanged. |
| p2 | 2,099,200–14,682,111 | 6 GiB (was 13.6 GiB) | ext4 `writable`, the A53's root: 1,572,864 blocks, 3.4 GB used |
| p3 | 14,682,112–30,535,679 | 7,741 MiB (new) | The RISC-V's root: Debian's file system alone, `LABEL=tanager-root`, no partition table of its own |

**Every change and its undo** are in the change log of [`../../README.md`](../../README.md) ("A53 OS changes"). **The backups** are on the laptop: `C:\KV260-backup\2026-10-17\` (`SHA256SUMS`).

## Steps 1 and 2: cleanup and sizing

- **Cleanup:** the Debian images on the A53 were deleted, once the gcc/sysbench image's sha256 (`d72f3872…`) matched the laptop backup's. Use went from 8.0 GB to 3.3 GB.
- **The gate:** `resize2fs -P` estimated a minimum of 1,258,730 blocks (4,916 MiB). × 1.1 is 5,408 MiB, within the 6,094 MiB target.
  - The estimate is high: on a mounted root, the counts on disk still predate the deletions. The initramfs's e2fsck later counted 940,130 blocks in use (3.6 GiB).

## Step 3: the one-shot shrink at boot, two runs

**The tool:** [`../runs/tg-shrink-root.premount`](../runs/tg-shrink-root.premount) with its [`.hook`](../runs/tg-shrink-root.hook) (commit `36058e2`, reviewed by the coordinator).
- It is a local-premount script in the A53's initramfs, armed by `tg-shrink-root.go` on p1 and renamed to `.ran` first, so it runs once.
- **Before arming:**
  - `image.fit.pre-shrink` saved, a byte-identical copy of the known-good FIT;
  - `update-initramfs -u`, and `lsinitramfs` listed the script with resize2fs, sfdisk, dumpe2fs, e2fsck and blockdev, and their libraries;
  - the new FIT's `mkimage -l` differed from the old only in the ramdisk's size.
- **The console:** [`uart_COM7_shrink.txt`](uart_COM7_shrink.txt), the A53's serial console (COM7) through both runs and one more boot.

**Run 1** (the boot at 21:49 board time), [`shrink_run1_p1.log`](shrink_run1_p1.log), the step's log as saved on p1:
- **`e2fsck -f -y`:** status 1. It fixed 3 inodes on the orphan list and shortened 8 extent trees.
- **`resize2fs`** to 6,094 MiB took about 5 min; then `e2fsck -n` was clean: 908,139 of 1,560,064 blocks.
- **`sfdisk --no-reread -N 2`:** p2 became 12,582,912 sectors. The script checked the table on disk, the re-read worked, and `e2fsck -n` on the new p2 was clean. "TG-SHRINK: done".
- **Then cloud-init undid it** ([`shrink_run1_cloud-init.txt`](shrink_run1_cloud-init.txt)).
  - 16 s into the boot, `cc_growpart` logged "'/' resized: changed (/dev/mmcblk1p2) from 6442450944 to 14559460864".
  - `cc_resizefs` then grew the filesystem online, from 1,560,064 to 3,554,555 blocks.
  - Ubuntu's `cloud.cfg` runs both modules with "frequency always". An online grow is safe, so nothing was lost; the A53 ran normally on its old size.
  - **The fix:** `/etc/cloud/cloud.cfg.d/99-tanager-root-size.cfg`, with `growpart: {mode: 'off'}` and `resize_rootfs: false`. `cloud-init single` showed both modules skipped.
  - **The rule:** Ubuntu's cloud-init regrows the root on every boot, so a shrink must disable it first. The rehearsal on a loop disk could not show this, because it happens later in the real boot.

**Run 2** (the boot at 22:00), [`shrink_run2_p1.log`](shrink_run2_p1.log):
- The same steps, all clean. `resize2fs` took about 20 s, since run 1 had already moved the data low.
- p2 held at 12,582,912 sectors through the boot; cloud-init logged "growpart disabled: mode=off" and "Skipping module named resizefs, resizing disabled".

## Step 4: the grow, p3, and back to the standard initramfs

- **The grow:** an online `resize2fs /dev/mmcblk1p2` grew the filesystem from 1,560,064 to 1,572,864 blocks, filling p2.
- **p3:** `echo ",+,83" | sfdisk --force --no-reread --append /dev/mmcblk1` made sectors 14,682,112–30,535,679. sfdisk told the kernel itself, so the plan's `partx -a` was unnecessary: it reports "error adding partition 3", which is harmless. `blkid -p` found only the partition entry.
- **The hook removed:** then `update-initramfs -u`. The initramfs again has the same 2,509 files as before the hook. The FIT differs from `image.fit.pre-shrink` only in its ramdisk.
- **One more A53 reboot (22:07):**
  - the layout held, and cloud-init skipped both modules;
  - systemd reached "running", `fancontrol` is active (pwm 17/255), `k26-starter-kits` is loaded, and the command line is unchanged.

## Step 5: Debian on p3, and the boot check: pass

**The image:**
- our gcc/sysbench Debian image, restored from the laptop backup with `tar -xSzf` on the A53 (1 min 52 s);
- its sha256 `d72f3872…c473a` checked against the backup's, and the SoC track's `sdpart-20261017` package checked against its `SHA256SUMS`.

**Onto p3:** `sudo debian_to_partition.sh tanager-trixie.img.bench /dev/mmcblk1p3` (the SoC track's script), [`to_p3.log`](to_p3.log).
- It shrank the image's filesystem in place from 8,191 to 7,741 MiB, then copied 380,780 blocks with e2image in 3 min 4 s (8.08 MB/s).
- It ended "`/dev/mmcblk1p3: tanager-root (ext4, UUID 45d8e126-fa57-4bee-8133-ba472bb7b0c6), 7741 MiB, checks clean, 8 backup superblocks`".
- The A53's copy of the image was then deleted (the laptop keeps the original), leaving the root at 3.4 GB used.

**The check:** [`../runs/p3_test.sh`](../runs/p3_test.sh), which runs [`../runs/sc3_p3.sh`](../runs/sc3_p3.sh) twice; its log is [`p3_test.txt`](p3_test.txt).
- **The setup:** sc3 (two `smt2` cores, 100 MHz), `tanager-host` `52329089`, `--blk /dev/mmcblk1p3 --rng`, and the package's `u-boot.bin` (`be25ec42…`) with sc3's `fw_jump.bin` and virtio device tree.

| Step | Result |
|---|---|
| Boot 1 ([`linux_shell_p3_w.txt`](linux_shell_p3_w.txt)) | U-Boot: `Retrieving file: /boot/extlinux/extlinux.conf` straight from the whole disk (no "Error reading" line), menu entry 1, Debian 13's `6.12.113+deb13-riscv64` with `root=LABEL=tanager-root`. `virtio_blk virtio0: [vda] 15853568 512-byte logical blocks (8.12 GB/7.56 GiB)`, exactly p3. `findmnt`: `/dev/vda ext4 7.3G`, UUID `45d8e126…`. Login at 191 s. 64 MiB written with `conv=fsync`, sha256 `22f5df5722052f1862c6db93ee4f3a1c1e84faf32d36aafcf32b11001524302e`. `sudo poweroff`: `reboot: Power down` at 283 s, `boot exit 0` |
| `sudo e2fsck -fn /dev/mmcblk1p3` on the A53 | Passes 1–5 clean: `tanager-root: 22904/499712 files (0.1% non-contiguous), 397283/1981696 blocks`, exit 0 |
| Boot 2 ([`linux_shell_p3_v.txt`](linux_shell_p3_v.txt)) | **`/var/tmp/blktest: OK`**. Power-off at 252 s, `boot exit 0` |

- **During both boots:** Linux's fan control (pwm 15/255, 33–34 °C), then back to `k26-starter-kits`.

**So:** the RISC-V boots Debian 13 from its own partition on the SD card, through the standard extlinux path, with its own kernel. Writes survive a clean power-off, and the filesystem checks clean on the A53. Stage D's root disk is in place.
