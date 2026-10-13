#!/bin/bash
# Shared compiler settings for tgsim workloads (GCC 15.2, newlib, tgsim bare-metal runtime).
# Full newlib (not nano): its printf handles long long, which the reports print.
TG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TG_CC="$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc"

# tg_isa_flags <isa>: compiler flags for an ISA name used throughout the reports.
tg_isa_flags() {
  case "$1" in
    rv64gc)   echo "-march=rv64gc -mabi=lp64d -mcmodel=medany" ;;
    rv64gcb)  echo "-march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64d -mcmodel=medany" ;;
    rv32im)   echo "-march=rv32im -mabi=ilp32" ;;
    rv32imac) echo "-march=rv32imac -mabi=ilp32" ;;
    rv64imac) echo "-march=rv64imac -mabi=lp64 -mcmodel=medany" ;;  # soft float, like NaxRiscv's RV64 build
    *) echo "unknown isa $1" >&2; return 1 ;;
  esac
}

# tg_link <isa> <out.elf> <cflags...> -- <sources...>
tg_link() {
  local isa="$1" out="$2"; shift 2
  local flags=() srcs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done
  shift
  srcs=("$@")
  mkdir -p "$(dirname "$out")"
  "$TG_CC" $(tg_isa_flags "$isa") "${flags[@]}" -I"$TG_ROOT/bsp" -static -nostartfiles \
    -T "$TG_ROOT/bsp/link.ld" -Wl,--gc-sections -Wl,--no-warn-rwx-segments \
    "$TG_ROOT/bsp/crt0.S" "$TG_ROOT/bsp/syscalls.c" "${srcs[@]}" -lm -o "$out"
}
