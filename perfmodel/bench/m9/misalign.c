/* Misaligned loads and stores, to check tgsim's m9_counts counters (docs/perf/area_recovery.md §7.11): 8-, 4- and
   2-byte words copied between buffers at odd offsets, as unaligned record or packet parsing does. The region makes
   3,584 misaligned loads and as many misaligned stores (512 + 1,024 + 2,048). The accesses are written in asm: GCC
   splits a C access it can see is misaligned into bytes. */
#include <stdint.h>
#include "memsuite.h"

#define LD(insn, T) static inline T insn##_(const uint8_t *p) {                                      \
    long v; __asm__ volatile(#insn " %0, 0(%1)" : "=r"(v) : "r"(p) : "memory"); return (T)v; }
#define ST(insn, T) static inline void insn##_(uint8_t *p, T v) {                                    \
    __asm__ volatile(#insn " %0, 0(%1)" :: "r"((long)v), "r"(p) : "memory"); }
LD(ld, uint64_t)
LD(lw, uint32_t)
LD(lh, uint16_t)
ST(sd, uint64_t)
ST(sw, uint32_t)
ST(sh, uint16_t)

static uint8_t src[4096 + 64] __attribute__((aligned(64))), dst[4096 + 64] __attribute__((aligned(64)));

int main(void) {
  for (int i = 0; i < (int)sizeof src; i++) src[i] = (uint8_t)(i * 7 + 1);
  uint64_t s = 0;
  tg_region_start();
  for (int i = 0; i < 4096; i += 8) {
    uint64_t v = ld_(src + 1 + i);
    sd_(dst + 3 + i, v);
    s += v;
  }
  for (int i = 0; i < 4096; i += 4) {
    uint32_t v = lw_(src + 2 + i);
    sw_(dst + 1 + i, v);
    s += v;
  }
  for (int i = 0; i < 4096; i += 2) {
    uint16_t v = lh_(src + 1 + i);
    sh_(dst + 1 + i, v);
    s += v;
  }
  tg_region_stop();
  printf("misalign check=%lu\n", (unsigned long)s);
  return 0;
}
