/* Rename out of wakeup tags: tg_rename's tag_short (verification.md §4.1, §6.4; the core track's
   recipe). Sixteen wakeup tags serve MUL, P1's bit counts and P4's FP-to-FP operations; a tag is
   held from rename until two cycles after its producer writes. Each round loads a cold line into
   x5 (a miss) and moves it to f5, then renames nine MULs of x5 interleaved with nine FMUL.Ds of f5,
   all with distinct destinations. They wait in IQ_A1 and IQ_FP (ten rows each) while the load is
   outstanding, so the 17th tag request stalls rename. Random programs reached it twice in 200.
   Self-checking: every pressured result must equal the same operation done again afterwards, and
   every step is in lockstep with Spike. Passes at once without F and D. */
#include "tg_test.h"
  .option arch, +f, +d

#define ROUNDS 8

  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  csrr t0, misa
  li t1, (1 << 3) | (1 << 5)            /* D, F */
  and t0, t0, t1
  bne t0, t1, pass
  li t0, 1 << 13                        /* mstatus.FS = Initial */
  csrs mstatus, t0
  la a0, lines                          /* one line per round, untouched until then */
  li a1, ROUNDS
  li a2, 0                              /* round */

round:
  slli t0, a2, 6
  add t0, a0, t0
  ld x5, 0(t0)                          /* misses: the line was never accessed */
  fmv.d.x f5, x5
  mul    x18, x5, x5
  fmul.d f6,  f5, f5
  mul    x19, x5, x5
  fmul.d f7,  f5, f5
  mul    x20, x5, x5
  fmul.d f8,  f5, f5
  mul    x21, x5, x5
  fmul.d f9,  f5, f5
  mul    x22, x5, x5
  fmul.d f10, f5, f5
  mul    x23, x5, x5
  fmul.d f11, f5, f5
  mul    x24, x5, x5
  fmul.d f12, f5, f5
  mul    x25, x5, x5
  fmul.d f13, f5, f5
  mul    x26, x5, x5                    /* the 17th tag request: rename stalls here */
  fmul.d f14, f5, f5

  /* The same operations, now without pressure */
  mul    t1, x5, x5
  fmul.d f15, f5, f5
  li a3, 1                              /* failure code: round * 16 + which result */
  bne x18, t1, fail_int
  addi a3, a3, 1
  bne x19, t1, fail_int
  addi a3, a3, 1
  bne x20, t1, fail_int
  addi a3, a3, 1
  bne x21, t1, fail_int
  addi a3, a3, 1
  bne x22, t1, fail_int
  addi a3, a3, 1
  bne x23, t1, fail_int
  addi a3, a3, 1
  bne x24, t1, fail_int
  addi a3, a3, 1
  bne x25, t1, fail_int
  addi a3, a3, 1
  bne x26, t1, fail_int
  addi a3, a3, 1
  feq.d t2, f6, f15
  beqz t2, fail_int
  addi a3, a3, 1
  feq.d t2, f7, f15
  beqz t2, fail_int
  addi a3, a3, 1
  feq.d t2, f8, f15
  beqz t2, fail_int
  addi a3, a3, 1
  feq.d t2, f9, f15
  beqz t2, fail_int
  addi a3, a3, 1
  feq.d t2, f10, f15
  beqz t2, fail_int
  addi a3, a3, 1
  feq.d t2, f11, f15
  beqz t2, fail_int
  /* f12..f14: compared by their bits, so a NaN would fail too */
  fmv.x.d t3, f15
  fmv.x.d t2, f12
  bne t2, t3, fail_int
  fmv.x.d t2, f13
  bne t2, t3, fail_int
  fmv.x.d t2, f14
  bne t2, t3, fail_int

  addi a2, a2, 1
  blt a2, a1, round

pass:
  TEST_PASS

fail_int:
  slli a2, a2, 4
  add a3, a3, a2
  mv a0, a3
  slli a0, a0, 1
  ori a0, a0, 1
  la a1, tohost
  sd a0, 0(a1)
1: j 1b

  .data
  .align 6
  /* One 64-byte line per round; the first word is a double (1.5, 2.5, ...), so FMUL.D works on
     normal numbers and MUL on their bit patterns. */
lines:
  .irp v, 0x3ff8000000000000, 0x4004000000000000, 0x400c000000000000, 0x4012000000000000, 0x4016000000000000, 0x401a000000000000, 0x401e000000000000, 0x4021000000000000
  .dword \v
  .zero 56
  .endr

TOHOST_DATA
