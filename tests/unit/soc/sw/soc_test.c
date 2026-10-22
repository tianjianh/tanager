/* SoC integration test, run by tg_tcore cores inside tanager_soc (tests/unit/soc, KIND=tcore).
 * Exercises: boot ROM hand-off (a0, a1), host control, the 16550 console, ACLINT mtime/mtimecmp,
 * the L2 (a region larger than the test L2, so lines are evicted and refetched), coherence between
 * two harts without atomics (flags and data handed over through the caches), and TOHOST. FROMHOST
 * = 0x7467_0000 | flags selects more (tb_soc): bit 0 the forwarded virtio window (VIRTIO=1: reads the
 * host answers, and a QueueNotify whose answer is an interrupt through the PLIC, claimed and
 * acknowledged); bit 1 the host DMA port (HOST_DMA=1: the host reads a buffer still dirty in this
 * hart's data cache, and writes one it holds copies of, both of which must be coherent); bit 2 the PS
 * window (PS_WINDOW=1, stage D's D1: accesses of every size through tb_soc's model of the PS, the
 * accesses the window must deny without a transaction, an error response, a timeout and the recovery
 * after it, and a PS interrupt through the PLIC; start.S records the access faults; then the board's reset,
 * CRL_APB RESET_CTRL, denied until the doorbell has the host set BOARD_CTRL[1], then that word alone passing;
 * after TOHOST, once the host says so, reads of the window nonstop for tb_soc's PMOD reset hook test); bit 3 a
 * release build (RELEASE=1, DR-180: the PLIC's M contexts empty and 1-bit priorities, the UART's interrupt claimed
 * on hart 0's S context; with the PS window, TTC1's line no source and UART1's claimed on the S context instead).
 * Pass: TOHOST = 1; failure: TOHOST = (code << 1) | 1. With one hart (the one-core KV260 bitstream's
 * first light, fpga/kv260/README.md) the coherence part is skipped. */
#include <stdint.h>

#define UART      ((volatile uint8_t *)0x10000000ul)
#define HOSTCTL   0x10001000ul
#define ACLINT    0x02000000ul
#define PLIC      0x0C000000ul
#define VIRTIO    0x10010000ul
/* The PS window (tb_soc's PS model, docs/spec/soc.md §8.2): byte registers, 0 until written, in UART1's
 * and USB0's apertures; TTC1's first register drives PLIC source 24; IOU_SLCR reads byte a as a ^ 0x5A;
 * SD1 + 0x100 answers SLVERR; GEM3 + 0x200 answers only after the window's 2^16-cycle timeout */
#define PS_SCR    0xFF010000ul
#define PS_USB    0xFE200000ul
#define PS_TTC1   0xFF120000ul
#define PS_SLCR   0xFF180000ul
#define PS_ERR    0xFF170100ul
#define PS_LATE   0xFF0E0200ul
#define PS_RST    0xFF5E0218ul                 /* CRL_APB RESET_CTRL: the board's reset (the model resets nothing) */
#define PS_U1IRQ  0xFF010040ul                 /* the PS model: bit 0 written is UART1's line, PLIC source 20 */
#define IRQ_UART  10
#define IRQ_UART1 20
#define IRQ_TTC1  24
#define P_EN(c)   (PLIC + 0x2000ul + 0x80ul * (c))      /* context c's enables, threshold, claim and complete */
#define P_THR(c)  (PLIC + 0x200000ul + 0x1000ul * (c))
#define P_CLAIM(c) (P_THR(c) + 4)
#define REG64(a)  (*(volatile uint64_t *)(a))
#define REG32(a)  (*(volatile uint32_t *)(a))
#define REG16(a)  (*(volatile uint16_t *)(a))
#define REG8(a)   (*(volatile uint8_t *)(a))

static void putc_(char c) {
  while (!(UART[5] & 0x20)) { }      /* LSR.THRE */
  UART[0] = (uint8_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint64_t v) {
  for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}
static void tohost(uint64_t v) { REG64(HOSTCTL + 0x28) = v; }

extern volatile uint64_t trap_save[4];          /* start.S: t1 (saved), mcause, mtval, count */
static void fail(int code) { puts_("FAIL "); puthex((uint64_t)code); puts_("\n"); tohost(((uint64_t)code << 1) | 1); for (;;) { } }

/* Shared between harts: each on its own cache line, zero in the loaded image (.data, not .bss) */
volatile uint64_t flag0 __attribute__((aligned(64), section(".data"))) = 0;
volatile uint64_t flag1 __attribute__((aligned(64), section(".data"))) = 0;
volatile uint64_t alive1 __attribute__((aligned(64), section(".data"))) = 0;
volatile uint64_t mailbox[16] __attribute__((aligned(64), section(".data"))) = { 0 };

static uint64_t region[8192] __attribute__((aligned(64)));   /* 64 KiB, larger than the test L2 */

static uint64_t mix(uint64_t x) { x ^= x >> 33; x *= 0xff51afd7ed558ccdull; x ^= x >> 29; return x; }

/* The host DMA port's buffers: fixed addresses in RAM above the program (tb_soc knows them) */
#define DMA_A ((volatile uint64_t *)0x80100000ul)   /* written here, read by the host */
#define DMA_B ((volatile uint64_t *)0x80101000ul)   /* read here, written by the host, read again */

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

    uint64_t fh = REG64(HOSTCTL + 0x30);
    int rel = (fh >> 16) == 0x7467 && (fh & 8);

    /* A release build's PLIC (DR-180): context 0, hart 0's M-mode, holds nothing; priorities and thresholds keep
     * bit 0; hart 0's S context (1) takes the UART's transmit interrupt, claimed and completed */
    if (rel) {
      REG32(PLIC + 4 * IRQ_UART) = 7;
      if (REG32(PLIC + 4 * IRQ_UART) != 1) fail(0x700);
      REG32(P_EN(0)) = 0xFFFFFFFEu;
      REG32(P_THR(0)) = 1;
      if (REG32(P_EN(0)) != 0 || REG32(P_THR(0)) != 0) fail(0x701);
      REG32(P_EN(1)) = 1u << IRQ_UART;
      REG32(P_THR(1)) = 7;
      if (REG32(P_EN(1)) != 1u << IRQ_UART || REG32(P_THR(1)) != 1) fail(0x702);
      UART[1] = 0x02;                                /* IER: the transmitter-empty interrupt */
      for (volatile int i = 0; i < 50; i++) { }
      if (REG32(PLIC + 0x1000) & (1u << IRQ_UART)) {
        if (REG32(P_CLAIM(1)) != 0) fail(0x703);     /* pending, but under the threshold */
      }
      REG32(P_THR(1)) = 0;
      while (!(REG32(PLIC + 0x1000) & (1u << IRQ_UART))) { }
      if (REG32(P_CLAIM(0)) != 0) fail(0x704);       /* no claim through an M context */
      if (REG32(P_CLAIM(1)) != IRQ_UART) fail(0x705);
      UART[1] = 0x00;                                /* the line drops */
      for (volatile int i = 0; i < 50; i++) { }
      REG32(P_CLAIM(1)) = IRQ_UART;                  /* complete */
      if (REG32(PLIC + 0x1000) & (1u << IRQ_UART)) fail(0x706);
      REG32(P_EN(1)) = 0;
      puts_("release plic ok\n");
    }

    /* The forwarded virtio window (docs/spec/soc.md §8.1): the host answers a read with "virt" at
     * offset 0, else (slot << 16) | offset; a QueueNotify of slot 3 makes it set the slot's used-buffer
     * bit, PLIC source 4. InterruptStatus and InterruptACK are answered in the uncore. */
    if ((fh >> 16) == 0x7467 && (fh & 1)) {
      if (REG32(VIRTIO + 0x000) != 0x74726976) fail(0x400);
      if (REG32(VIRTIO + 0x1008) != 0x00010008) fail(0x401);
      if (REG8(VIRTIO + 0x2101) != 0x01) fail(0x402);
      if (REG16(VIRTIO + 0x2102) != 0x0102) fail(0x403);
      REG32(PLIC + 4 * 4) = 1;                       /* source 4: priority 1 */
      REG32(PLIC + 0x2000) = 1u << 4;                /* enabled for context 0, hart 0's M-mode */
      REG32(PLIC + 0x200000) = 0;                    /* threshold */
      if (REG32(PLIC + 0x1000) & (1u << 4)) fail(0x404);
      if (REG32(VIRTIO + 0x3060) != 0) fail(0x405);
      REG32(VIRTIO + 0x3050) = 0;                    /* QueueNotify, queue 0 */
      while (!(REG32(PLIC + 0x1000) & (1u << 4))) { }
      if (REG32(PLIC + 0x200004) != 4) fail(0x406);  /* claim */
      if (REG32(VIRTIO + 0x3060) != 1) fail(0x407);  /* InterruptStatus: used buffer */
      REG32(VIRTIO + 0x3064) = 1;                    /* InterruptACK */
      REG32(PLIC + 0x200004) = 4;                    /* complete */
      if (REG32(VIRTIO + 0x3060) != 0) fail(0x408);
      if (REG32(PLIC + 0x1000) & (1u << 4)) fail(0x409);
      puts_("virtio ok\n");
    }

    /* The host DMA port (docs/spec/soc.md §8.1): DMA_A is left dirty in this hart's cache for the host
     * to read; DMA_B is cached here, then the host overwrites it. The doorbell hands over, MBOX_OUT
     * answers. Coherence: the host reads the dirty bytes, and this hart then reads the host's. */
    if ((fh >> 16) == 0x7467 && (fh & 2)) {
      uint64_t sum = 0;
      REG64(HOSTCTL + 0x40) = 1;                       /* MBOX_PENDING: clear the earlier test's */
      for (int i = 0; i < 64; i++) DMA_A[i] = mix((uint64_t)i ^ 0xA5);
      for (int i = 0; i < 64; i++) sum += DMA_B[i];    /* copies of DMA_B in the cache */
      mailbox[15] = sum;
      REG64(HOSTCTL + 0x38) = 1;                       /* DOORBELL: the host's turn */
      while (!(REG64(HOSTCTL + 0x40) & 1)) { }         /* MBOX_OUT: the host is done */
      REG64(HOSTCTL + 0x40) = 1;
      for (int i = 0; i < 64; i++) if (DMA_B[i] != mix((uint64_t)i ^ 0xB6)) fail(0x510 + i);
      puts_("dma ok\n");
    }

    /* The PS window (docs/spec/soc.md §8.2, stage D's D1), against tb_soc's model of the PS */
    if ((fh >> 16) == 0x7467 && (fh & 4)) {
      uint64_t n;
      /* every access size, each half of the 128-bit beat */
      REG64(PS_SCR + 0x00) = 0x0123456789ABCDEFull;
      if (REG64(PS_SCR + 0x00) != 0x0123456789ABCDEFull) fail(0x600);
      REG32(PS_SCR + 0x0C) = 0xCAFEF00Du;
      if (REG32(PS_SCR + 0x0C) != 0xCAFEF00Du) fail(0x601);
      REG16(PS_SCR + 0x12) = 0xBEEF;
      REG8(PS_SCR + 0x15) = 0x7A;
      if (REG64(PS_SCR + 0x10) != 0x00007A00BEEF0000ull) fail(0x602);
      REG64(PS_USB + 0x08) = 0x1122334455667788ull;
      if (REG64(PS_USB + 0x08) != 0x1122334455667788ull) fail(0x603);
      if (REG32(PS_SLCR + 0x40) != 0x19181B1Au) fail(0x604);
      /* denied in the window, no transaction: TTC0 (the fan's), a write to IOU_SLCR, an address outside
       * the apertures; each an access fault with the address in mtval */
      n = trap_save[3];
      (void)REG32(0xFF110000ul);
      if (trap_save[3] != n + 1 || trap_save[1] != 5 || trap_save[2] != 0xFF110000ul) fail(0x610);
      REG32(PS_SLCR + 0x40) = 1;
      if (trap_save[3] != n + 2 || trap_save[1] != 7 || trap_save[2] != PS_SLCR + 0x40) fail(0x611);
      (void)REG32(0xFFFF0000ul);
      if (trap_save[3] != n + 3 || trap_save[1] != 5 || trap_save[2] != 0xFFFF0000ul) fail(0x612);
      /* an error response */
      (void)REG32(PS_ERR);
      if (trap_save[3] != n + 4 || trap_save[1] != 5 || trap_save[2] != PS_ERR) fail(0x613);
      /* no response: the window times out, denies while the late response is outstanding, then works */
      (void)REG32(PS_LATE);
      if (trap_save[3] != n + 5 || trap_save[1] != 5 || trap_save[2] != PS_LATE) fail(0x614);
      uint64_t v = 0, tries = 0;
      do { n = trap_save[3]; v = REG64(PS_SCR + 0x00); tries++; } while (trap_save[3] != n && tries < 100000);
      if (trap_save[3] != n || v != 0x0123456789ABCDEFull) fail(0x615);
      if (!rel) {
        /* a PS interrupt (TTC1's line) through the PLIC */
        REG32(PLIC + 4 * IRQ_TTC1) = 1;              /* priority 1 */
        REG32(PLIC + 0x2000) = 1u << IRQ_TTC1;       /* enabled for context 0, hart 0's M-mode */
        REG32(PLIC + 0x200000) = 0;                  /* threshold */
        if (REG32(PLIC + 0x1000) & (1u << IRQ_TTC1)) fail(0x620);
        REG32(PS_TTC1) = 1;                          /* the model raises the line */
        while (!(REG32(PLIC + 0x1000) & (1u << IRQ_TTC1))) { }
        if (REG32(PLIC + 0x200004) != IRQ_TTC1) fail(0x621);   /* claim */
        REG32(PS_TTC1) = 0;                          /* and lowers it */
        for (volatile int i = 0; i < 50; i++) { }    /* through the synchronizer */
        REG32(PLIC + 0x200004) = IRQ_TTC1;           /* complete */
        if (REG32(PLIC + 0x1000) & (1u << IRQ_TTC1)) fail(0x622);
      } else {
        /* a release build: TTC1's line is no source; UART1's is, claimed on hart 0's S context */
        REG32(PLIC + 4 * IRQ_TTC1) = 1;
        REG32(PS_TTC1) = 1;
        for (volatile int i = 0; i < 200; i++) { }
        if (REG32(PLIC + 0x1000) & (1u << IRQ_TTC1)) fail(0x640);
        REG32(PS_TTC1) = 0;
        REG32(PLIC + 4 * IRQ_UART1) = 1;
        REG32(P_EN(1)) = 1u << IRQ_UART1;
        REG32(P_THR(1)) = 0;
        if (REG32(PLIC + 0x1000) & (1u << IRQ_UART1)) fail(0x641);
        REG32(PS_U1IRQ) = 1;
        while (!(REG32(PLIC + 0x1000) & (1u << IRQ_UART1))) { }
        if (REG32(P_CLAIM(1)) != IRQ_UART1) fail(0x642);
        REG32(PS_U1IRQ) = 0;
        for (volatile int i = 0; i < 50; i++) { }
        REG32(P_CLAIM(1)) = IRQ_UART1;
        if (REG32(PLIC + 0x1000) & (1u << IRQ_UART1)) fail(0x643);
        REG32(P_EN(1)) = 0;
      }
      /* the board's reset (docs/spec/soc-d4-modes.md): RESET_CTRL, denied while the host's BOARD_CTRL[1] is
       * clear; with it set, that word alone passes */
      n = trap_save[3];
      REG32(PS_RST) = 0x10;
      if (trap_save[3] != n + 1 || trap_save[1] != 7 || trap_save[2] != PS_RST) fail(0x630);
      REG64(HOSTCTL + 0x40) = 1;                       /* MBOX_PENDING: clear the earlier tests' */
      REG64(HOSTCTL + 0x38) = 1;                       /* DOORBELL: the host sets BOARD_CTRL[1] */
      while (!(REG64(HOSTCTL + 0x40) & 1)) { }         /* MBOX_OUT: it has */
      REG64(HOSTCTL + 0x40) = 1;
      REG32(PS_RST) = 0x10;
      if (trap_save[3] != n + 1) fail(0x631);
      if (REG32(PS_RST) != 0x10) fail(0x632);
      (void)REG64(PS_RST);                             /* a doubleword reaches the next register: denied */
      if (trap_save[3] != n + 2 || trap_save[1] != 5 || trap_save[2] != PS_RST) fail(0x633);
      (void)REG32(PS_RST + 4);                         /* the rest of CRL_APB: denied */
      if (trap_save[3] != n + 3 || trap_save[1] != 5 || trap_save[2] != PS_RST + 4) fail(0x634);
      REG32(PS_RST - 0x18) = 1;                        /* BOOT_MODE_USER */
      if (trap_save[3] != n + 4 || trap_save[1] != 7 || trap_save[2] != PS_RST - 0x18) fail(0x635);
      puts_("ps window ok, ");
      puthex(tries);
      puts_(" tries after the timeout\n");
    }

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
    if ((fh >> 16) == 0x7467 && (fh & 4)) {
      /* tb_soc's PMOD reset hook test: once the host says so, read the window nonstop, as a hart stuck polling a
       * PS register would. The hook's write still goes out; the reads it meets are denied (faults, skipped) */
      while (!(REG64(HOSTCTL + 0x40) & 1)) { }
      REG64(HOSTCTL + 0x40) = 1;
      for (;;) (void)REG32(PS_SCR + 0x08);
    }
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
