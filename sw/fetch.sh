#!/bin/bash
# Downloads the pinned sources of sw/versions.sh into $SOC_DL and checks them against sw/sha256sums.
# A file with no recorded sum is recorded on first download (trust on first use; commit the change).
#   bash sw/fetch.sh [opensbi|linux|buildroot|rvtc|aatc|uboot|spike ...]     (default: all but uboot and spike)
# aatc (the aarch64 toolchain for sw/host) is unpacked after the check, into $SOC_TC_DIR (default
# $SOC_BUILD/tc; $SOC_TC_SHARED to share it), and its archive deleted; it is fetched again only if
# neither this worktree nor the shared directory has it (sw/env.sh SOC_AATC).
# spike is Spike's source at tools/versions.sh's SPIKE_SHA, for tanager-lockstep on the A53
# (sim/Makefile lockstep-aarch64; docs/spec/verification.md §3.9).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/env.sh"
sums="$here/sha256sums"
touch "$sums"
mkdir -p "$SOC_DL"

fetch() {  # url subdir file   (files go to $SOC_DL/<subdir>/, Buildroot's per-package layout)
  local url="$1" d="$SOC_DL/$2" f="$3"
  mkdir -p "$d"
  if [ ! -f "$d/$f" ]; then
    echo "[fetch] $url"
    curl -fL --retry 3 -o "$d/$f.part" "$url"
    mv "$d/$f.part" "$d/$f"
  fi
  local got; got="$(sha256sum "$d/$f" | cut -d' ' -f1)"
  local want; want="$(awk -v f="$f" '$2 == f { print $1 }' "$sums")"
  if [ -z "$want" ]; then
    echo "$got  $f" >> "$sums"
    echo "[fetch] recorded sha256 of $f (first download)"
  elif [ "$got" != "$want" ]; then
    echo "[fetch] SHA-256 MISMATCH for $f: got $got, want $want" >&2
    exit 1
  else
    echo "[fetch] ok $f"
  fi
}

items=("$@"); [ ${#items[@]} -gt 0 ] || items=(opensbi linux buildroot rvtc aatc)
for i in "${items[@]}"; do
  case "$i" in
    opensbi)   fetch "$OPENSBI_URL"   opensbi                   "$OPENSBI_TAR" ;;
    linux)     fetch "$LINUX_URL"     linux                     "$LINUX_TAR" ;;
    buildroot) fetch "$BUILDROOT_URL" buildroot                 "$BUILDROOT_TAR" ;;
    rvtc)      fetch "$RVTC_URL"      toolchain-external-custom "$RVTC_TAR" ;;
    uboot)     fetch "$UBOOT_URL"     uboot                     "$UBOOT_TAR" ;;
    aatc)
      if [ -x "$SOC_AATC/bin/aarch64-buildroot-linux-musl-gcc" ]; then
        echo "[fetch] ok $AATC_NAME (unpacked in $(dirname "$SOC_AATC"))"
      else
        dest="${SOC_TC_DIR:-$SOC_BUILD/tc}"
        fetch "$AATC_URL" toolchain-aarch64 "$AATC_TAR"
        mkdir -p "$dest"
        tar -xf "$SOC_DL/toolchain-aarch64/$AATC_TAR" -C "$dest"
        rm -f "$SOC_DL/toolchain-aarch64/$AATC_TAR"
        echo "[fetch] unpacked $AATC_NAME into $dest (archive deleted)"
      fi ;;
    spike)
      SPIKE_SHA="$(source "$here/../tools/versions.sh" && echo "$SPIKE_SHA")"
      fetch "https://github.com/riscv-software-src/riscv-isa-sim/archive/$SPIKE_SHA.tar.gz" spike "spike-$SPIKE_SHA.tar.gz" ;;
    *) echo "unknown item $i" >&2; exit 2 ;;
  esac
done
