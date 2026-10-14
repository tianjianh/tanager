// Operand generators for the FPU tests: biased random FP and integer operands, and directed
// hard-rounding cases for division and square root (docs/spec/fpu.md, "Verification").
#pragma once
#include <cstdint>
#include <random>
#include <utility>
#include <vector>

namespace ops {

typedef unsigned __int128 u128;

struct Gen {
  std::mt19937_64 &r;
  explicit Gen(std::mt19937_64 &rng) : r(rng) {}

  uint64_t bits(int n) { return n >= 64 ? r() : (r() & ((1ull << n) - 1)); }
  bool chance(int pct) { return (int)(r() % 100) < pct; }

  // A fraction of n bits with structure: random, runs of ones or zeros, sparse bits.
  uint64_t frac(int n) {
    uint64_t m = (1ull << n) - 1;
    switch (r() % 6) {
      case 0: return 0;
      case 1: return m;
      case 2: {  // a run of ones
        int lo = r() % n, hi = lo + r() % (n - lo);
        return (m >> (n - 1 - hi)) & ~((1ull << lo) - 1);
      }
      case 3: {  // sparse
        uint64_t v = 0;
        for (int k = r() % 4; k >= 0; k--) v |= 1ull << (r() % n);
        return v;
      }
      case 4: return m ^ (1ull << (r() % n));
      default: return r() & m;
    }
  }

  // A random operand of the given format, NaN-boxed for S (and occasionally not).
  uint64_t fp(bool dbl) {
    const int fb = dbl ? 52 : 23, eb = dbl ? 11 : 8;
    const int emax = (1 << eb) - 1, bias = emax >> 1;
    uint64_t sign = r() & 1, e, f;
    int k = r() % 100;
    if (k < 10) {          // specials
      static const int kinds = 12;
      switch (r() % kinds) {
        case 0: e = 0; f = 0; break;                                   // zero
        case 1: e = emax; f = 0; break;                                // infinity
        case 2: e = emax; f = 1ull << (fb - 1); break;                 // canonical-like qNaN
        case 3: e = emax; f = (1ull << (fb - 1)) | frac(fb - 1); break; // qNaN
        case 4: e = emax; f = frac(fb - 1) | 1; break;                 // sNaN
        case 5: e = 0; f = 1; break;                                   // min subnormal
        case 6: e = 0; f = (1ull << fb) - 1; break;                    // max subnormal
        case 7: e = 1; f = 0; break;                                   // min normal
        case 8: e = emax - 1; f = (1ull << fb) - 1; break;             // max finite
        case 9: e = bias; f = 0; break;                                // 1.0
        case 10: e = bias + 1; f = 0; break;                           // 2.0
        default: e = bias - 1; f = (1ull << fb) - 1; break;            // just below 1
      }
    } else if (k < 22) {   // subnormal
      e = 0; f = frac(fb); if (!f) f = 1;
    } else if (k < 32) {   // near the exponent extremes
      e = chance(50) ? 1 + r() % (fb + 4) : emax - 1 - r() % (fb + 4); f = frac(fb);
    } else if (k < 72) {   // near 1.0, so operations interact (cancellation, exact results)
      e = bias + (int)(r() % 61) - 30; f = frac(fb);
    } else {
      e = 1 + r() % (emax - 1); f = frac(fb);
    }
    uint64_t v = (sign << (dbl ? 63 : 31)) | (e << fb) | f;
    if (!dbl) v = (chance(2) ? (r() << 32) : 0xFFFFFFFF00000000ull) | v;
    return v;
  }

  // A random integer source with structure (FCVT.F.I, FMV.F.X).
  uint64_t integer() {
    switch (r() % 8) {
      case 0: return r() % 5 - 2;                                  // -2..2
      case 1: return 1ull << (r() % 64);
      case 2: return -(1ull << (r() % 64));
      case 3: return frac(64 - r() % 64);
      case 4: return (uint64_t)(int64_t)(int32_t)r();
      case 5: return (uint32_t)r();
      case 6: return ~frac(64);
      default: return r();
    }
  }
};

// Modular inverse of an odd number modulo 2^64 (Newton iteration).
inline uint64_t inv_odd(uint64_t b) {
  uint64_t x = b;  // correct to 3 bits
  for (int i = 0; i < 6; i++) x *= 2 - b * x;
  return x;
}

inline uint64_t pack(bool dbl, bool sign, int ebiased, uint64_t frac) {
  if (dbl) return ((uint64_t)sign << 63) | ((uint64_t)ebiased << 52) | frac;
  return 0xFFFFFFFF00000000ull | ((uint64_t)sign << 31) | ((uint64_t)ebiased << 23) | frac;
}

// Exponent pairs for division: ordinary, quotient at the subnormal boundary, at the overflow edge.
inline void div_exps(std::mt19937_64 &r, bool dbl, int &ea, int &eb) {
  const int bias = dbl ? 1023 : 127, emin = 1 - bias, emax = bias;
  switch (r() % 4) {
    case 0: ea = emin; eb = 1; break;                    // q * 2^(emin - 1): rounds into or below emin
    case 1: ea = emin + 1; eb = 1; break;
    case 2: ea = emax; eb = 0; break;                    // q * 2^emax: overflow when rounding up from ~2
    default: ea = (int)(r() % 41) - 20; eb = (int)(r() % 41) - 20; break;
  }
  ea += bias; eb += bias;
}

// Divisions whose exact quotient lies within about 2^-2p of a rounding boundary (a midpoint or a
// representable number), plus exact quotients.
inline std::vector<std::pair<uint64_t, uint64_t>> hard_div(std::mt19937_64 &r, bool dbl, int n) {
  const int p = dbl ? 53 : 24;
  const uint64_t top = 1ull << p, half = 1ull << (p - 1);
  std::vector<std::pair<uint64_t, uint64_t>> v;
  while ((int)v.size() < n) {
    uint64_t B = half | (r() & (half - 1)) | 1;          // odd p-bit divisor
    int kind = r() % 4;
    u128 A = 0;
    if (kind == 3) {                                     // exact: A = B' * T with few bits in B'
      int bb = 1 + r() % 10;
      uint64_t Bs = (1ull << (bb - 1)) | (r() & ((1ull << (bb - 1)) - 1)) | 1;
      uint64_t T = (half >> (bb - 1)) | (r() & ((half >> (bb - 1)) - 1));
      A = (u128)Bs * T;
      B = Bs << (p - bb);
      while (A >= top) A >>= 1;                          // keep it a p-bit significand (stays exact)
      if (A < half) continue;
    } else {
      // A*2^k - B*M = rr with |rr| small and odd:
      //   kind 0: k = p,   M in [2^p, 2^(p+1)) odd: q = A/B in [1, 2) next to the midpoint M/2^p;
      //   kind 1: k = p+1, the same for 2A/B (q < 1, the dividend gets doubled);
      //   kind 2: k = p-1, M in [2^(p-1), 2^p): q next to the representable value M/2^(p-1).
      int k = kind == 0 ? p : kind == 1 ? p + 1 : p - 1;
      uint64_t lo = kind == 2 ? half : top;
      int64_t rr = (int64_t)(r() % 4) * 2 + 1; if (r() & 1) rr = -rr;
      uint64_t M = ((uint64_t)(-rr) * inv_odd(B)) & ((1ull << k) - 1);
      if (kind != 1) M += lo;
      if (M < lo || M >= 2 * lo) continue;
      u128 num = (u128)B * M + (u128)(__int128)rr;
      if (num & (((u128)1 << k) - 1)) continue;
      A = num >> k;
      if (A < half || A >= top) continue;
    }
    int ea, eb;
    div_exps(r, dbl, ea, eb);
    bool sa = r() & 1, sb = r() & 1;
    v.push_back({pack(dbl, sa, ea, (uint64_t)A & (half - 1)), pack(dbl, sb, eb, B & (half - 1))});
  }
  return v;
}

// 2-adic square root: an odd M with M^2 = rr (mod 2^m), for rr = 1 (mod 8).
inline uint64_t sqrt_mod2k(int64_t rr, int m) {
  uint64_t M = 1;
  for (int k = 3; k < m; k++) {
    u128 sq = (u128)M * M;
    u128 mod = (u128)1 << (k + 1);
    if ((uint64_t)((sq - (u128)(__int128)rr) & (mod - 1)) != 0) M += 1ull << (k - 1);
  }
  return M;
}

// Square roots within about 2^-2p of a midpoint or a representable number, exact squares and
// near-exact squares.
inline std::vector<uint64_t> hard_sqrt(std::mt19937_64 &r, bool dbl, int n) {
  const int p = dbl ? 53 : 24, bias = dbl ? 1023 : 127;
  const uint64_t half = 1ull << (p - 1), top = 1ull << p;
  std::vector<uint64_t> v;
  while ((int)v.size() < n) {
    int kind = r() % 4;
    uint64_t X = 0; bool odd = false;
    if (kind == 0) {                                     // exact or near-exact square of a short T
      int h = p / 2;
      uint64_t T = (1ull << (h - 1)) | (r() & ((1ull << (h - 1)) - 1));
      u128 sq = (u128)T * T;
      int sh = 0; while ((sq << sh) < (u128)half) sh++;
      X = (uint64_t)(sq << sh);
      // x = X * 2^(E - p + 1) = T^2 * 2^(sh - p + 1 + E) is a square when that exponent is even.
      odd = ((sh - p + 1) & 1) != 0;
      int64_t d = (int64_t)(r() % 7) - 3;              // d != 0: next to a square
      X += d;
      if (X < half || X >= top) continue;
    } else {
      // X * 2^m - M^2 = -rr: sqrt(x) within ~2^-2p of M / 2^(p or p-1) (midpoint or representable).
      bool mid = kind != 3;
      odd = r() & 1;
      int m = (mid ? p + 1 : p - 1) + (odd ? 1 : 0);
      int64_t rr = 1 + 8 * ((int64_t)(r() % 16) - 8);
      uint64_t M0 = sqrt_mod2k(rr, m);
      uint64_t mk = (1ull << m) - 1;
      uint64_t cands[4] = {M0 & mk, (-M0) & mk, (M0 + (1ull << (m - 1))) & mk, (-M0 + (1ull << (m - 1))) & mk};
      uint64_t M = cands[r() % 4];
      int mb = mid ? p : p - 1;                          // M must have mb + 1 bits
      if (M < (1ull << mb) || M >= (2ull << mb)) continue;
      u128 sq = (u128)M * M;
      u128 num = sq - (u128)(__int128)rr;
      if (num & (((u128)1 << m) - 1)) continue;
      u128 Xw = num >> m;
      if (Xw < half || Xw >= top) continue;
      X = (uint64_t)Xw;
    }
    int e = (int)(r() % 41) - 20;
    e = (e & ~1) + (odd ? 1 : 0);
    if (r() % 8 == 0) e = (odd ? 1 : 0) - bias + 2 * (int)(r() % 4);  // small exponents
    v.push_back(pack(dbl, false, e + bias, X & (half - 1)));
  }
  return v;
}

}  // namespace ops
