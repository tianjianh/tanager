/* Rename's register transfers (M7 step 5a, D3 revised; core-pipeline §5.4). With hart 1 on (HART1=1) and hart 0
   alone, hart 0 holds half of each register bank's free registers and takes more from hart 1's lists, one a cycle,
   when its window needs them. For each bank in turn: first map many architectural registers into it (their last
   writers are of the bank's class), then fill the window behind a divide with more writers of that class, so the
   bank needs more than hart 0's share. F0: FP adds; F1: FP loads; bank 0: JALs (port 0's links); bank 1: multiplies
   (port 1); the load bank: loads. Rename's TG-XFER line (stderr) then shows each bank's transfers. Without hart 1 the
   same code runs and nothing transfers. Lockstep checks every value. Added by the core track (for verif-2's review). */
#include "tg_test.h"
  .option arch, +zicsr, +f, +d
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  csrr t0, misa
  andi t0, t0, 0x28            /* F and D */
  li t1, 0x28
  bne t0, t1, pass
  li t0, 0x2000                /* mstatus.FS: initial */
  csrs mstatus, t0
  li s0, 0x80100000
  li t0, 0x3ff0000000000000    /* 1.0 */
  sd t0, 0(s0)
  sd t0, 8(s0)
  li s1, 4                     /* rounds */
  li a2, 1000003
  li a3, 7
  fld f30, 0(s0)
  fld f31, 8(s0)

  .macro BLOCK                 /* a long head: the window fills behind it */
  div a4, a2, a3
  mul a4, a4, a3
  div a4, a4, a3
  .endm
round:
  /* F0: every f register but the sources written by an FP add, then 37 more behind the block */
  fdiv.d f29, f30, f31
  .irp r, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28
  fadd.d f\r, f30, f31
  .endr
  BLOCK
  .rept 37
  fadd.d f1, f30, f31
  .endr
  /* F1: the f registers written by FP loads, then FP loads behind the block */
  .irp r, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29
  fld f\r, 0(s0)
  .endr
  BLOCK
  .rept 36
  fld f2, 8(s0)
  .endr
  /* bank 0: 20 registers written by JALs (port 0's links; no stack operation: not x1 or x5), then links behind the
     block (each JAL jumps to the next instruction) */
  .irp r, t1,t2,t3,t4,t5,t6,a5,a6,a7,s2,s3,s4,s5,s6,s7,s8,s9,s10,s11,a1
  jal \r, 1f
1:
  .endr
  BLOCK
  .rept 37
  jal ra, 1f
1:
  .endr
  /* bank 1: the same registers written by multiplies, then multiplies behind the block */
  .irp r, t1,t2,t3,t4,t5,t6,a5,a6,a7,s2,s3,s4,s5,s6,s7,s8,s9,s10,s11,a1
  mul \r, a2, a3
  .endr
  BLOCK
  .rept 36
  mul t1, a2, a3
  .endr
  /* the load bank: the same registers written by loads, then loads behind the block */
  .irp r, t1,t2,t3,t4,t5,t6,a5,a6,a7,s2,s3,s4,s5,s6,s7,s8,s9,s10,s11,a1
  ld \r, 0(s0)
  .endr
  BLOCK
  .rept 36
  ld t1, 8(s0)
  .endr
  addi s1, s1, -1
  bnez s1, round

  /* the values: lockstep checked each; a last sanity check of the arithmetic */
  li t0, 142857               /* (1000003 / 7) * 7 / 7 */
  bne a4, t0, fail
pass:
  TEST_PASS
fail:
  TEST_FAIL(1)

  TOHOST_DATA
