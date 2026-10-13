// Shared helpers for the Tanager simulation harness (docs/spec/verification.md).
#pragma once

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace tg {

// Exit statuses of tg_vsim and tg_replay (verification.md §2.7).
enum exit_status : int {
  EXIT_PASS = 0,
  EXIT_PROGRAM_FAIL = 1,
  EXIT_MISMATCH = 2,
  EXIT_PROTOCOL = 3,
  EXIT_TIMEOUT = 4,
  EXIT_HARNESS = 5,
};

inline const char* exit_status_name(int s) {
  switch (s) {
    case EXIT_PASS: return "PASS";
    case EXIT_PROGRAM_FAIL: return "FAIL";
    case EXIT_MISMATCH: return "MISMATCH";
    case EXIT_PROTOCOL: return "PROTOCOL";
    case EXIT_TIMEOUT: return "TIMEOUT";
    default: return "ERROR";
  }
}

[[noreturn]] inline void fatal(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "tg: error: ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
  exit(EXIT_HARNESS);
}

inline std::string strfmt(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  char buf[1024];
  int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (n < (int)sizeof buf) return std::string(buf, n > 0 ? n : 0);
  std::string s(n + 1, '\0');
  va_start(ap, fmt);
  vsnprintf(s.data(), s.size(), fmt, ap);
  va_end(ap);
  s.resize(n);
  return s;
}

inline uint64_t sext(uint64_t v, unsigned bits) {
  if (bits >= 64) return v;
  uint64_t m = 1ull << (bits - 1);
  v &= (1ull << bits) - 1;
  return (v ^ m) - m;
}

inline uint64_t size_mask(unsigned log2_bytes) {
  return log2_bytes >= 3 ? ~0ull : ((1ull << (8u << log2_bytes)) - 1);
}

// Small deterministic PRNG (xorshift64*) so runs are reproducible from --seed.
struct rng_t {
  uint64_t s;
  explicit rng_t(uint64_t seed = 1) : s(seed ? seed : 0x9e3779b97f4a7c15ull) {}
  uint64_t next() {
    s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
    return s * 0x2545f4914f6cdd1dull;
  }
  // Uniform in [0, n); n > 0.
  uint64_t below(uint64_t n) { return n ? next() % n : 0; }
  // True with probability p/1000.
  bool permille(unsigned p) { return p && below(1000) < p; }
  bool percent(unsigned p) { return p && below(100) < p; }
};

}  // namespace tg
