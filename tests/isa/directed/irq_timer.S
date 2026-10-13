/* Timer and software interrupts through the CLINT, taken in lockstep (TR_IRQ), with WFI and mip
   reads (adopted by the checker). 16 timer interrupts at varying distances, then 4 software ones,
   then 6 more timer interrupts that wake WFI. */
#include "tg_test.h"
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  li s0, 0                  /* timer interrupts taken */
  li s3, 0                  /* software interrupts taken */
  /* First compare: mtime + 40 */
  li t0, CLINT_MTIME
  ld t1, 0(t0)
  addi t1, t1, 40
  li t2, CLINT_MTIMECMP
  sd t1, 0(t2)
  li t0, 0x88               /* MTIE | MSIE */
  csrs mie, t0
  csrsi mstatus, 8          /* MIE */
1:                          /* busy loop until 16 timer interrupts */
  addi s2, s2, 3
  xor s4, s4, s2
  csrr t3, mip              /* non-deterministic: adopted */
  li t0, 16
  blt s0, t0, 1b
  /* Software interrupts: set msip, the handler clears it. */
  li s5, 0
2:
  li t0, CLINT_MSIP
  li t1, 1
  sw t1, 0(t0)
3:
  beq s3, s5, 3b            /* wait for the handler */
  addi s5, s5, 1
  li t0, 4
  blt s5, t0, 2b
  /* WFI: sleep until the next timer interrupts */
4:
  wfi
  li t0, 22
  blt s0, t0, 4b
  csrci mstatus, 8
  li t0, 22
  bltu s0, t0, fail         /* at least 22 timer and 4 software interrupts (an injecting */
  li t0, 4                  /* checker test may add more) */
  bltu s3, t0, fail
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
  li t6, 3
  beq t5, t6, soft
bad:
  TEST_FAIL(2)
timer:
  addi s0, s0, 1
  li t6, CLINT_MTIMECMP
  ld t5, 0(t6)
  andi a2, s0, 7
  slli a2, a2, 3            /* vary the distance: 30 + 8 * (count % 8) ticks */
  addi a2, a2, 30
  add t5, t5, a2
  sd t5, 0(t6)
  mret
soft:
  li t6, CLINT_MSIP
  sw zero, 0(t6)
  addi s3, s3, 1
  mret

  TOHOST_DATA
