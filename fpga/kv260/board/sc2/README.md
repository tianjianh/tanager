# DR-147 stage C: sc2 on the board, Debian 13 through U-Boot on two cores (2026-10-17)

**Package:** `sc2-smt2-c2-70` from the SoC track; bitstream sha256 `a732238f…`; `tanager-host` `1cda3c33…` (the SoC track's newest: `--blk`, `--rng`, `dma`, `vq`). Hashes in [`SHA256SUMS`](SHA256SUMS), build facts in [`summary.txt`](summary.txt), the SoC track's steps in [`package_README.txt`](package_README.txt).
- **Tree:** p0f's `aae33dc` (the `rn_fire` fix), with the virtio window and the coherent host DMA port.
- **Design:** two `smt2` cores (harts 0 and 2), 70 MHz; trace and counters on; WNS +1.057 ns; 112,905 LUTs (96.4%).
- **CAPS:** `0x12f`.
- **Debian:** the separate package `debian-trixie-20261015` ([`README.debian.txt`](README.debian.txt), [`SHA256SUMS.debian`](SHA256SUMS.debian)). It holds U-Boot 2026.07 in S-mode, and an 8 GiB disk image (409 MiB on disk) with Debian's kernel `6.12.111+deb13-riscv64`, systemd, and the user `tanager` logged in automatically.
- **How it ran:** the app `tanager-sc2`, with Linux's fan control throughout (15/255, 32–34 °C). Scripts are in [`../runs/`](../runs/) (`sc2_step1.sh`, `sc2_step2.sh`, `sc2_debian.sh`); `tg.sh shell` gained `SH_DTB`, `SH_ARGS`, `SH_KERNEL`, `SH_TIMEOUT`, `SH_USER`, `SH_POWEROFF`, `TH_DURING` and `OFF_S`. The PMOD console of all three runs is in [`uart_COM5.txt`](uart_COM5.txt).

| Step | Result |
|---|---|
| 1. `dma check` and `vq` with the cores held | **Not run as written.** After `load` the uncore stays in reset ("cores in reset, uncore in reset, L2 not ready"), and `dma check` answers "the uncore must run with the L2 ready (load first)". `vq`: "served", no requests. Sent to the SoC track. ([`step1_run1.txt`](step1_run1.txt)) |
| 2. Buildroot with `--blk` (16 MiB random image) and `--rng` | **Pass.** `virtio_blk virtio0: [vda] 32768 512-byte logical blocks`; `md5sum /dev/vda` = `39d5e266b010796028907f801b07c39d`, the host's; `/dev/hwrng` gives 64 random bytes; interrupts virtio1 72, virtio0 9. Login at 6 s, power-off at 22 s, L2 errors 0. ([`step2_run1.txt`](step2_run1.txt), [`linux_shell_step2.txt`](linux_shell_step2.txt)) |
| 3. Debian 13 via U-Boot, `--blk tanager-trixie.img` | **Pass.** See below. ([`debian_run1.txt`](debian_run1.txt), [`linux_shell_debian.txt`](linux_shell_debian.txt)) |

**Debian 13 on two Tanager cores:**
- **U-Boot 2026.07, its first run on hardware:** "Scanning virtio 0:1…", "Found /boot/extlinux/extlinux.conf", the menu, the kernel (31 MB) and initrd (41 MB) retrieved through the window and the DMA port, then "Starting kernel".
- **Debian's kernel:** `Linux version 6.12.111+deb13-riscv64 … #1 SMP Debian 6.12.111-1 (2026-09-28)`, command line `root=LABEL=tanager-root console=ttyS0,115200 earlycon rw`; `random: crng init done` at 181 s.
- **The login:** `tanager login: tanager (automatic login)` 240 s after the load.
- **In the shell:**
  - `/etc/debian_version` 13.7; `nproc` 2; `lsblk`: `vda` 8G, `vda1` on `/`; `free -m`: 942 total, 833 free.
  - `systemctl is-system-running`: **running** (no failed units).
  - `systemd-analyze`: `Startup finished in 1min 40.918s (kernel) + 2min 756ms (userspace) = 3min 41.675s`.
  - Longest units: `dev-vda1.device` 1 min 17 s, `systemd-udev-trigger` 27 s, `modprobe@drm` 18 s, `ssh` 18 s, `systemd-journald` 17 s.
- **`sudo poweroff`:** systemd stopped every unit, and the power-off reached the host 387 s after the load (`boot exit 0`).
- **Host DMA port over the run:** 18,615,356 read, 13,451,972 written, 0 dropped.
  - The unit is in doubt: step 2's 16 MiB disk read counted 2,098,563 "lines written", which is 16 MiB in 8-byte units.
- **⚠ L2 error events: 68** after the Debian run (sticky `L2_ERR`, levels `0x40044555`).
  - The Buildroot run on the same bitstream had 0, and p0f's plain boot had 0; p0f's lockstep run had 5,928.
  - So they come with heavier two-core or DMA traffic. The SoC track is identifying them.
