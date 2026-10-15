// Spike lockstep checker: docs/spec/verification.md §3.
#include "lockstep.h"

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
        if (sbits != r.insn)
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
      if (r.mmio_ld || r.nondet || csr_adopt) {
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
        done(false);
        return mismatch(&h, &r, strfmt("%c%u value: RTL %016llx, Spike %016llx", r.rd_fp ? 'f' : 'x', r.rd,
                                       (unsigned long long)r.rd_value, (unsigned long long)st.rd_value));
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

}  // namespace tg
