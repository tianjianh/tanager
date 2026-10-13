#!/bin/bash
# Fetches and builds the third-party tools of the RTL flow at the versions pinned in versions.sh.
# Run as the normal user in WSL Ubuntu-24.04, after setup_root.sh:
#   bash tools/setup_tools.sh [verilator|spike|riscv-tests|arch-test|testfloat ...]   (default: all)
# Sources go to ~/src/tanager/<tool>, one directory each; installs go to ~/opt/tanager/<tool>.
# Nothing is installed system-wide. Finished steps are skipped on a re-run.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/versions.sh"
SRC="$HOME/src/tanager"
OPT="$HOME/opt/tanager"
JOBS="$(nproc)"
XPACK="$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin"
mkdir -p "$SRC" "$OPT"

# fetch <dir> <url> <sha>: shallow checkout of one pinned commit into its own directory.
fetch() {
  local d="$SRC/$1"
  if [ -d "$d/.git" ] && [ "$(git -C "$d" rev-parse HEAD)" = "$3" ]; then return; fi
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" fetch -q --depth 1 "$2" "$3"
  git -C "$d" checkout -q FETCH_HEAD
}

build_verilator() {
  local p="$OPT/verilator-$VERILATOR_TAG"
  [ -x "$p/bin/verilator" ] && return
  fetch verilator https://github.com/verilator/verilator.git "$VERILATOR_SHA"
  cd "$SRC/verilator"
  autoconf
  ./configure --prefix="$p"
  make -j"$JOBS"
  make install
}

build_spike() {
  local p="$OPT/spike"
  [ -x "$p/bin/spike" ] && [ "$(cat "$p/SHA" 2>/dev/null)" = "$SPIKE_SHA" ] && return
  fetch riscv-isa-sim https://github.com/riscv-software-src/riscv-isa-sim.git "$SPIKE_SHA"
  mkdir -p "$SRC/riscv-isa-sim/build"
  cd "$SRC/riscv-isa-sim/build"
  ../configure --prefix="$p"
  make -j"$JOBS"
  make install
  echo "$SPIKE_SHA" > "$p/SHA"
}

# riscv-tests: the ISA tests are built with GCC 15 (xPack) for RV64.
build_riscv_tests() {
  local p="$OPT/riscv-tests"
  [ -f "$p/SHA" ] && [ "$(cat "$p/SHA")" = "$RISCV_TESTS_SHA" ] && return
  fetch riscv-tests https://github.com/riscv-software-src/riscv-tests.git "$RISCV_TESTS_SHA"
  cd "$SRC/riscv-tests"
  git submodule -q update --init --depth 1
  autoconf
  ./configure --prefix="$p" --with-xlen=64
  make -C isa -j"$JOBS" XLEN=64 RISCV_PREFIX="$XPACK/riscv-none-elf-"
  rm -rf "$p"; mkdir -p "$p/isa"
  find isa -maxdepth 1 -type f -name 'rv64*' ! -name '*.dump' -exec cp {} "$p/isa/" \;
  cp isa/*.dump "$p/isa/" 2>/dev/null || true
  echo "$RISCV_TESTS_SHA" > "$p/SHA"
}

# riscv-arch-test (ACT4): fetched now; the runner is set up in M3.
build_arch_test() {
  fetch riscv-arch-test https://github.com/riscv-non-isa/riscv-arch-test.git "$ARCH_TEST_SHA"
}

# SoftFloat and TestFloat with the RISC-V NaN specialization, for FPU test vectors.
build_testfloat() {
  local p="$OPT/testfloat"
  [ -x "$p/bin/testfloat_gen" ] && [ "$(cat "$p/SHA" 2>/dev/null)" = "$TESTFLOAT_SHA" ] && return
  fetch berkeley-softfloat-3 https://github.com/ucb-bar/berkeley-softfloat-3.git "$SOFTFLOAT_SHA"
  fetch berkeley-testfloat-3 https://github.com/ucb-bar/berkeley-testfloat-3.git "$TESTFLOAT_SHA"
  make -C "$SRC/berkeley-softfloat-3/build/Linux-x86_64-GCC" -j"$JOBS" SPECIALIZE_TYPE=RISCV
  make -C "$SRC/berkeley-testfloat-3/build/Linux-x86_64-GCC" -j"$JOBS" SPECIALIZE_TYPE=RISCV \
    SOFTFLOAT_DIR="$SRC/berkeley-softfloat-3"
  mkdir -p "$p/bin"
  cp "$SRC/berkeley-testfloat-3/build/Linux-x86_64-GCC"/{testfloat_gen,testfloat_ver,testfloat,testsoftfloat,timesoftfloat} "$p/bin/"
  echo "$TESTFLOAT_SHA" > "$p/SHA"
}

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(verilator spike riscv-tests arch-test testfloat)
for s in "${steps[@]}"; do
  echo "=== $s"
  case "$s" in
    verilator)   build_verilator ;;
    spike)       build_spike ;;
    riscv-tests) build_riscv_tests ;;
    arch-test)   build_arch_test ;;
    testfloat)   build_testfloat ;;
    *) echo "unknown step $s" >&2; exit 2 ;;
  esac
done
echo "=== done"
