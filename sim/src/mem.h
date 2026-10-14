// Sparse physical memory for the harness models and the program image (verification.md §2.3).
#pragma once

#include <cstdint>
#include <cstring>
#include <memory>
#include <unordered_map>

namespace tg {

class mem_t {
 public:
  static constexpr unsigned CHUNK_BITS = 16;  // 64 KiB chunks, allocated on first write
  static constexpr uint64_t CHUNK = 1ull << CHUNK_BITS;

  void read(uint64_t addr, size_t len, void* dst) const {
    auto* d = static_cast<uint8_t*>(dst);
    while (len) {
      uint64_t off = addr & (CHUNK - 1);
      size_t n = std::min<uint64_t>(len, CHUNK - off);
      const uint8_t* c = find(addr);
      if (c) memcpy(d, c + off, n); else memset(d, 0, n);
      addr += n; d += n; len -= n;
    }
  }

  void write(uint64_t addr, size_t len, const void* src) {
    auto* s = static_cast<const uint8_t*>(src);
    while (len) {
      uint64_t off = addr & (CHUNK - 1);
      size_t n = std::min<uint64_t>(len, CHUNK - off);
      memcpy(get(addr) + off, s, n);
      addr += n; s += n; len -= n;
    }
  }

  // Writes the bytes of `src` whose bit is set in `mask` (bit i = byte i), as TileLink puts do.
  void write_masked(uint64_t addr, size_t len, const void* src, uint64_t mask) {
    auto* s = static_cast<const uint8_t*>(src);
    for (size_t i = 0; i < len; i++)
      if ((mask >> i) & 1) write(addr + i, 1, s + i);
  }

  uint64_t read64(uint64_t addr) const { uint64_t v; read(addr, 8, &v); return v; }
  uint32_t read32(uint64_t addr) const { uint32_t v; read(addr, 4, &v); return v; }
  void write64(uint64_t addr, uint64_t v) { write(addr, 8, &v); }

  // Calls f(base, ptr) for every allocated chunk, in no particular order.
  template <class F> void for_each_chunk(F f) const {
    for (auto& [k, p] : chunks_) f(k << CHUNK_BITS, p.get());
  }

 private:
  const uint8_t* find(uint64_t addr) const {
    uint64_t k = addr >> CHUNK_BITS;
    if (k == last_key_ && last_) return last_;
    auto it = chunks_.find(k);
    if (it == chunks_.end()) return nullptr;
    last_key_ = k; last_ = it->second.get();
    return last_;
  }
  uint8_t* get(uint64_t addr) {
    uint64_t k = addr >> CHUNK_BITS;
    if (k == last_key_ && last_) return last_;
    auto& p = chunks_[k];
    if (!p) { p.reset(new uint8_t[CHUNK]); memset(p.get(), 0, CHUNK); }
    last_key_ = k; last_ = p.get();
    return last_;
  }

  std::unordered_map<uint64_t, std::unique_ptr<uint8_t[]>> chunks_;
  mutable uint64_t last_key_ = ~0ull;
  mutable uint8_t* last_ = nullptr;
};

}  // namespace tg
