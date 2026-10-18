#!/bin/bash
# The A53's handover tree for stage D's D4 (docs/spec/soc.md §8.2), from its live tree (sudo cat
# /sys/firmware/fdt on the board): SD1 (mmc@ff170000) and UART1 (serial@ff010000) become generic-uio devices
# without interrupts, so the handover kernel maps them but never drives them, while their power domains keep
# them requested from the PMU firmware (the board's command line already has uio_pdrv_genirq.of_id=generic-uio);
# the console leaves UART1, and kexec sets the command line; the host bridge's node marks our design in the PL
# for tanager-host's check. Needs dtc's fdtget and fdtput.
#   bash sw/handover/handover_dtb.sh <fdt-live.dtb> <handover.dtb>
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <fdt-live.dtb> <handover.dtb>" >&2; exit 2; }
in=$1 out=$2
nodes="/axi/mmc@ff170000 /axi/serial@ff010000"
cp "$in" "$out"
for n in $nodes; do
  fdtget "$out" "$n" compatible >/dev/null || { echo "$in has no $n" >&2; exit 1; }
  fdtput -t s "$out" "$n" compatible generic-uio
  for p in interrupts interrupts-extended; do
    fdtget "$out" "$n" "$p" >/dev/null 2>&1 && fdtput -d "$out" "$n" "$p"
  done
done
for p in stdout-path bootargs; do
  fdtget "$out" /chosen "$p" >/dev/null 2>&1 && fdtput -d "$out" /chosen "$p"
done
# The host bridge's node, as the overlay adds it but without its interrupt. tanager-host touches the PL only
# while this node is in the live tree (check_overlay), and the handover kernel applies no overlay, though
# handover.sh checks that our design holds the PL just before the kexec, which leaves the PL as it is.
fdtput -c "$out" /axi/tanager@a0000000
fdtput -t s "$out" /axi/tanager@a0000000 compatible generic-uio
fdtput -t x "$out" /axi/tanager@a0000000 reg 0 0xa0000000 0 0x10000
for n in $nodes; do
  echo "$n: compatible $(fdtget "$out" "$n" compatible), status $(fdtget -d okay "$out" "$n" status)," \
       "power-domains $(fdtget -d none "$out" "$n" power-domains)"
done
sha256sum "$in" "$out"
