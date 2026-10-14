// tg_replay: a second Spike plays the core, producing tr_rec_t / tr_wb_t records that feed the
// lockstep checker exactly as the RTL's would, with the legal perturbations a real core makes and,
// on request, one injected fault the checker must catch (docs/spec/verification.md §3.8).
#include <cinttypes>
#include <cstring>
#include <deque>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "common.h"
#include "elfload.h"
#include "htif.h"
#include "lockstep.h"
#include "spike_env.h"

using namespace tg;

namespace {

struct opts_t {
  std::string elf;
  std::string isa = "rv64imafdc_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs";
  std::string priv = "MSU";
  unsigned harts = 1, width = 2, wb_ports = 2, tags = 16, history = 32, pmp = 16, mtime_div = 1;
  uint64_t ids[3] = {0, 0, 0};  // mvendorid, marchid, mimpid as the core reports them (Spike's marchid is 5)
  uint64_t seed = 1, max_steps = 20000000;
  unsigned defer = 0, defer_max = 200, irq = 0;
  bool defer_all = false, nondet = false, quiet = false;
  unsigned sc_fail = 0;  // percent of SCs the replaying Spike fails (as a core may, §3.4)
  std::string inject;
  int64_t inject_at = -1;
  std::vector<uint64_t> tohost_va;
  std::string log;
};

[[noreturn]] void usage() {
  fprintf(stderr,
          "usage: tg_replay [options] program.elf\n"
          "  --isa=STR --priv=STR --harts=N --pmp=N --seed=N --max-steps=N --history=N --tohost-va=ADDR --quiet --log=FILE\n"
          "  --mtime-div=N    the CLINT's mtime advances once per N retired instructions (default 1)\n"
          "  --width=N        records per cycle, 1..N at random (default 2)\n"
          "  --defer=PCT      defer the results of loads, DIV/REM, FDIV/FSQRT (percent); --defer-all: any result\n"
          "  --defer-max=N    deliver deferred writebacks 1..N records later (default 200)\n"
          "  --tags=N         wb_tag space (default 16); --wb-ports=N writebacks per cycle (default 2)\n"
          "  --nondet         perturb the values of non-deterministic CSR reads\n"
          "  --sc-fail=PCT    fail this share of SCs (the replaying Spike drops its reservation)\n"
          "  --mvendorid=N --marchid=N --mimpid=N   the core's ID CSR values (default 0, core-pipeline.md §9)\n"
          "  --irq=PERMILLE   random interrupts at boundaries where one is enabled\n"
          "  --inject=KIND    inject one fault the checker must report; --inject-at=N: at record N or later\n"
          "                   KIND: pc insn priv rd value nowrite store-data store-addr nostore cause tval\n"
          "                         trap-as-retire retire-as-trap wb-value wb-missing wb-extra tag-reuse\n"
          "                         nondet-bad skip irq-cause\n");
  exit(EXIT_HARNESS);
}

uint64_t num(const std::string& s, const char* what) {
  char* end = nullptr;
  uint64_t v = strtoull(s.c_str(), &end, 0);
  if (s.empty() || *end) fatal("bad number for %s: '%s'", what, s.c_str());
  return v;
}

opts_t parse(int argc, char** argv) {
  opts_t o;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a.rfind("--", 0) != 0) { o.elf = a; continue; }
    std::string k = a.substr(2), v;
    size_t eq = k.find('=');
    if (eq != std::string::npos) { v = k.substr(eq + 1); k = k.substr(0, eq); }
    if (k == "isa") o.isa = v;
    else if (k == "priv") o.priv = v;
    else if (k == "harts") o.harts = unsigned(num(v, "--harts"));
    else if (k == "width") o.width = std::max(1u, unsigned(num(v, "--width")));
    else if (k == "wb-ports") o.wb_ports = std::max(1u, unsigned(num(v, "--wb-ports")));
    else if (k == "tags") o.tags = std::max(1u, unsigned(num(v, "--tags")));
    else if (k == "history") o.history = unsigned(num(v, "--history"));
    else if (k == "pmp") o.pmp = unsigned(num(v, "--pmp"));
    else if (k == "mtime-div") o.mtime_div = std::max(1u, unsigned(num(v, "--mtime-div")));
    else if (k == "seed") o.seed = num(v, "--seed");
    else if (k == "max-steps") o.max_steps = num(v, "--max-steps");
    else if (k == "defer") o.defer = unsigned(num(v, "--defer"));
    else if (k == "defer-all") o.defer_all = true;
    else if (k == "defer-max") o.defer_max = std::max(1u, unsigned(num(v, "--defer-max")));
    else if (k == "nondet") o.nondet = true;
    else if (k == "sc-fail") o.sc_fail = unsigned(num(v, "--sc-fail"));
    else if (k == "mvendorid") o.ids[0] = num(v, "--mvendorid");
    else if (k == "marchid") o.ids[1] = num(v, "--marchid");
    else if (k == "mimpid") o.ids[2] = num(v, "--mimpid");
    else if (k == "irq") o.irq = unsigned(num(v, "--irq"));
    else if (k == "inject") o.inject = v;
    else if (k == "inject-at") o.inject_at = int64_t(num(v, "--inject-at"));
    else if (k == "tohost-va") o.tohost_va.push_back(num(v, "--tohost-va"));
    else if (k == "quiet") o.quiet = true;
    else if (k == "log") o.log = v;
    else usage();
  }
  if (o.elf.empty()) usage();
  return o;
}

// The phrase the checker's report must contain for each injected fault.
const char* expected_phrase(const std::string& k) {
  static const std::pair<const char*, const char*> t[] = {
      {"pc", "pc:"}, {"skip", "pc:"}, {"insn", "instruction:"}, {"priv", "privilege:"}, {"rd", "destination:"},
      {"nowrite", "destination:"}, {"value", "value:"}, {"store-data", "store:"}, {"store-addr", "store:"},
      {"nostore", "store:"}, {"cause", "trap cause:"}, {"tval", "trap tval:"},
      {"trap-as-retire", "Spike trapped"}, {"retire-as-trap", "Spike retired"}, {"wb-value", "deferred"},
      {"wb-missing", "never arrived|reused while"}, {"wb-extra", "not pending"}, {"tag-reuse", "reused"},
      {"nondet-bad", "nondet on an instruction"}, {"irq-cause", "interrupt cause:|not enabled in Spike"},
  };
  for (auto& [kind, phrase] : t)
    if (k == kind) return phrase;
  return nullptr;
}

// Results the RTL may deliver late (early retirement, plan §4.5).
bool deferrable(uint32_t insn, bool rvc) {
  if (is_load_insn(insn, rvc)) return true;
  if (rvc) return false;
  unsigned op = insn & 0x7f, f3 = (insn >> 12) & 7, f7 = insn >> 25;
  if ((op == 0x33 || op == 0x3b) && f7 == 1 && f3 >= 4) return true;   // DIV[U][W], REM[U][W]
  if (op == 0x53 && ((f7 >> 2) == 0x03 || (f7 >> 2) == 0x0b)) return true;  // FDIV, FSQRT
  return false;
}

unsigned log2_size(unsigned bytes) { return bytes >= 8 ? 3 : bytes >= 4 ? 2 : bytes >= 2 ? 1 : 0; }

struct pending_t {
  uint64_t due;   // record count at which it may be delivered
  tr_wb_t wb;
};

}  // namespace

int main(int argc, char** argv) {
  opts_t o = parse(argc, argv);
  rng_t rng(o.seed * 0x9e3779b97f4a7c15ull + 7);
  const char* want = nullptr;
  if (!o.inject.empty() && !(want = expected_phrase(o.inject))) fatal("unknown --inject kind '%s'", o.inject.c_str());
  if (!o.inject.empty() && o.inject_at < 0) o.inject_at = int64_t(rng.below(2000));

  mem_t mem;
  elf_t elf;
  elf.load(o.elf, mem);
  tohost_watch_t tohost;
  tohost.va.insert(o.tohost_va.begin(), o.tohost_va.end());
  if (elf.has("tohost")) tohost.va.insert(elf.sym("tohost"));

  spike_platform_t plat;
  plat.isa = o.isa;
  plat.priv = o.priv;
  plat.pmp_regions = o.pmp;
  plat.hartids.clear();
  for (unsigned i = 0; i < o.harts; i++) plat.hartids.push_back(i);
  plat.dev_regions = {{0x02000000ull, 0x10000}, {0x0C000000ull, 0x4000000}, {0x10000000ull, 0x1000},
                      {0x10001000ull, 0x1000},  {0x10010000ull, 0x4000},    {0x11000000ull, 0x10000}};
  spike_env_t dut(plat, mem);
  std::string console;

  // The platform of tg_vsim, for the replaying Spike (verification.md §2.4): the UART, a CLINT whose
  // mtime advances once per --mtime-div retired instructions, and the simple interrupt generator.
  // Their levels drive the replaying Spike's mip; the interrupts it takes become TR_IRQ records.
  const uint64_t CLINT = 0x02000000ull, SIG = 0x0C000004ull, UART = 0x10000000ull;
  std::vector<uint64_t> mtimecmp(o.harts, ~0ull);
  std::vector<uint32_t> msip(o.harts, 0);
  uint64_t mtime = 0, steps_total = 0;
  uint32_t sig_lines = 0;
  auto rd_bytes = [](uint64_t v, uint64_t off, size_t len, uint8_t* b) {
    for (size_t i = 0; i < len; i++) b[i] = uint8_t(v >> (8 * ((off + i) & 7)));
  };
  dut.dev_load = [&](uint64_t pa, size_t len, uint8_t* b) {
    if (pa <= UART + 5 && pa + len > UART + 5) b[UART + 5 - pa] = 0x60;  // UART LSR: THR empty
    if (pa >= CLINT && pa < CLINT + 0x10000) {
      uint64_t off = pa - CLINT;
      if (off < 0x4000 && off / 4 < o.harts) rd_bytes(msip[off / 4], off & 3, len, b);
      else if (off >= 0x4000 && off < 0xbff8 && (off - 0x4000) / 8 < o.harts) rd_bytes(mtimecmp[(off - 0x4000) / 8], off & 7, len, b);
      else if (off >= 0xbff8 && off < 0xc000) rd_bytes(mtime, off & 7, len, b);
    }
  };
  dut.dev_store = [&](uint64_t pa, size_t len, const uint8_t* b) {
    uint64_t v = 0;
    for (size_t i = 0; i < len && i < 8; i++) v |= uint64_t(b[i]) << (8 * i);
    if (pa == UART && len >= 1) {
      console.push_back(char(b[0]));
      fputc(b[0], stdout);
    } else if (pa >= CLINT && pa < CLINT + 0x10000) {
      uint64_t off = pa - CLINT;
      auto merge = [&](uint64_t& reg) {
        unsigned sh = unsigned(off & 7) * 8;
        uint64_t m = (len >= 8 ? ~0ull : ((1ull << (8 * len)) - 1)) << sh;
        reg = (reg & ~m) | ((v << sh) & m);
      };
      if (off < 0x4000 && off / 4 < o.harts) msip[off / 4] = v & 1;
      else if (off >= 0x4000 && off < 0xbff8 && (off - 0x4000) / 8 < o.harts) merge(mtimecmp[(off - 0x4000) / 8]);
      else if (off >= 0xbff8 && off < 0xc000) merge(mtime);
    } else if (pa == SIG && len == 4) {
      if (v & 0x80000000u) sig_lines |= uint32_t(v) & 0x7fffffffu;
      else sig_lines &= ~uint32_t(v);
    }
  };
  auto platform_levels = [&](unsigned h) -> reg_t {
    reg_t m = 0;
    if (mtime >= mtimecmp[h]) m |= MIP_MTIP;
    if (msip[h]) m |= MIP_MSIP;
    if (sig_lines >> 11 & 1) m |= MIP_MEIP;
    if (sig_lines >> 9 & 1) m |= MIP_SEIP;
    if (sig_lines >> 1 & 1) m |= MIP_SSIP;
    return m;
  };
  // MTIP, MSIP and MEIP are read-only in mip and follow the platform's levels. Software may also
  // write SEIP and SSIP, so the SIG sets or clears those only when its line changes (as Sail's SIG
  // and Spike's own PLIC do).
  const reg_t PLATFORM_MIP = MIP_MTIP | MIP_MSIP | MIP_MEIP;
  const reg_t SIG_EDGE_MIP = MIP_SEIP | MIP_SSIP;
  std::vector<reg_t> sig_edge_last(o.harts, 0);

  lockstep_cfg_t lc;
  lc.isa = o.isa;
  lc.priv = o.priv;
  lc.pmp_regions = o.pmp;
  lc.hartids = plat.hartids;
  lc.history = o.history;
  lc.dev_regions = plat.dev_regions;
  lockstep_t ls(lc, mem, &elf);

  // Free wb_tags per hart and writebacks waiting for delivery.
  std::vector<std::vector<uint32_t>> free_tags(o.harts);
  for (auto& f : free_tags)
    for (uint32_t t = 0; t < o.tags; t++) f.push_back(t);
  std::vector<std::set<uint32_t>> live_tags(o.harts);
  std::deque<pending_t> pend;

  uint64_t nrec = 0, cycle = 0, instret = 0;
  bool injected = false, exit_seen = false, htif_console = false;
  int code = 0;
  std::string why;
  int status = EXIT_PASS;
  bool skip_next = false;

  auto make_record = [&](unsigned h) -> tr_rec_t {
    processor_t* p = dut.procs[h];
    state_t* s = p->get_state();
    tr_rec_t r;
    r.cycle = cycle;
    r.hart = plat.hartids[h];
    r.priv = uint8_t(s->prv);
    r.pc = s->pc;
    uint32_t bits = 0;
    spike_fetch(p, s->pc, bits);

    // Platform interrupt levels; the SIG's SEIP and SSIP only on a change.
    if (++steps_total % o.mtime_div == 0) mtime++;
    if (s->time) s->time->sync(mtime);  // the time CSR follows the CLINT, as with Spike's own CLINT
    reg_t lv = platform_levels(h);
    s->mip->backdoor_write_with_mask(PLATFORM_MIP, lv);
    if (reg_t changed = (lv & SIG_EDGE_MIP) ^ sig_edge_last[h]) {
      s->mip->backdoor_write_with_mask(changed, lv);
      sig_edge_last[h] = lv & SIG_EDGE_MIP;
    }

    // A random interrupt, if one is enabled here.
    reg_t forced = 0;
    if (o.irq && rng.permille(o.irq)) {
      static const unsigned causes[] = {IRQ_M_SOFT, IRQ_M_TIMER, IRQ_M_EXT, IRQ_S_SOFT, IRQ_S_TIMER, IRQ_S_EXT};
      reg_t mie = s->mie->read();
      std::vector<unsigned> c;
      for (unsigned x : causes)
        if ((mie >> x) & 1) c.push_back(x);
      if (!c.empty()) {
        forced = reg_t(1) << c[rng.below(c.size())];
        if (s->mip->read() & forced) forced = 0;
        else s->mip->backdoor_write_with_mask(forced, forced);
      }
    }
    // An SC the core fails (lost reservation, §3.4): the checker must adopt the failure.
    if (o.sc_fail && (bits & 3) == 3 && is_amo_insn(bits) && (bits >> 27) == 3 && rng.percent(o.sc_fail))
      p->get_mmu()->yield_load_reservation();
    // As the core does (interfaces.md §2.4), an AMO outside main memory faults (LR/SC already do).
    const unsigned f5 = bits >> 27;
    dut.amo_step = (bits & 3) == 3 && is_amo_insn(bits) && f5 != 2 && f5 != 3;
    spike_step_t st = spike_step(p, bits);
    dut.amo_step = false;
    if (forced) s->mip->backdoor_write_with_mask(forced, platform_levels(h) & forced & PLATFORM_MIP);

    if (st.trapped && st.interrupt) {
      r.kind = TR_IRQ;
      r.cause = st.cause;
      return r;
    }
    r.insn = bits;
    r.rvc = (bits & 3) != 3;
    if (st.trapped) {
      r.kind = TR_TRAP;
      r.cause = st.cause;
      r.tval = st.tval;
      return r;
    }
    r.kind = TR_RETIRE;
    if (st.nwr) {
      r.rd_we = true;
      r.rd = uint8_t(st.rd);
      r.rd_fp = st.rd_fp;
      r.rd_value = st.rd_value;
    }
    if (st.nst) {
      r.mem_st = true;
      r.mem_vaddr = st.st_addr;
      r.mem_wdata = st.st_val;
      r.mem_size = uint8_t(log2_size(st.st_size));
    }
    // Device loads: with translation off the load address is physical (enough for the programs
    // replay runs; the RTL knows the physical address itself).
    reg_t eff = s->prv;  // the privilege of data accesses (MPRV)
    if (eff == PRV_M && (s->mstatus->read() & MSTATUS_MPRV)) eff = get_field(s->mstatus->read(), MSTATUS_MPP);
    bool bare = eff == PRV_M || !p->extension_enabled('S') || (p->get_csr(CSR_SATP) >> 60) == 0;
    if (r.rd_we && is_load_insn(bits, r.rvc) && st.nld && bare && !dut.in_dram(st.ld_addr)) r.mmio_ld = true;
    if (r.rd_we && is_csr_insn(bits) && adopted_csr(bits >> 20)) {
      r.nondet = true;
      unsigned csr = bits >> 20;
      if (csr >= 0xF11 && csr <= 0xF13) {  // the replaying Spike stands for the core: its ID values
        r.rd_value = o.ids[csr - 0xF11];
        s->XPR.write(r.rd, r.rd_value);
      } else if (o.nondet) {
        r.rd_value ^= rng.next() & 0xffff;
        if (r.rd_fp) { freg_t v; v.v[0] = r.rd_value; v.v[1] = ~0ull; s->FPR.write(r.rd, v); }
        else s->XPR.write(r.rd, r.rd_value);
      }
    }
    if (r.rd_we && !r.mmio_ld && !r.nondet && o.defer && (o.defer_all || deferrable(bits, r.rvc)) &&
        rng.percent(o.defer) && !free_tags[h].empty()) {
      size_t i = rng.below(free_tags[h].size());
      uint32_t tag = free_tags[h][i];
      free_tags[h].erase(free_tags[h].begin() + long(i));
      live_tags[h].insert(tag);
      r.rd_deferred = true;
      r.wb_tag = tag;
      tr_wb_t w;
      w.hart = r.hart;
      w.wb_tag = tag;
      w.rd_fp = r.rd_fp;
      w.rd = r.rd;
      w.value = r.rd_value;
      pend.push_back({nrec + 1 + rng.below(o.defer_max), w});
    }
    return r;
  };

  // Applies the injected fault to the first eligible record (or writeback) at or after inject_at.
  auto inject_rec = [&](tr_rec_t& r) -> bool {
    const std::string& k = o.inject;
    bool plain_rd = r.kind == TR_RETIRE && r.rd_we && !r.rd_deferred && !r.mmio_ld && !r.nondet;
    if (k == "pc" && r.kind == TR_RETIRE) { r.pc += 4; return true; }
    if (k == "insn" && r.kind == TR_RETIRE) { r.insn ^= r.rvc ? 0x4 : 0x80; return true; }
    if (k == "priv" && r.kind == TR_RETIRE) { r.priv = r.priv == 3 ? 0 : 3; return true; }
    if (k == "rd" && plain_rd) { r.rd = r.rd == 31 ? 30 : r.rd + 1; return true; }
    if (k == "value" && plain_rd) { r.rd_value ^= 1; return true; }
    if (k == "nowrite" && plain_rd) { r.rd_we = false; return true; }
    if (k == "store-data" && r.mem_st) { r.mem_wdata ^= 1; return true; }
    if (k == "store-addr" && r.mem_st) { r.mem_vaddr ^= 8; return true; }
    if (k == "nostore" && r.mem_st) { r.mem_st = false; return true; }
    if (k == "cause" && r.kind == TR_TRAP) { r.cause ^= 1; return true; }
    if (k == "tval" && r.kind == TR_TRAP) { r.tval ^= 4; return true; }
    if (k == "trap-as-retire" && r.kind == TR_TRAP) { r.kind = TR_RETIRE; return true; }
    if (k == "retire-as-trap" && r.kind == TR_RETIRE && !r.rd_deferred) { r.kind = TR_TRAP; r.cause = 2; r.tval = r.insn; return true; }
    if (k == "nondet-bad" && plain_rd && !is_csr_insn(r.insn)) { r.nondet = true; return true; }
    if (k == "irq-cause" && r.kind == TR_IRQ) { r.cause ^= 2; return true; }
    if (k == "tag-reuse" && r.rd_deferred) {
      unsigned h = 0;
      while (plat.hartids[h] != r.hart) h++;
      for (uint32_t t : live_tags[h])
        if (t != r.wb_tag) { r.wb_tag = t; return true; }
    }
    return false;
  };

  FILE* logf = o.log.empty() ? nullptr : fopen(o.log.c_str(), "w");
  auto dis = [&](uint32_t i) { return ls.disasm(i); };
  std::vector<tr_rec_t> recs;
  std::vector<tr_wb_t> wbs;
  while (status == EXIT_PASS) {
    recs.clear();
    wbs.clear();
    unsigned n = 1 + unsigned(rng.below(o.width));
    for (unsigned i = 0; i < n && !exit_seen; i++) {
      unsigned h = unsigned(rng.below(o.harts));
      tr_rec_t r = make_record(h);
      nrec++;
      if (r.kind == TR_RETIRE) instret++;
      uint64_t v;
      if (r.kind == TR_RETIRE && r.mem_st && tohost.store(r.mem_vaddr, r.mem_wdata, r.mem_size, v)) {
        if (tohost_watch_t::is_putchar(v)) {  // HTIF console
          console.push_back(char(v & 0xff));
          htif_console = true;
          fputc(int(v & 0xff), stdout);
        } else if (tohost_watch_t::is_exit(v) && h == 0) {
          exit_seen = true;
          code = int(v >> 1);
        }
      }
      if (!o.inject.empty() && !injected && int64_t(nrec) >= o.inject_at) {
        if (o.inject == "skip" && r.kind == TR_RETIRE) { injected = true; skip_next = true; }
        else if (o.inject != "wb-value" && o.inject != "wb-missing" && o.inject != "wb-extra" && inject_rec(r)) injected = true;
      }
      if (skip_next) { skip_next = false; continue; }
      recs.push_back(r);
    }
    // Deliver due writebacks, at most wb_ports per cycle, in random order among the due ones.
    std::vector<size_t> due;
    for (size_t i = 0; i < pend.size(); i++)
      if (pend[i].due <= nrec || exit_seen) due.push_back(i);
    std::vector<size_t> pick;
    while (!due.empty() && pick.size() < o.wb_ports) {
      size_t j = rng.below(due.size());
      pick.push_back(due[j]);
      due.erase(due.begin() + long(j));
    }
    std::sort(pick.rbegin(), pick.rend());
    for (size_t i : pick) {
      tr_wb_t w = pend[i].wb;
      pend.erase(pend.begin() + long(i));
      w.cycle = cycle;
      unsigned h = 0;
      while (plat.hartids[h] != w.hart) h++;
      live_tags[h].erase(w.wb_tag);
      free_tags[h].push_back(w.wb_tag);
      if (!o.inject.empty() && !injected && int64_t(nrec) >= o.inject_at) {
        if (o.inject == "wb-value") { w.value ^= 1; injected = true; }
        else if (o.inject == "wb-missing") { injected = true; continue; }
      }
      wbs.push_back(w);
    }
    if (o.inject == "wb-extra" && !injected && int64_t(nrec) >= o.inject_at) {
      std::set<uint32_t> used(live_tags[0].begin(), live_tags[0].end());
      for (uint32_t t = 0; t < 4096; t++)
        if (!used.count(t)) {
          tr_wb_t w;
          w.cycle = cycle;
          w.hart = plat.hartids[0];
          w.wb_tag = t;
          w.rd = 1;
          w.value = 0x1234;
          wbs.push_back(w);
          injected = true;
          break;
        }
    }
    if (logf) {
      for (auto& r : recs) fprintf(logf, "%s\n", format_rec(r, dis).c_str());
      for (auto& w : wbs) fprintf(logf, "%s\n", format_wb(w).c_str());
    }
    if (!ls.cycle(recs, wbs)) { status = EXIT_MISMATCH; why = ls.error(); break; }
    cycle++;
    if (exit_seen && pend.empty()) {
      if (!ls.finish()) { status = EXIT_MISMATCH; why = ls.error(); }
      else if (code) { status = EXIT_PROGRAM_FAIL; why = strfmt("program exit code %d", code); }
      break;
    }
    if (htif_console && !exit_seen && console.size() > 4096) { status = EXIT_PROGRAM_FAIL; why = "HTIF console: " + console; break; }
    if (nrec >= o.max_steps) {
      status = htif_console ? EXIT_PROGRAM_FAIL : EXIT_TIMEOUT;
      why = htif_console ? "the program printed through tohost and waits for the host: " + console : "step limit reached";
      break;
    }
  }
  fflush(stdout);
  if (logf) fclose(logf);

  if (!o.inject.empty()) {
    // Fault-injection mode: pass only if the checker reported the injected fault. A program with
    // no record the fault applies to reports NA (exit 0).
    if (!injected) {
      printf("TG-REPLAY inject=%s status=NA detected=0 records=%llu\n", o.inject.c_str(), (unsigned long long)nrec);
      return EXIT_PASS;
    }
    bool phrase = false;
    for (size_t b = 0, e; !phrase; b = e + 1) {
      e = std::string(want).find('|', b);
      phrase = why.find(std::string(want).substr(b, e == std::string::npos ? e : e - b)) != std::string::npos;
      if (e == std::string::npos) break;
    }
    bool ok = status == EXIT_MISMATCH && phrase;
    if (!ok) {
      if (status == EXIT_MISMATCH) ls.report(stderr);
      fprintf(stderr, "tg_replay: inject=%s at record %lld: NOT DETECTED as expected (status %s: %s)\n",
              o.inject.c_str(), (long long)o.inject_at, exit_status_name(status), why.c_str());
    }
    printf("TG-REPLAY inject=%s status=%s detected=%d records=%llu\n", o.inject.c_str(), ok ? "PASS" : "FAIL",
           ok ? 1 : 0, (unsigned long long)nrec);
    return ok ? EXIT_PASS : EXIT_MISMATCH;
  }
  if (status == EXIT_MISMATCH) ls.report(stderr);
  if (!why.empty()) fprintf(stderr, "tg_replay: %s\n", why.c_str());
  printf("TG-REPLAY status=%s code=%d records=%llu instret=%llu cycles=%llu\n", exit_status_name(status), code,
         (unsigned long long)nrec, (unsigned long long)instret, (unsigned long long)cycle);
  return status;
}
