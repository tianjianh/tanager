/* Commit turns with hart 1 (M7 step 5d): a head operation never waits long behind a sibling that keeps committing.
   Hart 0 runs a long loop of independent ALU instructions, so its head is nearly always complete and it keeps the
   commit turn while it commits. Hart 1 meanwhile reads the CLINT's mtime (an MMIO load, issued only at the head in
   hart 1's turns) and adds to a counter with an AMO (performed at the head, not complete before), 64 times each, then
   parks in WFI. tg_rob asserts that a thread with entries, not parked, waits at most RUN_K (4) cycles for a turn; the
   rule that gives a busy sibling's turn away after RUN_K in a row is what keeps hart 1's AMO going here. Hart 1 checks
   every AMO's old value and that mtime never goes back, and fails the test through tohost if not. Without hart 1 only
   hart 0 runs it. Added by the core track (for verif-2's review). */
#include "tg_test.h"
  .option arch, +zicsr, +a
  .section .text.init, "ax"
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  /* Hart 0: 8,000 iterations of six independent ALU instructions and the loop's two (about 64K instructions,
     longer than hart 1's work) */
  li t1, 8000
  li a1, 0
  li a2, 0
1:
  addi a1, a1, 1
  addi a2, a2, 3
  addi a3, a3, 5
  addi a4, a4, 7
  xor  a5, a5, a1
  add  a6, a6, a2
  addi t1, t1, -1
  bnez t1, 1b
  li t0, 8000
  bne a1, t0, fail
  TEST_PASS
fail:
  TEST_FAIL(1)

  /* Hart 1: MMIO reads and AMOs, each a head operation */
hart1:
  csrr t0, misa
  andi t0, t0, 1            /* (misa.A) */
  beqz t0, park
  li s1, 0x80100100         /* the AMO counter, a line of its own */
  sd zero, 0(s1)
  li s0, 0                  /* its expected value */
  li a0, CLINT_MTIME
  li t1, 64
2:
  ld t3, 0(a0)
  ld t4, 0(a0)
  bltu t4, t3, h1fail       /* mtime never goes back */
  li t0, 1
  amoadd.d t5, t0, (s1)
  bne t5, s0, h1fail        /* each AMO's old value */
  addi s0, s0, 1
  addi t1, t1, -1
  bnez t1, 2b
park:
  wfi
  j park
h1fail:
  TEST_FAIL(2)

TOHOST_DATA
