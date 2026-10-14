// Reference model of the RISC-V F/D operations for the FPU tests (docs/spec/fpu.md, "Verification").
// Arithmetic comes from Berkeley SoftFloat 3 built with the RISC-V specialization; the behaviour
// SoftFloat does not cover (NaN boxing, FMIN/FMAX, FCLASS, sign injection, moves, RV64 sign
// extension) is written here from the ISA manual.
#pragma once
#include <cstdint>
extern "C" {
#define SOFTFLOAT_FAST_INT64
#include "softfloat.h"
}

namespace ref {

// Operation codes: the values of tg_fpu_pkg::fop_e.
enum Op {
  FADD, FSUB, FMUL, FMADD, FMSUB, FNMSUB, FNMADD,
  FDIV, FSQRT,
  FSGNJ, FSGNJN, FSGNJX, FMIN, FMAX,
  FEQ, FLT, FLE, FCLASS,
  FCVT_F_F, FCVT_I_F, FCVT_F_I, FMV_X_F, FMV_F_X,
  NUM_OPS
};
enum Fmt { S = 0, D = 1 };
enum IFmt { W = 0, WU = 1, L = 2, LU = 3 };
enum { NX = 1, UF = 2, OF = 4, DZ = 8, NV = 16 };

struct Req {
  int op, fmt, src_fmt, ifmt, rm;
  uint64_t a, b, c;
};
struct Resp {
  uint64_t result;
  uint8_t flags;
  bool int_dest;
};

inline const char *op_name(int op) {
  static const char *n[] = {"fadd", "fsub", "fmul", "fmadd", "fmsub", "fnmsub", "fnmadd", "fdiv", "fsqrt",
                            "fsgnj", "fsgnjn", "fsgnjx", "fmin", "fmax", "feq", "flt", "fle", "fclass",
                            "fcvt.f.f", "fcvt.i.f", "fcvt.f.i", "fmv.x.f", "fmv.f.x"};
  return op >= 0 && op < NUM_OPS ? n[op] : "?";
}
inline int unit_of(int op) {  // 0 = FMA, 1 = FMISC, 2 = divide/sqrt
  return op <= FNMADD ? 0 : (op <= FSQRT ? 2 : 1);
}

inline uint64_t box32(uint32_t v) { return 0xFFFFFFFF00000000ull | v; }
inline uint32_t unbox32(uint64_t v) { return (v >> 32) == 0xFFFFFFFFull ? (uint32_t)v : 0x7FC00000u; }
inline uint64_t sext32(uint32_t v) { return (uint64_t)(int64_t)(int32_t)v; }

inline bool isnan32(uint32_t v) { return ((v >> 23) & 0xFF) == 0xFF && (v & 0x7FFFFF); }
inline bool isnan64(uint64_t v) { return ((v >> 52) & 0x7FF) == 0x7FF && (v & 0xFFFFFFFFFFFFFull); }
inline bool issnan32(uint32_t v) { return isnan32(v) && !((v >> 22) & 1); }
inline bool issnan64(uint64_t v) { return isnan64(v) && !((v >> 51) & 1); }

inline uint16_t classify(uint64_t v, bool dbl) {
  bool sign; int e, emax; uint64_t frac, qbit;
  if (dbl) { sign = v >> 63; e = (v >> 52) & 0x7FF; frac = v & 0xFFFFFFFFFFFFFull; emax = 0x7FF; qbit = 1ull << 51; }
  else { sign = (v >> 31) & 1; e = (v >> 23) & 0xFF; frac = v & 0x7FFFFF; emax = 0xFF; qbit = 1ull << 22; }
  if (e == emax) {
    if (frac == 0) return sign ? 1 << 0 : 1 << 7;
    return (frac & qbit) ? 1 << 9 : 1 << 8;
  }
  if (e == 0) {
    if (frac == 0) return sign ? 1 << 3 : 1 << 4;
    return sign ? 1 << 2 : 1 << 5;
  }
  return sign ? 1 << 1 : 1 << 6;
}

inline void sf_begin(int rm) {
  softfloat_roundingMode = (uint_fast8_t)rm;
  softfloat_exceptionFlags = 0;
  softfloat_detectTininess = softfloat_tininess_afterRounding;
}
inline uint8_t sf_flags() { return (uint8_t)(softfloat_exceptionFlags & 0x1F); }

inline Resp compute(const Req &q) {
  Resp r{0, 0, false};
  const bool dbl = q.fmt == D;
  const uint32_t a32 = unbox32(q.a), b32 = unbox32(q.b), c32 = unbox32(q.c);
  float32_t fa{a32}, fb{b32}, fc{c32};
  float64_t da{q.a}, db{q.b}, dc{q.c};
  sf_begin(q.rm);
  auto fr32 = [&](float32_t v) { r.result = box32(v.v); r.flags = sf_flags(); };
  auto fr64 = [&](float64_t v) { r.result = v.v; r.flags = sf_flags(); };
  const uint32_t s32 = 0x80000000u;
  const uint64_t s64 = 0x8000000000000000ull;
  switch (q.op) {
    case FADD: dbl ? fr64(f64_add(da, db)) : fr32(f32_add(fa, fb)); break;
    case FSUB: dbl ? fr64(f64_sub(da, db)) : fr32(f32_sub(fa, fb)); break;
    case FMUL: dbl ? fr64(f64_mul(da, db)) : fr32(f32_mul(fa, fb)); break;
    case FMADD: dbl ? fr64(f64_mulAdd(da, db, dc)) : fr32(f32_mulAdd(fa, fb, fc)); break;
    case FMSUB:
      dbl ? fr64(f64_mulAdd(da, db, float64_t{dc.v ^ s64})) : fr32(f32_mulAdd(fa, fb, float32_t{fc.v ^ s32}));
      break;
    case FNMSUB:
      dbl ? fr64(f64_mulAdd(float64_t{da.v ^ s64}, db, dc)) : fr32(f32_mulAdd(float32_t{fa.v ^ s32}, fb, fc));
      break;
    case FNMADD:
      dbl ? fr64(f64_mulAdd(float64_t{da.v ^ s64}, db, float64_t{dc.v ^ s64}))
          : fr32(f32_mulAdd(float32_t{fa.v ^ s32}, fb, float32_t{fc.v ^ s32}));
      break;
    case FDIV: dbl ? fr64(f64_div(da, db)) : fr32(f32_div(fa, fb)); break;
    case FSQRT: dbl ? fr64(f64_sqrt(da)) : fr32(f32_sqrt(fa)); break;
    case FSGNJ: case FSGNJN: case FSGNJX: {
      if (dbl) {
        uint64_t sb = q.b & s64;
        if (q.op == FSGNJN) sb ^= s64;
        if (q.op == FSGNJX) sb = (q.a ^ q.b) & s64;
        r.result = (q.a & ~s64) | sb;
      } else {
        uint32_t sb = b32 & s32;
        if (q.op == FSGNJN) sb ^= s32;
        if (q.op == FSGNJX) sb = (a32 ^ b32) & s32;
        r.result = box32((a32 & ~s32) | sb);
      }
      break;
    }
    case FMIN: case FMAX: {
      bool mx = q.op == FMAX;
      if (dbl) {
        bool na = isnan64(q.a), nb = isnan64(q.b);
        if (issnan64(q.a) || issnan64(q.b)) r.flags |= NV;
        if (na && nb) r.result = 0x7FF8000000000000ull;
        else if (na) r.result = q.b;
        else if (nb) r.result = q.a;
        else {
          sf_begin(q.rm);
          bool alt = f64_lt_quiet(da, db) || (f64_eq(da, db) && (q.a >> 63) && !(q.b >> 63));
          r.result = (alt != mx) ? q.a : q.b;
        }
      } else {
        bool na = isnan32(a32), nb = isnan32(b32);
        if (issnan32(a32) || issnan32(b32)) r.flags |= NV;
        if (na && nb) r.result = box32(0x7FC00000u);
        else if (na) r.result = box32(b32);
        else if (nb) r.result = box32(a32);
        else {
          sf_begin(q.rm);
          bool alt = f32_lt_quiet(fa, fb) || (f32_eq(fa, fb) && (a32 >> 31) && !(b32 >> 31));
          r.result = box32((alt != mx) ? a32 : b32);
        }
      }
      break;
    }
    case FEQ: case FLT: case FLE: {
      bool v;
      if (dbl) v = q.op == FEQ ? f64_eq(da, db) : q.op == FLT ? f64_lt(da, db) : f64_le(da, db);
      else v = q.op == FEQ ? f32_eq(fa, fb) : q.op == FLT ? f32_lt(fa, fb) : f32_le(fa, fb);
      r.result = v; r.flags = sf_flags(); r.int_dest = true;
      break;
    }
    case FCLASS:
      r.result = dbl ? classify(q.a, true) : classify(a32, false);
      r.int_dest = true;
      break;
    case FCVT_F_F:
      if (dbl) fr64(f32_to_f64(fa));      // FCVT.D.S
      else fr32(f64_to_f32(da));          // FCVT.S.D
      break;
    case FCVT_I_F: {
      uint64_t v = 0;
      switch (q.ifmt) {
        case W: v = sext32((uint32_t)(dbl ? f64_to_i32(da, q.rm, true) : f32_to_i32(fa, q.rm, true))); break;
        case WU: v = sext32(dbl ? f64_to_ui32(da, q.rm, true) : f32_to_ui32(fa, q.rm, true)); break;
        case L: v = (uint64_t)(dbl ? f64_to_i64(da, q.rm, true) : f32_to_i64(fa, q.rm, true)); break;
        default: v = dbl ? f64_to_ui64(da, q.rm, true) : f32_to_ui64(fa, q.rm, true); break;
      }
      r.result = v; r.flags = sf_flags(); r.int_dest = true;
      break;
    }
    case FCVT_F_I:
      switch (q.ifmt) {
        case W: dbl ? fr64(i32_to_f64((int32_t)q.a)) : fr32(i32_to_f32((int32_t)q.a)); break;
        case WU: dbl ? fr64(ui32_to_f64((uint32_t)q.a)) : fr32(ui32_to_f32((uint32_t)q.a)); break;
        case L: dbl ? fr64(i64_to_f64((int64_t)q.a)) : fr32(i64_to_f32((int64_t)q.a)); break;
        default: dbl ? fr64(ui64_to_f64(q.a)) : fr32(ui64_to_f32(q.a)); break;
      }
      break;
    case FMV_X_F: r.result = dbl ? q.a : sext32((uint32_t)q.a); r.int_dest = true; break;
    case FMV_F_X: r.result = dbl ? q.a : box32((uint32_t)q.a); break;
    default: break;
  }
  return r;
}

}  // namespace ref
