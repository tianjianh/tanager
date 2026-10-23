/* Copies a set distance apart for the partial-address LQ/SQ search (area_recovery.md §7.10): BYTES copied from src to
   src + DIST in one buffer, so a load meets the stores DIST bytes behind it modulo 2^N. KIND 0: a word at a time, eight
   loads then eight stores a 64-byte block; 2: newlib's memcpy. PASSES passes in the region. */
#include <string.h>
#include "memsuite.h"
#ifndef KIND
#define KIND 0
#endif
#ifndef BYTES
#define BYTES (64u << 10)
#endif
#ifndef DIST
#define DIST ((17u << 12) + 64u)
#endif
#ifndef PASSES
#define PASSES 8
#endif

static uint64_t buf[(DIST + BYTES) / 8 + 8] __attribute__((aligned(4096)));

static void copy_words(uint64_t *d, const uint64_t *s) {
  for (unsigned i = 0; i < BYTES / 8; i += 8) {
    uint64_t a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
    uint64_t a4 = s[i + 4], a5 = s[i + 5], a6 = s[i + 6], a7 = s[i + 7];
    d[i] = a0; d[i + 1] = a1; d[i + 2] = a2; d[i + 3] = a3;
    d[i + 4] = a4; d[i + 5] = a5; d[i + 6] = a6; d[i + 7] = a7;
  }
}

static void pass(uint8_t *dst, const uint8_t *src) {
#if KIND == 0
  copy_words((uint64_t *)dst, (const uint64_t *)src);
#else
  memcpy(dst, src, BYTES);
#endif
  __asm__ volatile("" ::: "memory");
}

int main(void) {
  uint8_t *src = (uint8_t *)buf, *dst = (uint8_t *)buf + DIST;
  for (unsigned i = 0; i < BYTES / 8; i++) buf[i] = i * 0x9e3779b97f4a7c15ull;
  pass(dst, src);   /* warm */
  tg_region_start();
  for (int p = 0; p < PASSES; p++) pass(dst, src);
  tg_region_stop();
  uint64_t sum = 0;
  for (unsigned i = 0; i < BYTES; i += 512) sum += dst[i];
  printf("copydist kind=%d dist=%u check=%llu\n", KIND, (unsigned)DIST, (unsigned long long)sum);
  return 0;
}
