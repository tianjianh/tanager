/* M-mode and locked PMP entries (pmp-at-fill.md §1, DR-183): M is bound only by locked entries.
   - No entry locked: M loads, stores and fetches through entries that deny S everything, and where no entry matches.
     S, in Bare mode, is denied by the same entry. (DR-183's switch needs no check of M's accesses then.)
   - A locked entry elsewhere: the same accesses of M, through the unlocked entries and no match, are still allowed.
     (With a locked entry, M's accesses take the check.)
   - Locked entries that match: one read and execute only, where M's store faults; one with no permission, where M's
     load, store and fetch fault.
   Lockstep compares each step with Spike. Passes at once without S mode. Added by the SoC track for DR-183. */
#include "tg_test.h"
  .option arch, +zifencei
#define DA  0x80200000                 /* entry 1: unlocked, no permission */
#define CA  0x80201000                 /* entry 2: unlocked, no permission; a code stub */
#define CL  0x80202000                 /* entry 3: locked, RX; a code stub */
#define DL  0x80203000                 /* entry 4: locked, no permission */
#define NO  0x80300000                 /* no entry */
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
  li s9, 0

  /* Data, and the stubs at CA, CL and DL: addi s9, s9, 1; ret */
  li t0, DA
  li t1, 0xDADA
  sd t1, 0(t0)
  li t0, NO
  li t1, 0x5050
  sd t1, 0(t0)
  li t1, 0x001C8C93
  li t2, 0x00008067
  li t0, CA
  sw t1, 0(t0)
  sw t2, 4(t0)
  li t0, CL
  sw t1, 0(t0)
  sw t2, 4(t0)
  li t0, DL
  sw t1, 0(t0)
  sw t2, 4(t0)
  fence.i

  /* PMP: 0 NAPOT 2 MiB at 0x80000000 RWX (code, tohost), 1 NAPOT 4 KiB DA none, 2 NAPOT 4 KiB CA none; nothing
     locked */
  li t0, 0x2003FFFF
  csrw pmpaddr0, t0
  li t0, 0x200801FF
  csrw pmpaddr1, t0
  li t0, 0x200805FF
  csrw pmpaddr2, t0
  li t0, 0x18181F
  csrw pmpcfg0, t0

  /* No entry locked: M passes the unlocked entries and no match */
  li t0, DA
  ld t1, 0(t0)
  NONE(f1)
  li t2, 0xDADA
  bne t1, t2, f1
  li t1, 0xDADB
  sd t1, 0(t0)
  NONE(f1)
  li t0, CA
  jalr ra, 0(t0)
  NONE(f1)
  li t1, 1
  bne s9, t1, f1
  li t0, NO
  ld t1, 0(t0)
  NONE(f1)
  li t2, 0x5050
  bne t1, t2, f1
  li t1, 0x5051
  sd t1, 0(t0)
  NONE(f1)
  /* ... and S, in Bare mode, is denied by entry 1 */
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x0800
  csrs mstatus, t0                     /* MPP = S, satp Bare */
  la t0, s_code
  csrw mepc, t0
  la s11, m_after_s
  mret
s_code:
  li t0, DA
  ld t1, 0(t0)
  EXPECT(5, DA, f2)
  li t0, CA
  jalr ra, 0(t0)
  EXPECT(1, CA, f2)
  ecall
m_after_s:
  li t5, 9
  bne a6, t5, f2
  li a6, -1

  /* Entry 3 locked, RX, at CL: now M's accesses take the check, and the same ones pass */
  li t0, 0x200809FF
  csrw pmpaddr3, t0
  li t0, 0x9D18181F
  csrw pmpcfg0, t0
  li t0, DA
  ld t1, 0(t0)
  NONE(f3)
  li t2, 0xDADB
  bne t1, t2, f3
  li t1, 0xDADC
  sd t1, 0(t0)
  NONE(f3)
  li t0, CA
  jalr ra, 0(t0)
  NONE(f3)
  li t1, 2
  bne s9, t1, f3
  li t0, NO
  ld t1, 0(t0)
  NONE(f3)
  li t2, 0x5051
  bne t1, t2, f3
  sd t1, 0(t0)
  NONE(f3)
  /* ... and the locked entry binds M: run and read CL, not write it */
  li t0, CL
  jalr ra, 0(t0)
  NONE(f4)
  li t1, 3
  bne s9, t1, f4
  ld t1, 0(t0)
  NONE(f4)
  sd t1, 0(t0)
  EXPECT(7, CL, f4)

  /* Entry 4 locked, no permission, at DL: M's load, store and fetch fault */
  li t0, 0x20080DFF
  csrw pmpaddr4, t0
  li t0, 0x989D18181F
  csrw pmpcfg0, t0                     /* byte 4 added; entries 0-3 as they were (3 is locked) */
  csrr t1, pmpcfg0
  li t2, 0x989D18181F
  bne t1, t2, f5
  li t0, DL
  ld t1, 0(t0)
  EXPECT(5, DL, f5)
  sd t1, 0(t0)
  EXPECT(7, DL, f5)
  jalr ra, 0(t0)
  EXPECT(1, DL, f5)
  li t1, 3
  bne s9, t1, f5
  j pass

pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)
f5: TEST_FAIL(5)

  /* M handler: record the trap. ECALL continues in M at s11; a fetch fault returns to ra; anything else skips the
     instruction (no compressed instructions here). */
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

TOHOST_DATA
