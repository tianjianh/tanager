/* SoC integration test, run by tg_tcore cores inside tanager_soc (tests/unit/soc, KIND=tcore).
 * Exercises: boot ROM hand-off (a0, a1), host control, the 16550 console, ACLINT mtime/mtimecmp,
 * the L2 (a region larger than the test L2, so lines are evicted and refetched), coherence between
 * two harts without atomics (flags and data handed over through the caches), and TOHOST.
 * Pass: TOHOST = 1; failure: TOHOST = (code << 1) | 1. With one hart (the one-core KV260 bitstream's
 * first light, fpga/kv260/README.md) the coherence part is skipped. */
#include <stdint.h>

#define UART      ((volatile uint8_t *)0x10000000ul)
#define HOSTCTL   0x10001000ul
#define ACLINT    0x02000000ul
#define REG64(a)  (*(volatile uint64_t *)(a))

static void putc_(char c) {
  while (!(UART[5] & 0x20)) { }      /* LSR.THRE */
  UART[0] = (uint8_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint64_t v) {
  for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}
static void tohost(uint64_t v) { REG64(HOSTCTL + 0x28) = v; }
static void fail(int code) { puts_("FAIL "); puthex((uint64_t)code); puts_("\n"); tohost(((uint64_t)code << 1) | 1); for (;;) { } }

/* Shared between harts: each on its own cache line, zero in the loaded image (.data, not .bss) */
volatile uint64_t flag0 __attribute__((aligned(64), section(".data"))) = 0;
volatile uint64_t flag1 __attribute__((aligned(64), section(".data"))) = 0;
volatile uint64_t alive1 __attribute__((aligned(64), section(".data"))) = 0;
volatile uint64_t mailbox[16] __attribute__((aligned(64), section(".data"))) = { 0 };

static uint64_t region[8192] __attribute__((aligned(64)));   /* 64 KiB, larger than the test L2 */

static uint64_t mix(uint64_t x) { x ^= x >> 33; x *= 0xff51afd7ed558ccdull; x ^= x >> 29; return x; }

int main(uint64_t hartid, uint64_t dtb) {
  if (hartid == 0) {
    puts_("tanager soc test: hart 0, dtb ");
    puthex(dtb);
    puts_("\n");
    if (dtb != REG64(HOSTCTL + 0x10)) fail(1);
    if (REG64(HOSTCTL + 0x00) != 0x4C54434852544E47ull) fail(2);

    /* ACLINT: mtime advances; mtimecmp of hart 0 reads back */
    uint64_t t0 = REG64(ACLINT + 0xBFF8);
    for (volatile int i = 0; i < 200; i++) { }
    uint64_t t1 = REG64(ACLINT + 0xBFF8);
    if (t1 <= t0) fail(3);
    REG64(ACLINT + 0x4000) = t1 + 1000;
    if (REG64(ACLINT + 0x4000) != t1 + 1000) fail(4);
    puts_("aclint ok\n");

    /* L2: fill a region larger than the L2, then check it twice */
    for (int i = 0; i < 8192; i++) region[i] = mix((uint64_t)i ^ 0x1234);
    for (int pass = 0; pass < 2; pass++)
      for (int i = 0; i < 8192; i++)
        if (region[i] != mix((uint64_t)i ^ 0x1234)) fail(0x100 + pass);
    puts_("memory ok\n");

    /* Coherence: hand data to hart 1 and get its answer back (no atomics: flags in memory). Hart 1
     * announces itself as it starts; with one hart, give up after 1 ms of mtime (10 MHz). */
    uint64_t t2 = REG64(ACLINT + 0xBFF8);
    while (!alive1 && REG64(ACLINT + 0xBFF8) - t2 < 10000) { }
    if (alive1) {
      for (int i = 0; i < 16; i++) mailbox[i] = 0xA000 + (uint64_t)i;
      flag0 = 1;
      while (flag1 != 1) { }
      for (int i = 0; i < 16; i++) if (mailbox[i] != 0xB000 + (uint64_t)i) fail(0x200 + i);
      puts_("coherence ok\n");
    } else {
      puts_("one hart: coherence skipped\n");
    }
    puts_("PASS\n");
    tohost(1);
  } else {
    alive1 = 1;
    while (flag0 != 1) { }
    for (int i = 0; i < 16; i++) {
      if (mailbox[i] != 0xA000 + (uint64_t)i) fail(0x300 + i);
      mailbox[i] = 0xB000 + (uint64_t)i;
    }
    flag1 = 1;
  }
  for (;;) { }
}
