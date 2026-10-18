#!/bin/sh
# dkms.conf's PRE_BUILD, in the DKMS build directory: extracts the two drivers, and the SD host headers the
# Arasan driver includes, from Debian's linux-source tarball (apt install linux-source-6.12). Its 6.12.y can
# be a little newer than the running kernel's; the stable series keeps these interfaces.
set -e
t=/usr/src/linux-source-6.12.tar.xz
[ -f "$t" ] || { echo "tanager-ps: no $t (apt install linux-source-6.12)" >&2; exit 1; }
p=linux-source-6.12/drivers
tar -xJf "$t" --strip-components=4 \
  "$p/mmc/host/sdhci-of-arasan.c" "$p/mmc/host/sdhci.h" "$p/mmc/host/sdhci-pltfm.h" \
  "$p/mmc/host/cqhci.h" "$p/mmc/host/sdhci-cqhci.h" "$p/tty/serial/xilinx_uartps.c"
ls -la *.c *.h
