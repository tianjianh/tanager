/* Counter updates scattered over a table of 2^TABLE_LOG words for the partial-address LQ/SQ search (area_recovery.md
   §7.10): each update loads a key, then loads, increments and stores its counter, so the store's address comes from a
   load and resolves late, and a younger counter load can meet it on the low address bits. KEYS random keys a pass,
   PASSES passes in the region. */
#include "memsuite.h"
#ifndef TABLE_LOG
#define TABLE_LOG 16
#endif
#ifndef KEYS
#define KEYS (1u << 15)
#endif
#ifndef PASSES
#define PASSES 4
#endif

static uint32_t table[1u << TABLE_LOG];
static uint32_t keys[KEYS];

int main(void) {
  for (unsigned i = 0; i < KEYS; i++) keys[i] = (uint32_t)(ms_rand() & ((1u << TABLE_LOG) - 1));
  for (unsigned i = 0; i < KEYS; i++) table[keys[i]]++;   /* warm */
  tg_region_start();
  for (int p = 0; p < PASSES; p++)
    for (unsigned i = 0; i < KEYS; i++) table[keys[i]]++;
  tg_region_stop();
  uint32_t chk = 0;
  for (unsigned b = 0; b < (1u << TABLE_LOG); b += 7) chk = chk * 31 + table[b];
  printf("scatter log=%d keys=%u chk=%08x\n", TABLE_LOG, (unsigned)KEYS, chk);
  return 0;
}
