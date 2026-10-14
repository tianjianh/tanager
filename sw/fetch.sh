#!/bin/bash
# Downloads the pinned sources of sw/versions.sh into $SOC_DL and checks them against sw/sha256sums.
# A file with no recorded sum is recorded on first download (trust on first use; commit the change).
#   bash sw/fetch.sh [opensbi|linux|buildroot|rvtc ...]     (default: all)
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

items=("$@"); [ ${#items[@]} -gt 0 ] || items=(opensbi linux buildroot rvtc)
for i in "${items[@]}"; do
  case "$i" in
    opensbi)   fetch "$OPENSBI_URL"   opensbi                   "$OPENSBI_TAR" ;;
    linux)     fetch "$LINUX_URL"     linux                     "$LINUX_TAR" ;;
    buildroot) fetch "$BUILDROOT_URL" buildroot                 "$BUILDROOT_TAR" ;;
    rvtc)      fetch "$RVTC_URL"      toolchain-external-custom "$RVTC_TAR" ;;
    *) echo "unknown item $i" >&2; exit 2 ;;
  esac
done
