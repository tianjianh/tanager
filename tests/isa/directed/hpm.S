/* M9's performance counters (TG_HPM, docs/spec/m9-plan.md §1): mhpmcounter3-6 counting mhpmevent's event (1 cycles,
   2 instructions retired, 3 branch mispredicts, 5 L1D load misses, 6 data walks, 7 fetch's walks, 8 I$ misses, 0
   nothing); mcountinhibit; Sscofpmf's mode inhibits (MINH, SINH, UINH) read in M, S and U; OF set by a wrap and not by
   a write (a write across bit 63, counting and stopped), a counter written as -1 wrapping at its next count; LCOFIP set
   as OF rises, not by a second wrap or by software's OF; LCOFI taken in M, delegated in S, and from S in M; scountovf in
   M and from S under mcounteren. Passes at once without the counters (mhpmevent3 reads zero: TG_HPM off, Spike, the
   test core). Spike's counters read zero, so with TG_HPM on it runs with --no-lockstep until the checker takes the
   counters from the core. Added by the FPU track. */
#include "tg_test.h"
#define LCOF      (1 << 13)
#define SCOUNTOVF 0xda0
/* mhpmevent: OF (63), MINH (62), SINH (61), UINH (60), the event (7:0) */
#define EV_OF     0x8000000000000000
#define EV_MINH   0x4000000000000000
#define EV_SINH   0x2000000000000000
#define EV_UINH   0x1000000000000000

/* 2n + 1 instructions, n cycles at least (t0) */
#define SPIN(n)                \
  li t0, n;                    \
77: addi t0, t0, -1;           \
  bnez t0, 77b

/* mret to label in S (MPP = S); its ECALL continues in M at cont (a7) */
#define TO_S(label, cont)      \
  la a7, cont;                 \
  li t0, 0x1800;               \
  csrc mstatus, t0;            \
  li t0, 0x0800;               \
  csrs mstatus, t0;            \
  la t0, label;                \
  csrw mepc, t0;               \
  mret

/* the pending LCOFIP into t0 (t1) */
#define LCOFIP(r)              \
  csrr r, mip;                 \
  li t1, LCOF;                 \
  and r, r, t1

  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  /* The counters exist if mhpmevent3 keeps an event; a trap here means they do not either */
  la t0, pass
  csrw mtvec, t0
  li t0, 1
  csrw mhpmevent3, t0
  csrr t1, mhpmevent3
  bne t0, t1, pass
  la t0, mtrap
  csrw mtvec, t0
  li s1, 0                             /* LCOFIs taken in M */
  li s2, 0                             /* ... in S */
  csrw mideleg, zero
  csrw mie, zero
  csrw mcountinhibit, zero

  /* 1. Cycles, instructions retired, nothing; mcountinhibit stops a counter */
  li t0, 1
  csrw mhpmevent3, t0
  li t0, 2
  csrw mhpmevent4, t0
  csrw mhpmevent5, zero
  li t0, 3
  csrw mhpmevent6, t0                  /* branch mispredicts (step 2) */
  csrw mhpmcounter3, zero
  li t0, 1000
  csrw mhpmcounter5, t0
  csrw mhpmcounter4, zero
  SPIN(100)
  csrr t1, mhpmcounter4
  csrr t2, mhpmcounter3
  csrr t3, mhpmcounter5
  li t4, 201
  bltu t1, t4, f1                      /* the spin's instructions ... */
  li t4, 221
  bgeu t1, t4, f1                      /* ... and the next few */
  li t4, 100
  bltu t2, t4, f1                      /* at least the spin's cycles */
  li t4, 1000
  bne t3, t4, f1
  li t0, 1 << 3
  csrw mcountinhibit, t0
  csrr t1, mhpmcounter3
  SPIN(50)
  csrr t2, mhpmcounter3
  bne t1, t2, f1                       /* stopped */
  csrw mcountinhibit, zero
  SPIN(50)
  csrr t3, mhpmcounter3
  bgeu t2, t3, f1                      /* counting again */

  /* 2. A branch on a pseudo-random bit (xorshift) mispredicts often */
  csrw mhpmcounter6, zero
  li t1, 0x2545f4914f6cdd1d
  li t2, 256
1:
  slli t3, t1, 13
  xor t1, t1, t3
  srli t3, t1, 7
  xor t1, t1, t3
  slli t3, t1, 17
  xor t1, t1, t3
  andi t3, t1, 1
  beqz t3, 2f
  addi t4, t4, 1
2:
  addi t2, t2, -1
  bnez t2, 1b
  csrr t1, mhpmcounter6
  li t2, 32
  bltu t1, t2, f2

  /* 3. A wrap sets OF and LCOFIP, and LCOFI is taken in M once; scountovf in M shows the OF */
  li t0, 1
  csrw mhpmevent3, t0
  li t0, -300
  csrw mhpmcounter3, t0
  li t0, LCOF
  csrs mie, t0
  csrsi mstatus, 8                     /* MIE */
  li t1, 100000
1:
  bnez s1, 2f
  addi t1, t1, -1
  bnez t1, 1b
  j f3
2:
  csrci mstatus, 8
  li t0, 1
  bne s1, t0, f3
  csrr t0, mhpmevent3
  bgez t0, f3                          /* OF */
  csrr t0, mhpmcounter3
  li t1, 1000000
  bgeu t0, t1, f3                      /* wrapped, counting on */
  csrr t0, SCOUNTOVF
  li t1, 1 << 3
  bne t0, t1, f3
  /* ... a second wrap while OF is set raises no LCOFIP */
  li t0, -300
  csrw mhpmcounter3, t0
  SPIN(400)
  csrr t0, mhpmcounter3
  li t1, 1000000
  bgeu t0, t1, f3                      /* it wrapped */
  LCOFIP(t0)
  bnez t0, f3
  /* ... nor does software's OF */
  li t0, 1
  csrw mhpmevent3, t0
  li t0, EV_OF | 1
  csrw mhpmevent3, t0
  SPIN(10)
  csrr t0, mhpmevent3
  bgez t0, f3                          /* OF as written */
  LCOFIP(t0)
  bnez t0, f3
  li t0, 1
  csrw mhpmevent3, t0

  /* 4. A write across bit 63 is no wrap, counting or stopped */
  li t0, EV_OF
  csrw mhpmcounter3, t0
  SPIN(20)
  csrw mhpmcounter3, zero
  SPIN(20)
  li t0, 1 << 3
  csrw mcountinhibit, t0
  li t0, EV_OF
  csrw mhpmcounter3, t0
  SPIN(20)
  csrw mhpmcounter3, zero
  SPIN(20)
  csrw mcountinhibit, zero
  csrr t0, mhpmevent3
  bltz t0, f4                          /* no OF */
  LCOFIP(t0)
  bnez t0, f4
  /* 5. A counter written as -1 wraps at its next count (perf's period 1) */
  li t0, -1
  csrw mhpmcounter3, t0
  SPIN(20)
  csrr t0, mhpmevent3
  bgez t0, f5                          /* OF */
  LCOFIP(t0)
  beqz t0, f5
  csrc mip, t1                         /* software clears LCOFIP */
  LCOFIP(t0)
  bnez t0, f5
  li t0, 1
  csrw mhpmevent3, t0

  /* 6. The mode inhibits: counter 3 counts cycles but in M, 4 but in S, 5 but in U, 6 never; read in M, S and U */
  csrr t0, misa
  li t1, (1 << 18) | (1 << 20)         /* S and U */
  and t0, t0, t1
  bne t0, t1, pass
  la t0, strap
  csrw stvec, t0
  li t0, 0x78
  csrw mcounteren, t0                  /* hpmcounter3-6 to S ... */
  csrw scounteren, t0                  /* ... and U */
  li t0, EV_MINH | 1
  csrw mhpmevent3, t0
  li t0, EV_SINH | 1
  csrw mhpmevent4, t0
  li t0, EV_UINH | 1
  csrw mhpmevent5, t0
  li t0, EV_MINH | EV_SINH | EV_UINH | 1
  csrw mhpmevent6, t0
  csrw mhpmcounter3, zero
  csrw mhpmcounter4, zero
  csrw mhpmcounter5, zero
  csrw mhpmcounter6, zero
  SPIN(50)
  csrr t1, mhpmcounter3
  bnez t1, f6
  csrr t1, mhpmcounter4
  beqz t1, f6
  csrr t1, mhpmcounter5
  beqz t1, f6
  csrr t1, mhpmcounter6
  bnez t1, f6
  TO_S(s_inh, m_inh)
s_inh:
  SPIN(10)
  csrr s3, hpmcounter3
  csrr s4, hpmcounter4
  csrr s5, hpmcounter5
  csrr s6, hpmcounter6
  SPIN(50)
  csrr t1, hpmcounter3
  bgeu s3, t1, f7                      /* counts in S */
  csrr t1, hpmcounter4
  bne s4, t1, f7                       /* not in S */
  csrr t1, hpmcounter5
  bgeu s5, t1, f7
  csrr t1, hpmcounter6
  bne s6, t1, f7
  bnez t1, f7
  li t0, 0x100
  csrc sstatus, t0                     /* SPP = U */
  la t0, u_inh
  csrw sepc, t0
  sret
u_inh:
  SPIN(10)
  csrr s3, hpmcounter3
  csrr s4, hpmcounter4
  csrr s5, hpmcounter5
  csrr s6, hpmcounter6
  SPIN(50)
  csrr t1, hpmcounter3
  bgeu s3, t1, f8                      /* counts in U */
  csrr t1, hpmcounter4
  bgeu s4, t1, f8
  csrr t1, hpmcounter5
  bne s5, t1, f8                       /* not in U */
  csrr t1, hpmcounter6
  bne s6, t1, f8
  ecall

  /* 7. scountovf: every OF in M; from S, those mcounteren gives S */
m_inh:
  li t0, EV_OF
  csrw mhpmevent3, t0
  csrw mhpmevent4, t0
  csrw mhpmevent5, zero
  csrw mhpmevent6, t0
  csrr t1, SCOUNTOVF
  li t2, 0x58                          /* 3, 4 and 6 */
  bne t1, t2, f9
  LCOFIP(t0)
  bnez t0, f9
  li t0, 0x48
  csrw mcounteren, t0                  /* 3 and 6 */
  TO_S(s_ovf, m_ovf)
s_ovf:
  csrr t1, SCOUNTOVF
  li t2, 0x48
  bne t1, t2, f9
  ecall
m_ovf:
  csrw mcounteren, zero
  TO_S(s_ovf0, m_ovf0)
s_ovf0:
  csrr t1, SCOUNTOVF
  bnez t1, f9
  ecall

  /* 8. LCOFI delegated: taken in S (sie, sip, scause), cleared through sip */
m_ovf0:
  li t0, 0x78
  csrw mcounteren, t0
  li t0, LCOF
  csrw mideleg, t0
  csrr t1, mideleg
  bne t0, t1, f10
  csrw mhpmevent4, zero
  csrw mhpmevent6, zero
  li t0, EV_MINH | 1
  csrw mhpmevent3, t0                  /* cycles but in M, OF clear */
  li t0, -300
  csrw mhpmcounter3, t0
  TO_S(s_del, m_del)
s_del:
  csrr t1, sie
  li t2, LCOF
  and t1, t1, t2
  beqz t1, f10                         /* mie's LCOFIE, delegated */
  csrsi sstatus, 2                     /* SIE */
  li t1, 100000
1:
  bnez s2, 2f
  addi t1, t1, -1
  bnez t1, 1b
  j f10
2:
  csrci sstatus, 2
  li t0, 1
  bne s2, t0, f10
  csrr t1, SCOUNTOVF
  li t2, 1 << 3
  bne t1, t2, f10
  ecall
m_del:
  li t0, 1
  bne s1, t0, f10                      /* none in M meanwhile */

  /* 9. Not delegated, LCOFI from S is taken in M */
  csrw mideleg, zero
  li t0, EV_MINH | 1
  csrw mhpmevent3, t0                  /* OF clear */
  li t0, -300
  csrw mhpmcounter3, t0
  TO_S(s_m, m_m)
s_m:
  li t1, 100000
  li t2, 2
1:
  beq s1, t2, 2f
  addi t1, t1, -1
  bnez t1, 1b
  j f11
2:
  ecall
m_m:
  li t0, 2
  bne s1, t0, f11
  li t0, 1
  bne s2, t0, f11

  /* 10. L1D load misses (a load's first only): 1,024 lines never touched; I$ misses: a block never fetched */
  li t0, 5
  csrw mhpmevent4, t0
  li t0, 8
  csrw mhpmevent5, t0
  csrw mhpmevent3, zero
  csrw mhpmevent6, zero
  csrw mhpmcounter4, zero
  csrw mhpmcounter5, zero
  li t1, 0x80200000
  li t2, 1024
1:
  ld t3, 0(t1)
  addi t1, t1, 64
  addi t2, t2, -1
  bnez t2, 1b
  jal ra, cold
  csrr t1, mhpmcounter4
  li t2, 512
  bltu t1, t2, f15
  li t2, 2048
  bgeu t1, t2, f15                     /* not again for a replay */
  csrr t1, mhpmcounter5
  beqz t1, f15

  /* 11. Data walks and fetch's walks: S through a 1 GiB identity page (Sv39), again after SFENCE.VMA */
  li t0, 0x80100000
  li t1, 0x80101000
1:
  sd zero, 0(t0)
  addi t0, t0, 8
  bltu t0, t1, 1b
  li t0, 0x80100000
  li t1, 0x200000CF                    /* root[2]: VA 0x80000000, 1 GiB identity, RWXAD */
  sd t1, 16(t0)
  li t0, 6
  csrw mhpmevent4, t0
  li t0, 7
  csrw mhpmevent5, t0
  csrw mhpmcounter4, zero
  csrw mhpmcounter5, zero
  li t0, (8 << 60) | (0x80100000 >> 12)
  csrw satp, t0
  sfence.vma
  TO_S(s_vm, m_vm)
s_vm:
  li t1, 0x80200000
  ld t2, 0(t1)
  sfence.vma
  ld t2, 0(t1)
  ecall
m_vm:
  csrw satp, zero
  sfence.vma
  csrr t3, mhpmcounter4
  csrr t4, mhpmcounter5
  li t2, 2
  bltu t3, t2, f16                     /* a walk for each load */
  bltu t4, t2, f17                     /* and for fetch, before and after SFENCE.VMA */
  .align 2
pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)
f5: TEST_FAIL(5)
f6: TEST_FAIL(6)
f7: TEST_FAIL(7)
f8: TEST_FAIL(8)
f9: TEST_FAIL(9)
f10: TEST_FAIL(10)
f11: TEST_FAIL(11)
f12: TEST_FAIL(12)
f13: TEST_FAIL(13)
f14: TEST_FAIL(14)
f15: TEST_FAIL(15)
f16: TEST_FAIL(16)
f17: TEST_FAIL(17)

  /* M handler (t5, t6): LCOFI counted, its LCOFIP cleared; an ECALL from S or U continues in M at a7 */
  .align 2
mtrap:
  csrr t5, mcause
  bgez t5, 3f
  slli t5, t5, 1
  srli t5, t5, 1
  li t6, 13
  bne t5, t6, f12
  csrr t5, mip
  li t6, LCOF
  and t5, t5, t6
  beqz t5, f12
  csrc mip, t6
  addi s1, s1, 1
  mret
3:
  li t6, 8
  beq t5, t6, 4f
  li t6, 9
  bne t5, t6, f13
4:
  csrw mepc, a7
  li t6, 0x1800
  csrs mstatus, t6                     /* MPP = M */
  mret

  /* S handler (t5, t6): the delegated LCOFI counted, its LCOFIP cleared through sip */
  .align 2
strap:
  csrr t5, scause
  bgez t5, f14
  slli t5, t5, 1
  srli t5, t5, 1
  li t6, 13
  bne t5, t6, f14
  csrr t5, sip
  li t6, LCOF
  and t5, t5, t6
  beqz t5, f14
  csrc sip, t6
  addi s2, s2, 1
  sret

  /* Step 10's block, on its own page */
  .align 12
cold:
  .rept 128
  nop
  .endr
  ret

TOHOST_DATA
