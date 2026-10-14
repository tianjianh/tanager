// TestFloat functions and their mapping onto fop_e requests, shared by the FPU testbenches
// (tb_fpu.cpp, tb_fpx.cpp; docs/spec/fpu.md, "Verification").
#pragma once
#include <cstdint>
#include <random>
#include "fpu_ref.h"

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

