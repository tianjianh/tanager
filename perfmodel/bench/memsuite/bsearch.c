/* Binary search over a sorted array far larger than the L2: dependent loads behind hard-to-predict
   branches, with independent queries. */
#include "memsuite.h"

#ifndef N_LOG
#define N_LOG 22  /* 4M x 4 bytes = 16 MiB */
#endif
#ifndef QUERIES
#define QUERIES 20000
#endif

int main(void) {
  const uint32_t n = 1u << N_LOG;
  uint32_t *a = (uint32_t *)ms_alloc((size_t)n * sizeof(uint32_t));
  for (uint32_t i = 0; i < n; i++) a[i] = i * 3 + 1;
  uint32_t hits = 0;
  tg_region_start();
  for (uint32_t q = 0; q < QUERIES; q++) {
    const uint32_t key = (uint32_t)(ms_rand() % (3ull * n));
    uint32_t lo = 0, hi = n;
    while (lo < hi) {
      const uint32_t mid = lo + (hi - lo) / 2;
      if (a[mid] < key) lo = mid + 1;
      else hi = mid;
    }
    hits += lo < n && a[lo] == key;
  }
  tg_region_stop();
  printf("bsearch queries=%d hits=%u\n", QUERIES, hits);
  return 0;
}
