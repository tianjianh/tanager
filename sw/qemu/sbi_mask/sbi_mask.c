/* sbi_mask: OpenSBI's remote fence and IPI with a hart mask that names a stopped hart (soc.md §5, Tanager's OpenSBI
   patch tg1). With fw_jump only the boot hart starts; the others wait in OpenSBI, stopped (HSM). The payload, in
   S-mode on QEMU virt with four harts, fences and IPIs itself plus a stopped hart (tg1: done, error 0, and its own
   SSIP set; upstream 1.9: SBI_ERR_INVALID_PARAM, -3, before any IPI), a hart that doesn't exist (-3 either way) and
   every hart (0), then powers off. sw/qemu/sbi_mask_test.sh checks the lines. */
#include <stdint.h>
struct sbiret { long error; long value; };
static struct sbiret ecall(long ext, long fid, long a0, long a1, long a2, long a3) {
  register long r0 __asm__("a0") = a0, r1 __asm__("a1") = a1, r2 __asm__("a2") = a2, r3 __asm__("a3") = a3;
  register long r6 __asm__("a6") = fid, r7 __asm__("a7") = ext;
  __asm__ volatile("ecall" : "+r"(r0), "+r"(r1) : "r"(r2), "r"(r3), "r"(r6), "r"(r7) : "memory");
  return (struct sbiret){r0, r1};
}
#define EXT_DBCN  0x4442434E
#define EXT_HSM   0x48534D
#define EXT_RFNC  0x52464E43
#define EXT_IPI   0x735049
#define EXT_SRST  0x53525354
static void putc_(char c) { ecall(EXT_DBCN, 2, c, 0, 0, 0); }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void putl(long v) {
  char b[24]; int i = 0; unsigned long u = v < 0 ? -(unsigned long)v : (unsigned long)v;
  if (v < 0) putc_('-');
  do { b[i++] = (char)('0' + u % 10); u /= 10; } while (u);
  while (i) putc_(b[--i]);
}
static void line(const char *what, long err) { puts_(what); puts_(" err="); putl(err); puts_("\n"); }
static unsigned long sip(void) { unsigned long v; __asm__ volatile("csrr %0, sip" : "=r"(v)); return v; }
static void sip_clear(void) { __asm__ volatile("csrc sip, %0" ::"r"(2ul)); }
int main(long hartid) {
  long stopped = -1;
  for (long h = 0; h < 4; h++)
    if (h != hartid && ecall(EXT_HSM, 2, h, 0, 0, 0).value == 1) { stopped = h; break; }
  puts_("SBI-MASK hart "); putl(hartid); puts_(" stopped "); putl(stopped); puts_("\n");
  if (stopped < 0) { puts_("SBI-MASK no stopped hart\n"); ecall(EXT_SRST, 0, 0, 0, 0, 0); return 1; }
  long mask = (1l << hartid) | (1l << stopped);
  line("SBI-MASK rfence-stopped", ecall(EXT_RFNC, 1, mask, 0, 0, -1).error);        /* remote_sfence_vma */
  line("SBI-MASK rfence-asid-stopped", ecall(EXT_RFNC, 2, mask, 0, 0, -1).error);   /* ..._asid, ASID 0 */
  line("SBI-MASK fencei-stopped", ecall(EXT_RFNC, 0, mask, 0, 0, 0).error);         /* remote_fence_i */
  sip_clear();
  long e = ecall(EXT_IPI, 0, mask, 0, 0, 0).error;
  for (volatile int i = 0; i < 1000; i++) { }
  puts_("SBI-MASK ipi-stopped err="); putl(e); puts_(" ssip="); putl((long)((sip() >> 1) & 1)); puts_("\n");
  sip_clear();
  line("SBI-MASK rfence-nohart", ecall(EXT_RFNC, 1, (1l << hartid) | (1l << 9), 0, 0, -1).error);
  line("SBI-MASK ipi-nohart", ecall(EXT_IPI, 0, (1l << hartid) | (1l << 9), 0, 0, 0).error);
  line("SBI-MASK rfence-all", ecall(EXT_RFNC, 1, 0, -1, 0, -1).error);
  sip_clear();
  puts_("SBI-MASK done\n");
  ecall(EXT_SRST, 0, 0, 0, 0, 0);   /* shutdown */
  return 0;
}
