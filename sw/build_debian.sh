#!/usr/bin/env bash
# Debian 13 (trixie) riscv64 disk image for the board's stage C (DR-147, docs/spec/soc.md §8.1): Debian's
# own kernel and initrd in /boot, booted by U-Boot's extlinux menu (u-boot-menu), the root file system on
# virtio-blk (tanager-host run --blk <image>).
#   sw/build_debian.sh [OUT] [SIZE_GIB] [SSH_PUBKEY]      (default $SOC_BUILD/debian/tanager-trixie.img, 8)
# Needs, on the build host: mmdebstrap, qemu-user-static with binfmt_misc (riscv64 maintainer scripts),
# e2fsprogs (mke2fs -d), fakeroot and util-linux (sfdisk). Runs without root (mmdebstrap --mode=unshare;
# the tarball is unpacked and the file system made in one fakeroot session, so the files keep root's
# ownership and the device nodes their numbers: e2fsprogs 1.47.0's mke2fs -d takes no tarball).
# The mirror is a pinned snapshot.debian.org date (DEBIAN_SNAPSHOT in sw/versions.sh), so a rebuild gets
# the same packages; the image's own apt uses deb.debian.org and updates as any Debian machine does.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/versions.sh"
out=${1:-${SOC_BUILD:?source sw/env.sh first}/debian/tanager-trixie.img}
size_gib=${2:-8}
pubkey=${3:-}
for t in mmdebstrap mke2fs fakeroot sfdisk; do
  command -v "$t" >/dev/null || { echo "$0: $t is missing (see the header)" >&2; exit 1; }
done
[ -e /proc/sys/fs/binfmt_misc/qemu-riscv64 ] || {
  echo "$0: no riscv64 binfmt handler; register it with: sudo /usr/lib/systemd/systemd-binfmt /usr/lib/binfmt.d/qemu-riscv64.conf (sw/README.md)" >&2
  exit 1; }

# The working directory must be reachable by the subordinate uids mmdebstrap's unshare mode runs as: a home
# directory (0750) or a private temp directory (0700) is not, so it sits under /tmp (TANAGER_DEBIAN_TMP
# overrides), mode 0711, and goes when the script ends. mmdebstrap's own temp directory goes inside it.
work=$(mktemp -d "${TANAGER_DEBIAN_TMP:-/tmp}/tanager-debian.XXXXXX")
chmod 0711 "$work"
trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"
mkdir -p "$(dirname "$out")"

# Debian's archive keys for trixie. The host's keyring (Ubuntu's debian-archive-keyring) stops at bookworm, and
# trixie's Release files are signed by newer keys. bookworm's own debian-archive-keyring package carries them:
# fetched from the snapshot with bookworm's signed Release file checked against the host's bookworm keys (named
# with --keyring: mmdebstrap otherwise takes the host apt's trusted keys, Ubuntu's own), and unpacked without
# running anything (variant extract), its keyring then verifies the trixie run.
host_keyring=${DEBIAN_HOST_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}
[ -r "$host_keyring" ] || { echo "$0: no $host_keyring (debian-archive-keyring, sw/README.md)" >&2; exit 1; }
mmdebstrap --mode=unshare --variant=extract --architectures=amd64 --include=debian-archive-keyring \
  --keyring="$host_keyring" bookworm "$work/keyring.tar" "deb $DEBIAN_SNAPSHOT bookworm main"
mkdir "$work/kr"
tar -C "$work/kr" -xf "$work/keyring.tar" ./usr/share/keyrings/debian-archive-keyring.gpg
keyring="$work/kr/usr/share/keyrings/debian-archive-keyring.gpg"
gpg --no-default-keyring --keyring "$keyring" --list-keys 2>/dev/null | grep -q "13/trixie" ||
  { echo "$0: bookworm's keyring package has no trixie keys" >&2; exit 1; }

# The root file system as a tarball: the packages, then our settings in a customize hook
# - virtio_mmio and virtio_blk in the initramfs: the root is on virtio-blk and both are modules
#   (docs/spec/debian-kernel.md); zstd, so the initramfs is zstd (Debian's default; without it, gzip,
#   slower to unpack at the board's clock); dbus and libpam-systemd, which mmdebstrap leaves out as
#   recommendations (systemctl and logind want the system bus)
# - u-boot-menu's command line: the 16550 console with earlycon, read-write; u-boot-update adds the root
#   from fstab (by label) and writes /boot/extlinux/extlinux.conf now and on every kernel install. No fdtdir
#   line (U_BOOT_FDT_DIR names no directory): U-Boot hands the kernel the device tree OpenSBI gave it
# - the hostname, in /etc/hosts too
# - the network (virtio-net, slot 2: tanager-host --net): systemd-networkd with DHCP on any Ethernet
#   interface, systemd-resolved for DNS (/etc/resolv.conf its stub, in place of the build host's, which
#   mmdebstrap copies in), systemd-timesyncd for the clock (the board has no RTC, and apt refuses Release
#   files from the future)
# - user tanager with its password locked: an automatic login on the serial console (ttyS0), sudo
#   without a password, SSH with the key given (none: console only)
# - apt on the normal mirrors (the image updates as any Debian machine does)
mmdebstrap --mode=unshare --architectures=riscv64 --variant=important --keyring="$keyring" \
  --include=linux-image-riscv64,u-boot-menu,initramfs-tools,zstd,systemd-sysv,dbus,libpam-systemd,systemd-resolved,systemd-timesyncd,openssh-server,sudo,ca-certificates \
  --customize-hook='printf "virtio_mmio\nvirtio_blk\n" >> "$1/etc/initramfs-tools/modules"' \
  --customize-hook='printf "U_BOOT_PARAMETERS=\"console=ttyS0,115200 earlycon rw\"\nU_BOOT_FDT_DIR=\"none\"\n" > "$1/etc/default/u-boot"' \
  --customize-hook='echo tanager > "$1/etc/hostname"' \
  --customize-hook='printf "127.0.0.1\tlocalhost\n127.0.1.1\ttanager\n::1\t\tlocalhost ip6-localhost ip6-loopback\nff02::1\t\tip6-allnodes\nff02::2\t\tip6-allrouters\n" > "$1/etc/hosts"' \
  --customize-hook='ln -sf ../run/systemd/resolve/stub-resolv.conf "$1/etc/resolv.conf"' \
  --customize-hook='printf "[Match]\nType=ether\n\n[Network]\nDHCP=yes\n" > "$1/etc/systemd/network/80-tanager.network" && chroot "$1" systemctl enable systemd-networkd' \
  --customize-hook='printf "LABEL=tanager-root / ext4 defaults 0 1\n" > "$1/etc/fstab"' \
  --customize-hook='chroot "$1" systemctl enable serial-getty@ttyS0.service' \
  --customize-hook='mkdir -p "$1/etc/systemd/system/serial-getty@ttyS0.service.d" && printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin tanager --keep-baud 115200 %%I \$TERM\n" > "$1/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf"' \
  --customize-hook='chroot "$1" useradd -m -s /bin/bash -G sudo tanager && chroot "$1" passwd -l tanager' \
  --customize-hook='echo "tanager ALL=(ALL) NOPASSWD: ALL" > "$1/etc/sudoers.d/tanager" && chmod 440 "$1/etc/sudoers.d/tanager"' \
  --customize-hook='rm -f "$1/etc/apt/sources.list.d/debian.sources"; printf "deb http://deb.debian.org/debian trixie main\ndeb http://deb.debian.org/debian trixie-updates main\ndeb http://security.debian.org/debian-security trixie-security main\n" > "$1/etc/apt/sources.list"' \
  --customize-hook='chroot "$1" update-initramfs -u -k all && chroot "$1" u-boot-update' \
  ${pubkey:+--customize-hook="mkdir -p \"\$1/home/tanager/.ssh\" && cp \"$pubkey\" \"\$1/home/tanager/.ssh/authorized_keys\" && chroot \"\$1\" chown -R tanager: /home/tanager/.ssh"} \
  trixie "$work/rootfs.tar" "deb $DEBIAN_SNAPSHOT trixie main" "deb $DEBIAN_SNAPSHOT_SECURITY trixie-security main"

# One partition (MBR) holding an ext4 file system labelled tanager-root, built from the tarball
img_mib=$((size_gib * 1024))
part_mib=$((img_mib - 1))
mkdir "$work/root"
fakeroot sh -c 'tar -C "$1" -xpf "$2" && mke2fs -q -t ext4 -L tanager-root -d "$1" "$3" "$4"' sh \
  "$work/root" "$work/rootfs.tar" "$work/part.ext4" "${part_mib}M"
rm -f "$out"                          # a fresh sparse file: dd's sparse copy skips the zero runs
truncate -s "${img_mib}M" "$out"
printf 'label: dos\nstart=2048, type=83, bootable\n' | sfdisk -q "$out"
dd if="$work/part.ext4" of="$out" bs=1M seek=1 conv=notrunc,sparse status=none
echo "$out: Debian trixie riscv64, ${size_gib} GiB, root LABEL=tanager-root (user tanager: console autologin,"
echo "SSH ${pubkey:+with the key given}${pubkey:-not set up}). Serve it with: sudo tanager-host boot --fw fw_jump.bin --kernel u-boot.bin \\"
echo "  --dtb tanager-kv260-virtio.dtb --blk $(basename "$out")"
