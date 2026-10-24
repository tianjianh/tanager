/* A write to mcycle and minstret takes effect: each reads back at least the written value. The checker cannot see a
   lost write (counter reads are nondeterministic in lockstep), so the test checks itself. Under SOLO_TID=1 the
   counters loaded thread 0's pending write (zero) instead of the running thread's, until tg_csr's g_ctr loaded each
   hart's own (fpu-2's hpm.S, 10-23). */
#include "tg_test.h"
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  li t0, 1
  slli t0, t0, 40
  csrw mcycle, t0
  csrr t1, mcycle
  bltu t1, t0, f1
  csrw minstret, t0
  csrr t1, minstret
  bltu t1, t0, f2
  TEST_PASS
f1:
  TEST_FAIL(1)
f2:
  TEST_FAIL(2)

TOHOST_DATA
