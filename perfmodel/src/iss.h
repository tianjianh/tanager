// tgsim: functional RISC-V simulator (machine mode, bare metal). It executes the program and hands
// every retired instruction, with its addresses and outcome, to the timing model.
#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "isa.h"

namespace tg {

// Host interface (MMIO) used by the benchmark runtime in bsp/.
constexpr uint64_t MMIO_BASE = 0x10000000ull;
constexpr uint64_t MMIO_PUTC = 0x10000000ull;    // store: write one character to stdout
constexpr uint64_t MMIO_GETC = 0x10000004ull;    // load: next stdin byte, or -1 at end
constexpr uint64_t MMIO_EXIT = 0x10000008ull;    // store: exit with this code
constexpr uint64_t MMIO_MARKER = 0x10000010ull;  // store: region marker (1 = start, 2 = stop)
constexpr uint64_t MMIO_SIZE = 0x1000ull;

struct DynInst {
  uint64_t seq = 0;           // dynamic instruction number
  uint64_t pc = 0, next_pc = 0;
  const Decoded* d = nullptr; // stable pointer into the decode cache
  uint64_t addr = 0;          // effective address (memory ops)
  bool taken = false;         // control flow: actual direction
  bool mmio = false;          // memory op to the host interface
  uint8_t marker = 0;         // region marker value stored by this instruction
  uint8_t lat_hint = 0;       // divide: significant quotient bits (early-out model)
};

class Memory {
 public:
  explicit Memory(uint64_t base, uint64_t size);
  ~Memory();
  Memory(const Memory&) = delete;
  Memory& operator=(const Memory&) = delete;
  bool contains(uint64_t a, unsigned n) const { return a >= base_ && a + n <= base_ + size_ && a + n >= a; }
  uint8_t* ptr(uint64_t a) { return mem_ + (a - base_); }
  uint64_t base() const { return base_; }
  uint64_t size() const { return size_; }

 private:
  uint64_t base_, size_;
  uint8_t* mem_;
};

class Iss {
 public:
  Iss(uint64_t ram_base, uint64_t ram_size);
  // Loads an ELF image; returns false (with a message in err) on failure.
  bool load_elf(const std::string& path, std::string& err);
  // Executes one instruction. Returns false once the program has exited or faulted.
  bool step(DynInst& out);
  // Decodes the static instruction at pc (used for shadow instructions skipped by a taken branch).
  const Decoded* decode_static(uint64_t pc);

  int xlen() const { return xlen_; }
  bool exited() const { return exited_; }
  int exit_code() const { return exit_code_; }
  const std::string& error() const { return error_; }
  std::string& stdout_buf() { return out_; }
  void set_stdin(const std::string& s) { in_ = s; in_pos_ = 0; }
  uint64_t instret() const { return instret_; }
  uint64_t tohost_symbol() const { return 0; }

 private:
  const Decoded* fetch_decode(uint64_t pc);
  template <class T> bool ld(uint64_t a, T& v, DynInst& di);
  template <class T> bool st(uint64_t a, T v, DynInst& di);
  uint64_t read_csr(uint16_t c);
  void write_csr(uint16_t c, uint64_t v);
  void fault(const char* what, uint64_t pc, uint64_t a = 0);
  int64_t sx(uint64_t v) const { return xlen_ == 32 ? (int64_t)(int32_t)v : (int64_t)v; }
  uint64_t wr(uint64_t v) const { return xlen_ == 32 ? (uint64_t)(uint32_t)v : v; }

  Memory mem_;
  int xlen_ = 64;
  uint64_t pc_ = 0;
  uint64_t x_[32] = {};
  uint64_t f_[32] = {};
  uint64_t instret_ = 0;
  uint32_t fcsr_ = 0;
  std::unordered_map<uint16_t, uint64_t> csr_;
  uint64_t resv_addr_ = ~0ull;
  bool resv_valid_ = false;
  bool exited_ = false;
  int exit_code_ = 0;
  std::string error_;
  std::string out_;
  std::string in_;
  size_t in_pos_ = 0;
  std::unordered_map<uint64_t, Decoded> dcache_;
};

}  // namespace tg
