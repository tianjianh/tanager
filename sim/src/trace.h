// Commit-trace records as the C++ side sees them: tg_trace_pkg::tr_rec_t and tr_wb_t
// (docs/spec/interfaces.md §5), plus the cycle and slot they arrived in.
#pragma once

#include <cstdint>
#include <functional>
#include <string>

#include "common.h"

namespace tg {

enum : uint8_t { TR_RETIRE = 0, TR_TRAP = 1, TR_IRQ = 2 };

struct tr_rec_t {
  uint64_t cycle = 0;
  unsigned slot = 0;
  uint8_t kind = TR_RETIRE;
  uint32_t hart = 0;
  uint8_t priv = 3;
  uint64_t pc = 0;
  uint32_t insn = 0;
  bool rvc = false;
  bool rd_we = false, rd_fp = false;
  uint8_t rd = 0;
  bool rd_deferred = false;
  uint32_t wb_tag = 0;
  uint64_t rd_value = 0;
  bool mem_st = false;
  uint64_t mem_vaddr = 0, mem_wdata = 0;
  uint8_t mem_size = 0;
  bool mmio_ld = false, nondet = false;
  bool mem_ld = false;        // v1.5: the instruction read memory; mem_vaddr and mem_size are the read's
  uint64_t cause = 0, tval = 0;
};

struct tr_wb_t {
  uint64_t cycle = 0;
  unsigned port = 0;
  uint32_t hart = 0, wb_tag = 0;
  bool rd_fp = false;
  uint8_t rd = 0;
  uint64_t value = 0;
};

inline const char* tr_kind_name(unsigned k) {
  return k == TR_RETIRE ? "retire" : k == TR_TRAP ? "trap" : k == TR_IRQ ? "irq" : "?";
}
inline char priv_char(unsigned p) { return p == 3 ? 'M' : p == 1 ? 'S' : p == 0 ? 'U' : '?'; }

// One line per record; `dis` turns an instruction into text (may be empty).
inline std::string format_rec(const tr_rec_t& r, const std::function<std::string(uint32_t)>& dis = {}) {
  std::string s = strfmt("%10llu h%u %c %-6s pc=%016llx", (unsigned long long)r.cycle, r.hart, priv_char(r.priv),
                         tr_kind_name(r.kind), (unsigned long long)r.pc);
  if (r.kind != TR_IRQ) {
    s += r.rvc ? strfmt(" (%04x)    ", r.insn & 0xffff) : strfmt(" (%08x)", r.insn);
    if (dis) s += strfmt(" %-28s", dis(r.insn).c_str());
  }
  if (r.kind == TR_RETIRE) {
    if (r.rd_we) {
      s += strfmt(" %c%-2u", r.rd_fp ? 'f' : 'x', r.rd);
      if (r.rd_deferred) s += strfmt(" <- (wb tag %u)", r.wb_tag);
      else s += strfmt(" <- %016llx", (unsigned long long)r.rd_value);
    }
    if (r.mem_st)
      s += strfmt(" mem[%016llx]/%u <- %016llx", (unsigned long long)r.mem_vaddr, 1u << r.mem_size,
                  (unsigned long long)r.mem_wdata);
    if (r.mem_ld && !r.mem_st)
      s += strfmt(" mem[%016llx]/%u read", (unsigned long long)r.mem_vaddr, 1u << r.mem_size);
    if (r.mmio_ld) s += " mmio";
    if (r.nondet) s += " nondet";
  } else {
    s += strfmt(" cause=%016llx", (unsigned long long)r.cause);
    if (r.kind == TR_TRAP) s += strfmt(" tval=%016llx", (unsigned long long)r.tval);
  }
  return s;
}

inline std::string format_wb(const tr_wb_t& w) {
  return strfmt("%10llu h%u wb     tag %u %c%-2u <- %016llx", (unsigned long long)w.cycle, w.hart, w.wb_tag,
                w.rd_fp ? 'f' : 'x', w.rd, (unsigned long long)w.value);
}

}  // namespace tg
