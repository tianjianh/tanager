/* L1D evictions and store/load ordering (core-lsu.md): fills 256 KiB with stores (8x a 32 KiB
   L1D, so dirty lines are released), reads it back, thrashes one set with 24 lines at a 4 KiB
   stride (read-modify-write, so every miss evicts a dirty line), then runs store-to-load
   forwarding and partial-overlap patterns. Lockstep compares every load value; the checksums
   are a second check. Added by the core track. */
#include "tg_test.h"
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  li s0, 0x80100000           /* buffer */
  li s1, 0x40000              /* 256 KiB */
  add s2, s0, s1

  /* Fill: value = addr ^ (addr << 13) */
  mv t0, s0
  li s3, 0
1:
  slli t1, t0, 13
  xor t1, t1, t0
  sd t1, 0(t0)
  add s3, s3, t1
  addi t0, t0, 8
  bltu t0, s2, 1b

  /* Read back */
  mv t0, s0
  li s4, 0
2:
  ld t1, 0(t0)
  add s4, s4, t1
  addi t0, t0, 8
  bltu t0, s2, 2b
  bne s3, s4, fail

  /* One set, 24 lines, 4 rounds of read-modify-write with a byte store in the same line */
  li s5, 4
3:
  mv t0, s0
  li t2, 24
4:
  ld t1, 0(t0)
  addi t1, t1, 1
  sd t1, 0(t0)
  sb t1, 9(t0)
  lbu t3, 9(t0)               /* forwarded from the byte store */
  andi t4, t1, 0xff
  bne t3, t4, fail
  li t3, 4096
  add t0, t0, t3
  addi t2, t2, -1
  bnez t2, 4b
  addi s5, s5, -1
  bnez s5, 3b

  /* Check the thrashed lines: first dword = original + 4 */
  mv t0, s0
  li t2, 24
5:
  ld t1, 0(t0)
  slli t3, t0, 13
  xor t3, t3, t0
  addi t3, t3, 4
  bne t1, t3, fail
  li t3, 4096
  add t0, t0, t3
  addi t2, t2, -1
  bnez t2, 5b

  /* Forwarding and partial overlaps */
  li t0, 0x80180000
  li t1, 0x1122334455667788
  sd t1, 0(t0)
  lb t2, 3(t0)                /* covered by the dword store */
  sb t2, 1(t0)                /* byte store inside it */
  ld t3, 0(t0)                /* partial overlap with the byte store: waits */
  sw t1, 4(t0)
  lwu t4, 4(t0)
  lh t5, 6(t0)
  sh t5, 2(t0)
  lw t6, 0(t0)                /* overlaps the dword, word and halfword stores */
  add s6, t3, t4
  add s6, s6, t5
  add s6, s6, t6
  li t1, 0x5566778855665588
  ld t2, 0(t0)
  bne t2, t1, fail
  TEST_PASS
fail:
  TEST_FAIL(1)

  TOHOST_DATA
