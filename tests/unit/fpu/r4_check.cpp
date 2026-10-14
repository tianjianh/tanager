// Checks the radix-4 divide/sqrt model (r4_model.h) against SoftFloat.
//   r4_check [-seed N] [-n N]        exits non-zero on any mismatch
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include "fpu_ref.h"
#include "operands.h"
#include "r4_model.h"

static long fails = 0;
static void check(int op, bool dbl, int rm, uint64_t a, uint64_t b) {
  ref::Req q{op, dbl ? ref::D : ref::S, 0, 0, rm, a, b, 0};
  ref::Resp e = ref::compute(q);
  gs::Result g = op == ref::FDIV ? r4::div(a, b, dbl, rm) : r4::sqrt(a, dbl, rm);
  if (g.bits != e.result || g.flags != e.flags) {
    if (fails < 20)
      printf("MISMATCH %s.%c rm=%d a=%016llx b=%016llx: model %016llx/%02x ref %016llx/%02x\n",
             ref::op_name(op), dbl ? 'd' : 's', rm, (unsigned long long)a, (unsigned long long)b,
             (unsigned long long)g.bits, g.flags, (unsigned long long)e.result, e.flags);
    fails++;
  }
}

int main(int argc, char **argv) {
  uint64_t seed = 1, n = 1000000;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-seed") && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
    else if (!strcmp(argv[i], "-n") && i + 1 < argc) n = strtoull(argv[++i], 0, 0);
  }
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
  }
  printf("r4_check: seed %llu, %ld cases, %ld failures; residual 4w needs %d bits (Q.56)\n",
         (unsigned long long)seed, count, fails, r4::stats().max_w_bits);
  return fails ? 1 : 0;
}
