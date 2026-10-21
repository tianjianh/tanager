/* M7's D3 (docs/spec/m7-smt2-plan.md): a context switch's FP restore, 32 FP loads in a row (fld f0-f31), between
   blocks of FP work that write every f register from the FP pipe, as Linux's __fstate_restore runs at each switch to
   a task that used the FPU. Under writer-sharded banks every fld takes a register from the FP load bank (F1) and
   every FP op one from F0; at commit each frees the f register's previous one, in whichever bank it was. So each
   block leaves all 32 f registers in one bank, and a hart whose own share of that bank is under 33 (32 to hold them
   and one to rename into) cannot finish the next block. With PASSES 2, two harts sharing F1 each hold all 32 there
   and need more: 64 entries hold both harts' f registers with none to rename into. FBLOCKS 4 (m7_fpcompute) is
   the same for F0: after the first block of FP work both harts' f registers are all in F0, and three more blocks of
   FP work need registers there. */
#include "memsuite.h"

#ifndef PASSES
#define PASSES 1  /* passes of the 32 flds a block; past the first, each fld renames into F1 and frees in F1 */
#endif
#ifndef FBLOCKS
#define FBLOCKS 1  /* blocks of 32 FP ops after the flds; past the first, each renames into F0 and frees in F0 */
#endif
#ifndef REPS
#define REPS 2000
#endif

#define FLD(n) "fld f" #n ", " #n "*8(%0)\n"
#define FLD8(a, b, c, d, e, f, g, h) FLD(a) FLD(b) FLD(c) FLD(d) FLD(e) FLD(f) FLD(g) FLD(h)
#define FADD(d, s) "fadd.d f" #d ", f" #d ", f" #s "\n"
#define FADD8(a, b, c, d, e, f, g, h, n) FADD(a, b) FADD(b, c) FADD(c, d) FADD(d, e) FADD(e, f) FADD(f, g) \
  FADD(g, h) FADD(h, n)

static double buf[32];

int main(void) {
  for (int i = 0; i < 32; i++) buf[i] = 0.5 * i;
  tg_region_start();
  for (int r = 0; r < REPS; r++) {
    for (int p = 0; p < PASSES - 1; p++)
      __asm__ volatile(FLD8(0, 1, 2, 3, 4, 5, 6, 7) FLD8(8, 9, 10, 11, 12, 13, 14, 15)
                       FLD8(16, 17, 18, 19, 20, 21, 22, 23) FLD8(24, 25, 26, 27, 28, 29, 30, 31)
                       :
                       : "r"(buf)
                       : "memory", "f0", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
                         "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25",
                         "f26", "f27", "f28", "f29", "f30", "f31");
    __asm__ volatile(
        FLD8(0, 1, 2, 3, 4, 5, 6, 7) FLD8(8, 9, 10, 11, 12, 13, 14, 15)
        FLD8(16, 17, 18, 19, 20, 21, 22, 23) FLD8(24, 25, 26, 27, 28, 29, 30, 31)
        FADD8(0, 1, 2, 3, 4, 5, 6, 7, 8) FADD8(8, 9, 10, 11, 12, 13, 14, 15, 16)
        FADD8(16, 17, 18, 19, 20, 21, 22, 23, 24) FADD8(24, 25, 26, 27, 28, 29, 30, 31, 0)
        "fsd f31, 0(%0)\n"
        :
        : "r"(buf)
        : "memory", "f0", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14",
          "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25", "f26", "f27", "f28", "f29",
          "f30", "f31");
    for (int b = 1; b < FBLOCKS; b++)
      __asm__ volatile(FADD8(0, 1, 2, 3, 4, 5, 6, 7, 8) FADD8(8, 9, 10, 11, 12, 13, 14, 15, 16)
                       FADD8(16, 17, 18, 19, 20, 21, 22, 23, 24) FADD8(24, 25, 26, 27, 28, 29, 30, 31, 0)
                       "fsd f31, 0(%0)\n"
                       :
                       : "r"(buf)
                       : "memory", "f0", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
                         "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25",
                         "f26", "f27", "f28", "f29", "f30", "f31");
  }
  tg_region_stop();
  printf("fprestore reps=%d check=%d\n", REPS, (int)(buf[0] > 0.0));
  return 0;
}
