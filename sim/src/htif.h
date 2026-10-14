// The tohost convention seen through the commit trace (docs/spec/verification.md §2.6).
#pragma once

#include <cstdint>
#include <set>

namespace tg {

// Tracks the 8 bytes of tohost (and its aliases) from retired stores. A command is complete when a
// store reaches its top byte: a 64-bit store, or the high half of riscv-tests' and ACT4's
// "sw value, tohost; sw high, tohost+4".
struct tohost_watch_t {
  std::set<uint64_t> va;  // tohost and its virtual aliases
  uint64_t shadow = 0;

  // True when the store completes a command; `value` is then the whole 64-bit tohost value.
  bool store(uint64_t vaddr, uint64_t wdata, unsigned size_log2, uint64_t& value) {
    for (uint64_t b : va) {
      if (vaddr < b || vaddr - b >= 8) continue;
      unsigned off = unsigned(vaddr - b), n = 1u << size_log2;
      for (unsigned i = 0; i < n && off + i < 8; i++) {
        uint64_t byte = (wdata >> (8 * i)) & 0xff;
        shadow = (shadow & ~(0xffull << (8 * (off + i)))) | (byte << (8 * (off + i)));
      }
      if (off + n < 8) return false;
      value = shadow;
      return true;
    }
    return false;
  }

  // Decoded command: an exit with a code, a console character, or nothing.
  static bool is_exit(uint64_t v) { return (v >> 48) != 0x0101 && (v & 1); }
  static bool is_putchar(uint64_t v) { return (v >> 48) == 0x0101; }
};

}  // namespace tg
