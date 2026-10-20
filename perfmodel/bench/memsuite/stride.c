/* Column walk over a row-major matrix: consecutive loads are one 4 KiB row apart, so a next-line stream
   prefetcher cannot follow them and a PC-stride prefetcher can. Each column touches new lines. */
#include "memsuite.h"

#ifndef ROWS
#define ROWS 4096
#endif
#ifndef COLS
#define COLS 512  /* 8-byte elements: 4 KiB rows, 16 MiB matrix */
#endif
#ifndef WALKS
#define WALKS 12  /* columns walked, one per cache line */
#endif

int main(void) {
  uint64_t *m = (uint64_t *)ms_alloc((size_t)ROWS * COLS * sizeof(uint64_t));
  for (size_t i = 0; i < (size_t)ROWS * COLS; i++) m[i] = i & 1023;
  uint64_t sum = 0;
  tg_region_start();
  for (uint32_t w = 0; w < WALKS; w++) {
    const uint32_t c = w * 8;
    for (uint32_t r = 0; r < ROWS; r++) sum += m[(size_t)r * COLS + c] ^ r;
  }
  tg_region_stop();
#if REPEAT
  for (;;) {  /* the region again (memsuite.h) */
    for (uint32_t w = 0; w < WALKS; w++) {
      const uint32_t c = w * 8;
      for (uint32_t r = 0; r < ROWS; r++) sum += m[(size_t)r * COLS + c] ^ r;
    }
    MS_SINK(sum);
  }
#endif
  printf("stride sum=%lu\n", (unsigned long)sum);
  return 0;
}
