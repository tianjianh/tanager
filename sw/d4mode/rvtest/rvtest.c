/* D4 modes, step 5's test image (docs/spec/soc-d4-modes.md): RISC-V mode bare metal, in U-Boot's place after
 * OpenSBI. It says hello on the PL UART (COM5, the 16550 at 0x1000_0000) and on UART1 (COM7, the Cadence UART through
 * the PS window), then asks OpenSBI for a cold reboot (SBI SRST), which goes to the tree's syscon-reboot: CRL_APB
 * RESET_CTRL's SOFT_RESET through the PS window. The board resets; the boot mode record says riscv with trial 1, so
 * the A53 boots Ubuntu: the pass. If SRST returns, it writes RESET_CTRL itself; still running after that, it asks
 * for the PMOD reset hook (a 3 s break on COM5) every 5 s. An access the PS window denies is a trap, counted and
 * skipped (start.S), so on QEMU (no UART1, no RESET_CTRL) it runs through to SRST too. */
#include <stdint.h>

#define UART0       ((volatile uint8_t *)0x10000000ul)    /* the PL UART: LSR at 5, THRE bit 5 */
#define UART1       0xFF010000ul                           /* Cadence: SR 0x2C (bit 4 TX full), FIFO 0x30 */
#define RESET_CTRL  0xFF5E0218ul
#define REG32(a)    (*(volatile uint32_t *)(a))

extern volatile uint64_t trap_count[2];
static int uart1_ok = 1;

static uint64_t now(void) { uint64_t t; __asm__ volatile ("rdtime %0" : "=r"(t)); return t; }   /* 10 MHz */
static void wait_ticks(uint64_t n) { uint64_t t0 = now(); while (now() - t0 < n) { } }

static void putc0(char c) { while (!(UART0[5] & 0x20)) { } UART0[0] = (uint8_t)c; }
static void putc1(char c) {
  if (!uart1_ok) return;
  uint64_t n = trap_count[0], t0 = now();
  while (REG32(UART1 + 0x2C) & 0x10) {
    if (trap_count[0] != n || now() - t0 > 100000) { uart1_ok = 0; return; }
  }
  REG32(UART1 + 0x30) = (uint8_t)c;
  if (trap_count[0] != n) uart1_ok = 0;
}
static void puts2(const char *s) {
  for (; *s; s++) {
    if (*s == '\n') { putc0('\r'); putc1('\r'); }
    putc0(*s); putc1(*s);
  }
}
static void puthex2(uint64_t v) {
  char b[17];
  for (int i = 0; i < 16; i++) b[i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 15];
  b[16] = 0;
  puts2(b);
}

static long sbi_srst(unsigned long type, unsigned long reason) {
  register unsigned long a0 __asm__("a0") = type;
  register unsigned long a1 __asm__("a1") = reason;
  register unsigned long a6 __asm__("a6") = 0;
  register unsigned long a7 __asm__("a7") = 0x53525354;   /* "SRST" */
  __asm__ volatile ("ecall" : "+r"(a0), "+r"(a1) : "r"(a6), "r"(a7) : "memory");
  return (long)a0;
}

static void hello(uint64_t hartid, uint64_t dtb) {
  puts2("\ntanager D4 step 5: RISC-V mode, bare metal, hart ");
  puthex2(hartid);
  puts2(", tree at ");
  puthex2(dtb);
  puts2("\n");
  puts2(uart1_ok ? "UART1: this line is on COM7 too\n" : "UART1: not reachable (the PS window denied it)\n");
}

int main(uint64_t hartid, uint64_t dtb) {
  hello(hartid, dtb);
  /* COM5's USB-UART drops out at every PL load (the board session, 10-19) and comes back seconds later: the hello
   * again after 10 s, for its log */
  wait_ticks(100000000);
  hello(hartid, dtb);
  puts2("SBI system reset, cold reboot: the board should reset, then boot Ubuntu (trial 1)\n");
  wait_ticks(5000000);                                      /* 0.5 s for the UARTs */
  long e = sbi_srst(1, 0);
  puts2("SBI SRST returned ");
  puthex2((uint64_t)e);
  puts2("; writing RESET_CTRL directly\n");
  wait_ticks(5000000);
  uint64_t n = trap_count[0];
  uint32_t v = REG32(RESET_CTRL);
  REG32(RESET_CTRL) = v | 0x10;
  wait_ticks(1000000);
  puts2(trap_count[0] != n ? "RESET_CTRL: an access fault (BOARD_CTRL[1] clear, or the PS refused)\n"
                           : "RESET_CTRL: written, but no reset\n");
  for (;;) {
    puts2("no reset: send a 3 s break on COM5 (the PMOD reset hook)\n");
    wait_ticks(50000000);
  }
}
