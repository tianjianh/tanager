/* Zbb bit counts and min/max (core-pipeline.md §7.2: clz, ctz, cpop and min/max ride P1's MUL
   slot, computed in EX and written in the MUL's cycle). Edge values for every op and its W form,
   then a long loop on xorshift values that interleaves them with multiplies sharing the slot and
   chains their results through the bypass. Lockstep compares every value; the loop also keeps a
   checksum. Passes at once if Zbb is not implemented (the first clz traps). Added by the FPU
   track (AR-8, Execute). */
#include "tg_test.h"
  .option arch, +zbb
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  la t0, trap
  csrw mtvec, t0

  /* 1. Edge values (the first clz is also the Zbb probe) */
  li s0, 0
probe:
  clz t1, s0
  li t2, 64
  bne t1, t2, f1
  ctz t1, s0
  bne t1, t2, f1
  cpop t1, s0
  bnez t1, f1
  clzw t1, s0
  li t2, 32
  bne t1, t2, f1
  ctzw t1, s0
  bne t1, t2, f1
  cpopw t1, s0
  bnez t1, f1

  li s0, -1
  clz t1, s0
  bnez t1, f2
  ctz t1, s0
  bnez t1, f2
  cpop t1, s0
  li t2, 64
  bne t1, t2, f2
  cpopw t1, s0
  li t2, 32
  bne t1, t2, f2

  li s0, 0xffffffff00000000           /* upper word only: the W forms see zero */
  clzw t1, s0
  li t2, 32
  bne t1, t2, f3
  ctzw t1, s0
  bne t1, t2, f3
  cpopw t1, s0
  bnez t1, f3
  ctz t1, s0
  bne t1, t2, f3
  clz t1, s0
  bnez t1, f3

  li s0, 0x8000000000000001
  clz t1, s0
  bnez t1, f4
  ctz t1, s0
  bnez t1, f4
  clzw t1, s0
  li t2, 31
  bne t1, t2, f4
  li s0, 0x0000000080000000
  clzw t1, s0
  bnez t1, f4
  ctzw t1, s0
  li t2, 31
  bne t1, t2, f4
  clz t1, s0
  li t2, 32
  bne t1, t2, f4

  /* min/max at the signed and unsigned boundaries, and equal operands */
  li s0, 0x8000000000000000
  li s1, 0x7fffffffffffffff
  min t1, s0, s1
  bne t1, s0, f5
  max t1, s0, s1
  bne t1, s1, f5
  minu t1, s0, s1
  bne t1, s1, f5
  maxu t1, s0, s1
  bne t1, s0, f5
  li s1, -1
  min t1, s1, zero
  bne t1, s1, f5
  minu t1, s1, zero
  bnez t1, f5
  max t1, s0, s0
  bne t1, s0, f5
  minu t1, s1, s1
  bne t1, s1, f5

  /* 2. Random values: every op, interleaved with MULs on the same slot, results chained */
  li s0, 0x9e3779b97f4a7c15           /* xorshift64 states */
  li s1, 0xd1b54a32d192ed03
  li s2, 0                            /* checksum */
  li s3, 3000                         /* iterations */
loop:
  slli t0, s0, 13
  xor s0, s0, t0
  srli t0, s0, 7
  xor s0, s0, t0
  slli t0, s0, 17
  xor s0, s0, t0
  slli t0, s1, 13
  xor s1, s1, t0
  srli t0, s1, 7
  xor s1, s1, t0
  slli t0, s1, 17
  xor s1, s1, t0
  andi t0, s3, 7                      /* thin some values: long runs of zeros at either end */
  bnez t0, 1f
  srli s4, s0, 40
  slli s5, s1, 37
  j 2f
1:
  mv s4, s0
  mv s5, s1
2:
  clz t1, s4
  mul t2, s4, s5                      /* the MUL slot, back to back with the bit counts */
  ctz t3, s5
  cpop t4, s4
  clzw t5, s5
  mulh t6, s5, s4
  ctzw a2, s4
  cpopw a3, s5
  min a4, s4, s5
  max a5, s5, s4
  minu a6, s4, s5
  maxu a7, s5, s4
  add t1, t1, t3                      /* chained through the bypass */
  clz t3, t1
  minu t4, t4, t3
  xor s2, s2, t1
  xor s2, s2, t2
  xor s2, s2, t4
  xor s2, s2, t5
  xor s2, s2, t6
  add s2, s2, a2
  add s2, s2, a3
  xor s2, s2, a4
  xor s2, s2, a5
  add s2, s2, a6
  xor s2, s2, a7
  rol s2, s2, a3
  addi s3, s3, -1
  bnez s3, loop

  /* Spike's lockstep checks every value above; the checksum only has to be consumed */
  beqz s2, pass                       /* (zero is as good as any other value) */
pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)
f5: TEST_FAIL(5)

  /* Any trap: an illegal-instruction trap on the first clz means no Zbb; anything else fails */
  .align 2
trap:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, f6
  csrr t0, mepc
  la t1, probe
  bne t0, t1, f6
  j pass
f6: TEST_FAIL(6)

  TOHOST_DATA
