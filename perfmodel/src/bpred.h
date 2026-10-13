// tgsim: branch predictors and small per-PC predictor tables.
#pragma once
#include <cstdint>
#include <vector>

namespace tg {

// Global history: the 128 most recent conditional-branch outcomes plus a short path history.
struct Hist {
  uint64_t lo = 0, hi = 0;
  uint32_t path = 0;
  void push(bool taken, uint64_t pc) {
    hi = (hi << 1) | (lo >> 63);
    lo = (lo << 1) | (taken ? 1 : 0);
    path = ((path << 1) ^ (uint32_t)((pc >> 1) & 1) ^ (uint32_t)((pc >> 5) & 2)) & 0xffff;
  }
  // XOR-fold the most recent len bits into out_bits bits.
  uint64_t fold(int len, int out_bits) const;
};

class DirPred {
 public:
  virtual ~DirPred() = default;
  virtual bool predict(uint64_t pc, const Hist& h) = 0;
  virtual void update(uint64_t pc, const Hist& h, bool taken) = 0;
};

class Bimodal : public DirPred {
 public:
  explicit Bimodal(int log_entries);
  bool predict(uint64_t pc, const Hist& h) override;
  void update(uint64_t pc, const Hist& h, bool taken) override;
 private:
  std::vector<uint8_t> t_;
  uint64_t mask_;
};

class Gshare : public DirPred {
 public:
  Gshare(int log_entries, int hist_bits);
  bool predict(uint64_t pc, const Hist& h) override;
  void update(uint64_t pc, const Hist& h, bool taken) override;
 private:
  uint64_t idx(uint64_t pc, const Hist& h) const;
  std::vector<uint8_t> t_;
  uint64_t mask_;
  int hist_bits_;
};

// TAGE-lite: bimodal base plus N partially tagged tables with geometric history lengths.
class Tage : public DirPred {
 public:
  Tage(int base_log, int ntables, int log_entries, int tag_bits, int hmin, int hmax);
  bool predict(uint64_t pc, const Hist& h) override;
  void update(uint64_t pc, const Hist& h, bool taken) override;
 private:
  struct Ent { uint16_t tag = 0; int8_t ctr = 0; uint8_t u = 0; };
  struct Look { int prov = -1, alt = -1; uint32_t idx[16]; uint16_t tag[16]; bool prov_pred, alt_pred, pred; };
  void lookup(uint64_t pc, const Hist& h, Look& l) const;
  std::vector<uint8_t> base_;
  std::vector<std::vector<Ent>> t_;
  std::vector<int> hlen_;
  int log_, tagb_, base_log_;
  int use_alt_ = 8;
  uint64_t updates_ = 0, rng_ = 0x2545F4914F6CDD1Dull;
};

struct BtbHit { bool hit = false; uint64_t target = 0; uint8_t kind = 0; };

// Branch target buffer: block-based (entries per fetch block, up to `slots` branches each) or
// per-instruction (slots = 1, block size = 2 bytes).
class Btb {
 public:
  Btb(int sets, int ways, int slots, int block_bytes, bool block_mode);
  BtbHit lookup(uint64_t pc);
  void insert(uint64_t pc, uint64_t target, uint8_t kind);
 private:
  struct Slot { bool v = false; uint16_t off = 0; uint64_t target = 0; uint8_t kind = 0; uint64_t lru = 0; };
  struct Way { bool v = false; uint64_t tag = 0; uint64_t lru = 0; std::vector<Slot> s; };
  uint64_t key(uint64_t pc) const { return block_ ? pc / (uint64_t)bb_ : pc >> 1; }
  std::vector<Way> w_;
  int sets_, ways_, slots_, bb_;
  bool block_;
  uint64_t stamp_ = 0;
};

// Micro-BTB: fully associative, fetch-block start address -> next fetch address, with a 2-bit
// confidence counter so a block that only sometimes ends in a taken branch does not thrash.
class MicroBtb {
 public:
  explicit MicroBtb(int entries);
  // Returns true when the entry predicts a taken redirect (hit and confident).
  bool lookup(uint64_t start, uint64_t& target);
  void taken(uint64_t start, uint64_t target);   // the block ended in a taken branch to target
  void fallthrough(uint64_t start);              // the block did not end in a taken branch
 private:
  struct E { bool v = false; uint64_t start = 0, target = 0, lru = 0; uint8_t ctr = 0; };
  E* find(uint64_t start);
  std::vector<E> e_;
  uint64_t stamp_ = 0;
};

class Ras {
 public:
  explicit Ras(int n) : s_(n ? n : 1), n_(n) {}
  void push(uint64_t v) { if (!n_) return; sp_ = (sp_ + 1) % n_; s_[sp_] = v; }
  uint64_t top() const { return n_ ? s_[sp_] : 0; }
  void pop() { if (n_) sp_ = (sp_ + n_ - 1) % n_; }
  int sp() const { return sp_; }
  uint64_t at(int i) const { return s_[i]; }
  void restore(int sp, int slot, uint64_t val) { sp_ = sp; if (slot >= 0) s_[slot] = val; }
 private:
  std::vector<uint64_t> s_;
  int n_, sp_ = 0;
};

// Small LRU-managed counter table keyed by PC (SFB candidates).
class PcCounters {
 public:
  explicit PcCounters(int entries) : e_(entries) {}
  int get(uint64_t pc) const;
  void bump(uint64_t pc, int delta, int maxv);
 private:
  struct E { bool v = false; uint64_t pc = 0; int c = 0; uint64_t lru = 0; };
  std::vector<E> e_;
  uint64_t stamp_ = 0;
};

// Direct-mapped saturating counters (load hit predictor) / bits (wait table).
class PcTable {
 public:
  PcTable(int entries, uint8_t init) : t_(entries, init), init_(init) {}
  uint8_t& at(uint64_t pc) { return t_[((pc >> 1) ^ (pc >> 13)) % t_.size()]; }
  void reset() { std::fill(t_.begin(), t_.end(), init_); }
 private:
  std::vector<uint8_t> t_;
  uint8_t init_;
};

}  // namespace tg
