// tgsim: out-of-order core timing model.
#include "core.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <sstream>

namespace tg {

namespace {

bool long_latency(const Uop& u) {
  return u.is_load || u.cls == Cls::DIV || u.cls == Cls::FDIV || u.cls == Cls::FSQRT;
}

std::string json_escape(const std::string& s, size_t max_len) {
  std::string o;
  for (size_t i = 0; i < s.size() && i < max_len; i++) {
    const unsigned char ch = (unsigned char)s[i];
    if (ch == '"' || ch == '\\') { o += '\\'; o += (char)ch; }
    else if (ch == '\n') o += "\\n";
    else if (ch == '\r') o += "\\r";
    else if (ch == '\t') o += "\\t";
    else if (ch < 0x20 || ch >= 0x7f) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", ch); o += b; }
    else o += (char)ch;
  }
  return o;
}

// R12: what a limited decode slot takes: integer ALU, branch, multiply/divide and integer load/store. CSR,
// FENCE, system, AMO and FP instructions (FP loads and stores included) need one of the full decoders.
bool decode_simple(Cls c) {
  switch (c) {
    case Cls::ALU: case Cls::ALUX: case Cls::BR: case Cls::JAL: case Cls::JALR: case Cls::MUL: case Cls::DIV:
    case Cls::LD: case Cls::ST:
      return true;
    default:
      return false;
  }
}

// R13: what a simple third ALU executes: add/sub, logic, compares, LUI/AUIPC and the Zba shift-adds. Shifts,
// Zbb, Zbs and Zicond stay on ALU0 and ALU1.
bool alu_simple(Op op) {
  switch (op) {
    case Op::LUI: case Op::AUIPC: case Op::ADDI: case Op::ADD: case Op::SUB: case Op::ADDIW: case Op::ADDW:
    case Op::SUBW: case Op::SLTI: case Op::SLTIU: case Op::SLT: case Op::SLTU: case Op::XORI: case Op::ORI:
    case Op::ANDI: case Op::XOR: case Op::OR: case Op::AND: case Op::SH1ADD: case Op::SH2ADD: case Op::SH3ADD:
    case Op::ADD_UW: case Op::SH1ADD_UW: case Op::SH2ADD_UW: case Op::SH3ADD_UW:
      return true;
    default:
      return false;
  }
}

// Integer register operands a uop reads at issue (FP sources read the FP banks; -2 is the SFB temp).
int int_srcs(const Uop& u) {
  int n = 0;
  for (int k = 0; k < u.nsrc; k++) if (u.src_arch[k] < 32) n++;
  return n;
}

// Thread 1's PCs are XORed with this salt where they index shared predictor tables (smt_bp_hash). It leaves
// the low 4 bits alone, so block-BTB slot offsets are unchanged.
constexpr uint64_t SALT1 = 0x79b97f4a7c10ull;
// Thread 1's physical addresses: 64 GiB plus 21 pages above its virtual ones. The two address spaces never
// share a line, and its pages sit 21 colours away in the L2, so two copies of one program do not alias set
// for set. The L1s are indexed within the page (VIPT), so their set mapping is unchanged.
constexpr uint64_t PA_OFF1 = (1ull << 36) + 21 * 4096ull;

}  // namespace

Core::Core(const Config& c, const std::vector<ThreadSpec>& specs)
    : c_(c), nthr_((int)std::clamp<int64_t>(c.threads, 1, MAX_THREADS)), mem_(c),
      btb_((int)c.btb_sets, (int)c.btb_ways, (int)std::max<int64_t>(1, c.btb_slots), (int)c.fetch_bytes,
           c.btb_block != 0),
      ubtb_((int)c.ubtb), m2_((int)std::max<int64_t>(1, c.ubtb), (int)c.ubtb_ways, (int)c.m2_ctr),
      sfb_tab_((int)std::max<int64_t>(1, c.sfb_entries)), hitpred_(1024, 3),
      waittab_((int)std::max<int64_t>(1, c.mdp_entries), 0) {
  if (c.dirpred == 2)
    dir_ = std::make_unique<Tage>((int)c.tage_base_log, (int)c.tage_tables, (int)c.tage_log, (int)c.tage_tag,
                                  (int)c.tage_hmin, (int)c.tage_hmax);
  else if (c.dirpred == 1)
    dir_ = std::make_unique<Gshare>((int)c.gshare_log, (int)c.gshare_hist);
  else
    dir_ = std::make_unique<Bimodal>((int)c.gshare_log);
  for (int t = 0; t < nthr_; t++) {
    auto T = std::make_unique<Thread>((int)c.ras);
    T->tid = t;
    if (t < (int)specs.size()) T->spec = specs[(size_t)t];
    T->iss = T->spec.iss;
    T->synth.resize(4096);
    T->salt = (t > 0 && c.smt_bp_hash) ? SALT1 : 0;
    T->pa_off = t > 0 ? PA_OFF1 : 0;
    T->win_base = T->next_id = T->disp_next = ((uint64_t)t << TID_SHIFT) + 1;
    th_.push_back(std::move(T));
  }
  // Banks: B0 (P0), B1 (P1), B2 (loads), F0 (FP pipe), F1 (FP loads), B3 (P5, only used with alu3).
  if (c.prf_banked) bank_size_ = {c.bank_size, c.bank_size, c.bank_size, c.bank_size, c.bank_size, c.bank_size};
  else bank_size_ = {c.prf_int, c.prf_fp};
  bank_committed_.assign(bank_size_.size(), 0);
  bank_inflight_.assign(bank_size_.size(), 0);
  // Every thread's architectural registers start out spread over the banks.
  for (auto& Tp : th_) {
    Thread& T = *Tp;
    for (int r = 1; r < 32; r++) { T.arch_bank[r] = c.prf_banked ? r % 3 : 0; bank_committed_[T.arch_bank[r]]++; }
    for (int r = 0; r < 32; r++) {
      T.arch_bank[32 + r] = c.prf_banked ? 3 + (r % 2) : 1;
      bank_committed_[T.arch_bank[32 + r]]++;
    }
    T.arch_bank[0] = -1;
  }
  if ((int)specs.size() < nthr_ || !th_.back()->iss) err_ = "a program is needed for every thread";
}

// ---------------------------------------------------------------- instruction stream

const DynInst* Core::get(Thread& T, uint64_t seq) {
  while (seq >= T.stream_base + T.stream.size()) {
    if (T.iss_done) return nullptr;
    DynInst di;
    if (!T.iss->step(di)) {
      T.iss_done = true;
      if (!T.iss->error().empty())
        err_ = (nthr_ > 1 ? "ISS (thread " + std::to_string(T.tid) + "): " : std::string("ISS: ")) + T.iss->error();
      return nullptr;
    }
    T.stream.push_back(di);
  }
  if (seq < T.stream_base) return nullptr;
  return &T.stream[seq - T.stream_base];
}

bool Core::stream_has(Thread& T, uint64_t seq) { return get(T, seq) != nullptr; }

void Core::prune_stream(Thread& T) {
  uint64_t keep = T.fetch_seq;
  if (!T.fetchq.empty()) keep = std::min(keep, T.fetchq.front().seq);
  if (!T.win.empty()) keep = std::min(keep, T.win.front().seq);
  while (!T.stream.empty() && T.stream_base < keep) { T.stream.pop_front(); T.stream_base++; }
}

Uop* Core::find(uint64_t id) {
  const uint64_t t = id >> TID_SHIFT;
  if (t >= (uint64_t)nthr_) return nullptr;
  Thread& T = *th_[t];
  if (id < T.win_base || id >= T.win_base + T.win.size()) return nullptr;
  return &T.win[id - T.win_base];
}
const Uop* Core::find(uint64_t id) const {
  const uint64_t t = id >> TID_SHIFT;
  if (t >= (uint64_t)nthr_) return nullptr;
  const Thread& T = *th_[t];
  if (id < T.win_base || id >= T.win_base + T.win.size()) return nullptr;
  return &T.win[id - T.win_base];
}

uint64_t Core::prod_ready_time(uint64_t prod) const {
  if (!prod) return 0;
  if (const Uop* p = find(prod)) return p->state == 2 ? p->t_ready : NEVER;
  auto it = pending_.find(prod);
  return it == pending_.end() ? 0 : it->second;
}

bool Core::src_ready(uint64_t prod, uint64_t t) const { return prod_ready_time(prod) <= t; }

// ---------------------------------------------------------------- multithreading

// Uops of a thread in the instruction queue, the decode/rename stages and the issue queues (ICOUNT).
uint64_t Core::icount(const Thread& T) const {
  uint64_t n = T.fetchq.size() + (T.next_id - T.disp_next);
  for (auto& v : iq_)
    for (uint64_t id : v) if ((id >> TID_SHIFT) == (uint64_t)T.tid) n++;
  return n;
}

// Thread priority this cycle (two threads). Fetch uses the smt_fetch policy: ICOUNT puts the thread with
// fewer uops in the pre-issue stages first (ties alternate), round robin alternates. Decode and rename always
// alternate: ICOUNT there would starve the thread whose uops are waiting, since waiting raises its count.
void Core::order(int* o, bool fetch_stage) const {
  const int first = (int)(t_ % (uint64_t)nthr_);
  o[0] = first;
  o[1] = 1 - first;
  if (fetch_stage && c_.smt_fetch == 0 && icount(*th_[(size_t)o[1]]) < icount(*th_[(size_t)o[0]]))
    std::swap(o[0], o[1]);
}

int Core::iq_occ(uint8_t q, int tid) const {
  int n = 0;
  for (uint64_t id : iq_[q]) if ((id >> TID_SHIFT) == (uint64_t)tid) n++;
  return n;
}

int64_t Core::iq_cap(uint8_t q) const {
  switch (q) {
    case Q_A0: return c_.iq_a0;
    case Q_A1: return c_.iq_a1;
    case Q_LD: return c_.iq_ld;
    case Q_STA: return c_.iq_sta;
    case Q_FP: return c_.iq_fp;
    case Q_A2: return c_.iq_a2 > 0 ? c_.iq_a2 : c_.iq_a1;
    case Q_UNI: return c_.iq_size;
    default: return 1 << 30;
  }
}

int64_t Core::iq_free(uint8_t q, int tid) const {
  int64_t f = iq_cap(q) - (int64_t)iq_[q].size();
  if (nthr_ > 1 && c_.smt_iq_cap < 100 && q != Q_SERIAL) {
    const int64_t cap = std::max<int64_t>(1, (iq_cap(q) * c_.smt_iq_cap + 99) / 100);
    f = std::min<int64_t>(f, cap - iq_occ(q, tid));
  }
  return f;
}

// iq_bank: each queue's rows are two banks, and a row wakes only on its bank's half of the ROB (with two
// threads, a thread's static half). Bank 0 takes the odd row.
int Core::rob_half(uint64_t id) const {
  if (nthr_ > 1) return (int)(id >> TID_SHIFT);
  return (int)((((id - 1) % (uint64_t)c_.rob) * 2) / (uint64_t)c_.rob);
}

int64_t Core::bank_free(uint8_t q, int b) const {
  int64_t n = 0;
  for (uint64_t id : iq_[q]) if (find(id)->iq_bank == b) n++;
  return (iq_cap(q) + 1 - b) / 2 - n;
}

// MX names a 1-cycle ALU-queue producer by its row while the row holds it: until 2 cycles after issue.
bool Core::mx_named(const Uop& p) const {
  return (p.q == Q_A0 || p.q == Q_A1 || p.q == Q_A2) &&
         (p.cls == Cls::ALU || p.is_ctrl || p.sfb_cmp || p.sfb_sel) &&
         (p.state == 1 || (p.state == 2 && t_ <= p.t_issue + 2));
}

// The bank whose rows see every wakeup a uop would wait on (one thread): a waiting producer's ROB half, or
// its row's bank while MX names it. Long-latency tags are seen by every row unless iq_bank_llt, which gives
// a tag the half of its producer. -1: any bank; -2: the producers need both, so the uop waits.
int Core::bank_need(const Thread& T, const Uop& u) const {
  int need = -1;
  for (int k = 0; k < u.nsrc; k++) {
    const uint64_t prod = u.src_arch[k] == -2 ? u.sfb_temp_of : T.rat[(size_t)u.src_arch[k]];
    if (!prod) continue;
    int b;
    if (const Uop* p = find(prod)) {
      if (p->state == 2 && p->t_ready <= t_) continue;
      if (p->has_llt && !c_.iq_bank_llt) continue;
      b = !p->has_llt && mx_named(*p) ? (int)p->iq_bank : rob_half(prod);
    } else {
      const auto it = pending_.find(prod);
      if (!c_.iq_bank_llt || it == pending_.end() || it->second <= t_) continue;
      b = rob_half(prod);
    }
    if (need >= 0 && need != b) return -2;
    need = b;
  }
  return need;
}

// wake_tags: with MX, a row never waits on a 1-cycle producer's ROB column (MX names it while its row holds it,
// and its value is ready after that), nor on a long-latency one (LLT). Only multi-cycle fixed-latency producers
// (MUL, complex Zbb, FMA, FP misc and moves, serialised ops) need a column, so they take a tag from a pool at
// dispatch instead. A tag is free again 2 cycles after its result wakes, past the load-shadow cancel (its column
// is then cleared in every row). Dispatch still checks the ROB-indexed woken bit first, so a source whose
// producer has woken never waits on a reused tag.
int Core::wtags_used() const {
  int n = 0;
  for (auto& Tp : th_)
    for (auto& w : Tp->win)
      if (w.has_wtag && !(w.state == 2 && w.t_ready + 2 <= t_)) n++;
  return n;
}

// A thread's share of a structure that SMT partitions statically (ROB, LQ, SQ, completion buffer).
int64_t Core::share(int64_t size, int tid) const { return (size + nthr_ - 1 - tid) / nthr_; }

// Whether a thread holding `own` entries (all threads: `total`) may not take another entry.
bool Core::window_full(int64_t size, uint64_t own, uint64_t total, int tid) const {
  if (nthr_ == 1) return (int64_t)own >= size;
  if (c_.smt_part) return (int64_t)own >= share(size, tid);
  const int64_t cap = std::max<int64_t>(1, (size * c_.smt_win_cap + 99) / 100);
  return (int64_t)total >= size || (int64_t)own >= cap;
}

// ---------------------------------------------------------------- front end

bool Core::sfb_shape(Thread& T, const DynInst& di, const Decoded** shadow) {
  const Decoded& d = *di.d;
  if (d.cls != Cls::BR || d.imm <= 0) return false;
  const Decoded* s = T.iss->decode_static(di.pc + d.len);
  if (!s) return false;
  if ((uint64_t)d.imm != (uint64_t)(d.len + s->len)) return false;
  if (s->cls != Cls::ALU || s->rd_k != RK_INT || s->rd == 0) return false;
  int extra = 0;
  if (s->rs1_k == RK_INT && s->rs1 != 0 && s->rs1 != s->rd) extra++;
  if (s->rs2_k == RK_INT && s->rs2 != 0 && s->rs2 != s->rd) extra++;
  if (extra > 1) return false;
  if (shadow) *shadow = s;
  return true;
}

bool Core::predict_ctrl(Thread& T, const DynInst& di, FetchRec& r, uint64_t /*block_start*/, bool ubtb_hit,
                        uint64_t ubtb_tgt, int& bubble) {
  const Decoded& d = *di.d;
  const uint64_t pc = di.pc;
  const BtbHit bh = btb_.lookup(pc ^ T.salt);
  bool ok = true;
  auto taken_bubble = [&](bool from_btb) -> int {
    if (!from_btb) { T.st.predecode_redirects++; return (int)c_.predecode_bubble; }
    if (c_.ubtb && ubtb_hit && ubtb_tgt == di.next_pc) return 0;
    return (int)c_.taken_bubble;
  };
  auto ras_push = [&](uint64_t v) {
    r.ras.op = true; r.ras.sp = T.ras.sp();
    r.ras.slot = c_.ras ? (int)((T.ras.sp() + 1) % c_.ras) : -1;
    r.ras.val = c_.ras ? T.ras.at(r.ras.slot) : 0;
    T.ras.push(v);
  };
  switch (d.cls) {
    case Cls::BR: {
      T.st.br_cond++;
      const bool pred = dir_->predict(pc ^ T.salt, T.ghr);
      if (pred == di.taken) {
        if (di.taken) bubble = taken_bubble(bh.hit);
      } else {
        ok = false;
        r.mp_kind = bh.hit ? 1 : 4;
      }
      T.ghr.push(di.taken, pc);
      break;
    }
    case Cls::JAL:
      T.st.br_jal++;
      bubble = taken_bubble(bh.hit);
      if (d.is_call()) ras_push(pc + d.len);
      break;
    case Cls::JALR:
      if (d.is_ret() && (c_.ras || !c_.ret_btb)) {  // ret_btb: without a RAS, returns use the BTB's target
        T.st.br_ret++;
        const uint64_t pt = T.ras.top();
        r.ras.op = true; r.ras.sp = T.ras.sp(); r.ras.slot = -1;
        T.ras.pop();
        if (pt != di.next_pc) { ok = false; r.mp_kind = 3; }
        else if (c_.ras_at_decode && !(bh.hit && bh.target == di.next_pc)) {
          // Fetch followed the BTB's stored target; decode corrects it with the RAS.
          T.st.predecode_redirects++;
          bubble = (int)c_.predecode_bubble;
        } else bubble = taken_bubble(bh.hit);
      } else {
        T.st.br_jalr++;
        if (bh.hit && bh.target == di.next_pc) bubble = taken_bubble(true);
        else { ok = false; r.mp_kind = 2; }
        if (d.is_call()) ras_push(pc + d.len);
      }
      break;
    default: break;
  }
  r.mispred = !ok;
  return ok;
}

// The M2 RTL's front end (fe_m2; core-pipeline.md §3.2-§3.4). The micro-BTB predicts the block taken at its slot,
// else it falls through. Decode repairs a JAL's target, a predicted-taken branch's wrong target and a bogus
// prediction: fetch then waits until that instruction is decoded and starts again the next cycle (`fpc_d`). Anything
// else is a mispredict, recovered at commit with ckpt = 0. The model follows the correct path only, so the training
// the RTL does at execute happens here, with the fetch-time lookup.
void Core::fetch_block_m2(Thread& T, uint64_t start, uint64_t blk_end) {
  const uint64_t fb = (uint64_t)c_.fetch_bytes;
  const uint64_t key = (start & ~(fb - 1)) ^ T.salt;
  const M2Ubtb::Look l = m2_.lookup(key);
  const bool hit = l.hit && (uint64_t)l.slot * 2 >= (start & (fb - 1));  // a slot before the start predicts nothing
  int n = 0, bubble = 0;
  while ((int64_t)T.fetchq.size() < c_.fetchq) {
    const DynInst* di = get(T, T.fetch_seq);
    if (!di) break;
    if (di->pc >= blk_end || di->pc < start) break;
    if (n > 0 && di->pc + di->d->len > blk_end) break;
    const Decoded& d = *di->d;
    FetchRec r;
    r.seq = T.fetch_seq;
    r.di = di;
    r.avail = t_ + (uint64_t)c_.if_stages;
    r.hist = T.ghr;
    const int slot = (int)(((di->pc + d.len - 2) & (fb - 1)) >> 1);
    const bool here = hit && slot == l.slot;
    bool ok = true, f2 = false;  // f2 (m2_f2): F2's pre-decode redirects fetch, at m2_f2_bubble cycles
    if (!d.is_ctrl()) {
      if (here) {  // bogus: decode (F2 with m2_f2) redirects to the next instruction and clears the entry
        if (c_.m2_f2) f2 = true;
        else { T.st.predecode_redirects++; r.de_redirect = true; }
        m2_.invalidate(key, l);
      }
    } else {
      if (d.cls == Cls::BR) T.st.br_cond++;
      else if (d.cls == Cls::JAL) T.st.br_jal++;
      else if (d.is_ret()) T.st.br_ret++;
      else T.st.br_jalr++;
      const uint64_t tgt = d.cls == Cls::JALR ? di->next_pc : di->pc + (uint64_t)d.imm;  // the taken target
      bool pred_taken = here, fixed = false, ras_fix = false;
      uint64_t pred_tgt = here ? l.target : 0;
      if (d.cls == Cls::JAL && !(here && l.target == tgt)) { pred_taken = true; pred_tgt = tgt; fixed = true; }
      else if (d.cls == Cls::BR && here && l.target != tgt) { pred_tgt = tgt; fixed = true; }
      // M6 steps on the M2 front end (DSE of area_recovery.md §6.3), each off by default:
      // m2_dir: the direction predictor (dirpred) decides a branch; a taken guess without the micro-BTB's target
      // is redirected at decode to PC + imm, a not-taken guess against a micro-BTB hit falls through. With m2_f2
      // (core-2's front end), both redirects come from F2's pre-decode, at m2_f2_bubble cycles.
      if (c_.m2_dir && d.cls == Cls::BR) {
        const bool dp = dir_->predict(di->pc ^ T.salt, T.ghr);  // trained at commit (train_predictors)
        if (dp && !(here && l.target == tgt)) { pred_taken = true; pred_tgt = tgt; fixed = true; }
        else if (!dp) { pred_taken = false; fixed = false; if (here && c_.m2_f2) f2 = true; }
      }
      // ras: calls push at fetch; a return the micro-BTB did not predict is redirected at decode to the RAS's top.
      if (c_.ras && d.is_call()) T.ras.push(di->pc + d.len);
      if (c_.ras && d.is_ret()) {
        const uint64_t top = T.ras.top();
        T.ras.pop();
        if (!(here && l.target == tgt) && top == tgt) { pred_taken = true; pred_tgt = tgt; fixed = true; ras_fix = true; }
      }
      if (fixed && c_.m2_f2 && (!ras_fix || c_.m2_ras_f2)) f2 = true;  // from F2's pre-decode (returns: m2_ras_f2)
      else if (fixed) { T.st.predecode_redirects++; r.de_redirect = true; }
      if (pred_taken != di->taken || (di->taken && pred_tgt != di->next_pc)) {
        ok = false;
        r.mp_kind = d.cls == Cls::BR ? (here ? 1 : 4) : d.is_ret() ? 3 : 2;
      }
      m2_.train(key, di->pc, slot, d.cls != Cls::BR, di->taken, tgt, l);
      // The RTL trains at execute on the wrong path too. Past a loop's exit it runs the loop again until the
      // commit flush, and the wrong path's copies of the branch resolve not taken: m2_wp_train more such updates.
      if (!ok && d.cls == Cls::BR && pred_taken && !di->taken && tgt <= di->pc)
        for (int k = 0; k < c_.m2_wp_train; k++) m2_.train(key, di->pc, slot, false, false, tgt, m2_.lookup(key));
      T.ghr.push(di->taken, di->pc);
    }
    r.mispred = !ok;
    if (!ok) { r.de_redirect = false; f2 = false; }  // the mispredict's recovery restarts fetch
    T.fetchq.push_back(r);
    T.fetch_seq++;
    n++;
    if (!ok || r.de_redirect) { T.fe_blocked = true; break; }
    if (f2) { T.st.f2_overrides++; bubble = (int)c_.m2_f2_bubble; break; }
    if (here || (d.is_ctrl() && di->taken)) break;
    if (di->pc + d.len >= blk_end) break;
  }
  T.st.taken_bubbles += (uint64_t)bubble;
  T.fe_resume = t_ + 1 + (uint64_t)bubble;
}

// One thread fetches per cycle (one I$ access): the first in priority order that can. The others record why
// they could not.
void Core::fetch() {
  if (nthr_ == 1) { fetch_thread(*th_[0]); return; }
  int o[MAX_THREADS];
  order(o, true);
  bool done = false;
  for (int k = 0; k < nthr_; k++) {
    Thread& T = *th_[(size_t)o[k]];
    if (T.fe_blocked) { T.st.fetch_stall_blocked++; continue; }
    if (t_ < T.fe_resume) { T.st.fetch_stall_bubble++; continue; }
    if ((int64_t)T.fetchq.size() >= c_.fetchq) { T.st.fetch_stall_queue++; continue; }
    if (!get(T, T.fetch_seq)) continue;
    if (done) { T.st.fetch_lost_smt++; continue; }
    T.st.fetch_cycles++;
    fetch_thread(T);
    done = true;
  }
}

void Core::fetch_thread(Thread& T) {
  if (T.fe_blocked) { T.st.fetch_stall_blocked++; return; }
  if (t_ < T.fe_resume) { T.st.fetch_stall_bubble++; return; }
  if ((int64_t)T.fetchq.size() >= c_.fetchq) { T.st.fetch_stall_queue++; return; }
  const DynInst* first = get(T, T.fetch_seq);
  if (!first) return;
  const uint64_t fb = (uint64_t)c_.fetch_bytes;
  const uint64_t start = first->pc, blk_end = (start & ~(fb - 1)) + fb;

  mem_.tid = T.tid;
  uint64_t ready = t_;
  const MemSys::Res res = mem_.l1i(pa(T, start), t_, false, ready);
  if (res != MemSys::Res::HIT) {
    T.fe_resume = std::max(ready, t_ + 1);
    T.st.fetch_stall_icache++;
    if (res == MemSys::Res::MISS && c_.fdip) {
      // Fetch-directed prefetch: the predictor runs ahead along the predicted path while fetch waits.
      uint64_t line = start >> 6;
      int issued = 0;
      for (uint64_t s = T.fetch_seq; s < T.fetch_seq + 128 && issued < c_.ftq / 8 + 1; s++) {
        const DynInst* d = get(T, s);
        if (!d) break;
        if ((d->pc >> 6) != line) {
          line = d->pc >> 6;
          uint64_t r2;
          mem_.l1i(pa(T, d->pc), t_, true, r2);
          issued++;
        }
      }
    }
    return;
  }

  if (c_.fe_m2) { fetch_block_m2(T, start, blk_end); return; }
  bool ubtb_hit = false;
  uint64_t ubtb_tgt = 0;
  if (c_.ubtb) ubtb_hit = ubtb_.lookup(start ^ T.salt, ubtb_tgt);
  int bubble = 0;
  bool taken_end = false;
  uint64_t taken_tgt = 0;
  int n = 0;
  while ((int64_t)T.fetchq.size() < c_.fetchq) {
    const DynInst* di = get(T, T.fetch_seq);
    if (!di) break;
    if (di->pc >= blk_end || di->pc < start) break;
    if (n > 0 && di->pc + di->d->len > blk_end) break;
    FetchRec r;
    r.seq = T.fetch_seq;
    r.di = di;
    r.avail = t_ + (uint64_t)c_.if_stages;
    r.hist = T.ghr;
    if (di->d->is_ctrl()) {
      const Decoded* shadow = nullptr;
      if (c_.sfb && di->d->cls == Cls::BR && sfb_tab_.get(di->pc ^ T.salt) >= c_.sfb_thresh &&
          sfb_shape(T, *di, &shadow)) {
        // Predicated short forward branch: fetch falls through into the shadow instruction.
        r.sfb = true;
        T.ghr.push(di->taken, di->pc);
        T.fetchq.push_back(r);
        T.fetch_seq++;
        n++;
        T.st.sfb_pairs++;
        FetchRec s;
        s.avail = r.avail;
        s.hist = T.ghr;
        if (di->taken) {
          DynInst& sy = T.synth[T.synth_pos++ % T.synth.size()];
          sy = DynInst{};
          sy.seq = r.seq;
          sy.pc = di->pc + di->d->len;
          sy.next_pc = di->next_pc;
          sy.d = shadow;
          s.seq = r.seq;
          s.di = &sy;
          s.synthetic = true;
          T.st.sfb_shadow_skipped++;
          T.fetchq.push_back(s);
        } else {
          const DynInst* nx = get(T, T.fetch_seq);
          if (!nx) break;
          s.seq = T.fetch_seq;
          s.di = nx;
          T.fetchq.push_back(s);
          T.fetch_seq++;
        }
        n++;
        const DynInst* nn = get(T, T.fetch_seq);
        if (!nn || nn->pc >= blk_end || nn->pc + nn->d->len > blk_end) break;
        continue;
      }
      int bub = 0;
      const bool ok = predict_ctrl(T, *di, r, start, ubtb_hit, ubtb_tgt, bub);
      T.fetchq.push_back(r);
      T.fetch_seq++;
      n++;
      if (!ok) { T.fe_blocked = true; break; }
      if (di->taken) { bubble = bub; taken_end = true; taken_tgt = di->next_pc; break; }
      continue;
    }
    T.fetchq.push_back(r);
    T.fetch_seq++;
    n++;
    if (di->pc + di->d->len >= blk_end) break;
  }
  if (c_.ubtb && !T.fe_blocked) {
    if (taken_end) ubtb_.taken(start ^ T.salt, taken_tgt);
    else {
      if (ubtb_hit) {  // fast redirect taken but the block fell through: BP2 overrides it
        bubble = std::max<int>(bubble, (int)c_.taken_bubble);
        T.st.ubtb_wrong++;
      }
      ubtb_.fallthrough(start ^ T.salt);
    }
  }
  T.st.taken_bubbles += (uint64_t)bubble;
  T.fe_resume = t_ + 1 + (uint64_t)bubble;
}

// ---------------------------------------------------------------- decode

void Core::add_srcs(Uop& u, const Decoded& d, bool skip_store_data) {
  auto add = [&](uint8_t reg, uint8_t kind) {
    if (kind == RK_NONE || (kind == RK_INT && reg == 0)) return;
    const int a = kind == RK_FP ? 32 + reg : reg;
    for (int k = 0; k < u.nsrc; k++) if (u.src_arch[k] == a) return;
    if (u.nsrc < 3) u.src_arch[u.nsrc++] = a;
  };
  add(d.rs1, d.rs1_k);
  if (!skip_store_data) add(d.rs2, d.rs2_k);
  add(d.rs3, d.rs3_k);
}

Uop& Core::new_uop(Thread& T, const FetchRec& r) {
  T.win.emplace_back();
  Uop& u = T.win.back();
  u.id = T.next_id++;
  u.tid = (uint8_t)T.tid;
  u.seq = r.seq;
  u.seq_next = r.seq + 1;
  u.di = r.di;
  const Decoded& d = *r.di->d;
  u.cls = d.cls;
  u.n_instr = r.synthetic ? 0 : 1;
  u.hist = r.hist;
  u.ras = r.ras;
  u.mispred = r.mispred;
  u.mp_kind = r.mp_kind;
  u.is_ctrl = d.is_ctrl();
  u.mmio = r.di->mmio;
  u.serial = d.cls == Cls::CSR || d.cls == Cls::FENCE || d.cls == Cls::SYS || d.cls == Cls::AMO || u.mmio;
  u.is_load = d.cls == Cls::LD || d.cls == Cls::FLD;
  u.is_store = d.cls == Cls::ST || d.cls == Cls::FST;
  u.addr = r.di->addr;
  u.size = d.msize;
  if (d.writes_int()) u.dst_arch = d.rd;
  else if (d.writes_fp()) u.dst_arch = 32 + d.rd;
  if (u.serial) u.q = Q_SERIAL;
  else if (c_.iq_unified) u.q = Q_UNI;
  else {
    switch (d.cls) {
      case Cls::ALU: u.q = Q_ALU_ANY; break;
      case Cls::ALUX: case Cls::MUL: case Cls::DIV: u.q = Q_A1; break;
      case Cls::BR: case Cls::JAL: case Cls::JALR: u.q = Q_A0; break;
      case Cls::LD: case Cls::FLD: u.q = Q_LD; break;
      case Cls::ST: case Cls::FST: u.q = Q_STA; break;
      default: u.q = Q_FP; break;
    }
  }
  const bool split = u.is_store && c_.sta_split && !u.serial;
  add_srcs(u, d, split);
  if (split) {
    if (d.rs2_k == RK_FP) u.data_arch = 32 + d.rs2;
    else if (d.rs2_k == RK_INT && d.rs2 != 0) u.data_arch = d.rs2;
  }
  u.t_disp_ok = t_ + (uint64_t)c_.dec_to_disp;
  return u;
}

bool Core::fusible(const FetchRec& a, const FetchRec& b) const {
  if (a.synthetic || b.synthetic || a.sfb || b.sfb || a.mispred) return false;
  const Decoded& x = *a.di->d;
  const Decoded& y = *b.di->d;
  if (b.di->pc != a.di->pc + x.len) return false;
  if (!x.writes_int() || a.di->mmio || b.di->mmio) return false;
  const uint8_t rd = x.rd;
  const bool y_load = y.cls == Cls::LD && y.rd == rd && y.rs1 == rd;
  if (c_.fuse_alubr && y.cls == Cls::BR && (x.op == Op::ADDI || x.op == Op::ADDIW || x.op == Op::ANDI) &&
      (y.rs1 == rd || y.rs2 == rd))
    return true;
  switch (x.op) {
    case Op::LUI: return ((y.op == Op::ADDI || y.op == Op::ADDIW) && y.rd == rd && y.rs1 == rd) || y_load;
    case Op::AUIPC:
      return (y.op == Op::ADDI && y.rd == rd && y.rs1 == rd) || y_load ||
             (y.op == Op::JALR && y.rs1 == rd && y.rd == rd);
    case Op::SLLI:
      return (y.op == Op::SRLI && x.imm == 32 && y.imm == 32 && y.rd == rd && y.rs1 == rd) ||
             (y.op == Op::ADD && x.imm <= 3 && y.rd == rd && (y.rs1 == rd || y.rs2 == rd));
    case Op::ADD: return y_load && y.imm == 0;
    default: return false;
  }
}

// The decode slots are shared: the first thread in priority order takes what it can, and with smt_mix the
// other thread fills the remaining slots in the same cycle.
void Core::decode() {
  if (nthr_ == 1) { decode_thread(*th_[0], (int)c_.decode_width); return; }
  int o[MAX_THREADS];
  order(o, false);
  int slots = (int)c_.decode_width;
  for (int k = 0; k < nthr_ && slots > 0; k++) {
    Thread& T = *th_[(size_t)o[k]];
    const int used = decode_thread(T, slots);
    T.st.decode_slots += (uint64_t)used;
    slots -= used;
    if (used > 0 && !c_.smt_mix) break;
  }
}

int Core::decode_thread(Thread& T, int slots_avail) {
  // The rename/dispatch pipeline holds at most decode_width uops per stage (with SMT, per thread: each thread
  // has its own queue between decode and dispatch, so a stalled thread does not block the other).
  if (T.next_id - T.disp_next >= (uint64_t)(c_.decode_width * (c_.dec_to_disp + 1))) return 0;
  int slots = slots_avail;
  Uop* last = nullptr;
  int scanned = 0;
  while (slots > 0 && !T.fetchq.empty() && scanned < 8) {
    FetchRec& r = T.fetchq.front();
    if (r.avail > t_) break;
    const Decoded& d = *r.di->d;
    // R12: slots from index dec_full on (counted over the whole cycle) have limited decoders.
    if (c_.dec_full > 0 && c_.decode_width - slots >= c_.dec_full && !decode_simple(d.cls)) {
      T.st.dec_slot_stops++;
      break;
    }
    if (c_.fold && d.cls == Cls::JAL && d.rd == 0 && last && !r.mispred && !r.synthetic) {
      last->n_instr++;
      last->seq_next = r.seq + 1;
      T.st.folded++;
      T.fetchq.pop_front();
      scanned++;
      continue;
    }
    if (r.sfb) {
      if (slots < 2) break;
      if (T.fetchq.size() < 2 || T.fetchq[1].avail > t_) break;
      const FetchRec br = r, sh = T.fetchq[1];
      T.fetchq.pop_front();
      T.fetchq.pop_front();
      Uop& cmp = new_uop(T, br);
      cmp.sfb_cmp = true;
      cmp.is_ctrl = false;
      cmp.cls = Cls::ALU;
      cmp.dst_arch = -2;
      cmp.q = c_.iq_unified ? Q_UNI : Q_A0;
      cmp.mispred = false;
      const uint64_t cmp_id = cmp.id;
      Uop& sel = new_uop(T, sh);
      sel.sfb_sel = true;
      sel.q = c_.iq_unified ? Q_UNI : Q_A0;
      sel.seq_next = br.seq + 1 + (sh.synthetic ? 0 : 1);
      if (sel.dst_arch >= 0) {  // the select also reads the old destination value
        bool have = false;
        for (int k = 0; k < sel.nsrc; k++) if (sel.src_arch[k] == sel.dst_arch) have = true;
        if (!have && sel.nsrc < 3) sel.src_arch[sel.nsrc++] = sel.dst_arch;
      }
      if (sel.nsrc < 3) sel.src_arch[sel.nsrc++] = -2;
      sel.sfb_temp_of = cmp_id;
      last = &sel;
      slots -= 2;
      scanned += 2;
      continue;
    }
    const int fuse_slots = c_.fuse_1slot ? 1 : 2;
    if (c_.fusion && slots >= fuse_slots && T.fetchq.size() >= 2 && T.fetchq[1].avail <= t_ &&
        fusible(r, T.fetchq[1])) {
      const FetchRec a = r, b = T.fetchq[1];
      T.fetchq.pop_front();
      T.fetchq.pop_front();
      Uop& u = new_uop(T, b);
      const int ard = a.di->d->rd;
      std::array<int, 3> keep{};
      int nk = 0;
      for (int k = 0; k < u.nsrc; k++) if (u.src_arch[k] != ard) keep[nk++] = u.src_arch[k];
      u.nsrc = 0;
      for (int k = 0; k < nk; k++) u.src_arch[u.nsrc++] = keep[k];
      add_srcs(u, *a.di->d, false);
      if (u.cls == Cls::BR) {  // ALU + branch: the fused uop also writes the ALU result
        u.dst_arch = a.di->d->rd;
        u.fused_br = true;
      }
      u.seq = a.seq;
      u.n_instr = 2;
      u.hist = a.hist;
      T.st.fused++;
      last = &u;
      slots -= fuse_slots;
      scanned += 2;
      continue;
    }
    const FetchRec rr = r;
    T.fetchq.pop_front();
    Uop& u = new_uop(T, rr);
    last = &u;
    slots--;
    scanned++;
    if (rr.de_redirect) {  // fe_m2: decode redirects fetch, which starts again next cycle; the group ends here
      T.fe_blocked = false;
      T.fe_resume = std::max(T.fe_resume, t_ + 1);
      break;
    }
  }
  return slots_avail - slots;
}

// ---------------------------------------------------------------- dispatch

int Core::bank_for(const Uop& u, uint8_t q) const {
  if (u.dst_arch == -1) return -1;
  if (!c_.prf_banked) return u.dst_arch >= 32 ? 1 : 0;
  if (u.dst_arch == -2) return 0;
  if (u.dst_arch >= 32) return u.cls == Cls::FLD ? 4 : 3;
  switch (q) {
    case Q_A0: return 0;
    case Q_A1: return 1;
    case Q_A2: return 5;
    case Q_LD: return 2;
    case Q_SERIAL: return (u.cls == Cls::AMO || u.is_load) ? 2 : 1;
    default: return 1;  // FP -> integer results write through ALU1's port
  }
}

int Core::free_regs(int bank) {
  return (int)(bank_size_[bank] - bank_committed_[bank] - bank_inflight_[bank]);
}

// Rename/dispatch slots are shared like the decode slots; a thread that stalls leaves its slots to the other.
void Core::dispatch() {
  for (auto it = deferred_free_.begin(); it != deferred_free_.end();) {
    if (it->first <= t_) { bank_committed_[it->second]--; it = deferred_free_.erase(it); }
    else ++it;
  }
  int n = 0;
  int row = -1;
  if (nthr_ == 1) { dispatch_thread(*th_[0], n, row); return; }
  int o[MAX_THREADS];
  order(o, false);
  for (int k = 0; k < nthr_ && n < c_.decode_width; k++) {
    Thread& T = *th_[(size_t)o[k]];
    const int before = n;
    dispatch_thread(T, n, row);
    T.st.dispatch_slots += (uint64_t)(n - before);
    if (n > before && !c_.smt_mix) break;
  }
}

void Core::dispatch_thread(Thread& T, int& n, int& row) {
  const int n0 = n;
  auto total = [&](auto f) -> uint64_t {  // occupancy over all threads (shared ROB/LQ/SQ mode only)
    uint64_t s = 0;
    if (nthr_ > 1 && !c_.smt_part) for (auto& Tp : th_) s += f(*Tp);
    return s;
  };
  while (n < c_.decode_width) {
    Uop* up = find(T.disp_next);
    if (!up || up->t_disp_ok > t_) { if (n == n0) T.st.disp_stall_empty++; break; }
    Uop& u = *up;
    if (window_full(c_.rob, T.rob_count, total([](const Thread& x) { return x.rob_count; }), T.tid)) {
      T.st.disp_stall_rob++;
      break;
    }
    const bool lq_need = u.is_load && !u.serial;
    if (lq_need && window_full(c_.lq, T.lq_count, total([](const Thread& x) { return x.lq_count; }), T.tid)) {
      T.st.disp_stall_lq++;
      break;
    }
    if (u.is_store &&
        window_full(c_.sq, T.sq.size(), total([](const Thread& x) { return (uint64_t)x.sq.size(); }), T.tid)) {
      T.st.disp_stall_sq++;
      break;
    }
    uint8_t q = u.q;
    // iq_bank: the bank whose rows see the uop's producers (-1: either; two threads: the thread's own)
    const bool banked = c_.iq_bank && q != Q_SERIAL && !c_.iq_unified;
    int ibank = -1;
    if (banked) {
      ibank = nthr_ > 1 ? T.tid : bank_need(T, u);
      if (ibank == -2) { T.st.disp_stall_bank++; break; }
    }
    auto qfree = [&](uint8_t qq) {
      int64_t f = iq_free(qq, T.tid);
      if (banked) f = std::min(f, ibank >= 0 ? bank_free(qq, ibank) : std::max(bank_free(qq, 0), bank_free(qq, 1)));
      return f;
    };
    if (q == Q_ALU_ANY) {
      int64_t f0 = qfree(Q_A0), f1 = qfree(Q_A1);
      if (c_.prf_banked) { if (free_regs(0) <= 0) f0 = -1; if (free_regs(1) <= 0) f1 = -1; }
      q = (f1 > f0) ? Q_A1 : Q_A0;
      if (c_.alu3) {
        int64_t f2 = qfree(Q_A2);
        if (c_.prf_banked && free_regs(5) <= 0) f2 = -1;
        if (c_.alu3_simple && !alu_simple(u.di->d->op)) {  // R13: ALU2 cannot take it
          if (f2 > 0 && std::max(f0, f1) <= 0) T.st.alu3_steer_stalls++;
          f2 = -1;
        }
        if (f2 > std::max(f0, f1)) q = Q_A2;
      }
    }
    if (q != Q_SERIAL) {
      if (c_.iq_unified && c_.iq_rows) {
        const int64_t rows_cap = c_.iq_size / std::max<int64_t>(1, c_.decode_width);
        if (row < 0 && rows_used_ >= rows_cap) { T.st.disp_stall_iq++; break; }
      } else if (qfree(q) <= 0) { T.st.disp_stall_iq++; break; }
    }
    if (banked && ibank < 0) {  // either bank: the one with more free rows, else the uop's own half
      const int64_t b0 = bank_free(q, 0), b1 = bank_free(q, 1);
      ibank = b0 == b1 ? rob_half(u.id) : (b1 > b0 ? 1 : 0);
    }
    const int bank = bank_for(u, q);
    if (bank >= 0 && free_regs(bank) <= 0) { T.st.disp_stall_reg++; break; }
    const bool need_llt = c_.llt > 0 && !u.serial && long_latency(u);
    if (need_llt) {
      // iq_bank_llt: a tag comes from its producer's half, which only that bank's rows see
      const bool lbank = c_.iq_bank && c_.iq_bank_llt;
      const int h = lbank ? rob_half(u.id) : 0;
      int used = 0, own = 0;
      for (auto& Tp : th_)
        for (auto& w : Tp->win)
          if (w.has_llt && (w.state < 2 || w.t_done > t_)) {
            used++;
            if (lbank ? rob_half(w.id) == h : w.tid == T.tid) own++;
          }
      for (auto& p : pending_)
        if (p.second > t_) {
          used++;
          if (lbank ? rob_half(p.first) == h : (p.first >> TID_SHIFT) == (uint64_t)T.tid) own++;
        }
      int64_t cap = nthr_ > 1 ? std::max<int64_t>(1, (c_.llt * c_.smt_llt_cap + 99) / 100) : c_.llt;
      if (lbank) cap = std::min<int64_t>(cap, (c_.llt + 1 - h) / 2);
      if (used >= c_.llt || own >= cap) { T.st.disp_stall_llt++; break; }
    }
    const bool mx_class = (q == Q_A0 || q == Q_A1 || q == Q_A2) &&
                          (u.cls == Cls::ALU || u.is_ctrl || u.sfb_cmp || u.sfb_sel);
    const bool need_wtag = c_.wake_tags > 0 && u.dst_arch != -1 && !need_llt && !mx_class;
    if (need_wtag && wtags_used() >= c_.wake_tags) { T.st.disp_stall_wtag++; break; }
    // allocate
    u.q = q;
    u.has_wtag = need_wtag;
    if (banked) u.iq_bank = (uint8_t)ibank;
    u.dst_bank = bank;
    if (bank >= 0) bank_inflight_[bank]++;
    u.has_llt = need_llt;
    if (lq_need) { T.lq_count++; u.in_lq = true; }
    if (u.is_ctrl && (u.cls == Cls::BR || u.cls == Cls::JALR) && c_.ckpt > 0) {
      int used = T.ckpt_used;
      if (nthr_ > 1 && c_.smt_ckpt_shared) {  // R10: one pool for both threads
        used = 0;
        for (auto& Tp : th_) used += Tp->ckpt_used;
      }
      if (used < c_.ckpt) { T.ckpt_used++; u.has_ckpt = true; }
      else T.st.ckpt_none++;
    }
    for (int k = 0; k < u.nsrc; k++)
      u.src_prod[k] = u.src_arch[k] == -2 ? u.sfb_temp_of : T.rat[(size_t)u.src_arch[k]];
    if (c_.census && q != Q_SERIAL)
      for (int k = 0; k < u.nsrc; k++) census_source(T, q, u.src_prod[k], u.id);
    if (u.sfb_sel) {
      if (const Uop* cmp = find(u.sfb_temp_of)) u.sfb_temp_bank = cmp->dst_bank;
    }
    if (u.data_arch >= 0) u.data_prod = T.rat[(size_t)u.data_arch];
    if (u.dst_arch >= 0) T.rat[(size_t)u.dst_arch] = u.id;
    if (u.is_store) {
      SqEntry e;
      e.id = u.id; e.addr = u.addr; e.size = u.size; e.mmio = u.mmio; e.data_prod = u.data_prod;
      T.sq.push_back(e);
    }
    T.rob_count++;
    u.state = 1;
    u.age = age_next_++;
    u.t_eligible = t_ + 1;
    if (q != Q_SERIAL) {
      iq_[q].push_back(u.id);
      if (c_.iq_unified && c_.iq_rows) {
        if (row < 0) { row = next_row_++; rows_used_++; }
        u.row = row;
        row_left_[row]++;
      }
    }
    T.disp_next++;
    n++;
  }
}

// ---------------------------------------------------------------- issue / execute

void Core::iq_remove(Uop& u) {
  auto& v = iq_[u.q];
  auto it = std::find(v.begin(), v.end(), u.id);
  if (it != v.end()) v.erase(it);
  if (u.row >= 0) {
    auto r = row_left_.find(u.row);
    if (r != row_left_.end() && --r->second == 0) { row_left_.erase(r); rows_used_--; }
    u.row = -1;
  }
}

// A replayed uop goes back to its place in age order (queues are kept in dispatch order).
void Core::iq_reinsert(Uop& u) {
  auto& v = iq_[u.q];
  const auto it = std::lower_bound(v.begin(), v.end(), u.age,
                                   [this](uint64_t id, uint64_t a) { return find(id)->age < a; });
  v.insert(it, u.id);
}

bool Core::can_issue(Uop& u) {
  if (u.t_eligible > t_) return false;
  for (int k = 0; k < u.nsrc; k++) if (!src_ready(u.src_prod[k], t_)) return false;
  if (u.cls == Cls::DIV && div_busy_ > t_) return false;
  if ((u.cls == Cls::FDIV || u.cls == Cls::FSQRT) && fdiv_busy_ > t_) return false;
  Thread& T = th(u);
  if (u.is_load && c_.mdp && waittab_.at(u.di->pc ^ T.salt)) {
    for (auto& s : T.sq) {
      if (s.id >= u.id) break;
      if (s.t_addr > t_) { T.st.mdp_waits++; return false; }
    }
  }
  if (c_.prf_banked && u.q == Q_A1) {
    const uint64_t lat = u.cls == Cls::MUL ? (uint64_t)c_.lat_mul : u.cls == Cls::DIV ? 0 : 1 + (uint64_t)c_.abl_alu;
    if (lat && wb_b1_[(t_ + lat) % wb_b1_.size()] == t_ + lat) return false;
  }
  return true;
}

void Core::resolve_branch(Uop& u, uint64_t when) {
  Thread& T = th(u);
  const bool ck = u.has_ckpt;
  if (ck) { T.ckpt_used--; u.has_ckpt = false; }
  if (!u.mispred) return;
  if (ck) {
    u.resolved = true;
    T.fe_blocked = false;
    T.fe_resume = std::max(T.fe_resume, when + (uint64_t)c_.redirect_lat);
    T.st.mp_resolved_exec++;
  }
}

void Core::exec_load(Uop& u) {
  Thread& T = th(u);
  const uint64_t t = t_, t_ag = t + 2;
  const uint64_t d = (uint64_t)c_.abl_ld_use, dn = (uint64_t)c_.abl_done;
  T.st.loads++;
  bool violated = false;
  for (auto it = T.sq.rbegin(); it != T.sq.rend(); ++it) {
    SqEntry& s = *it;
    if (s.id > u.id || s.mmio) continue;
    if (!(s.addr < u.addr + u.size && u.addr < s.addr + s.size)) continue;
    if (s.t_addr <= t_ag) {
      const bool covers = s.addr <= u.addr && s.addr + s.size >= u.addr + u.size;
      const bool ok = covers && (!c_.fwd_strict || (s.addr == u.addr && s.size == u.size));
      if (ok) {
        const uint64_t dt = s.data_now ? s.t_addr : prod_ready_time(s.data_prod);
        if (dt == NEVER) {  // data producer not issued yet: retry later
          u.state = 1; u.t_eligible = t + 4; u.t_issue = NEVER;
          iq_reinsert(u);
          T.st.ld_fwd_wait++;
          return;
        }
        u.t_ag = t_ag;
        if (dt <= t + 3) { u.t_ready = t + (uint64_t)c_.ld_fwd_lat + d; T.st.ld_fwd++; }
        else { u.t_ready = dt + (uint64_t)c_.ld_fwd_wait + d; T.st.ld_fwd_wait++; }
        u.t_done = u.t_ready + 1 + dn;
        return;
      }
      T.st.ld_partial++;  // partial overlap: wait for the store to drain
      u.state = 1; u.t_eligible = t + 8; u.t_issue = NEVER;
      iq_reinsert(u);
      return;
    }
    violated = true;  // an older store with an unknown address will overlap
    break;
  }
  mem_.tid = T.tid;
  uint64_t ready = 0;
  const MemSys::Res res = mem_.l1d(pa(T, u.addr), t + 3, MemSys::LOAD, ready);
  if (res == MemSys::Res::NO_MSHR) {
    T.st.ld_no_mshr++;
    u.state = 1; u.t_eligible = std::max(t + 1, mem_.l1d_mshr_free_at(t + 3) - 3); u.t_issue = NEVER;
    iq_reinsert(u);
    return;
  }
  if (violated) { u.violated = true; T.st.violations++; }
  u.t_ag = t_ag;
  const bool hit = res == MemSys::Res::HIT;
  uint8_t& hp = hitpred_.at(u.di->pc ^ T.salt);
  const bool pred_hit = !c_.hit_pred || hp >= 2;
  if (hit) { if (hp < 3) hp++; T.st.ld_l1_hit++; }
  else { if (hp > 0) hp--; T.st.ld_l1_miss++; }
  if (hit) {
    u.t_ready = (c_.spec_wakeup && pred_hit) ? t + 3 + d : t + 5 + d;
  } else {
    u.t_ready = ready + 2 + d;
    if (c_.spec_wakeup && pred_hit) {
      T.st.hitpred_wrong++;
      if (c_.hitmiss_flush) {
        if (!T.pflush.v || u.id + 1 < T.pflush.from_id) {
          T.pflush.v = true; T.pflush.at = t + 4 + d; T.pflush.from_id = u.id + 1; T.pflush.resume = u.seq_next;
        }
      } else if (c_.shadow > 0) {
        // The shadow cancel is not selective: it cancels whatever any thread issues in the shadow.
        if (cancel_from_ == NEVER || t + 3 + d > cancel_to_) cancel_from_ = t + 3 + d;
        cancel_to_ = std::max(cancel_to_, t + 2 + d + (uint64_t)c_.shadow);
        cancel_tid_ = T.tid;
        T.st.shadow_cancels++;
      }
    }
  }
  u.t_done = u.t_ready + 1 + dn;
  mem_.train_stride(pa(T, u.di->pc), pa(T, u.addr), t + 3);
}

void Core::exec_store(Uop& u) {
  Thread& T = th(u);
  const uint64_t t = t_;
  T.st.stores++;
  u.t_ag = t + 2;
  for (auto& s : T.sq)
    if (s.id == u.id) {
      s.t_addr = t + 2;
      if (!c_.sta_split) s.data_now = true;
      break;
    }
  mem_.tid = T.tid;
  if (c_.rfo_pf && !mem_.l1d_present(pa(T, u.addr), t + 2)) {
    uint64_t r;
    mem_.l1d(pa(T, u.addr), t + 2, MemSys::RFO_PF, r);
  }
  if (c_.rfo_pf) mem_.train_stride(pa(T, u.di->pc), pa(T, u.addr), t + 2);  // store streams prefetch ownership ahead
  u.t_ready = t + 1;
  u.t_done = t + 3 + (uint64_t)c_.abl_done + (uint64_t)c_.abl_st_done;  // address done; data readiness is checked at commit
}

void Core::do_issue(Uop& u, int /*port*/) {
  iq_remove(u);
  u.state = 2;
  u.t_issue = t_;
  const uint64_t t = t_;
  auto reserve_b1 = [&](uint64_t when) { if (c_.prf_banked) wb_b1_[when % wb_b1_.size()] = when; };
  const bool fp_d = u.di->d->fmt == 1;
  bool one_cycle = false;
  switch (u.cls) {
    case Cls::LD: case Cls::FLD: exec_load(u); return;
    case Cls::ST: case Cls::FST: exec_store(u); return;
    case Cls::MUL: u.t_ready = t + (uint64_t)c_.lat_mul; if (u.q == Q_A1) reserve_b1(u.t_ready); break;
    case Cls::DIV: {
      const uint64_t lat = (uint64_t)c_.div_base +
                           ((uint64_t)u.di->lat_hint + (uint64_t)c_.div_bits_per_cycle - 1) /
                               (uint64_t)std::max<int64_t>(1, c_.div_bits_per_cycle);
      div_busy_ = t + lat;
      u.t_ready = t + lat;
      break;
    }
    case Cls::FMA: u.t_ready = t + (uint64_t)c_.lat_fma; break;
    // Divide/sqrt: an iterative unit is busy for the whole operation (fdiv_ii = 0); a multiplicative
    // (Goldschmidt) unit with pipelined multipliers accepts a new operation every fdiv_ii cycles.
    case Cls::FDIV: { const uint64_t lat = (uint64_t)(fp_d ? c_.lat_fdiv_d : c_.lat_fdiv_s);
                      fdiv_busy_ = t + (c_.fdiv_ii > 0 ? (uint64_t)c_.fdiv_ii : lat); u.t_ready = t + lat; break; }
    case Cls::FSQRT: { const uint64_t lat = (uint64_t)(fp_d ? c_.lat_fsqrt_d : c_.lat_fsqrt_s);
                       fdiv_busy_ = t + (c_.fdiv_ii > 0 ? (uint64_t)c_.fdiv_ii : lat); u.t_ready = t + lat; break; }
    case Cls::FTOI: u.t_ready = t + (uint64_t)c_.lat_fmisc; reserve_b1(u.t_ready); break;
    case Cls::FMISC: case Cls::ITOF: u.t_ready = t + (uint64_t)c_.lat_fmisc; break;
    default:
      u.t_ready = t + 1 + (uint64_t)c_.abl_alu;
      one_cycle = true;
      if (u.q == Q_A1) reserve_b1(u.t_ready);
      break;
  }
  u.t_done = u.t_ready - (one_cycle ? (uint64_t)c_.abl_alu : 0) + 2 + (uint64_t)c_.abl_done;
  if (u.is_ctrl) resolve_branch(u, t + 2 + (u.fused_br ? 1 : 0));
}

// The queues hold both threads' uops in dispatch order, so select is oldest first across threads.
void Core::issue() {
  const bool cancel = t_ >= cancel_from_ && t_ <= cancel_to_ && cancel_from_ != NEVER;
  std::vector<Uop*> picks;
  auto take = [&](Uop* u) { if (u) picks.push_back(u); };
  if (c_.iq_unified) {
    Uop* p2 = nullptr;
    Uop* alu[2] = {nullptr, nullptr};
    for (uint64_t id : iq_[Q_UNI]) {
      Uop* u = find(id);
      if (!u || !can_issue(*u)) continue;
      const bool alu_cls = u->cls == Cls::ALU || u->cls == Cls::ALUX || u->is_ctrl || u->sfb_cmp || u->sfb_sel;
      if (alu_cls) { if (!alu[0]) alu[0] = u; else if (!alu[1]) alu[1] = u; }
      else if (!p2) p2 = u;
      if (p2 && alu[1]) break;
    }
    take(alu[0]); take(alu[1]); take(p2);
  } else {
    for (uint8_t q : {Q_A0, Q_A1, Q_A2, Q_LD, Q_STA, Q_FP}) {  // Q_A2 stays empty unless alu3
      const int ports = q == Q_LD   ? (int)std::max<int64_t>(1, c_.ld_ports)
                        : q == Q_FP ? (int)std::max<int64_t>(1, c_.fp_ports)
                                    : 1;
      Uop* first = nullptr;
      Uop* first_br = nullptr;
      bool fdiv_picked = false;
      std::vector<Uop*> ready;
      for (uint64_t id : iq_[q]) {
        Uop* u = find(id);
        if (!u || !can_issue(*u)) continue;
        if (u->cls == Cls::FDIV || u->cls == Cls::FSQRT) {  // one iterative divide/sqrt unit
          if (fdiv_picked) continue;
          fdiv_picked = true;
        }
        if (q == Q_A0 && c_.br_first && u->is_ctrl && !first_br) first_br = u;
        if (!first) first = u;
        ready.push_back(u);
        if ((int)ready.size() >= ports && !(q == Q_A0 && c_.br_first && !first_br)) break;
      }
      if (q == Q_A0 && first_br) { take(first_br); continue; }
      for (int k = 0; k < ports && k < (int)ready.size(); k++) take(ready[(size_t)k]);
    }
    // R11: ALU2 has no register-file read ports of its own. Its operand 0 reads through the STA port and its
    // operand 1 through the shared port (FP's integer source); their owners win, and a refused ALU2 pick
    // stays in its queue. (Store data also uses the shared port; that is not modelled.)
    if (c_.alu3 && c_.rf_share_a2) {
      bool sta = false, sh = false;
      Uop* a2 = nullptr;
      for (Uop* u : picks) {
        if (u->q == Q_STA && int_srcs(*u) > 0) sta = true;
        else if (u->q == Q_FP && int_srcs(*u) > 0) sh = true;
        else if (u->q == Q_A2) a2 = u;
      }
      const int n = a2 ? int_srcs(*a2) : 0;
      if ((n >= 1 && sta) || (n >= 2 && sh)) {
        picks.erase(std::find(picks.begin(), picks.end(), a2));
        th(*a2).st.rf_port_conflicts++;
      }
    }
  }
  for (Uop* u : picks) {
    if (cancel) {
      u->t_eligible = cancel_to_ + 1;
      th(*u).st.cancelled_issues++;
      continue;
    }
    do_issue(*u, 0);
  }
}

// ---------------------------------------------------------------- commit

bool Core::early_retire_ok(Uop& u) {
  if (u.state != 2 || u.t_ready == NEVER) return false;
  if (u.is_load) {
    const Thread& T = th(u);
    uint64_t total = 0;
    if (nthr_ > 1 && !c_.smt_part) for (auto& Tp : th_) total += Tp->lqcb_done.size();
    return !u.violated && u.t_ag <= t_ && !window_full(c_.lqcb, T.lqcb_done.size(), total, T.tid);
  }
  return u.cls == Cls::DIV || u.cls == Cls::FDIV || u.cls == Cls::FSQRT;
}

void Core::train_predictors(const Uop& u) {
  const uint64_t salt = th_[u.tid]->salt;
  const DynInst& di = *u.di;
  const Decoded& d = *di.d;
  if (d.cls == Cls::BR) {
    dir_->update(di.pc ^ salt, u.hist, di.taken);
    if (di.taken) btb_.insert(di.pc ^ salt, di.next_pc, 0);
  } else if (d.cls == Cls::JAL) {
    btb_.insert(di.pc ^ salt, di.next_pc, 1);
  } else if (d.cls == Cls::JALR) {
    btb_.insert(di.pc ^ salt, di.next_pc, d.is_ret() ? 2 : 3);
  }
}

// Region markers of a thread's first run. With two threads, the overlap window is where both first-run
// regions are open.
void Core::region_event(Thread& T, bool start) {
  T.st.cycles = t_;
  const MemStats& ms = nthr_ > 1 ? mem_.tst[T.tid] : mem_.st;
  if (start) {
    T.in_region = true;
    T.region_seen = true;
    T.st_start = T.st;
    T.ms_start = ms;
    T.r_start_cycle = t_;
  } else {
    T.in_region = false;
    T.st_end = T.st;
    T.ms_end = ms;
    T.r_end_cycle = t_;
    if (const char* f = std::getenv("TGSIM_MPDUMP")) {  // calibration: mispredicts by PC (scripts/rtlcal.py)
      if (FILE* o = std::fopen(f, "w")) {
        for (auto& kv : mp_pc_) std::fprintf(o, "%llx %u\n", (unsigned long long)kv.first, kv.second);
        std::fclose(o);
      }
    }
  }
  if (nthr_ == 1) return;
  if (start) overlap_check_start();
  else if (ov_started_ && !ov_ended_) {
    ov_ended_ = true;
    ov_end_ = t_;
    for (auto& Tp : th_) ov_i1_[(size_t)Tp->tid] = Tp->st.instr;
  }
}

void Core::overlap_check_start() {
  if (ov_started_) return;
  for (auto& Tp : th_) if (!Tp->in_region || Tp->lap > 0) return;
  ov_started_ = true;
  ov_start_ = t_;
  for (auto& Tp : th_) {
    ov_i0_[(size_t)Tp->tid] = Tp->st.instr;
    ov_r0_[(size_t)Tp->tid] = Tp->st.instr - Tp->st_start.instr;
  }
}

void Core::retire(Uop& u, bool early) {
  Thread& T = th(u);
  if (early) {
    pending_[u.id] = u.t_ready;
    T.st.early_retired++;
    if (u.is_load) T.lqcb_done.push_back(u.t_done);
  }
  T.st.instr += u.n_instr;
  T.st.uops++;
  if (T.refill_from != NEVER) {  // the first retire after a mispredict recovered at commit: the refill
    T.st.mp_refill_cycles += t_ - T.refill_from;
    T.st.mp_refills++;
    T.refill_from = NEVER;
  }
  if (u.di && u.di->marker && T.lap == 0) {  // later runs of a restarted program are not measured
    if (u.di->marker == 1 && !T.in_region) region_event(T, true);
    else if (u.di->marker == 2 && T.in_region) region_event(T, false);
  }
  if (u.is_ctrl) {
    if (u.mispred) {
      if (!u.resolved) {
        T.fe_blocked = false;
        T.fe_resume = std::max(T.fe_resume, t_ + (uint64_t)c_.commit_redirect);
        T.st.mp_resolved_commit++;
        T.refill_from = t_;
      }
      if (T.in_region && u.di) mp_pc_[u.di->pc]++;
      switch (u.mp_kind) {
        case 1: T.st.mp_dir++; break;
        case 2: T.st.mp_target++; break;
        case 3: T.st.mp_ret++; break;
        default: T.st.mp_cold++; break;
      }
      const Decoded* sh = nullptr;
      if (c_.sfb && u.cls == Cls::BR && sfb_shape(T, *u.di, &sh)) sfb_tab_.bump(u.di->pc ^ T.salt, 1, 3);
    }
    train_predictors(u);
  }
  if (u.has_ckpt) { T.ckpt_used--; u.has_ckpt = false; }
  if (u.in_lq) T.lq_count--;
  if (u.is_store)
    for (auto& s : T.sq) if (s.id == u.id) { s.committed = true; break; }
  if (u.dst_arch >= 0) {
    const int b = u.dst_bank;
    bank_inflight_[b]--;
    bank_committed_[b]++;
    const int ob = T.arch_bank[(size_t)u.dst_arch];
    const uint64_t op = T.arch_prod[(size_t)u.dst_arch];
    uint64_t pt = 0;
    if (op) {
      auto it = pending_.find(op);
      if (it != pending_.end() && it->second > t_) pt = it->second;
    }
    if (ob >= 0) {
      if (pt) deferred_free_.push_back({pt, ob});
      else bank_committed_[ob]--;
    }
    T.arch_bank[(size_t)u.dst_arch] = b;
    T.arch_prod[(size_t)u.dst_arch] = u.id;
  }
  if (u.sfb_sel && u.sfb_temp_bank >= 0) bank_inflight_[u.sfb_temp_bank]--;
  T.rob_count--;
  T.win.pop_front();
  T.win_base++;
}

// Commit slots are shared; the thread that goes first alternates every cycle.
void Core::commit() {
  for (auto& Tp : th_)
    while (!Tp->lqcb_done.empty() && Tp->lqcb_done.front() <= t_) Tp->lqcb_done.pop_front();
  if ((t_ & 1023) == 0)
    for (auto it = pending_.begin(); it != pending_.end();) it = it->second <= t_ ? pending_.erase(it) : std::next(it);
  if (nthr_ == 1) { commit_thread(*th_[0], (int)c_.commit_width); return; }
  int left = (int)c_.commit_width;
  const int first = (int)(t_ % (uint64_t)nthr_);
  for (int k = 0; k < nthr_ && left > 0; k++) {
    const int used = commit_thread(*th_[(size_t)((first + k) % nthr_)], left);
    left -= used;
    if (used > 0 && !c_.smt_mix) break;
  }
}

int Core::commit_thread(Thread& T, int width) {
  int n = 0;
  bool any = false;
  while (n < width && !T.win.empty()) {
    Uop& u = T.win.front();
    if (u.state == 0) break;
    if (u.serial) {
      if (u.state == 1) {
        if (u.cls == Cls::FENCE && !T.sq.empty() && T.sq.front().id < u.id) break;
        bool rdy = true;
        for (int k = 0; k < u.nsrc; k++) if (!src_ready(u.src_prod[k], t_)) rdy = false;
        if (!rdy) break;
        u.state = 2;
        u.t_issue = t_;
        uint64_t lat = (uint64_t)c_.lat_serial;
        if (u.mmio) lat = (uint64_t)c_.lat_mmio;
        else if (u.cls == Cls::AMO) {
          mem_.tid = T.tid;
          uint64_t r = t_;
          const MemSys::Res res = mem_.l1d(pa(T, u.addr), t_, MemSys::STORE, r);
          lat = res == MemSys::Res::HIT ? 4 : res == MemSys::Res::MISS ? (r - t_) + 4 : 16;
        }
        u.t_ready = t_ + lat;
        u.t_done = t_ + lat + (uint64_t)c_.abl_done;
        if (u.is_store)
          for (auto& s : T.sq) if (s.id == u.id) { s.t_addr = t_; s.data_now = true; break; }
        break;
      }
      if (u.t_done > t_) break;
    } else if (u.is_load && u.violated && u.state == 2) {
      T.st.violation_flushes++;
      waittab_.at(u.di->pc ^ T.salt) = 1;
      flush_from(T, u.id, u.seq);
      T.fe_resume = std::max(T.fe_resume, t_ + (uint64_t)c_.commit_redirect);
      T.last_commit_t = t_;
      return n;
    } else {
      bool done = u.state == 2 && u.t_done <= t_;
      if (done && u.is_store && c_.sta_split && u.data_arch >= 0) done = src_ready(u.data_prod, t_ - 1);
      if (!done) {
        if (c_.early_retire && early_retire_ok(u)) { retire(u, true); n++; any = true; continue; }
        break;
      }
    }
    retire(u, false);
    n++;
    any = true;
  }
  if (any) T.last_commit_t = t_;
  else T.st.commit_stall_cycles++;
  return n;
}

// Committed stores drain in order per thread through the one D$ store port; with two threads the thread
// tried first alternates every cycle.
void Core::drain_stores() {
  if (nthr_ == 1) { drain_thread(*th_[0]); return; }
  const int first = (int)(t_ % (uint64_t)nthr_);
  for (int k = 0; k < nthr_; k++)
    if (drain_thread(*th_[(size_t)((first + k) % nthr_)])) break;
}

// Returns true when the thread used the D$ this cycle (a store write or an ownership request).
bool Core::drain_thread(Thread& T) {
  if (T.sq.empty() || !T.sq.front().committed) return false;
  SqEntry& s = T.sq.front();
  if (s.mmio) { T.sq.pop_front(); return false; }
  mem_.tid = T.tid;
  if (mem_.l1d_present(pa(T, s.addr), t_)) {
    uint64_t r;
    mem_.l1d(pa(T, s.addr), t_, MemSys::STORE, r);
    T.sq.pop_front();
    T.drain_wait = NEVER;
    return true;
  }
  // With SMT, the line requested for the store can be evicted before the store drains (the sibling's misses churn
  // the L1D sets), so the store asks again. Single-thread runs keep M1's behaviour; no single-thread run of the
  // suite loses such a line (checked at 30/120/250 cycles on tanager_v1 and v1_freeze).
  const bool lost = s.rfo && !mem_.l1d_has(pa(T, s.addr));
  if (!s.rfo || (nthr_ > 1 && lost)) {
    uint64_t r;
    if (mem_.l1d(pa(T, s.addr), t_, MemSys::STORE, r) != MemSys::Res::NO_MSHR) {
      s.rfo = true;
      T.drain_wait = NEVER;
    } else if (T.drain_wait == NEVER) {
      T.drain_wait = t_;
    }
    return true;
  }
  return false;
}

// With one L1D MSHR, loads book it at their access time (issue + 3) while the drain asks at the current cycle, so a
// sibling thread's stream of misses can hold off a committed store for good. With `drain_guard` set, a store that has
// waited that long makes loads and prefetches leave it an MSHR.
int Core::drain_reserve() const {
  if (c_.drain_guard <= 0) return 0;
  for (auto& Tp : th_)
    if (Tp->drain_wait != NEVER && t_ >= Tp->drain_wait + (uint64_t)c_.drain_guard) return 1;
  return 0;
}

// ---------------------------------------------------------------- flush (memory-order violation, NaxRiscv hit flush)

// Flushes one thread from from_id on. The other thread, and every early-retired operation, are untouched.
void Core::flush_from(Thread& T, uint64_t from_id, uint64_t resume_seq) {
  Hist oldest = T.ghr;
  for (auto it = T.fetchq.rbegin(); it != T.fetchq.rend(); ++it) {
    if (it->ras.op) T.ras.restore(it->ras.sp, it->ras.slot, it->ras.val);
    oldest = it->hist;
  }
  T.fetchq.clear();
  while (!T.win.empty() && T.win.back().id >= from_id) {
    Uop& u = T.win.back();
    if (u.ras.op) T.ras.restore(u.ras.sp, u.ras.slot, u.ras.val);
    oldest = u.hist;
    if (u.state >= 1) {
      T.rob_count--;
      if (u.state == 1 && u.q != Q_SERIAL) iq_remove(u);
      if (u.in_lq) T.lq_count--;
      if (u.dst_bank >= 0) bank_inflight_[u.dst_bank]--;
      if (u.has_ckpt) T.ckpt_used--;
      if (u.is_store && !T.sq.empty() && T.sq.back().id == u.id) T.sq.pop_back();
    }
    T.win.pop_back();
  }
  T.ghr = oldest;
  T.next_id = from_id;
  T.disp_next = std::min(T.disp_next, from_id);
  T.rat.fill(0);
  for (auto& u : T.win) if (u.state >= 1 && u.dst_arch >= 0) T.rat[(size_t)u.dst_arch] = u.id;
  T.fe_blocked = false;
  T.fetch_seq = resume_seq;
  T.fe_resume = std::max(T.fe_resume, t_ + 1);
  if (nthr_ == 1 || cancel_tid_ == T.tid) cancel_from_ = NEVER;
  if (T.pflush.v && T.pflush.from_id >= from_id) T.pflush.v = false;
}

// ---------------------------------------------------------------- main loop

// One source of a uop being dispatched into queue q: what its readiness would have to wait on.
void Core::census_source(const Thread& T, uint8_t q, uint64_t prod, uint64_t cons) {
  auto& c = census_[q];
  if (!prod) { c[CK_READY]++; return; }
  if ((prod >> TID_SHIFT) != (uint64_t)T.tid) { c[CK_XTHREAD]++; return; }
  const Uop* p = find(prod);
  if (!p) {  // retired: either complete, or early-retired and still pending on its long-latency tag
    auto it = pending_.find(prod);
    c[it != pending_.end() && it->second > t_ ? CK_LLT : CK_READY]++;
    return;
  }
  if (p->state == 2 && p->t_ready <= t_) { c[CK_READY]++; return; }
  if (p->has_llt) { c[CK_LLT]++; return; }
  if (rob_half(prod) != rob_half(cons)) census_xhalf_[q]++;
  if (mx_named(*p)) { c[CK_MX]++; return; }
  c[CK_ROB]++;
  census_rob_from_[q][p->q]++;
  if ((p->q == Q_A0 || p->q == Q_A1 || p->q == Q_A2) &&
      (p->cls == Cls::ALU || p->is_ctrl || p->sfb_cmp || p->sfb_sel))
    census_rob_1c_[q]++;
}

void Core::sample_mlp() {
  for (auto& Tp : th_) {
    Stats& s = Tp->st;
    const uint64_t n = (uint64_t)mem_.l1d_demand_outstanding(t_, nthr_ > 1 ? Tp->tid : -1);
    s.mlp_sum += n;
    if (n) s.mlp_cycles_nz++;
    s.mlp_max = std::max(s.mlp_max, n);
  }
}

// Executes functionally up to the region start marker (caches and predictors stay cold). Returns whether
// the marker was found.
bool Core::fast_forward(Thread& T) {
  DynInst di;
  bool found = false;
  while (T.iss->step(di))
    if (di.marker == 1) { found = true; break; }
  T.stream_base = di.seq + 1;
  T.fetch_seq = T.stream_base;
  if (!found) T.iss_done = true;
  return found;
}

bool Core::finished(Thread& T) {
  return T.iss_done && T.win.empty() && T.fetchq.empty() && T.sq.empty() && !stream_has(T, T.fetch_seq);
}

// End of a thread's first run: a region that never started covers the whole run; one still open ends here.
void Core::end_first_region(Thread& T) {
  T.st.cycles = t_;
  if (!T.region_seen) {
    T.st_end = T.st;
    T.ms_end = nthr_ > 1 ? mem_.tst[T.tid] : mem_.st;
    T.r_end_cycle = t_;
  } else if (T.in_region) {
    if (nthr_ > 1) region_event(T, false);
    else { T.st_end = T.st; T.ms_end = mem_.st; T.r_end_cycle = t_; }
  }
}

// Runs the thread's program again (multithreaded runs), so it keeps loading the core until the other
// thread's first run is complete. Its window is empty; caches, predictors and IDs carry on.
void Core::restart(Thread& T) {
  T.owned = std::make_unique<Iss>(T.spec.ram_base, T.spec.ram_size);
  std::string e;
  if (!T.owned->load_elf(T.spec.elf, e)) { err_ = "restart: " + e; return; }
  T.owned->set_stdin(T.spec.stdin_text);
  T.iss = T.owned.get();
  T.stream.clear();
  T.stream_base = 0;
  T.fetch_seq = 0;
  T.iss_done = false;
  if (T.spec.ff) {
    fast_forward(T);
    if (!T.iss->error().empty()) { err_ = "restart ISS: " + T.iss->error(); return; }
  }
  T.fe_blocked = false;
  T.fe_resume = t_ + 1;
  T.lap++;
  T.last_commit_t = t_;
}

bool Core::run() {
  if (!err_.empty()) return false;
  for (auto& Tp : th_) {
    Thread& T = *Tp;
    if (!T.spec.ff) continue;
    const bool found = fast_forward(T);
    if (!T.iss->error().empty()) { err_ = "ISS: " + T.iss->error(); return false; }
    if (found) { T.in_region = true; T.region_seen = true; }
  }
  if (nthr_ > 1) overlap_check_start();
  for (t_ = 0;; t_++) {
    for (auto& Tp : th_) Tp->st.cycles = t_;
    for (auto& Tp : th_) {
      Thread& T = *Tp;
      if (T.pflush.v && T.pflush.at <= t_) {
        const PendingFlush f = T.pflush;
        T.pflush.v = false;
        if (find(f.from_id - 1)) {
          T.st.hitmiss_flushes++;
          flush_from(T, f.from_id, f.resume);
        }
      }
    }
    if (c_.mdp_clear > 0 && t_ % (uint64_t)c_.mdp_clear == 0) waittab_.reset();
    commit();
    drain_stores();
    mem_.drain_reserve = drain_reserve();
    issue();
    dispatch();
    decode();
    fetch();
    sample_mlp();
    if (!err_.empty()) return false;
    if (nthr_ == 1) {
      if (finished(*th_[0])) break;
    } else {
      // The run ends when every thread's first run is complete; a thread that finishes earlier restarts.
      bool all = true;
      for (auto& Tp : th_) {
        Thread& T = *Tp;
        if (finished(T)) {
          if (!T.first_done) {
            T.first_done = true;
            T.first_exit = T.iss->exit_code();
            T.first_stdout = T.iss->stdout_buf();
            T.first_cycles = t_;
            T.first_instr = T.st.instr;
            end_first_region(T);
          }
          bool others = false;
          for (auto& U : th_) if (!U->first_done) others = true;
          if (others) restart(T);
          if (!err_.empty()) return false;
        }
        all = all && T.first_done;
      }
      if (all) break;
    }
    if (c_.max_cycles && (int64_t)t_ >= c_.max_cycles) break;
    for (auto& Tp : th_) {
      const Thread& T = *Tp;
      if (t_ - T.last_commit_t <= 500000) continue;
      char buf[256];
      const Uop* h = T.win.empty() ? nullptr : &T.win.front();
      std::snprintf(buf, sizeof buf, "deadlock at cycle %llu: %shead id=%llu cls=%s state=%d pc=0x%llx",
                    (unsigned long long)t_, nthr_ > 1 ? (T.tid ? "thread 1 " : "thread 0 ") : "",
                    h ? (unsigned long long)h->id : 0ull, h ? cls_name(h->cls) : "-", h ? h->state : -1,
                    h ? (unsigned long long)h->di->pc : 0ull);
      err_ = buf;
      if (nthr_ > 1) {
        const SqEntry* s = T.sq.empty() ? nullptr : &T.sq.front();
        std::snprintf(buf, sizeof buf, "; rob %llu lq %llu sq %zu (head committed %d rfo %d present %d)",
                      (unsigned long long)T.rob_count, (unsigned long long)T.lq_count, T.sq.size(), s ? s->committed : -1,
                      s ? s->rfo : -1, s ? (int)mem_.l1d_present(pa(T, s->addr), t_) : -1);
        err_ += buf;
      }
      return false;
    }
    if ((t_ & 1023) == 0)
      for (auto& Tp : th_) prune_stream(*Tp);
  }
  for (auto& Tp : th_) {
    Thread& T = *Tp;
    T.st.cycles = t_;
    if (nthr_ == 1) {
      if (!T.region_seen) { T.st_end = T.st; T.ms_end = mem_.st; T.r_end_cycle = t_; }
      else if (T.in_region) { T.st_end = T.st; T.ms_end = mem_.st; T.r_end_cycle = t_; }
    } else if (!T.first_done) {
      end_first_region(T);  // stopped by max_cycles
    }
  }
  return true;
}

std::string Core::region_json(const Thread& T) const {
  std::ostringstream o;
  o << "{";
  bool first = true;
#define TG_RJ(n)                                                                                   \
  o << (first ? "" : ",") << "\"" #n "\":" << (T.st_end.n - (T.region_seen ? T.st_start.n : 0));  \
  first = false;
  TG_STATS(TG_RJ)
  if (nthr_ > 1) { TG_SMT_STATS(TG_RJ) }
  if (c_.rf_share_a2 || c_.dec_full || c_.alu3_simple || c_.smt_ckpt_shared || c_.iq_bank || c_.wake_tags) {
    TG_LEVER_STATS(TG_RJ)
  }
#undef TG_RJ
#define TG_MJ(n) o << ",\"" #n "\":" << (T.ms_end.n - (T.region_seen ? T.ms_start.n : 0));
  TG_MEMSTATS(TG_MJ)
#undef TG_MJ
  o << ",\"mlp_peak\":" << T.st_end.mlp_max;
  o << "}";
  return o.str();
}

// The dependency census (census = 1), as ',"census":{...}', or nothing.
std::string Core::census_json() const {
  if (!c_.census) return "";
  static const char* qn[NQ] = {"A0", "A1", "LD", "STA", "FP", "UNI", "SERIAL", "ALU_ANY", "A2"};
  static const char* kn[CK_N] = {"ready", "mx", "rob", "llt", "xthread"};
  std::ostringstream o;
  o << ",\"census\":{";
  bool fq = true;
  for (int q = 0; q < NQ; q++) {
    uint64_t tot = 0;
    for (int k = 0; k < CK_N; k++) tot += census_[(size_t)q][(size_t)k];
    if (!tot) continue;
    o << (fq ? "" : ",") << "\"" << qn[q] << "\":{";
    fq = false;
    for (int k = 0; k < CK_N; k++) o << (k ? "," : "") << "\"" << kn[k] << "\":" << census_[(size_t)q][(size_t)k];
    o << ",\"rob_1cycle\":" << census_rob_1c_[(size_t)q] << ",\"cross_half\":" << census_xhalf_[(size_t)q];
    o << ",\"rob_from\":{";
    bool fp = true;
    for (int p = 0; p < NQ; p++)
      if (census_rob_from_[(size_t)q][(size_t)p]) {
        o << (fp ? "" : ",") << "\"" << qn[p] << "\":" << census_rob_from_[(size_t)q][(size_t)p];
        fp = false;
      }
    o << "}}";
  }
  o << "}";
  return o.str();
}

std::string Core::result_json(const std::string& bench) const {
  std::ostringstream o;
  o << "{\"bench\":\"" << json_escape(bench, 256) << "\",\"config\":" << c_.to_json();
  if (nthr_ == 1) {
    const Thread& T = *th_[0];
    o << ",\"exit_code\":" << T.iss->exit_code() << ",\"error\":\"" << json_escape(err_, 512) << "\"";
    o << ",\"region\":" << region_json(T);
    o << ",\"total\":{\"cycles\":" << T.st.cycles << ",\"instr\":" << T.st.instr << "}";
    o << ",\"marked\":" << (T.region_seen ? "true" : "false");
    o << ",\"stdout\":\"" << json_escape(T.iss->stdout_buf(), 4000) << "\"" << census_json() << "}";
    return o.str();
  }
  // Multithreaded: per-thread results of each program's first run, plus the window where both regions overlap.
  o << ",\"error\":\"" << json_escape(err_, 512) << "\",\"cycles\":" << t_ << ",\"threads\":[";
  for (auto& Tp : th_) {
    const Thread& T = *Tp;
    o << (T.tid ? "," : "") << "{\"bench\":\"" << json_escape(T.spec.bench, 256) << "\"";
    o << ",\"exit_code\":" << (T.first_done ? T.first_exit : T.iss->exit_code());
    o << ",\"region\":" << region_json(T);
    o << ",\"total\":{\"cycles\":" << (T.first_done ? T.first_cycles : T.st.cycles)
      << ",\"instr\":" << (T.first_done ? T.first_instr : T.st.instr) << "}";
    o << ",\"marked\":" << (T.region_seen ? "true" : "false") << ",\"laps\":" << T.lap
      << ",\"region_start\":" << T.r_start_cycle << ",\"region_end\":" << T.r_end_cycle;
    o << ",\"stdout\":\"" << json_escape(T.first_done ? T.first_stdout : T.iss->stdout_buf(), 4000) << "\"}";
  }
  o << "],\"overlap\":{\"valid\":" << (ov_started_ && ov_ended_ ? "true" : "false") << ",\"start\":" << ov_start_
    << ",\"end\":" << ov_end_ << ",\"instr\":[";
  for (int t = 0; t < nthr_; t++) o << (t ? "," : "") << (ov_i1_[(size_t)t] - ov_i0_[(size_t)t]);
  o << "],\"region_instr_at_start\":[";
  for (int t = 0; t < nthr_; t++) o << (t ? "," : "") << ov_r0_[(size_t)t];
  o << "]}" << census_json() << "}";
  return o.str();
}

}  // namespace tg
