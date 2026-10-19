/* D4 modes, step 2(a) on the board (docs/spec/soc-d4-modes.md): the RISC-V resets the whole board through the
 * PS window, as Debian's reboot will in RISC-V mode (OpenSBI's syscon-reboot: a read-modify-write of CRL_APB
 * RESET_CTRL's SOFT_RESET, bit 4). Under tanager-host in ARM mode, a bitstream built with TG_PS_WINDOW=1 and
 * BOARD_CTRL set to 2 first, so the window passes RESET_CTRL. Bare metal, hart 0:
 *   1. reads RESET_CTRL, the access timed with mtime. A fault is the window denying it (BOARD_CTRL[1] clear),
 *      the PS answering an error (the XPPU or TrustZone refusing a non-secure PL master: then the PMU's reset
 *      service is the fallback), or, after the window's 2^16-cycle timeout (655 us), no answer at all;
 *   2. after a second for the host to show the console, writes RESET_CTRL | 0x10: the board resets (the PS and
 *      the PL) and the A53 boots Ubuntu again, which is the pass;
 *   3. still running 100 ms later, it reports how the write ended: a fault, or taken without a reset.
 * Progress goes to the RISC-V's own console (the PL UART, through tanager-host); TOHOST = (code << 1) | 1 on
 * each failure. Run: tanager-host poke 0x1404 2; tanager-host load --fw ps_reset.bin --kernel /dev/null
 * --dtb /dev/null; tanager-host run. */
#include <stdint.h>

#define UART      ((volatile uint8_t *)0x10000000ul)
#define HOSTCTL   0x10001000ul
#define ACLINT    0x02000000ul
#define REG32(a)  (*(volatile uint32_t *)(a))
#define REG64(a)  (*(volatile uint64_t *)(a))

#define RESET_CTRL 0xFF5E0218ul                 /* CRL_APB: [4] SOFT_RESET, a system reset */
#define NO_ANSWER  5000                         /* ticks of 10 MHz: past this, the window's timeout */

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
static uint64_t now(void) { return REG64(ACLINT + 0xBFF8); }   /* 10 MHz */
static void wait_ticks(uint64_t t) { uint64_t t0 = now(); while (now() - t0 < t) { } }
static void stop(int code) { tohost(((uint64_t)code << 1) | 1); for (;;) { } }

int main(uint64_t hartid, uint64_t dtb) {
  (void)dtb;
  if (hartid != 0) for (;;) { }
  puts_("tanager D4 step 2a: the board's reset through the PS window\n");

  /* 1. read RESET_CTRL */
  uint64_t n0 = trap_save[3];
  uint64_t t0 = now();
  uint32_t v = REG32(RESET_CTRL);
  uint64_t dt = now() - t0;
  if (trap_save[3] != n0) {
    puts_("RESET_CTRL read: access fault (mcause "); puthex(trap_save[1], 2);
    puts_(") after "); puthex(dt, 8); puts_(" ticks of 10 MHz: ");
    puts_(dt > NO_ANSWER ? "no answer from the PS (the window's timeout)\n"
                         : "the window denied it (BOARD_CTRL[1] clear?) or the PS answered an error\n");
    stop(1);
  }
  puts_("RESET_CTRL "); puthex(v, 8); puts_(", read in "); puthex(dt, 8);
  puts_(" ticks of 10 MHz; writing SOFT_RESET in 1 s: the board should reset\n");

  /* 2. write SOFT_RESET */
  while (!(UART[5] & 0x40)) { }                  /* LSR.TEMT: the console has it all */
  wait_ticks(10000000);
  n0 = trap_save[3];
  t0 = now();
  REG32(RESET_CTRL) = v | 0x10;
  dt = now() - t0;

  /* 3. still here */
  wait_ticks(1000000);
  if (trap_save[3] != n0) {
    puts_("RESET_CTRL write: access fault (mcause "); puthex(trap_save[1], 2);
    puts_(") after "); puthex(dt, 8); puts_(" ticks: ");
    puts_(dt > NO_ANSWER ? "no answer from the PS\n"
                         : "the PS answered an error (the XPPU or TrustZone): the fallback is the PMU's reset service\n");
    stop(2);
  }
  puts_("RESET_CTRL write taken in "); puthex(dt, 8); puts_(" ticks, but no reset after 100 ms; RESET_CTRL now ");
  puthex(REG32(RESET_CTRL), 8); puts_("\n");
  stop(3);
  return 0;
}
