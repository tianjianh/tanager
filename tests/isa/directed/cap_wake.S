/* M7 step 7: the issue-queue caps lift while the halves are merged and come back at the split (core-2's review,
   10-21). Hart 1 enables its software interrupt (mie.MSIE; mstatus.MIE stays 0, so WFI resumes without a trap), says it
   is ready, and waits in WFI. Hart 0 sees it ready and gives it time to fall asleep and the halves to merge (step 6:
   the caps lift). Then hart 0 wakes it by an IPI and at once fills its window with long-latency work: a load from a cold
   line, three divides behind it, and behind those ALU ops, loads, store addresses and FP ops, more than half of every
   issue queue (two ALU queues of 10, LD 6, STA 4, FP 10). The wake splits the halves once hart 0's window fits in its
   half, and the caps come back. Hart 1 then needs rows while hart 0 holds more than its share. The caps stop hart 0's
   dispatch, hart 0's rows drain as the divides complete, and hart 1 must finish its work (a sum, then a done flag)
   before hart 0's bounded wait runs out. Lockstep checks every value. Without hart 1, hart 0 finds no ready flag
   within its wait and runs the block alone. tg_issue's +capstat line (stderr) counts the splits that find the running
   thread above its share of every queue before the woken thread's first row; tg_rename's TG-SMT line counts the
   merges and splits. Added by the FPU track (for verif-2's review). */
#include "tg_test.h"
  .option arch, +zicsr, +f, +d
  .section .text.init, "ax"
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1

hart0:
  li t0, 0x2000                /* mstatus.FS: initial */
  csrs mstatus, t0
  la s3, sink                  /* the block's addresses, set up ahead: the block must fit in hart 0's half of the */
  la s5, ldbuf                 /* window (40 entries) with every queue's rows */
  li a0, 3
  la s2, warm                  /* the block once on a warm line, so that its code is in the I$ (at long memory */
  ld t0, 0(s2)                 /* latencies its fetch would otherwise lag hart 1's wake) */
  jal ra, block
  /* Hart 1 ready? (at most about 4,000 iterations: none without hart 1) */
  la s0, flags
  la s2, chain                 /* the cold line */
  li t1, 4000
1:
  ld t2, 0(s0)                 /* flags+0: hart 1 ready */
  bnez t2, 2f
  addi t1, t1, -1
  bnez t1, 1b
  jal ra, block                /* no hart 1: the block alone */
  j pass
2:
  li t1, 200                   /* hart 1 falls asleep and the halves merge: the caps lift */
3:
  addi t1, t1, -1
  bnez t1, 3b
  li t0, CLINT_MSIP            /* wake hart 1 */
  li t1, 1
  sw t1, 4(t0)
  jal ra, block

  /* Wait for hart 1's done flag (flags+8), when hart 1 runs; bounded */
  la s0, flags
  ld t2, 0(s0)
  beqz t2, pass
  li t1, 200000
4:
  ld t2, 8(s0)
  bnez t2, 5f
  addi t1, t1, -1
  bnez t1, 4b
  TEST_FAIL(2)                 /* hart 1 never finished */
5:
  ld t3, 16(s0)                /* hart 1's sum */
  li t4, 5050
  bne t3, t4, fail
pass:
  TEST_PASS
fail:
  TEST_FAIL(1)

block:                         /* a subroutine: run once on a warm line to fetch it into the I$ */
  ld s2, 0(s2)                 /* a cold line (no store touched it): a miss */
  div a6, s2, a0               /* three dependent divides behind it, about 30 cycles each (one quotient bit a */
  div a6, a6, a0               /* cycle), in the second ALU queue */
  div a6, a6, a0
  sub a1, a6, a6               /* zero, when they are done */
  /* Behind it, more than half of every issue queue, all waiting on a1: FP ops first (the window's last entries go
     to the ALU ops, which have rows to spare), loads, store addresses, ALU ops for both ALU queues */
  fmv.d.x f1, a1
  .irp r, 2,3,4,5,6,7
  fadd.d f\r, f1, f1
  .endr
  add a7, s5, a1
  ld a2, 0(a7)
  ld a3, 8(a7)
  ld a4, 16(a7)
  ld a5, 24(a7)
  add s4, s3, a1
  sd a2, 0(s4)
  sd a3, 8(s4)
  sd a4, 16(s4)
  .irp r, 5,6,7,28,29,30
  add x\r, a1, x\r
  .endr
  .irp r, 5,6,7,28,29,30
  xor x\r, a1, x\r
  .endr
  ret

hart1:
  li t1, 1
  csrr t2, mhartid
  bne t2, t1, park             /* only hart 1 */
  li t0, 0x2000                /* mstatus.FS: initial */
  csrs mstatus, t0
  li t0, 0x8                   /* mie.MSIE */
  csrs mie, t0
  la s0, flags
  li t1, 1
  sd t1, 0(s0)                 /* ready */
  li s1, CLINT_MSIP
6:
  wfi
  lw t2, 4(s1)                 /* our IPI? */
  beqz t2, 6b
  sw zero, 4(s1)               /* clear it */
  /* The work: rows in every queue (ALU, loads, stores, FP) */
  la s2, h1buf
  li t3, 0
  li t4, 1
  li t5, 101
7:
  add t3, t3, t4
  sd t3, 0(s2)
  ld t6, 0(s2)
  fcvt.d.l f8, t6
  fadd.d f9, f8, f8
  addi t4, t4, 1
  bne t4, t5, 7b
  sd t3, 16(s0)                /* the sum, 5050 */
  li t1, 1
  sd t1, 8(s0)                 /* done */
park:
  wfi
  j park

  .data
  .align 6
flags:  .dword 0, 0, 0         /* ready, done, hart 1's sum */
  .align 6
h1buf:  .dword 0
  .align 6
sink:   .space 64
  .align 6
ldbuf:  .dword 1, 2, 3, 4
  .align 6
warm:   .dword 0x123456789
  /* The cold line: the divides' dividend */
  .align 12
chain:  .dword 0x123456789

  TOHOST_DATA
