/* External interrupts (MEI) from random pulses (tg_vsim --irq-rand): the handler counts them and
   returns; the line drops on its own. The test passes after 2000 loop iterations, so it also
   passes when no pulse arrives (tg_replay injects interrupts itself). */
#include "tg_test.h"
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  la t0, trap
  csrw mtvec, t0
  li s0, 0
  li t0, 0x800              /* MEIE */
  csrs mie, t0
  csrsi mstatus, 8
  li s1, 2000
1:
  addi s2, s2, 1
  mul s4, s2, s2
  bne s2, s1, 1b
  csrci mstatus, 8
  TEST_PASS

  .align 2
trap:
  csrr t5, mcause
  bgez t5, bad
  addi s0, s0, 1
  mret
bad:
  TEST_FAIL(2)

  TOHOST_DATA
