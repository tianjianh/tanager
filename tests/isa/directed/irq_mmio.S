/* MMIO reads at the ROB head while interrupts arrive (DR-176, SD1's lost interrupt, 10-20). A loop of reads of the
   CLINT's mtime (each an MMIO load, which issues only at the ROB head) while timer interrupts come every 48-108
   ticks, so some arrive in a read's issue cycle; 128 interrupts. tg_lsu asserts that no flush meets an MMIO read
   already sent: before the fix, an interrupt taken in the read's issue cycle flushed the read with its request out,
   and it ran again after the trap (a PLIC claim read twice). Under the regress's trace back-pressure (--trace-stall)
   the ROB often cannot take a pending interrupt (its ready low): the reads must still go out, and the loop end. */
#include "tg_test.h"
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  la t0, trap
  csrw mtvec, t0
  li s0, 0                  /* timer interrupts taken */
  li s1, 0                  /* reads */
  /* First compare: mtime + 48 */
  li t0, CLINT_MTIME
  ld t1, 0(t0)
  addi t1, t1, 48
  li t2, CLINT_MTIMECMP
  sd t1, 0(t2)
  li t0, 0x80               /* MTIE */
  csrs mie, t0
  csrsi mstatus, 8          /* MIE */
  li a0, CLINT_MTIME
1:                          /* back-to-back MMIO reads until 128 timer interrupts */
  ld t3, 0(a0)
  ld t4, 0(a0)
  bltu t4, t3, fail         /* mtime never goes back */
  addi s1, s1, 2
  li t0, 128
  blt s0, t0, 1b
  csrci mstatus, 8
  li t0, 128
  bltu s1, t0, fail         /* the reads went on between the interrupts */
  TEST_PASS
fail:
  TEST_FAIL(1)

  .align 2
trap:
  csrr t5, mcause
  bgez t5, bad              /* an exception: fail */
  slli t5, t5, 1
  srli t5, t5, 1
  li t6, 7
  beq t5, t6, timer
bad:
  TEST_FAIL(2)
timer:
  addi s0, s0, 1
  li t6, CLINT_MTIMECMP
  ld t5, 0(t6)
  andi a2, s0, 15
  slli a2, a2, 2            /* vary the distance: 48 + 4 * (count % 16) ticks */
  addi a2, a2, 48
  add t5, t5, a2
  sd t5, 0(t6)
  mret

  TOHOST_DATA
