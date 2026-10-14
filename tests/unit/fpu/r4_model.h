// Bit-accurate model of the radix-4 divide/sqrt fallback (docs/spec/fpu.md, "Fallback: radix-4
// divide/sqrt"). Restoring digit recurrence, two quotient bits per step chosen by three trial
// subtractions in parallel, no redundancy and no tables:
//   division     X = 4w;  T1 = X - d,           T2 = X - 2d,           T3 = X - d - 2d
//   square root  X = 4w;  T1 = X - (2Q | u),    T2 = X - (4Q | 4u),    T3 = X - (2Q | u) - (4Q | 8u)
// with u = 4^-(j+1) the weight of the digit being chosen. The digit is the largest b in {1,2,3}
// with T_b >= 0 (else 0), and w <- T_b (or X). The result is (T, G, S) at normal precision, the
// same hand-off as the Goldschmidt unit's F0, so rounding is shared (gs::round_pack).
#pragma once
#include <cstdint>
#include "gs_model.h"

namespace r4 {

typedef unsigned __int128 u128;
static const int F = 56;                 // fraction bits of residual and root (Q4.56 residual)

struct Stats { int max_w_bits = 0; };
inline Stats &stats() { static Stats s; return s; }

static inline void note_width(u128 w) {
  int b = 0;
  while (w >> b) b++;
  if (b > stats().max_w_bits) stats().max_w_bits = b;
}

// Digits needed after the integer digit: (p - 1) fraction bits plus a guard bit, rounded up to
// whole radix-4 digits.
inline int steps(bool dbl) { return dbl ? 27 : 12; }

// One radix-4 step. Returns the digit; w is updated in place.
inline unsigned step(u128 &w, u128 a, u128 b, u128 c) {
  u128 x = w << 2;
  // two's complement trials in 128 bits; the RTL uses a 61-bit window
  bool p1 = x >= a, p2 = x >= b, p3 = x >= a + c;
  if (p3) { w = x - a - c; return 3; }
  if (p2) { w = x - b; return 2; }
  if (p1) { w = x - a; return 1; }
  w = x;
  return 0;
}

inline gs::Result div(uint64_t av, uint64_t bv, bool dbl, int rm) {
  using namespace gs;
  Unpacked ua = unpack(av, dbl), ub = unpack(bv, dbl);
  bool sign = ua.sign ^ ub.sign;
  if (ua.nan || ub.nan) return {canon_nan(dbl), (uint8_t)((ua.snan || ub.snan) ? NV : 0)};
  if ((ua.inf && ub.inf) || (ua.zero && ub.zero)) return {canon_nan(dbl), NV};
  if (ua.inf || ub.zero) return {inf_bits(sign, dbl), (uint8_t)(ub.zero && !ua.inf ? DZ : 0)};
  if (ua.zero || ub.inf) return {zero_bits(sign, dbl), 0};
  bool lt = ua.sig < ub.sig;
  int eq = ua.exp - ub.exp - lt;
  // A in [1, 4), d in [1, 2), Q4.56
  u128 A = (u128)(lt ? ua.sig << 1 : ua.sig) << (F - 52);
  u128 d = (u128)ub.sig << (F - 52);
  u128 w = A - d;                         // integer digit of q in [1, 2) is 1
  uint64_t q = 1;
  int n = steps(dbl);
  for (int j = 0; j < n; j++) {
    q = (q << 2) | step(w, d, d << 1, d << 1);
    note_width(w << 2);
  }
  // q has 1 + 2n bits: integer bit, p - 1 fraction bits, guard (and one more for S)
  int extra = 2 * n - (dbl ? 52 : 23);    // bits below the last fraction bit: guard (+1)
  uint64_t t = q >> extra;
  bool g = (q >> (extra - 1)) & 1;
  bool s = (w != 0) || (q & ((1ull << (extra - 1)) - 1));
  return round_pack(sign, eq, t, g, s, dbl, rm);
}

inline gs::Result sqrt(uint64_t av, bool dbl, int rm) {
  using namespace gs;
  Unpacked u = unpack(av, dbl);
  if (u.nan) return {canon_nan(dbl), (uint8_t)(u.snan ? NV : 0)};
  if (u.zero) return {zero_bits(u.sign, dbl), 0};
  if (u.sign) return {canon_nan(dbl), NV};
  if (u.inf) return {inf_bits(false, dbl), 0};
  bool odd = u.exp & 1;
  int eq = (u.exp - odd) >> 1;
  u128 X = (u128)(odd ? u.sig << 1 : u.sig) << (F - 52);   // x in [1, 4)
  u128 Q = (u128)1 << F;                  // root so far: 1
  u128 w = X - Q;                         // x - 1
  int n = steps(dbl);
  for (int j = 0; j < n; j++) {
    u128 uu = (u128)1 << (F - 2 * (j + 1));
    u128 s1 = (Q << 1) | uu;
    u128 s2 = (Q << 2) | (uu << 2);
    u128 s2b = (Q << 2) | (uu << 3);
    unsigned b = step(w, s1, s2, s2b);
    Q |= (u128)b * uu;
    note_width(w << 2);
  }
  int extra = 2 * n - (dbl ? 52 : 23);
  uint64_t q = (uint64_t)(Q >> (F - 2 * n));
  uint64_t t = q >> extra;
  bool g = (q >> (extra - 1)) & 1;
  bool s = (w != 0) || (q & ((1ull << (extra - 1)) - 1));
  return round_pack(false, eq, t, g, s, dbl, rm);
}

}  // namespace r4
