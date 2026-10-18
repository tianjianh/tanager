# Tanager software (SoC track)

Design: [docs/spec/soc.md](../docs/spec/soc.md) §3–§6, [docs/spec/host.md](../docs/spec/host.md).
Run everything after `source tools/env.sh && source sw/env.sh`. Build trees go to `$SOC_BUILD`
(`$TANAGER_BUILD/<worktree>`), downloads to `$SOC_DL`. The Bootlin toolchains are unpacked once: a worktree
uses its own `$SOC_BUILD/tc` if it has one, else the shared `$TANAGER_BUILD/tc` (`sw/env.sh` `SOC_AATC`,
`SOC_RVTC`), so other worktrees and CI build `tanager-host` and OpenSBI without a copy of their own;
`SOC_TC_DIR=$TANAGER_BUILD/tc bash sw/fetch.sh aatc` installs into the shared directory.

| Path | What | Command |
|---|---|---|
| `versions.sh`, `sha256sums` | pinned OpenSBI, Linux, Buildroot, Bootlin toolchains, with checksums | `bash sw/fetch.sh` |
| `buildroot/` | Buildroot external tree: `tanager_lp64d` (OpenSBI 1.9 fw_jump, Linux 6.18.56, busybox initramfs built in) | `bash sw/build_linux.sh` |
| `buildroot/configs/tanager_lp64d_bench_defconfig` | the bench image (DR-141): `tanager_lp64d` plus the SBI PMU driver (user-mode `rdcycle`, `board/tanager/linux-bench.fragment`) and the verification track's Linux workload set (package `tg-lbench`, from `tests/bench/linux`; it runs at boot with `tanager.bench=1` and powers off). `tanager_lp64d` stays the reference image for tb_boot, lockstep and the cycle-identical boot | `bash sw/build_linux.sh tanager_lp64d_bench` |
| `dts/` | device trees for the plan §5.4 map: `tanager-kv260.dts`, `tanager-qemu.dts` | `make -C sw/dts CORES=2 THREADS=1 MEM=0x40000000 FPU=1` |
| `qemu/boot_test.sh` | boots the images on QEMU virt with the Tanager tree; PASS/FAIL | `bash sw/qemu/boot_test.sh 2 1` |
| `bootrom/` | boot ROM source; regenerates `rtl/uncore/bootrom/tg_bootrom_img_pkg.sv` | `make -C sw/bootrom` / `make -C sw/bootrom check` |
| `dts/` `VIRTIO=1` | the same trees with the forwarded virtio window's four slots (soc.md §8.1), for bitstreams built with `TG_VIRTIO_WINDOW=1` | `make -C sw/dts CORES=2 THREADS=2 RUN_THREADS=1 VIRTIO=1` |
| `dts/` `UART1=1` | the KV260 tree with the PS's UART1, the board's USB serial port, as the stdout path and a second console, through the PS window (stage D's D3, soc.md §8.2, DR-163), for bitstreams built with `TG_PS_WINDOW=1`, after the A53 releases its getty | `make -C sw/dts CORES=2 THREADS=2 RUN_THREADS=1 UART1=1` |
| `uboot/`, `build_uboot.sh` | U-Boot 2026.07 in S-mode after OpenSBI (DR-147): `qemu-riscv64_smode_defconfig` plus `uboot/tanager.config`. Its boot command tries extlinux on the first virtio disk as a whole (the RISC-V's SD partition: a file system with no partition table), then distro boot | `bash sw/build_uboot.sh` |
| `build_debian.sh` | Debian 13 riscv64 disk image for stage C (DR-147): Debian's kernel and initrd booted by U-Boot's extlinux menu, root on virtio-blk, from a pinned snapshot.debian.org date with every download verified (below). Needs the build-host packages below | `bash sw/build_debian.sh [OUT] [GiB] [ssh.pub]` |
| `qemu/debian_test.sh` | boots that image on QEMU virt through OpenSBI, U-Boot's extlinux menu and Debian's kernel to the serial autologin, then powers off (QEMU's own device tree: checks the image and U-Boot, not the board's tree); PASS/FAIL | `bash sw/qemu/debian_test.sh [image]` |
| `debian_to_partition.sh` | the image's file system onto the RISC-V's own SD partition (docs/spec/soc.md §8.2): shrunk in place to the partition's size if larger, its used blocks copied (`e2image -ra`), grown to fill the partition, both checked; the partition then holds `LABEL=tanager-root` alone, for `tanager-host --blk` in stage C and the RISC-V's own SD driver in stage D | `sudo sw/debian_to_partition.sh IMAGE /dev/mmcblk1p3` |
| `host/` | `tanager-host`, the A53 control program, with the virtio back-ends (`virtio.c`: blk, net on a TAP device, rng) and their external-write records for board lockstep (`extwrite.c`) | `make -C sw/host` (aarch64) / `make -C sw/host native` / `make -C sw/host test` |

**Build-host packages for the Debian image** (installed 2026-10-17, the user's OK through the coordinator, DR-147):
`sudo apt install mmdebstrap qemu-user-static binfmt-support` gave mmdebstrap 1.4.3-6, qemu-user-static
1:8.2.2+ds-0ubuntu1.18 and binfmt-support 2.2.2-7, with arch-test 0.21-1 and uidmap 1:4.13+dfsg1-4ubuntu3.2 as
dependencies; then `sudo apt install debian-archive-keyring` (2023.4ubuntu1; the user's OK of 10-17), Debian's archive
public keys through bookworm (12).
- **Trust path:** the host's keyring verifies bookworm's signed Release file on the snapshot; `build_debian.sh` takes
  bookworm's own `debian-archive-keyring` from it (2023.3+deb12u2, which adds the trixie keys), unpacks it without
  running anything, and verifies trixie's and trixie-security's Release files with its keyring. apt checks every
  package against the signed indices, so nothing unverified enters the image.
- **Handlers:** only `qemu-riscv64` is registered, with flags `POF` (the interpreter is opened at registration,
  so it works inside mmdebstrap's user namespace), by `sudo /usr/lib/systemd/systemd-binfmt
  /usr/lib/binfmt.d/qemu-riscv64.conf`. systemd-binfmt does not run in this WSL instance, so the other qemu
  architectures' files in `/usr/lib/binfmt.d` stay unregistered, and after a WSL restart that command has to be
  run again (`build_debian.sh` stops with this hint when the handler is missing).
- **Undo:** `echo -1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-riscv64`, then `sudo apt remove mmdebstrap
  qemu-user-static binfmt-support arch-test uidmap debian-archive-keyring`.

Image layout in the carve-out (soc.md §3): `fw_jump.bin` at +0, `Image` at +0x20_0000, DTB at
+0x220_0000. The kernel's effective size must stay below 32 MiB (`build_linux.sh` checks it).

QEMU results (2026-10-13): PASS for 1 core x 1 thread, 2 x 1 (`st`) and 2 x 2 (`smt2`). The Debian image
(2026-10-17, snapshot 20261015, kernel 6.12.111+deb13): `debian_test.sh` PASS, from U-Boot to the login in about
25 s of emulated time. The image is 8 GiB sparse, about 410 MiB written; U-Boot loads 72 MB (the 31 MB kernel and
a 41 MB initrd, 32 MB of it the xz-compressed modules of `MODULES=most`). On the board (sc2, 70 MHz) it reaches
the autologin about 240 s after the load, and networkd brings eth0 up a minute or two later: a script waits with
`systemd-networkd-wait-online -i eth0 -4` before network work.
