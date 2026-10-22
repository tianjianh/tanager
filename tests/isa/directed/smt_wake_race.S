/* M7 step 6's merge race (core-pipeline.md §8.5): a sleeper's wake request in the cycle a merge travels (rename's
   mdn_q merged, md_q still split). On 124edb9f the hold on the runner's tails dropped with the request, rename could
   wrap a tail in its half in that cycle, and the merged window then took the sleeper's stale half in. Here the wake is
   an interrupt, with no stress: hart 1, ROUNDS times, sets its own timer a few ticks ahead and spins a few cycles (the
   delay sweeps 3 to 10 ticks and the spin 0 to 31 rounds, so the interrupt lands at many points around the merge),
   waits in WFI with MTIE enabled (mstatus.MIE stays 0, so no trap), sleeps after 64 cycles, and the halves merge for
   hart 0. Hart 0 meanwhile runs ALU work with a store and a load a round, so one of its tails (the LQ's and SQ's
   halves are 12 and 10 entries) is often within a group of its half's end when a merge waits, and rename fires as soon
   as the hold drops. The sweep assumes tg_vsim's default --mtime-div (20 cycles a tick): a much smaller divider fires
   the timer before hart 1 sleeps, a much larger one after the merge has settled. Lockstep checks every record: on
   124edb9f (main 2e7b7229) every latency fails, at native, 30, 120 and 250 cycles, within 90K cycles. At the end hart 0
   checks its sums (code 2) and hart 1's round count (code 3). Without hart 1 only hart 0 runs. Added by the core track
   (reviewed by verif-2). */
#include "tg_test.h"
#define ROUNDS 1000
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  csrr t0, mhartid
  la s0, h1_state
  bnez t0, hart1

hart0:
  /* Hart 1 there? It sets h1_state at once */
  li t1, 20000
1:
  lw t2, 0(s0)
  bnez t2, 2f
  addi t1, t1, -1
  bnez t1, 1b
  TEST_PASS
2:
  /* Work until hart 1 is done: ALU ops, and a store and a load a round (so the LQ's and SQ's tails, in halves of 12
     and 10, are often within a group of their half's end when a merge waits); every eighth round reads its flag */
  li a1, 0
  li a2, 0
  li a3, 0
  li a4, 0
  la s5, buf
3:
  addi a1, a1, 1
  addi a2, a2, 3
  andi t3, a1, 63
  slli t3, t3, 3
  add t3, t3, s5
  sd a2, 0(t3)
  ld t4, 0(t3)
  add a3, a3, t4
  addi a4, a4, 7
  andi t1, a1, 7
  bnez t1, 3b
  lw t2, 4(s0)
  beqz t2, 3b
  /* The sums: a2 = 3 n, a3 = 3 n (n + 1) / 2, a4 = 7 n */
  slli t1, a1, 1
  add t1, t1, a1
  bne t1, a2, fail_sum
  addi t3, a1, 1
  mul t1, t1, t3
  srli t1, t1, 1
  bne t1, a3, fail_sum
  slli t1, a1, 3
  sub t1, t1, a1
  bne t1, a4, fail_sum
  li t1, ROUNDS
  bne t2, t1, fail_rounds
  TEST_PASS

hart1:
  li t1, 1
  sw t1, 0(s0)
  li t0, 0x80                  /* mie.MTIE: the timer completes WFI; mstatus.MIE stays 0 */
  csrs mie, t0
  li s1, 0
  li s2, ROUNDS
  li s3, CLINT_MTIMECMP + 8    /* hart 1's mtimecmp */
  li s4, CLINT_MTIME
10:
  andi t0, s1, 7
  addi t0, t0, 3               /* the delay, 3 to 10 ticks */
  srli t3, s1, 3
  andi t3, t3, 31              /* then a spin of 0 to 31 rounds */
  ld t1, 0(s4)
  add t1, t1, t0
  sd t1, 0(s3)
13:
  beqz t3, 11f
  addi t3, t3, -1
  j 13b
11:
  wfi
  csrr t2, mip
  andi t2, t2, 0x80
  beqz t2, 11b                 /* a wake without the timer (WFI may complete at any time): wait again */
  li t1, -1
  sd t1, 0(s3)                 /* the timer off: MTIP clears */
  addi s1, s1, 1
  bne s1, s2, 10b
  sw s1, 4(s0)                 /* done: the rounds */
12:
  wfi
  j 12b

fail_sum:
  TEST_FAIL(2)
fail_rounds:
  TEST_FAIL(3)

  .section .data
  .align 6
h1_state: .word 0     /* 1: hart 1 runs */
h1_done:  .word 0     /* hart 1's rounds, once done */
  .align 6
buf:      .space 512

TOHOST_DATA
