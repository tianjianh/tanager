// Cycle signatures for the cycle-identical check (verification.md §4.5): for each window of cycles,
// a hash of what the core drove that has meaning:
//   - the commit trace, each record and writeback with its cycle and slot or port;
//   - its TileLink ports: each channel's valid beat with its payload, and its ready on B and D in
//     the cycles the model offers a beat there.
// Fields without meaning are left out: data of a message that carries none, a store's bytes beyond
// its size, rd_value without rd_we. A rewrite that changes only don't-care bits is still identical.
// Two runs of one program with the same options have the same signature exactly when the core
// behaved the same, cycle by cycle (up to hash collisions).
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "tl.h"
#include "tlmodels.h"
#include "trace.h"

namespace tg {

struct sig_t {
  FILE* f = nullptr;            // --sig
  uint64_t window = 1024;       // --sig-window: cycles per line
  bool log_bus = false;         // --log-bus, from --log-from on: describe each event in bus_lines
  std::vector<std::string> bus_lines;

  // The current window, which began at cycle last_end
  uint64_t h_trace = 0, h_bus = 0, n_recs = 0, n_wbs = 0, n_bus = 0, last_end = 0;
  // What the model offers in the current cycle (registered DPI outputs): ready only counts then.
  bool d_offered[3] = {false, false, false}, b_offered = false;

  bool active() const { return f || log_bus; }

  static void mix(uint64_t& h, uint64_t x) {
    h ^= x;
    h *= 0xff51afd7ed558ccdull;
    h ^= h >> 32;
  }

  void rec(const tr_rec_t& r) {
    if (!f) return;
    uint64_t& h = h_trace;
    n_recs++;
    mix(h, 0x7265630000000000ull | (uint64_t(r.slot) << 32) | (uint64_t(r.kind) << 8) | r.priv);
    mix(h, r.cycle);
    mix(h, r.hart);
    mix(h, r.pc);
    if (r.kind != TR_IRQ) mix(h, (uint64_t(r.rvc) << 32) | (r.rvc ? r.insn & 0xffff : r.insn));
    if (r.kind == TR_RETIRE) {
      mix(h, (uint64_t(r.rd_we) << 3) | (uint64_t(r.mem_st) << 2) | (uint64_t(r.mmio_ld) << 1) | r.nondet);
      if (r.rd_we) {
        mix(h, (uint64_t(r.rd_fp) << 40) | (uint64_t(r.rd_deferred) << 32) | r.rd);
        mix(h, r.rd_deferred ? r.wb_tag : r.rd_value);
      }
      if (r.mem_st) {
        mix(h, r.mem_vaddr);
        mix(h, r.mem_wdata & size_mask(r.mem_size));
        mix(h, r.mem_size);
      }
    } else {
      mix(h, r.cause);
      if (r.kind == TR_TRAP) mix(h, r.tval);
    }
  }

  void wb(const tr_wb_t& w) {
    if (!f) return;
    n_wbs++;
    mix(h_trace, 0x7762000000000000ull | (uint64_t(w.port) << 32) | (uint64_t(w.rd_fp) << 8) | w.rd);
    mix(h_trace, w.cycle);
    mix(h_trace, (uint64_t(w.hart) << 32) | w.wb_tag);
    mix(h_trace, w.value);
  }

  // One bus event: `what` names it for --log-bus; v0..v4 are its fields.
  void bus(uint64_t now, const char* port, const char* what, uint64_t v0, uint64_t v1 = 0, uint64_t v2 = 0,
           uint64_t v3 = 0, uint64_t v4 = 0, const std::string& text = "") {
    if (f) {
      n_bus++;
      mix(h_bus, now);
      for (const char* p = port; *p; p++) mix(h_bus, uint8_t(*p));
      for (const char* p = what; *p; p++) mix(h_bus, uint8_t(*p));
      mix(h_bus, v0);
      mix(h_bus, v1);
      mix(h_bus, v2);
      mix(h_bus, v3);
      mix(h_bus, v4);
    }
    if (log_bus) bus_lines.push_back(strfmt("%10llu %-4s %s%s", (unsigned long long)now, port, what, text.c_str()));
  }

  void a_beat(uint64_t now, const char* port, const tl_a_t& a) {
    bool data = a.opcode <= A_LOGIC;  // Put*, Arithmetic and Logical carry data
    uint64_t d0 = data ? a.data.d[0] : 0, d1 = data ? a.data.d[1] : 0;
    bus(now, port, "A", (uint64_t(a.opcode) << 48) | (uint64_t(a.param) << 40) | (uint64_t(a.size) << 32) | a.source,
        a.address, uint64_t(a.mask) | (uint64_t(data && a.corrupt) << 16), d0, d1,
        log_bus ? strfmt(" %s param=%u size=%u source=%u address=%016llx mask=%04x%s", a_op_name(a.opcode), a.param,
                         a.size, a.source, (unsigned long long)a.address, a.mask,
                         data ? strfmt(" data=%016llx_%016llx%s", (unsigned long long)d1, (unsigned long long)d0,
                                       a.corrupt ? " corrupt" : "").c_str() : "")
                : std::string());
  }

  void c_beat(uint64_t now, const char* port, const tl_c_t& c) {
    bool data = c.opcode == C_PROBE_ACK_DATA || c.opcode == C_RELEASE_DATA;
    uint64_t d0 = data ? c.data.d[0] : 0, d1 = data ? c.data.d[1] : 0;
    bus(now, port, "C", (uint64_t(c.opcode) << 48) | (uint64_t(c.param) << 40) | (uint64_t(c.size) << 32) | c.source,
        c.address, uint64_t(data && c.corrupt), d0, d1,
        log_bus ? strfmt(" %s param=%u size=%u source=%u address=%016llx%s", c_op_name(c.opcode), c.param, c.size,
                         c.source, (unsigned long long)c.address,
                         data ? strfmt(" data=%016llx_%016llx%s", (unsigned long long)d1, (unsigned long long)d0,
                                       c.corrupt ? " corrupt" : "").c_str() : "")
                : std::string());
  }

  void ready(uint64_t now, const char* port, const char* what, bool r) {
    bus(now, port, what, r, 0, 0, 0, 0, log_bus ? std::string(r ? " taken" : " refused") : std::string());
  }

  // The core's side of a TL-UL port (0: l1i, 2: mmio) in this cycle.
  void ul(uint64_t now, int port, const ul_in_t& in) {
    if (!active()) return;
    const char* name = port == 0 ? "l1i" : "mmio";
    if (in.a_valid) a_beat(now, name, in.a);
    if (d_offered[port]) ready(now, name, "D", in.d_ready);
  }

  // The core's side of the TL-C port (l1d) in this cycle.
  void c(uint64_t now, const c_in_t& in) {
    if (!active()) return;
    if (in.a_valid) a_beat(now, "l1d", in.a);
    if (b_offered) ready(now, "l1d", "B", in.b_ready);
    if (in.c_valid) c_beat(now, "l1d", in.c);
    if (d_offered[1]) ready(now, "l1d", "D", in.d_ready);
    if (in.e_valid) bus(now, "l1d", "E", in.e_sink, 0, 0, 0, 0, log_bus ? strfmt(" sink=%u", in.e_sink) : "");
  }

  void merr(uint64_t now, int m) {
    if (active() && m) bus(now, "core", "merr", uint64_t(m), 0, 0, 0, 0, log_bus ? strfmt(" %d", m) : "");
  }

  void header() {
    if (f) fprintf(f, "# tg_vsim cycle signature v1, %llu-cycle windows: end cycle, records, writebacks, trace hash, "
                      "bus events, bus hash\n", (unsigned long long)window);
  }

  // Closes the window that ends before cycle `end`.
  void line(uint64_t end) {
    if (!f) return;
    fprintf(f, "%llu %llu %llu %016llx %llu %016llx\n", (unsigned long long)end, (unsigned long long)n_recs,
            (unsigned long long)n_wbs, (unsigned long long)h_trace, (unsigned long long)n_bus,
            (unsigned long long)h_bus);
    h_trace = h_bus = n_recs = n_wbs = n_bus = 0;
    last_end = end;
  }

  // After cycle `now`: a full window ends here.
  void cycle_end(uint64_t now) {
    if (f && (now + 1) % window == 0) line(now + 1);
  }

  // The run ended after cycle `last` (TG-RESULT's cycles).
  void finish(uint64_t last, uint64_t instret, const char* status, int code) {
    if (!f) return;
    if (last + 1 > last_end) line(last + 1);
    fprintf(f, "end cycles=%llu instret=%llu status=%s code=%d\n", (unsigned long long)last,
            (unsigned long long)instret, status, code);
    fclose(f);
    f = nullptr;
  }
};

}  // namespace tg
