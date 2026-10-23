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

// The core's PMP entries in this tree's tg_core_pkg (DR-167; sim/Makefile's tg_pmp_default.h), so the
// replaying Spike models the core
#ifndef TG_DEFAULT_PMP
#define TG_DEFAULT_PMP 16
#endif

namespace {

struct opts_t {
  std::string elf;
  std::string isa = "rv64imafdc_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs";
  std::string priv = "MSU";
  unsigned harts = 1, width = 2, wb_ports = 2, tags = 16, history = 32, pmp = TG_DEFAULT_PMP, mtime_div = 1;
  uint64_t ids[3] = {0, 0, 0};  // mvendorid, marchid, mimpid as the core reports them (Spike's marchid is 5)
  uint64_t seed = 1, max_steps = 20000000;
  unsigned defer = 0, defer_max = 200, irq = 0;
  bool defer_all = false, nondet = false, quiet = false;
  unsigned sc_fail = 0;  // percent of SCs the replaying Spike fails (as a core may, §3.4)
  unsigned ext = 0, ext_delay = 64, ext_window = 512;  // external writes (§3.10): per mille of cycles, delay
  unsigned sb = 0, sb_max = 100;  // several harts (§3.7): plain stores that wait in a store buffer (percent), cycles
  unsigned atomic_early = 0;      // several harts: an atomic's record up to this many cycles after it performs
  bool mtgsmt = false;            // the cores have mtgsmt (0x7C0), shared by harts 2k and 2k + 1
  std::string inject;
  int64_t inject_at = -1;
  std::vector<uint64_t> tohost_va;
  std::string log;
};

[[noreturn]] void usage() {
  fprintf(stderr,
          "usage: tg_replay [options] program.elf\n"
          "  --isa=STR --priv=STR --harts=N --pmp=N --seed=N --max-steps=N --history=N --tohost-va=ADDR --quiet --log=FILE\n"
          "  --pmp=N          Spike's PMP regions (default %d: the PMP entries of this tree's core, DR-167)\n"
          "  --mtime-div=N    the CLINT's mtime advances once per N retired instructions (default 1)\n"
          "  --width=N        records per cycle, 1..N at random (default 2)\n"
          "  --defer=PCT      defer the results of loads, DIV/REM, FDIV/FSQRT (percent); --defer-all: any result\n"
          "  --defer-max=N    deliver deferred writebacks 1..N records later (default 200)\n"
          "  --tags=N         wb_tag space (default 16); --wb-ports=N writebacks per cycle (default 2)\n"
          "  --nondet         perturb the values of non-deterministic CSR reads\n"
          "  --sc-fail=PCT    fail this share of SCs (the replaying Spike drops its reservation)\n"
          "  --mvendorid=N --marchid=N --mimpid=N   the core's ID CSR values (default 0, core-pipeline.md §9)\n"
          "  --irq=PERMILLE   random interrupts at boundaries where one is enabled\n"
          "  --ext=PERMILLE   external writes (another master's DMA, §3.10) into bytes the program loads; the\n"
          "                   replaying Spike sees each 0..N cycles after the checker hears of it (--ext-delay=N,\n"
          "                   default 64); --ext-window=N the checker's window in records (default 512)\n"
          "  --mtgsmt         the cores have M7's mtgsmt CSR (0x7C0), one per hart pair (core-pipeline.md §9)\n"
          "  --sb=PCT         several harts: this share of plain stores to main memory waits in its hart's store\n"
          "                   buffer and reaches memory 1..N cycles after its record (--sb-max=N, default 100);\n"
          "                   the hart's later stores queue behind it, its loads see them, and its AMOs, LR/SCs\n"
          "                   and fences wait until they have all reached memory\n"
          "  --atomic-early=N several harts: an AMO or SC's record carries a cycle 0..N after it performed (at\n"
          "                   most %llu, the checker's bound), its hart sitting out until then; the checker gets\n"
          "                   the records in cycle order, as tanager-lockstep's (verification.md §3.7)\n"
          "  --inject=KIND    inject one fault the checker must report; --inject-at=N: at record N or later\n"
          "                   KIND: pc insn priv rd value nowrite store-data store-addr nostore cause tval\n"
          "                         trap-as-retire retire-as-trap wb-value wb-missing wb-extra tag-reuse\n"
          "                         nondet-bad skip irq-cause ld-addr noload ext-unannounced ext-stale (with --ext)\n"
          "                         sb-reorder (two stores of one hart reach memory in the wrong order) and\n"
          "                         sb-late (a store waits past every window) with --sb; atomic-late (an\n"
          "                         atomic's record past the checker's bound) with --atomic-early\n",
          TG_DEFAULT_PMP, (unsigned long long)ATOMIC_EARLY);
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
    else if (k == "ext") o.ext = unsigned(num(v, "--ext"));
    else if (k == "ext-delay") o.ext_delay = unsigned(num(v, "--ext-delay"));
    else if (k == "ext-window") o.ext_window = std::max(1u, unsigned(num(v, "--ext-window")));
    else if (k == "sb") o.sb = unsigned(num(v, "--sb"));
    else if (k == "sb-max") o.sb_max = std::max(1u, unsigned(num(v, "--sb-max")));
    else if (k == "atomic-early") o.atomic_early = unsigned(num(v, "--atomic-early"));
    else if (k == "mtgsmt") o.mtgsmt = true;
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
      {"ext-unannounced", "value:"}, {"ext-stale", "value:"}, {"ld-addr", "load address:"},
      {"noload", "load address:"}, {"sb-reorder", "value:|store:"}, {"sb-late", "value:|store:"},
      {"atomic-late", "value:|store:"},
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

// A plain store's (integer or FP, RV64GC) virtual address and size, from the hart's registers before it executes
bool plain_store(processor_t* p, uint32_t bits, uint64_t& va, unsigned& n) {
  const auto x = [&](unsigned r) { return uint64_t(p->get_state()->XPR[r]); };
  if ((bits & 3) == 3) {
    const unsigned op = bits & 0x7f, f3 = (bits >> 12) & 7;
    if (!(op == 0x23 && f3 < 4) && !(op == 0x27 && (f3 == 2 || f3 == 3))) return false;
    const uint64_t raw = ((bits >> 25) << 5) | ((bits >> 7) & 31);
    va = x((bits >> 15) & 31) + raw - (raw & 0x800 ? 0x1000 : 0);
    n = 1u << f3;
    return true;
  }
  const unsigned q = bits & 3, f3 = (bits >> 13) & 7;
  if (f3 < 5 || (q != 0 && q != 2)) return false;
  n = f3 == 6 ? 4 : 8;  // C.FSD[SP], C.SW[SP], C.SD[SP]
  if (q == 0) {
    const uint64_t off = ((bits >> 10) & 7) << 3 | (f3 == 6 ? ((bits >> 6) & 1) << 2 | ((bits >> 5) & 1) << 6
                                                             : ((bits >> 5) & 3) << 6);
    va = x(((bits >> 7) & 7) + 8) + off;
  } else {
    const uint64_t off = f3 == 6 ? ((bits >> 9) & 15) << 2 | ((bits >> 7) & 3) << 6
                                 : ((bits >> 10) & 7) << 3 | ((bits >> 7) & 7) << 6;
    va = x(2) + off;
  }
  return true;
}

// Whether an instruction may read register number r (integer or FP): every field a source can be in, so a few
// it does not read count too
bool may_read(uint32_t bits, unsigned r) {
  if ((bits & 3) == 3) return r == ((bits >> 15) & 31) || r == ((bits >> 20) & 31) || r == (bits >> 27);
  return r == ((bits >> 7) & 31) || r == ((bits >> 2) & 31) || r == ((bits >> 7) & 7) + 8 || r == ((bits >> 2) & 7) + 8 ||
         r == 2;
}

// An instruction that orders the hart's memory accesses: an AMO, LR or SC, FENCE or FENCE.I
bool orders_memory(uint32_t bits) {
  return (bits & 3) == 3 && (is_amo_insn(bits) || (bits & 0x7f) == 0x0f);
}

struct pending_t {
  uint64_t due;   // record count at which it may be delivered
  tr_wb_t wb;
  uint64_t cycle = 0;  // its record's
};

}  // namespace

// Whether a hart's data addresses are physical: M-mode without MPRV, or satp Bare.
static bool bare_translation(processor_t* p) {
  state_t* s = p->get_state();
  if (s->prv == PRV_M && !(s->mstatus->read() & MSTATUS_MPRV)) return true;
  return p->extension_enabled('S') ? (p->get_csr(CSR_SATP) >> 60) == 0 : true;
}

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
  plat.mtgsmt = o.mtgsmt;
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
  lc.ext_window = o.ext_window;
  lc.mtgsmt = o.mtgsmt;
  lockstep_t ls(lc, mem, &elf);
  if (o.ext && o.defer) fatal("--ext with --defer: a deferred load's value is not checked against external writes");
  if (o.inject.rfind("ext-", 0) == 0 && !o.ext) fatal("--inject=%s needs --ext", o.inject.c_str());
  if ((o.sb || o.atomic_early) && (o.ext || o.harts < 2)) fatal("--sb and --atomic-early need several harts and no --ext");
  if (o.atomic_early > ATOMIC_EARLY)
    fatal("--atomic-early=%u is past the checker's bound (%llu); --inject=atomic-late goes past it", o.atomic_early,
          (unsigned long long)ATOMIC_EARLY);
  if (o.inject.rfind("sb-", 0) == 0 && !o.sb) fatal("--inject=%s needs --sb", o.inject.c_str());
  if (o.inject == "atomic-late" && !o.atomic_early) fatal("--inject=atomic-late needs --atomic-early");
  const bool order_inj = o.inject.rfind("sb-", 0) == 0 || o.inject == "atomic-late";
  const uint64_t HART_WINDOW = lockstep_cfg_t().hart_window;

  // Several harts (§3.7). The store buffer (--sb): a hart's plain stores to main memory may wait in a buffer of
  // its own and reach memory up to --sb-max cycles after their records, in order, while the other harts read
  // what memory held; the hart itself sees them (they are laid over memory while it steps), and its AMOs,
  // LR/SCs and fences wait until they have all reached memory. Early atomics (--atomic-early): an AMO or SC
  // performs when its hart steps it, but its record carries a later cycle and its hart sits out until then, so
  // other harts may read what it wrote before its record; the checker gets the records in cycle order, as
  // tanager-lockstep applies them, with the same lookahead (lockstep_t::early_atomic).
  // --inject=sb-reorder lands two of a hart's stores to the same bytes in the wrong order, sb-late keeps a store
  // in its buffer past every window, atomic-late gives an atomic's record a cycle past the checker's bound;
  // each must be reported once a read shows it (otherwise not applicable).
  struct sb_entry_t {
    uint64_t pa = 0, due = 0;           // physical address; the cycle it reaches memory
    unsigned n = 0;
    uint8_t nw[8] = {}, under[8] = {};  // its bytes; memory's under them while its hart steps
    std::vector<uint64_t> at;           // each hart's record count at its record
  };
  std::vector<std::deque<sb_entry_t>> sbuf(o.harts);
  std::vector<uint64_t> busy_until(o.harts, 0), hrec(o.harts, 0);
  auto M = [&](uint64_t pa) { return reinterpret_cast<uint8_t*>(dut.addr_to_mem(pa)); };
  struct ord_bad_t {  // the injected fault: bytes a read may show it in
    bool live = false;
    unsigned hart = 0, n = 0;
    uint64_t pa = 0, stamp = 0;
    uint8_t mask = 0, val[8] = {}, other[8] = {};  // what the fault leaves there; what should be there
    std::vector<uint64_t> at;
  } ord_bad;
  bool ord_applicable = false;
  // The doublewords each hart read lately: an order fault goes where another hart is likely to read again
  std::vector<std::deque<uint64_t>> recent_rd(o.harts);
  auto read_by_other = [&](unsigned h, uint64_t pa) {
    for (unsigned g = 0; g < o.harts; g++)
      if (g != h)
        for (uint64_t a : recent_rd[g])
          if (a == (pa & ~7ull)) return true;
    return false;
  };
  // A write reaching memory: the fault is gone from its bytes
  auto ord_overwritten = [&](uint64_t pa, unsigned n) {
    if (ord_bad.live && o.inject != "atomic-late" && pa < ord_bad.pa + ord_bad.n && ord_bad.pa < pa + n) ord_bad.live = false;
  };

  // External writes (§3.10): another master writes bytes the program recently loaded. The checker hears
  // of each at its cycle; the replaying Spike, standing for the core, sees it up to ext_delay cycles
  // later, as loads that read before the write may commit after it. A store the core makes meanwhile to
  // the same bytes comes after the write: those bytes keep the store. --inject=ext-unannounced hides
  // writes from the checker, ext-stale hides them from the core: both must be reported once a load reads
  // the bytes (for ext-stale, after the window).
  struct ext_inj_t {
    uint64_t pa = 0, at = 0;
    uint8_t data[8] = {};
    uint32_t mask = 0;
  };
  std::deque<ext_inj_t> ext_q;                       // writes the replaying Spike has not seen yet
  std::vector<uint64_t> recent_ld;                   // physical addresses of recent loads from main memory
  std::vector<std::pair<uint64_t, uint64_t>> bad;    // injected faults: address, record count then
  uint64_t ext_writes = 0, ext_last_at = 0;
  bool ext_applicable = false;

  // Free wb_tags per hart and writebacks waiting for delivery.
  std::vector<std::vector<uint32_t>> free_tags(o.harts);
  for (auto& f : free_tags)
    for (uint32_t t = 0; t < o.tags; t++) f.push_back(t);
  std::vector<std::set<uint32_t>> live_tags(o.harts);
  std::vector<bool> ld_seen(o.harts, false);   // a hart's records have carried mem_ld: --inject=noload needs one
  std::deque<pending_t> pend;

  uint64_t nrec = 0, cycle = 0, instret = 0;
  bool injected = false, exit_seen = false, htif_console = false;
  int code = 0;
  std::string why;
  int status = EXIT_PASS;
  bool skip_next = false;

  // A store into another hart's reservation set clears that reservation (see make_record). Spike's check takes a
  // virtual address, so a hart whose loads translate is matched by the line its last LR read (resv_line, physical)
  std::vector<uint64_t> resv_line(dut.procs.size(), ~0ull);
  auto clear_reservations = [&](size_t h, uint64_t pa) {
    for (size_t k = 0; k < dut.procs.size(); k++) {
      processor_t* q = dut.procs[k];
      if (k == h) continue;
      if (!bare_translation(q)) {
        if (resv_line[k] == (pa & ~63ull)) q->get_mmu()->yield_load_reservation();
        continue;
      }
      for (uint64_t a = pa & ~63ull; a < (pa & ~63ull) + 64; a += 4) {
        bool hit = false;
        try {
          hit = q->get_mmu()->check_load_reservation(a, 1);
        } catch (...) {
        }
        if (hit) {
          q->get_mmu()->yield_load_reservation();
          break;
        }
      }
    }
  };
  // The oldest store in hart h's buffer reaches memory (--sb); with --inject=sb-reorder, a later one of the same
  // bytes goes first
  auto land = [&](unsigned h) {
    auto& sb = sbuf[h];
    sb_entry_t e = sb.front();
    sb.pop_front();
    if (o.inject == "sb-reorder" && !injected && int64_t(nrec) >= o.inject_at)
      for (size_t j = 0; j < sb.size(); j++) {
        const sb_entry_t& e2 = sb[j];
        uint8_t mask = 0;
        for (unsigned i = 0; i < 8; i++) {
          const uint64_t b = (e.pa & ~7ull) + i;
          if (b >= e.pa && b < e.pa + e.n && b >= e2.pa && b < e2.pa + e2.n && e.nw[b - e.pa] != e2.nw[b - e2.pa])
            mask |= uint8_t(1u << i);
        }
        if (!mask || (e2.pa & ~7ull) != (e.pa & ~7ull)) continue;
        memcpy(M(e2.pa), e2.nw, e2.n);  // the later store first
        clear_reservations(h, e2.pa);
        injected = true;
        ord_bad.live = true;
        ord_bad.hart = h;
        ord_bad.pa = e.pa & ~7ull;
        ord_bad.n = 8;
        ord_bad.mask = mask;
        for (unsigned i = 0; i < 8; i++)
          if (mask >> i & 1) ord_bad.val[i] = e.nw[ord_bad.pa + i - e.pa], ord_bad.other[i] = e2.nw[ord_bad.pa + i - e2.pa];
        ord_bad.at = e2.at;
        memcpy(M(e.pa), e.nw, e.n);
        clear_reservations(h, e.pa);
        sb.erase(sb.begin() + long(j));
        return;
      }
    ord_overwritten(e.pa, e.n);
    if (ord_bad.live && o.inject == "sb-late" && ord_bad.hart == h && ord_bad.pa == e.pa) ord_bad.live = false;
    memcpy(M(e.pa), e.nw, e.n);
    clear_reservations(h, e.pa);
  };
  // Whether hart h waits this cycle: for its atomic's record (--atomic-early), or with an AMO, LR/SC or fence next
  // while its buffer holds stores (--sb)
  auto waits = [&](unsigned h) {
    if (busy_until[h] > cycle) return true;
    if (sbuf[h].empty()) return false;
    uint32_t bits = 0;
    return spike_fetch(dut.procs[h], dut.procs[h]->get_state()->pc, bits, true) && orders_memory(bits);
  };

  auto make_record = [&](unsigned h) -> tr_rec_t {
    processor_t* p = dut.procs[h];
    state_t* s = p->get_state();
    tr_rec_t r;
    r.cycle = cycle;
    r.hart = plat.hartids[h];
    r.priv = uint8_t(s->prv);
    r.pc = s->pc;
    uint32_t bits = 0;
    spike_fetch(p, s->pc, bits, true);  // what this Spike's step will execute

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
    // The store buffer (--sb): the hart's own waiting stores are laid over memory for its step, and a plain store
    // to main memory joins them (always behind one already waiting)
    auto& sb = sbuf[h];
    uint64_t sva = 0, spa = 0;
    unsigned sn = 0;
    uint8_t view[8] = {};
    const bool to_buffer = o.sb && plain_store(p, bits, sva, sn) && spike_data_paddr(p, dut, sva, spa) &&
                           dut.in_dram(spa) && (spa & 7) + sn <= 8 && (!sb.empty() || rng.percent(o.sb));
    for (auto& e : sb) {
      memcpy(e.under, M(e.pa), e.n);
      memcpy(M(e.pa), e.nw, e.n);
    }
    if (to_buffer) memcpy(view, M(spa), sn);
    spike_step_t st = spike_step(p, bits);
    dut.amo_step = false;
    if (uint64_t lpa = 0; (bits & 3) == 3 && is_amo_insn(bits) && f5 == 2 && !st.trapped && st.nld == 1 &&
                          spike_data_paddr(p, dut, st.ld_addr, lpa))
      resv_line[h] = lpa & ~63ull;
    bool buffered = false;
    sb_entry_t ne;
    if (to_buffer && !st.trapped && st.nst == 1 && st.st_addr == sva && st.st_size == sn) {
      ne.pa = spa;
      ne.n = sn;
      memcpy(ne.nw, M(spa), sn);
      memcpy(M(spa), view, sn);
      ne.due = cycle + 1 + rng.below(o.sb_max);
      ne.at = hrec;
      buffered = true;
    }
    for (size_t i = sb.size(); i-- > 0;) memcpy(M(sb[i].pa), sb[i].under, sb[i].n);
    if (buffered) {
      if (o.inject == "sb-late" && !injected && int64_t(nrec) >= o.inject_at && read_by_other(h, ne.pa)) {
        ne.due = cycle + 8 * HART_WINDOW;  // past every window, the hart's later stores behind it
        injected = true;
        ord_bad.live = true;
        ord_bad.hart = h;
        ord_bad.pa = ne.pa;
        ord_bad.n = ne.n;
        memcpy(ord_bad.other, ne.nw, ne.n);
        ord_bad.at = ne.at;
      }
      sb.push_back(ne);
    } else if (uint64_t a = 0; !sb.empty() && !st.trapped && st.nst && spike_data_paddr(p, dut, st.st_addr, a) && dut.in_dram(a)) {
      fatal("--sb: a store at %016llx (%08x) the store buffer does not know", (unsigned long long)st.pc, bits);
    }
    if (forced) s->mip->backdoor_write_with_mask(forced, platform_levels(h) & forced & PLATFORM_MIP);
    uint64_t xpa = 0;
    // An SC fails once another hart has stored into its reservation set (RVWMO; Spike's harts keep theirs through
    // each other's stores). The core clears a sibling's reservation when a store reaches its line, as a probe
    // does, so the replay clears every other hart's reservation in the line of a store: a stricter set than
    // Spike's, and an SC may always fail. A hart whose loads translate is matched by its last LR's line.
    if (dut.procs.size() > 1 && !st.trapped && st.nst && !buffered && spike_data_paddr(p, dut, st.st_addr, xpa) &&
        dut.in_dram(xpa)) {
      clear_reservations(h, xpa);
      ord_overwritten(xpa, st.st_size);
    }
    xpa = 0;
    if (o.ext && !st.trapped && st.nld && spike_data_paddr(p, dut, st.ld_addr, xpa) && dut.in_dram(xpa)) {
      recent_ld.push_back(xpa);
      if (recent_ld.size() > 64) recent_ld.erase(recent_ld.begin());
      for (auto& [ba, at] : bad)
        if (xpa < ba + 8 && ba < xpa + st.ld_size && (o.inject != "ext-stale" || nrec > at + 2 * o.ext_window))
          ext_applicable = true;
    }
    if (o.ext && !st.trapped && st.nst && spike_data_paddr(p, dut, st.st_addr, xpa))
      for (auto& q : ext_q)
        for (unsigned i = 0; i < 8; i++)
          if (xpa <= q.pa + i && q.pa + i < xpa + st.st_size) q.mask &= ~(1u << i);

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
    // A read (interfaces.md §5, v1.5): its address and size, as the core reports them; an AMO's are its write's
    if (st.nld) {
      r.mem_ld = true;
      if (!r.mem_st) r.mem_vaddr = st.ld_addr, r.mem_size = uint8_t(log2_size(st.ld_size));
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
      pend.push_back({nrec + 1 + rng.below(o.defer_max), w, cycle});
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
    if (k == "ld-addr" && r.mem_ld && !r.mem_st) { r.mem_vaddr ^= 8; return true; }
    if (k == "noload" && r.mem_ld && !r.mem_st && ld_seen[r.hart]) { r.mem_ld = false; return true; }
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

  // --atomic-early: the records and writebacks go through the checker's cycle-order queue (hart_order_t); at the
  // end of a cycle all of that cycle or earlier go, each after the atomic of another hart its read needs, as in
  // tanager-lockstep
  hart_order_t order(ls, plat.hartids);

  FILE* logf = o.log.empty() ? nullptr : fopen(o.log.c_str(), "w");
  auto dis = [&](uint32_t i) { return ls.disasm(i); };
  std::vector<tr_rec_t> recs;
  std::vector<tr_wb_t> wbs;
  while (status == EXIT_PASS) {
    recs.clear();
    wbs.clear();
    if (o.ext) {
      while (!ext_q.empty() && ext_q.front().at <= cycle) {  // the replaying Spike sees the write now
        const ext_inj_t& q = ext_q.front();
        uint8_t* m = reinterpret_cast<uint8_t*>(dut.addr_to_mem(q.pa));
        for (unsigned i = 0; i < 8; i++)
          if (q.mask >> i & 1) m[i] = q.data[i];
        for (auto* pp : dut.procs) pp->get_mmu()->flush_icache();  // the bytes may be instructions
        ext_q.pop_front();
      }
      if (!recent_ld.empty() && rng.permille(o.ext)) {
        ext_inj_t q;
        q.pa = recent_ld[rng.below(recent_ld.size())] & ~7ull;
        for (auto& b : q.data) b = uint8_t(rng.next());
        q.mask = 0xff;
        q.at = ext_last_at = std::max(ext_last_at, cycle + rng.below(o.ext_delay + 1));  // in order
        const bool fault = o.inject.rfind("ext-", 0) == 0 && int64_t(nrec) >= o.inject_at;
        if (fault) {
          injected = true;
          bad.push_back({q.pa, nrec});
        }
        if (!(fault && o.inject == "ext-unannounced")) {
          if (!ls.external_write(q.pa, q.data, q.mask, 8, cycle)) { status = EXIT_MISMATCH; why = ls.error(); break; }
          ext_writes++;
        }
        if (!(fault && o.inject == "ext-stale")) ext_q.push_back(q);
      }
    }
    // Buffered stores whose time has come reach memory, each hart's in order (--sb)
    for (unsigned k = 0; k < o.harts && o.sb; k++) {
      const unsigned h = unsigned((k + cycle) % o.harts);  // who goes first rotates
      while (!sbuf[h].empty() && sbuf[h].front().due <= cycle) land(h);
    }
    unsigned n = 1 + unsigned(rng.below(o.width));
    for (unsigned i = 0; i < n && !exit_seen; i++) {
      unsigned h = unsigned(rng.below(o.harts));
      if ((o.sb || o.atomic_early) && waits(h)) continue;
      // With other harts' writes in flight (--sb, --atomic-early), a deferred value may not be what the checker's
      // Spike read, so as in the core, an instruction that reads it comes after its writeback: one waiting is
      // delivered now (or, its record from this cycle, the hart waits)
      if ((o.sb || o.atomic_early) && o.defer) {
        uint32_t next = 0;
        spike_fetch(dut.procs[h], dut.procs[h]->get_state()->pc, next, true);
        bool wait = false;
        for (size_t k = 0; k < pend.size() && !wait; k++) {
          if (pend[k].wb.hart != plat.hartids[h] || !may_read(next, pend[k].wb.rd)) continue;
          if (pend[k].cycle == cycle) {
            wait = true;
            break;
          }
          tr_wb_t w = pend[k].wb;
          w.cycle = cycle;
          live_tags[h].erase(w.wb_tag);
          free_tags[h].push_back(w.wb_tag);
          pend.erase(pend.begin() + long(k--));
          if (o.atomic_early) order.push(w);
          else wbs.push_back(w);
        }
        if (wait) continue;
      }
      tr_rec_t r = make_record(h);
      nrec++;
      hrec[h]++;
      // --atomic-early: an AMO or SC's record a few cycles after it performed, its hart sitting out until then
      if (o.atomic_early && r.kind == TR_RETIRE && r.mem_st && !r.rvc && is_amo_insn(r.insn)) {
        uint64_t apa = 0;
        const bool late = o.inject == "atomic-late" && !injected && int64_t(nrec) >= o.inject_at && r.rd_we &&
                          (r.insn >> 27) != 3 && spike_data_paddr(dut.procs[h], dut, r.mem_vaddr, apa) && dut.in_dram(apa) &&
                          read_by_other(h, apa);
        const uint64_t k = late ? ATOMIC_EARLY + 1 + rng.below(64) : rng.below(o.atomic_early + 1);
        r.cycle = cycle + k;
        busy_until[h] = cycle + k;
        if (late) {
          injected = true;
          ord_bad.live = true;
          ord_bad.hart = h;
          ord_bad.pa = apa;
          ord_bad.n = 1u << r.mem_size;
          ord_bad.stamp = r.cycle;
          memcpy(ord_bad.val, M(apa), ord_bad.n);  // what it wrote
          for (unsigned b = 0; b < ord_bad.n; b++) ord_bad.other[b] = uint8_t(r.rd_value >> (8 * b));  // what it read
        }
      }
      if (order_inj && r.kind == TR_RETIRE && r.mem_ld)
        if (uint64_t pa = 0; spike_data_paddr(dut.procs[h], dut, r.mem_vaddr, pa)) {
          recent_rd[h].push_back(pa & ~7ull);
          if (recent_rd[h].size() > 32) recent_rd[h].pop_front();
        }
      // An injected order fault counts once a read shows it where the checker must see it (see above)
      if (order_inj && ord_bad.live && !ord_applicable && r.kind == TR_RETIRE && r.mem_ld && r.rd_we && !r.mmio_ld) {
        uint64_t pa = 0;
        if (spike_data_paddr(dut.procs[h], dut, r.mem_vaddr, pa))
          for (unsigned b = 0; b < (1u << r.mem_size); b++) {
            const uint64_t a = pa + b, j = a - ord_bad.pa;
            if (a < ord_bad.pa || j >= ord_bad.n) continue;
            bool own = false;  // the hart's own waiting store: what it reads there
            for (auto& e : sbuf[h]) own = own || (a >= e.pa && a < e.pa + e.n);
            const uint8_t got = uint8_t(r.rd_value >> (8 * b));
            const bool past = hrec[h] - (ord_bad.at.empty() ? 0 : ord_bad.at[h]) >= HART_WINDOW;
            if (own) continue;
            if (o.inject == "atomic-late")
              ord_applicable |= h != ord_bad.hart && r.cycle + ATOMIC_EARLY < ord_bad.stamp && got == ord_bad.val[j] &&
                                ord_bad.val[j] != ord_bad.other[j];
            else if (o.inject == "sb-reorder")
              ord_applicable |= (ord_bad.mask >> j & 1) && got == ord_bad.val[j] && (h == ord_bad.hart || past);
            else
              ord_applicable |= h != ord_bad.hart && got != ord_bad.other[j] && past;
          }
      }
      if (r.kind == TR_RETIRE) instret++;
      uint64_t v;
      if (r.kind == TR_RETIRE && r.mem_st && tohost.store(r.mem_vaddr, r.mem_wdata, r.mem_size, v)) {
        if (tohost_watch_t::is_putchar(v)) {  // HTIF console
          console.push_back(char(v & 0xff));
          htif_console = true;
          fputc(int(v & 0xff), stdout);
        } else if (tohost_watch_t::is_exit(v)) {   // any hart's, as in tg_vsim (the pair runner's last finisher)
          exit_seen = true;
          code = int(v >> 1);
        }
      }
      if (!o.inject.empty() && !injected && int64_t(nrec) >= o.inject_at) {
        if (o.inject == "skip" && r.kind == TR_RETIRE) { injected = true; skip_next = true; }
        else if (o.inject != "wb-value" && o.inject != "wb-missing" && o.inject != "wb-extra" && inject_rec(r)) injected = true;
      }
      if (skip_next) { skip_next = false; continue; }
      if (r.mem_ld) ld_seen[r.hart] = true;
      recs.push_back(r);
      if (o.atomic_early) order.push(r);
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
    if (o.atomic_early) {  // in cycle order (above)
      for (auto& w : wbs) order.push(w);
      if (!order.drain(exit_seen && pend.empty() ? ~0ull : cycle)) { status = EXIT_MISMATCH; why = ls.error(); break; }
    } else if (!ls.cycle(recs, wbs)) {
      status = EXIT_MISMATCH;
      why = ls.error();
      break;
    }
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
    if (!injected || (o.inject.rfind("ext-", 0) == 0 && !ext_applicable && status != EXIT_MISMATCH) ||
        (order_inj && !ord_applicable && status != EXIT_MISMATCH)) {
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
  printf("TG-REPLAY status=%s code=%d records=%llu instret=%llu cycles=%llu%s%s\n", exit_status_name(status), code,
         (unsigned long long)nrec, (unsigned long long)instret, (unsigned long long)cycle,
         o.ext ? strfmt(" ext_writes=%llu ext_loads_new=%llu", (unsigned long long)ext_writes,
                        (unsigned long long)ls.ext_loads_new()).c_str() : "",
         o.sb || o.atomic_early ? strfmt(" loads_old=%llu reapplied=%llu late_stores=%llu early_atomics=%llu",
                                         (unsigned long long)ls.hart_loads_old(), (unsigned long long)ls.hart_reapplied(),
                                         (unsigned long long)ls.hart_late(), (unsigned long long)order.early()).c_str() : "");
  return status;
}
