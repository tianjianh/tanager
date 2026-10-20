/* PMP (core-mmu.md): M programs eight entries (NAPOT 8 B / 16 B / 4 KiB / 32 KiB, NA4, TOR and a
   locked entry) with no catch-all, then S runs in Bare mode: loads, stores and atomics allowed
   and denied, an 8-byte access that only half matches an NA4 entry, addresses no entry matches,
   a fetch from a non-executable region, and a fetch block whose first two words are executable
   and the rest not (the front end must run them and fault at the third word). Back in M: a
   locked entry binds M, an unlocked one does not. Lockstep compares each step with Spike.
   Passes at once without S mode. Added by the core track. */
#include "tg_test.h"
  .option arch, +a
#define EXPECT(c, tv, lbl) li t5, c; bne a6, t5, lbl; li t5, tv; bne a7, t5, lbl; li a6, -1
#define NONE(lbl) li t5, -1; bne a6, t5, lbl

  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  csrr t0, misa
  li t1, 1 << 18                       /* S */
  and t0, t0, t1
  beqz t0, pass
  la t0, trap
  csrw mtvec, t0
  li a6, -1

  li t0, 0x80100000
  li t1, 0xAAAA
  sd t1, 0(t0)
  li t0, 0x80101000
  li t1, 0x12345678
  sw t1, 0(t0)
  li t0, 0x80102008
  li t1, 0xBBBB
  sd t1, 0(t0)
  li t0, 0x80103000
  li t1, 0xCCCC
  sd t1, 0(t0)

  li t0, 0x20001000                    /* 0: NAPOT 8 B at 0x80004000, X */
  csrw pmpaddr0, t0
  li t0, 0x20001001                    /* 1: NAPOT 16 B at 0x80004000, no access */
  csrw pmpaddr1, t0
  li t0, 0x20000FFF                    /* 2: NAPOT 32 KiB at 0x80000000 (code), RX */
  csrw pmpaddr2, t0
  li t0, 0x200401FF                    /* 3: NAPOT 4 KiB at 0x80100000, R */
  csrw pmpaddr3, t0
  li t0, 0x20040400                    /* 4: NA4 at 0x80101000, RW */
  csrw pmpaddr4, t0
  li t0, 0x20040800                    /* 5: TOR base 0x80102000 (off) */
  csrw pmpaddr5, t0
  li t0, 0x20040804                    /* 6: TOR [0x80102000, 0x80102010), RW */
  csrw pmpaddr6, t0
  li t0, 0x20040DFF                    /* 7: NAPOT 4 KiB at 0x80103000, R, locked */
  csrw pmpaddr7, t0
  li t0, 0x990B0013191D181C
  csrw pmpcfg0, t0
  csrr t1, pmpcfg0
  bne t0, t1, f1

  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x0800
  csrs mstatus, t0                     /* MPP = S, satp Bare */
  la t0, s_code
  csrw mepc, t0
  la s11, m_after_s
  mret

s_code:
  li t0, 0x80100000                    /* R only: loads and LR; no stores, AMOs or SC */
  ld t1, 0(t0)
  li t2, 0xAAAA
  bne t1, t2, f2
  lr.d t1, (t0)
  NONE(f2)
  sd t1, 0(t0)
  EXPECT(7, 0x80100000, f2)
  amoadd.d t1, t2, (t0)
  EXPECT(7, 0x80100000, f2)
  sc.d t1, t2, (t0)
  EXPECT(7, 0x80100000, f2)
  li t0, 0x80101000                    /* NA4: words yes, a dword half matches: no */
  lw t1, 0(t0)
  li t2, 0x12345678
  bne t1, t2, f3
  sw t1, 0(t0)
  NONE(f3)
  ld t1, 0(t0)
  EXPECT(5, 0x80101000, f3)
  lw t1, 4(t0)
  EXPECT(5, 0x80101004, f3)
  li t0, 0x80102008                    /* TOR */
  ld t1, 0(t0)
  li t2, 0xBBBB
  bne t1, t2, f3
  sd t1, -8(t0)
  NONE(f3)
  ld t1, 8(t0)
  EXPECT(5, 0x80102010, f3)
  li t0, 0x80200000                    /* no entry: S is denied */
  ld t1, 0(t0)
  EXPECT(5, 0x80200000, f3)

  /* Fetch: a region without X, and a block executable for two words only */
  li t0, 0x80100000
  jalr ra, 0(t0)
  EXPECT(1, 0x80100000, f4)
  li s9, 0
  la t0, fx
  jalr ra, 0(t0)
  EXPECT(1, 0x80004008, f4)
  li t1, 2
  bne s9, t1, f4
  ecall                                /* back to M at m_after_s */

m_after_s:
  li t5, 9
  bne a6, t5, f5
  li a6, -1
  li t0, 0x80103000                    /* locked, R: binds M */
  ld t1, 0(t0)
  li t2, 0xCCCC
  bne t1, t2, f5
  sd t1, 0(t0)
  EXPECT(7, 0x80103000, f5)
  li t0, 0x80100000                    /* unlocked R only: M writes */
  li t1, 0x7777
  sd t1, 0(t0)
  ld t2, 0(t0)
  bne t1, t2, f5
  NONE(f5)

pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)
f5: TEST_FAIL(5)

  /* M handler: record the trap. ECALL continues in M at s11; a fetch fault returns to ra;
     anything else skips the instruction. */
  .align 2
trap:
  csrr a6, mcause
  csrr a7, mtval
  li t6, 9
  beq a6, t6, 2f
  li t6, 1
  beq a6, t6, 3f
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  mret
2:
  li t6, 0x1800
  csrs mstatus, t6                     /* MPP = M */
  csrw mepc, s11
  mret
3:
  csrw mepc, ra
  mret

  /* At 0x80004000: words 0 and 1 executable (entry 0), words 2 and 3 not (entry 1) */
  .align 14
fx:
  addi s9, s9, 1
  addi s9, s9, 1
  ret
  nop

TOHOST_DATA
