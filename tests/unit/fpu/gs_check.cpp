// Checks the bit-accurate Goldschmidt model (gs_model.h) against SoftFloat and reports the
// worst approximation error before the remainder step, against the budget of docs/spec/fpu.md.
//   gs_check [-seed N] [-n N]       exits non-zero on any mismatch or budget violation
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include "fpu_ref.h"
#include "gs_model.h"
#include "operands.h"

static long fails = 0;

static void check(int op, bool dbl, int rm, uint64_t a, uint64_t b) {
  ref::Req q{op, dbl ? ref::D : ref::S, 0, 0, rm, a, b, 0};
  ref::Resp e = ref::compute(q);
  gs::Result g = op == ref::FDIV ? gs::div(a, b, dbl, rm) : gs::sqrt(a, dbl, rm);
  if (g.bits != e.result || g.flags != e.flags) {
    if (fails < 20)
      printf("MISMATCH %s.%c rm=%d a=%016llx b=%016llx: model %016llx/%02x ref %016llx/%02x\n",
             ref::op_name(op), dbl ? 'd' : 's', rm, (unsigned long long)a, (unsigned long long)b,
             (unsigned long long)g.bits, g.flags, (unsigned long long)e.result, e.flags);
    fails++;
  }
}

int main(int argc, char **argv) {
  uint64_t seed = 1, n = 2000000;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-seed") && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
    else if (!strcmp(argv[i], "-n") && i + 1 < argc) n = strtoull(argv[++i], 0, 0);
  }
  printf("gs_check: seed %llu, %llu random cases per kind\n", (unsigned long long)seed, (unsigned long long)n);
  std::mt19937_64 rng(seed);
  ops::Gen gen(rng);
  long count = 0;
  for (int dbl = 0; dbl < 2; dbl++) {
    for (uint64_t i = 0; i < n; i++) {
      int rm = rng() % 5;
      check(ref::FDIV, dbl, rm, gen.fp(dbl), gen.fp(dbl));
      check(ref::FSQRT, dbl, rm, gen.fp(dbl), 0);
      count += 2;
    }
    for (int rm = 0; rm < 5; rm++) {
      for (auto &v : ops::hard_div(rng, dbl, 20000)) { check(ref::FDIV, dbl, rm, v.first, v.second); count++; }
      for (auto &v : ops::hard_sqrt(rng, dbl, 20000)) { check(ref::FSQRT, dbl, rm, v, 0); count++; }
    }
    // Both ends of every seed-ROM interval, where the seed error peaks.
    const int fb = dbl ? 52 : 23;
    const uint64_t one = dbl ? 0x3FF0000000000000ull : 0xFFFFFFFF3F800000ull;
    for (int idx = 0; idx < 1024; idx++) {
      for (int end = 0; end < 2; end++) {
        uint64_t f = ((uint64_t)idx << (fb - 10)) + (end ? (1ull << (fb - 10)) - 1 : 0);
        uint64_t b = one | f;
        for (int k = 0; k < 8; k++) {
          int rm = rng() % 5;
          check(ref::FDIV, dbl, rm, gen.fp(dbl), b);
          // square root: the same fraction in both binades (index bit 9 is the exponent parity)
          uint64_t fs = ((uint64_t)(idx & 511) << (fb - 9)) + (end ? (1ull << (fb - 9)) - 1 : 0);
          uint64_t x = (one | fs) + ((uint64_t)(idx >> 9) << fb);
          check(ref::FSQRT, dbl, rm, x, 0);
          count += 2;
        }
      }
    }
  }
  const char *kind[4] = {"div S", "div D", "sqrt S", "sqrt D"};
  // Budget: |q_approx - q| < u_g / 2 = 2^-25 (S) or 2^-54 (D), in units of 2^-58.
  const double budget[4] = {std::ldexp(1.0, 33), std::ldexp(1.0, 4), std::ldexp(1.0, 33), std::ldexp(1.0, 4)};
  for (int k = 0; k < 4; k++) {
    double w = gs::stats().worst_err[k];
    printf("  %-7s worst |q_approx - q| = 2^%.2f (budget 2^%.0f)\n", kind[k], std::log2(w * std::ldexp(1.0, -58)),
           std::log2(budget[k] * std::ldexp(1.0, -58)));
    if (w >= budget[k]) { printf("  BUDGET EXCEEDED: %s\n", kind[k]); fails++; }
  }
  printf("gs_check: %ld cases, %ld failures\n", count, fails);
  return fails ? 1 : 0;
}
