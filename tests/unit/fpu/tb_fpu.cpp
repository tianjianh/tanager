// Verilator testbench for tg_fpu (docs/spec/fpu.md, "Verification"). Exits non-zero on failure.
//
//   tb_fpu tf <function> [-rm N] [-n N]
//       TestFloat vectors from stdin (testfloat_gen output for <function>, e.g. f64_mulAdd).
//       Each vector is also run through the sign-flipped variants (FSUB, FMSUB, FNMSUB, FNMADD).
//   tb_fpu rand [-seed N] [-n N] [-units fma,misc,div] [-ready PCT] [-issue PCT]
//       random operations on all units at once, checked against the SoftFloat-based reference
//   tb_fpu hard [-seed N] [-n N]
//       directed divide/sqrt cases next to rounding boundaries, all formats and modes
#include <verilated.h>
#include "Vtg_fpu.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

#include "fpu_ref.h"
#include "operands.h"

// ---- Port layout (tg_fpu_pkg::fpu_req_t / fpu_resp_t, packed MSB first) ----
// req:  op[237:233] fmt[232:231] src_fmt[230:229] ifmt[228:227] rm[226:224] a[223:160] b[159:96]
//       c[95:32] tag[31:0]
// resp: result[101:38] fflags[37:33] int_dest[32] tag[31:0]
template <typename W>
static void put(W &w, int lsb, int width, uint64_t v) {
  for (int i = 0; i < width; i++) {
    int b = lsb + i;
    uint32_t m = 1u << (b & 31);
    if ((v >> i) & 1) w[b >> 5] |= m;
    else w[b >> 5] &= ~m;
  }
}
template <typename W>
static uint64_t get(const W &w, int lsb, int width) {
  uint64_t v = 0;
  for (int i = 0; i < width; i++) {
    int b = lsb + i;
    v |= (uint64_t)((w[b >> 5] >> (b & 31)) & 1) << i;
  }
  return v;
}

// Latencies: the tg_fpu_pkg constants, passed in by the Makefile.
#if !defined(FMA_LAT) || !defined(FMISC_LAT) || !defined(FDIV_LAT_S) || !defined(FDIV_LAT_D) || \
    !defined(FSQRT_LAT_S) || !defined(FSQRT_LAT_D)
#error "build with the latency constants of tg_fpu_pkg (tests/unit/fpu/Makefile)"
#endif
static int fdiv_lat(int op, int fmt) {
  if (op == ref::FDIV) return fmt == ref::D ? FDIV_LAT_D : FDIV_LAT_S;
  return fmt == ref::D ? FSQRT_LAT_D : FSQRT_LAT_S;
}

struct Item {
  ref::Req req;
  ref::Resp exp;
  const char *src;
};
struct Inflight {
  Item it;
  uint64_t cycle;
};

class Tb {
 public:
  Vtg_fpu *top;
  uint64_t cycle = 0;
  long checked = 0, errors = 0;
  std::deque<Item> q[3];            // per unit: FMA, FMISC, divide/sqrt
  std::unordered_map<uint32_t, Inflight> inflight;
  uint32_t next_tag = 1;
  std::mt19937_64 rng;
  int ready_pct = 100;               // probability of fdiv_ready_i
  int issue_pct = 100;               // probability of issuing when a request is queued
  bool fdiv_holding = false;         // a divide request is presented and must stay until accepted
  uint32_t fdiv_tag = 0;             // its tag
  bool fdiv_blocked = false;         // backpressure was applied (latencies may stretch)
  long max_report = 20;

  explicit Tb(uint64_t seed) : rng(seed) {
    top = new Vtg_fpu;
    top->clk = 0;
    top->rst = 1;
    top->fma_valid_i = top->fmisc_valid_i = top->fdiv_valid_i = 0;
    top->fdiv_ready_i = 1;
    for (int i = 0; i < 4; i++) tick();
    top->rst = 0;
  }
  ~Tb() { top->final(); delete top; }

  void tick() {
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
    cycle++;
  }

  template <typename W>
  void drive(W &w, const ref::Req &r, uint32_t tag) {
    put(w, 233, 5, r.op); put(w, 231, 2, r.fmt); put(w, 229, 2, r.src_fmt); put(w, 227, 2, r.ifmt);
    put(w, 224, 3, r.rm); put(w, 160, 64, r.a); put(w, 96, 64, r.b); put(w, 32, 64, r.c); put(w, 0, 32, tag);
  }

  void report(const char *what, const Inflight &f, uint64_t res, unsigned fl, bool idst, uint32_t tag) {
    errors++;
    if (errors > max_report) return;
    const ref::Req &r = f.it.req;
    printf("FAIL %s [%s] %s fmt=%d src=%d ifmt=%d rm=%d a=%016llx b=%016llx c=%016llx tag=%u issued@%llu now@%llu\n"
           "     expected %016llx flags %02x int %d, got %016llx flags %02x int %d\n",
           what, f.it.src, ref::op_name(r.op), r.fmt, r.src_fmt, r.ifmt, r.rm, (unsigned long long)r.a,
           (unsigned long long)r.b, (unsigned long long)r.c, tag, (unsigned long long)f.cycle,
           (unsigned long long)cycle, (unsigned long long)f.it.exp.result, f.it.exp.flags, f.it.exp.int_dest,
           (unsigned long long)res, fl, idst);
  }

  template <typename W>
  void check(const W &w, int unit) {
    uint32_t tag = (uint32_t)get(w, 0, 32);
    uint64_t res = get(w, 38, 64);
    unsigned fl = (unsigned)get(w, 33, 5);
    bool idst = get(w, 32, 1);
    auto it = inflight.find(tag);
    if (it == inflight.end()) {
      errors++;
      printf("FAIL unit %d returned unknown tag %u at cycle %llu\n", unit, tag, (unsigned long long)cycle);
      return;
    }
    const Inflight &f = it->second;
    if (ref::unit_of(f.it.req.op) != unit) report("wrong unit", f, res, fl, idst, tag);
    else if (res != f.it.exp.result || fl != f.it.exp.flags || idst != f.it.exp.int_dest)
      report("mismatch", f, res, fl, idst, tag);
    else {
      uint64_t lat = cycle - f.cycle;
      uint64_t want = unit == 0 ? FMA_LAT : unit == 1 ? FMISC_LAT : fdiv_lat(f.it.req.op, f.it.req.fmt);
      if (lat < want || (lat != want && (unit != 2 || !fdiv_blocked)))
        report(("latency " + std::to_string(lat) + " != " + std::to_string(want)).c_str(), f, res, fl, idst, tag);
    }
    checked++;
    inflight.erase(it);
  }

  bool want(int pct) { return pct >= 100 || (int)(rng() % 100) < pct; }

  // One clock cycle: present requests, check responses, advance.
  void step() {
    // FMA and FMISC: no backpressure
    top->fma_valid_i = 0;
    if (!q[0].empty() && want(issue_pct)) {
      uint32_t tag = next_tag++;
      drive(top->fma_req_i, q[0].front().req, tag);
      top->fma_valid_i = 1;
      inflight[tag] = {q[0].front(), cycle};
      q[0].pop_front();
    }
    top->fmisc_valid_i = 0;
    if (!q[1].empty() && want(issue_pct)) {
      uint32_t tag = next_tag++;
      drive(top->fmisc_req_i, q[1].front().req, tag);
      top->fmisc_valid_i = 1;
      inflight[tag] = {q[1].front(), cycle};
      q[1].pop_front();
    }
    // Divide/sqrt: valid holds until accepted
    if (!fdiv_holding && !q[2].empty() && want(issue_pct)) {
      fdiv_tag = next_tag++;
      drive(top->fdiv_req_i, q[2].front().req, fdiv_tag);
      fdiv_holding = true;
    }
    top->fdiv_valid_i = fdiv_holding;
    top->fdiv_ready_i = want(ready_pct);
    if (!top->fdiv_ready_i) fdiv_blocked = true;
    top->eval();

    if (top->fma_valid_o) check(top->fma_resp_o, 0);
    if (top->fmisc_valid_o) check(top->fmisc_resp_o, 1);
    if (top->fdiv_valid_o && top->fdiv_ready_i) check(top->fdiv_resp_o, 2);
    if (fdiv_holding && top->fdiv_ready_o) {
      inflight[fdiv_tag] = {q[2].front(), cycle};
      q[2].pop_front();
      fdiv_holding = false;
    }
    tick();
  }

  bool busy() const { return !inflight.empty() || fdiv_holding || !q[0].empty() || !q[1].empty() || !q[2].empty(); }

  void drain() {
    uint64_t limit = cycle + 10000;
    while (busy() && cycle < limit) step();
    if (busy()) {
      errors++;
      printf("FAIL %zu operations never completed (cycle %llu)\n", inflight.size(), (unsigned long long)cycle);
    }
  }

  void add(const ref::Req &r, const char *src) {
    Item it{r, ref::compute(r), src};
    q[ref::unit_of(r.op)].push_back(it);
  }
  void add_exp(const ref::Req &r, const ref::Resp &e, const char *src) {
    q[ref::unit_of(r.op)].push_back(Item{r, e, src});
  }
  size_t queued() const { return q[0].size() + q[1].size() + q[2].size(); }
};

// ---- TestFloat mode ----
struct TfFunc {
  const char *name;
  int op, fmt, src_fmt, ifmt;
  int nin;       // operands in the vector
  char in;       // 's' f32, 'd' f64, 'i' i32, 'u' ui32, 'I' i64, 'U' ui64
  char out;      // 's', 'd', 'i'/'u' (32-bit, sign-extended), 'I', 'U', 'b' (bool)
};

static const TfFunc tf_funcs[] = {
  {"f32_add", ref::FADD, ref::S, 0, 0, 2, 's', 's'},     {"f64_add", ref::FADD, ref::D, 0, 0, 2, 'd', 'd'},
  {"f32_sub", ref::FSUB, ref::S, 0, 0, 2, 's', 's'},     {"f64_sub", ref::FSUB, ref::D, 0, 0, 2, 'd', 'd'},
  {"f32_mul", ref::FMUL, ref::S, 0, 0, 2, 's', 's'},     {"f64_mul", ref::FMUL, ref::D, 0, 0, 2, 'd', 'd'},
  {"f32_mulAdd", ref::FMADD, ref::S, 0, 0, 3, 's', 's'}, {"f64_mulAdd", ref::FMADD, ref::D, 0, 0, 3, 'd', 'd'},
  {"f32_div", ref::FDIV, ref::S, 0, 0, 2, 's', 's'},     {"f64_div", ref::FDIV, ref::D, 0, 0, 2, 'd', 'd'},
  {"f32_sqrt", ref::FSQRT, ref::S, 0, 0, 1, 's', 's'},   {"f64_sqrt", ref::FSQRT, ref::D, 0, 0, 1, 'd', 'd'},
  {"f32_eq", ref::FEQ, ref::S, 0, 0, 2, 's', 'b'},       {"f64_eq", ref::FEQ, ref::D, 0, 0, 2, 'd', 'b'},
  {"f32_lt", ref::FLT, ref::S, 0, 0, 2, 's', 'b'},       {"f64_lt", ref::FLT, ref::D, 0, 0, 2, 'd', 'b'},
  {"f32_le", ref::FLE, ref::S, 0, 0, 2, 's', 'b'},       {"f64_le", ref::FLE, ref::D, 0, 0, 2, 'd', 'b'},
  {"f32_to_i32", ref::FCVT_I_F, ref::S, 0, ref::W, 1, 's', 'i'},
  {"f32_to_ui32", ref::FCVT_I_F, ref::S, 0, ref::WU, 1, 's', 'u'},
  {"f32_to_i64", ref::FCVT_I_F, ref::S, 0, ref::L, 1, 's', 'I'},
  {"f32_to_ui64", ref::FCVT_I_F, ref::S, 0, ref::LU, 1, 's', 'U'},
  {"f64_to_i32", ref::FCVT_I_F, ref::D, 0, ref::W, 1, 'd', 'i'},
  {"f64_to_ui32", ref::FCVT_I_F, ref::D, 0, ref::WU, 1, 'd', 'u'},
  {"f64_to_i64", ref::FCVT_I_F, ref::D, 0, ref::L, 1, 'd', 'I'},
  {"f64_to_ui64", ref::FCVT_I_F, ref::D, 0, ref::LU, 1, 'd', 'U'},
  {"i32_to_f32", ref::FCVT_F_I, ref::S, 0, ref::W, 1, 'i', 's'},
  {"ui32_to_f32", ref::FCVT_F_I, ref::S, 0, ref::WU, 1, 'u', 's'},
  {"i64_to_f32", ref::FCVT_F_I, ref::S, 0, ref::L, 1, 'I', 's'},
  {"ui64_to_f32", ref::FCVT_F_I, ref::S, 0, ref::LU, 1, 'U', 's'},
  {"i32_to_f64", ref::FCVT_F_I, ref::D, 0, ref::W, 1, 'i', 'd'},
  {"ui32_to_f64", ref::FCVT_F_I, ref::D, 0, ref::WU, 1, 'u', 'd'},
  {"i64_to_f64", ref::FCVT_F_I, ref::D, 0, ref::L, 1, 'I', 'd'},
  {"ui64_to_f64", ref::FCVT_F_I, ref::D, 0, ref::LU, 1, 'U', 'd'},
  {"f32_to_f64", ref::FCVT_F_F, ref::D, ref::S, 0, 1, 's', 'd'},
  {"f64_to_f32", ref::FCVT_F_F, ref::S, ref::D, 0, 1, 'd', 's'},
};

static uint64_t tf_in(char kind, uint64_t v, std::mt19937_64 &rng) {
  switch (kind) {
    case 's': return ref::box32((uint32_t)v);
    case 'i': case 'u': return (rng() << 32) | (v & 0xFFFFFFFFull);   // upper bits must be ignored
    default: return v;
  }
}
static uint64_t tf_out(char kind, uint64_t v) {
  switch (kind) {
    case 's': return ref::box32((uint32_t)v);
    case 'i': case 'u': return ref::sext32((uint32_t)v);
    default: return v;
  }
}

static int run_tf(Tb &tb, const char *fname, int rm, long limit) {
  const TfFunc *f = nullptr;
  for (auto &t : tf_funcs) if (!strcmp(t.name, fname)) f = &t;
  if (!f) { fprintf(stderr, "unknown TestFloat function %s\n", fname); return 2; }
  const bool dbl_in = f->in == 'd';
  const uint64_t sbit = dbl_in ? 1ull << 63 : 1ull << 31;
  std::mt19937_64 rng(1);
  char line[512];
  long n = 0;
  bool eof = false;
  while (!eof || tb.busy()) {
    while (!eof && tb.queued() < 64) {
      if ((limit && n >= limit) || !fgets(line, sizeof line, stdin)) { eof = true; break; }
      uint64_t v[5] = {0, 0, 0, 0, 0};
      int k = 0;
      for (char *p = strtok(line, " \t\r\n"); p && k < 5; p = strtok(nullptr, " \t\r\n")) v[k++] = strtoull(p, 0, 16);
      if (k != f->nin + 2) { fprintf(stderr, "bad vector line %ld\n", n + 1); return 2; }
      ref::Req r{f->op, f->fmt, f->src_fmt, f->ifmt, rm, 0, 0, 0};
      uint64_t in[3] = {0, 0, 0};
      for (int i = 0; i < f->nin; i++) in[i] = tf_in(f->in, v[i], rng);
      ref::Resp e{tf_out(f->out, v[f->nin]), (uint8_t)(v[f->nin + 1] & 0x1F), f->out != 's' && f->out != 'd'};
      if (f->op == ref::FSQRT) { r.a = in[0]; }
      else { r.a = in[0]; r.b = in[1]; r.c = in[2]; }
      tb.add_exp(r, e, f->name);
      // sign-flipped variants with the same exact result
      if (f->op == ref::FADD || f->op == ref::FSUB) {
        ref::Req v2 = r; v2.op = f->op == ref::FADD ? ref::FSUB : ref::FADD; v2.b ^= sbit;
        tb.add_exp(v2, e, f->op == ref::FADD ? "fsub(a,-b)" : "fadd(a,-b)");
      } else if (f->op == ref::FMADD) {
        ref::Req v2 = r; v2.op = ref::FMSUB; v2.c ^= sbit; tb.add_exp(v2, e, "fmsub(a,b,-c)");
        ref::Req v3 = r; v3.op = ref::FNMSUB; v3.a ^= sbit; tb.add_exp(v3, e, "fnmsub(-a,b,c)");
        ref::Req v4 = r; v4.op = ref::FNMADD; v4.a ^= sbit; v4.c ^= sbit; tb.add_exp(v4, e, "fnmadd(-a,b,-c)");
      }
      n++;
    }
    tb.step();
    if (tb.cycle > 4000000000ull) break;
  }
  printf("tf %s rm=%d: %ld vectors, %ld results checked, %ld errors\n", fname, rm, n, tb.checked, tb.errors);
  if (n == 0) { printf("FAIL no vectors read\n"); return 1; }
  return tb.errors ? 1 : 0;
}

// ---- Random mode ----
static ref::Req rand_req(std::mt19937_64 &rng, ops::Gen &gen, int unit) {
  ref::Req r{0, (int)(rng() & 1), 0, (int)(rng() & 3), (int)(rng() % 5), 0, 0, 0};
  bool dbl = r.fmt == ref::D;
  if (unit == 0) {
    unsigned k = rng() % 9;
    if (k == 7) {                  // FCVT.F.F (R5: on the FMA)
      r.op = ref::FCVT_F_F; r.src_fmt = !r.fmt; r.a = gen.fp(r.src_fmt == ref::D);
      return r;
    }
    if (k == 8) {                  // FCVT.F.I
      r.op = ref::FCVT_F_I; r.a = gen.integer();
      return r;
    }
    r.op = k;
    r.a = gen.fp(dbl); r.b = gen.fp(dbl); r.c = gen.fp(dbl);
    // Cancellation: the addend close to +-(a*b), or b close to +-a for FADD/FSUB.
    const uint64_t sbit = dbl ? 1ull << 63 : 1ull << 31;
    if (rng() % 3 == 0) {
      uint64_t noise = rng() % 4 == 0 ? 0 : rng() & 0xFF;
      if (r.op == ref::FADD || r.op == ref::FSUB) {
        r.b = (r.a ^ (rng() & 1 ? sbit : 0)) ^ noise;
      } else if (r.op != ref::FMUL) {
        ref::Req m{ref::FMUL, r.fmt, 0, 0, (int)(rng() % 5), r.a, r.b, 0};
        r.c = (ref::compute(m).result ^ (rng() & 1 ? sbit : 0)) ^ noise;
      }
    }
  } else if (unit == 1) {
    static const int mops[] = {ref::FSGNJ, ref::FSGNJN, ref::FSGNJX, ref::FMIN, ref::FMAX, ref::FEQ, ref::FLT,
                               ref::FLE, ref::FCLASS, ref::FCVT_I_F, ref::FMV_X_F, ref::FMV_F_X};
    r.op = mops[rng() % 12];
    if (r.op == ref::FMV_F_X) r.a = gen.integer();
    else { r.a = gen.fp(dbl); r.b = rng() % 8 == 0 ? r.a ^ (rng() & 1 ? 0 : (dbl ? 1ull << 63 : 1ull << 31)) : gen.fp(dbl); }
  } else {
    r.op = rng() & 1 ? ref::FDIV : ref::FSQRT;
    r.a = gen.fp(dbl);
    r.b = r.op == ref::FDIV ? gen.fp(dbl) : 0;
  }
  return r;
}

static int run_rand(Tb &tb, uint64_t seed, long n, const std::string &units) {
  std::mt19937_64 rng(seed ^ 0x5DEECE66Dull);
  ops::Gen gen(rng);
  bool en[3] = {units.find("fma") != std::string::npos, units.find("misc") != std::string::npos,
                units.find("div") != std::string::npos};
  long made = 0;
  uint64_t last_progress = 0;
  long last_checked = -1;
  while (made < n || tb.busy()) {
    for (int u = 0; u < 3 && made < n; u++) {
      if (!en[u]) continue;
      size_t cap = u == 2 ? 8 : 4;
      if (tb.q[u].size() < cap) { tb.add(rand_req(rng, gen, u), "rand"); made++; }
    }
    tb.step();
    if (tb.checked != last_checked) { last_checked = tb.checked; last_progress = tb.cycle; }
    if (tb.cycle - last_progress > 2000) {
      tb.errors++;
      printf("FAIL no response for 2000 cycles at cycle %llu: %zu in flight, fdiv_ready_o=%d holding=%d\n",
             (unsigned long long)tb.cycle, tb.inflight.size(), tb.top->fdiv_ready_o, tb.fdiv_holding);
      int shown = 0;
      for (auto &kv : tb.inflight)
        if (shown++ < 10)
          printf("  in flight: tag %u %s fmt=%d issued@%llu\n", kv.first, ref::op_name(kv.second.it.req.op),
                 kv.second.it.req.fmt, (unsigned long long)kv.second.cycle);
      break;
    }
  }
  printf("rand seed=%llu units=%s: %ld operations, %ld checked, %ld errors\n", (unsigned long long)seed,
         units.c_str(), made, tb.checked, tb.errors);
  return tb.errors ? 1 : 0;
}

// ---- Hard divide/sqrt cases ----
static int run_hard(Tb &tb, uint64_t seed, long n) {
  std::mt19937_64 rng(seed);
  long made = 0;
  for (int dbl = 0; dbl < 2; dbl++) {
    auto dv = ops::hard_div(rng, dbl, (int)n);
    auto sv = ops::hard_sqrt(rng, dbl, (int)n);
    for (int i = 0; i < (int)n; i++) {
      int rm = rng() % 5;
      tb.add(ref::Req{ref::FDIV, dbl, 0, 0, rm, dv[i].first, dv[i].second, 0}, "hard div");
      tb.add(ref::Req{ref::FSQRT, dbl, 0, 0, rm, sv[i], 0, 0}, "hard sqrt");
      made += 2;
      while (tb.queued() > 16) tb.step();
    }
  }
  tb.drain();
  printf("hard seed=%llu: %ld operations, %ld checked, %ld errors\n", (unsigned long long)seed, made, tb.checked,
         tb.errors);
  return tb.errors ? 1 : 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    fprintf(stderr, "usage: tb_fpu tf <function> [-rm N] [-n N] | rand [-seed N] [-n N] [-units ...] | hard\n");
    return 2;
  }
  std::string mode = argv[1];
  uint64_t seed = 1;
  long n = 0;
  int rm = 0;
  int ready = 100, issue = 100;
  std::string units = "fma,misc,div", func;
  int i = 2;
  if (mode == "tf" && argc > 2) func = argv[i++];
  for (; i < argc; i++) {
    std::string a = argv[i];
    if (a == "-seed" && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
    else if (a == "-n" && i + 1 < argc) n = strtol(argv[++i], 0, 0);
    else if (a == "-rm" && i + 1 < argc) rm = atoi(argv[++i]);
    else if (a == "-units" && i + 1 < argc) units = argv[++i];
    else if (a == "-ready" && i + 1 < argc) ready = atoi(argv[++i]);
    else if (a == "-issue" && i + 1 < argc) issue = atoi(argv[++i]);
  }
  Tb tb(seed);
  tb.ready_pct = ready;
  tb.issue_pct = issue;
  int rc;
  if (mode == "tf") rc = run_tf(tb, func.c_str(), rm, n);
  else if (mode == "rand") rc = run_rand(tb, seed, n ? n : 100000, units);
  else if (mode == "hard") rc = run_hard(tb, seed, n ? n : 2000);
  else { fprintf(stderr, "unknown mode %s\n", mode.c_str()); return 2; }
  if (tb.errors > tb.max_report) printf("(%ld more failures not shown)\n", tb.errors - tb.max_report);
  return rc;
}
