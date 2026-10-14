// Verilator testbench for tg_fcsr (docs/spec/fpu.md, "Core integration", fcsr): random CSR writes
// of fflags/frm/fcsr, commit-time accumulation, early-retired divides and their completions,
// checked every cycle against a model (frm, fflags, er_busy, fs_dirty). Exits non-zero on failure.
//   tb_fcsr [-seed N] [-n CYCLES]
#include <verilated.h>
#include "Vtg_fcsr.h"

#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>

#if !defined(TID_W) || !defined(DECODE_WIDTH)
#error "build with the configuration constants (tests/unit/fpu/Makefile, target tbc)"
#endif
static constexpr int NT = 1 << TID_W;
static constexpr int NC = DECODE_WIDTH;
static constexpr int TB = TID_W > 0 ? TID_W : 1;   // tid_t width

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t seed = 1;
  long n = 200000;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "-seed" && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
    else if (a == "-n" && i + 1 < argc) n = strtol(argv[++i], 0, 0);
    else { fprintf(stderr, "bad argument %s\n", a.c_str()); return 2; }
  }
  std::mt19937_64 rng(seed);
  auto r = [&](int k) { return (int)(rng() % (uint64_t)k); };
  Vtg_fcsr *top = new Vtg_fcsr;
  int frm[NT] = {}, ff[NT] = {}, er[NT] = {};
  long errors = 0, checks = 0;
  auto fail = [&](const char *what, long c) {
    if (++errors <= 20) printf("ERROR cycle %ld: %s\n", c, what);
  };
  auto clear = [&]() {
    top->csr_rtid = 0; top->csr_wvalid = 0; top->csr_wtid = 0; top->csr_waddr = 0; top->csr_wdata = 0;
    top->cm_valid = 0; top->cm_tid = 0; top->cm_fflags = 0; top->cm_fpr = 0;
    top->er_ret_valid = 0; top->er_ret_tid = 0; top->er_valid = 0; top->er_tid = 0; top->er_fflags = 0;
  };
  top->clk = 0; top->rst = 1; clear();
  for (int i = 0; i < 3; i++) { top->clk = 1; top->eval(); top->clk = 0; top->eval(); }
  top->rst = 0;
  for (long c = 0; c < n; c++) {
    clear();
    int rt = r(NT);
    top->csr_rtid = rt;
    bool dirty[NT] = {};
    int nfrm[NT], nff[NT], ner[NT];
    for (int t = 0; t < NT; t++) { nfrm[t] = frm[t]; nff[t] = ff[t]; ner[t] = er[t]; }
    // A CSR write (serialising: nothing else of its hart in that cycle)
    int wt = -1;
    if (r(10) == 0) {
      wt = r(NT);
      int addr = 1 + r(3), data = r(256);
      top->csr_wvalid = 1; top->csr_wtid = wt; top->csr_waddr = addr; top->csr_wdata = data;
      if (addr == 1) nff[wt] = data & 0x1F;
      else if (addr == 2) nfrm[wt] = data & 7;
      else { nff[wt] = data & 0x1F; nfrm[wt] = (data >> 5) & 7; }
      dirty[wt] = true;
    }
    // Commit slots
    uint64_t cv = 0, ctid = 0, cfl = 0, cfp = 0;
    for (int k = 0; k < NC; k++) {
      if (r(3) != 0) continue;
      int t = r(NT);
      if (t == wt) continue;
      int fl = r(4) == 0 ? r(32) : 0;
      bool fp = r(2);
      cv |= 1ull << k; ctid |= (uint64_t)t << (k * TB); cfl |= (uint64_t)fl << (k * 5); cfp |= (uint64_t)fp << k;
      nff[t] |= fl;
      if (fp || fl) dirty[t] = true;
    }
    top->cm_valid = cv; top->cm_tid = ctid; top->cm_fflags = cfl; top->cm_fpr = cfp;
    // Early-retired divides: one retires, one completes
    if (r(6) == 0) {
      int t = r(NT);
      if (t != wt && er[t] < 15) { top->er_ret_valid = 1; top->er_ret_tid = t; ner[t]++; }
    }
    if (r(5) == 0) {
      int t = r(NT);
      if (t != wt && er[t] > 0) {
        int fl = r(32);
        top->er_valid = 1; top->er_tid = t; top->er_fflags = fl;
        ner[t]--; nff[t] |= fl;
        if (fl) dirty[t] = true;
      }
    }
    top->eval();
    // Combinational outputs this cycle
    checks++;
    if ((int)top->csr_frm != frm[rt] || (int)top->csr_fflags != ff[rt]) fail("CSR read", c);
    for (int t = 0; t < NT; t++) {
      if ((int)((top->frm_o >> (3 * t)) & 7) != frm[t]) fail("frm_o", c);
      if ((bool)((top->er_busy >> t) & 1) != (er[t] != 0)) fail("er_busy", c);
      if ((bool)((top->fs_dirty >> t) & 1) != dirty[t]) fail("fs_dirty", c);
    }
    top->clk = 1; top->eval(); top->clk = 0; top->eval();
    for (int t = 0; t < NT; t++) { frm[t] = nfrm[t]; ff[t] = nff[t]; er[t] = ner[t]; }
  }
  printf("fcsr seed=%llu: %ld cycles, %ld checks, %ld errors\n", (unsigned long long)seed, n, checks, errors);
  delete top;
  return errors ? 1 : 0;
}
