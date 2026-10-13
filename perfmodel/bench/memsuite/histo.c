/* Byte histogram of skewed data (most bytes come from a few values, as in text): the load of a counter
   often follows, closely, a store to the same counter. This is the case memory-dependence prediction is
   for: a load that runs ahead of an older store to the same address must be replayed. */
#include "memsuite.h"

#ifndef N
#define N (1u << 18)
#endif

int main(void) {
  uint8_t *in = (uint8_t *)ms_alloc(N);
  for (uint32_t i = 0; i < N; i++) {
    const uint64_t r = ms_rand();
    in[i] = (r & 7) ? (uint8_t)((r >> 8) & 7) : (uint8_t)(r >> 16);  /* 7/8 from 8 values */
  }
  static uint32_t hist[256];
  tg_region_start();
  for (uint32_t i = 0; i < N; i++) hist[in[i]]++;
  tg_region_stop();
  uint32_t chk = 0;
  for (int b = 0; b < 256; b++) chk = chk * 31 + hist[b];
  printf("histo n=%u chk=%08x\n", N, chk);
  return 0;
}
