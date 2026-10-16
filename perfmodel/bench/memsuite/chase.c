/* Pointer chasing over CHAINS independent random cycles of 64-byte nodes, with FILLER independent
   ALU instructions between hops. CHAINS=1 measures pure latency; CHAINS=8 measures memory-level
   parallelism (how many misses the core keeps in flight). */
#include "memsuite.h"

#ifndef CHAINS
#define CHAINS 8
#endif
#ifndef FILLER
#define FILLER 0
#endif
#ifndef FOOTPRINT_MB
#define FOOTPRINT_MB 32
#endif
#ifndef FOOTPRINT_KB
#define FOOTPRINT_KB (FOOTPRINT_MB * 1024)
#endif
#ifndef HOPS
#define HOPS 6000
#endif
#ifndef WARM
#define WARM 0  /* full passes over every chain before the region, for runs without fast-forward */
#endif

typedef struct node { struct node *next; uint64_t pad[7]; } node;

#define STR2(x) #x
#define STR(x) STR2(x)

static inline void filler(uint64_t *a, uint64_t *b) {
#if FILLER > 0
  /* Exactly FILLER instructions: FILLER/2 dependent adds on each of two registers, independent of the
     loaded pointers (.rept keeps the compiler from adding loop overhead). */
  __asm__ volatile(".rept " STR(FILLER) "/2\n\taddi %0, %0, 1\n\taddi %1, %1, 3\n\t.endr" : "+r"(*a), "+r"(*b));
#else
  (void)a;
  (void)b;
#endif
}

int main(void) {
  const uint32_t per_chain = (uint32_t)(((uint64_t)FOOTPRINT_KB << 10) / sizeof(node) / CHAINS);
  node *heads[CHAINS];
  uint32_t *perm = (uint32_t *)malloc(per_chain * sizeof(uint32_t));
  for (int c = 0; c < CHAINS; c++) {
    node *arr = (node *)ms_alloc((size_t)per_chain * sizeof(node));
    ms_cycle(perm, per_chain);
    for (uint32_t i = 0; i < per_chain; i++) arr[i].next = &arr[perm[i]];
    heads[c] = &arr[0];
  }
  uint64_t fa = 0, fb = 0;
  node *p[CHAINS];
  for (int c = 0; c < CHAINS; c++) p[c] = heads[c];
#if WARM > 0
  for (int w = 0; w < WARM; w++)
    for (uint32_t h = 0; h < per_chain; h++)
      for (int c = 0; c < CHAINS; c++) p[c] = p[c]->next;  /* each chain is one cycle: back at its head */
#endif
  tg_region_start();
  for (int h = 0; h < HOPS; h++) {
#pragma GCC unroll 16
    for (int c = 0; c < CHAINS; c++) {
      p[c] = p[c]->next;
      filler(&fa, &fb);
    }
  }
  tg_region_stop();
  uintptr_t sum = 0;
  for (int c = 0; c < CHAINS; c++) sum ^= (uintptr_t)p[c];
  printf("chase chains=%d filler=%d hops=%d check=%lx f=%lu\n", CHAINS, FILLER, HOPS, (unsigned long)(sum & 0xfffff),
         (unsigned long)(fa + fb));
  return 0;
}
