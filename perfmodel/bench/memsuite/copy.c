/* Large memcpy (newlib), streaming reads and writes far beyond the L2. */
#include <string.h>

#include "memsuite.h"

#ifndef BYTES
#define BYTES (4u << 20)
#endif

int main(void) {
  uint8_t *src = (uint8_t *)ms_alloc(BYTES);
  uint8_t *dst = (uint8_t *)ms_alloc(BYTES);
  for (uint32_t i = 0; i < BYTES; i += 64) src[i] = (uint8_t)i;
  tg_region_start();
  memcpy(dst, src, BYTES);
  tg_region_stop();
  uint32_t sum = 0;
  for (uint32_t i = 0; i < BYTES; i += 4096) sum += dst[i];
  printf("copy bytes=%u check=%u\n", (unsigned)BYTES, sum);
  return 0;
}
