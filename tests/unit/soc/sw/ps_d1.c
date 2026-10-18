/* Stage D's first milestone on the board (docs/spec/soc.md §8.2, D1): the RISC-V reaches the PS through the
 * PS window, a bitstream built with TG_PS_WINDOW=1, while the A53's Linux keeps running. Bare metal, hart 0:
 *   1. writes a line into UART1's transmit FIFO: it shows on the board's USB console, among the A53's output.
 *      UART1 is the A53's console: only its status and FIFO are touched, never its mode, baud or FIFO control;
 *   2. reads IOU_SLCR (UART1's MIO pin, SD1's tap delays: what stage D's SD will inherit);
 *   3. takes TTC1's interval interrupt through its PLIC (source 24), then stops TTC1 (the A53 doesn't use
 *      TTC1: D0 checks that first);
 *   4. gets access faults, without a PS transaction, from TTC0 (the fan's) and UART0, which the window denies.
 * Progress goes to the RISC-V's own console (the PL UART, through tanager-host); TOHOST = 1 on success, else
 * (code << 1) | 1. Run: tanager-host load --fw ps_d1.bin --kernel /dev/null --dtb /dev/null, then run.
 * Registers as in Linux's xilinx_uartps and timer-cadence-ttc drivers. */
#include <stdint.h>

#define UART      ((volatile uint8_t *)0x10000000ul)
#define HOSTCTL   0x10001000ul
#define ACLINT    0x02000000ul
#define PLIC      0x0C000000ul
#define REG32(a)  (*(volatile uint32_t *)(a))
#define REG64(a)  (*(volatile uint64_t *)(a))

#define PS_UART1  0xFF010000ul                  /* Cadence UART: SR 0x2C (bit 4 TX full), FIFO 0x30 */
#define PS_TTC1   0xFF120000ul                  /* Cadence TTC, counter 1 */
#define PS_SLCR   0xFF180000ul                  /* IOU_SLCR: MIO_PIN_n at 4n, SD_ITAPDLY 0x314, SD_OTAPDLYSEL 0x318 */
#define PS_TTC0   0xFF110000ul                  /* the fan's: denied by the window */
#define PS_UART0  0xFF000000ul                  /* not one of the window's apertures */
#define IRQ_TTC1  24

#define TTC_CLK   0x00
#define TTC_CNT   0x0C                          /* [0] disable, [1] interval mode, [4] reset, [5] waveform off */
#define TTC_INTV  0x24
#define TTC_ISR   0x54                          /* read clears */
#define TTC_IER   0x60                          /* [0] interval */

extern volatile uint64_t trap_save[4];          /* start.S: t1 (saved), mcause, mtval, count */

static void putc_(char c) {
  while (!(UART[5] & 0x20)) { }
  UART[0] = (uint8_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint64_t v, int digits) {
  for (int i = 4 * (digits - 1); i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}
static void tohost(uint64_t v) { REG64(HOSTCTL + 0x28) = v; }
static void fail(int code) { puts_("FAIL "); puthex((uint64_t)code, 4); puts_("\n"); tohost(((uint64_t)code << 1) | 1); for (;;) { } }
static uint64_t now(void) { return REG64(ACLINT + 0xBFF8); }   /* 10 MHz */

static void ps_putc(char c) {
  uint64_t t0 = now();
  while (REG32(PS_UART1 + 0x2C) & 0x10) if (now() - t0 > 100000) fail(0x10);   /* 10 ms */
  REG32(PS_UART1 + 0x30) = (uint8_t)c;
}

int main(uint64_t hartid, uint64_t dtb) {
  (void)dtb;
  if (hartid != 0) for (;;) { }
  puts_("tanager D1: the PS window\n");
  uint64_t n0 = trap_save[3];

  /* 1. UART1, the A53's console */
  uint32_t sr = REG32(PS_UART1 + 0x2C);
  if (trap_save[3] != n0) fail(0x11);
  puts_("UART1 SR "); puthex(sr, 8); puts_("\n");
  for (const char *s = "\r\n[tanager RISC-V] hello from the RISC-V, through the PS window\r\n"; *s; s++) ps_putc(*s);
  puts_("UART1: line written\n");

  /* 2. IOU_SLCR, read-only */
  puts_("IOU_SLCR MIO_PIN_36 "); puthex(REG32(PS_SLCR + 0x90), 8);
  puts_(", SD_ITAPDLY "); puthex(REG32(PS_SLCR + 0x314), 8);
  puts_(", SD_OTAPDLYSEL "); puthex(REG32(PS_SLCR + 0x318), 8); puts_("\n");
  if (trap_save[3] != n0) fail(0x20);

  /* 3. TTC1's interval interrupt through the PLIC */
  REG32(PS_TTC1 + TTC_CNT) = 0x23;               /* stopped, interval mode, no waveform */
  REG32(PS_TTC1 + TTC_CLK) = 0;                  /* the bus clock, no prescaler */
  REG32(PS_TTC1 + TTC_INTV) = 0x2000;
  (void)REG32(PS_TTC1 + TTC_ISR);
  REG32(PS_TTC1 + TTC_IER) = 1;
  REG32(PLIC + 4 * IRQ_TTC1) = 1;
  REG32(PLIC + 0x2000) = 1u << IRQ_TTC1;         /* context 0: hart 0's M-mode */
  REG32(PLIC + 0x200000) = 0;
  if (REG32(PLIC + 0x1000) & (1u << IRQ_TTC1)) fail(0x30);
  REG32(PS_TTC1 + TTC_CNT) = 0x32;               /* reset and run */
  uint64_t t0 = now();
  while (!(REG32(PLIC + 0x1000) & (1u << IRQ_TTC1))) if (now() - t0 > 100000) fail(0x31);   /* 10 ms */
  uint64_t dt = now() - t0;
  uint32_t claim = REG32(PLIC + 0x200004);
  REG32(PS_TTC1 + TTC_CNT) = 0x23;               /* stop */
  uint32_t isr = REG32(PS_TTC1 + TTC_ISR);       /* clears the line */
  REG32(PS_TTC1 + TTC_IER) = 0;
  REG32(PLIC + 0x200004) = claim;                /* complete */
  if (claim != IRQ_TTC1) fail(0x32);
  for (volatile int i = 0; i < 100; i++) { }
  if (REG32(PLIC + 0x1000) & (1u << IRQ_TTC1)) fail(0x33);
  puts_("TTC1: interrupt after "); puthex(dt, 8); puts_(" ticks of 10 MHz, ISR "); puthex(isr, 8); puts_("\n");
  if (trap_save[3] != n0) fail(0x34);

  /* 4. what the window denies: access faults, no PS transaction */
  (void)REG32(PS_TTC0);
  if (trap_save[3] != n0 + 1 || trap_save[1] != 5 || trap_save[2] != PS_TTC0) fail(0x40);
  (void)REG32(PS_UART0);
  if (trap_save[3] != n0 + 2 || trap_save[1] != 5 || trap_save[2] != PS_UART0) fail(0x41);
  puts_("denied: TTC0 and UART0 fault\n");

  puts_("D1 PASS\n");
  tohost(1);
  for (;;) { }
}
