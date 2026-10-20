/* Atomics (A extension, core-lsu.md): AMO arithmetic and .W sign extension, ordering against the
   store queue (an older store drains first; a younger load never forwards from the atomic's SQ
   entry), rd = x0 / rs1 / rs2, the LR/SC reservation rules, and the fault causes (misaligned,
   device, unmapped). The RTL may fail an SC that Spike lets succeed (the checker adopts it), so
   those SCs are checked for consistency with memory; SCs that must fail are checked exactly.
   Lockstep compares every value. Passes at once when misa.A is clear. Added by the core track. */
#include "tg_test.h"
  .option arch, +a
  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  csrr t0, misa
  andi t0, t0, 1
  beqz t0, pass
  la t0, trap
  csrw mtvec, t0
  li s0, 0x80100000

  /* 1. .W sign extension; younger loads read memory, not the atomic's rs2 */
  li t0, -5
  sw t0, 0(s0)
  li t1, 3
  amoadd.w t2, t1, (s0)
  li t3, -5
  bne t2, t3, f1
  lw t4, 0(s0)
  li t3, -2
  bne t4, t3, f1
  lwu t4, 0(s0)
  li t3, 0xfffffffe
  bne t4, t3, f1

  /* 2. An older store (and a byte store into the word) drains before the atomic reads; a younger
        store forwards to a younger load */
  addi s1, s0, 8
  li t0, 0x1122334455667788
  sd t0, 0(s1)
  li t1, 0x0f0f
  amoswap.d t2, t1, (s1)
  bne t2, t0, f2
  ld t3, 0(s1)
  bne t3, t1, f2
  li t0, 0x5a
  sb t0, 1(s1)
  li t1, 1
  amoadd.d.aqrl t2, t1, (s1)
  li t3, 0x5a0f
  bne t2, t3, f2
  li t0, 0x4d
  amoor.d.aq t2, t0, (s1)
  li t3, 0x5a10
  bne t2, t3, f2
  li t4, 99
  sd t4, 0(s1)
  ld t5, 0(s1)
  bne t5, t4, f2

  /* 3. min / max, signed and unsigned, .W and .D; and, xor; rd = x0 */
  addi s1, s0, 16
  li t0, -7
  sw t0, 0(s1)
  li t1, 4
  amomin.w t2, t1, (s1)
  li t3, -7
  bne t2, t3, f3
  amomax.w.rl t2, t1, (s1)
  bne t2, t3, f3
  lw t2, 0(s1)
  bne t2, t1, f3
  li t0, -1
  amominu.w t2, t0, (s1)
  bne t2, t1, f3
  amomaxu.w t2, t0, (s1)
  bne t2, t1, f3
  lw t2, 0(s1)
  bne t2, t0, f3
  addi s2, s1, 8
  li t0, 0x8000000000000000
  sd t0, 0(s2)
  li t1, 1
  amomaxu.d t2, t1, (s2)
  bne t2, t0, f3
  amomax.d t2, t1, (s2)
  bne t2, t0, f3
  ld t2, 0(s2)
  bne t2, t1, f3
  amoand.d t2, x0, (s2)
  amoxor.d x0, t0, (s2)
  ld t2, 0(s2)
  bne t2, t0, f3
  li t0, 0x00000000ffff0000
  sd t0, 0(s2)
  li t1, 0x0000ffff
  addi s3, s2, 4
  amoxor.w t2, t1, (s3)          /* the upper word: 0 ^ 0xffff */
  bnez t2, f3
  ld t2, 0(s2)
  li t3, 0x0000ffffffff0000
  bne t2, t3, f3

  /* 4. rd = rs1, rd = rs2 */
  addi s1, s0, 32
  li t0, 10
  sd t0, 0(s1)
  mv t1, s1
  li t2, 5
  amoadd.d t1, t2, (t1)
  bne t1, t0, f4
  li t2, 1
  amoadd.d t2, t2, (s1)
  li t3, 15
  bne t2, t3, f4
  ld t3, 0(s1)
  li t4, 16
  bne t3, t4, f4

  /* 5. LR/SC: a retried increment; memory agrees with every outcome */
  addi s1, s0, 64
  li t0, 100
  sd t0, 0(s1)
  li t5, 1024                    /* probe stress (--probe-rate, --bp) took up to ~30 tries */
1:
  lr.d t1, (s1)
  addi t1, t1, 1
  sc.d t2, t1, (s1)
  beqz t2, 2f
  addi t5, t5, -1
  bnez t5, 1b
  j f5
2:
  ld t3, 0(s1)
  li t4, 101
  bne t3, t4, f5
  /* an SC after an SC has no reservation: fails, no write */
  li t1, 7
  sc.d t2, t1, (s1)
  li t3, 1
  bne t2, t3, f5
  ld t3, 0(s1)
  bne t3, t4, f5
  /* LR.W sign-extends; SC.W to another word of the same 64-byte line may succeed (Za64rs) */
  li t0, 0x80000000
  sw t0, 8(s1)
  addi s2, s1, 8
  lr.w t1, (s2)
  li t3, 0xffffffff80000000
  bne t1, t3, f5
  addi s3, s1, 16
  li t1, 0x1234
  sc.w t2, t1, (s3)
  lw t3, 0(s3)
  bnez t2, 3f
  bne t3, t1, f5                 /* succeeded: written */
  j 4f
3:
  beq t3, t1, f5                 /* failed: not written */
4:
  /* SC to another line than the LR's: fails */
  lr.d t1, (s1)
  addi s3, s0, 128
  sd x0, 0(s3)
  li t1, 9
  sc.d t2, t1, (s3)
  li t3, 1
  bne t2, t3, f5
  ld t3, 0(s3)
  bnez t3, f5
  /* LR, own store to the line, SC: allowed to succeed; memory agrees */
  lr.d t1, (s1)
  li t0, 55
  sd t0, 24(s1)
  li t1, 66
  sc.d t2, t1, (s1)
  ld t3, 0(s1)
  bnez t2, 5f
  bne t3, t1, f5
  j 6f
5:
  li t4, 66
  beq t3, t4, f5
6:
  /* LR, ECALL (a trap ends the reservation in the RTL), SC: memory agrees */
  sd x0, 0(s1)
  lr.d t1, (s1)
  ecall
  li t1, 77
  sc.d t2, t1, (s1)
  ld t3, 0(s1)
  bnez t2, 7f
  bne t3, t1, f5
  j 8f
7:
  bnez t3, f5
8:

  /* 6. Faults: cause and tval; rd is not written */
#define EXPECT(c, tv, lbl) li t3, c; bne a6, t3, lbl; li t3, tv; bne a7, t3, lbl; li t3, 0x5555; bne t1, t3, lbl
  li t1, 0x5555
  li a6, -1
  addi t0, s0, 2
  amoadd.w t1, t2, (t0)
  EXPECT(6, 0x80100002, f6)
  li a6, -1
  addi t0, s0, 4
  lr.d t1, (t0)
  EXPECT(4, 0x80100004, f6)
  li a6, -1
  addi t0, s0, 1
  sc.w t1, t2, (t0)
  EXPECT(6, 0x80100001, f6)
  li a6, -1
  li t0, CLINT_MSIP
  amoswap.w t1, t2, (t0)
  EXPECT(7, CLINT_MSIP, f6)
  li a6, -1
  lr.w t1, (t0)
  EXPECT(5, CLINT_MSIP, f6)
  li a6, -1
  sc.w t1, t2, (t0)
  EXPECT(7, CLINT_MSIP, f6)
  li a6, -1
  li t0, 0x10
  amoor.d t1, t2, (t0)
  EXPECT(7, 0x10, f6)
  li a6, -1
  lr.d t1, (t0)
  EXPECT(5, 0x10, f6)
  li a6, -1
  li t0, 0x8000000000000000
  amomin.d t1, t2, (t0)
  EXPECT(7, 0x8000000000000000, f6)

pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)
f5: TEST_FAIL(5)
f6: TEST_FAIL(6)

  /* Records the cause and tval, skips the instruction */
  .align 2
trap:
  csrr a6, mcause
  csrr a7, mtval
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  mret

TOHOST_DATA
