# Pinned third-party tool versions for the RTL flow (sourced by setup_tools.sh).
# Change a pin only on purpose, and record why in the commit message.

VERILATOR_TAG=v5.052          # released 2026-09-05
VERILATOR_SHA=ea338be98e1e838d3518809ce8899f85a009963c

SPIKE_SHA=f8a060b7bea8da6f738f193ed1b66b665978d092        # riscv-software-src/riscv-isa-sim, master 2026-10-13
RISCV_TESTS_SHA=7b68f7b91f827f8d94cc1c57ff123752c5c8f704  # riscv-software-src/riscv-tests, master 2026-10-13
ARCH_TEST_SHA=729288a56b7628c6464b3a229e3862abd4f56245    # riscv-non-isa/riscv-arch-test, act4 branch 2026-10-13
SOFTFLOAT_SHA=a0c6494cdc11865811dec815d5c0049fba9d82a8    # ucb-bar/berkeley-softfloat-3
TESTFLOAT_SHA=a9c849f1b0eb0264b626d9686ffae167d996e3be    # ucb-bar/berkeley-testfloat-3

# Already installed, not built here:
#   Vivado 2025.2 at ~/Xilinx/2025.2/Vivado (D3)
#   xPack riscv-none-elf-gcc 15.2.0-1 at ~/opt (perfmodel/scripts/fetch_deps.sh)
