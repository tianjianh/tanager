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
# Concurrent Vivado jobs per machine (tools/vivado_run.sh): 3 on the 32-thread build host, else 1
# (at most 2 of them full-device runs; conventions §9).
export TANAGER_VIVADO_SLOTS="${TANAGER_VIVADO_SLOTS:-$( [ "$(nproc)" -ge 24 ] && echo 3 || echo 1 )}"
# Build trees live in the Linux filesystem: builds under /mnt/c are several times slower.
export TANAGER_BUILD="${TANAGER_BUILD:-$HOME/tanager-build}"
unset _tg_here
