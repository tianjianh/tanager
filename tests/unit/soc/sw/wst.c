/* wst: DDR write and read streaming on the SoC, for tb_boot (tests/unit/boot) as its firmware (soc-2, 10-23; soc.md
   §8.5): hart RUN_HART (0, or 1 for wst_h1) writes 4 MiB, 8x the board's L2, once to allocate it, then times a write
   pass and a read pass with mcycle, in 64-byte lines of eight 8-byte stores or loads, and prints cycles per line x100
   on the 16550; TANAGER-BOOT-OK ends tb_boot. The other harts wait in WFI. Run, for example:
     make -C tests/unit/boot run CFG=smt2 CORES=2 LAT_INJ=0 VTHREADS=1 TAG=_wst MEM_PARAMS="-GL2_SETS_TB=1024" \
       ARGS="+fw=$SOC_BUILD/tests/soc_sw/wst.bin +expect=TANAGER-BOOT-OK +max_mcycles=60 +mem_lat_min=22 \
             +mem_lat_max=22 +mem_ready_pct=100 +mem_r_pct=100 +mem_ooo=0" */
#include <stdint.h>
#define UART   ((volatile uint8_t *)0x10000000ul)
#define REGION ((volatile uint64_t *)0x81000000ul)
#define BYTES  (4ul << 20)
#define LINES  (BYTES / 64)
static void putc_(char c) { while (!(UART[5] & 0x20)) { } UART[0] = (uint8_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void putdec(uint64_t v) { char b[24]; int i = 0; do { b[i++] = (char)('0' + v % 10); v /= 10; } while (v); while (i) putc_(b[--i]); }
static inline uint64_t cyc(void) { uint64_t c; __asm__ volatile("csrr %0, mcycle" : "=r"(c)); return c; }
static void wr(uint64_t v) {
  volatile uint64_t *p = REGION;
  for (uint64_t l = 0; l < LINES; l++, p += 8) { p[0] = v; p[1] = v; p[2] = v; p[3] = v; p[4] = v; p[5] = v; p[6] = v; p[7] = v; }
}
static uint64_t rd(void) {
  volatile uint64_t *p = REGION; uint64_t s = 0;
  for (uint64_t l = 0; l < LINES; l++, p += 8) s += p[0] + p[1] + p[2] + p[3] + p[4] + p[5] + p[6] + p[7];
  return s;
}
#ifndef RUN_HART
#define RUN_HART 0
#endif
int main(uint64_t hartid) {
  if (hartid != RUN_HART) for (;;) __asm__ volatile("wfi");
  puts_("WST start\n");
  wr(1);
  uint64_t t0 = cyc(); wr(2); uint64_t t1 = cyc();
  uint64_t s = rd(); uint64_t t2 = cyc();
  puts_("WST write x100 cycles/line "); putdec((t1 - t0) * 100 / LINES);
  puts_(" read x100 cycles/line "); putdec((t2 - t1) * 100 / LINES);
  puts_(" sum "); putdec(s); puts_("\n");
  puts_("TANAGER-BOOT-OK\n");
  for (;;) __asm__ volatile("wfi");
}
