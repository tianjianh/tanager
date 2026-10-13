// tg_vsim: the Verilator harness around tg_core (docs/spec/verification.md §2).
#include <verilated.h>
#include <verilated_fst_c.h>

#include <cerrno>
#include <chrono>
#include <cinttypes>
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "Vtg_tb_top.h"
#include "common.h"
#include "elfload.h"
#include "lockstep.h"
#include "mem.h"
#include "tb.h"

#ifndef TG_DEFAULT_ISA
#define TG_DEFAULT_ISA "rv64im_zicsr_zifencei"
#endif
#ifndef TG_DEFAULT_PRIV
#define TG_DEFAULT_PRIV "M"
#endif
#ifndef TG_DEFAULT_PMP
#define TG_DEFAULT_PMP 16
#endif
#ifndef TG_CORE_NAME
#define TG_CORE_NAME "tg_core"
#endif

using namespace tg;

namespace {

struct opts_t {
  std::string elf;
  uint64_t cycles = 50000000, hang = 100000, wb_drain = 2000, wb_timeout = 100000;
  double timeout = 3600;
  std::string fst, log;
  uint64_t fst_from = 0, fst_to = ~0ull;
  bool lockstep = true, rand_reset = false, quiet = false;
  std::string isa = TG_DEFAULT_ISA, priv = TG_DEFAULT_PRIV;
  uint64_t seed = 1;
  unsigned history = 32;
  unsigned pmp = TG_DEFAULT_PMP, pmp_g = 4;
  bool pmp_reset_off = false;
  int harts = -1;
  uint64_t mem_mb = 2048;
  std::string rom;
  std::vector<uint64_t> tohost_va;
};

void usage() {
  fprintf(stderr,
          "usage: tg_vsim [options] program.elf\n"
          "  run control: --cycles=N --timeout=S --hang=N --wb-drain=N --wb-timeout=N --seed=N --quiet\n"
          "  waveforms:   --fst=FILE [--fst-from=C] [--fst-to=C]; text trace: --log=FILE\n"
          "  lockstep:    --lockstep | --no-lockstep, --isa=STR --priv=STR --harts=N --history=N\n"
          "               --pmp=N --pmp-g=BYTES --pmp-reset=spike|off\n"
          "  memory:      --lat=native|90|120|250|N --lat-jitter=N --bp=PCT --d-gap=PCT --grant-b=PCT\n"
          "               --probe-rate=PERMILLE --mmio-lat=N --d-stall-max=N --mem-mb=N --rom=FILE\n"
          "               --deny=ADDR[:LEN] --boot=ADDR --tohost-va=ADDR\n"
          "  devices:     --mtime-div=N --irq-rand=PERMILLE\n"
          "  RTL:         --rand-reset; +plusargs are passed to the model (tg_tcore: +tcore_defer=PCT\n"
          "               +tcore_spread=1 +tcore_seed=N)\n"
          "built for %s, configuration from the RTL, default ISA %s, privilege %s\n",
          TG_CORE_NAME, TG_DEFAULT_ISA, TG_DEFAULT_PRIV);
  exit(EXIT_HARNESS);
}

uint64_t num(const std::string& s, const char* what) {
  char* end = nullptr;
  errno = 0;
  uint64_t v = strtoull(s.c_str(), &end, 0);
  if (s.empty() || *end || errno) fatal("bad number for %s: '%s'", what, s.c_str());
  return v;
}

opts_t parse(int argc, char** argv, model_cfg_t& mc) {
  opts_t o;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a.rfind("+", 0) == 0) continue;  // plusargs belong to the model
    if (a.rfind("--", 0) != 0) {
      if (!o.elf.empty()) fatal("more than one program given ('%s' and '%s')", o.elf.c_str(), a.c_str());
      o.elf = a;
      continue;
    }
    std::string k = a.substr(2), v;
    size_t eq = k.find('=');
    bool has_v = eq != std::string::npos;
    if (has_v) { v = k.substr(eq + 1); k = k.substr(0, eq); }
    auto need = [&] { if (!has_v) fatal("--%s needs a value", k.c_str()); return v; };
    if (k == "help") usage();
    else if (k == "cycles") o.cycles = num(need(), "--cycles");
    else if (k == "timeout") o.timeout = double(num(need(), "--timeout"));
    else if (k == "hang") o.hang = num(need(), "--hang");
    else if (k == "wb-drain") o.wb_drain = num(need(), "--wb-drain");
    else if (k == "wb-timeout") o.wb_timeout = num(need(), "--wb-timeout");
    else if (k == "fst") o.fst = need();
    else if (k == "fst-from") o.fst_from = num(need(), "--fst-from");
    else if (k == "fst-to") o.fst_to = num(need(), "--fst-to");
    else if (k == "log") o.log = need();
    else if (k == "lockstep") o.lockstep = true;
    else if (k == "no-lockstep") o.lockstep = false;
    else if (k == "isa") o.isa = need();
    else if (k == "priv") o.priv = need();
    else if (k == "harts") o.harts = int(num(need(), "--harts"));
    else if (k == "history") o.history = unsigned(num(need(), "--history"));
    else if (k == "pmp") o.pmp = unsigned(num(need(), "--pmp"));
    else if (k == "pmp-g") o.pmp_g = unsigned(num(need(), "--pmp-g"));
    else if (k == "pmp-reset") {
      need();
      if (v == "off") o.pmp_reset_off = true;
      else if (v == "spike") o.pmp_reset_off = false;
      else fatal("--pmp-reset is spike or off");
    }
    else if (k == "seed") o.seed = num(need(), "--seed");
    else if (k == "quiet") o.quiet = true;
    else if (k == "rand-reset") o.rand_reset = true;
    else if (k == "lat") {
      need();
      mc.lat = v == "native" ? 30 : unsigned(num(v, "--lat"));
      if (mc.lat < 1) fatal("--lat must be at least 1");
    }
    else if (k == "lat-jitter") mc.lat_jitter = unsigned(num(need(), "--lat-jitter"));
    else if (k == "bp") mc.bp = unsigned(num(need(), "--bp"));
    else if (k == "d-gap") mc.d_gap = unsigned(num(need(), "--d-gap"));
    else if (k == "grant-b") mc.grant_b = unsigned(num(need(), "--grant-b"));
    else if (k == "probe-rate") mc.probe_rate = unsigned(num(need(), "--probe-rate"));
    else if (k == "mmio-lat") mc.mmio_lat = std::max(1u, unsigned(num(need(), "--mmio-lat")));
    else if (k == "d-stall-max") mc.d_stall_max = unsigned(num(need(), "--d-stall-max"));
    else if (k == "mem-mb") o.mem_mb = num(need(), "--mem-mb");
    else if (k == "rom") o.rom = need();
    else if (k == "deny") {
      need();
      size_t c = v.find(':');
      uint64_t base = num(v.substr(0, c), "--deny"), len = c == std::string::npos ? 1 : num(v.substr(c + 1), "--deny");
      mc.deny.push_back({base, len});
    }
    else if (k == "boot") tb().boot_addr = num(need(), "--boot");
    else if (k == "tohost-va") o.tohost_va.push_back(num(need(), "--tohost-va"));
    else if (k == "mtime-div") mc.mtime_div = std::max(1u, unsigned(num(need(), "--mtime-div")));
    else if (k == "irq-rand") mc.irq_rand = unsigned(num(need(), "--irq-rand"));
    else { fprintf(stderr, "tg: unknown option --%s\n", k.c_str()); usage(); }
  }
  if (o.elf.empty()) usage();
  mc.seed = o.seed;
  mc.dram_size = o.mem_mb << 20;
  return o;
}

double now_s() {
  using namespace std::chrono;
  return duration<double>(steady_clock::now().time_since_epoch()).count();
}

}  // namespace

int main(int argc, char** argv) {
  tb_t& t = tb();
  model_cfg_t& mc = t.ctx.cfg;
  // Device regions of tg_map_pkg (PMA_DEVICE)
  mc.dev_regions = {{0x02000000ull, 0x10000}, {0x0C000000ull, 0x4000000}, {0x10000000ull, 0x1000},
                    {0x10001000ull, 0x1000},  {0x10010000ull, 0x4000},    {0x11000000ull, 0x10000}};
  opts_t o = parse(argc, argv, mc);
  t.ctx.rng = rng_t(o.seed * 0x9e3779b97f4a7c15ull + 1);
  t.ctx.quiet = false;  // the console always goes to stdout; --quiet drops the banners

  mem_t mem;
  t.ctx.mem = &mem;
  elf_t elf;
  elf.load(o.elf, mem);
  if (!o.rom.empty()) {
    FILE* f = fopen(o.rom.c_str(), "rb");
    if (!f) fatal("cannot open ROM image %s", o.rom.c_str());
    std::vector<uint8_t> b(mc.rom_size);
    size_t n = fread(b.data(), 1, b.size(), f);
    fclose(f);
    mem.write(mc.rom_base, n, b.data());
  }

  // tohost and its aliases (verification.md §2.6)
  std::set<uint64_t> tohost_va(o.tohost_va.begin(), o.tohost_va.end());
  uint64_t tohost = elf.sym("tohost");
  if (elf.has("tohost")) tohost_va.insert(tohost);
  bool has_marker = elf.has("tg_marker");
  uint64_t marker = elf.sym("tg_marker");

  // ---- Verilated model ----
  auto vctx = std::make_unique<VerilatedContext>();
  vctx->commandArgs(argc, argv);  // +plusargs for the RTL (for example +tcore_defer=50)
  vctx->randReset(o.rand_reset ? 2 : 0);
  vctx->randSeed(int(o.seed & 0x7fffffff));
  if (!o.fst.empty()) vctx->traceEverOn(true);
  auto top = std::make_unique<Vtg_tb_top>(vctx.get(), "TOP");
  std::unique_ptr<VerilatedFstC> fst;
  if (!o.fst.empty()) {
    fst = std::make_unique<VerilatedFstC>();
    top->trace(fst.get(), 99);
  }
  top->clk = 0;
  top->rst = 1;
  top->eval();  // initial blocks: tg_dpi_config
  if (!t.hw.known) fatal("the RTL did not report its configuration (tg_dpi_config)");
  const hw_cfg_t& hw = t.hw;
  mc.num_threads = hw.num_threads;
  mc.core_id = hw.core_id;
  t.mmio.clint.init((hw.core_id + 1) * hw.num_threads);

  // ---- Lockstep ----
  std::unique_ptr<lockstep_t> ls;
  if (o.lockstep) {
    lockstep_cfg_t lc;
    lc.isa = o.isa;
    lc.priv = o.priv;
    unsigned nh = o.harts > 0 ? unsigned(o.harts) : hw.num_threads;
    lc.hartids.clear();
    for (unsigned i = 0; i < nh; i++) lc.hartids.push_back(hw.core_id * hw.num_threads + i);
    lc.boot_pc = t.boot_addr;
    lc.pmp_regions = o.pmp;
    lc.pmp_granularity = o.pmp_g;
    lc.pmp_reset_off = o.pmp_reset_off;
    lc.history = o.history;
    lc.dram_base = mc.dram_base;
    lc.dram_size = mc.dram_size;
    lc.rom_base = mc.rom_base;
    lc.rom_size = mc.rom_size;
    lc.dev_regions = mc.dev_regions;
    lc.deny = mc.deny;
    ls = std::make_unique<lockstep_t>(lc, mem, &elf);
  }

  FILE* logf = nullptr;
  if (!o.log.empty()) {
    logf = fopen(o.log.c_str(), "w");
    if (!logf) fatal("cannot open %s", o.log.c_str());
  }
  auto dis = [&](uint32_t insn) { return ls ? ls->disasm(insn) : std::string(); };

  if (!o.quiet) {
    fprintf(stderr, "tg_vsim: %s, core %s, cfg %s (commit width %u, %u thread(s)), seed %llu, lat %u, lockstep %s%s\n",
            o.elf.c_str(), TG_CORE_NAME, hw.cfg_name.c_str(), hw.commit_width, hw.num_threads,
            (unsigned long long)o.seed, mc.lat, ls ? "on" : "off", ls ? (" (" + o.isa + ", " + o.priv + ")").c_str() : "");
  }

  // ---- Reset ----
  uint64_t vtime = 0;
  for (int i = 0; i < 8; i++) {
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
  }
  top->rst = 0;

  // ---- Main loop ----
  int status = EXIT_PASS, code = 0;
  std::string why;
  uint64_t cycle = 0, instret = 0, last_rec = 0;
  uint64_t region_c0 = 0, region_i0 = 0, region_cycles = 0, region_instret = 0;
  bool exit_seen = false, htif_console = false;
  uint64_t exit_cycle = 0, htif_cycle = 0;
  double t0 = now_s(), tlimit = t0 + o.timeout;
  bool fst_open = false;

  for (;; cycle++) {
    t.ctx.now = cycle;
    t.recs.clear();
    t.wbs.clear();
    top->clk = 1;
    top->eval();
    if (fst) {
      if (!fst_open && cycle >= o.fst_from && cycle <= o.fst_to) { fst->open(o.fst.c_str()); fst_open = true; }
      if (fst_open && cycle > o.fst_to) { fst->close(); fst.reset(); fst_open = false; }
      if (fst_open) fst->dump(vtime);
    }
    vtime++;
    top->clk = 0;
    top->eval();
    if (fst_open) fst->dump(vtime);
    vtime++;

    if (t.ctx.failed) { status = EXIT_PROTOCOL; why = t.ctx.error; break; }

    if (!t.recs.empty() || !t.wbs.empty()) last_rec = cycle;
    for (auto& r : t.recs) {
      if (logf) fprintf(logf, "%s\n", format_rec(r, dis).c_str());
      if (r.kind != TR_RETIRE) continue;
      instret++;
      if (!r.mem_st) continue;
      if (tohost_va.count(r.mem_vaddr) && !exit_seen) {
        uint64_t v = r.mem_wdata & size_mask(r.mem_size);
        if ((v >> 48) == 0x0101) {  // HTIF console: device 1, command 1
          char c = char(v & 0xff);
          t.ctx.console.push_back(c);
          fputc(c, stdout);
          htif_console = true;
          htif_cycle = cycle;
        } else if (v & 1) {
          exit_seen = true;
          exit_cycle = cycle;
          code = int(v >> 1);
        } else if (v != 0) {
          status = EXIT_PROGRAM_FAIL;
          why = strfmt("unexpected tohost value %016llx", (unsigned long long)v);
        }
      }
      if (has_marker && r.mem_vaddr == marker) {
        uint64_t v = r.mem_wdata & size_mask(r.mem_size);
        if (v == 1) { region_c0 = cycle; region_i0 = instret; }
        else if (v == 2) { region_cycles = cycle - region_c0; region_instret = instret - region_i0; }
      }
    }
    for (auto& w : t.wbs)
      if (logf) fprintf(logf, "%s\n", format_wb(w).c_str());
    if (status != EXIT_PASS) break;

    if (ls && !ls->cycle(t.recs, t.wbs)) { status = EXIT_MISMATCH; why = ls->error(); break; }
    if (ls && (cycle & 4095) == 0 && !ls->check_stale(cycle, o.wb_timeout)) { status = EXIT_MISMATCH; why = ls->error(); break; }

    if (exit_seen) {
      // Let deferred writebacks of retired instructions arrive (verification.md §3.5).
      if (!ls || ls->pending_wbs() == 0 || cycle - exit_cycle >= o.wb_drain) {
        if (ls && !ls->finish()) { status = EXIT_MISMATCH; why = ls->error(); }
        else if (code) { status = EXIT_PROGRAM_FAIL; why = strfmt("program exit code %d", code); }
        break;
      }
    }
    if (cycle - last_rec >= o.hang) {
      status = EXIT_TIMEOUT;
      why = strfmt("HANG: no trace record for %llu cycles", (unsigned long long)o.hang);
      break;
    }
    if (cycle + 1 >= o.cycles) {
      status = EXIT_TIMEOUT;
      why = strfmt("TIMEOUT: cycle limit %llu reached", (unsigned long long)o.cycles);
      break;
    }
    if ((cycle & 4095) == 0 && now_s() > tlimit) {
      status = EXIT_TIMEOUT;
      why = strfmt("TIMEOUT: wall-clock limit of %.0f s reached", o.timeout);
      break;
    }
  }
  fflush(stdout);
  if (fst_open) fst->close();
  top->final();
  if (logf) fclose(logf);

  double secs = now_s() - t0;
  if (status == EXIT_MISMATCH && ls && ls->failed()) ls->report(stderr);
  if (!why.empty()) fprintf(stderr, "tg_vsim: %s\n", why.c_str());
  if (!o.quiet) {
    fprintf(stderr, "tg_vsim: %s after %llu cycles, %llu instructions retired, IPC %.3f, %.1f s (%.1f kHz)\n",
            exit_status_name(status), (unsigned long long)cycle, (unsigned long long)instret,
            cycle ? double(instret) / double(cycle) : 0.0, secs, secs > 0 ? cycle / secs / 1000 : 0.0);
    fprintf(stderr, "tg_vsim: l1i %llu Gets; l1d %llu Acquires, %llu Releases, %llu probes, %llu Gets, %llu Puts; "
                    "mmio %llu requests%s\n",
            (unsigned long long)t.l1i.requests, (unsigned long long)t.l1d.acquires, (unsigned long long)t.l1d.releases,
            (unsigned long long)t.l1d.probes_sent, (unsigned long long)t.l1d.gets, (unsigned long long)t.l1d.puts,
            (unsigned long long)t.mmio.requests,
            t.merr_pulses ? strfmt("; merr_o pulsed %llu times", (unsigned long long)t.merr_pulses).c_str() : "");
  }
  printf("TG-RESULT status=%s code=%d cycles=%llu instret=%llu ipc=%.4f khz=%.2f region_cycles=%llu region_instret=%llu\n",
         exit_status_name(status), code, (unsigned long long)cycle, (unsigned long long)instret,
         cycle ? double(instret) / double(cycle) : 0.0, secs > 0 ? cycle / secs / 1000 : 0.0,
         (unsigned long long)region_cycles, (unsigned long long)region_instret);
  fflush(stdout);
  return status;
}
