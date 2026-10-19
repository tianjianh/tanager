#!/bin/bash
# The vendor's URAM288_BASE model (the Vivado installation's unisims source) made compilable by Verilator,
# for tb_urf (spikes.md §8.14): Verilator has no tristate inputs, so the model's defaults for unconnected
# pins, "(X !== 1'bz) && ..." (rv 0) and "(X === 1'bz) || ..." (rv 1), lose their z test. tg_urf drives
# every pin, so the model behaves the same; nothing else changes.
#   sim/vendor_uram_vl.sh <out.v>
src=${XILINX_VIVADO:-$HOME/Xilinx/2025.2/Vivado}/data/verilog/src/unisims/URAM288_BASE.v
sed -E -e "s/\(([A-Za-z_0-9]+(\[[0-9]+\])?) !== 1'bz\) && //g" \
       -e "s/\(([A-Za-z_0-9]+(\[[0-9]+\])?) === 1'bz\) \|\| //g" \
       -e "s/^(\s*)tri0 glblGSR/\1wire glblGSR/" "$src" > "$1"
echo "$(grep -c "1'bz" "$1") z tests left in $1"
