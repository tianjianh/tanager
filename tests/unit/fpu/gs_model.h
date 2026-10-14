// Bit-accurate model of the Goldschmidt divide/sqrt unit (docs/spec/fpu.md, "Divide/sqrt unit").
// Every truncation and width here matches the RTL (rtl/core/fpu/tg_fpu_div*.sv); the testbench
// can compare the RTL's internal values with these. Results are RISC-V F/D exact.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "seed_tab.h"

namespace gs {

typedef unsigned __int128 u128;
typedef __int128 i128;

enum { RNE = 0, RTZ = 1, RDN = 2, RUP = 3, RMM = 4 };
enum { NX = 1, UF = 2, OF = 4, DZ = 8, NV = 16 };

static const int QF = 58;                       // Q2.58 fraction bits
static const uint64_t ONE = 1ull << QF;
static const uint64_t QMASK = (1ull << 60) - 1;

// Statistics the checker reports: the worst |q_approx - q| seen, in units of 2^-58, per kind.
struct Stats {
  double worst_err[4] = {0, 0, 0, 0};  // div S, div D, sqrt S, sqrt D
};
inline Stats &stats() { static Stats s; return s; }

inline uint64_t mul(uint64_t x, uint64_t y) {   // Q2.58 x Q2.58 -> Q2.58, truncated
  u128 p = (u128)x * y;
  uint64_t r = (uint64_t)(p >> QF);
  if (r >> 60) { fprintf(stderr, "gs model: product overflow\n"); abort(); }
  return r;
}

struct Unpacked {
  bool sign, zero, inf, nan, snan;
  int exp;          // unbiased exponent of the normalised significand
  uint64_t sig;     // 53 bits, bit 52 set when non-zero (S: 24 bits in 52:29)
};

inline Unpacked unpack(uint64_t a, bool dbl) {
  Unpacked u{};
  uint64_t frac; int e, emax, bias;
  if (dbl) {
    u.sign = a >> 63; e = (a >> 52) & 0x7FF; frac = a & ((1ull << 52) - 1); emax = 0x7FF; bias = 1023;
  } else {
    if ((a >> 32) != 0xFFFFFFFFull) a = 0x7FC00000ull;   // improperly NaN-boxed -> canonical NaN
    u.sign = (a >> 31) & 1; e = (a >> 23) & 0xFF; frac = (a & 0x7FFFFF) << 29; emax = 0xFF; bias = 127;
  }
  u.zero = (e == 0 && frac == 0);
  u.inf = (e == emax && frac == 0);
  u.nan = (e == emax && frac != 0);
  u.snan = u.nan && !((frac >> 51) & 1);
  u.sig = ((uint64_t)(e != 0) << 52) | frac;
  u.exp = (e == 0 ? 1 : e) - bias;
  if (!u.zero && !u.inf && !u.nan) {
    while (!((u.sig >> 52) & 1)) { u.sig <<= 1; u.exp--; }
  }
  return u;
}

inline bool round_up(int rm, bool sign, bool lsb, bool g, bool s) {
  switch (rm) {
    case RNE: return g && (s || lsb);
    case RTZ: return false;
    case RDN: return (g || s) && sign;
    case RUP: return (g || s) && !sign;
    default:  return g;   // RMM
  }
}

struct Result { uint64_t bits; uint8_t flags; };

inline uint64_t canon_nan(bool dbl) { return dbl ? 0x7FF8000000000000ull : 0xFFFFFFFF7FC00000ull; }
inline uint64_t box(uint64_t v, bool dbl) { return dbl ? v : (0xFFFFFFFF00000000ull | (v & 0xFFFFFFFFull)); }
inline uint64_t inf_bits(bool sign, bool dbl) {
  return dbl ? ((uint64_t)sign << 63) | 0x7FF0000000000000ull : box(((uint64_t)sign << 31) | 0x7F800000ull, false);
}
inline uint64_t zero_bits(bool sign, bool dbl) { return dbl ? (uint64_t)sign << 63 : box((uint64_t)sign << 31, false); }

// Rounds and packs q * 2^eq, q in [1, 2) given as (T with hidden bit, G, S) at normal precision.
inline Result round_pack(bool sign, int eq, uint64_t t, bool g, bool s, bool dbl, int rm) {
  const int fb = dbl ? 52 : 23, bias = dbl ? 1023 : 127, emin = 1 - bias, efmax = dbl ? 2047 : 255;
  const uint64_t tmax = (1ull << (fb + 1)) - 1;
  uint8_t fl = 0;
  uint64_t tt = t; bool gg = g, ss = s;
  if (eq < emin) {                                  // denormalise (T, G, S) by k with sticky
    int k = emin - eq; if (k > fb + 3) k = fb + 3;
    uint64_t x = (t << 1) | g;
    ss = s || (x & ((1ull << k) - 1)) != 0;
    x >>= k; tt = x >> 1; gg = x & 1;
  }
  bool inc = round_up(rm, sign, tt & 1, gg, ss);
  uint64_t packed;
  if (eq < emin) packed = tt + inc;
  else packed = ((uint64_t)(eq + bias - 1) << fb) + tt + inc;
  bool inexact = gg || ss;
  bool tiny = eq < emin && !(eq == emin - 1 && t == tmax && round_up(rm, sign, 1, g, s));
  if (inexact) fl |= NX;
  if (tiny && inexact) fl |= UF;
  if (eq + bias >= efmax || (packed >> fb) >= (uint64_t)efmax) {
    fl |= OF | NX;
    bool to_inf = rm == RNE || rm == RMM || (rm == RUP && !sign) || (rm == RDN && sign);
    if (to_inf) return {inf_bits(sign, dbl), fl};
    packed = ((uint64_t)(efmax - 1) << fb) | ((1ull << fb) - 1);
  }
  uint64_t bits = ((uint64_t)sign << (dbl ? 63 : 31)) | packed;
  return {box(bits, dbl), fl};
}

// The approximate correction terms of the small multipliers: e0 in Q.33 (signed),
// e2 ~ e0^2 and e3 ~ e0^3 in Q2.58 (signed).
// |e0| < 2^-8.6 (seed ROM bound plus the truncation of the SM0/SMa operands), so e0 fits the
// 27-bit signed A port of a DSP48E2 in Q.33, e0 >> 9 its 18-bit signed B port, and e2 >> 24
// (Q.34) the 17 magnitude bits of a B port. Returns the round-2 correction term in Q2.58:
// division e2 + e3, square root 3/8 e2 + 5/16 e3 (as (6 e2 + 5 e3) / 16, the SMc DSP's form).
inline int64_t small_terms(int64_t e0_33, bool sqrt) {
  int64_t b = e0_33 >> 9;                 // SMb B operand, Q.24
  int64_t e2 = (e0_33 * b) << 1;          // Q.33 x Q.24 = Q.57 -> Q.58
  int64_t e2hi = e2 >> 24;                // SMc A operand, Q.34
  if (e0_33 >= (1ll << 26) || e0_33 < -(1ll << 26) || e2hi >= (1ll << 17)) {
    fprintf(stderr, "gs model: small-multiplier operand out of range\n"); abort();
  }
  if (sqrt) return (5 * e2hi * b + 6 * e2) >> 4;
  return e2hi * b + e2;                   // e3 = e2hi x (e0 >> 9): Q.34 x Q.24 = Q.58
}

inline Result div(uint64_t a, uint64_t b, bool dbl, int rm, uint64_t *q_out = nullptr) {
  Unpacked ua = unpack(a, dbl), ub = unpack(b, dbl);
  bool sign = ua.sign ^ ub.sign;
  if (ua.nan || ub.nan) return {canon_nan(dbl), (uint8_t)((ua.snan || ub.snan) ? NV : 0)};
  if ((ua.inf && ub.inf) || (ua.zero && ub.zero)) return {canon_nan(dbl), NV};
  if (ua.inf || ub.zero) return {inf_bits(sign, dbl), (uint8_t)(ub.zero && !ua.inf ? DZ : 0)};
  if (ua.zero || ub.inf) return {zero_bits(sign, dbl), 0};

  bool lt = ua.sig < ub.sig;
  int eq = ua.exp - ub.exp - lt;
  uint64_t A = (lt ? ua.sig << 1 : ua.sig) << 6;     // Q2.58, [1, 4)
  uint64_t B = ub.sig << 6;                           // Q2.58, [1, 2)
  unsigned idx = (ub.sig >> 42) & 0x3FF;
  uint64_t s10 = 512 + SEED_ROM[idx];                 // Q0.10
  uint64_t s = s10 << (QF - 10);
  // SM0: approximate D0 from the top 24 bits of mb.
  uint64_t d0a = (ub.sig >> 29) * s10;                // Q1.23 x Q0.10 = Q1.33
  int64_t e0 = (int64_t)(1ull << 33) - (int64_t)d0a;
  int64_t e23 = small_terms(e0, false);
  // R1
  uint64_t n = mul(A, s), d = mul(B, s);
  // R2: cubic step
  uint64_t r = (uint64_t)((int64_t)(2 * ONE) - (int64_t)d + e23) & QMASK;
  n = mul(n, r); d = mul(d, r);
  // R3 (D)
  if (dbl) { r = (2 * ONE - d) & QMASK; n = mul(n, r); }
  // Error statistics: |n - q| with q = A/B exactly, in units of 2^-58: |n*B - A*2^58| / B.
  {
    i128 diff = (i128)((u128)n * B) - (i128)((u128)A << QF);
    double err = (double)(diff < 0 ? -diff : diff) / (double)B;
    double &w = stats().worst_err[dbl ? 1 : 0];
    if (err > w) w = err;
  }
  if (q_out) *q_out = n;
  // Remainder round
  const int gb = dbl ? 5 : 34;                        // guard-bit position in Q2.58
  uint64_t grid = 1ull << gb;
  uint64_t c = (n + (grid >> 1)) & ~(grid - 1);
  i128 rem = (i128)((u128)A << QF) - (i128)((u128)B * c);
  uint64_t f = rem < 0 ? c - grid : c;
  bool st = rem != 0;
  uint64_t t = f >> (gb + 1);
  bool g = (f >> gb) & 1;
  if ((t >> (dbl ? 52 : 23)) != 1) { fprintf(stderr, "gs model: div T out of range\n"); abort(); }
  return round_pack(sign, eq, t, g, st, dbl, rm);
}

inline Result sqrt(uint64_t a, bool dbl, int rm, uint64_t *q_out = nullptr) {
  Unpacked u = unpack(a, dbl);
  if (u.nan) return {canon_nan(dbl), (uint8_t)(u.snan ? NV : 0)};
  if (u.zero) return {zero_bits(u.sign, dbl), 0};
  if (u.sign) return {canon_nan(dbl), NV};
  if (u.inf) return {inf_bits(false, dbl), 0};

  bool odd = u.exp & 1;
  int eq = (u.exp - odd) >> 1;
  uint64_t X = (odd ? u.sig << 1 : u.sig) << 6;       // Q2.58, [1, 4)
  unsigned idx = 1024 | (odd << 9) | ((u.sig >> 43) & 0x1FF);
  uint64_t y10 = 512 + SEED_ROM[idx];                 // Q0.10
  uint64_t y0 = y10 << (QF - 10);
  uint64_t y2 = y10 * y10;                            // SM0: Q0.20, exact
  // SMa: approximate u0 = x * y0^2 from the top 26 bits of x.
  uint64_t ua = (X >> 34) * y2;                       // Q2.24 x Q0.20 = Q2.44
  int64_t e0 = ((int64_t)(1ull << 44) - (int64_t)ua) >> 11;   // Q.33
  int64_t t23 = small_terms(e0, true);
  // R1
  uint64_t q = mul(X, y0), u0 = mul(X, y2 << (QF - 20));
  // R2: P = (3 - u0)/2 + 3/8 e2 + 5/16 e3
  uint64_t p = (uint64_t)((int64_t)(3 * (ONE >> 1)) - (int64_t)(u0 >> 1) + t23) & QMASK;
  uint64_t y = mul(y0, p);
  q = mul(q, p);
  if (dbl) {
    uint64_t w = mul(q, y);                           // R3
    uint64_t f = 3 * (ONE >> 1) - (w >> 1);           // R4
    q = mul(q, f);
  }
  {
    // |q - sqrt(X)| ~ |q^2 - X| / (2 sqrt X); in units of 2^-58 with q, X in Q2.58.
    i128 diff = (i128)((u128)q * q) - (i128)((u128)X << QF);
    double sq = 0; { double xf = (double)X / (double)ONE; sq = __builtin_sqrt(xf); }
    double err = (double)(diff < 0 ? -diff : diff) / (double)ONE / (2.0 * sq);
    double &w = stats().worst_err[dbl ? 3 : 2];
    if (err > w) w = err;
  }
  if (q_out) *q_out = q;
  const int gb = dbl ? 5 : 34;
  uint64_t grid = 1ull << gb;
  uint64_t c = (q + (grid >> 1)) & ~(grid - 1);
  i128 rem = (i128)((u128)X << QF) - (i128)((u128)c * c);
  uint64_t f = rem < 0 ? c - grid : c;
  bool st = rem != 0;
  uint64_t t = f >> (gb + 1);
  bool g = (f >> gb) & 1;
  if ((t >> (dbl ? 52 : 23)) != 1) { fprintf(stderr, "gs model: sqrt T out of range\n"); abort(); }
  return round_pack(false, eq, t, g, st, dbl, rm);
}

}  // namespace gs
