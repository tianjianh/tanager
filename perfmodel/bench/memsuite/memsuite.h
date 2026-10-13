/* Shared helpers for the memory-latency kernels. Each kernel brackets its timed loop with tgsim's
   region markers and prints a checksum so a functional error is visible. */
#ifndef MEMSUITE_H
#define MEMSUITE_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "tgsim.h"

static uint64_t ms_rng = 0x9e3779b97f4a7c15ull;
static inline uint64_t ms_rand(void) {
  ms_rng ^= ms_rng << 13;
  ms_rng ^= ms_rng >> 7;
  ms_rng ^= ms_rng << 17;
  return ms_rng;
}

/* Random cyclic permutation of n elements (Sattolo's algorithm). */
static inline void ms_cycle(uint32_t *perm, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) perm[i] = i;
  for (uint32_t i = n - 1; i > 0; i--) {
    uint32_t j = (uint32_t)(ms_rand() % i);
    uint32_t t = perm[i];
    perm[i] = perm[j];
    perm[j] = t;
  }
}

static inline void *ms_alloc(size_t bytes) {
  void *p = malloc(bytes + 64);
  if (!p) { printf("out of memory\n"); exit(2); }
  return (void *)(((uintptr_t)p + 63) & ~(uintptr_t)63);
}

#endif
