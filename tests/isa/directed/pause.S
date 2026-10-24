/* PAUSE (Zihintpause, in v1's ISA string since DR-194) is the FENCE with pred=W and succ=0, 0x0100000f: a hint that
   writes no register, which Linux's cpu_relax runs in its spin loops. Spike decodes it as PAUSE with zihintpause in
   its string (sim/Makefile since 2026-10-24) and as that FENCE without; lockstep compares each record either way. A
   loop runs PAUSEs between a store and the load that reads it back, then the encoding as Linux writes it, then the
   ordinary FENCE and FENCE.TSO beside it. Hart 0 passes; another hart parks. Added by verif-2. */
#include "tg_test.h"
  .option arch, +zicsr, +zihintpause
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  la t0, word
  li t1, 100
1:
  pause
  sd t1, 0(t0)
  pause
  ld t2, 0(t0)
  bne t1, t2, fail
  addi t1, t1, -1
  bnez t1, 1b
  .4byte 0x0100000f           /* the same PAUSE, as Linux's cpu_relax writes it for a toolchain without Zihintpause */
  fence rw, rw
  fence.tso
  ld t2, 0(t0)
  li t1, 1
  bne t1, t2, fail
pass:
  TEST_PASS
fail:
  TEST_FAIL(1)

  .data
  .align 3
word:
  .dword 0

TOHOST_DATA
