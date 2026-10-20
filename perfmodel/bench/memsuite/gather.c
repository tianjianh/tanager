/* Random gather with dependent work: the index stream is sequential (prefetchable), the gathered elements
   are random in a 32 MiB table, and each gathered value feeds a short chain of dependent arithmetic, as in
   hash joins and graph edge loops. The misses are independent, but their consumers wait in the issue
   queues and at the ROB head, so the window, not just the MSHRs, sets the memory-level parallelism. */
#include "memsuite.h"

#ifndef TAB_LOG
#define TAB_LOG 22  /* 4M x 8 bytes = 32 MiB */
#endif
#ifndef N
#define N 30000
#endif

int main(void) {
  const uint64_t n = 1ull << TAB_LOG, mask = n - 1;
  uint64_t *tab = (uint64_t *)ms_alloc(n * sizeof(uint64_t));
  for (uint64_t i = 0; i < n; i++) tab[i] = i * 0x9e3779b97f4a7c15ull;
  uint32_t *idx = (uint32_t *)ms_alloc(N * sizeof(uint32_t));
  for (uint32_t i = 0; i < N; i++) idx[i] = (uint32_t)(ms_rand() & mask);
  uint64_t acc = 0;
  tg_region_start();
  for (uint32_t i = 0; i < N; i++) {
    uint64_t v = tab[idx[i]];
    v ^= v >> 29;
    v *= 0xbf58476d1ce4e5b9ull;
    v ^= v >> 32;
    acc += v;
  }
  tg_region_stop();
#if REPEAT
  for (;;) {  /* the region again (memsuite.h) */
    for (uint32_t i = 0; i < N; i++) {
      uint64_t v = tab[idx[i]];
      v ^= v >> 29;
      v *= 0xbf58476d1ce4e5b9ull;
      v ^= v >> 32;
      acc += v;
    }
    MS_SINK(acc);
  }
#endif
  printf("gather n=%d acc=%016llx\n", N, (unsigned long long)acc);
  return 0;
}
