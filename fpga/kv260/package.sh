#!/usr/bin/env bash
# Puts together the files the KV260 loads as the PL app "tanager" (fpga/kv260/README.md, board setup):
# the build's tanager.bit.bin, tanager.dtbo compiled from dtbo/tanager.dtso, shell.json for dfx-mgr,
# the static aarch64 tanager-host, the build's summary (commit, options, timing) and SHA256SUMS.
#   fpga/kv260/package.sh <run-dir> <out-dir>
# After `source tools/env.sh && source sw/env.sh` and `make -C sw/host`.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <run-dir> <out-dir>" >&2; exit 2; }
run=$1 out=$2
here=$(cd "$(dirname "$0")" && pwd)
host=${SOC_BUILD:?source sw/env.sh first}/host/tanager-host
for f in "$run/tanager.bit.bin" "$run/reports/summary.txt" "$host"; do
  [ -f "$f" ] || { echo "$0: missing $f" >&2; exit 1; }
done
file "$host" | grep -q "ARM aarch64.*statically linked" || { echo "$0: $host is not a static aarch64 binary" >&2; exit 1; }
mkdir -p "$out"
cp "$run/tanager.bit.bin" "$run/reports/summary.txt" "$here/dtbo/shell.json" "$host" "$out/"
dtc -q -@ -W no-reg_format -W no-simple_bus_reg -I dts -O dtb -o "$out/tanager.dtbo" "$here/dtbo/tanager.dtso"
(cd "$out" && sha256sum tanager.bit.bin tanager.dtbo shell.json tanager-host summary.txt > SHA256SUMS)
echo "$out:"; cat "$out/summary.txt"
