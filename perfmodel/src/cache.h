// tgsim: memory hierarchy timing (L1I, L1D, shared L2, DRAM) with MSHRs and prefetchers. With SMT the
// threads share everything here; addresses are physical, so the core offsets each thread's addresses.
#pragma once
#include <cstdint>
#include <vector>

#include "config.h"

namespace tg {

class Cache {
 public:
  struct Line { uint64_t tag = ~0ull; uint64_t ready = 0; uint64_t lru = 0; bool pf = false; };
  Cache(int64_t kb, int64_t ways);
  bool enabled() const { return sets_ > 0; }
  Line* find(uint64_t line);
  Line* insert(uint64_t line, uint64_t ready, bool pf);
  void touch(Line* l) { l->lru = ++stamp_; }
 private:
  std::vector<Line> l_;
  int64_t sets_ = 0, ways_ = 0;
  uint64_t stamp_ = 0;
};

#define TG_MEMSTATS(X)                                                                             \
  X(l1d_access) X(l1d_miss) X(l1d_merge) X(l1d_no_mshr) X(l1i_access) X(l1i_miss) X(l2_access)     \
  X(l2_miss) X(dram_reads) X(pf_l1_issued) X(pf_l1_useful) X(pf_l2_issued) X(pf_l2_useful)         \
  X(pf_i_issued) X(rfo_pf_issued)

struct MemStats {
#define TG_MDECL(n) uint64_t n = 0;
  TG_MEMSTATS(TG_MDECL)
#undef TG_MDECL
};

class MemSys {
 public:
  enum class Res { HIT, MISS, NO_MSHR };
  enum Kind { LOAD = 0, STORE = 1, PREFETCH = 2, RFO_PF = 3 };
  explicit MemSys(const Config& c);

  // Data access at cycle t. On HIT ready = t; on MISS ready = cycle the line is filled into the L1D.
  Res l1d(uint64_t addr, uint64_t t, Kind kind, uint64_t& ready);
  bool l1d_present(uint64_t addr, uint64_t t);
  bool l1d_has(uint64_t addr);  // the line is in the L1D, filled or in flight
  uint64_t l1d_mshr_free_at(uint64_t t) const;
  int l1d_demand_outstanding(uint64_t t, int thread = -1) const;  // thread -1: all threads
  // Instruction fetch / prefetch at cycle t.
  Res l1i(uint64_t addr, uint64_t t, bool prefetch, uint64_t& ready);
  void train_stride(uint64_t pc, uint64_t addr, uint64_t t);

  MemStats st;                // all threads
  MemStats tst[MAX_THREADS];  // per hardware thread
  int tid = 0;                // hardware thread making the current request (set by the core before each call)

 private:
  struct Mshr { uint64_t line = 0, ready = 0; bool demand = false; int tid = 0; };
  uint64_t l2_fill(uint64_t line, uint64_t t, bool demand);  // returns cycle data reaches the L1
  uint64_t dram(uint64_t t);
  void stream_train(uint64_t line, uint64_t t);
  int busy(const std::vector<Mshr>& m, uint64_t t) const;
  Mshr* free_slot(std::vector<Mshr>& m, uint64_t t);
  bool l1d_capped(uint64_t t) const;  // SMT: the requesting thread holds its share of the L1D MSHRs

  const Config& c_;
  Cache l1i_, l1d_, l2_;
  std::vector<Mshr> l1i_m_, l1d_m_, l2_m_;
  uint64_t dram_free_ = 0;
  struct Stream { uint64_t last = 0; int conf = 0; uint64_t lru = 0; bool v = false; };
  std::vector<Stream> streams_;
  struct Stride { uint64_t pc = 0, last = 0; int64_t stride = 0; int conf = 0; uint64_t lru = 0; bool v = false; };
  std::vector<Stride> strides_;
  uint64_t stamp_ = 0;
};

}  // namespace tg
