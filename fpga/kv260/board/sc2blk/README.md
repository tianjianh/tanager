# DR-147 stage C/D: virtio-blk from a block device, the way the RISC-V's own SD partition will be served (2026-10-17)

**Why:** the RISC-V's own partition will be a block device (`/dev/mmcblk1p3`, or `/dev/sdX` on a USB disk), not an image file.
- **The concern:** for a block device `st_size` is 0.
- **The fix, already in place:** the SoC track's `c2cc421` sizes one with `ioctl(BLKGETSIZE64)` when `S_ISBLK`, and does `fsync` on a virtio flush request and at exit.
- **The binary:** that commit is in `tanager-host` `a88547b` (`52329089…`), the one installed on the board.
- **No partition yet:** the SD card has no free space (the coordinator has put the card question to the user), so this test uses a loop device of the Debian image file.

**The test** ([`blk_test.txt`](blk_test.txt); [`../runs/sc2_blk_test.sh`](../runs/sc2_blk_test.sh), [`../runs/sc2_blkdev.sh`](../runs/sc2_blkdev.sh)):
- **Setup:** sc2 (two `smt2` cores, 70 MHz), sc2netc's Debian image with gcc and sysbench, and `--blk /dev/loop8 --rng`, no network.
- **The loop device:** `losetup` attaches it before each boot and detaches it after (temporary, nothing persisted).

| Step | Result |
|---|---|
| The loop device | `/dev/loop8`, 8,589,934,592 bytes |
| Boot 1: what Debian sees ([`linux_shell_blk_w.txt`](linux_shell_blk_w.txt)) | `virtio_blk virtio0: [vda] 16777216 512-byte logical blocks (8.59 GB/8.00 GiB)`; `lsblk`: `vda` 8G, `vda1` 8G on `/` |
| Boot 1: write | `dd if=/dev/urandom of=/var/tmp/blktest bs=1M count=64 conv=fsync`; sha256 `2b48f164c85ef48301f2bf6039600b4cffd6896be22ffcb097c2a35f54e7ab14` saved, `sync`, then `sudo poweroff` (power-off at 399 s, `boot exit 0`); `virtio: 8277 requests, 118 MiB read, 71 MiB written` |
| fsck, read-only, after boot 1 | `e2fsck -fn` on the image's root partition (a second, read-only loop device with partitions): passes 1–5 clean, `tanager-root: 22904/524288 files (0.1% non-contiguous), 398813/2096896 blocks`, exit 0 |
| Boot 2: verify ([`linux_shell_blk_v.txt`](linux_shell_blk_v.txt)) | `sha256sum -c /var/tmp/blktest.sha256`: **`/var/tmp/blktest: OK`**; power-off at 360 s, `boot exit 0` |

**So:** `tanager-host` serves a block device at its full size, and writes survive a clean power-off: the filesystem checks clean and the data matches. When the RISC-V's own partition exists, `--blk /dev/<partition>` is all it takes.
