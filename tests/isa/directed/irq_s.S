/* Supervisor interrupts (core-priv.md): SSI, STI and SEI delegated to S through mideleg; Sstc
   (stimecmp, with menvcfg.STCE and mcounteren.TM); an S software interrupt that waits for
   sstatus.SIE; STI in a loop, waking WFI in S, and while in U (taken in S whatever SIE says);
   an M timer interrupt that is not delegated, taken from S although mstatus.MIE is clear; SEI
   pulses with --irq-rand, counted. The checker injects every interrupt into Spike and checks its
   cause and EPC. Passes at once without S mode. Added by the core track. */
#include "tg_test.h"
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  csrr t0, misa
  li t1, 1 << 18                       /* S */
  and t0, t0, t1
  beqz t0, pass
  la t0, mtrap
  csrw mtvec, t0
  la t0, strap
  csrw stvec, t0
  li s2, 0                             /* SSI taken */
  li s3, 0                             /* STI taken */
  li s4, 0                             /* MTI taken */
  li s6, 0                             /* SEI taken */
  li t0, 0x222
  csrw mideleg, t0                     /* SSI, STI, SEI to S */
  li t0, 1 << 8
  csrw medeleg, t0                     /* ECALL from U to S */
  li t0, 0x2a2
  csrs mie, t0                         /* SSIE, STIE, SEIE, MTIE */
  li t0, 1
  slli t0, t0, 63
  csrs menvcfg, t0                     /* STCE */
  li t0, 2
  csrs mcounteren, t0                  /* TM */
  li t0, -1
  csrw stimecmp, t0
  li t0, CLINT_MTIME                   /* one M timer interrupt, taken while S or U runs */
  ld t1, 0(t0)
  addi t1, t1, 200
  li t2, CLINT_MTIMECMP
  sd t1, 0(t2)
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x0800
  csrs mstatus, t0                     /* MPP = S; SIE = 0 there */
  la t0, s_code
  csrw mepc, t0
  mret

s_code:
  /* 1. SSI: pending while SIE = 0, taken once SIE is set */
  csrsi sip, 2
  nop
  bnez s2, f1
  csrsi sstatus, 2
  li t0, 1
  bne s2, t0, f1
  /* 2. STI in a loop */
  rdtime t0
  addi t0, t0, 30
  csrw stimecmp, t0
1:
  beqz s3, 1b
  /* 3. STI wakes WFI */
  rdtime t0
  addi t0, t0, 30
  csrw stimecmp, t0
2:
  wfi
  li t0, 2
  blt s3, t0, 2b
  /* 4. STI in U, with SIE = 0 */
  rdtime t0
  addi t0, t0, 30
  csrw stimecmp, t0
  csrci sstatus, 2
  li t0, 0x100
  csrc sstatus, t0                     /* SPP = U */
  la t0, u_code
  csrw sepc, t0
  sret
u_code:
  li t0, 3
3:
  blt s3, t0, 3b
  ecall                                /* to S at s_after_u */
s_after_u:
  /* 5. The M timer interrupt reaches M from S although mstatus.MIE = 0 */
  csrsi sstatus, 2
  li t0, 1
4:
  blt s4, t0, 4b
  ecall                                /* to M at m_done */

m_done:
  li t0, 1
  bne s2, t0, f2
  li t0, 3
  bltu s3, t0, f2
  li t0, 1
  bne s4, t0, f2
pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)

  /* S handler (t5, t6): ECALL from U continues in S at s_after_u; interrupts are counted and
     their source cleared (SEI cannot be: SEIE is turned off) */
  .align 2
strap:
  csrr t5, scause
  bltz t5, 1f
  li t6, 8
  bne t5, t6, f3
  la t6, s_after_u
  csrw sepc, t6
  li t6, 0x100
  csrs sstatus, t6                     /* SPP = S */
  sret
1:
  slli t5, t5, 1
  srli t5, t5, 1
  li t6, 1
  beq t5, t6, 2f
  li t6, 5
  beq t5, t6, 3f
  li t6, 9
  beq t5, t6, 4f
  j f3
2:
  csrci sip, 2
  addi s2, s2, 1
  sret
3:
  li t6, -1
  csrw stimecmp, t6
  addi s3, s3, 1
  sret
4:
  li t6, 0x200
  csrc sie, t6
  addi s6, s6, 1
  sret

  /* M handler (a6, a7): ECALL from S ends at m_done; the timer interrupt is counted */
  .align 2
mtrap:
  csrr a6, mcause
  bltz a6, 1f
  li a7, 9
  bne a6, a7, f4
  la a7, m_done
  csrw mepc, a7
  li a7, 0x1800
  csrs mstatus, a7                     /* MPP = M */
  mret
1:
  slli a6, a6, 1
  srli a6, a6, 1
  li a7, 7
  bne a6, a7, f4
  li a6, CLINT_MTIMECMP
  li a7, -1
  sd a7, 0(a6)
  addi s4, s4, 1
  mret

TOHOST_DATA
