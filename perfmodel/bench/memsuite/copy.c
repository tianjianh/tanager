/* Large memcpy (newlib), streaming reads and writes far beyond the L2. */
#include <string.h>

#include "memsuite.h"

#ifndef BYTES
#define BYTES (4u << 20)
#endif
#ifndef REPS
#define REPS 1  /* copies in the region */
#endif
#ifndef WARM
#define WARM 0  /* one copy before the region, for runs without fast-forward */
#endif

int main(void) {
  uint8_t *src = (uint8_t *)ms_alloc(BYTES);
  uint8_t *dst = (uint8_t *)ms_alloc(BYTES);
  for (uint32_t i = 0; i < BYTES; i += 64) src[i] = (uint8_t)i;
#if WARM > 0
  memcpy(dst, src, BYTES);
  __asm__ volatile("" ::: "memory");  /* keeps the copies below from being merged with this one */
#endif
  tg_region_start();
#if REPS > 1
  for (int r = 0; r < REPS; r++) {
    memcpy(dst, src, BYTES);
    __asm__ volatile("" ::: "memory");
  }
#else
  memcpy(dst, src, BYTES);
#endif
  tg_region_stop();
#if REPEAT
  for (;;) {  /* the region again (memsuite.h) */
    for (int r = 0; r < (REPS > 1 ? REPS : 1); r++) {
      memcpy(dst, src, BYTES);
      MS_SINK(dst);
    }
  }
#endif
  uint32_t sum = 0;
  for (uint32_t i = 0; i < BYTES; i += 4096) sum += dst[i];
  printf("copy bytes=%u check=%u\n", (unsigned)BYTES, sum);
  return 0;
}
