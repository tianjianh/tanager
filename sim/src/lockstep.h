// Spike lockstep checker for the commit trace (docs/spec/verification.md §3, interfaces.md §5).
// Spike is linked as a library; the Spike headers stay inside lockstep.cpp.
#pragma once

#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "elfload.h"
#include "mem.h"
#include "trace.h"

namespace tg {

struct lockstep_cfg_t {
  std::string isa = "rv64im_zicsr_zifencei";
  std::string priv = "M";
  std::vector<uint32_t> hartids = {0};
  uint64_t boot_pc = 0x80000000ull;
  unsigned pmp_regions = 16;
  unsigned pmp_granularity = 4;
  bool pmp_reset_off = false;
  unsigned history = 32;
  // Memory map (tg_map_pkg)
  uint64_t dram_base = 0x80000000ull, dram_size = 2048ull << 20;
  uint64_t rom_base = 0x1000, rom_size = 0x1000;
  std::vector<std::pair<uint64_t, uint64_t>> dev_regions;
};

class lockstep_impl_t;

class lockstep_t {
 public:
  lockstep_t(const lockstep_cfg_t& cfg, const mem_t& image, const elf_t* elf);
  ~lockstep_t();

  // One cycle of the trace: records in slot order, then writebacks (§3.5 for the order).
  // Returns false at the first mismatch; the checker then ignores further input.
  bool cycle(const std::vector<tr_rec_t>& recs, const std::vector<tr_wb_t>& wbs);
  // End of run: deferred writebacks still pending are a mismatch.
  bool finish();

  size_t pending_wbs() const;
  bool failed() const;
  const std::string& error() const;
  // The divergence report of §3.6.
  void report(FILE* f) const;
  std::string disasm(uint32_t insn) const;
  // Spike's architectural memory, by physical address.
  uint64_t read_mem64(uint64_t paddr) const;
  uint64_t steps() const;

 private:
  std::unique_ptr<lockstep_impl_t> impl_;
};

}  // namespace tg
