// tgsim: memory hierarchy timing.
#include "cache.h"

#include <algorithm>

namespace tg {

constexpr int LINE_SHIFT = 6;

// Every statistic is counted for all threads and for the thread making the request.
#define CNT(f) (st.f++, tst[tid].f++)

Cache::Cache(int64_t kb, int64_t ways) {
  if (kb <= 0 || ways <= 0) return;
  const int64_t lines = kb * 1024 / 64;
  ways_ = ways;
  sets_ = lines / ways;
  l_.resize((size_t)(sets_ * ways_));
}

Cache::Line* Cache::find(uint64_t line) {
  if (!sets_) return nullptr;
  Line* s = &l_[(size_t)((line % (uint64_t)sets_) * ways_)];
  for (int64_t i = 0; i < ways_; i++) if (s[i].tag == line) return &s[i];
  return nullptr;
}

Cache::Line* Cache::insert(uint64_t line, uint64_t ready, bool pf) {
  if (!sets_) return nullptr;
  Line* s = &l_[(size_t)((line % (uint64_t)sets_) * ways_)];
  Line* v = &s[0];
  for (int64_t i = 0; i < ways_; i++) {
    if (s[i].tag == line) { v = &s[i]; break; }
    if (s[i].tag == ~0ull) { v = &s[i]; break; }
    if (s[i].lru < v->lru) v = &s[i];
  }
  v->tag = line; v->ready = ready; v->pf = pf; v->lru = ++stamp_;
  return v;
}

MemSys::MemSys(const Config& c)
    : c_(c), l1i_(c.l1i_kb, c.l1i_ways), l1d_(c.l1d_kb, c.l1d_ways), l2_(c.l2_kb, c.l2_ways),
      l1i_m_((size_t)std::max<int64_t>(1, c.l1i_mshr)), l1d_m_((size_t)std::max<int64_t>(1, c.l1d_mshr)),
      l2_m_((size_t)std::max<int64_t>(1, c.l2_mshr)), streams_(8), strides_((size_t)std::max<int64_t>(1, c.pf_stride_entries)) {}

int MemSys::busy(const std::vector<Mshr>& m, uint64_t t) const {
  int n = 0;
  for (auto& e : m) if (e.ready > t) n++;
  return n;
}

MemSys::Mshr* MemSys::free_slot(std::vector<Mshr>& m, uint64_t t) {
  for (auto& e : m) if (e.ready <= t) return &e;
  return nullptr;
}

bool MemSys::l1d_capped(uint64_t t) const {
  if (c_.threads <= 1 || c_.smt_mshr_cap >= 100) return false;
  const int cap = (int)std::max<int64_t>(1, ((int64_t)l1d_m_.size() * c_.smt_mshr_cap + 99) / 100);
  int n = 0;
  for (auto& e : l1d_m_) if (e.ready > t && e.tid == tid) n++;
  return n >= cap;
}

uint64_t MemSys::l1d_mshr_free_at(uint64_t t) const {
  const bool own = l1d_capped(t);  // a capped thread waits for one of its own MSHRs
  uint64_t best = ~0ull;
  for (auto& e : l1d_m_) if (!own || e.tid == tid) best = std::min(best, std::max(e.ready, t + 1));
  return best;
}

int MemSys::l1d_demand_outstanding(uint64_t t, int thread) const {
  int n = 0;
  for (auto& e : l1d_m_) if (e.ready > t && e.demand && (thread < 0 || e.tid == thread)) n++;
  return n;
}

uint64_t MemSys::dram(uint64_t t) {
  const uint64_t done = std::max<uint64_t>(t + (uint64_t)c_.dram_lat, dram_free_ + (uint64_t)c_.dram_line_cyc);
  dram_free_ = done;
  CNT(dram_reads);
  return done;
}

void MemSys::stream_train(uint64_t line, uint64_t t) {
  if (!c_.pf_stream || !l2_.enabled()) return;
  Stream* hit = nullptr;
  for (auto& s : streams_)
    if (s.v && line > s.last && line <= s.last + 2) { hit = &s; break; }
  if (!hit) {
    Stream* v = &streams_[0];
    for (auto& s : streams_) { if (!s.v) { v = &s; break; } if (s.lru < v->lru) v = &s; }
    v->v = true; v->last = line; v->conf = 0; v->lru = ++stamp_;
    return;
  }
  hit->conf = std::min(hit->conf + 1, 3);
  hit->last = line;
  hit->lru = ++stamp_;
  if (hit->conf < 1) return;
  const int reserve = 4;
  for (int64_t k = 0; k < c_.pf_stream_deg; k++) {
    const uint64_t pl = line + (uint64_t)c_.pf_stream_dist + (uint64_t)k;
    if (l2_.find(pl)) continue;
    if ((int)l2_m_.size() - busy(l2_m_, t) <= reserve) break;
    Mshr* m = free_slot(l2_m_, t);
    if (!m) break;
    const uint64_t done = dram(t);
    m->line = pl; m->ready = done; m->demand = false; m->tid = tid;
    l2_.insert(pl, done, true);
    CNT(pf_l2_issued);
  }
}

uint64_t MemSys::l2_fill(uint64_t line, uint64_t t, bool demand) {
  const uint64_t lat = (uint64_t)c_.l2_lat;
  if (!l2_.enabled()) return dram(t);
  CNT(l2_access);
  Cache::Line* l = l2_.find(line);
  // The stream prefetcher sees every request from the L1s (demand misses, L1 prefetches and
  // ownership requests): an L1 prefetcher must not hide the stream from it.
  if (l) {
    l2_.touch(l);
    if (l->pf) { if (demand) CNT(pf_l2_useful); l->pf = false; }
    stream_train(line, t);
    return std::max(t + lat, l->ready + 2);
  }
  CNT(l2_miss);
  uint64_t start = t;
  Mshr* m = free_slot(l2_m_, t);
  if (!m) {
    m = &l2_m_[0];
    for (auto& e : l2_m_) if (e.ready < m->ready) m = &e;
    start = m->ready;
  }
  const uint64_t done = dram(start);
  m->line = line; m->ready = done; m->demand = demand; m->tid = tid;
  l2_.insert(line, done, false);
  stream_train(line, t);
  return done + lat;
}

MemSys::Res MemSys::l1d(uint64_t addr, uint64_t t, Kind kind, uint64_t& ready) {
  const uint64_t line = addr >> LINE_SHIFT;
  const bool demand = kind == LOAD || kind == STORE;
  if (demand) CNT(l1d_access);
  Cache::Line* l = l1d_.find(line);
  if (l) {
    if (demand) {
      l1d_.touch(l);
      if (l->pf) { CNT(pf_l1_useful); l->pf = false; }
    }
    if (l->ready <= t) { ready = t; return Res::HIT; }
    if (demand) CNT(l1d_merge);
    ready = l->ready;
    // Promote an in-flight prefetch to demand so it counts as outstanding demand.
    if (demand) for (auto& m : l1d_m_) if (m.line == line && m.ready > t) m.demand = true;
    return Res::MISS;
  }
  const int reserve = ((kind == PREFETCH || kind == RFO_PF) ? 2 : 0) + (kind == STORE ? 0 : drain_reserve);
  if ((int)l1d_m_.size() - busy(l1d_m_, t) <= reserve || l1d_capped(t)) {
    if (demand) CNT(l1d_no_mshr);
    return Res::NO_MSHR;
  }
  Mshr* m = free_slot(l1d_m_, t);
  if (demand) CNT(l1d_miss);
  else if (kind == PREFETCH) CNT(pf_l1_issued);
  else CNT(rfo_pf_issued);
  const uint64_t done = l2_fill(line, t, demand) + (uint64_t)c_.l1_fill_extra;
  m->line = line; m->ready = done; m->demand = demand; m->tid = tid;
  l1d_.insert(line, done, kind == PREFETCH);
  ready = done;
  return Res::MISS;
}

bool MemSys::l1d_present(uint64_t addr, uint64_t t) {
  Cache::Line* l = l1d_.find(addr >> LINE_SHIFT);
  return l && l->ready <= t;
}

bool MemSys::l1d_has(uint64_t addr) { return l1d_.find(addr >> LINE_SHIFT) != nullptr; }

MemSys::Res MemSys::l1i(uint64_t addr, uint64_t t, bool prefetch, uint64_t& ready) {
  const uint64_t line = addr >> LINE_SHIFT;
  if (!prefetch) CNT(l1i_access);
  Cache::Line* l = l1i_.find(line);
  if (l) {
    if (!prefetch) l1i_.touch(l);
    ready = std::max(l->ready, t);
    return l->ready <= t ? Res::HIT : Res::MISS;
  }
  // A prefetch leaves one MSHR for demand, unless a demand miss of the same thread is already outstanding:
  // that thread's fetch is stalled on it, so it cannot make a second demand miss before it returns.
  bool demand_pending = false;
  for (auto& e : l1i_m_) if (e.demand && e.ready > t && e.tid == tid) demand_pending = true;
  const int reserve = prefetch && !demand_pending ? 1 : 0;
  if ((int)l1i_m_.size() - busy(l1i_m_, t) <= reserve) {
    if (!prefetch) {
      // Wait for the oldest outstanding fill, then retry.
      uint64_t best = ~0ull;
      for (auto& e : l1i_m_) best = std::min(best, e.ready);
      ready = best;
    }
    return Res::NO_MSHR;
  }
  Mshr* m = free_slot(l1i_m_, t);
  if (!prefetch) CNT(l1i_miss);
  else CNT(pf_i_issued);
  const uint64_t done = l2_fill(line, t, !prefetch) + (uint64_t)c_.l1_fill_extra;
  m->line = line; m->ready = done; m->demand = !prefetch; m->tid = tid;
  l1i_.insert(line, done, prefetch);
  ready = done;
  if (!prefetch && c_.pf_i_nextline) {
    uint64_t r2;
    l1i((line + 1) << LINE_SHIFT, t, true, r2);
  }
  return Res::MISS;
}

void MemSys::train_stride(uint64_t pc, uint64_t addr, uint64_t t) {
  if (!c_.pf_stride) return;
  Stride* e = nullptr;
  for (auto& s : strides_) if (s.v && s.pc == pc) { e = &s; break; }
  if (!e) {
    e = &strides_[0];
    for (auto& s : strides_) { if (!s.v) { e = &s; break; } if (s.lru < e->lru) e = &s; }
    e->v = true; e->pc = pc; e->last = addr; e->stride = 0; e->conf = 0; e->lru = ++stamp_;
    return;
  }
  e->lru = ++stamp_;
  const int64_t d = (int64_t)(addr - e->last);
  if (d != 0 && d == e->stride) e->conf = std::min(e->conf + 1, 3);
  else { e->stride = d; e->conf = 0; }
  e->last = addr;
  if (e->conf >= 2) {
    // Distance is pf_stride_dist strides, but at least pf_stride_dist lines for sub-line strides.
    int64_t ahead = e->stride * c_.pf_stride_dist;
    const int64_t min_ahead = 64 * c_.pf_stride_dist;
    if (ahead > 0 && ahead < min_ahead) ahead = min_ahead;
    if (ahead < 0 && ahead > -min_ahead) ahead = -min_ahead;
    const uint64_t target = addr + (uint64_t)ahead;
    if ((target >> LINE_SHIFT) != (addr >> LINE_SHIFT)) {
      uint64_t r;
      l1d(target, t, PREFETCH, r);
    }
  }
}

}  // namespace tg
