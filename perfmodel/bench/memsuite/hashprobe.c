/* Open-addressing hash table lookups with random keys: independent lookups (memory-level parallelism)
   mixed with data-dependent branches. */
#include "memsuite.h"

#ifndef SLOTS_LOG
#define SLOTS_LOG 22  /* 4M slots x 8 bytes = 32 MiB */
#endif
#ifndef LOOKUPS
#define LOOKUPS 60000
#endif

static inline uint64_t mix(uint64_t k) {
  k ^= k >> 33; k *= 0xff51afd7ed558ccdull; k ^= k >> 33;
  return k;
}

int main(void) {
  const uint64_t slots = 1ull << SLOTS_LOG, mask = slots - 1;
  uint64_t *tab = (uint64_t *)ms_alloc(slots * sizeof(uint64_t));
  const uint64_t nkeys = slots / 2;
  for (uint64_t i = 1; i <= nkeys; i++) {
    uint64_t h = mix(i * 2) & mask;
    while (tab[h]) h = (h + 1) & mask;
    tab[h] = i * 2;
  }
  uint64_t found = 0;
  tg_region_start();
  for (uint32_t q = 0; q < LOOKUPS; q++) {
    const uint64_t key = (ms_rand() % (2 * nkeys)) + 1;  /* even keys present, odd keys absent */
    uint64_t h = mix(key) & mask;
    while (tab[h] && tab[h] != key) h = (h + 1) & mask;
    found += tab[h] == key;
  }
  tg_region_stop();
#if REPEAT
  for (;;) {  /* the region again (memsuite.h) */
    for (uint32_t q = 0; q < LOOKUPS; q++) {
      const uint64_t key = (ms_rand() % (2 * nkeys)) + 1;
      uint64_t h = mix(key) & mask;
      while (tab[h] && tab[h] != key) h = (h + 1) & mask;
      found += tab[h] == key;
    }
    MS_SINK(found);
  }
#endif
  printf("hashprobe lookups=%d found=%lu\n", LOOKUPS, (unsigned long)found);
  return 0;
}
