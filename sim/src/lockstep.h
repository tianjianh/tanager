// Spike lockstep checker for the commit trace (docs/spec/verification.md §3, interfaces.md §5).
// Spike is linked as a library; the Spike headers stay inside lockstep.cpp.
#pragma once

#include <cstdint>
#include <cstdio>
#include <deque>
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
  uint64_t dram_base = 0x80000000ull, dram_size = 1024ull << 20;  // the PMA's memory region (DR-151)
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

// Several harts (§3.7): how many cycles before its record another hart may read the bytes an AMO or SC wrote
// (it performs before it retires); the checkers that apply records in cycle order look this far ahead.
constexpr uint64_t ATOMIC_EARLY = 64;

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
  // Reads that showed another hart's plain store reached memory after later writes to its bytes (§3.7)
  uint64_t hart_late() const;
  // Several harts (§3.7): whether the read in record r, the next one of its hart, returned bytes only an AMO or
  // SC of another hart in `later` (records queued with later cycles) wrote. Returns that record's index; -1 when
  // r reads nothing the checker compares or Spike's memory and the windows explain its value; -2 when nothing
  // does. Records of the atomic's hart up to it then go first: the atomic performed before its record.
  int early_atomic(const tr_rec_t& r, const std::vector<const tr_rec_t*>& later);
  // The same for a deferred load's writeback w, the next record or writeback of its hart.
  int early_atomic(const tr_wb_t& w, const std::vector<const tr_rec_t*>& later);

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

// Several harts' records and writebacks, applied to a lockstep_t in cycle order (§3.7): each hart's wait in a
// queue of their own, in its order, and the earliest goes first; a read that needs an atomic of another hart queued
// with a later cycle (lockstep_t::early_atomic, up to ATOMIC_EARLY cycles) takes it first, with that hart's records
// before it. A source of records in cycle order (tg_vsim, tg_replay) holds them ATOMIC_EARLY cycles before
// draining, so that the atomic has arrived.
class hart_order_t {
 public:
  explicit hart_order_t(lockstep_t& ls, const std::vector<uint32_t>& hartids);
  void push(const tr_rec_t& r);  // r.cycle orders it
  void push(const tr_wb_t& w);   // w.cycle orders it
  // Applies every queued item of cycle `upto` or earlier (all of them with ~0); false at a mismatch
  bool drain(uint64_t upto);
  size_t queued() const;
  uint64_t early() const { return early_; }  // reads that took an atomic queued with a later cycle

 private:
  struct item_t {
    uint64_t cyc = 0, idx = 0;
    bool wb = false;
    tr_rec_t r;
    tr_wb_t w;
  };
  bool head(size_t b, unsigned busy);
  size_t index(uint32_t hart) const;
  lockstep_t& ls_;
  std::vector<uint32_t> ids_;
  std::vector<std::deque<item_t>> q_;
  uint64_t idx_ = 0, early_ = 0;
};

}  // namespace tg
