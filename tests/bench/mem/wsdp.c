/* wsdp: the L2's write-back batching against the DRAM controller (docs/spec/area_switches.md §Platform tunings, soc.md
   §8.5), bare-metal on one hart as memcal. On a build with the batching (TG_L2_WB_PACE=1), each setting is written to
   the host-control block's L2_PACE (0x1000_1048: [3:0] the batch, 0 or 1 off; [15:4] the cycles a ready write-back may
   wait for it), then WSD_MB MiB are written in 64-byte lines of eight sd at full rate, past the 1 MiB L2, so every line
   is an ownership read and a dirty write-back. The first two runs are the batching off, at full rate and with 4 idle
   cycles after each line (the KV260's controller ran that 28% faster than full rate: board MR39). Each prints
   "WSDP batch=B wait=W k=K readback=R x100 cycles/line C" (R is L2_PACE as read back: 0 on a build without it, where
   the setting does nothing); the run ends with WSDP-END. The setting that runs fastest is the platform's
   TG_L2_PACE_INIT. wsdp.bin streams 16 MiB a setting for the board (about 1.5 s at 100 MHz), wsdp-sim.bin 2 MiB for
   tb_boot. */
#include <stdint.h>

#ifndef WSD_MB
#define WSD_MB 16
#endif
#define UART    ((volatile uint8_t *)0x10000000ul)
#define L2_PACE ((volatile uint64_t *)0x10001048ul)
#define BUF     0x84000000ul             /* memcal's BUF_A: 64 MiB above the image, clear of the boot's other slots */
#define BYTES   ((uint64_t)WSD_MB << 20)

static void putc_(char c) {
  while (!(UART[5] & 0x20)) {}
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
/* WSD_MB MiB in 64-byte lines of eight sd, k idle cycles (a counted loop) after each line */
static void stream(uint64_t p, uint64_t end, uint64_t v, uint64_t k) {
  __asm__ volatile(
    "1: sd %2, 0(%0)\n sd %2, 8(%0)\n sd %2, 16(%0)\n sd %2, 24(%0)\n"
    "   sd %2, 32(%0)\n sd %2, 40(%0)\n sd %2, 48(%0)\n sd %2, 56(%0)\n"
    "   mv t0, %3\n"
    "2: beqz t0, 3f\n addi t0, t0, -1\n j 2b\n"
    "3: addi %0, %0, 64\n bltu %0, %1, 1b\n"
    : "+r"(p) : "r"(end), "r"(v), "r"(k) : "t0", "memory");
}

int main(void) {
  /* {batch, wait, k}: off at full rate and at k=4, then batches of 2 to 8 at full rate, then off again (drift) */
  static const uint16_t set[][3] = {{1, 64, 0}, {1, 64, 4}, {2, 256, 0}, {3, 256, 0}, {4, 256, 0}, {4, 1024, 0},
                                    {6, 512, 0}, {6, 1024, 0}, {8, 1024, 0}, {1, 64, 0}};
  uint64_t init = *L2_PACE;
  puts_("WSDP-BEGIN ");
  putu(WSD_MB);
  puts_(" MiB, L2_PACE at boot ");
  putu(init);
  puts_("\n");
  stream(BUF, BUF + BYTES, 1, 0);                  /* untimed: the L2 then holds the last MiB, dirty */
  for (unsigned i = 0; i < sizeof set / sizeof set[0]; i++) {
    *L2_PACE = (uint64_t)set[i][1] << 4 | set[i][0];
    uint64_t rb = *L2_PACE;
    uint64_t t0 = cycles();
    stream(BUF, BUF + BYTES, i + 2, set[i][2]);
    uint64_t t1 = cycles();
    puts_("WSDP batch=");
    putu(set[i][0]);
    puts_(" wait=");
    putu(set[i][1]);
    puts_(" k=");
    putu(set[i][2]);
    puts_(" readback=");
    putu(rb);
    puts_(" x100 cycles/line ");
    putu((t1 - t0) * 100 / (BYTES / 64));
    puts_("\n");
  }
  *L2_PACE = init;
  puts_("WSDP-END\n");
  return 0;
}
