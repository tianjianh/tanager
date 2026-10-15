// Verilator testbench for the FP back end: tg_fp_exec with tg_fprf and tg_fpu (docs/spec/fpu.md,
// "Core integration"). A model of the core's side of port P4 (scheduler with the woken vector,
// physical registers, ROB and LLT pools, the 16 wakeup tags of AR-1, rename credits, the load
// path and the bank-1 arbiter) drives operation streams and checks every F0 write, completion,
// wakeup and integer result against the SoftFloat-based reference, with exact cycles. Exits
// non-zero on failure.
//
//   tb_fpx rand [-seed N] [-n N] [-flush N] [-ret PCT] [-ready PCT] [-tags N]
//       random FP operations with dependencies, loads, flushes every ~N cycles (0: none),
//       early retirement of divides (PCT per cycle), B1 back-pressure (the arbiter claims the
//       queue head with PCT per cycle and writes it 1-4 cycles later), N wakeup tags (default
//       16; fewer exhaust the pool, so dispatch waits and tags are reused at once)
//   tb_fpx tf <function> [-rm N] [-n N]
//       TestFloat vectors (testfloat_gen output on stdin), operands through F1 loads and the
//       integer source port, results through F0 and the B1 queue
#include <verilated.h>
#include "Vtb_fpx_top.h"

#include <algorithm>
#include <cstdarg>
#include <functional>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <random>
#include <string>
#include <type_traits>
#include <vector>

#include "fpu_ref.h"
#include "operands.h"
#include "tf_table.h"

#if !defined(FMA_LAT) || !defined(FMISC_LAT) || !defined(ROB_ENTRIES) || !defined(LLT_ENTRIES) || \
    !defined(TID_W) || !defined(FP_PREGS) || !defined(INT_PREGS)
#error "build with the configuration constants (tests/unit/fpu/Makefile, target tbx)"
#endif

static constexpr int clog2(int n) { int w = 0; while ((1 << w) < n) w++; return w; }
static constexpr int NROB  = ROB_ENTRIES;
static constexpr int NLLT  = LLT_ENTRIES;
static constexpr int NT    = 1 << TID_W;
static constexpr int NFP   = FP_PREGS;
static constexpr int FPIDX = clog2(FP_PREGS);
static constexpr int PIDX  = clog2(INT_PREGS);
static constexpr int ROBI  = clog2(ROB_ENTRIES);
static constexpr int FDIVQ = 4;
static constexpr int FPIQ  = 4;
static constexpr int NINT  = 64;                    // integer pregs the bench uses (bank B1)
static constexpr int NTAG  = 16;                    // wakeup tags (AR-1)
static constexpr uint64_t NEVER = ~0ull;

// ---- Bit access on Verilator ports of any width ----
template <typename T> static bool bit_of(const T &w, int i) {
  if constexpr (std::is_integral_v<T>) return (w >> i) & 1;
  else return (w[i >> 5] >> (i & 31)) & 1;
}

enum { U_FMA = 0, U_MISC = 1, U_DIV = 2 };

struct Op {
  long id = 0;
  int tid = 0, rob = 0, robi = 0, wid = 0, llt = -1;   // rob: index plus wrap bit
  int tag = -1;                      // wakeup tag (FMA, FMISC with an FP destination)
  int unit = 0;
  bool fp_dst = true, dst_en = true;
  int dst = 0;                       // F0 index, or integer preg index
  int src[3] = {0, 0, 0};            // FP tags {bank, idx}; src[0] is an integer preg when !src1_fp
  bool src1_fp = true;
  ref::Req req{};
  ref::Resp exp{};
  uint64_t sel = 0, wake = NEVER;
  bool live = true, retired = false, done = false;
  bool free_isrc = false;            // the integer source register is released when this completes
  bool srcs_settled = false;         // no source had a producer in flight when it was selected
  const char *src_name = "rand";
};

struct FReg {                         // an FP physical register as the bench sees it
  bool busy = false;                  // allocated (pending result or holding a value)
  bool known = false;                 // its value is known (val)
  uint64_t val = 0;
  uint64_t avail = NEVER;             // first select cycle a consumer may use it
  uint64_t in_rf = NEVER;             // first cycle the register file holds it
  uint64_t last_use = 0;              // EX0 cycle of its last consumer
  long prod = -1;                     // producing op id while pending
  int tid = 0;                        // the producer's thread
  int pins = 0;                       // operands of vectors not yet issued: not recycled
};

class Bench {
 public:
  Vtb_fpx_top *top;
  std::mt19937_64 rng;
  ops::Gen gen;
  uint64_t cycle = 0;
  long checked = 0, errors = 0, issued = 0, flushes = 0, rets = 0, dead_ops = 0;
  long tag_allocs = 0, tag_waits = 0, fpi_claims = 0, fpi_kills = 0;
  uint64_t last_progress = 0;
  // Knobs
  int flush_every = 0, ret_pct = 0, ready_pct = 100;
  // State
  FReg fr[2][NFP];
  uint64_t ival[NINT];
  bool ibusy[NINT];
  uint64_t iavail[NINT];
  std::map<long, Op> ops;             // in flight (by id)
  long next_id = 1;
  bool rob_busy[NROB] = {};
  bool llt_busy[NLLT] = {};
  int nfx = 0;                        // fixed-latency wakeup columns (tags), then the LLT columns
  int ntag = 0;                       // tags in use by the bench: min(NTAG, nfx)
  bool tag_busy[NTAG] = {};
  uint64_t tag_free_at[NTAG] = {};    // rename frees a tag 2 cycles after its producer's F0 write
  std::vector<long> wid_owner;        // op id waiting for this wakeup column (-1: none)
  int fdiv_cnt = 0, fpi_cnt = 0;
  std::deque<long> fpi_exp;           // integer results in queue order (ids; dead ones included)
  std::map<uint64_t, long> f0_sched;  // cycle -> op expected to write F0 (FMA, FMISC FP)
  // Pipeline of the bench's own inputs
  bool have_iss = false;              // an op selected last cycle, presented this cycle
  long iss_id = 0;
  // Bank-1 arbiter: a claimed queue head, written (fpi_ready) fpi_left cycles later
  bool fpi_claimed = false;
  long fpi_claim_id = 0;
  int fpi_left = 0;
  uint64_t fpi_snap[8] = {};
  struct Ld { bool v = false; int idx = 0; bool single = false; uint64_t raw = 0; };
  Ld ld_new, ld_m2, ld_wr;            // started this cycle, announced this cycle, writing this cycle
  int tr_chk_idx = -1;                // F0 index written last cycle: checked through the trace port
  uint64_t tr_chk_val = 0;
  long tr_chk_id = 0;

  Bench(uint64_t seed) : rng(seed), gen(rng) {
    top = new Vtb_fpx_top;
    top->eval();
    nfx = top->nfx_o;
    ntag = std::min(NTAG, nfx);
    wid_owner.assign(nfx + NLLT, -1);
    for (int i = 0; i < NINT; i++) { ival[i] = gen.integer(); ibusy[i] = false; iavail[i] = 0; }
  }

  int r(int n) { return (int)(rng() % (uint64_t)n); }
  bool chance(int pct) { return r(100) < pct; }

  void fail(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
    errors++;
    if (errors <= 20) {
      va_list ap; va_start(ap, fmt);
      printf("ERROR cycle %llu: ", (unsigned long long)cycle);
      vprintf(fmt, ap); printf("\n");
      va_end(ap);
    }
  }

  // ---- Clocking ----
  void reset() {
    top->clk = 0; top->rst = 1;
    clear_inputs();
    for (int i = 0; i < 4; i++) { top->clk = 1; top->eval(); top->clk = 0; top->eval(); }
    top->rst = 0;
    // Reset sequence: zero into a few registers of F0 through the init port (the core's sequence
    // writes only F0), and of F1 through the load write port
    for (int b = 0; b < 2; b++) {
      for (int i = 0; i < 8; i++) {
        if (b == 0) { top->init_we = 1; top->init_bank = 0; top->init_idx = i; }
        else        { top->fld_valid = 1; top->fld_idx = i; top->fld_data = 0; }
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
        FReg &f = fr[b][i];
        f.busy = true; f.known = true; f.val = 0; f.avail = 0; f.in_rf = 0;
      }
    }
    top->init_we = 0; top->fld_valid = 0;
  }
  void clear_inputs() {
    top->flush = 0; top->flush_tid = 0; top->init_we = 0;
    top->iss_valid = 0; top->fld_m2_will = 0; top->fld_valid = 0;
    top->fpi_ready = 0; top->fdiv_ret_valid = 0; top->fsd_tag = 0; top->tr_tag = 0;
    top->isrc_data = 0;
  }

  // ---- Allocation ----
  int alloc_free(bool *busy, int n) {
    int start = r(n);
    for (int k = 0; k < n; k++) { int i = (start + k) % n; if (!busy[i]) return i; }
    return -1;
  }
  int alloc_tag() {
    int start = r(ntag);
    for (int k = 0; k < ntag; k++) {
      int i = (start + k) % ntag;
      if (!tag_busy[i] && tag_free_at[i] <= cycle) return i;
    }
    return -1;
  }
  int alloc_f(int bank) {
    int start = r(NFP);
    for (int k = 0; k < NFP; k++) {
      int i = (start + k) % NFP;
      if (!fr[bank][i].busy) return i;
    }
    return -1;
  }
  // An FP source for a consumer of thread tid selected now: available, and either settled or
  // produced by the same thread (another thread's result can be squashed under it), sometimes
  // just woken (bypass levels)
  int pick_src(int tid) {
    std::vector<int> fresh, any;
    for (int b = 0; b < 2; b++)
      for (int i = 0; i < NFP; i++) {
        const FReg &f = fr[b][i];
        if (f.busy && f.known && f.avail <= cycle && (f.prod < 0 || f.tid == tid)) {
          int tag = (b << FPIDX) | i;
          any.push_back(tag);
          if (f.avail + 2 >= cycle) fresh.push_back(tag);
        }
      }
    if (any.empty()) return -1;
    if (!fresh.empty() && chance(60)) return fresh[r((int)fresh.size())];
    return any[r((int)any.size())];
  }
  FReg &freg(int tag) { return fr[(tag >> FPIDX) & 1][tag & (NFP - 1)]; }

  // ---- Free registers nobody will read again ----
  void recycle() {
    int live = 0;
    for (int b = 0; b < 2; b++) for (int i = 0; i < NFP; i++) if (fr[b][i].busy) live++;
    if (live < NFP && !chance(10)) return;
    for (int t = 0; t < 4; t++) {
      int b = r(2), i = r(NFP);
      FReg &f = fr[b][i];
      if (f.busy && f.known && f.in_rf < cycle && f.last_use + 2 < cycle && f.prod < 0 && f.pins == 0) f = FReg{};
    }
  }

  // ---- Building an operation ----
  bool make_op(Op &o, const ref::Req *fixed, const int *fsrc, int nfsrc, int isrc_preg) {
    // o.req.op/fmt/... set by the caller (random) or from a vector (fixed)
    if (fixed) o.req = *fixed;
    const int op = o.req.op;
    o.unit = ref::unit_of(op);
    o.fp_dst = !(op == ref::FEQ || op == ref::FLT || op == ref::FLE || op == ref::FCLASS ||
                 op == ref::FCVT_I_F || op == ref::FMV_X_F);
    o.src1_fp = !(op == ref::FCVT_F_I || op == ref::FMV_F_X);
    // Sources
    int nsrc = (op == ref::FSQRT || op == ref::FCVT_F_F || op == ref::FCVT_F_I || op == ref::FCVT_I_F ||
                op == ref::FCLASS || op == ref::FMV_X_F || op == ref::FMV_F_X) ? 1
             : (op >= ref::FMADD && op <= ref::FNMADD) ? 3 : 2;
    int used[3] = {0, 0, 0};
    for (int k = 0; k < 3; k++) {
      if (k == 0 && !o.src1_fp) continue;
      int t;
      if (fsrc) t = fsrc[std::min(k, nfsrc - 1)];
      else t = pick_src(o.tid);
      if (t < 0) return false;
      o.src[k] = t;
      used[k] = k < nsrc;
    }
    if (!o.src1_fp) {
      int ip = isrc_preg;
      if (ip < 0) {
        for (int t = 0; t < 8 && ip < 0; t++) { int i = r(NINT); if (!ibusy[i] && iavail[i] <= cycle) ip = i; }
        if (ip < 0) return false;
      }
      o.src[0] = ip;
    }
    // Operand values
    uint64_t v[3] = {0, 0, 0};
    for (int k = 0; k < 3; k++) {
      if (k == 0 && !o.src1_fp) v[0] = ival[o.src[0]];
      else v[k] = freg(o.src[k]).val;
    }
    if (!fixed) { o.req.a = v[0]; o.req.b = v[1]; o.req.c = v[2]; }
    else {
      // vector operands must be what the registers hold
      if (o.req.a != v[0] || (nsrc > 1 && o.req.b != v[1]) || (nsrc > 2 && o.req.c != v[2]))
        fail("bench: vector operands not in their registers");
    }
    if (!fixed) o.exp = ref::compute(o.req);
    (void)used;
    return true;
  }

  // ---- Selection: one operation selected this cycle, presented next cycle ----
  bool try_issue(Op o, bool fmisc_block) {
    if (o.unit == U_MISC && o.fp_dst && fmisc_block) return false;
    if (o.unit == U_DIV && fdiv_cnt >= FDIVQ) return false;
    if (!o.fp_dst && fpi_cnt >= FPIQ) return false;
    int rob = alloc_free(rob_busy, NROB);
    if (rob < 0) return false;
    bool need_llt = o.unit == U_DIV || !o.fp_dst;
    int llt = need_llt ? alloc_free(llt_busy, NLLT) : -1;
    if (need_llt && llt < 0) return false;
    int tag = need_llt ? -1 : alloc_tag();
    if (!need_llt && tag < 0) { tag_waits++; return false; }   // no free tag: dispatch waits
    int dst;
    if (o.fp_dst) { dst = alloc_f(0); if (dst < 0) return false; }
    else { dst = alloc_free(ibusy, NINT); if (dst < 0) return false; o.dst_en = chance(95); }
    // Commit the allocation
    o.id = next_id++;
    o.rob = rob | (int)((rng() & 1) << ROBI);
    o.robi = rob;
    rob_busy[rob] = true;
    o.llt = llt;
    if (need_llt) llt_busy[llt] = true;
    o.tag = tag;
    if (tag >= 0) { tag_busy[tag] = true; tag_allocs++; }
    o.wid = need_llt ? nfx + llt : tag;
    o.dst = dst;
    o.sel = cycle;
    if (o.fp_dst) {
      FReg &f = fr[0][dst];
      f = FReg{}; f.busy = true; f.known = true; f.val = o.exp.result; f.prod = o.id; f.tid = o.tid;
    } else ibusy[dst] = true;
    o.srcs_settled = true;
    for (int k = 0; k < 3; k++) {
      if (k == 0 && !o.src1_fp) continue;
      freg(o.src[k]).last_use = std::max(freg(o.src[k]).last_use, cycle + 2);
      if (freg(o.src[k]).prod >= 0) o.srcs_settled = false;
    }
    wid_owner[o.wid] = o.id;
    if (o.unit == U_DIV) fdiv_cnt++;
    if (!o.fp_dst) { fpi_cnt++; fpi_exp.push_back(o.id); }
    if (o.fp_dst && o.unit != U_DIV) {
      uint64_t w = cycle + 2 + (o.unit == U_FMA ? FMA_LAT : FMISC_LAT);
      if (f0_sched.count(w)) fail("bench: F0 slot %llu double-booked", (unsigned long long)w);
      f0_sched[w] = o.id;
    }
    ops[o.id] = o;
    have_iss = true;
    iss_id = o.id;
    issued++;
    return true;
  }

  void present(const Op &o) {
    top->iss_valid = 1;
    top->iss_tid = o.tid; top->iss_rob = o.rob; top->iss_wid = o.wid; top->iss_llt = o.llt < 0 ? 0 : o.llt;
    top->iss_dst_en = o.fp_dst ? 1 : o.dst_en;
    top->iss_dst = o.fp_dst ? o.dst : ((1 << PIDX) | o.dst);
    top->iss_src1 = o.src1_fp ? o.src[0] : ((1 << PIDX) | o.src[0]);
    top->iss_src2 = o.src[1]; top->iss_src3 = o.src[2];
    top->iss_src1_fp = o.src1_fp;
    top->iss_fop = o.req.op; top->iss_fmt = o.req.fmt; top->iss_src_fmt = o.req.src_fmt;
    top->iss_ifmt = o.req.ifmt; top->iss_rm = o.req.rm;
    top->iss_fp_int = !o.fp_dst; top->iss_fp_div = o.unit == U_DIV;
  }

  // ---- Flush: every in-flight operation of the thread that has not retired early dies ----
  void do_flush(int tid) {
    flushes++;
    for (auto &kv : ops) {
      Op &o = kv.second;
      if (o.tid != tid || !o.live || o.retired || o.done) continue;
      o.live = false;
      dead_ops++;
      rob_busy[o.robi] = false;
      if (o.llt >= 0) llt_busy[o.llt] = false;
      if (wid_owner[o.wid] == o.id) wid_owner[o.wid] = -1;
      if (o.tag >= 0) { tag_busy[o.tag] = false; tag_free_at[o.tag] = cycle + 1; }
      if (o.fp_dst) {
        FReg &f = fr[0][o.dst];
        if (f.prod == o.id) f = FReg{};
        for (auto it = f0_sched.begin(); it != f0_sched.end();) it = (it->second == o.id) ? f0_sched.erase(it) : std::next(it);
      } else ibusy[o.dst] = false;
    }
  }

  // ---- One cycle ----
  void step(bool can_issue, const std::function<bool(bool)> &pick) {
    // Inputs for this cycle
    clear_inputs();
    bool flushing = false;
    int ftid = 0;
    if (flush_every > 0 && r(flush_every) == 0) { flushing = true; ftid = r(NT); }
    if (have_iss) {
      Op &o = ops[iss_id];
      present(o);
    }
    if (ld_m2.v) { top->fld_m2_will = 1; top->fld_m2_idx = ld_m2.idx; }
    if (ld_wr.v) {
      // the core's LSU NaN-boxes FLW before the load result register (3f9a227), so fld_data is
      // the value F1 gets
      top->fld_valid = 1; top->fld_idx = ld_wr.idx;
      top->fld_data = ld_wr.single ? ref::box32((uint32_t)ld_wr.raw) : ld_wr.raw;
    }
    if (flushing) { top->flush = 1; top->flush_tid = ftid; }
    // Early retirement of a divide already in RF or beyond
    if (ret_pct && chance(ret_pct)) {
      std::vector<long> cand;
      for (auto &kv : ops) {
        const Op &o = kv.second;
        // Retirement is in order: a divide retires only after its producers, and a flush (which
        // is registered) kills nothing that retires with it.
        if (o.unit == U_DIV && o.live && !o.retired && !o.done && o.sel + 1 <= cycle && o.srcs_settled &&
            !(flushing && o.tid == ftid))
          cand.push_back(o.id);
      }
      if (!cand.empty()) {
        Op &o = ops[cand[r((int)cand.size())]];
        top->fdiv_ret_valid = 1; top->fdiv_ret_tid = o.tid; top->fdiv_ret_llt = o.llt;
        o.retired = true;
        rets++;
      }
    }
    // Store-data read of a register the file holds
    int fsd = -1;
    for (int t = 0; t < 4 && fsd < 0; t++) {
      int b = r(2), i = r(NFP);
      if (fr[b][i].busy && fr[b][i].known && fr[b][i].in_rf <= cycle) fsd = (b << FPIDX) | i;
    }
    if (fsd >= 0) top->fsd_tag = fsd;
    if (tr_chk_idx >= 0) top->tr_tag = tr_chk_idx;
    top->eval();
    // Integer source: the shared port answers combinationally
    if (top->isrc_valid) {
      int ip = top->isrc_tag & (NINT - 1);
      top->isrc_data = ival[ip];
      top->eval();
    }
    // The flush acts in this cycle: its thread's operations are dead from now on
    if (flushing) do_flush(ftid);
    // Bank-1 arbiter: claim a live head, write it 1-4 cycles later (the head must stay put), and
    // pop a killed head without a write, wakeup or completion
    bool fpi_write = false;
    if (top->fpi_valid) {
      if (fpi_claimed) {
        if (top->fpi_kill) { if (--fpi_left <= 0 || chance(50)) top->fpi_ready = 1; }
        else if (--fpi_left <= 0) { top->fpi_ready = 1; fpi_write = true; }
      } else if (top->fpi_kill) {
        if (chance(70)) top->fpi_ready = 1;
      } else if (chance(ready_pct)) {
        fpi_claimed = true;
        fpi_claim_id = fpi_exp.empty() ? -1 : fpi_exp.front();
        fpi_left = 1 + r(4);
        fpi_snap_take();
        fpi_claims++;
      }
      top->eval();
    }

    // ---- Observe ----
    if (fsd >= 0) {
      checked++;
      if (top->fsd_data != freg(fsd).val)
        fail("store data f%d:%d %016llx, expected %016llx", fsd >> FPIDX, fsd & (NFP - 1),
             (unsigned long long)top->fsd_data, (unsigned long long)freg(fsd).val);
    }
    if (tr_chk_idx >= 0) {
      checked++;
      if (top->tr_data != tr_chk_val)
        fail("F0[%d] holds %016llx, expected %016llx (op %ld)", tr_chk_idx, (unsigned long long)top->tr_data,
             (unsigned long long)tr_chk_val, tr_chk_id);
      tr_chk_idx = -1;
    }
    // Wakeups
    for (int w = 0; w < nfx + NLLT; w++) {
      if (!bit_of(top->wake_reg, w)) continue;
      long id = wid_owner[w];
      if (id < 0 || !ops.count(id) || !ops[id].live) { fail("wakeup of ID %d with no live producer", w); continue; }
      Op &o = ops[id];
      uint64_t want = o.unit == U_FMA ? o.sel + FMA_LAT - 1 : o.unit == U_MISC ? o.sel + 1 : NEVER;
      if (o.unit != U_DIV && cycle != want)
        fail("op %ld (%s) woke at %llu, expected %llu", id, ref::op_name(o.req.op),
             (unsigned long long)cycle, (unsigned long long)want);
      if (o.wake != NEVER) fail("op %ld woke twice", id);
      o.wake = cycle;
      if (o.fp_dst) fr[0][o.dst].avail = cycle + 1;
    }
    // F0 write and completion
    long wid_ = -1;
    Op wop;
    if (top->f0_we_o) {
      int idx = top->f0_widx_o;
      long id = -1;
      auto it = f0_sched.find(cycle);
      if (it != f0_sched.end()) id = it->second;
      else {
        for (auto &kv : ops) {
          const Op &o = kv.second;
          if (o.unit == U_DIV && o.live && !o.done && o.dst == idx && o.wake != NEVER && o.wake + 1 == cycle) id = o.id;
        }
      }
      if (id < 0) fail("F0[%d] written with no live operation due", idx);
      else {
        Op &o = ops[id];
        if (o.dst != idx) fail("op %ld writes F0[%d], expected F0[%d]", id, idx, o.dst);
        wid_ = id;
        wop = o;
        tr_chk_idx = idx; tr_chk_val = o.exp.result; tr_chk_id = id;
        FReg &f = fr[0][o.dst];
        f.in_rf = cycle + 1;
        f.prod = -1;
        if (o.unit != U_DIV && o.wake == NEVER) fail("op %ld written without its wakeup", id);
        if (o.unit == U_DIV) {
          if (o.wake + 1 != cycle) fail("divide op %ld written %llu cycles after its wakeup", id,
                                        (unsigned long long)(cycle - o.wake));
          uint64_t min_lat = o.sel + 2 + 1;   // the unit's own latency comes on top
          if (cycle < min_lat) fail("divide op %ld written too early", id);
        }
      }
      f0_sched.erase(cycle);
    } else if (f0_sched.count(cycle)) {
      fail("op %ld did not write F0 in its slot", f0_sched[cycle]);
      f0_sched.erase(cycle);
    }
    if (top->cmp_valid) {
      long id = -1;
      for (auto &kv : ops) {
        const Op &o = kv.second;
        if (o.live && !o.done && o.tid == (int)top->cmp_tid && o.rob == (int)top->cmp_rob) id = o.id;
      }
      if (id < 0) fail("completion of rob %d tid %d with no live operation", (int)top->cmp_rob, (int)top->cmp_tid);
      else {
        Op &o = ops[id];
        checked++;
        if (id != wid_) fail("op %ld completes without its F0 write", id);
        if (o.retired) fail("op %ld retired early but completes to the ROB", id);
        if ((int)top->cmp_wid != o.wid) fail("op %ld completes with wid %d, expected %d", id, (int)top->cmp_wid, o.wid);
        if (top->cmp_fflags != o.exp.flags)
          fail("op %ld %s fmt %d rm %d a %016llx b %016llx c %016llx: flags %02x, expected %02x", id,
               ref::op_name(o.req.op), o.req.fmt, o.req.rm, (unsigned long long)o.req.a, (unsigned long long)o.req.b,
               (unsigned long long)o.req.c, (int)top->cmp_fflags, o.exp.flags);
        finish(o);
      }
    } else if (wid_ >= 0 && !wop.retired) fail("op %ld written without completing", wid_);
    if (top->er_valid) {
      long id = wid_;
      if (id < 0 || !wop.retired || !ops.count(id)) fail("early-retired completion with no early-retired divide written");
      else {
        Op &o = ops[id];
        checked++;
        if ((int)top->er_tid != o.tid) fail("early-retired completion thread");
        if (top->er_fflags != o.exp.flags) fail("op %ld early-retired flags %02x, expected %02x", id, (int)top->er_fflags, o.exp.flags);
        finish(o);
      }
    }
    // Divide LLTs written
    for (int l = 0; l < NLLT; l++) {
      if (!bit_of(top->llt_done, l)) continue;
      if (wid_ < 0 || wop.unit != U_DIV || wop.llt != l) fail("llt_done[%d] without its divide", l);
    }
    // Integer results: the queue head, held until the arbiter's fpi_ready
    if (top->fpi_pop != (top->fpi_valid && top->fpi_ready)) fail("fpi_pop without fpi_ready on a valid head");
    if (top->fpi_valid) {
      if (fpi_exp.empty()) fail("B1 queue presents a head with nothing expected");
      else {
        Op &o = ops[fpi_exp.front()];
        if ((bool)top->fpi_kill != !o.live) fail("B1 head op %ld: fpi_kill %d, live %d", o.id, (int)top->fpi_kill, (int)o.live);
        if (fpi_claimed) {
          if (fpi_claim_id != o.id) fail("B1 head changed under a claim (op %ld, claimed %ld)", o.id, fpi_claim_id);
          else if (!fpi_snap_same()) fail("B1 head of op %ld changed under a claim", o.id);
        }
        if (o.live) {
          checked++;
          if ((int)top->fpi_rob != o.rob || (int)top->fpi_tid != o.tid || (int)top->fpi_wid != o.wid ||
              (int)top->fpi_llt != o.llt || (int)(top->fpi_dst & (NINT - 1)) != o.dst || (bool)top->fpi_dst_en != o.dst_en)
            fail("B1 record of op %ld differs", o.id);
          if (top->fpi_data != o.exp.result || top->fpi_fflags != o.exp.flags)
            fail("op %ld %s fmt %d ifmt %d rm %d a %016llx b %016llx: %016llx/%02x, expected %016llx/%02x", o.id,
                 ref::op_name(o.req.op), o.req.fmt, o.req.ifmt, o.req.rm, (unsigned long long)o.req.a,
                 (unsigned long long)o.req.b, (unsigned long long)top->fpi_data, (int)top->fpi_fflags,
                 (unsigned long long)o.exp.result, o.exp.flags);
          if (o.wake != NEVER) fail("integer-result op %ld woke through P4", o.id);
          uint64_t want = o.sel + 2 + FMISC_LAT;
          if (cycle < want) fail("integer result of op %ld before its FMISC cycle", o.id);
        }
        if (top->fpi_pop) {
          if (o.live) {
            if (!fpi_write) fail("bench: live B1 head popped without a write");
            if (o.dst_en) { ival[o.dst] = o.exp.result; iavail[o.dst] = cycle + 1; }
            finish(o);
          } else { ops.erase(o.id); fpi_kills++; }
          fpi_exp.pop_front();
          fpi_cnt--;
          fpi_claimed = false;
        }
      }
    } else if (fpi_claimed) {
      fail("B1 head of op %ld left under a claim", fpi_claim_id);
      fpi_claimed = false;
    }
    if (top->fdiv_done) {
      fdiv_cnt--;
      if (fdiv_cnt < 0) fail("fdiv_done without a divide");
      // without a divide written this cycle, a dead one drained: it leaves no other trace
      if (!(wid_ >= 0 && wop.unit == U_DIV)) {
        bool found = false;
        for (auto it = ops.begin(); it != ops.end(); ++it)
          if (it->second.unit == U_DIV && !it->second.live) { ops.erase(it); found = true; break; }
        if (!found) fail("fdiv_done with no divide written or squashed");
      }
    }
    // Squashed fixed-latency ops leave once their result would have appeared
    for (auto it = ops.begin(); it != ops.end();) {
      const Op &o = it->second;
      if (!o.live && o.unit != U_DIV && o.fp_dst && cycle > o.sel + 2 + FMA_LAT + 1) it = ops.erase(it);
      else ++it;
    }

    // The op presented this cycle is in RF; the one selected now is presented next cycle
    have_iss = false;
    if (can_issue) {
      bool blk = top->fmisc_block;
      pick(blk);
      if (have_iss && flushing && ops[iss_id].tid == ftid) {
        // the scheduler is flushed: the select of this cycle does not issue
        Op o = ops[iss_id];
        undo_issue(o);
        have_iss = false;
      }
    }
    // Loads: the announced one writes next cycle, the started one is announced
    ld_wr = ld_m2;
    ld_m2 = ld_new;
    ld_new = Ld{};
    recycle();

    // ---- Clock ----
    top->clk = 1; top->eval(); top->clk = 0; top->eval();
    cycle++;
  }

  void finish(Op &o) {
    o.done = true;
    if (o.free_isrc) ibusy[o.src[0]] = false;
    rob_busy[o.robi] = false;
    if (o.llt >= 0) llt_busy[o.llt] = false;
    if (wid_owner[o.wid] == o.id) wid_owner[o.wid] = -1;
    // completes in its F0 write cycle; rename frees the tag 2 cycles later (core track's rule)
    if (o.tag >= 0) { tag_busy[o.tag] = false; tag_free_at[o.tag] = cycle + 2; }
    if (!o.fp_dst) ibusy[o.dst] = false;
    ops.erase(o.id);
  }
  void undo_issue(Op &o) {
    rob_busy[o.robi] = false;
    if (o.llt >= 0) llt_busy[o.llt] = false;
    if (wid_owner[o.wid] == o.id) wid_owner[o.wid] = -1;
    if (o.tag >= 0) tag_busy[o.tag] = false;
    if (o.fp_dst) fr[0][o.dst] = FReg{};
    else ibusy[o.dst] = false;
    if (o.unit == U_DIV) fdiv_cnt--;
    if (!o.fp_dst) { fpi_cnt--; fpi_exp.pop_back(); }
    for (auto it = f0_sched.begin(); it != f0_sched.end();) it = (it->second == o.id) ? f0_sched.erase(it) : std::next(it);
    ops.erase(o.id);
    issued--;
  }

  // The B1 head record, for the stability check between the arbiter's claim and its write
  void fpi_snap_read(uint64_t *v) {
    v[0] = top->fpi_tid; v[1] = top->fpi_rob; v[2] = top->fpi_wid; v[3] = top->fpi_llt;
    v[4] = top->fpi_dst_en; v[5] = top->fpi_dst; v[6] = top->fpi_data; v[7] = top->fpi_fflags;
  }
  void fpi_snap_take() { fpi_snap_read(fpi_snap); }
  bool fpi_snap_same() {
    uint64_t v[8];
    fpi_snap_read(v);
    return std::equal(v, v + 8, fpi_snap);
  }

  // A load into a free F1 register: announced next cycle, written the cycle after
  bool start_load(uint64_t raw, bool single, int *idx_out) {
    if (ld_new.v) return false;
    int i = alloc_f(1);
    if (i < 0) return false;
    // ld_m2 is presented next cycle (fld_m2_will), ld_wr the cycle after (fld_valid)
    FReg &f = fr[1][i];
    f = FReg{};
    f.busy = true; f.known = true;
    f.val = single ? ref::box32((uint32_t)raw) : raw;
    f.avail = cycle;              // announced next cycle, written the cycle after: a consumer
    f.in_rf = cycle + 3;          // selected now reaches EX0 as it is written (F1 bypass)
    ld_new = Ld{true, i, single, raw};
    if (idx_out) *idx_out = (1 << FPIDX) | i;
    return true;
  }
  bool busy() const { return !ops.empty() || ld_new.v || ld_m2.v || ld_wr.v || have_iss; }
};

// ---- Random mode ----
static int run_rand(uint64_t seed, long n, int flush_every, int ret_pct, int ready_pct, int tags) {
  Bench b(seed);
  b.flush_every = flush_every; b.ret_pct = ret_pct; b.ready_pct = ready_pct;
  b.ntag = std::max(1, std::min(b.ntag, tags));
  b.reset();
  static const int fma_ops[] = {ref::FADD, ref::FSUB, ref::FMUL, ref::FMADD, ref::FMSUB, ref::FNMSUB, ref::FNMADD,
                                ref::FCVT_F_F, ref::FCVT_F_I};
  static const int misc_ops[] = {ref::FSGNJ, ref::FSGNJN, ref::FSGNJX, ref::FMIN, ref::FMAX, ref::FEQ, ref::FLT,
                                 ref::FLE, ref::FCLASS, ref::FCVT_I_F, ref::FMV_X_F, ref::FMV_F_X};
  long target = n;
  uint64_t limit = (uint64_t)n * 40 + 100000;
  auto pick = [&](bool blk) -> bool {
    // a load now and then: interesting operand values enter through F1
    if (b.chance(35)) {
      bool single = b.chance(50);
      uint64_t v = b.gen.fp(!single);
      b.start_load(single ? (b.chance(3) ? b.rng() : v) : v, single, nullptr);
    }
    if (b.issued >= target || !b.chance(85)) return false;
    for (int t = 0; t < 6; t++) {
      Op o;
      o.tid = b.r(NT);
      int k = b.r(100);
      ref::Req &q = o.req;
      q.fmt = b.r(2); q.rm = b.r(5); q.ifmt = b.r(4); q.src_fmt = q.fmt;
      if (k < 45) q.op = fma_ops[b.r(9)];
      else if (k < 85) q.op = misc_ops[b.r(12)];
      else q.op = b.chance(50) ? ref::FDIV : ref::FSQRT;
      if (q.op == ref::FCVT_F_F) q.src_fmt = !q.fmt;
      if (!b.make_op(o, nullptr, nullptr, 0, -1)) continue;
      if (b.try_issue(o, blk)) return true;
    }
    return false;
  };
  while ((b.issued < target || b.busy()) && b.cycle < limit) b.step(true, pick);
  bool hung = b.cycle >= limit;
  printf("rand seed=%llu: %ld operations, %ld checks, %ld flushes (%ld ops squashed), %ld early retirements, "
         "%ld tags taken (%ld dispatch waits), %ld B1 claims, %ld killed B1 heads, %llu cycles, %ld errors%s\n",
         (unsigned long long)seed, b.issued, b.checked, b.flushes, b.dead_ops, b.rets, b.tag_allocs, b.tag_waits,
         b.fpi_claims, b.fpi_kills, (unsigned long long)b.cycle, b.errors, hung ? ", HUNG" : "");
  return (b.errors || hung) ? 1 : 0;
}

// ---- TestFloat mode ----
static int run_tf(const char *fname, int rm, long limit) {
  const TfFunc *f = nullptr;
  for (auto &t : tf_funcs) if (!strcmp(t.name, fname)) f = &t;
  if (!f) { fprintf(stderr, "unknown TestFloat function %s\n", fname); return 2; }
  Bench b(1);
  b.reset();
  std::mt19937_64 rng(7);
  struct Job { ref::Req req; ref::Resp exp; int ftag[3]; int ip; int nload; };
  std::deque<Job> jobs;
  char line[512];
  long nvec = 0;
  bool eof = false;
  auto pick = [&](bool blk) -> bool {
    // feed the operands of the next job that still needs loads
    for (auto &j : jobs) {
      if (j.nload < 3 && j.ftag[j.nload] == -2) {
        uint64_t v = j.nload == 0 ? j.req.a : j.nload == 1 ? j.req.b : j.req.c;
        bool single = (f->in == 's');
        int tag;
        if (b.start_load(single ? (v & 0xFFFFFFFFull) : v, single, &tag)) {
          j.ftag[j.nload] = tag; j.nload++;
          b.freg(tag).pins++;
        }
        break;
      }
    }
    if (jobs.empty()) return false;
    Job &j = jobs.front();
    for (int k = 0; k < 3; k++) if (j.ftag[k] == -2) return false;
    for (int k = 0; k < 3; k++) if (j.ftag[k] >= 0 && b.freg(j.ftag[k]).avail > b.cycle) return false;
    if (j.ip >= 0 && b.iavail[j.ip] > b.cycle) return false;
    Op o;
    o.req = j.req; o.exp = j.exp; o.tid = 0; o.src_name = f->name;
    int fs[3]; int nf = 0;
    for (int k = 0; k < 3; k++) if (j.ftag[k] >= 0) fs[nf++] = j.ftag[k];
    if (!b.make_op(o, &j.req, nf ? fs : nullptr, nf ? nf : 1, j.ip)) return false;
    o.exp = j.exp;
    o.free_isrc = j.ip >= 0;
    if (!b.try_issue(o, blk)) return false;
    for (int k = 0; k < 3; k++) if (j.ftag[k] >= 0) b.freg(j.ftag[k]).pins--;
    jobs.pop_front();
    return true;
  };
  while (!eof || !jobs.empty() || b.busy()) {
    while (!eof && jobs.size() < 4) {
      if ((limit && nvec >= limit) || !fgets(line, sizeof line, stdin)) { eof = true; break; }
      uint64_t v[5] = {0, 0, 0, 0, 0};
      int k = 0;
      for (char *p = strtok(line, " \t\r\n"); p && k < 5; p = strtok(nullptr, " \t\r\n")) v[k++] = strtoull(p, 0, 16);
      if (k != f->nin + 2) { fprintf(stderr, "bad vector line %ld\n", nvec + 1); return 2; }
      Job j{};
      j.req = ref::Req{f->op, f->fmt, f->src_fmt, f->ifmt, rm, 0, 0, 0};
      uint64_t in[3] = {0, 0, 0};
      for (int i = 0; i < f->nin; i++) in[i] = tf_in(f->in, v[i], rng);
      j.exp = ref::Resp{tf_out(f->out, v[f->nin]), (uint8_t)(v[f->nin + 1] & 0x1F), f->out != 's' && f->out != 'd'};
      j.req.a = in[0]; j.req.b = in[1]; j.req.c = in[2];
      j.ip = -1;
      for (int i = 0; i < 3; i++) j.ftag[i] = -1;
      bool int_in = f->in == 'i' || f->in == 'u' || f->in == 'I' || f->in == 'U';
      if (int_in) {
        int ip = -1;
        for (int t = 0; t < NINT && ip < 0; t++) { int i = (int)(rng() % NINT); if (!b.ibusy[i]) ip = i; }
        if (ip < 0) { fprintf(stderr, "bench: no free integer register\n"); return 2; }
        b.ibusy[ip] = true; b.ival[ip] = in[0]; b.iavail[ip] = 0;
        j.ip = ip;
        j.nload = 3;
      } else {
        for (int i = 0; i < f->nin; i++) j.ftag[i] = -2;   // to load
        j.nload = 0;
        // FP sources the op does not read still need a tag: reuse the first
        if (f->nin < 3) for (int i = f->nin; i < 3; i++) j.ftag[i] = -1;
      }
      jobs.push_back(j);
      nvec++;
    }
    long before = b.issued;
    b.step(true, pick);
    if (b.issued != before) b.last_progress = b.cycle;
    if (b.cycle > b.last_progress + 20000) {
      printf("HUNG at cycle %llu: %zu jobs waiting, %zu ops in flight, fdiv %d fpi %d\n",
             (unsigned long long)b.cycle, jobs.size(), b.ops.size(), b.fdiv_cnt, b.fpi_cnt);
      for (auto &kv : b.ops) {
        const Op &o = kv.second;
        printf("  op %ld %s unit %d live %d sel %llu wake %llu dst %d\n", o.id, ref::op_name(o.req.op), o.unit,
               o.live, (unsigned long long)o.sel, (unsigned long long)o.wake, o.dst);
      }
      if (!jobs.empty()) {
        const Job &j = jobs.front();
        printf("  job: ftag %d %d %d ip %d nload %d\n", j.ftag[0], j.ftag[1], j.ftag[2], j.ip, j.nload);
      }
      return 1;
    }
  }
  printf("tf %s rm=%d: %ld vectors, %ld checks, %llu cycles, %ld errors\n", fname, rm, nvec, b.checked,
         (unsigned long long)b.cycle, b.errors);
  if (nvec == 0) { printf("FAIL no vectors read\n"); return 1; }
  return b.errors ? 1 : 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) { fprintf(stderr, "usage: tb_fpx rand|tf ...\n"); return 2; }
  std::string mode = argv[1];
  uint64_t seed = 1;
  long n = 0;
  int rm = 0, flush_every = 300, ret_pct = 0, ready = 85, tags = NTAG;
  std::string fn;
  for (int i = 2; i < argc; i++) {
    std::string a = argv[i];
    if (a == "-seed" && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
    else if (a == "-n" && i + 1 < argc) n = strtol(argv[++i], 0, 0);
    else if (a == "-rm" && i + 1 < argc) rm = atoi(argv[++i]);
    else if (a == "-flush" && i + 1 < argc) flush_every = atoi(argv[++i]);
    else if (a == "-ret" && i + 1 < argc) ret_pct = atoi(argv[++i]);
    else if (a == "-ready" && i + 1 < argc) ready = atoi(argv[++i]);
    else if (a == "-tags" && i + 1 < argc) tags = atoi(argv[++i]);
    else if (mode == "tf" && fn.empty()) fn = a;
    else { fprintf(stderr, "bad argument %s\n", a.c_str()); return 2; }
  }
  if (mode == "rand") return run_rand(seed, n ? n : 100000, flush_every, ret_pct, ready, tags);
  if (mode == "tf") return run_tf(fn.c_str(), rm, n);
  fprintf(stderr, "unknown mode %s\n", mode.c_str());
  return 2;
}
