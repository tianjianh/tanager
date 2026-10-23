/* M7 step 7: the issue-queue caps lift while the halves are merged and come back at the split (core-2's review,
   10-21). 32 rounds. In each, hart 1 waits in WFI with its software interrupt enabled locally (mie.MSIE; mstatus.MIE
   stays 0, so WFI resumes without a trap), falls asleep, and the halves merge for hart 0 (step 6: the caps lift).
   Hart 0 then wakes it by an IPI and at once fills its window with long-latency work: a load from a cold line, three
   divides behind it, and behind those ALU ops, loads, store addresses and FP ops, more than half of every issue queue
   (two ALU queues of 10, LD 6, STA 4, FP 10). The wake splits the halves and the caps come back.
   - The split goes early, with that work still in the window, only if hart 0's ROB, LQ and SQ windows all lie in its
     half without wrapping (step 6's win_fits); otherwise it waits until hart 0's window is empty. So before each
     IPI hart 0 moves its ROB, LQ and SQ tails by a round's own amounts (a load-and-store loop and a no-op loop, from
     the table below), and some splits find hart 0 above its share. Hart 1 then needs rows while hart 0 holds more
     than its share: the caps stop hart 0's dispatch, its rows drain as the divides complete, and hart 1 must do its
     work (a sum, then an answer) before hart 0's bounded wait runs out (else code 3).
   - Lockstep checks every value; at the end hart 0 checks hart 1's sum (32 rounds of 5050; code 2). A wake without
     an IPI (WFI may complete at any time) waits again. Without hart 1, hart 0 finds no hart 1 and runs the block
     alone.
   - tg_issue's +capstat line (stderr) counts the splits that find the running thread above its share of every queue,
     and of any queue, before the woken thread's first row; tg_rename's TG-SMT line counts the merges and splits.
   Added by the FPU track (for verif-2's review); hart 1's wake idiom follows core-2's smt_sleep.S. */
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
  la s3, sink                  /* the block's addresses, set up ahead */
  la s5, ldbuf
  li a0, 3
  la s2, warm                  /* the block once on a warm line, so that its code is in the I$ (at long memory */
  jal ra, block                /* latencies its fetch would otherwise lag hart 1's wake) */
  /* Hart 1 there? It sets h1_alive at once; a build without hart 1 never does */
  la s0, h1_alive
  li t1, 20000
1:
  ld t0, 0(s0)
  bnez t0, 2f
  addi t1, t1, -1
  bnez t1, 1b
  la s2, chain                 /* no hart 1: the block alone */
  jal ra, block
  j pass
2:
  li s7, 0                     /* the round */
  la s8, chain                 /* this round's cold line (a page apart: no line of them is touched before) */
  la s9, shifts                /* this round's tail shifts */
  la s10, padbuf
round:
  /* Hart 1 falls asleep and the halves merge: the caps lift (SLP_WAIT is 64 cycles, then the merge) */
  li t1, 400
3:
  addi t1, t1, -1
  bnez t1, 3b
  /* Move the ROB, LQ and SQ tails: k1 loads and stores, then k2 no-op iterations */
  lbu t1, 0(s9)
  lbu t2, 1(s9)
  beqz t1, 5f
4:
  ld t0, 0(s10)
  sd t0, 8(s10)
  addi t1, t1, -1
  bnez t1, 4b
5:
  beqz t2, 7f
6:
  addi t2, t2, -1
  bnez t2, 6b
7:
  addi s7, s7, 1
  la t2, h1_round
  sd s7, 0(t2)
  fence w, o                   /* the round before the IPI (a device output) */
  li t3, CLINT_MSIP + 4        /* wake hart 1 */
  li t0, 1
  sw t0, 0(t3)
  mv s2, s8
  jal ra, block
  /* Wait for hart 1's answer to this round; bounded */
  la t4, h1_ack
  li t5, 1000000
8:
  ld t0, 0(t4)
  beq t0, s7, 9f
  addi t5, t5, -1
  bnez t5, 8b
  TEST_FAIL(3)                 /* hart 1 never answered */
9:
  li t0, 4096
  add s8, s8, t0
  addi s9, s9, 2
  li t0, 32
  bne s7, t0, round
  fence r, r                   /* the answers before the sum */
  la t2, h1_sum
  ld t3, 0(t2)
  li t4, 161600                /* 32 * 5050 */
  bne t3, t4, fail
pass:
  TEST_PASS
fail:
  TEST_FAIL(2)

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

  /* Hart 1: each IPI wakes it from WFI (mstatus.MIE stays 0: no trap) */
hart1:
  li t1, 1
  csrr t2, mhartid
  bne t2, t1, park             /* only hart 1 */
  li t0, 0x2000                /* mstatus.FS: initial */
  csrs mstatus, t0
  li t0, 0x8                   /* mie.MSIE */
  csrs mie, t0
  la s0, h1_alive
  li t1, 1
  sd t1, 0(s0)
  la s1, h1_sum
  la s2, h1_round
  la s4, h1_ack
  la s5, h1buf
  li s3, CLINT_MSIP + 4
10:
  wfi
  csrr t0, mip
  andi t0, t0, 8
  beqz t0, 10b                 /* a wake without an IPI: wait again */
  sw zero, 0(s3)               /* clear its msip, and wait until mip shows it */
11:
  csrr t0, mip
  andi t0, t0, 8
  bnez t0, 11b
  /* The work: rows in every queue (ALU, loads, stores, FP) */
  li t3, 0
  li t4, 1
  li t5, 101
12:
  add t3, t3, t4
  sd t3, 0(s5)
  ld t6, 0(s5)
  fcvt.d.l f8, t6
  fadd.d f9, f8, f8
  addi t4, t4, 1
  bne t4, t5, 12b
  ld t2, 0(s1)
  add t2, t2, t3               /* 5050 a round */
  sd t2, 0(s1)
  fence r, r
  ld t1, 0(s2)                 /* the round hart 0 called */
  fence w, w
  sd t1, 0(s4)                 /* answer it */
  j 10b
park:
  wfi
  j park

  .data
  /* Each round's tail shifts: k1 load-and-store iterations ((7r) mod 23), k2 no-op iterations ((11r) mod 37) */
shifts:
  .byte 0, 0,  7, 11,  14, 22,  21, 33,  5, 7,  12, 18,  19, 29,  3, 3
  .byte 10, 14,  17, 25,  1, 36,  8, 10,  15, 21,  22, 32,  6, 6,  13, 17
  .byte 20, 28,  4, 2,  11, 13,  18, 24,  2, 35,  9, 9,  16, 20,  0, 31
  .byte 7, 5,  14, 16,  21, 27,  5, 1,  12, 12,  19, 23,  3, 34,  10, 8
  .align 6
h1_alive: .dword 0
  .align 6
h1_round: .dword 0
  .align 6
h1_ack:   .dword 0
  .align 6
h1_sum:   .dword 0
  .align 6
h1buf:  .dword 0
  .align 6
padbuf: .dword 0, 0
  .align 6
sink:   .space 64
  .align 6
ldbuf:  .dword 1, 2, 3, 4
  .align 6
warm:   .dword 0x123456789
  /* The cold lines, a page apart: the divides' dividends */
  .align 12
chain:
  .rept 32
  .dword 0x123456789
  .align 12
  .endr

  TOHOST_DATA
