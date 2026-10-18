#!/usr/bin/env bash
# The Debian image's file system onto the RISC-V's own SD partition (docs/spec/soc.md §8.2). The partition
# holds the file system alone, LABEL=tanager-root, with no partition table of its own, so it is the virtio
# disk in stage C (tanager-host --blk /dev/mmcblk1p3; U-Boot boots it whole) and mmcblk1p3 in stage D.
# sw/build_debian.sh's 8 GiB image is larger than what is left beside the A53's 1 + 6 GiB on a 16 GB
# card, so the image's file system is shrunk to the target's size first, in place: the image stays
# bootable (its partition simply ends past its file system), and `resize2fs` grows it back. Then
# e2image copies the used blocks and the metadata, debugfs writes the backup superblocks and group
# descriptors (e2image writes only the primary ones), a smaller file system is grown to fill the target,
# and both are checked, every backup superblock included.
#   sudo sw/debian_to_partition.sh IMAGE TARGET [--force]
# IMAGE: the disk image as built (one MBR partition; root for its loop device), or a file system alone.
# TARGET: the partition (/dev/mmcblk1p3), or a regular file of the partition's size (a test; no root).
# TARGET is overwritten: the script refuses a mounted one, and one holding a file system labelled
# other than tanager-root unless --force.
# Needs e2fsprogs (e2fsck, resize2fs, e2image, dumpe2fs, debugfs), util-linux (sfdisk, losetup, blockdev,
# findmnt, blkid).
set -euo pipefail
usage() { echo "usage: $0 IMAGE TARGET [--force]" >&2; exit 2; }
die() { echo "$0: $*" >&2; exit 1; }
# Runs a command quietly (e2fsprogs print their version on stderr), showing its output only if it fails
quiet() { local out; out=$("$@" 2>&1) || { printf '%s\n' "$out" >&2; die "failed: $*"; }; }
[ $# -ge 2 ] || usage
img=$1 tgt=$2 force=${3:-}
[ -z "$force" ] || [ "$force" = --force ] || usage
for t in e2fsck resize2fs e2image dumpe2fs debugfs sfdisk blkid findmnt; do
  command -v "$t" >/dev/null || { echo "$0: $t is missing (see the header)" >&2; exit 1; }
done
[ -f "$img" ] || { echo "$0: $img is not a file" >&2; exit 1; }
[ -b "$tgt" ] || [ -f "$tgt" ] || { echo "$0: $tgt is neither a block device nor a file" >&2; exit 1; }
[ "$(realpath "$img")" != "$(realpath "$tgt")" ] || { echo "$0: IMAGE and TARGET are the same" >&2; exit 1; }

# The target: its size, not mounted, and not someone else's file system
if [ -b "$tgt" ]; then
  tbytes=$(blockdev --getsize64 "$tgt")
  if findmnt -rn -S "$tgt" >/dev/null; then echo "$0: $tgt is mounted" >&2; exit 1; fi
else
  tbytes=$(stat -c %s "$tgt")
fi
tlabel=$(blkid -o value -s LABEL "$tgt" 2>/dev/null || true)
if [ -n "$tlabel" ] && [ "$tlabel" != tanager-root ] && [ -z "$force" ]; then
  echo "$0: $tgt holds a file system labelled '$tlabel'; --force overwrites it" >&2; exit 1
fi

# The source file system: partition 1 of a disk image through a loop device, or the file itself
loop=
cleanup() { [ -z "$loop" ] || losetup -d "$loop"; }
trap cleanup EXIT
if sfdisk -d "$img" >/dev/null 2>&1; then
  [ "$(id -u)" -eq 0 ] || { echo "$0: a disk image needs root, for its loop device" >&2; exit 1; }
  loop=$(losetup -P -f --show "$img")
  src=${loop}p1
  for _ in 1 2 3 4 5; do [ -b "$src" ] && break; sleep 1; done
  [ -b "$src" ] || { echo "$0: no $src after losetup -P" >&2; exit 1; }
else
  src=$img
fi
label=$(dumpe2fs -h "$src" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')
[ "$label" = tanager-root ] || { echo "$0: $img's file system is labelled '$label', not tanager-root" >&2; exit 1; }
bs=$(dumpe2fs -h "$src" 2>/dev/null | sed -n 's/^Block size: *//p')
blocks=$(dumpe2fs -h "$src" 2>/dev/null | sed -n 's/^Block count: *//p')
tblocks=$((tbytes / bs))
echo "source: $src, $((blocks * bs >> 20)) MiB; target: $tgt, $((tbytes >> 20)) MiB"

# Shrink the source to the target's size if it is larger (resize2fs wants a fresh check first; e2fsck's
# status 1 means it fixed something)
rc=0; out=$(e2fsck -f -y "$src" 2>&1) || rc=$?
[ "$rc" -le 1 ] || { printf '%s\n' "$out" >&2; die "e2fsck found errors it could not fix in $src"; }
if [ "$blocks" -gt "$tblocks" ]; then
  min=$(resize2fs -P "$src" 2>/dev/null | sed -n 's/^Estimated minimum size of the filesystem: *//p')
  [ -n "$min" ] && [ "$min" -le "$tblocks" ] ||
    die "the file system needs $((${min:-0} * bs >> 20)) MiB, more than the target's $((tbytes >> 20)) MiB"
  echo "shrinking $src to $((tblocks * bs >> 20)) MiB (in place; resize2fs grows it back)"
  quiet resize2fs "$src" "$tblocks"
fi

# Copy the used blocks and the metadata. e2image truncates a regular file to the file system's size, so a
# file target gets its size back; fill the target. e2image writes only the primary superblock and group
# descriptors, leaving the backups' blocks as the target had them (zeros, or an older file system's), and
# a grow adds only the new groups' backups: debugfs then writes them all (e2fsck recovers a damaged
# primary from a backup, and the kernel checks them when it updates the superblock). Then check.
echo "copying"
e2image -ra -p "$src" "$tgt" 2>&1 | tr '\r' '\n' | tail -1
[ -b "$tgt" ] || [ "$(stat -c %s "$tgt")" -ge "$tbytes" ] || truncate -s "$tbytes" "$tgt"
quiet resize2fs "$tgt"
printf 'dirty\nclose -a\n' | debugfs -w -f - "$tgt" >/dev/null 2>&1 || die "debugfs could not write $tgt's backup superblocks"
# debugfs leaves the primary superblock marked not clean (the kernel would warn at mount): e2fsck checks
# the copy and marks it clean (its status 1: it changed that flag), then a read-only pass must find nothing
rc=0; out=$(e2fsck -f -y "$tgt" 2>&1) || rc=$?
[ "$rc" -le 1 ] || { printf '%s\n' "$out" >&2; die "the copy on $tgt does not check clean"; }
quiet e2fsck -f -n "$tgt"
nb=0
for b in $(dumpe2fs "$tgt" 2>/dev/null | sed -n 's/.*Backup superblock at \([0-9]*\).*/\1/p'); do
  dumpe2fs -o superblock="$b" -o blocksize="$bs" -h "$tgt" >/dev/null 2>&1 || die "$tgt's backup superblock at block $b does not read"
  nb=$((nb + 1))
done
echo "$tgt: $(blkid -o value -s LABEL "$tgt") ($(blkid -o value -s TYPE "$tgt"), UUID $(blkid -o value -s UUID "$tgt")), $(( $(dumpe2fs -h "$tgt" 2>/dev/null | sed -n 's/^Block count: *//p') * bs >> 20)) MiB, checks clean, $nb backup superblocks"
