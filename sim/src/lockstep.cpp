// Spike lockstep checker: docs/spec/verification.md §3.
#include "lockstep.h"

#include <algorithm>
#include <climits>
#include <cstring>
#include <deque>
#include <map>
#include <unordered_map>

#include "common.h"
#include "spike_env.h"

namespace tg {

namespace {

spike_platform_t platform_of(const lockstep_cfg_t& c) {
  spike_platform_t p;
  p.isa = c.isa;
  p.priv = c.priv;
  p.hartids = c.hartids;
  p.boot_pc = c.boot_pc;
  p.pmp_regions = c.pmp_regions;
  p.pmp_granularity = c.pmp_granularity;
  p.pmp_reset_off = c.pmp_reset_off;
  p.dram_base = c.dram_base;
  p.dram_size = c.dram_size;
  p.rom_base = c.rom_base;
  p.rom_size = c.rom_size;
  p.dev_regions = c.dev_regions;
  p.deny = c.deny;
  p.mtgsmt = c.mtgsmt;
  return p;
}

// The destination value the RTL reports is taken over rather than compared (§3.4).
bool adopts_value(const tr_rec_t& r) {
  return r.mmio_ld || r.nondet || (!r.rvc && is_csr_insn(r.insn) && adopted_csr(r.insn >> 20));
}

// An external write (§3.10): new bytes another master wrote into main memory, visible from `cycle` on.
// Until it is applied to Spike's memory, a load may return its new bytes; once applied, a hart whose
// window is still open may return the old ones it replaced.
struct ext_write_t {
  uint64_t pa = 0, cycle = 0;
  unsigned len = 0;
  uint32_t mask = 0;
  uint8_t nw[32] = {}, old[32] = {};
  bool applied = false;
  std::vector<uint32_t> seen;  // per hart: its records of `cycle` or later
};

// How a load's destination extends the bytes it read.
enum class ld_ext_t { sext, zext, nanbox, none, unknown };
ld_ext_t load_extension(uint32_t insn, bool rvc) {
  if (rvc) {
    const unsigned q = insn & 3, f3 = (insn >> 13) & 7;
    if (q != 0 && q != 2) return ld_ext_t::unknown;
    return f3 == 2 ? ld_ext_t::sext : (f3 == 3 || f3 == 1) ? ld_ext_t::none : ld_ext_t::unknown;  // C.LW[SP]; C.LD[SP], C.FLD[SP]
  }
  const unsigned op = insn & 0x7f, f3 = (insn >> 12) & 7;
  if (op == 0x03) return f3 < 3 ? ld_ext_t::sext : f3 == 3 ? ld_ext_t::none : f3 < 7 ? ld_ext_t::zext : ld_ext_t::unknown;
  if (op == 0x07) return f3 == 2 ? ld_ext_t::nanbox : f3 == 3 ? ld_ext_t::none : ld_ext_t::unknown;  // FLW, FLD
  if (op == 0x2f) return f3 == 2 ? ld_ext_t::sext : f3 == 3 ? ld_ext_t::none : ld_ext_t::unknown;  // LR.W, LR.D
  return ld_ext_t::unknown;
}
// The value an AMO (RV64A, not LR/SC) stores, from the value it read and rs2; false for others.
bool amo_result(uint32_t insn, uint64_t rd, uint64_t rs2, uint64_t& out) {
  const unsigned f5 = insn >> 27, w = ((insn >> 12) & 7) == 2;
  const uint64_t a = w ? uint64_t(int64_t(int32_t(rd))) : rd, b = w ? uint64_t(int64_t(int32_t(rs2))) : rs2;
  switch (f5) {
    case 0x01: out = b; break;
    case 0x00: out = a + b; break;
    case 0x04: out = a ^ b; break;
    case 0x0c: out = a & b; break;
    case 0x08: out = a | b; break;
    case 0x10: out = int64_t(a) < int64_t(b) ? a : b; break;
    case 0x14: out = int64_t(a) > int64_t(b) ? a : b; break;
    case 0x18: out = (w ? uint32_t(a) < uint32_t(b) : a < b) ? a : b; break;
    case 0x1c: out = (w ? uint32_t(a) > uint32_t(b) : a > b) ? a : b; break;
    default: return false;
  }
  if (w) out &= 0xffffffffull;
  return true;
}
uint64_t extend_load(const uint8_t* b, unsigned n, ld_ext_t k) {
  uint64_t v = 0;
  for (unsigned i = 0; i < n; i++) v |= uint64_t(b[i]) << (8 * i);
  if (n < 8 && ((k == ld_ext_t::sext && (v >> (8 * n - 1) & 1)) || k == ld_ext_t::nanbox)) v |= ~0ull << (8 * n);
  return v;
}

struct pending_wb_t {
  unsigned rd = 0;
  bool rd_fp = false;
  uint64_t value = 0, pc = 0, cycle = 0;
  uint32_t insn = 0;
  // A load's view at its record, for another hart's write it may have read past (§3.7): its bytes, Spike's
  // memory then, the writes up to then (sequence number), its hart's record count then, and its step
  bool hw = false, atomic = false;
  unsigned n = 0;
  ld_ext_t kind = ld_ext_t::unknown;
  uint64_t pa = 0, seq = 0, nrec = 0, step = 0, id_end = 0;  // id_end: the writes up to then, by id
  uint8_t mem[8] = {};
  // The late landers on its doubleword then (newest first, up to 4): a later write, its own AMO's included, may end
  // one before the value arrives
  struct {
    uint8_t mask = 0, nw[8] = {};
  } late[4];
  unsigned nlate = 0;
  // For each byte, the values a read past could return at its record (hw_accept's search then), up to 6
  uint8_t past[8][6] = {}, npast[8] = {};
  // A deferred AMO's (amo): its operand, its store data (wdata, under wmask), which what it read must give, and the
  // read its record settled on (decided: Spike's, or hw_amo_x0's from the store data)
  bool amo = false;
  uint64_t rs2 = 0, wdata = 0, wmask = 0, decided = 0;
};

// A write of one hart to main memory (§3.7). Spike applies it when it commits; in the core it reaches the
// other harts later (the store queue), and their loads may have read the line before (out of order). So
// until each other hart has committed hart_window more records, it may still read the bytes the write
// replaced; never past a write of its own to the same bytes. An AMO or SC is performed at the head of the
// ROB on the line itself, so atomics read only past plain stores, never past each other.
constexpr unsigned HW_MAX_HARTS = 8;
constexpr size_t HW_CAP = 65536;  // writes kept at most, for harts that stay quiet (WFI)
constexpr uint64_t HW_NONE = ~0ull;
struct hart_write_t {
  uint64_t pa = 0, id = 0;     // id: in commit order, kept when the write moves in the history
  unsigned len = 0, hart = 0;  // hart: index into harts_
  bool atomic = false;
  bool moved = false;          // moved behind later writes (hw_move_back, late_settle)
  bool settled = false;        // a late lander a read showed (late_settle): it reached memory before that read
  bool read_known = false;     // an AMO or SC whose read the trace shows: the bytes it read (`read`)
  uint8_t old[8] = {}, nw[8] = {}, read[8] = {};
  uint8_t spike_old[8] = {};    // Spike's memory before it (`old` may become what the core's write replaced)
  uint8_t alt_mask = 0, alt[8] = {};  // other bytes it may have replaced: those of a late lander it ended
  uint64_t cycle = 0, rs2 = 0;  // its record's cycle; an AMO's rs2
  uint32_t insn = 0;
  uint64_t base[HW_MAX_HARTS] = {};  // each hart's record count when it was written
};

// A plain store of one hart that a later write of another hart replaced in Spike's memory while the store could
// still be in its hart's store queue (its window for the writing hart was open): in the core it may reach memory
// after that write, and a read much later may show it (§3.7). By doubleword: the bytes it may still land on.
struct late_t {
  uint64_t id = 0;     // the store's hart_write_t::id
  unsigned hart = 0;
  uint8_t mask = 0;    // bytes of the doubleword
  uint8_t nw[8] = {};  // its bytes there, by position in the doubleword
  uint64_t base[HW_MAX_HARTS] = {};
};

struct hart_state_t {
  processor_t* p = nullptr;
  uint32_t id = 0;
  std::deque<tr_rec_t> rtl_hist;
  std::deque<tr_wb_t> wb_hist;
  std::deque<spike_step_t> spike_hist;
  std::map<uint32_t, pending_wb_t> pending;
  uint64_t steps = 0;
  uint64_t nrec = 0;                // records checked
  uint64_t last_wr[2][32] = {};     // the step that last wrote each x and f register
  // The last LR, for its SC: its bytes and the writes since (lr_seq, the sequence number at its record), or
  // since the first one it read past (lr_old)
  bool lr_valid = false, lr_old = false;
  bool saw_mem_ld = false;          // a record of this hart carried mem_ld (v1.5): every read must now
  uint64_t lr_pa = 0, lr_seq = 0, lr_from = 0;
  unsigned lr_n = 0;
  bool lr_val_ok = false;           // the bytes the LR returned, once the trace has shown them
  uint8_t lr_val[8] = {};
  bool lr_amb = false;              // a late lander explains as well each byte the LR read past
};

}  // namespace

class lockstep_impl_t {
 public:
  lockstep_impl_t(const lockstep_cfg_t& cfg, const mem_t& image, const elf_t* elf)
      : cfg_(cfg), env_(new spike_env_t(platform_of(cfg), image)), elf_(elf) {
    adopt_hpm_events() = cfg.isa.find("sscofpmf") != std::string::npos;
    for (size_t i = 0; i < env_->procs.size(); i++) {
      hart_state_t h;
      h.p = env_->procs[i];
      h.id = cfg.hartids[i];
      by_id_[h.id] = harts_.size();
      harts_.push_back(std::move(h));
    }
    dis_.reset(new disassembler_t(&harts_[0].p->get_isa()));
  }

  bool cycle(const std::vector<tr_rec_t>& recs, const std::vector<tr_wb_t>& wbs) {
    if (failed_) return false;
    // Writebacks for tags pending before this cycle first, then the records, then writebacks
    // for tags the records created (§3.5).
    std::vector<const tr_wb_t*> later;
    for (auto& w : wbs) {
      auto it = by_id_.find(w.hart);
      if (it != by_id_.end() && harts_[it->second].pending.count(w.wb_tag)) {
        if (!wb(w)) return false;
      } else {
        later.push_back(&w);
      }
    }
    for (auto& r : recs)
      if (!rec(r)) return false;
    for (auto* w : later)
      if (!wb(*w)) return false;
    return true;
  }

  bool finish() {
    if (failed_) return false;
    for (auto& h : harts_) {
      if (h.pending.empty()) continue;
      auto& [tag, pw] = *h.pending.begin();
      return mismatch(&h, nullptr, strfmt("%zu deferred writeback(s) never arrived; first: tag %u for %c%u of the "
                                          "instruction at %016llx (retired at cycle %llu)",
                                          h.pending.size(), tag, pw.rd_fp ? 'f' : 'x', pw.rd,
                                          (unsigned long long)pw.pc, (unsigned long long)pw.cycle));
    }
    return true;
  }

  bool check_stale(uint64_t now, uint64_t limit) {
    if (failed_) return false;
    for (auto& h : harts_)
      for (auto& [tag, pw] : h.pending)
        if (now > pw.cycle && now - pw.cycle > limit)
          return mismatch(&h, nullptr, strfmt("deferred writeback tag %u for %c%u of the instruction at %016llx is still "
                                              "pending %llu cycles after it retired (cycle %llu)", tag, pw.rd_fp ? 'f' : 'x',
                                              pw.rd, (unsigned long long)pw.pc, (unsigned long long)(now - pw.cycle),
                                              (unsigned long long)pw.cycle));
    return true;
  }

  size_t pending_wbs() const {
    size_t n = 0;
    for (auto& h : harts_) n += h.pending.size();
    return n;
  }
  bool failed() const { return failed_; }
  const std::string& error() const { return error_; }
  uint64_t steps() const {
    uint64_t n = 0;
    for (auto& h : harts_) n += h.steps;
    return n;
  }
  uint64_t read_mem64(uint64_t pa) const { return env_->read64(pa); }

  bool external_write(uint64_t pa, const uint8_t* data, uint32_t mask, unsigned len, uint64_t cycle) {
    if (failed_) return false;
    if (!len || len > 32) return mismatch(nullptr, nullptr, strfmt("external write of %u bytes (1 to 32 allowed)", len));
    if (!env_->in_dram(pa) || !env_->in_dram(pa + len - 1))
      return mismatch(nullptr, nullptr, strfmt("external write of %u bytes at %016llx, outside main memory", len,
                                               (unsigned long long)pa));
    if (any_rec_ && last_cycle_ >= cycle)
      return mismatch(nullptr, nullptr, strfmt("external write at %016llx, visible from cycle %llu, arrived after a record "
                                               "of cycle %llu was checked: it must come first (§3.10)",
                                               (unsigned long long)pa, (unsigned long long)cycle, (unsigned long long)last_cycle_));
    ext_write_t e;
    e.pa = pa;
    e.cycle = cycle;
    e.len = len;
    e.mask = len == 32 ? mask : mask & ((1u << len) - 1);
    memcpy(e.nw, data, len);
    e.seen.assign(harts_.size(), 0);
    ext_.push_back(e);
    return true;
  }
  uint64_t ext_loads_new() const { return ext_loads_new_; }
  size_t ext_pending() const { return ext_.size(); }
  uint64_t hart_loads_old() const { return hart_loads_old_; }
  uint64_t hart_reapplied() const { return hart_reapplied_; }
  uint64_t hart_late() const { return hart_late_; }
  std::string disasm(uint32_t insn) const { return dis_->disassemble(insn_t(insn)); }

  void report(FILE* f) const;

 private:
  bool mismatch(hart_state_t* h, const tr_rec_t* r, const std::string& what) {
    failed_ = true;
    error_ = what;
    fail_hart_ = h ? int(h - harts_.data()) : -1;
    if (r) { fail_rec_ = *r; has_fail_rec_ = true; }
    return false;
  }

  template <class T> void push_hist(std::deque<T>& q, const T& v) {
    q.push_back(v);
    while (q.size() > cfg_.history) q.pop_front();
  }

  spike_step_t step(hart_state_t& h, uint32_t insn) {
    h.steps++;
    return spike_step(h.p, insn);
  }

  bool rec(const tr_rec_t& r) {
    auto it = by_id_.find(r.hart);
    if (it == by_id_.end()) return mismatch(nullptr, &r, strfmt("record for hart %u, which Spike does not have", r.hart));
    hart_state_t& h = harts_[it->second];
    h.nrec++;
    push_hist(h.rtl_hist, r);
    ext_tick(it->second, r.cycle);
    state_t* s = h.p->get_state();
    if (s->pc != r.pc)
      return mismatch(&h, &r, strfmt("pc: RTL %016llx, Spike %016llx", (unsigned long long)r.pc, (unsigned long long)s->pc));
    if (s->prv != r.priv)
      return mismatch(&h, &r, strfmt("privilege: RTL %c, Spike %c", priv_char(r.priv), priv_char(unsigned(s->prv))));
    if (r.kind != TR_IRQ) {
      uint32_t sbits = 0;
      bool fetched = spike_fetch(h.p, r.pc, sbits);
      if (fetched && sbits != r.insn) fetched = spike_fetch(h.p, r.pc, sbits, true);  // a difference counts uncached
      if (fetched) {
        if (sbits != r.insn && !ext_fetch(h, r))
          return mismatch(&h, &r, strfmt("instruction: RTL %08x, Spike %08x (%s)", r.insn, sbits, disasm(sbits).c_str()));
        if (r.rvc != ((r.insn & 3) != 3))
          return mismatch(&h, &r, strfmt("rvc flag %u does not match the encoding %08x", r.rvc, r.insn));
      }
    }
    switch (r.kind) {
      case TR_RETIRE: return retire(h, r);
      case TR_TRAP: return trap(h, r);
      case TR_IRQ: return irq(h, r);
      default: return mismatch(&h, &r, strfmt("unknown record kind %u", r.kind));
    }
  }

  bool retire(hart_state_t& h, const tr_rec_t& r) {
    const uint32_t insn = r.insn;
    const bool amo = !r.rvc && is_amo_insn(insn);
    const unsigned f5 = insn >> 27;
    const bool lr = amo && f5 == 2, sc = amo && f5 == 3;
    const bool csr = !r.rvc && is_csr_insn(insn);
    const bool csr_adopt = csr && adopted_csr(insn >> 20);

    // Protocol rules on the record itself.
    if (r.rd_deferred && !r.rd_we) return mismatch(&h, &r, "rd_deferred on a record with no destination");
    if ((r.mmio_ld || r.nondet) && r.rd_deferred) return mismatch(&h, &r, "mmio_ld or nondet together with rd_deferred");
    if (r.nondet && !csr_adopt)
      return mismatch(&h, &r, "nondet on an instruction that is not a read of a CSR on the checker's list");
    if (r.mmio_ld && !is_load_insn(insn, r.rvc)) return mismatch(&h, &r, "mmio_ld on an instruction that is not a load");
    if (r.mem_ld && !is_load_insn(insn, r.rvc) && !(amo && !sc))
      return mismatch(&h, &r, "mem_ld on an instruction that does not read memory");

    // An SC the RTL failed: make Spike fail it too (§3.4). A successful SC always stores, so the
    // missing store is the sign; with rd = x0 it is the only one.
    if (sc && !r.mem_st) h.p->get_mmu()->yield_load_reservation();
    // The bytes a write replaces, for the other harts' windows (§3.7): read before Spike stores, at the
    // RTL's address (a different address is a mismatch anyway). A new LR forgets what the last one read.
    hart_write_t hw;
    const bool hw_rec = r.mem_st && hw_before(h, r, amo || sc, hw);
    if (hw_rec && sc) hw_sc_read(h, hw);
    hw_moved_.clear();
    env_->amo_step = amo && !lr && !sc;
    const uint64_t rs2 = h.p->get_state()->XPR[(insn >> 20) & 31];  // before an AMO overwrites it
    hw.cycle = r.cycle;
    hw.insn = insn;
    hw.rs2 = rs2;
    spike_step_t st = step(h, insn);
    env_->amo_step = false;
    auto done = [&](bool ok) { push_hist(h.spike_hist, st); return ok; };

    if (st.trapped) {
      done(false);
      if (st.interrupt)
        return mismatch(&h, &r, strfmt("the RTL retired the instruction; Spike took interrupt %llu first",
                                       (unsigned long long)(st.cause & 63)));
      return mismatch(&h, &r, strfmt("the RTL retired the instruction; Spike trapped with cause %llu, tval %016llx",
                                     (unsigned long long)st.cause, (unsigned long long)st.tval));
    }
    if (st.nwr > 1) return done(false), mismatch(&h, &r, "Spike wrote more than one register (not supported by the checker)");
    if (st.nwr == 1) h.last_wr[st.rd_fp][st.rd & 31] = h.steps;
    if (lr) hw_note_lr_start(h, st);

    // A read's address and size (interfaces.md §5, v1.5: mem_ld), before its value. A core that reports them
    // reports every read: once a hart's trace has shown mem_ld, a read without it is a mismatch too.
    if (r.mem_ld) h.saw_mem_ld = true;
    if (r.mem_ld || (h.saw_mem_ld && st.nld)) {
      const unsigned bytes = 1u << r.mem_size;
      if (!r.mem_ld || st.nld != 1 || r.mem_vaddr != st.ld_addr || bytes != st.ld_size) {
        done(false);
        return mismatch(&h, &r, strfmt("load address: RTL %s, Spike %s",
                                       r.mem_ld ? strfmt("read %u bytes at %016llx", bytes, (unsigned long long)r.mem_vaddr).c_str()
                                                : "no read",
                                       st.nld ? strfmt("read %u bytes at %016llx", st.ld_size, (unsigned long long)st.ld_addr).c_str()
                                              : "no read"));
      }
    }

    // Destination register
    bool s_we = st.nwr == 1;
    if (r.rd_we != s_we || (s_we && (r.rd != st.rd || r.rd_fp != st.rd_fp))) {
      done(false);
      auto dst = [](bool we, bool fp, unsigned rd) { return we ? strfmt("%c%u", fp ? 'f' : 'x', rd) : std::string("none"); };
      return mismatch(&h, &r, strfmt("destination: RTL %s, Spike %s", dst(r.rd_we, r.rd_fp, r.rd).c_str(),
                                     dst(s_we, st.rd_fp, st.rd).c_str()));
    }
    if (r.rd_we) {
      if (adopts_value(r)) {
        state_t* s = h.p->get_state();
        if (r.rd_fp) {
          freg_t v;
          v.v[0] = r.rd_value;
          v.v[1] = ~0ull;
          s->FPR.write(r.rd, v);
        } else {
          s->XPR.write(r.rd, r.rd_value);
        }
        st.rd_value = r.rd_value;
        st.adopted = true;
      } else if (r.rd_deferred) {
        if (h.pending.count(r.wb_tag)) {
          done(false);
          return mismatch(&h, &r, strfmt("wb_tag %u reused while its writeback is still pending", r.wb_tag));
        }
        pending_wb_t pw;
        pw.rd = r.rd;
        pw.rd_fp = r.rd_fp;
        pw.value = st.rd_value;
        pw.pc = r.pc;
        pw.cycle = r.cycle;
        pw.insn = r.insn;
        if (amo && !lr && !sc) hw_view_amo(h, r, st, hw_rec ? &hw : nullptr, rs2, pw);
        else hw_view(h, r, st, lr, pw);
        h.pending[r.wb_tag] = pw;
      } else if (r.rd_value != st.rd_value) {
        const bool ok = amo && !lr && !sc ? ext_amo(h, r, st, rs2) || hw_amo(h, r, st, rs2, hw_rec ? &hw : nullptr)
                                          : ext_load(h, r, st) || hw_load(h, r, st, lr);
        if (!ok) {
          done(false);
          return mismatch(&h, &r, strfmt("%c%u value: RTL %016llx, Spike %016llx%s", r.rd_fp ? 'f' : 'x', r.rd,
                                         (unsigned long long)r.rd_value, (unsigned long long)st.rd_value,
                                         ext_.empty() ? "" : strfmt(" (%zu external writes in a window)", ext_.size()).c_str()));
        }
        st.rd_value = r.rd_value;
        st.adopted = true;
      }
      // What an AMO or LR read, for the late landers of §3.7; a plain load's value may rule some out
      if (!r.rd_deferred && !adopts_value(r)) {
        if (amo && !lr && !sc && hw_rec) {
          hw.read_known = true;
          for (unsigned i = 0; i < hw.len; i++) hw.read[i] = uint8_t(r.rd_value >> (8 * i));
        }
        if (lr && h.lr_valid) {
          h.lr_val_ok = true;
          for (unsigned i = 0; i < h.lr_n; i++) h.lr_val[i] = uint8_t(r.rd_value >> (8 * i));
        }
        if (!late_.empty() && st.nld == 1 && !st.nst) late_seen(h, st.ld_addr, st.ld_size, r.rd_value);
      }
    }

    // Memory write
    if (st.nst > 1) return done(false), mismatch(&h, &r, "Spike logged more than one memory write (not supported by the checker)");
    if (r.mem_st != (st.nst == 1)) {
      done(false);
      return mismatch(&h, &r, strfmt("store: RTL %s, Spike %s", r.mem_st ? "wrote memory" : "no write",
                                     st.nst ? strfmt("wrote %u bytes at %016llx", st.st_size, (unsigned long long)st.st_addr).c_str()
                                            : "no write"));
    }
    if (r.mem_st) {
      unsigned bytes = 1u << r.mem_size;
      uint64_t m = size_mask(r.mem_size);
      // An AMO that shows no value it read at its record: rd = x0, or deferred (its writeback is checked against
      // this record's view, hw_view_amo)
      const bool amo_x0 = amo && !lr && !sc && (!r.rd_we || r.rd_deferred) && hw_rec && r.mem_vaddr == st.st_addr &&
                          bytes == st.st_size;
      if ((r.mem_vaddr != st.st_addr || bytes != st.st_size || (r.mem_wdata & m) != (st.st_val & m)) &&
          !(amo_x0 && hw_amo_x0(h, r, st, rs2, hw))) {
        done(false);
        return mismatch(&h, &r, strfmt("store: RTL %u bytes %016llx at %016llx, Spike %u bytes %016llx at %016llx", bytes,
                                       (unsigned long long)(r.mem_wdata & m), (unsigned long long)r.mem_vaddr, st.st_size,
                                       (unsigned long long)(st.st_val & size_mask(st.st_size == 8 ? 3 : st.st_size == 4 ? 2 : st.st_size == 2 ? 1 : 0)),
                                       (unsigned long long)st.st_addr));
      }
    }
    if (r.mem_st && !ext_.empty()) ext_store(h, r, st);
    // A deferred AMO: the read its record settled on (hw.old: Spike's, or what hw_amo_x0 found), for its writeback
    if (amo && !lr && !sc && r.rd_we && r.rd_deferred && hw_rec)
      if (auto pit = h.pending.find(r.wb_tag); pit != h.pending.end() && pit->second.amo)
        pit->second.decided = extend_load(hw.old, hw.len, hw.len == 4 ? ld_ext_t::sext : ld_ext_t::none);
    // A successful SC whose LR read past other harts' stores: in the core those stores came after it
    if (sc) {
      if (r.mem_st && h.lr_valid) hw_after_sc(h, st, r.cycle);
      h.lr_valid = h.lr_old = false;
    }
    if (hw_rec) hw_push(hw);
    if (!hw_moved_.empty()) hw_move_back();
    // A load the RTL calls mmio_ld must not read main memory when translation is off.
    if (r.mmio_ld && st.nld && bare_translation(h) && in_range(st.ld_addr, cfg_.dram_base, cfg_.dram_size)) {
      done(false);
      return mismatch(&h, &r, strfmt("mmio_ld on a load from main memory (%016llx)", (unsigned long long)st.ld_addr));
    }
    return done(true);
  }

  bool bare_translation(hart_state_t& h) {
    state_t* s = h.p->get_state();
    if (s->prv == PRV_M && !(s->mstatus->read() & MSTATUS_MPRV)) return true;
    return h.p->extension_enabled('S') ? (h.p->get_csr(CSR_SATP) >> 60) == 0 : true;
  }

  bool data_paddr(hart_state_t& h, uint64_t va, uint64_t& pa) { return spike_data_paddr(h.p, *env_, va, pa); }

  static bool ext_overlap(const ext_write_t& e, uint64_t pa, unsigned n) { return pa < e.pa + e.len && e.pa < pa + n; }

  // Applies external write `k` to Spike's memory, keeping the bytes it replaces. Earlier writes to any of
  // the same bytes are applied first, so that the later write wins; writes to other bytes wait for their
  // own load, store or window, as the core may not have seen them yet.
  void ext_apply(size_t k) {
    ext_write_t& e = ext_[k];
    if (e.applied) return;
    for (size_t j = 0; j < k; j++)
      if (!ext_[j].applied && ext_overlap(ext_[j], e.pa, e.len)) ext_apply(j);
    uint8_t* m = reinterpret_cast<uint8_t*>(env_->addr_to_mem(e.pa));
    for (unsigned i = 0; i < e.len; i++)
      if (e.mask >> i & 1) { e.old[i] = m[i]; m[i] = e.nw[i]; }
    e.applied = true;
    if (!late_.empty()) late_forget(e.pa, e.len, e.mask);
    for (auto& h : harts_) h.p->get_mmu()->flush_icache();  // the bytes may be instructions
  }

  // Applies, in order, the writes visible at `cycle` that overlap [pa, pa+n) and are not applied yet.
  void ext_apply_under(uint64_t pa, unsigned n, uint64_t cycle) {
    for (size_t k = 0; k < ext_.size(); k++)
      if (!ext_[k].applied && cycle + cfg_.ext_early >= ext_[k].cycle && ext_overlap(ext_[k], pa, n)) ext_apply(k);
  }

  // An instruction whose bits differ from Spike's fetch: accepted if each differing byte is the new byte
  // of an external write visible at the record's cycle and not applied yet (code that arrived by DMA,
  // fetched before the checker applied the write); the writes are then applied, so Spike executes them
  // too. A stale fetch of old bytes is not accepted: software runs DMA'd code only after FENCE.I.
  bool ext_fetch(hart_state_t& h, const tr_rec_t& r) {
    if (ext_.empty()) return false;
    const unsigned n = r.rvc ? 2 : 4;
    std::vector<size_t> took;
    for (unsigned i = 0; i < n; i++) {
      uint64_t pa = 0;
      if (!spike_data_paddr(h.p, *env_, r.pc + i, pa, true) || !env_->in_dram(pa)) return false;
      const uint8_t got = uint8_t(r.insn >> (8 * i)), have = *reinterpret_cast<const uint8_t*>(env_->addr_to_mem(pa));
      if (got == have) continue;
      bool ok = false;
      for (size_t k = ext_.size(); k-- > 0 && !ok;) {
        const ext_write_t& e = ext_[k];
        const uint64_t off = pa - e.pa;
        if (off < e.len && (e.mask >> off & 1) && !e.applied && r.cycle + cfg_.ext_early >= e.cycle && got == e.nw[off])
          ok = true, took.push_back(k);
      }
      if (!ok) return false;
    }
    for (size_t k : took) ext_apply(k);
    return true;
  }

  // Every record of hart hi counts towards the windows of the writes visible at its cycle. A hart past a
  // write's window reads only its new bytes, so the write is applied then; a write every hart is past is
  // just memory and is dropped.
  void ext_tick(size_t hi, uint64_t cycle) {
    any_rec_ = true;
    if (cycle > last_cycle_) last_cycle_ = cycle;
    if (ext_.empty()) return;
    for (size_t k = 0; k < ext_.size(); k++) {
      ext_write_t& e = ext_[k];
      if (cycle >= e.cycle && e.seen[hi] < cfg_.ext_window && ++e.seen[hi] == cfg_.ext_window) ext_apply(k);
    }
    while (!ext_.empty()) {
      const ext_write_t& e = ext_.front();
      bool all = true;
      for (uint32_t n : e.seen) all = all && n >= cfg_.ext_window;
      if (!all || !e.applied) break;
      ext_.pop_front();
    }
  }

  // A plain load whose value differs from Spike's: accepted if each byte is Spike's memory, the new byte
  // of an external write visible at the record's cycle and not applied yet, or the old byte of an applied
  // one whose window is still open for this hart (§3.10). The RTL's value is then taken over, and a write
  // whose new bytes it returned is applied: the hart has seen it.
  bool ext_load(hart_state_t& h, const tr_rec_t& r, const spike_step_t& st) {
    if (ext_.empty() || st.nld != 1 || st.nst || st.ld_size == 0 || st.ld_size > 8) return false;
    const ld_ext_t kind = load_extension(r.insn, r.rvc);
    uint64_t pa = 0;
    if (kind == ld_ext_t::unknown || !data_paddr(h, st.ld_addr, pa) || !env_->in_dram(pa) ||
        !env_->in_dram(pa + st.ld_size - 1))
      return false;
    if (!ext_bytes(h, r, pa, st.ld_size, reinterpret_cast<const uint8_t*>(env_->addr_to_mem(pa)), kind)) return false;
    adopt_rd(h, r);
    return true;
  }

  // An AMO that read an external write's bytes: its read is accepted as a load's (against the value Spike
  // read, since Spike's memory now holds Spike's result), its store data must be the operation on what the
  // RTL read, and Spike's memory gets the writes, then that result.
  bool ext_amo(hart_state_t& h, const tr_rec_t& r, spike_step_t& st, uint64_t rs2) {
    uint64_t pa = 0, res = 0;
    const unsigned n = st.ld_size;
    if (ext_.empty() || st.nld != 1 || st.nst != 1 || (n != 4 && n != 8) || !r.mem_st ||
        !data_paddr(h, st.ld_addr, pa) || !env_->in_dram(pa) || !env_->in_dram(pa + n - 1))
      return false;
    uint8_t before[8];
    for (unsigned i = 0; i < n; i++) before[i] = uint8_t(st.rd_value >> (8 * i));
    uint8_t* m = reinterpret_cast<uint8_t*>(env_->addr_to_mem(pa));
    memcpy(m, before, n);  // Spike's memory as the AMO found it
    if (!ext_bytes(h, r, pa, n, m, n == 4 ? ld_ext_t::sext : ld_ext_t::none) || !amo_result(r.insn, r.rd_value, rs2, res)) {
      amo_result(r.insn, st.rd_value, rs2, res);
      memcpy(m, &res, n);  // as Spike left it
      return false;
    }
    ext_apply_under(pa, n, r.cycle);
    memcpy(m, &res, n);
    st.st_val = res;  // the store data compare that follows checks the RTL's against it
    adopt_rd(h, r);
    return true;
  }

  void adopt_rd(hart_state_t& h, const tr_rec_t& r) {
    state_t* s = h.p->get_state();
    if (r.rd_fp) {
      freg_t v;
      v.v[0] = r.rd_value;
      v.v[1] = ~0ull;
      s->FPR.write(r.rd, v);
    } else {
      s->XPR.write(r.rd, r.rd_value);
    }
  }

  // Whether the n bytes the RTL's value holds are, each, memory's byte `m` or an external write's
  // alternative (§3.10); applies the writes whose new bytes the hart read.
  bool ext_bytes(hart_state_t& h, const tr_rec_t& r, uint64_t pa, unsigned n, const uint8_t* m, ld_ext_t kind) {
    const size_t hi = size_t(&h - harts_.data());
    uint8_t got[8] = {};
    for (unsigned i = 0; i < n; i++) got[i] = uint8_t(r.rd_value >> (8 * i));
    if (extend_load(got, n, kind) != r.rd_value) return false;
    std::vector<size_t> took_new;
    for (unsigned i = 0; i < n; i++) {
      if (got[i] == m[i]) continue;
      bool ok = false;
      for (size_t k = ext_.size(); k-- > 0 && !ok;) {  // the newest write of the byte first
        const ext_write_t& e = ext_[k];
        const uint64_t off = pa + i - e.pa;
        if (off >= e.len || !(e.mask >> off & 1) || r.cycle + cfg_.ext_early < e.cycle) continue;
        if (!e.applied && got[i] == e.nw[off]) ok = true, took_new.push_back(k);
        else if (e.applied && e.seen[hi] < cfg_.ext_window && got[i] == e.old[off]) ok = true;
      }
      if (!ok) return false;
    }
    for (size_t k : took_new) ext_apply(k);
    if (!took_new.empty()) ext_loads_new_++;
    return true;
  }

  // A store that commits at or after an external write's cycle comes after it: the write is applied
  // first, under the store's bytes (Spike has already stored them), and those bytes leave the write.
  void ext_store(hart_state_t& h, const tr_rec_t& r, const spike_step_t& st) {
    uint64_t pa = 0;
    if (!data_paddr(h, st.st_addr, pa) || !env_->in_dram(pa)) return;
    const unsigned n = st.st_size;
    uint8_t* m = reinterpret_cast<uint8_t*>(env_->addr_to_mem(pa));
    uint8_t keep[8];
    memcpy(keep, m, n);
    for (size_t k = 0; k < ext_.size(); k++)
      if (!ext_[k].applied && r.cycle >= ext_[k].cycle && ext_overlap(ext_[k], pa, n)) ext_apply(k);
    memcpy(m, keep, n);
    // The store's bytes are the core's now: no write offers another value for them.
    for (auto& e : ext_)
      for (unsigned i = 0; i < n; i++)
        if (pa + i >= e.pa && pa + i < e.pa + e.len) e.mask &= ~(1u << (pa + i - e.pa));
  }

  // ---- Other harts' writes (§3.7) ----
  bool multi() const { return cfg_.hart_window && harts_.size() > 1 && harts_.size() <= HW_MAX_HARTS; }
  uint64_t hw_next() const { return hw_base_ + hw_.size(); }
  uint8_t* mem_at(uint64_t pa) { return reinterpret_cast<uint8_t*>(env_->addr_to_mem(pa)); }
  // A main-memory access within one doubleword (the core traps misaligned ones), translated as hart h would
  bool hw_paddr(hart_state_t& h, uint64_t va, unsigned n, uint64_t& pa) {
    return n && n <= 8 && data_paddr(h, va, pa) && env_->in_dram(pa) && env_->in_dram(pa + n - 1) && (pa & 7) + n <= 8;
  }

  // Before a store, AMO or SC: the bytes it is about to replace
  bool hw_before(hart_state_t& h, const tr_rec_t& r, bool atomic, hart_write_t& w) {
    if (!multi()) return false;
    const unsigned n = 1u << r.mem_size;
    uint64_t pa = 0;
    if (!hw_paddr(h, r.mem_vaddr, n, pa)) return false;
    w.pa = pa;
    w.len = n;
    w.hart = unsigned(&h - harts_.data());
    w.atomic = atomic;
    memcpy(w.old, mem_at(pa), n);
    memcpy(w.spike_old, w.old, n);
    return true;
  }

  // After it: its new bytes, and each hart's record count, which opens the windows
  void hw_push(hart_write_t& w) {
    memcpy(w.nw, mem_at(w.pa), w.len);
    for (size_t i = 0; i < harts_.size(); i++) w.base[i] = harts_[i].nrec;
    w.id = hw_id_++;
    late_write(w);
    hw_.push_back(w);
    // Writes every hart that has run is past go; a hart that stays quiet keeps them up to HW_CAP
    while (!hw_.empty()) {
      const hart_write_t& f = hw_.front();
      bool drop = hw_.size() > HW_CAP;
      if (!drop) {
        drop = true;
        for (size_t i = 0; i < harts_.size() && drop; i++)
          if (i != f.hart && harts_[i].nrec && harts_[i].nrec - f.base[i] < cfg_.hart_window) drop = false;
      }
      if (!drop) break;
      hw_.pop_front();
      hw_base_++;
    }
  }

  // Whether the n bytes `got` may be what hart hi read at its record (of `cycle`): each is Spike's memory `mem`
  // then, or the old byte of a write of another hart from before then (seq_end) whose window was open for hi
  // (nrec, hi's record count then), searching back no further than a write of hi's own, and for an atomic no
  // further than another hart's atomic recorded ATOMIC_EARLY cycles or more before it (atomics perform before
  // they retire, so one recorded just before may have performed after it); or, with `late`, the byte of a
  // late lander (late_) that was one before then (id_end). seq[i]: the write whose old byte i took, or HW_NONE;
  // late[i]: the late lander's id, or HW_NONE.
  bool hw_accept(size_t hi, uint64_t pa, unsigned n, const uint8_t* got, const uint8_t* mem, bool atomic,
                 uint64_t cycle, uint64_t seq_end, uint64_t nrec, uint64_t* seq, uint64_t* late = nullptr,
                 uint64_t id_end = HW_NONE) {
    for (unsigned i = 0; i < n; i++) {
      seq[i] = HW_NONE;
      if (late) late[i] = HW_NONE;
      if (got[i] == mem[i]) continue;
      const uint64_t b = pa + i;
      bool ok = false;
      for (size_t k = hw_.size(); k-- > 0;) {
        const uint64_t q = hw_base_ + k;
        if (q >= seq_end) continue;
        const hart_write_t& e = hw_[k];
        if (b < e.pa || b >= e.pa + e.len) continue;
        if (e.hart == hi || nrec - e.base[hi] >= cfg_.hart_window || (atomic && e.atomic && e.cycle + ATOMIC_EARLY <= cycle))
          break;
        if (e.old[b - e.pa] == got[i] || (e.alt_mask >> (b - e.pa) & 1 && e.alt[b - e.pa] == got[i])) {
          ok = true;
          seq[i] = q;
          break;
        }
      }
      if (!ok && late) ok = late_find(b, got[i], id_end, late[i]);
      if (!ok) return false;
    }
    return true;
  }

  // Whether every byte an access read past (seq) is as well the byte of a late lander: then either may be what
  // happened (that write had not landed, or the late lander landed after it), and later reads tell
  bool hw_late_too(uint64_t pa, unsigned n, const uint8_t* got, const uint64_t* seq) const {
    bool any = false;
    for (unsigned i = 0; i < n; i++) {
      if (seq[i] == HW_NONE) continue;
      uint64_t id = 0;
      if (!late_find(pa + i, got[i], HW_NONE, id)) return false;
      any = true;
    }
    return any;
  }

  // The first write an access read past (HW_NONE: none)
  static uint64_t hw_from(const uint64_t* seq, unsigned n) {
    uint64_t f = HW_NONE;
    for (unsigned i = 0; i < n; i++) f = std::min(f, seq[i]);
    return f;
  }

  // Whether atomic write e, back on top of `dw` (its doubleword as memory would hold it there), read what it
  // finds: the bytes its record showed (an AMO's rd, an SC's LR), or for an AMO with rd = x0 a value whose result
  // is what it wrote. An SC whose LR the trace did not show fits anywhere.
  static bool hw_fits(const hart_write_t& e, const uint8_t* dw) {
    const uint8_t* cur = dw + (e.pa & 7);
    if (e.read_known) return memcmp(e.read, cur, e.len) == 0;
    if ((e.insn >> 27) == 3) return true;
    uint64_t v = 0, res = 0;
    memcpy(&v, cur, e.len);
    return amo_result(e.insn, v, e.rs2, res) && memcmp(&res, e.nw, e.len) == 0;
  }

  // An access of hart hi (of `cycle`) that read past write `from` overlapping [pa, pa+n): in the core, that write
  // and the later ones of other harts' plain stores there reached memory after it, and so did the atomics of other
  // harts it read past (seq: per byte, the write it read past; null: any), recorded less than ATOMIC_EARLY cycles
  // before it. A store is one access, so each goes back on top whole, oldest first. Here they are chosen (qs) on
  // `sim`, the doubleword as memory will hold it under them, and an atomic among them must have read what it finds
  // there (hw_fits): if one did not, the result is false. For a successful SC (`lenient`; lr: the bytes its LR
  // read, at lr_pa, or null), an atomic goes on top only if its write changed bytes the LR read (it came after the
  // LR, so after the SC) and it fits; any other stays where it is, as do late landers a read has placed.
  // A plain store that goes back on top is followed by its hart's younger plain stores to its bytes, beyond the
  // access too: a hart's stores reach memory in order (core-2's case, 10-23: an sd on top without the sh after it
  // to bytes the AMO did not touch put the sd's stale bytes over the sh's).
  bool hw_reapply_plan(size_t hi, uint64_t pa, unsigned n, uint64_t from, const uint64_t* seq, uint64_t cycle,
                       bool lenient, uint8_t* sim, std::vector<uint64_t>& qs, const uint8_t* lr = nullptr,
                       uint64_t lr_pa = 0, unsigned lr_n = 0) {
    const uint64_t dw = pa & ~7ull;
    std::vector<uint8_t> follow(harts_.size(), 0);  // per hart: the bytes of its plain stores back on top
    for (uint64_t q = std::max(from, hw_base_); q < hw_next(); q++) {
      const hart_write_t& e = hw_[q - hw_base_];
      if (!e.len || e.hart == hi || (lenient && e.settled)) continue;
      if (e.pa >= pa + n || e.pa + e.len <= pa) {   // beyond the access: only as a follower
        if (!e.atomic && (e.pa & ~7ull) == dw && (dw_mask(e.pa, e.len) & follow[e.hart])) {
          memcpy(sim + (e.pa - dw), e.nw, e.len);
          qs.push_back(q);
          follow[e.hart] |= dw_mask(e.pa, e.len);
        }
        continue;
      }
      if (e.atomic) {
        bool past = !seq;
        for (unsigned i = 0; i < n && !past; i++)
          past = seq[i] != HW_NONE && seq[i] <= q && pa + i >= e.pa && pa + i < e.pa + e.len;
        if (!past || e.cycle + ATOMIC_EARLY <= cycle) continue;
        if (lenient) {
          bool changed = false;
          for (unsigned b = 0; lr && b < e.len; b++)
            if (e.pa + b >= lr_pa && e.pa + b < lr_pa + lr_n) changed = changed || e.nw[b] != lr[e.pa + b - lr_pa];
          if (!changed) continue;
        }
        // What it finds there: beyond the access, where memory still holds its own bytes, the ones it replaced
        uint8_t at[8];
        memcpy(at, sim, 8);
        for (unsigned b = 0; b < e.len; b++) {
          const uint64_t a = e.pa + b;
          if ((a < pa || a >= pa + n) && at[a - dw] == e.nw[b]) at[a - dw] = e.old[b];
        }
        if (!hw_fits(e, at)) {
          if (lenient) continue;
          return false;
        }
      }
      memcpy(sim + (e.pa - dw), e.nw, e.len);
      qs.push_back(q);
      if (!e.atomic) follow[e.hart] |= dw_mask(e.pa, e.len);
    }
    return true;
  }

  // Puts back the writes hw_reapply_plan chose for the access [pa, pa+n); each keeps the bytes it now replaces as its
  // old ones, and where memory still holds its own bytes (beyond the access, untouched since), the ones it replaced
  // before. Within the access memory's byte is the atomic's (or an earlier write's put back), even where it equals
  // the write's own: seed 463583 of the coordinator's stress check (10-23), a swap's 0x00 under an sd's 0x00 left
  // the sd's old byte from before the swap, and a later read past the sd expected it.
  void hw_reapply(const std::vector<uint64_t>& qs, uint64_t pa, unsigned n) {
    for (size_t x = 0; x < qs.size(); x++) {
      const uint64_t q = qs[x];
      hart_write_t& e = hw_[q - hw_base_];
      uint8_t* m = mem_at(e.pa);
      for (unsigned b = 0; b < e.len; b++) {
        const uint64_t a = e.pa + b;
        const bool in = a >= pa && a < pa + n;
        // beyond the access, memory may hold a younger store of its hart that goes back after it: that one lands
        // after it, so it keeps the byte it replaced (seed 523692 of the 10-23 checks: an sd put back took the next
        // sd's bytes as its old ones, and a later read of the bytes from before both was not found)
        bool younger = false;
        for (size_t z = x + 1; z < qs.size() && !in && !younger; z++) {
          const hart_write_t& f = hw_[qs[z] - hw_base_];
          younger = f.hart == e.hart && !f.atomic && a >= f.pa && a < f.pa + f.len;
        }
        if (in || (m[b] != e.nw[b] && !younger)) e.old[b] = m[b];
        m[b] = e.nw[b];
      }
      hw_moved_.push_back(q);
      if (!late_.empty()) late_drop(e);  // it reached memory here, whatever later writes it might have followed
    }
  }

  // The writes re-applied after an atomic came after it in the core: they move behind its own write, so that
  // later searches meet them first (it is a barrier for its own hart's)
  void hw_move_back() {
    std::sort(hw_moved_.begin(), hw_moved_.end());
    hw_moved_.erase(std::unique(hw_moved_.begin(), hw_moved_.end()), hw_moved_.end());
    for (uint64_t q : hw_moved_)
      if (q >= hw_base_ && q < hw_next()) hw_to_back(size_t(q - hw_base_));
    hw_moved_.clear();
  }

  // Moves write k of the history to its end. Its place stays, empty (len 0), so that the sequence numbers
  // views, LRs and reads past hold keep naming the same writes.
  void hw_to_back(size_t k) {
    hart_write_t e = hw_[k];
    hw_[k].len = 0;
    e.moved = true;
    hw_.push_back(e);
  }

  void hw_note_lr(hart_state_t& h, const uint64_t* seq, unsigned n, bool amb) {
    const uint64_t from = hw_from(seq, n);
    if (from == HW_NONE) return;
    h.lr_old = true;
    h.lr_from = from;
    h.lr_amb = amb;
  }

  // A plain load or LR whose value differs from Spike's: accepted if it read bytes other harts' writes had
  // replaced (hw_accept); the RTL's value is taken over
  bool hw_load(hart_state_t& h, const tr_rec_t& r, const spike_step_t& st, bool lr) {
    if (!multi() || st.nld != 1 || st.nst) return false;
    const unsigned n = st.ld_size;
    const ld_ext_t kind = load_extension(r.insn, r.rvc);
    uint64_t pa = 0, seq[8];
    if (kind == ld_ext_t::unknown || !hw_paddr(h, st.ld_addr, n, pa)) return false;
    uint8_t got[8] = {};
    for (unsigned i = 0; i < n; i++) got[i] = uint8_t(r.rd_value >> (8 * i));
    if (extend_load(got, n, kind) != r.rd_value) return false;
    const size_t hi = size_t(&h - harts_.data());
    uint64_t late[8];
    if (!hw_accept(hi, pa, n, got, mem_at(pa), lr, r.cycle, hw_next(), h.nrec, seq, late)) return false;
    if (lr) hw_note_lr(h, seq, n, hw_late_too(pa, n, got, seq));
    late_settle(hi, pa, n, late, got);
    adopt_rd(h, r);
    if (hw_from(seq, n) != HW_NONE) hart_loads_old_++;
    return true;
  }

  // The doubleword at pa as memory will hold it once an AMO's result res (n bytes at pa) is written (late
  // landers it read settle only under it): for hw_reapply_plan
  void hw_amo_sim(uint64_t pa, unsigned n, const uint8_t* res, uint8_t* sim) {
    const uint64_t dw = pa & ~7ull;
    memcpy(sim, mem_at(dw), 8);
    memcpy(sim + (pa - dw), res, n);
  }

  // An AMO that read past another hart's plain store (or its atomic, recorded just before): its store data must
  // be the operation on what the RTL read, and Spike's memory gets that result, then the writes it read past on
  // top (hw_reapply_plan)
  bool hw_amo(hart_state_t& h, const tr_rec_t& r, spike_step_t& st, uint64_t rs2, hart_write_t* w) {
    const unsigned n = st.ld_size;
    uint64_t pa = 0, res = 0, seq[8];
    if (!multi() || st.nld != 1 || st.nst != 1 || (n != 4 && n != 8) || !r.mem_st || !hw_paddr(h, st.ld_addr, n, pa))
      return false;
    uint8_t before[8] = {}, got[8] = {};
    for (unsigned i = 0; i < n; i++) before[i] = uint8_t(st.rd_value >> (8 * i)), got[i] = uint8_t(r.rd_value >> (8 * i));
    if (extend_load(got, n, n == 4 ? ld_ext_t::sext : ld_ext_t::none) != r.rd_value) return false;
    const size_t hi = size_t(&h - harts_.data());
    uint64_t late[8];
    if (!hw_accept(hi, pa, n, got, before, true, r.cycle, hw_next(), h.nrec, seq, late) ||
        !amo_result(r.insn, r.rd_value, rs2, res))
      return false;
    // Bytes a late lander explains as well need nothing put back, byte by byte: what they read past stays put, and
    // becomes a late lander at its write (seed 1831284 of the soak, 10-23: one byte's read past, which a late lander
    // also explained, put an older store back on top that a later read contradicted)
    uint64_t need[8];
    for (unsigned i = 0; i < n; i++) {
      uint64_t id = 0;
      need[i] = seq[i] != HW_NONE && late_find(pa + i, got[i], HW_NONE, id) ? HW_NONE : seq[i];
    }
    const uint64_t from = hw_from(need, n);
    uint8_t sim[8];
    std::vector<uint64_t> qs;
    hw_amo_sim(pa, n, reinterpret_cast<const uint8_t*>(&res), sim);
    if (!hw_reapply_plan(hi, pa, n, from, need, r.cycle, false, sim, qs)) return false;
    memcpy(mem_at(pa), before, n);  // Spike's memory as the AMO found it, for the late landers it read
    late_settle(hi, pa, n, late, got);
    memcpy(mem_at(pa), &res, n);
    hw_reapply(qs, pa, n);
    st.st_val = res;  // the store data compare that follows checks the RTL's against it
    if (w) memcpy(w->old, got, n);
    adopt_rd(h, r);
    if (hw_from(seq, n) != HW_NONE) hart_loads_old_++;
    if (!qs.empty()) hart_reapplied_++;
    return true;
  }

  // An AMO with rd = x0 shows no value it read. If its store data differs from Spike's, the values its word may
  // have held are tried: as before the newest of the other harts' recent plain stores (and atomics recorded just
  // before it), one more each time, each byte with what they replaced or a late lander's bytes they ended; where
  // none of those writes reaches, Spike's or a late lander's. The first whose result is the RTL's store data is
  // what it read: the late landers it read are settled, the writes it read past follow it into Spike's memory
  // (oldest first, hw_reapply_plan), unless both explain it (below).
  bool hw_amo_x0(hart_state_t& h, const tr_rec_t& r, spike_step_t& st, uint64_t rs2, hart_write_t& w) {
    const unsigned n = w.len;
    if (!multi() || (n != 4 && n != 8)) return false;
    const size_t hi = size_t(&h - harts_.data());
    const uint64_t m = size_mask(r.mem_size), dw = w.pa & ~7ull;
    // newest first, each with the bytes of the access it may be read past on: as in hw_accept, a write of its own
    // hart, or another hart's atomic recorded ATOMIC_EARLY cycles or more before it, closes only its own bytes to
    // the older writes (seed 453487 of the 10-23 checks: an amominu.w of its own on the upper word hid the other
    // hart's sw on the lower word, which both were still in its store queue). A plain store of another hart on
    // closed bytes only ends the list: what follows the AMO is every such store from the oldest it read past.
    std::vector<size_t> past;
    std::vector<uint8_t> pmask;
    uint8_t closed = 0;
    for (size_t k = hw_.size(); k-- > 0 && past.size() < 8;) {
      const hart_write_t& e = hw_[k];
      if (!e.len || e.pa + e.len <= w.pa || e.pa >= w.pa + n) continue;
      if (h.nrec - e.base[hi] >= cfg_.hart_window) break;
      uint8_t em = 0;
      for (unsigned b = 0; b < e.len; b++)
        if (e.pa + b >= w.pa && e.pa + b < w.pa + n) em |= uint8_t(1u << (e.pa + b - w.pa));
      if (e.hart == hi || (e.atomic && e.cycle + ATOMIC_EARLY <= r.cycle)) {
        closed |= em;
        continue;
      }
      if (!(em & ~closed)) break;
      past.push_back(k);
      pmask.push_back(em & ~closed);
    }
    auto lit = late_.find(dw);
    const std::vector<late_t> cands = lit == late_.end() ? std::vector<late_t>() : lit->second;
    // One explanation: reading past the np newest (np_lo..np_hi), each byte may be: as before the oldest of them
    // that reaches it, or a late lander's a write it read past may have replaced instead (alt); where none
    // reaches, Spike's or (with lat) late landers' bytes. Every combination (a few hundred at most) is tried.
    struct found_t {
      size_t np = 0;
      uint8_t word[8] = {};
      uint64_t late[8] = {}, res = 0;
      std::vector<uint64_t> qs;
    };
    auto find = [&](bool lat, bool whole, size_t np_lo, size_t np_hi, found_t& f) {
      for (size_t np = np_lo; np <= np_hi && np <= past.size(); np++) {
        struct opt_t {
          uint8_t v;
          uint64_t late;
        };
        std::vector<opt_t> opts[8];
        uint8_t cover = 0;
        for (unsigned i = 0; i < n; i++) opts[i].push_back({w.old[i], HW_NONE});  // Spike's memory before the AMO
        for (size_t j = 0; j < np; j++) {
          const hart_write_t& e = hw_[past[j]];
          for (unsigned b = 0; b < e.len; b++) {
            if (e.pa + b < w.pa || e.pa + b >= w.pa + n) continue;
            const unsigned i = unsigned(e.pa + b - w.pa);
            if (!(pmask[j] >> i & 1)) continue;
            opts[i].assign(1, {e.old[b], HW_NONE});  // the oldest passed write that reaches it decides
            if (e.alt_mask >> b & 1) opts[i].push_back({e.alt[b], HW_NONE});
            cover |= uint8_t(1u << i);
          }
        }
        // With lat, late landers whole (a store is one access) or, with !whole, byte by byte: a late lander may have
        // landed and a newer write on some of its bytes after it, so a read may show it on only some of them. Whole
        // ones are tried first (seed 1830755 of the soak, 10-23: byte by byte, one byte of an old sd and seven of a
        // newer one came first, a mix no order of the two gives, where the old sd whole explained the result).
        std::vector<std::pair<const late_t*, uint8_t>> lc;  // whole: newest first, with its bytes of the access
        for (auto c = cands.rbegin(); lat && c != cands.rend(); ++c) {
          uint8_t lm = 0;
          for (unsigned i = 0; i < n; i++) {
            const unsigned b = unsigned(w.pa - dw) + i;
            if ((c->mask >> b & 1) && !(cover >> i & 1)) {
              lm |= uint8_t(1u << i);
              if (!whole) opts[i].push_back({c->nw[b], c->id});
            }
          }
          if (whole && lm && lc.size() < 6) lc.emplace_back(&*c, lm);
        }
        size_t combos = 1;
        for (unsigned i = 0; i < n; i++) combos *= opts[i].size();
        if (combos > 4096) combos = 4096;
        for (size_t sub = 0; sub < (size_t(1) << lc.size()); sub++)
          for (size_t x = np || sub ? 0 : 1; x < combos; x++) {  // x = 0 with np = 0 and no late lander: Spike's value
            size_t y = x;
            for (unsigned i = 0; i < n; i++) {
              const opt_t& o = opts[i][y % opts[i].size()];
              y /= opts[i].size();
              f.word[i] = o.v;
              f.late[i] = o.late;
            }
            for (size_t k = lc.size(); k-- > 0;)  // the oldest first, newer ones on top
              if (sub >> k & 1)
                for (unsigned i = 0; i < n; i++)
                  if (lc[k].second >> i & 1) f.word[i] = lc[k].first->nw[unsigned(w.pa - dw) + i], f.late[i] = lc[k].first->id;
            uint64_t read = 0;
            memcpy(&read, f.word, n);
            if (!amo_result(r.insn, read, rs2, f.res) || (f.res & m) != (r.mem_wdata & m)) continue;
            uint8_t sim[8];
            f.qs.clear();
            hw_amo_sim(w.pa, n, reinterpret_cast<const uint8_t*>(&f.res), sim);
            if (np && !hw_reapply_plan(hi, w.pa, n, hw_base_ + past[np - 1], nullptr, r.cycle, false, sim, f.qs)) continue;
            f.np = np;
            return true;
          }
      }
      return false;
    };
    // Reads past first; if late landers alone explain it as well, either may have happened, and it commits to
    // neither: its result goes into memory, and the writes it would have read past become late landers at its
    // write. Late landers' bytes come in only once reads past alone have failed (a result need not depend on
    // what it read).
    found_t f, g;
    bool settle = true;
    if (find(false, false, 1, past.size(), f)) {
      if (!cands.empty() && (find(true, true, 0, 0, g) || find(true, false, 0, 0, g)))
        settle = false, f.qs.clear(), std::fill(f.late, f.late + 8, HW_NONE);
    } else if (!find(true, true, 0, past.size(), f) && !find(true, false, 0, past.size(), f)) {
      return false;
    }
    memcpy(mem_at(w.pa), w.old, n);  // as the AMO found it, under the late landers
    if (settle) late_settle(hi, w.pa, n, f.late, f.word);
    memcpy(mem_at(w.pa), &f.res, n);
    hw_reapply(f.qs, w.pa, n);
    memcpy(w.old, f.word, n);
    st.st_val = f.res;
    if (f.np) hart_loads_old_++;
    if (!f.qs.empty()) hart_reapplied_++;
    return true;
  }

  // A successful SC (of `cycle`): no other hart's write reached its bytes between it and its LR, so the plain
  // stores of other harts that Spike applied since the LR (or since the first one the LR read past) came after it
  // in the core and go back on top; so do their atomics recorded just before it that read what it wrote
  void hw_after_sc(hart_state_t& h, const spike_step_t& st, uint64_t cycle) {
    uint64_t pa = 0;
    if (!hw_paddr(h, st.st_addr, st.st_size, pa) || (h.lr_old && h.lr_amb)) return;  // as hw_amo
    const uint64_t from = h.lr_old ? h.lr_from : h.lr_seq;
    uint8_t sim[8];
    std::vector<uint64_t> qs;
    memcpy(sim, mem_at(pa & ~7ull), 8);
    hw_reapply_plan(size_t(&h - harts_.data()), pa, st.st_size, from, nullptr, cycle, true, sim, qs,
                    h.lr_val_ok ? h.lr_val : nullptr, h.lr_pa, h.lr_n);
    if (qs.empty()) return;
    hw_reapply(qs, pa, st.st_size);
    hart_reapplied_++;
  }

  // An LR: where its SC's window starts
  void hw_note_lr_start(hart_state_t& h, const spike_step_t& st) {
    uint64_t pa = 0;
    h.lr_old = h.lr_val_ok = h.lr_amb = false;
    h.lr_valid = multi() && st.nld == 1 && hw_paddr(h, st.ld_addr, st.ld_size, pa);
    h.lr_pa = pa;
    h.lr_n = st.ld_size;
    h.lr_seq = hw_next();
  }

  // A deferred load or LR keeps its view, for its writeback
  void hw_view(hart_state_t& h, const tr_rec_t& r, const spike_step_t& st, bool lr, pending_wb_t& pw) {
    if (!multi() || st.nld != 1 || st.nst) return;
    const ld_ext_t kind = load_extension(r.insn, r.rvc);
    uint64_t pa = 0;
    if (kind == ld_ext_t::unknown || !hw_paddr(h, st.ld_addr, st.ld_size, pa)) return;
    pw.hw = true;
    pw.atomic = lr;
    pw.n = st.ld_size;
    pw.kind = kind;
    pw.pa = pa;
    memcpy(pw.mem, mem_at(pa), pw.n);
    pw.seq = hw_next();
    pw.id_end = hw_id_;
    pw.nrec = h.nrec;
    pw.step = h.steps;
    view_snapshot(h, pw);
  }

  // What a deferred read's view keeps of the history at its record, for its writeback: the late landers on its
  // doubleword (newest first, pending_wb_t::late), and for each byte the values a read past could return then
  // (hw_accept's search, pending_wb_t::past). A later write may end a late lander, and a write moved behind a later
  // atomic leaves its slot empty (seed 465101 of the coordinator's stress check, 10-23: a deferred ld read past an sd
  // that a later AMO of its hart then moved, so its writeback's own search no longer found the sd).
  void view_snapshot(hart_state_t& h, pending_wb_t& pw) {
    if (auto it = late_.find(pw.pa & ~7ull); it != late_.end())
      for (auto c = it->second.rbegin(); c != it->second.rend() && pw.nlate < 4; ++c) {
        pw.late[pw.nlate].mask = c->mask;
        memcpy(pw.late[pw.nlate].nw, c->nw, 8);
        pw.nlate++;
      }
    const size_t hi = size_t(&h - harts_.data());
    for (unsigned i = 0; i < pw.n; i++) {
      const uint64_t b = pw.pa + i;
      auto put = [&](uint8_t v) {
        for (unsigned j = 0; j < pw.npast[i]; j++)
          if (pw.past[i][j] == v) return;
        if (pw.npast[i] < 6) pw.past[i][pw.npast[i]++] = v;
      };
      for (size_t k = hw_.size(); k-- > 0;) {
        const hart_write_t& e = hw_[k];
        if (b < e.pa || b >= e.pa + e.len) continue;
        if (e.hart == hi || pw.nrec - e.base[hi] >= cfg_.hart_window ||
            (pw.atomic && e.atomic && e.cycle + ATOMIC_EARLY <= pw.cycle))
          break;
        put(e.old[b - e.pa]);
        if (e.alt_mask >> (b - e.pa) & 1) put(e.alt[b - e.pa]);
      }
    }
  }

  // A deferred AMO keeps its view too (tg_replay's --defer-all; the core shows an AMO's read at its record): Spike's
  // memory as the AMO found it (w, from before its step), and its operand and store data, which what it read must
  // give (wb). Its record went as with rd = x0 (hw_amo_x0).
  void hw_view_amo(hart_state_t& h, const tr_rec_t& r, const spike_step_t& st, const hart_write_t* w, uint64_t rs2,
                   pending_wb_t& pw) {
    const unsigned n = st.ld_size;
    if (!multi() || !w || st.nld != 1 || st.nst != 1 || (n != 4 && n != 8) || w->len != n) return;
    pw.hw = pw.atomic = pw.amo = true;
    pw.n = n;
    pw.kind = n == 4 ? ld_ext_t::sext : ld_ext_t::none;
    pw.pa = w->pa;
    memcpy(pw.mem, w->spike_old, n);
    pw.seq = hw_next();
    pw.id_end = hw_id_;
    pw.nrec = h.nrec;
    pw.step = h.steps;
    pw.rs2 = rs2;
    pw.wmask = size_mask(r.mem_size);
    pw.wdata = r.mem_wdata & pw.wmask;
    view_snapshot(h, pw);
  }

  // A deferred load's bytes that its view and the windows do not explain together (§3.7). It may have read
  // later than its record, so each byte may also be: one hw_accept takes on its own; that of a late lander from
  // before its record that a read has since shown landed, or one there at its record that a later write has ended
  // since (p.late), or one a read past could return at its record (p.past); or that of atomics of other harts
  // recorded after it (by up to ATOMIC_EARLY cycles), which performed before they retired (its view with their writes
  // on top, oldest first).
  bool hw_wb_more(size_t hi, const pending_wb_t& p, const uint8_t* got) {
    bool ok[8] = {};
    uint8_t b[8];
    memcpy(b, p.mem, p.n);
    for (unsigned i = 0; i < p.n; i++) {
      uint64_t seq = 0, late = 0;
      ok[i] = hw_accept(hi, p.pa + i, 1, got + i, p.mem + i, p.atomic, p.cycle, p.seq, p.nrec, &seq, &late, p.id_end);
      const unsigned at = unsigned((p.pa + i) & 7);
      for (unsigned k = 0; k < p.nlate && !ok[i]; k++) ok[i] = (p.late[k].mask >> at & 1) && p.late[k].nw[at] == got[i];
      for (unsigned j = 0; j < p.npast[i] && !ok[i]; j++) ok[i] = p.past[i][j] == got[i];
    }
    for (uint64_t q = hw_base_; q < hw_next(); q++) {
      const hart_write_t& e = hw_[q - hw_base_];
      if (!e.len || e.hart == hi || e.pa >= p.pa + p.n || e.pa + e.len <= p.pa) continue;
      const bool settled = e.settled && e.id < p.id_end;
      const bool early = q >= p.seq && e.atomic && e.cycle <= p.cycle + ATOMIC_EARLY;
      for (unsigned i = 0; i < p.n; i++) {
        if (p.pa + i < e.pa || p.pa + i >= e.pa + e.len) continue;
        const uint8_t v = e.nw[p.pa + i - e.pa];
        if (early) b[i] = v;
        ok[i] = ok[i] || (settled && got[i] == v) || (early && got[i] == b[i]);
      }
    }
    for (unsigned i = 0; i < p.n; i++)
      if (!ok[i]) return false;
    return true;
  }

  // A deferred value that differs from Spike's, checked against the load's view; taken over into Spike's
  // register unless a later instruction has written it since
  bool hw_wb(hart_state_t& h, const pending_wb_t& p, const tr_wb_t& w) {
    uint8_t got[8] = {};
    uint64_t seq[8];
    for (unsigned i = 0; i < p.n; i++) got[i] = uint8_t(w.value >> (8 * i));
    if (extend_load(got, p.n, p.kind) != w.value) return false;
    const size_t hi = size_t(&h - harts_.data());
    uint64_t late[8];
    // A deferred AMO that read what its record settled on needs nothing more: its record put back what that read past
    if (!(p.amo && w.value == p.decided) &&
        !hw_accept(hi, p.pa, p.n, got, p.mem, p.atomic, p.cycle, p.seq, p.nrec, seq, late, p.id_end)) {
      if (!hw_wb_more(hi, p, got)) return false;
      std::fill(seq, seq + 8, HW_NONE);
    }
    if (p.atomic && !p.amo) hw_note_lr(h, seq, p.n, hw_late_too(p.pa, p.n, got, seq));
    if (h.last_wr[p.rd_fp][p.rd & 31] == p.step) {
      state_t* s = h.p->get_state();
      if (p.rd_fp) {
        freg_t v;
        v.v[0] = w.value;
        v.v[1] = ~0ull;
        s->FPR.write(p.rd, v);
      } else {
        s->XPR.write(p.rd, w.value);
      }
    }
    hart_loads_old_++;
    return true;
  }

  // ---- Late landers (§3.7) ----
  static uint8_t dw_mask(uint64_t pa, unsigned n) { return uint8_t(((1u << n) - 1) << (pa & 7)); }

  // Write w (about to enter the history) and the late landers: none of its hart's own earlier stores, nor any
  // whose window its hart is past, can still land after it on its bytes. The plain stores of other harts it
  // replaced may, while their window for its hart is open, unless it read them (an AMO, or an SC through its
  // LR, that returned a store's new bytes came after it). So may their atomics recorded less than ATOMIC_EARLY
  // cycles before w if w is an atomic (it may have performed before them) and they read what w wrote. An atomic
  // that read past stores is followed by them instead (hw_reapply): they are the last writers of their bytes, and
  // the older stores under them stay candidates as above (core-2's case, 10-23: an sd whose bytes equal what was
  // there before it may have landed after the AMO whose read showed them, as its hart's younger sw did). A plain
  // store that may land after w, a late lander or one this record put back on top, brings its hart's older plain
  // stores to those bytes, back to another hart's write there: they may land after w too, before it (seed 503877 of
  // the 10-23 checks: an AMO read past three sd's of the other hart, a late lander explained it as well, and a later
  // read showed the second sd, the third still to land; seed 1810279 of the soak, 10-23: an AMO read past two sh's of
  // the other hart, the second went back on top, and the next AMO read the first, which equals the bytes before it).
  void late_write(hart_write_t& w) {
    const uint64_t dw = w.pa & ~7ull, nh = harts_[w.hart].nrec;
    const uint8_t wm = dw_mask(w.pa, w.len);
    if (auto it = late_.find(dw); it != late_.end()) {
      // A late lander it ends had reached memory by now, perhaps after the write it was one over: so the bytes w
      // replaced may be its (newest first)
      for (auto c = it->second.rbegin(); c != it->second.rend(); ++c) {
        const uint8_t ends = c->mask & wm;
        if (!ends || (c->hart != w.hart && nh - c->base[w.hart] < cfg_.hart_window)) continue;
        for (unsigned b = 0; b < 8; b++) {
          const unsigned i = b - unsigned(w.pa & 7);
          if ((ends >> b & 1) && !(w.alt_mask >> i & 1)) w.alt[i] = c->nw[b], w.alt_mask |= uint8_t(1u << i);
        }
        c->mask &= uint8_t(~wm);
      }
      late_prune(it);
    }
    auto add = [&](const late_t& c) {
      auto& v = late_[dw];
      auto same = std::find_if(v.begin(), v.end(), [&](const late_t& x) { return x.id == c.id; });
      if (same == v.end()) {
        v.push_back(c);
        return;
      }
      same->mask |= c.mask;
      for (unsigned b = 0; b < 8; b++)
        if (c.mask >> b & 1) same->nw[b] = c.nw[b];
    };
    // Plain store e's (write k) older plain stores of its hart to the bytes `mask`, back to another hart's write there
    auto older = [&](size_t k, const hart_write_t& e, uint8_t mask) {
      for (size_t j = k; j-- > 0 && !e.atomic;) {
        const hart_write_t& o = hw_[j];
        if (nh - o.base[w.hart] >= cfg_.hart_window && !o.moved) break;
        if (!o.len || (o.pa & ~7ull) != dw) continue;
        const uint8_t om = dw_mask(o.pa, o.len) & mask;
        if (!om) continue;
        if (o.hart != e.hart || o.atomic) break;
        late_t oc;
        oc.id = o.id;
        oc.hart = o.hart;
        memcpy(oc.base, o.base, sizeof oc.base);
        for (unsigned b = 0; b < 8; b++) {
          if (!(om >> b & 1)) continue;
          const unsigned oi = b - unsigned(o.pa & 7), wi = b - unsigned(w.pa & 7);
          if (w.read_known && w.read[wi] == o.nw[oi] && late_only(j, b + dw, o.nw[oi], w.hart)) continue;  // w read it
          oc.mask |= uint8_t(1u << b);
          oc.nw[b] = o.nw[oi];
        }
        if (oc.mask) add(oc);
      }
    };
    uint8_t left = wm;  // bytes whose last writer is still to be found
    for (size_t k = hw_.size(); k-- > 0 && left;) {
      const hart_write_t& e = hw_[k];
      const bool open = nh - e.base[w.hart] < cfg_.hart_window;
      if (!open && !e.moved) break;  // the writes before it are past w's hart's window too
      if (!e.len || (e.pa & ~7ull) != dw) continue;
      const uint8_t mine = dw_mask(e.pa, e.len) & left;
      if (!mine) continue;
      left &= uint8_t(~mine);
      // back on top behind w (hw_reapply), so not a late lander: the last writer of its bytes
      if (!hw_moved_.empty() && std::find(hw_moved_.begin(), hw_moved_.end(), uint64_t(k) + hw_base_) != hw_moved_.end()) {
        if (e.hart != w.hart && open) older(k, e, mine);
        continue;
      }
      if (e.hart == w.hart || !open) continue;
      if (e.atomic) {
        if (!w.atomic || e.cycle + ATOMIC_EARLY <= w.cycle) continue;
        uint8_t at[8];  // what e would have found after w: w's bytes, and e's own old ones beyond
        memcpy(at, mem_at(dw), 8);
        for (unsigned b = 0; b < e.len; b++) at[e.pa + b - dw] = e.old[b];
        memcpy(at + (w.pa - dw), w.nw, w.len);
        if (!hw_fits(e, at)) continue;
      }
      late_t c;
      c.id = e.id;
      c.hart = e.hart;
      memcpy(c.base, e.base, sizeof c.base);
      for (unsigned b = 0; b < 8; b++) {
        if (!(mine >> b & 1)) continue;
        const unsigned ei = b - unsigned(e.pa & 7), wi = b - unsigned(w.pa & 7);
        if (e.nw[ei] != w.spike_old[wi]) continue;  // not memory's byte then (a settled late lander, an external write)
        if (w.read_known && w.read[wi] == e.nw[ei] && late_only(k, b + dw, e.nw[ei], w.hart)) continue;  // w read it
        c.mask |= uint8_t(1u << b);
        c.nw[b] = e.nw[ei];
      }
      if (!c.mask) continue;
      add(c);
      older(k, e, c.mask);
    }
    if (auto it = late_.find(dw); it != late_.end())  // by id: late_find looks newest first
      std::sort(it->second.begin(), it->second.end(), [](const late_t& a, const late_t& b) { return a.id < b.id; });
  }

  // Whether value v of byte b, written by write k of the history, was none of the byte's values before it that
  // hart h might still have read (the writes before k in h's window, and what they replaced): then a read of v by
  // h shows that k had reached memory
  bool late_only(size_t k, uint64_t b, uint8_t v, unsigned h) const {
    const uint64_t nh = harts_[h].nrec;
    if (hw_[k].old[b - hw_[k].pa] == v) return false;
    for (size_t j = k; j-- > 0;) {
      const hart_write_t& e = hw_[j];
      if (nh - e.base[h] >= cfg_.hart_window && !e.moved) break;
      if (!e.len || b < e.pa || b >= e.pa + e.len) continue;
      if (e.nw[b - e.pa] == v || e.old[b - e.pa] == v) return false;
    }
    return true;
  }

  void late_prune(std::unordered_map<uint64_t, std::vector<late_t>>::iterator it) {
    auto& v = it->second;
    v.erase(std::remove_if(v.begin(), v.end(), [](const late_t& c) { return !c.mask; }), v.end());
    if (v.empty()) late_.erase(it);
  }

  // A late lander whose byte at physical address b is v (written before id_end): its id, newest first
  bool late_find(uint64_t b, uint8_t v, uint64_t id_end, uint64_t& id) const {
    auto it = late_.find(b & ~7ull);
    if (it == late_.end()) return false;
    for (auto c = it->second.rbegin(); c != it->second.rend(); ++c)
      if (c->id < id_end && (c->mask >> (b & 7) & 1) && c->nw[b & 7] == v) {
        id = c->id;
        return true;
      }
    return false;
  }

  // late_find takes the newest late lander that shows a byte. Where an older lander of the same hart shows every byte
  // a read took the younger one for, the older one is the one to settle: one hart's stores land in order, so the younger
  // may still land later (seed 3420615 of the soak, 10-24: two sd's of hart 0 both wrote zeros where hart 1's AMO read
  // zeros; settling the younger dropped it, and it landed after the AMO, under hart 1's next load of the doubleword)
  void oldest_landers(uint64_t dw, uint64_t pa, unsigned n, uint64_t* late, const uint8_t* got) const {
    auto it = late_.find(dw);
    if (it == late_.end()) return;
    const auto& v = it->second;  // by id
    for (unsigned i = 0; i < n; i++) {
      if (late[i] == HW_NONE) continue;
      const uint64_t id = late[i];
      auto c = std::find_if(v.begin(), v.end(), [&](const late_t& x) { return x.id == id; });
      for (auto o = v.begin(); o != c && c != v.end(); ++o) {
        if (o->hart != c->hart) continue;
        bool all = true;
        for (unsigned j = 0; j < n && all; j++)
          if (late[j] == id) {
            const unsigned b = unsigned(pa - dw) + j;
            all = (o->mask >> b & 1) && o->nw[b] == got[j];
          }
        if (all) {
          for (unsigned j = 0; j < n; j++)
            if (late[j] == id) late[j] = o->id;
          break;
        }
      }
    }
  }

  // A read of n bytes at pa that returned `got` showed the late landers late[0..n) (ids; HW_NONE: none): each
  // reached memory after the writes it may land on, so Spike's memory gets its bytes where the read shows them, and
  // its write moves behind them in the history, as if it had just been written (old bytes: those it replaced;
  // windows from now on). Where the read shows other bytes, a later write came on top: it is no late lander there.
  // Bytes the read did not cover stay as they were, it may still land on them. Its hart's earlier late landers on
  // the bytes it settled came before it. Plain stores it landed over that the reading hart hi might not have seen
  // yet (in its window) may still land on top: they become late landers there.
  void late_settle(size_t hi, uint64_t pa, unsigned n, const uint64_t* late_in, const uint8_t* got) {
    const uint64_t dw = pa & ~7ull;
    std::vector<uint64_t> late(late_in, late_in + n);
    oldest_landers(dw, pa, n, late.data(), got);
    std::vector<uint64_t> ids;
    for (unsigned i = 0; i < n; i++)
      if (late[i] != HW_NONE) ids.push_back(late[i]);
    if (ids.empty()) return;
    std::sort(ids.begin(), ids.end());
    ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
    uint8_t* m = mem_at(dw);
    std::vector<std::pair<unsigned, uint64_t>> landed;  // (hart, id) of the late landers this read settled
    for (uint64_t id : ids) {
      auto it = late_.find(dw);
      if (it == late_.end()) return;
      auto& v = it->second;
      auto c = std::find_if(v.begin(), v.end(), [&](const late_t& x) { return x.id == id; });
      if (c == v.end()) continue;
      // A younger late lander of a hart whose older one this read showed has not landed: one hart's stores land in
      // order, so where it matched, its bytes equal the older one's (seed 1950150 of the soak, 10-23: the middle of
      // three sd's showed on two bytes and the last matched the other two, which settled it there and dropped it on
      // the first two, though it landed later)
      if (std::any_of(landed.begin(), landed.end(), [&](const auto& l) { return l.first == c->hart && l.second < id; }))
        continue;
      uint8_t before[8], mask = 0, drop = 0;
      memcpy(before, m, 8);
      for (unsigned i = 0; i < n; i++) {
        const unsigned b = unsigned(pa - dw) + i;
        if (c->mask >> b & 1) (got[i] == c->nw[b] ? mask : drop) |= uint8_t(1u << b);
      }
      const unsigned hart = c->hart;
      if (mask) landed.emplace_back(hart, id);
      for (unsigned b = 0; b < 8; b++)
        if (mask >> b & 1) m[b] = c->nw[b];
      c->mask &= uint8_t(~(mask | drop));
      for (auto& x : v)
        if (x.hart == hart && x.id < id) x.mask &= uint8_t(~mask);
      late_prune(it);
      std::vector<late_t> over;
      for (size_t k = 0; k < hw_.size(); k++) {
        if (hw_[k].id != id || !hw_[k].len) continue;
        for (size_t j = k + 1; j < hw_.size(); j++) {
          const hart_write_t& x = hw_[j];
          const uint8_t xm = x.len && (x.pa & ~7ull) == dw ? dw_mask(x.pa, x.len) & mask : 0;
          if (!xm || x.atomic || x.hart == hi || harts_[hi].nrec - x.base[hi] >= cfg_.hart_window) continue;
          late_t l;
          l.id = x.id;
          l.hart = x.hart;
          l.mask = xm;
          memcpy(l.base, x.base, sizeof l.base);
          for (unsigned b = 0; b < 8; b++)
            if (xm >> b & 1) l.nw[b] = x.nw[b - unsigned(x.pa & 7)];
          over.push_back(l);
        }
        hw_to_back(k);
        hart_write_t& e = hw_.back();
        e.settled = true;
        for (unsigned i = 0; i < e.len; i++) {
          const unsigned b = unsigned(e.pa - dw) + i;
          if (mask >> b & 1) e.old[i] = before[b];
          else e.old[i] = e.nw[i] = m[b];  // bytes it did not land on last: no change there
        }
        for (size_t j = 0; j < harts_.size(); j++) e.base[j] = harts_[j].nrec;
        break;
      }
      if (!over.empty()) {
        auto& lv = late_[dw];
        for (auto& l : over) {
          auto same = std::find_if(lv.begin(), lv.end(), [&](const late_t& x) { return x.id == l.id; });
          if (same == lv.end()) {
            lv.push_back(l);
            continue;
          }
          same->mask |= l.mask;
          for (unsigned b = 0; b < 8; b++)
            if (l.mask >> b & 1) same->nw[b] = l.nw[b];
        }
        std::sort(lv.begin(), lv.end(), [](const late_t& a, const late_t& b) { return a.id < b.id; });
      }
      hart_late_++;
    }
  }

  // A load of hart h returned `value` (n bytes at va): where that is Spike's memory, a late lander with other
  // bytes there has reached memory before the last write if h would see it by now (its own, or past its window)
  void late_seen(hart_state_t& h, uint64_t va, unsigned n, uint64_t value) {
    uint64_t pa = 0;
    if (!hw_paddr(h, va, n, pa)) return;
    auto it = late_.find(pa & ~7ull);
    if (it == late_.end()) return;
    const size_t hi = size_t(&h - harts_.data());
    const uint8_t* m = mem_at(pa);
    for (auto& c : it->second) {
      if (c.hart != hi && h.nrec - c.base[hi] < cfg_.hart_window) continue;
      for (unsigned i = 0; i < n; i++) {
        const unsigned b = unsigned(pa & 7) + i;
        const uint8_t got = uint8_t(value >> (8 * i));
        if ((c.mask >> b & 1) && got == m[i] && c.nw[b] != got) c.mask &= uint8_t(~(1u << b));
      }
    }
    late_prune(it);
  }

  // A write that has reached memory for certain is no late lander
  void late_drop(const hart_write_t& e) {
    auto it = late_.find(e.pa & ~7ull);
    if (it == late_.end()) return;
    for (auto& c : it->second)
      if (c.id == e.id) c.mask = 0;
    late_prune(it);
  }

  // Bytes another master wrote: no late lander stays on them
  void late_forget(uint64_t pa, unsigned len, uint32_t mask) {
    for (unsigned i = 0; i < len; i++) {
      if (!(mask >> i & 1)) continue;
      auto it = late_.find((pa + i) & ~7ull);
      if (it == late_.end()) continue;
      for (auto& c : it->second) c.mask &= uint8_t(~(1u << ((pa + i) & 7)));
      late_prune(it);
    }
  }

  // An SC: the bytes its LR returned are what it replaced, when the trace showed them (§3.7)
  void hw_sc_read(hart_state_t& h, hart_write_t& w) {
    if (!h.lr_valid || !h.lr_val_ok || w.pa < h.lr_pa || w.pa + w.len > h.lr_pa + h.lr_n) return;
    w.read_known = true;
    memcpy(w.read, h.lr_val + (w.pa - h.lr_pa), w.len);
  }

  // Whether atomic later[k] (of harts_[ai]) could have performed before the read early_atomic applies: each byte it
  // read is memory's now, one a read past or a late lander explains, or one a write of its hart queued before it
  // reaches. One that shows no read (an SC, an AMO with rd = x0) could, and so could any while external writes are
  // in a window (§3.10). Seed 423607 of the 10-23 random campaign: an LR read the bytes of a late lander and of an
  // AMO recorded 37 cycles after it; the AMO went first, and its own read showed the SC after that LR.
  bool could_go_first(const std::vector<const tr_rec_t*>& later, size_t k, size_t ai) {
    const tr_rec_t& a = *later[k];
    hart_state_t& ha = harts_[ai];
    const unsigned n = 1u << a.mem_size;
    uint64_t pa = 0;
    if ((a.insn >> 27) == 3 || !a.rd_we || a.rd_deferred || adopts_value(a) || !ext_.empty() ||
        !hw_paddr(ha, a.mem_vaddr, n, pa))
      return true;
    uint8_t got[8] = {}, mem[8];
    for (unsigned i = 0; i < n; i++) got[i] = uint8_t(a.rd_value >> (8 * i));
    memcpy(mem, mem_at(pa), n);
    for (size_t j = 0; j < k; j++) {
      const tr_rec_t& s = *later[j];
      const unsigned sn = 1u << s.mem_size;
      uint64_t spa = 0;
      if (s.hart != a.hart || !hw_paddr(ha, s.mem_vaddr, sn, spa)) continue;
      for (unsigned i = 0; i < n; i++)
        if (pa + i >= spa && pa + i < spa + sn) mem[i] = got[i];
    }
    uint64_t seq[8], late[8];
    return hw_accept(ai, pa, n, got, mem, true, a.cycle, hw_next(), ha.nrec, seq, late);
  }

 public:
  // §3.7, early atomics (lockstep.h)
  int early_atomic(const tr_rec_t& r, const std::vector<const tr_rec_t*>& later) {
    auto it = by_id_.find(r.hart);
    if (failed_ || !multi() || it == by_id_.end() || r.kind != TR_RETIRE || !r.mem_ld || adopts_value(r))
      return -1;
    hart_state_t& h = harts_[it->second];
    const size_t hi = it->second;
    const unsigned n = 1u << r.mem_size;
    const bool amo = !r.rvc && is_amo_insn(r.insn), sc = amo && (r.insn >> 27) == 3, lr = amo && (r.insn >> 27) == 2;
    uint64_t pa = 0;
    if (sc || (r.rd_deferred && (!amo || lr)) || h.p->get_state()->pc != r.pc || !hw_paddr(h, r.mem_vaddr, n, pa))
      return -1;  // a deferred load or LR looks ahead at its writeback
    const uint8_t* m = mem_at(pa);
    uint8_t got[8] = {};
    uint64_t rs2 = 0;
    // An AMO with rd = x0, or whose value is deferred: its store data tells what it read
    const bool x0 = amo && !lr && (!r.rd_we || r.rd_deferred);
    if (x0) {
      if (!r.mem_st || (n != 4 && n != 8)) return -1;
      rs2 = h.p->get_state()->XPR[(r.insn >> 20) & 31];
    } else {
      const ld_ext_t kind = amo ? (n == 4 ? ld_ext_t::sext : ld_ext_t::none) : load_extension(r.insn, r.rvc);
      if (!r.rd_we || kind == ld_ext_t::unknown) return -1;
      for (unsigned i = 0; i < n; i++) got[i] = uint8_t(r.rd_value >> (8 * i));
      if (extend_load(got, n, kind) != r.rd_value) return -1;
    }
    const uint64_t sm = size_mask(r.mem_size);
    // Bytes b may be what it read: for an AMO with rd = x0, exactly; for a value it shows, each byte b's or
    // memory's (a write recorded before the atomic may have reached memory after it performed: it stays on top)
    auto fits = [&](const uint8_t* b) {
      if (!x0) {
        for (unsigned i = 0; i < n; i++)
          if (got[i] != b[i] && got[i] != m[i]) return false;
        return true;
      }
      uint64_t v = 0, res = 0;
      memcpy(&v, b, n);
      return amo_result(r.insn, v, rs2, res) && (res & sm) == (r.mem_wdata & sm);
    };
    if (fits(m)) return -1;
    uint64_t seq[8], late[8];
    if (!x0 && hw_accept(hi, pa, n, got, m, amo, r.cycle, hw_next(), h.nrec, seq)) return -1;  // a read past
    // A late lander may explain it as well; an atomic goes first all the same, which settles nothing, unless what
    // the atomic read could not be there yet (could_go_first)
    const bool by_late = !x0 && hw_accept(hi, pa, n, got, m, amo, r.cycle, hw_next(), h.nrec, seq, late);
    for (size_t k = 0; k < later.size(); k++) {
      const tr_rec_t& a = *later[k];
      auto ia = by_id_.find(a.hart);
      if (ia == by_id_.end() || ia->second == hi || a.kind != TR_RETIRE || !a.mem_st || a.rvc || !is_amo_insn(a.insn) ||
          (a.insn >> 27) == 2)
        continue;
      const unsigned an = 1u << a.mem_size;
      uint64_t apa = 0;
      if (!hw_paddr(harts_[ia->second], a.mem_vaddr, an, apa) || apa >= pa + n || pa >= apa + an) continue;
      uint8_t b[8];
      memcpy(b, m, n);
      for (unsigned i = 0; i < n; i++)
        if (pa + i >= apa && pa + i < apa + an) b[i] = uint8_t(a.mem_wdata >> (8 * (pa + i - apa)));
      if (fits(b) && (!by_late || could_go_first(later, k, ia->second))) return int(k);
    }
    return by_late ? -1 : -2;
  }

  int early_atomic(const tr_wb_t& w, const std::vector<const tr_rec_t*>& later) {
    auto it = by_id_.find(w.hart);
    if (failed_ || !multi() || it == by_id_.end()) return -1;
    const size_t hi = it->second;
    hart_state_t& h = harts_[hi];
    auto pit = h.pending.find(w.wb_tag);
    if (pit == h.pending.end() || !pit->second.hw || pit->second.value == w.value ||
        (pit->second.amo && pit->second.decided == w.value))  // a deferred AMO's record went ahead already
      return -1;
    const pending_wb_t& p = pit->second;
    uint8_t got[8] = {};
    for (unsigned i = 0; i < p.n; i++) got[i] = uint8_t(w.value >> (8 * i));
    uint64_t seq[8], late[8];
    if (extend_load(got, p.n, p.kind) != w.value ||
        hw_accept(hi, p.pa, p.n, got, p.mem, p.atomic, p.cycle, p.seq, p.nrec, seq, late, p.id_end) ||
        hw_wb_more(hi, p, got))
      return -1;
    for (size_t k = 0; k < later.size(); k++) {
      const tr_rec_t& a = *later[k];
      auto ia = by_id_.find(a.hart);
      if (ia == by_id_.end() || ia->second == hi || a.kind != TR_RETIRE || !a.mem_st || a.rvc || !is_amo_insn(a.insn) ||
          (a.insn >> 27) == 2)
        continue;
      const unsigned an = 1u << a.mem_size;
      uint64_t apa = 0;
      if (!hw_paddr(harts_[ia->second], a.mem_vaddr, an, apa) || apa >= p.pa + p.n || p.pa >= apa + an) continue;
      bool ok = true, any = false;  // each byte its view's, or the atomic's
      for (unsigned i = 0; i < p.n && ok; i++) {
        const bool in = p.pa + i >= apa && p.pa + i < apa + an;
        const uint8_t v = in ? uint8_t(a.mem_wdata >> (8 * (p.pa + i - apa))) : 0;
        ok = got[i] == p.mem[i] || (in && got[i] == v);
        any = any || (in && got[i] == v && got[i] != p.mem[i]);
      }
      if (ok && any) return int(k);
    }
    return -2;
  }

 private:

  bool trap(hart_state_t& h, const tr_rec_t& r) {
    const bool amo = !r.rvc && is_amo_insn(r.insn);
    const unsigned f5 = r.insn >> 27;
    env_->amo_step = amo && f5 != 2 && f5 != 3;
    spike_step_t st = step(h, r.insn);
    env_->amo_step = false;
    push_hist(h.spike_hist, st);
    if (!st.trapped)
      return mismatch(&h, &r, strfmt("the RTL trapped with cause %llu; Spike retired the instruction", (unsigned long long)r.cause));
    if (st.interrupt)
      return mismatch(&h, &r, strfmt("the RTL trapped with cause %llu; Spike took interrupt %llu", (unsigned long long)r.cause,
                                     (unsigned long long)(st.cause & 63)));
    if (st.cause != r.cause)
      return mismatch(&h, &r, strfmt("trap cause: RTL %llu, Spike %llu", (unsigned long long)r.cause, (unsigned long long)st.cause));
    if (st.tval != r.tval)
      return mismatch(&h, &r, strfmt("trap tval: RTL %016llx, Spike %016llx", (unsigned long long)r.tval, (unsigned long long)st.tval));
    return true;
  }

  bool irq(hart_state_t& h, const tr_rec_t& r) {
    if (!(r.cause >> 63)) return mismatch(&h, &r, "TR_IRQ whose cause has no interrupt bit");
    unsigned code = unsigned(r.cause & 63);
    reg_t m = reg_t(1) << code;
    state_t* s = h.p->get_state();
    bool was = s->mip->read() & m;
    if (!was) s->mip->backdoor_write_with_mask(m, m);
    spike_step_t st = step(h, 0);
    if (!was) s->mip->backdoor_write_with_mask(m, 0);
    push_hist(h.spike_hist, st);
    if (!st.trapped)
      return mismatch(&h, &r, strfmt("the RTL took interrupt %u before %016llx; Spike executed the instruction "
                                     "(not enabled in Spike)", code, (unsigned long long)r.pc));
    if (!st.interrupt || st.cause != r.cause)
      return mismatch(&h, &r, strfmt("interrupt cause: RTL %016llx, Spike %016llx", (unsigned long long)r.cause,
                                     (unsigned long long)st.cause));
    if (st.epc != r.pc)
      return mismatch(&h, &r, strfmt("interrupt EPC: RTL %016llx, Spike %016llx", (unsigned long long)r.pc,
                                     (unsigned long long)st.epc));
    return true;
  }

  bool wb(const tr_wb_t& w) {
    auto it = by_id_.find(w.hart);
    if (it == by_id_.end()) return mismatch(nullptr, nullptr, strfmt("writeback for hart %u, which Spike does not have", w.hart));
    hart_state_t& h = harts_[it->second];
    push_hist(h.wb_hist, w);
    auto pit = h.pending.find(w.wb_tag);
    if (pit == h.pending.end())
      return mismatch(&h, nullptr, strfmt("writeback with tag %u (%c%u <- %016llx at cycle %llu), which is not pending",
                                          w.wb_tag, w.rd_fp ? 'f' : 'x', w.rd, (unsigned long long)w.value,
                                          (unsigned long long)w.cycle));
    const pending_wb_t& p = pit->second;
    if (p.rd != w.rd || p.rd_fp != w.rd_fp)
      return mismatch(&h, nullptr, strfmt("writeback tag %u: register %c%u, but the instruction at %016llx writes %c%u",
                                          w.wb_tag, w.rd_fp ? 'f' : 'x', w.rd, (unsigned long long)p.pc,
                                          p.rd_fp ? 'f' : 'x', p.rd));
    // A deferred AMO's value: what it read, which its operation must turn into the store data its record showed
    uint64_t res = 0;
    if (p.amo && (!amo_result(p.insn, w.value, p.rs2, res) || (res & p.wmask) != p.wdata))
      return mismatch(&h, nullptr, strfmt("deferred %c%u value (tag %u, AMO at %016llx): RTL %016llx, whose result is not "
                                          "the store data %016llx", w.rd_fp ? 'f' : 'x', w.rd, w.wb_tag,
                                          (unsigned long long)p.pc, (unsigned long long)w.value,
                                          (unsigned long long)p.wdata));
    if (p.value != w.value && !(p.hw && hw_wb(h, p, w)))
      return mismatch(&h, nullptr, strfmt("deferred %c%u value (tag %u, instruction at %016llx): RTL %016llx, Spike %016llx",
                                          w.rd_fp ? 'f' : 'x', w.rd, w.wb_tag, (unsigned long long)p.pc,
                                          (unsigned long long)w.value, (unsigned long long)p.value));
    // A deferred LR's value, for its SC (late landers, §3.7)
    if (p.hw && p.atomic && !p.amo && h.lr_valid && p.pa == h.lr_pa && p.n == h.lr_n && p.seq >= h.lr_seq) {
      h.lr_val_ok = true;
      for (unsigned i = 0; i < p.n; i++) h.lr_val[i] = uint8_t(w.value >> (8 * i));
    }
    h.pending.erase(pit);
    return true;
  }

  std::string sym(uint64_t pc) const {
    if (!elf_) return "";
    std::string s = elf_->nearest(pc);
    return s.empty() ? s : " <" + s + ">";
  }

  lockstep_cfg_t cfg_;
  std::unique_ptr<spike_env_t> env_;
  const elf_t* elf_;
  std::vector<hart_state_t> harts_;
  std::map<uint32_t, size_t> by_id_;
  std::unique_ptr<disassembler_t> dis_;
  bool failed_ = false;
  std::string error_;
  int fail_hart_ = -1;
  tr_rec_t fail_rec_;
  bool has_fail_rec_ = false;
  std::deque<ext_write_t> ext_;
  bool any_rec_ = false;
  uint64_t last_cycle_ = 0, ext_loads_new_ = 0;
  std::deque<hart_write_t> hw_;  // writes still in a window, in the order they reached memory in the core
  uint64_t hw_base_ = 0;         // the sequence number of hw_.front()
  std::vector<uint64_t> hw_moved_;  // writes the current record re-applied
  uint64_t hart_loads_old_ = 0, hart_reapplied_ = 0;
  uint64_t hw_id_ = 0;              // the next write's id
  std::unordered_map<uint64_t, std::vector<late_t>> late_;  // late landers by doubleword, oldest first
  uint64_t hart_late_ = 0;
};

void lockstep_impl_t::report(FILE* f) const {
  auto dis = [this](uint32_t i) { return disasm(i); };
  fprintf(f, "\n==== LOCKSTEP MISMATCH ====\n%s\n", error_.c_str());
  if (has_fail_rec_) fprintf(f, "RTL record: %s%s\n", format_rec(fail_rec_, dis).c_str(), sym(fail_rec_.pc).c_str());
  if (fail_hart_ < 0) return;
  const hart_state_t& h = harts_[fail_hart_];
  fprintf(f, "\n---- last %zu RTL records, hart %u (cycle, hart, privilege, kind) ----\n", h.rtl_hist.size(), h.id);
  for (auto& r : h.rtl_hist) fprintf(f, "%s%s\n", format_rec(r, dis).c_str(), sym(r.pc).c_str());
  if (!h.wb_hist.empty()) {
    fprintf(f, "\n---- last %zu deferred writebacks, hart %u ----\n", h.wb_hist.size(), h.id);
    for (auto& w : h.wb_hist) fprintf(f, "%s\n", format_wb(w).c_str());
  }
  fprintf(f, "\n---- last %zu Spike steps, hart %u (step %llu is the last) ----\n", h.spike_hist.size(), h.id,
          (unsigned long long)h.steps);
  for (auto& s : h.spike_hist) {
    std::string line = strfmt("%c pc=%016llx", priv_char(s.priv), (unsigned long long)s.pc);
    if (s.trapped) {
      line += strfmt(" %s cause=%016llx tval=%016llx epc=%016llx", s.interrupt ? "INTERRUPT" : "TRAP     ",
                     (unsigned long long)s.cause, (unsigned long long)s.tval, (unsigned long long)s.epc);
    } else {
      line += strfmt(" (%08x) %-28s", s.insn, disasm(s.insn).c_str());
      if (s.nwr) line += strfmt(" %c%-2u <- %016llx%s", s.rd_fp ? 'f' : 'x', s.rd, (unsigned long long)s.rd_value,
                                s.adopted ? " (adopted)" : "");
      if (s.nst) line += strfmt(" mem[%016llx]/%u <- %016llx", (unsigned long long)s.st_addr, s.st_size,
                                (unsigned long long)s.st_val);
    }
    fprintf(f, "%s%s\n", line.c_str(), sym(s.pc).c_str());
  }
  if (!h.pending.empty()) {
    fprintf(f, "\n---- pending deferred writebacks, hart %u ----\n", h.id);
    for (auto& [tag, p] : h.pending)
      fprintf(f, "tag %u: %c%u = %016llx, instruction at %016llx retired at cycle %llu\n", tag, p.rd_fp ? 'f' : 'x', p.rd,
              (unsigned long long)p.value, (unsigned long long)p.pc, (unsigned long long)p.cycle);
  }
  fprintf(f, "==== END OF REPORT ====\n");
}

// ---------------------------------------------------------------------------------------------

hart_order_t::hart_order_t(lockstep_t& ls, const std::vector<uint32_t>& hartids)
    : ls_(ls), ids_(hartids), q_(hartids.size() + 1) {}  // the last queue: harts the checker lacks (it reports them)

size_t hart_order_t::index(uint32_t hart) const {
  for (size_t i = 0; i < ids_.size(); i++)
    if (ids_[i] == hart) return i;
  return ids_.size();
}

void hart_order_t::push(const tr_rec_t& r) {
  item_t it;
  it.cyc = r.cycle;
  it.idx = idx_++;
  it.r = r;
  q_[index(r.hart)].push_back(it);
}

void hart_order_t::push(const tr_wb_t& w) {
  item_t it;
  it.cyc = w.cycle;
  it.idx = idx_++;
  it.wb = true;
  it.w = w;
  q_[index(w.hart)].push_back(it);
}

size_t hart_order_t::queued() const {
  size_t n = 0;
  for (auto& d : q_) n += d.size();
  return n;
}

// Applies the head of queue b, after the atomic of another queue its read needs (from queues not already waiting
// for one: `busy`)
bool hart_order_t::head(size_t b, unsigned busy) {
  busy |= 1u << b;
  if (b < ids_.size()) {
    const item_t& hd = q_[b].front();
    std::vector<const tr_rec_t*> later;
    std::vector<std::pair<size_t, size_t>> at;
    for (size_t h = 0; h < ids_.size(); h++)
      for (size_t k = 0; !(busy >> h & 1) && k < q_[h].size() && q_[h][k].cyc <= hd.cyc + ATOMIC_EARLY; k++)
        if (!q_[h][k].wb && q_[h][k].r.mem_st) {
          later.push_back(&q_[h][k].r);
          at.push_back({h, k});
        }
    if (const int e = hd.wb ? ls_.early_atomic(hd.w, later) : ls_.early_atomic(hd.r, later); e >= 0) {
      early_++;
      for (size_t j = 0; j <= at[size_t(e)].second; j++)
        if (!head(at[size_t(e)].first, busy)) return false;
    }
  }
  item_t it = std::move(q_[b].front());
  q_[b].pop_front();
  std::vector<tr_rec_t> rr;
  std::vector<tr_wb_t> ww;
  if (it.wb) ww.push_back(it.w);
  else rr.push_back(it.r);
  return ls_.cycle(rr, ww);
}

bool hart_order_t::drain(uint64_t upto) {
  for (;;) {
    int best = -1;
    for (size_t i = 0; i < q_.size(); i++)
      if (!q_[i].empty() && q_[i].front().cyc <= upto &&
          (best < 0 || q_[i].front().cyc < q_[size_t(best)].front().cyc ||
           (q_[i].front().cyc == q_[size_t(best)].front().cyc && q_[i].front().idx < q_[size_t(best)].front().idx)))
        best = int(i);
    if (best < 0) return true;
    if (!head(size_t(best), 0)) return false;
  }
}

lockstep_t::lockstep_t(const lockstep_cfg_t& cfg, const mem_t& image, const elf_t* elf)
    : impl_(new lockstep_impl_t(cfg, image, elf)) {}
lockstep_t::~lockstep_t() = default;
bool lockstep_t::cycle(const std::vector<tr_rec_t>& recs, const std::vector<tr_wb_t>& wbs) { return impl_->cycle(recs, wbs); }
bool lockstep_t::finish() { return impl_->finish(); }
bool lockstep_t::check_stale(uint64_t now, uint64_t limit) { return impl_->check_stale(now, limit); }
size_t lockstep_t::pending_wbs() const { return impl_->pending_wbs(); }
bool lockstep_t::failed() const { return impl_->failed(); }
const std::string& lockstep_t::error() const { return impl_->error(); }
void lockstep_t::report(FILE* f) const { impl_->report(f); }
std::string lockstep_t::disasm(uint32_t insn) const { return impl_->disasm(insn); }
uint64_t lockstep_t::read_mem64(uint64_t pa) const { return impl_->read_mem64(pa); }
uint64_t lockstep_t::steps() const { return impl_->steps(); }
bool lockstep_t::external_write(uint64_t paddr, const uint8_t* data, uint32_t mask, unsigned len, uint64_t cycle) {
  return impl_->external_write(paddr, data, mask, len, cycle);
}
uint64_t lockstep_t::ext_loads_new() const { return impl_->ext_loads_new(); }
uint64_t lockstep_t::hart_loads_old() const { return impl_->hart_loads_old(); }
uint64_t lockstep_t::hart_reapplied() const { return impl_->hart_reapplied(); }
uint64_t lockstep_t::hart_late() const { return impl_->hart_late(); }
int lockstep_t::early_atomic(const tr_rec_t& r, const std::vector<const tr_rec_t*>& later) {
  return impl_->early_atomic(r, later);
}
int lockstep_t::early_atomic(const tr_wb_t& w, const std::vector<const tr_rec_t*>& later) {
  return impl_->early_atomic(w, later);
}
size_t lockstep_t::ext_pending() const { return impl_->ext_pending(); }
bool lockstep_t::compares_value(const tr_rec_t& r) {
  return r.kind == TR_RETIRE && r.rd_we && !r.rd_deferred && !adopts_value(r);
}

}  // namespace tg
