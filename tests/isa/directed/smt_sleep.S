/* Sleep, merge and split with hart 1 (M7 step 6, D2): hart 1 waits in WFI with its software interrupt enabled
   locally (mie.MSIE) but not globally, so each IPI from hart 0 wakes it without a trap. Waiting there it goes to
   sleep and the window's halves merge for hart 0, which streams loads over a 64 KiB buffer, a new line each load,
   so its window fills with misses. Every 512 loads hart 0 sends hart 1 an IPI and waits for its answer: the wake
   splits the window under hart 0's misses, hart 1 clears its msip, adds the round to a sum and answers, and its next
   WFI sleeps again, so the halves merge again. 32 rounds; hart 0 checks hart 1's sum and its own loads' sum. A wake
   without an IPI (WFI may complete at any time; step 6's sleep timeout) waits again. Hart 0 waits for each answer at
   most 1M polls (else it fails with code 3: hart 1 never woke). Without hart 1 (a build without it) hart 0 finds no
   hart 1 at the start and runs the stream alone. Added by the core track; reviewed by verif-2 (the fences: the round's
   store before the IPI's device store, the answers before the sum). */
#include "tg_test.h"
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1

  /* Hart 0: the buffer, a word a line: line i holds i */
  la s4, buf
  li t1, 1024
  li t2, 0
1:
  sd t2, 0(s4)
  addi t2, t2, 1
  addi s4, s4, 64
  bne t2, t1, 1b
  /* Hart 1 there? It sets h1_alive at once; a build without hart 1 never does */
  la s0, h1_alive
  li t1, 20000
2:
  ld t0, 0(s0)
  bnez t0, 3f
  addi t1, t1, -1
  bnez t1, 2b
  li s7, 0
  j 4f
3:
  li s7, 1
4:
  /* 32 rounds of 512 loads, a line apart, around the buffer */
  la s4, buf
  li s5, 0                  /* the round */
  li s6, 0                  /* the loads' sum */
  li s8, 0                  /* the offset in the buffer */
  li s9, 0xffff
5:
  li t1, 512
6:
  add t3, s4, s8
  ld t0, 0(t3)
  add s6, s6, t0
  addi s8, s8, 64
  and s8, s8, s9
  addi t1, t1, -1
  bnez t1, 6b
  addi s5, s5, 1
  beqz s7, 8f
  la t2, h1_round
  sd s5, 0(t2)
  fence w, o                /* the round before the IPI (a device output) */
  li t3, CLINT_MSIP + 4     /* hart 1's msip */
  li t0, 1
  sw t0, 0(t3)
  la t4, h1_ack
  li t5, 1000000
7:
  ld t0, 0(t4)
  beq t0, s5, 8f            /* hart 1 answered this round */
  addi t5, t5, -1
  bnez t5, 7b
  j fail3                   /* no answer: hart 1 never woke */
8:
  li t0, 32
  bne s5, t0, 5b
  /* 16 passes over the buffer: 16 * (0 + 1 + ... + 1023) */
  li t0, 8380416
  bne s6, t0, fail
  beqz s7, pass
  fence r, r                /* the answers before the sum */
  la t2, h1_sum
  ld t0, 0(t2)
  li t1, 528                /* 1 + 2 + ... + 32 */
  bne t0, t1, fail2
pass:
  TEST_PASS
fail:
  TEST_FAIL(1)
fail2:
  TEST_FAIL(2)
fail3:
  TEST_FAIL(3)

  /* Hart 1: each IPI wakes it from WFI (mstatus.MIE stays 0: no trap) */
hart1:
  li t0, 8                  /* mie.MSIE */
  csrw mie, t0
  la s0, h1_alive
  li t0, 1
  sd t0, 0(s0)
  la s1, h1_sum
  la s2, h1_round
  la s4, h1_ack
  li s3, CLINT_MSIP + 4
9:
  wfi
  csrr t0, mip
  andi t0, t0, 8
  beqz t0, 9b               /* a wake without an IPI: wait again */
  sw zero, 0(s3)            /* clear its msip, and wait until mip shows it */
10:
  csrr t0, mip
  andi t0, t0, 8
  bnez t0, 10b
  fence r, r
  ld t1, 0(s2)              /* the round hart 0 called */
  ld t2, 0(s1)
  add t2, t2, t1
  sd t2, 0(s1)
  fence w, w
  sd t1, 0(s4)              /* answer it */
  j 9b

  .section .data
  .align 6
h1_alive: .dword 0
  .align 6
h1_round: .dword 0
  .align 6
h1_ack:   .dword 0
  .align 6
h1_sum:   .dword 0
  .section .bss
  .align 12
buf: .skip 65536

TOHOST_DATA
