# Pinned third-party software for the SoC track (sw/). Sourced by sw/fetch.sh and the build scripts.
# Change a pin only on purpose, and record why in the commit message.
# SHA-256 sums were recorded at the first download (2026-10-13) and are checked on every fetch.

OPENSBI_VER=1.9                       # riscv-software-src/opensbi, released 2026-07-01
OPENSBI_URL=https://github.com/riscv-software-src/opensbi/archive/refs/tags/v${OPENSBI_VER}.tar.gz
OPENSBI_TAR=opensbi-${OPENSBI_VER}.tar.gz
OPENSBI_REV=tg1                       # Tanager's patch set, sw/buildroot/patches/opensbi (soc.md §5): its own build folder

LINUX_VER=6.18.56                     # longterm, released 2026-10-11
LINUX_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz
LINUX_TAR=linux-${LINUX_VER}.tar.xz

BUILDROOT_VER=2026.08                 # stable, released 2026-09-04
BUILDROOT_URL=https://buildroot.org/downloads/buildroot-${BUILDROOT_VER}.tar.xz
BUILDROOT_TAR=buildroot-${BUILDROOT_VER}.tar.xz

# External RISC-V Linux toolchain for Buildroot: GCC 15.3.0, glibc 2.44, binutils 2.45.1, headers 5.10
RVTC_NAME=riscv64-lp64d--glibc--stable-2026.08-1
RVTC_URL=https://toolchains.bootlin.com/downloads/releases/toolchains/riscv64-lp64d/tarballs/${RVTC_NAME}.tar.xz
RVTC_TAR=${RVTC_NAME}.tar.xz

# External aarch64 toolchain for tanager-host, the A53 program (a static musl binary runs on the
# board's Ubuntu 22.04 or 24.04): GCC 15. Approved by the coordinator 2026-10-13. sw/fetch.sh unpacks
# it under $SOC_BUILD/tc and deletes the archive.
AATC_NAME=aarch64--musl--stable-2026.08-1
AATC_URL=https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/${AATC_NAME}.tar.xz
AATC_TAR=${AATC_NAME}.tar.xz

# U-Boot in S-mode after OpenSBI's fw_jump (DR-147: OpenSBI, U-Boot, Debian 13's own kernel), the
# Tanager fragment sw/uboot/tanager.config over qemu-riscv64_smode_defconfig; sw/build_uboot.sh
UBOOT_VER=2026.07
UBOOT_URL=https://ftp.denx.de/pub/u-boot/u-boot-${UBOOT_VER}.tar.bz2
UBOOT_TAR=u-boot-${UBOOT_VER}.tar.bz2

# Debian 13 (trixie) riscv64 for the board's stage C image (sw/build_debian.sh, DR-147): a pinned
# snapshot.debian.org date, so a rebuild gets the same packages. The image's own apt then uses the
# normal mirrors.
DEBIAN_SNAPSHOT=https://snapshot.debian.org/archive/debian/20261015T000000Z
DEBIAN_SNAPSHOT_SECURITY=https://snapshot.debian.org/archive/debian-security/20261015T000000Z

# The udb gem's binaries for ACT4 (docs/spec/verification.md §6.1): the gem downloads them at install into
# $XDG_CACHE_HOME/udb/<name>/<version>/x64 (default ~/.cache/udb), from riscv/riscv-unified-db's releases, and checks
# each against its release checksum. The disk cleanup of 10-21 deleted that cache; the user approved fetching them again
# (10-23, 22:50), by rerunning the gem's ext/udb_download/extconf.rb, into the shared tools folder that cleanups keep,
# $TANAGER_BUILD/tools/udb-deps, which tests/arch/Makefile gives udb (UDB_CACHE). The versions are the gem's pins (udb
# 0.1.17, lib/udb/*_VERSION); tests/arch/Makefile reads them here to check the folder.
UDB_DEPS_URL=https://github.com/riscv/riscv-unified-db/releases/download
UDB_Z3_VER=z3-5.1.0                   # libz3-x64.so (libz3.so in the cache)
UDB_ESPRESSO_VER=espresso-18f59c7     # espresso-x64
UDB_EQNTOTT_VER=eqntott-392759e       # eqntott-x64
UDB_MUST_VER=must-17fa9f9             # must-x64
