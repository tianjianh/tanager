// Scratch measurement (verif-2, 2026-10-21; not for main): where a Linux boot runs untranslated, M-mode or bare,
// from the commit trace and Spike's state at each record (tanager-lockstep --profile=FILE).
#pragma once

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <map>
#include <string>

#include "common.h"
#include "lockstep.h"
#include "trace.h"

namespace tg {

struct mode_profile_t {
  static constexpr const char* PHASE[3] = {"boot ROM", "OpenSBI cold boot", "Linux (after the first S-mode record)"};
  static constexpr const char* FCLS[3] = {"M-mode", "bare S/U", "translated"};
  static constexpr const char* DCLS[4] = {"M-mode (effective)", "bare S/U", "M-mode with MPRV, translated", "translated"};
  struct acc_t {
    uint64_t insns = 0, traps = 0, irqs = 0, cycles = 0, blocks = 0;
  };
  acc_t ph[3][3] = {};          // [phase][fetch class]
  uint64_t data[3][4] = {};     // [phase][data class]
  struct entry_t {
    uint64_t n = 0, insns = 0, cycles = 0, max_insns = 0, max_cycles = 0, min_insns = ~0ull, min_cycles = ~0ull;
  };
  std::map<std::string, entry_t> entries;
  int phase = 0;
  bool in_entry = false, any = false;
  std::string key;
  uint64_t e_start = 0, e_insns = 0, last_cycle = 0, last_block = ~0ull, records = 0;
  // Cycles in which an untranslated new fetch block and an untranslated data access both retire (a proxy: the trace
  // shows retirement, not when the checks happen)
  uint64_t cur_cycle = ~0ull, both = 0, fetch_only = 0, data_only = 0;
  bool cyc_fetch = false, cyc_data = false;

  void end_cycle() {
    if (cyc_fetch && cyc_data) both++;
    else if (cyc_fetch) fetch_only++;
    else if (cyc_data) data_only++;
    cyc_fetch = cyc_data = false;
  }

  static std::string entry_key(const tr_rec_t& r, const lockstep_t::hart_mode_t& m) {
    if (r.kind == TR_IRQ) {
      const unsigned c = unsigned(r.cause & 63);
      return c == 3 ? "M software interrupt" : c == 7 ? "M timer interrupt" : c == 11 ? "M external interrupt"
                                                     : strfmt("interrupt %u", c);
    }
    switch (r.cause) {
      case 9: return strfmt("SBI ecall ext 0x%" PRIx64 " fid %" PRIu64, m.a7, m.a6);
      case 8: return strfmt("U ecall a7=0x%" PRIx64, m.a7);
      case 2: return strfmt("illegal instruction %08x", r.insn);
      case 4: return "misaligned load";
      case 6: return "misaligned store/AMO";
      default: return strfmt("trap cause %" PRIu64, r.cause);
    }
  }

  void record(const tr_rec_t& r, const lockstep_t::hart_mode_t& b, const lockstep_t::hart_mode_t& a) {
    records++;
    if (phase == 0 && r.pc >= 0x80000000ull) phase = 1;
    if (phase == 1 && b.priv == 1) phase = 2;
    if (r.cycle != cur_cycle) {
      if (cur_cycle != ~0ull) end_cycle();
      cur_cycle = r.cycle;
    }
    const int fc = b.priv == 3 ? 0 : !b.satp_on ? 1 : 2;
    acc_t& x = ph[phase][fc];
    if (any && r.cycle >= last_cycle) x.cycles += r.cycle - last_cycle;
    last_cycle = r.cycle;
    any = true;
    if (r.kind == TR_RETIRE) x.insns++;
    else if (r.kind == TR_TRAP) x.traps++;
    else x.irqs++;
    if (r.kind != TR_IRQ && (r.pc >> 4) != last_block) {
      x.blocks++;
      last_block = r.pc >> 4;
      if (fc < 2) cyc_fetch = true;
    }
    if (r.kind == TR_RETIRE && (r.mem_ld || r.mem_st || r.mmio_ld)) {
      const unsigned eff = b.priv == 3 && b.mprv ? b.mpp : b.priv;
      const int dc = eff == 3 ? 0 : !b.satp_on ? 1 : b.priv == 3 ? 2 : 3;
      data[phase][dc]++;
      if (dc < 2) cyc_data = true;
    }
    // M-mode entries once Linux runs: from the record that enters M-mode to the next one outside it
    if (phase == 2) {
      if (in_entry && b.priv != 3) {
        entry_t& e = entries[key];
        const uint64_t cyc = r.cycle - e_start;
        e.n++;
        e.insns += e_insns;
        e.cycles += cyc;
        e.max_insns = std::max(e.max_insns, e_insns);
        e.min_insns = std::min(e.min_insns, e_insns);
        e.max_cycles = std::max(e.max_cycles, cyc);
        e.min_cycles = std::min(e.min_cycles, cyc);
        in_entry = false;
      }
      if (!in_entry && b.priv != 3 && a.priv == 3) {
        in_entry = true;
        key = entry_key(r, b);
        e_start = r.cycle;
        e_insns = 0;
      } else if (in_entry && b.priv == 3 && r.kind == TR_RETIRE) {
        e_insns++;
      }
    }
  }

  void dump(FILE* f) const {
    fprintf(f, "records %" PRIu64 "\n", records);
    uint64_t tb[3] = {}, td[4] = {}, tc[3] = {}, ti[3] = {};
    for (int p = 0; p < 3; p++) {
      uint64_t cyc = 0, ins = 0, blk = 0;
      for (int c = 0; c < 3; c++) cyc += ph[p][c].cycles, ins += ph[p][c].insns, blk += ph[p][c].blocks;
      fprintf(f, "\n== %s: %" PRIu64 " instructions, %" PRIu64 " cycles, %" PRIu64 " fetch blocks\n", PHASE[p], ins, cyc, blk);
      for (int c = 0; c < 3; c++) {
        const acc_t& x = ph[p][c];
        if (!x.insns && !x.cycles && !x.traps && !x.irqs) continue;
        fprintf(f, "  fetch %-10s %13" PRIu64 " insns %13" PRIu64 " cycles %13" PRIu64 " blocks  (traps %" PRIu64 ", interrupts %" PRIu64 ")\n",
                FCLS[c], x.insns, x.cycles, x.blocks, x.traps, x.irqs);
        tb[c] += x.blocks, tc[c] += x.cycles, ti[c] += x.insns;
      }
      for (int d = 0; d < 4; d++) {
        if (data[p][d]) fprintf(f, "  data  %-28s %13" PRIu64 "\n", DCLS[d], data[p][d]);
        td[d] += data[p][d];
      }
    }
    const uint64_t ab = tb[0] + tb[1] + tb[2], ad = td[0] + td[1] + td[2] + td[3], ac = tc[0] + tc[1] + tc[2];
    const uint64_t ai = ti[0] + ti[1] + ti[2];
    auto pct = [](uint64_t a, uint64_t b) { return b ? 100.0 * double(a) / double(b) : 0.0; };
    fprintf(f, "\n== Whole run\n");
    fprintf(f, "  instructions: M %.3f%%, bare %.3f%%, together %.3f%% of %" PRIu64 "\n", pct(ti[0], ai), pct(ti[1], ai),
            pct(ti[0] + ti[1], ai), ai);
    fprintf(f, "  cycles:       M %.3f%%, bare %.3f%%, together %.3f%% of %" PRIu64 "\n", pct(tc[0], ac), pct(tc[1], ac),
            pct(tc[0] + tc[1], ac), ac);
    fprintf(f, "  fetch blocks: M %.3f%%, bare %.3f%%, together %.3f%% of %" PRIu64 "\n", pct(tb[0], ab), pct(tb[1], ab),
            pct(tb[0] + tb[1], ab), ab);
    fprintf(f, "  data:         M %.3f%%, bare %.3f%%, together %.3f%% of %" PRIu64 " (MPRV translated %" PRIu64 ")\n",
            pct(td[0], ad), pct(td[1], ad), pct(td[0] + td[1], ad), ad, td[2]);
    fprintf(f, "  cycles retiring an untranslated new fetch block and an untranslated data access: %" PRIu64
               "; a new block alone %" PRIu64 "; a data access alone %" PRIu64 "\n", both, fetch_only, data_only);
    fprintf(f, "\n== M-mode entries after Linux starts (instructions in M-mode; cycles from the entering record to the "
               "next outside M-mode)\n");
    uint64_t n = 0, ins = 0, cyc = 0;
    for (auto& [k, e] : entries) n += e.n, ins += e.insns, cyc += e.cycles;
    fprintf(f, "  all: %" PRIu64 " entries, %" PRIu64 " instructions, %" PRIu64 " cycles\n", n, ins, cyc);
    for (auto& [k, e] : entries)
      fprintf(f, "  %-44s %7" PRIu64 " entries  insns mean %7.1f min %6" PRIu64 " max %7" PRIu64
                 "  cycles mean %8.1f min %7" PRIu64 " max %8" PRIu64 "  total %" PRIu64 " insns %" PRIu64 " cycles\n",
              k.c_str(), e.n, double(e.insns) / double(e.n), e.min_insns, e.max_insns, double(e.cycles) / double(e.n),
              e.min_cycles, e.max_cycles, e.insns, e.cycles);
    if (in_entry) fprintf(f, "  (an entry still open: %s, %" PRIu64 " instructions so far)\n", key.c_str(), e_insns);
  }
};

}  // namespace tg
