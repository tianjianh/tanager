/* SD1's lost interrupt (the board's s19b boot 1, 10-20), in simulation: tb_soc's PS model with SDIRQ = 1 has an
 * SD-like device at SD1's address, and this program does with it what Linux's sdhci and PLIC drivers do, while
 * the other core contends on the device bus as the boot's udev reads did. Every request must complete.
 *   Hart 0 (core 0), Linux's CPU0: N_REQ requests one at a time. A request is a write to the model's command
 *     register; the model then sets status bit 0 (command complete) and later bit 1 (transfer complete), each
 *     after a random delay, some short enough to land inside the handler. The interrupt is taken as Linux takes
 *     it: a trap on the external interrupt, then claim; for source 21, sdhci_irq's loop (read the status, write
 *     the bits read back to clear them, read again, while any is set; bit 1 completes the request); then
 *     6.12.113's plic_irq_eoi (read the context's enable bit; if set, complete; if not, enable, complete,
 *     disable), and claim again until 0.
 *     Half the requests are writes: hart 0 first fills the buffer (dirty in its cache), and the model reads it
 *     through the host DMA port before transfer complete, as SD1's ADMA reads a write's data. Two more sources
 *     interrupt hart 0 meanwhile, as ttyS0 and the PS's other devices do around a shutdown: the PL UART (source
 *     10), whose transmit interrupts hart 0 drives as Linux's 8250 does (a queue of characters, THRE), and TTC1
 *     (source 24) in the PS model, which the contender raises and hart 0's handler clears.
 *   Hart CONT_HART (core 1's first: 1 in st, 2 in smt2), Linux's CPU1: until hart 0 is done, at random: PS window
 *     writes and reads (a scratch register of the model: CPU1 submitting the next request), read-modify-writes of
 *     hart 0's enable word for source 23 (request_irq and free_irq on CPU1; USB0's line, idle here), priority
 *     writes of sources 20 and 23 (mask and unmask; 20's shares an 8-byte word with 21's), PLIC reads, GEM3
 *     register polls (as macb's MDIO accesses at its probe and close), and TTC1's line raised. Any other hart
 *     sleeps in WFI, as the board's idle threads.
 *   SMODE = 0: hart 0 in M-mode on context 0. SMODE = 1 (sd_irq_smt2s.bin, the real cores only): as Linux, in
 *     S-mode on context 1 (hart 0's S-mode) with SEI delegated, plus timer ticks on Sstc's stimecmp at random.
 *     With SMODE, the contender also sends hart 0 IPIs as Linux does through OpenSBI: hart 0's MSIP in the
 *     ACLINT, an M-mode software interrupt, which preempts S-mode even inside the handler (SIE off), as an IPI
 *     preempts plic_handle_irq; hart 0's M-mode handler clears MSIP and returns, as OpenSBI's does.
 *     SMODE = 2 (sd_irq_smt2v.bin): the same under Sv39, as Linux's ioremap has it: identity mappings, 2 MiB
 *     pages for the PLIC and the PS window (each inside its region, so the core decides their accesses with
 *     the DTLB's cached PMP result), the rest of the first GiB in 2 MiB pages, RAM in a 1 GiB page.
 * A request not done in TIMEOUT ticks (10 MHz) fails with the PLIC's view of source 21; an enable read with
 * bit 21 clear fails too (the second candidate). TOHOST = 1 on success, else (code << 1) | 1. On a release build
 * (FROMHOST bit 3, tb_soc RELEASE, DR-180) TTC1's line is no PLIC source: the end check then wants no TTC1 interrupt.
 * Registers: the PS model's SD device (tests/unit/soc/tb_soc.sv, SDIRQ): status 0x30 (write 1 to clear), signal
 * enable 0x38, command 0x40 (the model's own), scratch 0x44. */
#include <stdint.h>

#ifndef CONT_HART
#define CONT_HART 1
#endif
#ifndef SMODE
#define SMODE     0
#endif

#define UART      ((volatile uint8_t *)0x10000000ul)
#define HOSTCTL   0x10001000ul
#define ACLINT    0x02000000ul
#define PLIC      0x0C000000ul
#define REG32(a)  (*(volatile uint32_t *)(a))
#define REG64(a)  (*(volatile uint64_t *)(a))

#define SD1       0xFF170000ul
#define SD_ST     0x30
#define SD_SIG    0x38
#define SD_CMD    0x40
#define SD_SCR    0x44
#define IRQ_SD1   21
#define IRQ_IDLE  23
#define IRQ_UART  10
#define IRQ_TTC1  24
#define IRQ_PSU1  20                            /* UART1's line, idle here: its priority shares 21's word */
#define PS_TTC1   0xFF120000ul                  /* the PS model: bit 0 written is TTC1's line */
#define PS_GEM3   0xFF0E0000ul                  /* GEM3: a maintenance write and status polls, as an MDIO access */
#define N_REQ     1500
#define TIMEOUT   20000ul                       /* 2 ms at 10 MHz: hundreds of times a request's longest delays */

#define CTX       (SMODE != 0)                  /* context 0: hart 0's M-mode; 1: its S-mode */
#define P_PRIO(s) (PLIC + 4ul * (s))
#define P_PEND    (PLIC + 0x1000ul)
#define P_EN      (PLIC + 0x2000ul + 0x80ul * CTX)
#define P_THR     (PLIC + 0x200000ul + 0x1000ul * CTX)
#define P_CLAIM   (P_THR + 4)

#define CSRR(c)    ({ uint64_t v_; __asm__ volatile("csrr %0, " #c : "=r"(v_)); v_; })
#define CSRW(c, v) __asm__ volatile("csrw " #c ", %0" :: "r"((uint64_t)(v)))
#define CSRS(c, v) __asm__ volatile("csrs " #c ", %0" :: "r"((uint64_t)(v)))
#define CSRC(c, v) __asm__ volatile("csrc " #c ", %0" :: "r"((uint64_t)(v)))
#if SMODE
#define IRQS_OFF() CSRC(sstatus, 1ul << 1)
#define IRQS_ON()  CSRS(sstatus, 1ul << 1)
#else
#define IRQS_OFF() CSRC(mstatus, 1ul << 3)
#define IRQS_ON()  CSRS(mstatus, 1ul << 3)
#endif

/* In .data, so the binary sets them: start.S doesn't clear .bss, and the memory model's unwritten words are not 0 */
#define DATA __attribute__((section(".data")))
static volatile uint32_t done_cnt DATA, irqs DATA, spurious DATA, other_irq DATA, loops_max DATA, en_lost DATA;
static volatile uint32_t en_seen DATA, ticks DATA, go1 DATA, stop1 DATA, ops1[8] DATA;
static volatile uint32_t uart_irqs DATA, ttc_irqs DATA, ttc_spur DATA, writes DATA, ipis DATA;
static volatile char txq[256] DATA;             /* the 8250's transmit queue: hart 0 only */
static volatile uint32_t tx_head DATA, tx_tail DATA;

static void putc_(char c) {
  while (!(UART[5] & 0x20)) { }
  UART[0] = (uint8_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint64_t v, int digits) {
  for (int i = 4 * (digits - 1); i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}
static void tohost(uint64_t v) { REG64(HOSTCTL + 0x28) = v; }
static uint64_t now(void) { return REG64(ACLINT + 0xBFF8); }   /* 10 MHz */
static uint64_t rnd_s[3] = {0x9E3779B97F4A7C15ull, 0xD1B54A32D192ED03ull, 0x8CB92BA72F3D8DD7ull};
static uint32_t rnd(int k) {                    /* xorshift64: 0 hart 0's loop, 1 the contender, 2 the handler */
  uint64_t x = rnd_s[k];
  x ^= x << 13; x ^= x >> 7; x ^= x << 17;
  rnd_s[k] = x;
  return (uint32_t)(x >> 16);
}

static void dump_plic(void) {
  puts_("  PLIC pending "); puthex(REG32(P_PEND), 8);
  puts_(" enable(ctx "); puthex(CTX, 1); puts_(") "); puthex(REG32(P_EN), 8);
  puts_(" prio21 "); puthex(REG32(P_PRIO(IRQ_SD1)), 8);
  puts_(" thr "); puthex(REG32(P_THR), 8);
  puts_(" SD status "); puthex(REG32(SD1 + SD_ST), 8);
  puts_(" sig "); puthex(REG32(SD1 + SD_SIG), 8); puts_("\n");
}
static void fail(int code) {
  stop1 = 1;
  puts_("FAIL "); puthex((uint64_t)code, 4); puts_(" after "); puthex(done_cnt, 4); puts_(" requests\n");
  dump_plic();
  tohost(((uint64_t)code << 1) | 1);
  for (;;) { }
}

#if SMODE == 2
/* Sv39: the root (1 GiB entries), the first GiB's 2 MiB entries, the fourth GiB's (the PS window) */
static uint64_t pt_root[512] __attribute__((aligned(4096))) DATA;
static uint64_t pt_g0[512] __attribute__((aligned(4096))) DATA;
static uint64_t pt_g3[512] __attribute__((aligned(4096))) DATA;
#define PTE_PTR(t) ((((uint64_t)(t)) >> 12 << 10) | 0x01)
#define PTE_RW(pa) ((((uint64_t)(pa)) >> 12 << 10) | 0xC7)        /* D A W R V */
#define PTE_RWX(pa) ((((uint64_t)(pa)) >> 12 << 10) | 0xCF)       /* D A X W R V */
static void sv39(void) {
  for (uint64_t i = 0; i < 512; i++) pt_g0[i] = PTE_RW(i << 21);              /* the first GiB: devices */
  pt_g3[(0xFF000000ul - 0xC0000000ul) >> 21] = PTE_RW(0xFF000000ul);          /* SD1's 2 MiB of the PS window */
  pt_root[0] = PTE_PTR(pt_g0);
  pt_root[2] = PTE_RWX(0x80000000ul);                                        /* RAM */
  pt_root[3] = PTE_PTR(pt_g3);
  CSRW(satp, (8ull << 60) | ((uint64_t)pt_root >> 12));
  __asm__ volatile("sfence.vma" ::: "memory");
}
#endif

static void toggle(int src, int on) {            /* plic_toggle on hart 0's context */
  uint32_t w = REG32(P_EN);
  REG32(P_EN) = on ? (w | (1u << src)) : (w & ~(1u << src));
}

/* The PL UART's transmit as Linux's 8250 drives it: a queue; when the transmitter is empty, a few characters
 * into THR (4 here, so a line takes several THRE interrupts); THRE's interrupt (IER bit 1) while the queue isn't
 * empty. tx_kick runs in the handler or with hart 0's interrupts off */
static void tx_kick(void) {
  if (UART[5] & 0x20)
    for (int n = 0; n < 4 && tx_tail != tx_head; n++) UART[0] = (uint8_t)txq[tx_tail++ & 255];
  UART[1] = (tx_tail != tx_head) ? 0x02 : 0x00;
}
static void tx_queue(const char *t) {             /* hart 0, interrupts off: a line, then one kick */
  for (; *t; t++) if (tx_head - tx_tail < 255) txq[tx_head++ & 255] = *t;
  if (!(UART[1] & 0x02)) tx_kick();
}

#if SMODE
/* OpenSBI's IPI path on hart 0: an M-mode software interrupt, taken whatever S-mode is doing; MSIP down, back */
__attribute__((interrupt("machine"))) void m_entry(void) {
  if (CSRR(mcause) != ((1ull << 63) | 3)) fail(0x03);
  REG32(ACLINT + 0) = 0;
  ipis++;
}
#endif

/* Linux's plic_handle_irq with sdhci_irq and 6.12.113's plic_irq_eoi; with SMODE, Linux's timer tick too */
#if SMODE
__attribute__((interrupt("supervisor"))) void irq_entry(void) {
  uint64_t cause = CSRR(scause);
  if (cause == ((1ull << 63) | 5)) {             /* the tick: the next one 5 to 105 us on */
    ticks++;
    CSRW(0x14D, CSRR(time) + 50 + (rnd(2) & 1023));
    return;
  }
  if (cause != ((1ull << 63) | 9)) fail(0x01);
#else
__attribute__((interrupt("machine"))) void irq_entry(void) {
  uint64_t cause = CSRR(mcause);
  if (cause != ((1ull << 63) | 11)) fail(0x01);
#endif
  uint32_t id;
  while ((id = REG32(P_CLAIM)) != 0) {
    irqs++;
    if (id == IRQ_SD1) {
      uint32_t st = REG32(SD1 + SD_ST), n = 0;
      if (!st) spurious++;
      while (st && n < 16) {
        REG32(SD1 + SD_ST) = st;
        if (st & 2) done_cnt++;
        st = REG32(SD1 + SD_ST);
        n++;
      }
      if (n > loops_max) loops_max = n;
    } else if (id == IRQ_UART) {
      uart_irqs++;
      (void)UART[2];                              /* IIR: clears THRE's interrupt when it reports it */
      tx_kick();
    } else if (id == IRQ_TTC1) {
      if (REG32(PS_TTC1) & 1) ttc_irqs++; else ttc_spur++;
      REG32(PS_TTC1) = 0;                         /* its line down */
    } else {
      other_irq++;
    }
    uint32_t en = REG32(P_EN);
    en_seen++;
    if (en & (1u << id)) {
      REG32(P_CLAIM) = id;
    } else {
      en_lost++;
      toggle((int)id, 1);
      REG32(P_CLAIM) = id;
      toggle((int)id, 0);
      fail(0x02);
    }
  }
}

static void contender(void) {
  while (!go1) { }
  while (!stop1) {
    uint32_t r = rnd(1);
    switch (r & 7) {
      case 0: REG32(SD1 + SD_SCR) = r; break;                            /* a PS window write */
      case 1: (void)REG32(SD1 + SD_SCR); break;                          /* a PS window read */
      case 2: toggle(IRQ_IDLE, 1); toggle(IRQ_IDLE, 0); break;           /* request_irq, free_irq */
      case 3: (void)REG32(P_PEND); break;                                /* a PLIC read */
      case 4: REG32(P_PRIO(IRQ_PSU1)) = 0; REG32(P_PRIO(IRQ_PSU1)) = 1; break;   /* mask, unmask: 21's word */
      case 5:
        if (r & 0x100) { REG32(P_PRIO(IRQ_IDLE)) = 0; REG32(P_PRIO(IRQ_IDLE)) = 1; }
        else {                                                           /* an MDIO access on GEM3 */
          REG32(PS_GEM3 + 0x34) = r;
          for (int n = 0; n < 6; n++) (void)REG32(PS_GEM3 + 0x08);
        }
        break;
      default:
        if (SMODE && (r & 0x200)) REG32(ACLINT + 0) = 1;                 /* an IPI to hart 0 (MSIP) */
        else REG32(PS_TTC1) = 1;                                         /* TTC1's event */
        break;
    }
    ops1[r & 7]++;
    for (uint32_t d = (r >> 8) & 31; d; d--) __asm__ volatile("nop");
  }
  for (;;) { }
}

/* With the host DMA port (FROMHOST bit 1: tb_soc HOST_DMA), each request's data arrives before its transfer
 * complete in buffer (request % 8) at 0x8020_0000 + 4 KiB * (request % 8); the first 128 bytes are always there */
static int dma_data(void) {
  uint64_t fh = REG64(HOSTCTL + 0x30);
  return (fh >> 16) == 0x7467 && (fh & 2);
}
/* A release build (FROMHOST bit 3: tb_soc RELEASE, DR-180): TTC1's line is no PLIC source, so it never interrupts */
static int release_build(void) {
  uint64_t fh = REG64(HOSTCTL + 0x30);
  return (fh >> 16) == 0x7467 && (fh & 8);
}
static uint64_t wword(uint32_t req, uint32_t k) {    /* a write's data, as tb_soc's sd_wword */
  return ((uint64_t)req * 0xC2B2AE3D27D4EB4Full) ^ k ^ 0x5A5A5A5A5A5A5A5Aull;
}
static void fill_data(uint32_t req) {             /* a write: the whole 512 bytes the model may read */
  volatile uint64_t *b = (volatile uint64_t *)(0x80200000ul + 4096ul * (req % 8));
  for (uint32_t k = 0; k < 64; k++) b[k] = wword(req, k);
}
static void check_data(uint32_t req) {
  volatile uint64_t *b = (volatile uint64_t *)(0x80200000ul + 4096ul * (req % 8));
  for (uint32_t k = 0; k < 16; k++)
    if (b[k] != (((uint64_t)req * 0x9E3779B97F4A7C15ull) ^ k)) {
      puts_("data: request "); puthex(req, 4); puts_(" word "); puthex(k, 2); puts_(" "); puthex(b[k], 16); puts_("\n");
      fail(0x30);
    }
}

static void requests(void) {                     /* hart 0, in M-mode or S-mode */
#if SMODE == 2
  sv39();
#endif
#if SMODE
  CSRW(0x14D, CSRR(time) + 100);
  CSRS(sstatus, 1ul << 1);
#else
  CSRS(mstatus, 1ul << 3);
#endif
  int dma = dma_data();
  if (dma) puts_("with data through the host DMA port\n");
  go1 = 1;
  for (uint32_t i = 0; i < N_REQ; i++) {
    uint32_t want = done_cnt + 1;
    int wr = dma && (rnd(0) & 1);
    if (wr) { fill_data(i); writes++; }
    if ((i & 7) == 0) {                           /* a line of output: ttyS0's transmit interrupts */
      char line[13] = " sd req ....";
      for (int k = 0; k < 4; k++) line[8 + k] = "0123456789abcdef"[(i >> (12 - 4 * k)) & 15];
      IRQS_OFF();
      tx_queue(line);
      IRQS_ON();
    }
    REG32(SD1 + SD_CMD) = i | ((uint32_t)wr << 31);
    uint64_t t0 = now();
    while (done_cnt < want) if (now() - t0 > TIMEOUT) fail(0x10);
    if (dma && !wr) check_data(i);
    for (uint32_t d = rnd(0) & 63; d; d--) __asm__ volatile("nop");
    if ((i & 255) == 255) { puts_("  "); puthex(i + 1, 4); puts_(" requests\n"); }
  }
  stop1 = 1;
  { uint64_t t0 = now(); while (tx_tail != tx_head) if (now() - t0 > TIMEOUT) fail(0x11); }
  IRQS_OFF();
  puts_("requests "); puthex(done_cnt, 4); puts_(", interrupts "); puthex(irqs, 4);
  puts_(", spurious "); puthex(spurious, 4); puts_(", others "); puthex(other_irq, 4);
  puts_(", most loops "); puthex(loops_max, 2); puts_(", enable reads "); puthex(en_seen, 4);
  puts_(", ticks "); puthex(ticks, 4); puts_("\n");
  puts_("writes "); puthex(writes, 4); puts_(", UART interrupts "); puthex(uart_irqs, 4);
  puts_(", TTC1 "); puthex(ttc_irqs, 4); puts_(" (spurious "); puthex(ttc_spur, 4); puts_("), IPIs "); puthex(ipis, 4);
  puts_("\n");
  puts_("contender: PS writes "); puthex(ops1[0], 4); puts_(", PS reads "); puthex(ops1[1], 4);
  puts_(", enable RMWs "); puthex(ops1[2], 4); puts_(", PLIC reads "); puthex(ops1[3], 4);
  puts_(", priority writes and GEM3 polls "); puthex(ops1[4] + ops1[5], 4); puts_(", TTC1 events "); puthex(ops1[6] + ops1[7], 4);
  puts_("\n");
  if (done_cnt != N_REQ || other_irq || en_lost || (SMODE && (ticks == 0 || ipis == 0)) || uart_irqs == 0 ||
      (release_build() ? ttc_irqs + ttc_spur != 0 : ttc_irqs == 0))
    fail(0x20);
  puts_("SDIRQ PASS\n");
  tohost(1);
  for (;;) { }
}

int main(uint64_t hartid, uint64_t dtb) {
  (void)dtb;
  if (hartid == CONT_HART) contender();
  if (hartid != 0) for (;;) __asm__ volatile("wfi");
  puts_(SMODE == 2 ? "tanager SD1 interrupt stress (S-mode under Sv39, context 1, ticks): hart 0 handles, hart "
        : SMODE ? "tanager SD1 interrupt stress (S-mode, context 1, ticks): hart 0 handles, hart "
                : "tanager SD1 interrupt stress (M-mode, context 0): hart 0 handles, hart ");
  puthex(CONT_HART, 1); puts_(" contends\n");
  REG32(SD1 + SD_SIG) = 0x3;                     /* command and transfer complete */
  REG32(P_PRIO(IRQ_SD1)) = 1;
  REG32(P_PRIO(IRQ_UART)) = 1;
  REG32(P_PRIO(IRQ_TTC1)) = 1;
  REG32(P_PRIO(IRQ_PSU1)) = 1;
  REG32(P_PRIO(IRQ_IDLE)) = 1;
  REG32(PS_TTC1) = 0;
  REG32(P_EN) = (1u << IRQ_SD1) | (1u << IRQ_UART) | (1u << IRQ_TTC1);
  REG32(P_THR) = 0;
#if SMODE
  CSRW(mtvec, m_entry);                          /* M-mode: the IPIs */
  CSRS(mie, 1ul << 3);                           /* MSIE: taken in S-mode whatever SIE says */
  CSRW(pmpaddr0, -1l);                           /* S-mode reaches everything */
  CSRW(pmpcfg0, 0x1F);
  CSRS(0x30A, 1ull << 63);                       /* menvcfg.STCE: Sstc */
  CSRS(mcounteren, 2);                           /* time */
  CSRW(0x14D, -1l);                              /* stimecmp: no tick yet */
  CSRS(mideleg, (1ul << 9) | (1ul << 5));        /* SEI, STI */
  CSRW(stvec, irq_entry);
  CSRS(sie, (1ul << 9) | (1ul << 5));
  CSRC(mstatus, 3ul << 11);
  CSRS(mstatus, 1ul << 11);                      /* MPP = S */
  CSRW(mepc, requests);
  __asm__ volatile("mret");
#else
  CSRW(mtvec, irq_entry);
  CSRS(mie, 1ul << 11);
  requests();
#endif
  for (;;) { }
}
