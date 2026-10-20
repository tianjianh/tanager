// DPI functions called by sim/tb/tg_tb_top.sv once per port per rising edge
// (docs/spec/verification.md §2.2). Including the generated header checks these definitions
// against the SystemVerilog import declarations.
#include <cstring>

#include "Vtg_tb_top__Dpi.h"
#include "tb.h"

namespace tg {
tb_t& tb() {
  static tb_t t;
  return t;
}
}  // namespace tg

using namespace tg;

static void get_beat(const svBitVecVal* v, beat_t& b) {
  b.d[0] = uint64_t(v[0]) | (uint64_t(v[1]) << 32);
  b.d[1] = uint64_t(v[2]) | (uint64_t(v[3]) << 32);
}

static void put_beat(svBitVecVal* v, const beat_t& b) {
  v[0] = uint32_t(b.d[0]);
  v[1] = uint32_t(b.d[0] >> 32);
  v[2] = uint32_t(b.d[1]);
  v[3] = uint32_t(b.d[1] >> 32);
}

static void get_a(tl_a_t& a, int opcode, int param, int size, int source, long long address, const svBitVecVal* mask,
                  const svBitVecVal* data, svBit corrupt) {
  a.opcode = uint8_t(opcode);
  a.param = uint8_t(param);
  a.size = uint8_t(size);
  a.source = uint32_t(source);
  a.address = uint64_t(address);
  a.mask = uint16_t(mask[0]);
  get_beat(data, a.data);
  a.corrupt = corrupt;
}

static void put_d(const tl_d_t& d, int* opcode, int* param, int* size, int* source, int* sink, svBit* denied,
                  svBitVecVal* data, svBit* corrupt) {
  *opcode = d.opcode;
  *param = d.param;
  *size = d.size;
  *source = int(d.source);
  *sink = int(d.sink);
  *denied = d.denied;
  put_beat(data, d.data);
  *corrupt = d.corrupt;
}

extern "C" void tg_dpi_config(const char* cfg_name, int commit_width, int num_threads, int core_id, int hart_w,
                              int wb_tag_w, int trace_wb_ports, int pa_w, int l1i_mshrs, int l1d_mshrs,
                              int llt_entries, int trace_stall_headroom, int pmp_entries) {
  hw_cfg_t& h = tb().hw;
  h.known = true;
  h.cfg_name = cfg_name;
  h.commit_width = unsigned(commit_width);
  h.num_threads = unsigned(num_threads);
  h.core_id = unsigned(core_id);
  h.hart_w = unsigned(hart_w);
  h.wb_tag_w = unsigned(wb_tag_w);
  h.trace_wb_ports = unsigned(trace_wb_ports);
  h.pa_w = unsigned(pa_w);
  h.l1i_mshrs = unsigned(l1i_mshrs);
  h.l1d_mshrs = unsigned(l1d_mshrs);
  h.llt_entries = unsigned(llt_entries);
  h.trace_stall_headroom = unsigned(trace_stall_headroom);
  h.pmp_entries = unsigned(pmp_entries);
}

extern "C" long long tg_dpi_boot_addr() { return (long long)tb().boot_addr; }

extern "C" void tg_dpi_tl_ul(int port, svBit a_valid, int a_opcode, int a_param, int a_size, int a_source,
                             long long a_address, const svBitVecVal* a_mask, const svBitVecVal* a_data,
                             svBit a_corrupt, svBit d_ready, svBit* a_ready_n, svBit* d_valid_n, int* d_opcode_n,
                             int* d_param_n, int* d_size_n, int* d_source_n, int* d_sink_n, svBit* d_denied_n,
                             svBitVecVal* d_data_n, svBit* d_corrupt_n) {
  ul_in_t in;
  in.a_valid = a_valid;
  get_a(in.a, a_opcode, a_param, a_size, a_source, a_address, a_mask, a_data, a_corrupt);
  in.d_ready = d_ready;
  tb_t& t = tb();
  t.sig.ul(t.ctx.now, port, in);
  ul_out_t out;
  if (port == 0) t.l1i.cycle(in, out);
  else t.mmio.cycle(in, out);
  t.sig.d_offered[port] = out.d_valid;
  *a_ready_n = out.a_ready;
  *d_valid_n = out.d_valid;
  put_d(out.d, d_opcode_n, d_param_n, d_size_n, d_source_n, d_sink_n, d_denied_n, d_data_n, d_corrupt_n);
}

extern "C" void tg_dpi_tl_c(svBit a_valid, int a_opcode, int a_param, int a_size, int a_source, long long a_address,
                            const svBitVecVal* a_mask, const svBitVecVal* a_data, svBit a_corrupt, svBit b_ready,
                            svBit c_valid, int c_opcode, int c_param, int c_size, int c_source, long long c_address,
                            const svBitVecVal* c_data, svBit c_corrupt, svBit d_ready, svBit e_valid, int e_sink,
                            svBit* a_ready_n, svBit* b_valid_n, int* b_opcode_n, int* b_param_n, int* b_size_n,
                            int* b_source_n, long long* b_address_n, svBit* c_ready_n, svBit* d_valid_n,
                            int* d_opcode_n, int* d_param_n, int* d_size_n, int* d_source_n, int* d_sink_n,
                            svBit* d_denied_n, svBitVecVal* d_data_n, svBit* d_corrupt_n, svBit* e_ready_n) {
  c_in_t in;
  in.a_valid = a_valid;
  get_a(in.a, a_opcode, a_param, a_size, a_source, a_address, a_mask, a_data, a_corrupt);
  in.b_ready = b_ready;
  in.c_valid = c_valid;
  in.c.opcode = uint8_t(c_opcode);
  in.c.param = uint8_t(c_param);
  in.c.size = uint8_t(c_size);
  in.c.source = uint32_t(c_source);
  in.c.address = uint64_t(c_address);
  get_beat(c_data, in.c.data);
  in.c.corrupt = c_corrupt;
  in.d_ready = d_ready;
  in.e_valid = e_valid;
  in.e_sink = uint32_t(e_sink);
  tb_t& t = tb();
  t.sig.c(t.ctx.now, in);
  c_out_t out;
  t.l1d.cycle(in, out);
  t.sig.b_offered = out.b_valid;
  t.sig.d_offered[1] = out.d_valid;
  *a_ready_n = out.a_ready;
  *b_valid_n = out.b_valid;
  *b_opcode_n = out.b.opcode;
  *b_param_n = out.b.param;
  *b_size_n = out.b.size;
  *b_source_n = int(out.b.source);
  *b_address_n = (long long)out.b.address;
  *c_ready_n = out.c_ready;
  *d_valid_n = out.d_valid;
  put_d(out.d, d_opcode_n, d_param_n, d_size_n, d_source_n, d_sink_n, d_denied_n, d_data_n, d_corrupt_n);
  *e_ready_n = out.e_ready;
}

extern "C" void tg_dpi_irq(int merr, int* mei_n, int* sei_n, int* mti_n, int* msi_n, int* ssi_n, long long* mtime_n) {
  tb_t& t = tb();
  model_ctx_t& ctx = t.ctx;
  t.sig.merr(ctx.now, merr);
  if (merr) {
    t.merr_seen |= uint32_t(merr);
    t.merr_pulses++;
  }
  clint_t& c = t.mmio.clint;
  c.tick(ctx.cfg.mtime_div);
  unsigned nt = t.hw.num_threads;
  if (t.mei_until.size() != nt) { t.mei_until.assign(nt, 0); t.sei_until.assign(nt, 0); }
  // Random external-interrupt pulses (--irq-rand): 1..200 cycles long.
  if (ctx.rng.permille(ctx.cfg.irq_rand)) {
    unsigned h = unsigned(ctx.rng.below(nt));
    auto& until = ctx.rng.below(2) ? t.mei_until : t.sei_until;
    until[h] = ctx.now + 1 + ctx.rng.below(200);
  }
  int mei = 0, sei = 0, mti = 0, msi = 0, ssi = 0;
  for (unsigned i = 0; i < nt; i++) {
    unsigned hart = t.hw.core_id * nt + i;
    if (t.mei_until[i] > ctx.now || (t.mmio.sig_lines >> 11 & 1)) mei |= 1 << i;
    if (t.sei_until[i] > ctx.now || (t.mmio.sig_lines >> 9 & 1)) sei |= 1 << i;
    if (t.mmio.sig_lines >> 1 & 1) ssi |= 1 << i;
    if (hart < c.mtimecmp.size() && c.mtime >= c.mtimecmp[hart]) mti |= 1 << i;
    if (hart < c.msip.size() && c.msip[hart]) msi |= 1 << i;
  }
  *mei_n = mei;
  *sei_n = sei;
  *mti_n = mti;
  *msi_n = msi;
  *ssi_n = ssi;
  *mtime_n = (long long)c.mtime;
}

extern "C" void tg_dpi_trace(int slot, int kind, int hart, int priv, long long pc, int insn, svBit rvc, svBit rd_we,
                             svBit rd_fp, int rd, svBit rd_deferred, int wb_tag, long long rd_value, svBit mem_st,
                             long long mem_vaddr, long long mem_wdata, int mem_size, svBit mmio_ld, svBit nondet,
                             svBit mem_ld, long long cause, long long tval) {
  tr_rec_t r;
  r.cycle = tb().ctx.now;
  r.slot = unsigned(slot);
  r.kind = uint8_t(kind);
  r.hart = uint32_t(hart);
  r.priv = uint8_t(priv);
  r.pc = uint64_t(pc);
  r.insn = uint32_t(insn);
  r.rvc = rvc;
  r.rd_we = rd_we;
  r.rd_fp = rd_fp;
  r.rd = uint8_t(rd);
  r.rd_deferred = rd_deferred;
  r.wb_tag = uint32_t(wb_tag);
  r.rd_value = uint64_t(rd_value);
  r.mem_st = mem_st;
  r.mem_vaddr = uint64_t(mem_vaddr);
  r.mem_wdata = uint64_t(mem_wdata);
  r.mem_size = uint8_t(mem_size);
  r.mmio_ld = mmio_ld;
  r.nondet = nondet;
  r.mem_ld = mem_ld;
  r.cause = uint64_t(cause);
  r.tval = uint64_t(tval);
  tb().recs.push_back(r);
}

// Called once per cycle after the cycle's records: the sink's checks, and trace_stall_i for the next cycle.
extern "C" svBit tg_dpi_trace_stall() {
  tb_t& t = tb();
  unsigned deferred = 0;
  for (auto& r : t.recs) deferred += r.rd_we && r.rd_deferred;
  std::string err;
  if (!t.sink.cycle(t.ctx.now, unsigned(t.recs.size()), deferred, unsigned(t.wbs.size()), err)) t.ctx.fail(err);
  return t.sink.stall;
}

extern "C" void tg_dpi_trace_wb(int port, int hart, int wb_tag, svBit rd_fp, int rd, long long value) {
  tr_wb_t w;
  w.cycle = tb().ctx.now;
  w.port = unsigned(port);
  w.hart = uint32_t(hart);
  w.wb_tag = uint32_t(wb_tag);
  w.rd_fp = rd_fp;
  w.rd = uint8_t(rd);
  w.value = uint64_t(value);
  tb().wbs.push_back(w);
}
