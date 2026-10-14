// The trace sink behind trace_stall_i (interfaces.md §5; verification.md §2.9): a FIFO that drains at
// random, with busy bursts, and stalls the core when its free space runs low, as the FPGA trace
// streamer will. It also checks the core's side of the contract on every run.
#pragma once

#include <algorithm>
#include <cstdint>
#include <string>

#include "common.h"

namespace tg {

struct trace_sink_t {
  // Configuration (main.cpp)
  bool enabled = false;      // --trace-stall: drive the stall; otherwise it stays 0
  unsigned busy = 0;         // permille per draining cycle: the sink stops draining for 1..64 cycles
  unsigned capacity = 0;     // records
  unsigned threshold = 0;    // stall while the free space is below this
  unsigned max_drain = 1;    // records drained per cycle at most
  unsigned llt = 0;          // deferred writebacks that may be outstanding (LLT_ENTRIES; 0: unchecked)
  rng_t rng{1};

  // State
  bool stall = false;        // the value driven in the cycle that is ending
  unsigned high_run = 0;     // consecutive cycles, ending with that one, with the stall high
  uint64_t high_since = 0;
  unsigned occ = 0;          // records in the FIFO
  uint64_t busy_until = 0;
  int64_t outstanding = 0;   // deferred records whose writeback has not arrived yet

  // Statistics
  uint64_t stall_cycles = 0, stalls = 0, overflows = 0, last_stall = 0;
  unsigned max_occ = 0;

  // The edge that ends cycle `now`: n_recs records (n_deferred with rd_deferred) and n_wbs writebacks
  // arrived in it. False, with `err` set, when the core broke the contract. Afterwards `stall` is
  // the value for the next cycle.
  bool cycle(uint64_t now, unsigned n_recs, unsigned n_deferred, unsigned n_wbs, std::string& err) {
    if (stall) {
      if (high_run++ == 0) { high_since = now; stalls++; }
      stall_cycles++;
      last_stall = now;
    } else {
      high_run = 0;
    }
    // The core registers the input, so it may still retire in the cycle the stall rises and in
    // the next one; from the third cycle on, nothing.
    if (n_recs && high_run >= 3) {
      err = strfmt("trace: %u record(s) in cycle %llu while trace_stall_i had been high since cycle %llu "
                   "(the core may retire only in the first two cycles; interfaces.md §5)",
                   n_recs, (unsigned long long)now, (unsigned long long)high_since);
      return false;
    }
    outstanding += int64_t(n_deferred) - int64_t(n_wbs);
    if (llt && outstanding > int64_t(llt)) {
      err = strfmt("trace: %lld deferred writebacks outstanding in cycle %llu, more than LLT_ENTRIES = %u "
                   "(interfaces.md §5)", (long long)outstanding, (unsigned long long)now, llt);
      return false;
    }
    if (!enabled) return true;
    occ += n_recs + n_wbs;
    if (occ > capacity) {  // cannot happen while the checks above hold (verification.md §2.9)
      overflows++;
      occ = capacity;
    }
    max_occ = std::max(max_occ, occ);
    if (now >= busy_until) {
      if (rng.permille(busy)) busy_until = now + 1 + rng.below(64);
      else occ -= std::min<unsigned>(occ, unsigned(rng.below(max_drain + 1)));
    }
    stall = capacity - occ < threshold;
    return true;
  }
};

}  // namespace tg
