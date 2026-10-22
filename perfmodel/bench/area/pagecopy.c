/* Page copies and clears for the partial-address LQ/SQ search (area_recovery.md §7.9): page-aligned buffers, the
   destination OFFSET bytes past its page boundary, so the loads run OFFSET bytes ahead of the stores modulo 4 KiB.
   KIND 0: PAGES pages copied a word at a time, eight loads then eight stores a 64-byte block; 1: the pages cleared,
   eight stores a block; 2: newlib's memcpy a page at a time. PASSES passes in the region. */
#include <string.h>
#include "memsuite.h"
#ifndef KIND
#define KIND 0
#endif
#ifndef PAGES
#define PAGES 64
#endif
#ifndef PASSES
#define PASSES 4
#endif
#ifndef OFFSET
#define OFFSET 0
#endif
#define PAGE 4096u

static uint64_t src_buf[PAGES * PAGE / 8] __attribute__((aligned(PAGE)));
static uint64_t dst_buf[(PAGES + 1) * PAGE / 8] __attribute__((aligned(PAGE)));

static void copy_page(uint64_t *d, const uint64_t *s) {
  for (unsigned i = 0; i < PAGE / 8; i += 8) {
    uint64_t a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
    uint64_t a4 = s[i + 4], a5 = s[i + 5], a6 = s[i + 6], a7 = s[i + 7];
    d[i] = a0; d[i + 1] = a1; d[i + 2] = a2; d[i + 3] = a3;
    d[i + 4] = a4; d[i + 5] = a5; d[i + 6] = a6; d[i + 7] = a7;
  }
}

static void clear_page(uint64_t *d) {
  for (unsigned i = 0; i < PAGE / 8; i += 8) {
    d[i] = 0; d[i + 1] = 0; d[i + 2] = 0; d[i + 3] = 0;
    d[i + 4] = 0; d[i + 5] = 0; d[i + 6] = 0; d[i + 7] = 0;
  }
}

static void pass(uint8_t *dst) {
  for (unsigned g = 0; g < PAGES; g++) {
#if KIND == 0
    copy_page((uint64_t *)(dst + g * PAGE), src_buf + g * (PAGE / 8));
#elif KIND == 1
    clear_page((uint64_t *)(dst + g * PAGE));
#else
    memcpy(dst + g * PAGE, (const uint8_t *)src_buf + g * PAGE, PAGE);
#endif
  }
  __asm__ volatile("" ::: "memory");
}

int main(void) {
  uint8_t *dst = (uint8_t *)dst_buf + OFFSET;
  for (unsigned i = 0; i < PAGES * PAGE / 8; i++) src_buf[i] = i * 0x9e3779b97f4a7c15ull;
  pass(dst);   /* warm: the pages touched once before the region */
  tg_region_start();
  for (int p = 0; p < PASSES; p++) pass(dst);
  tg_region_stop();
  uint64_t sum = 0;
  for (unsigned i = 0; i < PAGES * PAGE; i += 512) sum += dst[i];
  printf("pagecopy kind=%d offset=%d check=%llu\n", KIND, OFFSET, (unsigned long long)sum);
  return 0;
}
