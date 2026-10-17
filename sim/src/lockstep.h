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
  std::vector<std::pair<uint64_t, uint64_t>> deny;  // --deny ranges: Spike faults on them too
  // External writes (§3.10): a hart may still read a write's old bytes for this many of its own records
  // after the write's cycle (a load that read before the write commits later: at most a ROB's worth), and
  // its new bytes from this many cycles before (the L2 may serve them before its AccessAck).
  unsigned ext_window = 512;
  uint64_t ext_early = 256;
  // Other harts' writes (§3.7): with several harts, a hart may still read the bytes another hart's store,
  // AMO or SC replaced for this many of its own records after it (a store waits in the store queue after
  // it commits, a load reads before it commits); 0 turns the windows off.
  unsigned hart_window = 512;
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
  // A deferred writeback pending for more than `limit` cycles at cycle `now` is a mismatch.
  bool check_stale(uint64_t now, uint64_t limit);
  // A write into main memory by another master (the host's DMA through the L2, soc.md §8.1), visible from
  // `cycle` on: `len` bytes (at most 32) from physical address `paddr`, byte i written when bit i of `mask`
  // is set. It must arrive before any record of `cycle` or later (§3.10).
  bool external_write(uint64_t paddr, const uint8_t* data, uint32_t mask, unsigned len, uint64_t cycle);
  // Loads that returned an external write's new bytes, and the writes still in a hart's window.
  uint64_t ext_loads_new() const;
  size_t ext_pending() const;
  // Loads, LRs and AMOs that read bytes another hart's write had replaced in Spike's memory (§3.7), and the
  // stores an AMO or a successful SC read past, which then followed it into Spike's memory.
  uint64_t hart_loads_old() const;
  uint64_t hart_reapplied() const;

  size_t pending_wbs() const;
  bool failed() const;
  const std::string& error() const;
  // The divergence report of §3.6.
  void report(FILE* f) const;
  std::string disasm(uint32_t insn) const;
  // Spike's architectural memory, by physical address.
  uint64_t read_mem64(uint64_t paddr) const;
  uint64_t steps() const;
  // Whether the checker compares a retire record's destination value with Spike's: not for values it
  // adopts from the RTL (mmio_ld, nondet, reads of the CSRs on its list; §3.4), nor while one is
  // deferred (its writeback is compared instead).
  static bool compares_value(const tr_rec_t& r);

 private:
  std::unique_ptr<lockstep_impl_t> impl_;
};

}  // namespace tg
