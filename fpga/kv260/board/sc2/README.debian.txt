debian-trixie-20261015: Debian 13 (trixie) riscv64 for the board's stage C (DR-147), booted by U-Boot from
virtio-blk. Needs a bitstream with the virtio window and the host DMA port (sc2 or later: CAPS bits 2 and 8).

Built by sw/build_debian.sh (soc-2's 6add4d4) from snapshot.debian.org 2026-10-15, every download verified
(Debian's archive keys, through bookworm's keyring package). Debian's kernel 6.12.111+deb13-riscv64 and its
initrd in /boot, U-Boot's extlinux menu (u-boot-menu), user tanager logged in automatically on the serial
console, sudo without a password, no network yet (virtio-net is not served), apt on deb.debian.org.
Checked on QEMU virt (sw/qemu/debian_test.sh): U-Boot, extlinux, Debian's kernel, systemd, the autologin and
a power-off, in about 25 s emulated. U-Boot has not run on the board before: this is its first hardware run.

Files:
- u-boot.bin: U-Boot 2026.07 in S-mode (sw/build_uboot.sh); fw_jump.bin starts it where the kernel went.
- tanager-trixie.img.tar.gz: the 8 GiB disk image as a sparse tar (241 MB; about 410 MiB on disk unpacked):
    tar -xSzf tanager-trixie.img.tar.gz          # GNU tar keeps it sparse
  The guest writes to the image: unpack again for a clean one.
- SHA256SUMS: u-boot.bin, the tarball and the unpacked tanager-trixie.img.
From sc2's package: fw_jump.bin, tanager-kv260-virtio.dtb, tanager-host.

Run, after sc2's steps 1 and 2 pass:
  sudo ./tanager-host boot --fw fw_jump.bin --kernel u-boot.bin --dtb tanager-kv260-virtio.dtb --blk tanager-trixie.img
Expected on the console:
- OpenSBI, then "U-Boot 2026.07", a 2 s countdown, "Scanning virtio 0:1...", "Found /boot/extlinux/extlinux.conf",
  the menu (5 s), then "Retrieving file: /boot/vmlinux-6.12.111+deb13-riscv64" (31 MB) and the initrd (41 MB):
  72 MB through the window and the DMA port, at about `dma check`'s rate.
- Linux 6.12.111+deb13 with earlycon on the 16550, "virtio_blk virtioN: [vda] ... 8.00 GiB", "EXT4-fs (vda1):
  mounted filesystem", "Welcome to Debian GNU/Linux 13 (trixie)!", then "tanager login: tanager (automatic
  login)" and a shell. Expect minutes at 70 MHz: systemd starts about 40 units and udev loads modules.
In the shell: cat /etc/debian_version (13.x); uname -a; nproc (2); lsblk; sudo poweroff (ends the run).
If U-Boot stops at its prompt: "virtio scan; virtio info; ls virtio 0:1 /boot" show what it sees.
From a second A53 shell during the run: sudo ./tanager-host vq; sudo ./tanager-host dma status.
