// tgsim: branch predictors.
#include "bpred.h"

#include <algorithm>
#include <cmath>

namespace tg {

uint64_t Hist::fold(int len, int out_bits) const {
  if (len <= 0 || out_bits <= 0) return 0;
  uint64_t r = 0;
  const uint64_t omask = (out_bits >= 64) ? ~0ull : ((1ull << out_bits) - 1);
  for (int pos = 0; pos < len; pos += out_bits) {
    const int n = std::min(out_bits, len - pos);
    uint64_t chunk;
    if (pos >= 64) chunk = hi >> (pos - 64);
    else if (pos + n <= 64) chunk = lo >> pos;
    else chunk = (lo >> pos) | (hi << (64 - pos));
    if (n < 64) chunk &= (1ull << n) - 1;
    r ^= chunk;
  }
  return r & omask;
}

// ---------------------------------------------------------------- bimodal / gshare

Bimodal::Bimodal(int lg) : t_(1ull << lg, 2), mask_((1ull << lg) - 1) {}
bool Bimodal::predict(uint64_t pc, const Hist&) { return t_[(pc >> 1) & mask_] >= 2; }
void Bimodal::update(uint64_t pc, const Hist&, bool taken) {
  uint8_t& c = t_[(pc >> 1) & mask_];
  if (taken) { if (c < 3) c++; } else if (c > 0) c--;
}

Gshare::Gshare(int lg, int hb) : t_(1ull << lg, 2), mask_((1ull << lg) - 1), hist_bits_(hb) {}
uint64_t Gshare::idx(uint64_t pc, const Hist& h) const {
  const uint64_t hb = hist_bits_ >= 64 ? h.lo : (h.lo & ((1ull << hist_bits_) - 1));
  return ((pc >> 1) ^ hb) & mask_;
}
bool Gshare::predict(uint64_t pc, const Hist& h) { return t_[idx(pc, h)] >= 2; }
void Gshare::update(uint64_t pc, const Hist& h, bool taken) {
  uint8_t& c = t_[idx(pc, h)];
  if (taken) { if (c < 3) c++; } else if (c > 0) c--;
}

// ---------------------------------------------------------------- TAGE-lite

Tage::Tage(int base_log, int n, int lg, int tagb, int hmin, int hmax)
    : base_(1ull << base_log, 2), t_(n), hlen_(n), log_(lg), tagb_(tagb), base_log_(base_log) {
  for (int i = 0; i < n; i++) {
    t_[i].resize(1ull << lg);
    const double r = n > 1 ? std::pow((double)hmax / hmin, (double)i / (n - 1)) : 1.0;
    hlen_[i] = std::min(128, (int)std::lround(hmin * r));
  }
}

void Tage::lookup(uint64_t pc, const Hist& h, Look& l) const {
  const uint64_t imask = (1ull << log_) - 1, tmask = (1ull << tagb_) - 1;
  for (int i = 0; i < (int)t_.size(); i++) {
    const uint64_t f = h.fold(hlen_[i], log_);
    const uint64_t p = (uint64_t)h.path & ((1ull << std::min(16, hlen_[i])) - 1);
    l.idx[i] = (uint32_t)(((pc >> 1) ^ (pc >> (1 + log_)) ^ f ^ (p * (i + 1)) ^ (p >> 3)) & imask);
    l.tag[i] = (uint16_t)(((pc >> 1) ^ h.fold(hlen_[i], tagb_) ^ (h.fold(hlen_[i], tagb_ - 1) << 1) ^ (pc >> 9)) &
                          tmask);
  }
  l.prov = l.alt = -1;
  for (int i = (int)t_.size() - 1; i >= 0; i--) {
    if (t_[i][l.idx[i]].tag == l.tag[i]) {
      if (l.prov < 0) l.prov = i;
      else { l.alt = i; break; }
    }
  }
  const bool base_pred = base_[(pc >> 1) & ((1ull << base_log_) - 1)] >= 2;
  l.alt_pred = l.alt >= 0 ? t_[l.alt][l.idx[l.alt]].ctr >= 0 : base_pred;
  if (l.prov < 0) {
    l.prov_pred = base_pred;
    l.pred = base_pred;
    return;
  }
  const Ent& e = t_[l.prov][l.idx[l.prov]];
  l.prov_pred = e.ctr >= 0;
  const bool weak = (e.ctr == 0 || e.ctr == -1) && e.u == 0;
  l.pred = (weak && use_alt_ >= 8) ? l.alt_pred : l.prov_pred;
}

bool Tage::predict(uint64_t pc, const Hist& h) {
  Look l;
  lookup(pc, h, l);
  return l.pred;
}

void Tage::update(uint64_t pc, const Hist& h, bool taken) {
  Look l;
  lookup(pc, h, l);
  const int n = (int)t_.size();
  if (l.prov >= 0) {
    Ent& e = t_[l.prov][l.idx[l.prov]];
    const bool weak = (e.ctr == 0 || e.ctr == -1) && e.u == 0;
    if (weak && l.prov_pred != l.alt_pred) {
      if (l.alt_pred == taken) { if (use_alt_ < 15) use_alt_++; }
      else if (use_alt_ > 0) use_alt_--;
    }
    if (l.prov_pred != l.alt_pred) {
      if (l.prov_pred == taken) { if (e.u < 3) e.u++; }
      else if (e.u > 0) e.u--;
    }
    if (taken) { if (e.ctr < 3) e.ctr++; } else if (e.ctr > -4) e.ctr--;
    if (l.alt < 0 && (weak || l.prov_pred != taken)) {
      uint8_t& c = base_[(pc >> 1) & ((1ull << base_log_) - 1)];
      if (taken) { if (c < 3) c++; } else if (c > 0) c--;
    }
  } else {
    uint8_t& c = base_[(pc >> 1) & ((1ull << base_log_) - 1)];
    if (taken) { if (c < 3) c++; } else if (c > 0) c--;
  }
  // Allocate a longer entry on a misprediction.
  if (l.pred != taken && l.prov < n - 1) {
    rng_ ^= rng_ << 13; rng_ ^= rng_ >> 7; rng_ ^= rng_ << 17;
    int start = l.prov + 1;
    if (start < n - 1 && (rng_ & 1)) start++;
    bool done = false;
    for (int i = start; i < n; i++) {
      Ent& e = t_[i][l.idx[i]];
      if (e.u == 0) {
        e.tag = l.tag[i];
        e.ctr = taken ? 0 : -1;
        e.u = 0;
        done = true;
        break;
      }
    }
    if (!done)
      for (int i = start; i < n; i++) { Ent& e = t_[i][l.idx[i]]; if (e.u > 0) e.u--; }
  }
  if (++updates_ % (256 * 1024) == 0)
    for (auto& tab : t_) for (auto& e : tab) e.u >>= 1;
}

// ---------------------------------------------------------------- core-2's block TAGE (tg_tage.sv)

namespace {
// the history lengths by table count (core-2's TAGE size study, tg_tage.sv hl())
constexpr int kBtHl[4][4] = {{12, 0, 0, 0}, {8, 32, 0, 0}, {5, 14, 40, 0}, {4, 9, 18, 40}};
}

BlockTage::BlockTage(int li, int tw, int bi, int slots, int nt)
    : t_((size_t)std::clamp(nt, 1, 4), std::vector<Ent>(1ull << li)), base_((1ull << bi) * (size_t)slots, 0), li_(li),
      tw_(tw), bi_(bi), np_(slots), nt_(std::clamp(nt, 1, 4)) {
  for (int t = 0; t < nt_; t++) hl_[t] = kBtHl[nt_ - 1][t];
}

// The RTL's hash: the block address (35 bits) folded into the index, XORed with the history's first HL[t] bits
// folded likewise; the tag is the address's low bits XORed with two foldings of the same history bits.
BlockTage::Ix BlockTage::hash(uint64_t blk, uint64_t gh) const {
  Ix x;
  uint32_t ai = 0;
  for (int i = 0; i < 35; i++) ai ^= (uint32_t)((blk >> i) & 1) << (i % li_);
  x.base = (uint16_t)(blk & ((1ull << bi_) - 1));
  for (int t = 0; t < nt_; t++) {
    uint32_t hf = 0, tf = 0, tf1 = 0;
    for (int i = 0; i < hl_[t]; i++) {
      const uint32_t b = (uint32_t)((gh >> i) & 1);
      hf ^= b << (i % li_);
      tf ^= b << (i % tw_);
      tf1 ^= b << (i % (tw_ - 1));
    }
    x.idx[t] = (uint16_t)((ai ^ hf) & ((1u << li_) - 1));
    x.tag[t] = (uint16_t)(((uint32_t)blk ^ tf ^ (tf1 << 1)) & ((1u << tw_) - 1));
  }
  return x;
}

bool BlockTage::dir(const Ix& x, int s) const {
  for (int t = nt_ - 1; t >= 0; t--)
    for (const Sub& e : t_[(size_t)t][x.idx[t]].w)
      if (e.v && e.tag == x.tag[t] && e.slot == s) return e.ctr >= 4;
  return base_[(size_t)x.base * (size_t)np_ + (size_t)s] >= 2;
}

void BlockTage::train(const Ix& x, int s, bool taken, bool pred) {
  int pt = -1, pw = 0, at = -1, aw = 0;
  for (int t = nt_ - 1; t >= 0; t--)
    for (int w = 0; w < 2; w++) {
      const Sub& e = t_[(size_t)t][x.idx[t]].w[w];
      if (e.v && e.tag == x.tag[t] && e.slot == s) {
        if (pt < 0) { pt = t; pw = w; }
        else if (at < 0 && t < pt) { at = t; aw = w; }
      }
    }
  uint8_t& bc = base_[(size_t)x.base * (size_t)np_ + (size_t)s];
  const bool adir = at >= 0 ? t_[(size_t)at][x.idx[at]].w[aw].ctr >= 4 : bc >= 2;
  if (pt >= 0) {
    Sub& e = t_[(size_t)pt][x.idx[pt]].w[pw];
    const bool pdir = e.ctr >= 4;
    if (taken && e.ctr != 7) e.ctr++;
    if (!taken && e.ctr != 0) e.ctr--;
    if (pdir != adir) {
      if (pdir == taken && e.u != 3) e.u++;
      if (pdir != taken && e.u != 0) e.u--;
    }
  } else {
    if (taken && bc != 3) bc++;
    if (!taken && bc != 0) bc--;
  }
  if (pred != taken && pt < nt_ - 1) {
    bool done = false;
    for (int t = pt + 1; t < nt_ && !done; t++)
      for (int w = 0; w < 2 && !done; w++) {
        Sub& e = t_[(size_t)t][x.idx[t]].w[w];
        if (!e.v || e.u == 0) {
          e = Sub{true, (uint8_t)s, x.tag[t], (uint8_t)(taken ? 4 : 3), 0};
          done = true;
        }
      }
    if (!done)
      for (int t = pt + 1; t < nt_; t++)
        for (Sub& e : t_[(size_t)t][x.idx[t]].w) if (e.u) e.u--;
  }
}

// ---------------------------------------------------------------- BTB / micro-BTB

Btb::Btb(int sets, int ways, int slots, int block_bytes, bool block_mode)
    : w_((size_t)sets * ways), sets_(sets), ways_(ways), slots_(slots), bb_(block_bytes), block_(block_mode) {
  for (auto& w : w_) w.s.resize(slots);
}

BtbHit Btb::lookup(uint64_t pc) {
  BtbHit r;
  const uint64_t k = key(pc);
  Way* base = &w_[(k % sets_) * ways_];
  const uint16_t off = block_ ? (uint16_t)(pc % bb_) : 0;
  for (int i = 0; i < ways_; i++) {
    Way& w = base[i];
    if (!w.v || w.tag != k) continue;
    for (auto& s : w.s)
      if (s.v && s.off == off) {
        w.lru = s.lru = ++stamp_;
        r.hit = true; r.target = s.target; r.kind = s.kind;
        return r;
      }
    return r;
  }
  return r;
}

void Btb::insert(uint64_t pc, uint64_t target, uint8_t kind) {
  const uint64_t k = key(pc);
  Way* base = &w_[(k % sets_) * ways_];
  const uint16_t off = block_ ? (uint16_t)(pc % bb_) : 0;
  Way* w = nullptr;
  for (int i = 0; i < ways_; i++) if (base[i].v && base[i].tag == k) w = &base[i];
  if (!w) {
    w = &base[0];
    for (int i = 0; i < ways_; i++) {
      if (!base[i].v) { w = &base[i]; break; }
      if (base[i].lru < w->lru) w = &base[i];
    }
    w->v = true; w->tag = k;
    for (auto& s : w->s) s.v = false;
  }
  w->lru = ++stamp_;
  Slot* s = nullptr;
  for (auto& x : w->s) if (x.v && x.off == off) s = &x;
  if (!s) {
    s = &w->s[0];
    for (auto& x : w->s) {
      if (!x.v) { s = &x; break; }
      if (x.lru < s->lru) s = &x;
    }
  }
  s->v = true; s->off = off; s->target = target; s->kind = kind; s->lru = stamp_;
}

MicroBtb::MicroBtb(int n) : e_(n) {}
MicroBtb::E* MicroBtb::find(uint64_t start) {
  for (auto& e : e_) if (e.v && e.start == start) return &e;
  return nullptr;
}
bool MicroBtb::lookup(uint64_t start, uint64_t& target) {
  E* e = find(start);
  if (!e) return false;
  e->lru = ++stamp_;
  target = e->target;
  return e->ctr >= 2;
}
void MicroBtb::taken(uint64_t start, uint64_t target) {
  if (e_.empty()) return;
  E* v = find(start);
  if (v) {
    if (v->target == target) { if (v->ctr < 3) v->ctr++; }
    else { v->target = target; v->ctr = 2; }
    v->lru = ++stamp_;
    return;
  }
  for (auto& e : e_) if (!e.v) { v = &e; break; }
  if (!v) { v = &e_[0]; for (auto& e : e_) if (e.lru < v->lru) v = &e; }
  v->v = true; v->start = start; v->target = target; v->ctr = 2; v->lru = ++stamp_;
}
void MicroBtb::fallthrough(uint64_t start) {
  if (E* e = find(start)) { if (e->ctr > 0) e->ctr--; }
}

// ---------------------------------------------------------------- M2 micro-BTB (the RTL as built)

M2Ubtb::M2Ubtb(int entries, int ways, int counters, bool rtl_way)
    : e_((size_t)std::max(1, entries)), ctr_((size_t)std::max(1, counters), 0),
      sets_(std::max(1, entries / std::max(1, ways))), ways_(std::max(1, ways)), rtl_way_(rtl_way) {}

M2Ubtb::Look M2Ubtb::lookup(uint64_t blk) const {
  Look l;
  for (int w = 0; w < ways_; w++) {
    const E& e = at(blk, w);
    if (e.v && e.tag == (blk >> 4)) { l.hit = true; l.way = w; l.target = e.target; l.slot = e.slot; break; }
  }
  return l;
}

// The counter moves toward the outcome. The block should be predicted taken if this is a jump or the new counter
// is at least 2: then a missing or different entry is written (in the way that hit the block, else a pseudo-random
// way; rtl_way, as the RTL: in the way that predicted this instruction, else a pseudo-random way).
// If it should not and the micro-BTB predicted this slot taken, the entry is cleared.
void M2Ubtb::train(uint64_t blk, uint64_t pc, int slot, bool is_jump, bool taken, uint64_t target, const Look& l) {
  uint8_t& c = ctr_[(size_t)((pc >> 2) % ctr_.size())];
  if (taken) { if (c < 3) c++; } else if (c > 0) c--;
  const bool here = l.hit && l.slot == slot;
  if (is_jump || c >= 2) {
    if (here && l.target == target) return;
    rng_ ^= rng_ << 13; rng_ ^= rng_ >> 7; rng_ ^= rng_ << 17;
    E& e = at(blk, (rtl_way_ ? here : l.hit) ? l.way : (int)(rng_ % (uint64_t)ways_));
    e.v = true; e.tag = blk >> 4; e.target = target; e.slot = slot;
  } else if (here) {
    at(blk, l.way).v = false;
  }
}

void M2Ubtb::invalidate(uint64_t blk, const Look& l) {
  if (l.hit) at(blk, l.way).v = false;
}

// ---------------------------------------------------------------- PC counters

int PcCounters::get(uint64_t pc) const {
  for (auto& e : e_) if (e.v && e.pc == pc) return e.c;
  return 0;
}
void PcCounters::bump(uint64_t pc, int delta, int maxv) {
  if (e_.empty()) return;
  E* v = nullptr;
  for (auto& e : e_) if (e.v && e.pc == pc) { v = &e; break; }
  if (!v) for (auto& e : e_) if (!e.v) { v = &e; break; }
  if (!v) { v = &e_[0]; for (auto& e : e_) if (e.lru < v->lru) v = &e; }
  if (!(v->v && v->pc == pc)) { v->v = true; v->pc = pc; v->c = 0; }
  v->c = std::clamp(v->c + delta, 0, maxv);
  v->lru = ++stamp_;
}

}  // namespace tg
