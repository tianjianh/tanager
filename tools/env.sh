# Source this in WSL Ubuntu-24.04 to put the pinned RTL tools first on PATH:
#   source tools/env.sh
_tg_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_tg_here/versions.sh"
export TANAGER_ROOT="$(cd "$_tg_here/.." && pwd)"
export TANAGER_OPT="$HOME/opt/tanager"
export VERILATOR_ROOT="$TANAGER_OPT/verilator-$VERILATOR_TAG/share/verilator"
export SPIKE_ROOT="$TANAGER_OPT/spike"
export RISCV_TESTS="$TANAGER_OPT/riscv-tests"
export PATH="$TANAGER_OPT/verilator-$VERILATOR_TAG/bin:$SPIKE_ROOT/bin:$TANAGER_OPT/testfloat/bin:$TANAGER_OPT/sail-$SAIL_VERSION/bin:$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin:$PATH"
export LD_LIBRARY_PATH="$SPIKE_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# GCC 15 for host C/C++ (harnesses, checkers). Verilator models use the g++-15 baked into
# verilated.mk when Verilator was built (tools/setup_tools.sh).
export CC=gcc-15 CXX=g++-15
# Vivado is sourced on demand by the FPGA scripts (fpga/), not here, because its settings
# script puts an older bundled toolchain on PATH.
export TANAGER_VIVADO_SETTINGS="$HOME/Xilinx/2025.2/Vivado/settings64.sh"
# Vivado admission (tools/vivado_run.sh, conventions §9): 2 slots and a 24 GB declared-memory budget on
# the 32-thread build host (39 GB WSL); 1 slot and 12 GB elsewhere. Jobs declare TANAGER_VIVADO_MEM_GB
# (default 10 for full-device runs; 4 for out-of-context unit runs).
if [ "$(nproc)" -ge 24 ]; then _tg_slots=2; _tg_vmem=24; else _tg_slots=1; _tg_vmem=12; fi
export TANAGER_VIVADO_SLOTS="${TANAGER_VIVADO_SLOTS:-$_tg_slots}"
export TANAGER_VIVADO_MEM_BUDGET="${TANAGER_VIVADO_MEM_BUDGET:-$_tg_vmem}"
unset _tg_slots _tg_vmem
# Build trees live in the Linux filesystem: builds under /mnt/c are several times slower.
export TANAGER_BUILD="${TANAGER_BUILD:-$HOME/tanager-build}"
unset _tg_here
