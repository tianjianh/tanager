// tgsim: command-line driver.
//   tgsim [--preset P] [--set name=value ...] [--stdin TEXT] [--bench NAME] [--json FILE] [--iss-only] prog.elf
//         [--stdin2 TEXT] [--bench2 NAME] [--ff2 0|1] [prog2.elf]
// With --set threads=2 the second program runs on hardware thread 1 (SMT2); ff applies to thread 0, --ff2 to
// thread 1.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "config.h"
#include "core.h"
#include "iss.h"

using namespace tg;

static void usage() {
  std::fprintf(stderr,
               "usage: tgsim [--preset tanager_v1|v1_freeze|nax|nax_cal] [--set name=value ...] [--stdin TEXT]\n"
               "             [--bench NAME] [--json FILE] [--iss-only] [--ram-mb N] [--params] program.elf\n"
               "             [--stdin2 TEXT] [--bench2 NAME] [--ff2 0|1] [program2.elf]   (with --set threads=2)\n");
}

int main(int argc, char** argv) {
  Config cfg;
  std::vector<std::pair<std::string, std::string>> sets;
  std::string preset = "tanager_v1", stdin_text, bench, json_out, stdin2, bench2;
  std::vector<std::string> elfs;
  int64_t ff2 = 0;
  bool iss_only = false;
  uint64_t ram_mb = 1024;
  for (int i = 1; i < argc; i++) {
    const std::string a = argv[i];
    auto next = [&]() -> std::string {
      if (i + 1 >= argc) { usage(); std::exit(2); }
      return argv[++i];
    };
    if (a == "--preset") preset = next();
    else if (a == "--set") {
      const std::string kv = next();
      const auto eq = kv.find('=');
      if (eq == std::string::npos) { std::fprintf(stderr, "bad --set %s\n", kv.c_str()); return 2; }
      sets.emplace_back(kv.substr(0, eq), kv.substr(eq + 1));
    } else if (a == "--stdin") stdin_text = next();
    else if (a == "--bench") bench = next();
    else if (a == "--stdin2") stdin2 = next();
    else if (a == "--bench2") bench2 = next();
    else if (a == "--ff2") ff2 = std::stoll(next());
    else if (a == "--json") json_out = next();
    else if (a == "--iss-only") iss_only = true;
    else if (a == "--ram-mb") ram_mb = std::stoull(next());
    else if (a == "--params") { std::fputs(Config::help().c_str(), stdout); return 0; }
    else if (!a.empty() && a[0] == '-') { usage(); return 2; }
    else elfs.push_back(a);
  }
  if (elfs.empty() || elfs.size() > (size_t)MAX_THREADS) { usage(); return 2; }
  if (!cfg.apply_preset(preset)) { std::fprintf(stderr, "unknown preset %s\n", preset.c_str()); return 2; }
  for (auto& kv : sets)
    if (!cfg.set(kv.first, kv.second)) {
      std::fprintf(stderr, "unknown parameter or bad value: %s=%s\n", kv.first.c_str(), kv.second.c_str());
      return 2;
    }
  if (cfg.threads < 1 || cfg.threads > MAX_THREADS || (!iss_only && (size_t)cfg.threads != elfs.size())) {
    std::fprintf(stderr, "threads=%lld needs that many programs (%zu given)\n", (long long)cfg.threads, elfs.size());
    return 2;
  }
  if (bench.empty()) bench = elfs[0];
  if (bench2.empty() && elfs.size() > 1) bench2 = elfs[1];

  const uint64_t ram_base = 0x80000000ull, ram_size = ram_mb << 20;
  Iss iss(ram_base, ram_size);
  std::string err;
  if (!iss.load_elf(elfs[0], err)) { std::fprintf(stderr, "load: %s\n", err.c_str()); return 1; }
  iss.set_stdin(stdin_text);

  std::string out;
  int rc = 0;
  if (iss_only) {
    DynInst di;
    const char* tr = std::getenv("TGSIM_TRACE");
    uint64_t trace_n = tr ? std::strtoull(tr, nullptr, 0) : 0;
    // TGSIM_PAIRS=N: histogram of adjacent instruction pairs inside the marked region where the second
    // reads the first's destination (candidate fusion pairs), plus the opcode mix; prints the top N.
    const char* pe = std::getenv("TGSIM_PAIRS");
    const int pairs_n = pe ? std::atoi(pe) : 0;
    std::map<std::string, uint64_t> pairs, mix;
    uint64_t region_instr = 0;
    bool in_region = false;
    const Decoded* prev = nullptr;
    while (iss.step(di)) {
      if (trace_n) {
        trace_n--;
        std::fprintf(stderr, "%8llu pc=%08llx %-10s raw=%08x addr=%llx taken=%d\n", (unsigned long long)di.seq,
                     (unsigned long long)di.pc, op_name(di.d->op), di.d->raw, (unsigned long long)di.addr, di.taken);
      }
      if (di.marker == 1) in_region = true;
      if (di.marker == 2) in_region = false;
      if (pairs_n && in_region) {
        region_instr++;
        mix[op_name(di.d->op)]++;
        const Decoded* d = di.d;
        if (prev && prev->writes_int() &&
            ((d->rs1_k == RK_INT && d->rs1 == prev->rd) || (d->rs2_k == RK_INT && d->rs2 == prev->rd))) {
          const bool same_rd = d->writes_int() && d->rd == prev->rd;
          pairs[std::string(op_name(prev->op)) + "+" + op_name(d->op) + (same_rd ? " (rd overwritten)" : "")]++;
        }
        prev = d;
      }
    }
    if (pairs_n) {
      auto top = [&](const std::map<std::string, uint64_t>& m, const char* title) {
        std::vector<std::pair<uint64_t, std::string>> v;
        for (auto& kv : m) v.emplace_back(kv.second, kv.first);
        std::sort(v.rbegin(), v.rend());
        std::fprintf(stderr, "%s (region instructions %llu)\n", title, (unsigned long long)region_instr);
        for (int i = 0; i < pairs_n && i < (int)v.size(); i++)
          std::fprintf(stderr, "  %6.2f%%  %s\n", 100.0 * v[i].first / std::max<uint64_t>(1, region_instr),
                       v[i].second.c_str());
      };
      top(mix, "opcode mix");
      top(pairs, "dependent adjacent pairs");
    }
    std::fputs(iss.stdout_buf().c_str(), stderr);
    char buf[256];
    std::snprintf(buf, sizeof buf, "{\"bench\":\"%s\",\"instret\":%llu,\"exit_code\":%d,\"error\":\"%s\"}",
                  bench.c_str(), (unsigned long long)iss.instret(), iss.exit_code(), iss.error().c_str());
    out = buf;
    rc = iss.error().empty() ? 0 : 1;
  } else {
    std::vector<ThreadSpec> specs = {{&iss, elfs[0], stdin_text, bench, cfg.ff != 0, ram_base, ram_size}};
    std::unique_ptr<Iss> iss2;
    if (cfg.threads == 2) {
      iss2 = std::make_unique<Iss>(ram_base, ram_size);
      if (!iss2->load_elf(elfs[1], err)) { std::fprintf(stderr, "load: %s\n", err.c_str()); return 1; }
      iss2->set_stdin(stdin2);
      specs.push_back({iss2.get(), elfs[1], stdin2, bench2, ff2 != 0, ram_base, ram_size});
    }
    Core core(cfg, specs);
    const bool ok = core.run();
    out = core.result_json(cfg.threads > 1 ? bench + "+" + bench2 : bench);
    rc = ok ? 0 : 1;
  }
  if (json_out.empty()) std::cout << out << "\n";
  else {
    std::ofstream f(json_out);
    f << out << "\n";
  }
  return rc;
}
