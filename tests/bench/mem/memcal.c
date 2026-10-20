/* memcal: the memory system's streaming rates and latency, bare-metal on one hart, so the same binary measures
   tb_boot's DDR model and the board's DDR alike (docs/spec/verification.md §4.7, follow-up 14). Each test prints
   "MEMCAL <test> bytes=N cycles=C" on the UART (rdcycle around the timed loop; bytes per cycle = N / C); the run
   ends with MEMCAL-END. memset is the kernel's loop shape (32 sd per 256 B); memcpy moves 8 bytes a load/store pair,
   eight pairs per 64 B. The 16 MiB and 8 MiB buffers are 16 and 8 times the 1 MiB L2, so they stream through DDR;
   the 1 MiB ones sit largely in the L2, as tg-lbench's 1M tests do on the board. */
#include <stdint.h>

#ifndef BIG
#define BIG 1               /* the board can afford more: BIG=4 repeats the DDR tests four times */
#endif
#define UART ((volatile uint8_t *)0x10000000ul)
#define BUF_A ((uint64_t *)0x84000000ul)   /* 64 MiB above the image: clear of the program and its stack */
#define BUF_B ((uint64_t *)0x86000000ul)

static void putc_(char c) {
  while (!(UART[5] & 0x20)) {}   /* LSR.THRE: the board's 16550 at 115200 baud would drop bytes past its FIFO */
  UART[0] = (uint8_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void putu(uint64_t v) {
  char b[24];
  int n = 0;
  do b[n++] = (char)('0' + v % 10); while ((v /= 10) != 0);
  while (n) putc_(b[--n]);
}
static inline uint64_t cycles(void) {
  uint64_t c;
  __asm__ volatile("rdcycle %0" : "=r"(c));
  return c;
}
static void report(const char *test, uint64_t bytes, uint64_t c) {
  puts_("MEMCAL ");
  puts_(test);
  puts_(" bytes=");
  putu(bytes);
  puts_(" cycles=");
  putu(c);
  puts_("\n");
}

static void memset256(uint64_t *d, uint64_t v, uint64_t bytes) {   /* the kernel's memset loop: 32 sd per 256 B */
  for (uint64_t *e = d + bytes / 8; d < e; d += 32) {
    d[0] = v; d[1] = v; d[2] = v; d[3] = v; d[4] = v; d[5] = v; d[6] = v; d[7] = v;
    d[8] = v; d[9] = v; d[10] = v; d[11] = v; d[12] = v; d[13] = v; d[14] = v; d[15] = v;
    d[16] = v; d[17] = v; d[18] = v; d[19] = v; d[20] = v; d[21] = v; d[22] = v; d[23] = v;
    d[24] = v; d[25] = v; d[26] = v; d[27] = v; d[28] = v; d[29] = v; d[30] = v; d[31] = v;
    __asm__ volatile("" : : "r"(d) : "memory");
  }
}
static void memcpy64(uint64_t *d, const uint64_t *s, uint64_t bytes) {
  for (const uint64_t *e = s + bytes / 8; s < e; s += 8, d += 8) {
    uint64_t a0 = s[0], a1 = s[1], a2 = s[2], a3 = s[3], a4 = s[4], a5 = s[5], a6 = s[6], a7 = s[7];
    d[0] = a0; d[1] = a1; d[2] = a2; d[3] = a3; d[4] = a4; d[5] = a5; d[6] = a6; d[7] = a7;
    __asm__ volatile("" : : "r"(d) : "memory");
  }
}
static uint64_t readsum(const uint64_t *s, uint64_t bytes) {
  uint64_t x = 0;
  for (const uint64_t *e = s + bytes / 8; s < e; s += 8) x += s[0] ^ s[4];   /* two loads a line */
  return x;
}

static void t_memset(const char *name, uint64_t size, uint64_t iters) {
  memset256(BUF_A, 0, size);                     /* untimed: the pages exist and the pattern is known */
  uint64_t c0 = cycles();
  for (uint64_t i = 0; i < iters; i++) memset256(BUF_A, i * 0x0101010101010101ull, size);
  report(name, size * iters, cycles() - c0);
}
static void t_memcpy(const char *name, uint64_t size, uint64_t iters) {
  memset256(BUF_A, 0x5a5a5a5a5a5a5a5aull, size);
  uint64_t c0 = cycles();
  for (uint64_t i = 0; i < iters; i++) memcpy64(BUF_B, BUF_A, size);
  report(name, size * iters, cycles() - c0);
}

int main(void) {
  puts_("MEMCAL-BEGIN\n");
  t_memset("memset-16M", 16u << 20, BIG);
  t_memcpy("memcpy-8M", 8u << 20, BIG);
  t_memset("memset-1M", 1u << 20, 8 * BIG);
  t_memcpy("memcpy-1M", 1u << 20, 8 * BIG);
  /* a streaming read of 8 MiB, after a pass that evicts it from the L2 */
  memset256(BUF_B, 1, 8u << 20);
  uint64_t c0 = cycles();
  uint64_t x = readsum(BUF_A, 8u << 20);
  report("read-8M", 8u << 20, cycles() - c0);
  /* latency: a dependent chase over 4 MiB, one line in 64 visited in a fixed scattered order */
  uint64_t lines = (4u << 20) / 64, step = 4099;          /* coprime with 65,536: one cycle through every line */
  uint64_t *base = BUF_B;
  for (uint64_t i = 0, j = 0; i < lines; i++, j = (j + step) % lines) base[j * 8] = (uint64_t)&base[((j + step) % lines) * 8];
  memset256(BUF_A, 2, 8u << 20);                          /* evict the chain from the L2 */
  uint64_t *p = base, n = 20000 * BIG;
  c0 = cycles();
  for (uint64_t i = 0; i < n; i++) p = (uint64_t *)*p;
  uint64_t c = cycles() - c0;
  report("chase-4M", n, c);                               /* bytes= is the number of dependent loads here */
  puts_(x == 0x1234 && p == 0 ? "" : "MEMCAL-END\n");     /* keep x and p live */
  return 0;
}
