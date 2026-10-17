// Spike lockstep checker: docs/spec/verification.md §3.
#include "lockstep.h"

#include <climits>
#include <cstring>
#include <deque>
#include <map>

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
  return p;
}

struct pending_wb_t {
  unsigned rd = 0;
  bool rd_fp = false;
  uint64_t value = 0, pc = 0, cycle = 0;
  uint32_t insn = 0;
};

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

struct hart_state_t {
  processor_t* p = nullptr;
  uint32_t id = 0;
  std::deque<tr_rec_t> rtl_hist;
  std::deque<tr_wb_t> wb_hist;
  std::deque<spike_step_t> spike_hist;
  std::map<uint32_t, pending_wb_t> pending;
  uint64_t steps = 0;
};

}  // namespace

class lockstep_impl_t {
 public:
  lockstep_impl_t(const lockstep_cfg_t& cfg, const mem_t& image, const elf_t* elf)
      : cfg_(cfg), env_(new spike_env_t(platform_of(cfg), image)), elf_(elf) {
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

    // An SC the RTL failed: make Spike fail it too (§3.4). A successful SC always stores, so the
    // missing store is the sign; with rd = x0 it is the only one.
    if (sc && !r.mem_st) h.p->get_mmu()->yield_load_reservation();
    env_->amo_step = amo && !lr && !sc;
    const uint64_t rs2 = h.p->get_state()->XPR[(insn >> 20) & 31];  // before an AMO overwrites it
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
        h.pending[r.wb_tag] = pending_wb_t{r.rd, r.rd_fp, st.rd_value, r.pc, r.cycle, r.insn};
      } else if (r.rd_value != st.rd_value) {
        if (!(amo && !lr && !sc ? ext_amo(h, r, st, rs2) : ext_load(h, r, st))) {
          done(false);
          return mismatch(&h, &r, strfmt("%c%u value: RTL %016llx, Spike %016llx%s", r.rd_fp ? 'f' : 'x', r.rd,
                                         (unsigned long long)r.rd_value, (unsigned long long)st.rd_value,
                                         ext_.empty() ? "" : strfmt(" (%zu external writes in a window)", ext_.size()).c_str()));
        }
        st.rd_value = r.rd_value;
        st.adopted = true;
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
      if (r.mem_vaddr != st.st_addr || bytes != st.st_size || (r.mem_wdata & m) != (st.st_val & m)) {
        done(false);
        return mismatch(&h, &r, strfmt("store: RTL %u bytes %016llx at %016llx, Spike %u bytes %016llx at %016llx", bytes,
                                       (unsigned long long)(r.mem_wdata & m), (unsigned long long)r.mem_vaddr, st.st_size,
                                       (unsigned long long)(st.st_val & size_mask(st.st_size == 8 ? 3 : st.st_size == 4 ? 2 : st.st_size == 2 ? 1 : 0)),
                                       (unsigned long long)st.st_addr));
      }
    }
    if (r.mem_st && !ext_.empty()) ext_store(h, r, st);
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
    uint8_t got[8];
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
    if (p.value != w.value)
      return mismatch(&h, nullptr, strfmt("deferred %c%u value (tag %u, instruction at %016llx): RTL %016llx, Spike %016llx",
                                          w.rd_fp ? 'f' : 'x', w.rd, w.wb_tag, (unsigned long long)p.pc,
                                          (unsigned long long)w.value, (unsigned long long)p.value));
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
size_t lockstep_t::ext_pending() const { return impl_->ext_pending(); }
bool lockstep_t::compares_value(const tr_rec_t& r) {
  return r.kind == TR_RETIRE && r.rd_we && !r.rd_deferred && !adopts_value(r);
}

}  // namespace tg
