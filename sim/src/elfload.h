// ELF64 loader for RISC-V executables: PT_LOAD segments into a mem_t, plus the symbol table
// (verification.md §2.3).
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "mem.h"

namespace tg {

struct elf_segment_t {
  uint64_t paddr, filesz, memsz;
};

class elf_t {
 public:
  // Loads `path` into `mem`; exits with an error on anything but a little-endian RV64 executable.
  void load(const std::string& path, mem_t& mem);

  uint64_t entry = 0;
  std::vector<elf_segment_t> segments;

  bool has(const std::string& name) const { return syms_.count(name) != 0; }
  uint64_t sym(const std::string& name) const {
    auto it = syms_.find(name);
    return it == syms_.end() ? 0 : it->second;
  }
  // "name+0x10" for the nearest symbol at or below addr, or "" when there is none.
  std::string nearest(uint64_t addr) const;

 private:
  std::map<std::string, uint64_t> syms_;
  std::map<uint64_t, std::string> by_addr_;
};

}  // namespace tg
