/* PMP with MPRV (pmp-at-fill.md §6, test 4): M's loads and stores with mstatus.MPRV set take MPP's privilege.
   - MPP = S with Sv39: translated, so PMP's answer is the DTLB's cached S/U result: a 4 KiB page S may write, and one
     no entry covers (S's default deny), each load and store with its own cause.
   - MPP = M: physical, M's rules: the page S is denied, M reads and writes, as no entry is locked.
   - Then a locked read-only entry over that page binds M: M's stores fault, plain and through MPRV with MPP = M, and
     S's view through MPRV with MPP = S reads it (the PMP write flushed the cached deny).
   Each trap taken in M sets MPP to M, and its MRET leaves MPP at U, so MPP is set again before the next access.
   Lockstep compares each step with Spike. Passes at once without S mode. Added by the SoC track for DR-183. */
#include "tg_test.h"
#define PT0 0x80100000
#define PT1 0x80101000
#define PT2 0x80102000
#define D1  0x80200000                 /* PMP entry 1: RW */
#define DN  0x80300000                 /* no entry; later entry 2, locked, R */
#define EXPECT(c, tv, lbl) li t5, c; bne a6, t5, lbl; li t5, tv; bne a7, t5, lbl; li a6, -1
#define NONE(lbl) li t5, -1; bne a6, t5, lbl
/* MPRV on with MPP = S, or MPP = M; off (t3 is theirs alone) */
#define MPRV_S li t3, 0x1800; csrc mstatus, t3; li t3, 0x20800; csrs mstatus, t3
#define MPRV_M li t3, 0x21800; csrs mstatus, t3
#define MPRV_OFF li t3, 0x20000; csrc mstatus, t3

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

  li t0, PT0
  li t1, PT2 + 0x1000
1:
  sd x0, 0(t0)
  addi t0, t0, 8
  bltu t0, t1, 1b
  li s0, PT0
  li s1, PT1
  li s2, PT2
  li t0, 0x200000CF                    /* root[2]: VA 0x80000000, 1 GiB identity, RWXAD */
  sd t0, 16(s0)
  li t0, 0x20040401                    /* root[1]: VA 0x40000000 -> PT1 */
  sd t0, 8(s0)
  li t0, 0x20040801                    /* PT1[0]: VA 0x40000000 -> PT2 */
  sd t0, 0(s1)
  li t0, 0x200800C7                    /* PT2[0]: VA 0x40000000 -> D1, RWAD */
  sd t0, 0(s2)
  li t0, 0x200C00C7                    /* PT2[1]: VA 0x40001000 -> DN, RWAD (PMP decides) */
  sd t0, 8(s2)

  li t0, D1
  li t1, 0x1111
  sd t1, 0(t0)
  li t0, DN
  li t1, 0x3333
  sd t1, 0(t0)

  /* PMP: 0 NAPOT 2 MiB at 0x80000000 RWX (code, tohost, the tables), 1 NAPOT 4 KiB D1 RW; nothing covers DN */
  li t0, 0x2003FFFF
  csrw pmpaddr0, t0
  li t0, 0x200801FF
  csrw pmpaddr1, t0
  li t0, 0x1B1F
  csrw pmpcfg0, t0
  li t0, 0x8000000000080100
  csrw satp, t0
  sfence.vma

  /* MPP = S: translated, the DTLB's cached S/U result */
  MPRV_S
  li t0, 0x40000000
  ld t1, 0(t0)
  NONE(f1)
  li t2, 0x1111
  bne t1, t2, f1
  li t1, 0x1112
  sd t1, 0(t0)
  NONE(f1)
  ld t2, 0(t0)
  bne t1, t2, f1
  li t0, 0x40001000                    /* DN: S's default deny */
  ld t1, 0(t0)
  EXPECT(5, 0x40001000, f2)
  MPRV_S
  sd t1, 0(t0)
  EXPECT(7, 0x40001000, f2)
  MPRV_S
  ld t1, 8(t0)
  EXPECT(5, 0x40001008, f2)

  /* MPP = M: physical, M's rules (no entry is locked) */
  MPRV_M
  li t0, DN
  ld t1, 0(t0)
  NONE(f3)
  li t2, 0x3333
  bne t1, t2, f3
  li t1, 0x3334
  sd t1, 0(t0)
  NONE(f3)
  ld t2, 0(t0)
  bne t1, t2, f3
  MPRV_OFF

  /* A locked entry over DN, read-only: binds M */
  li t0, 0x200C01FF                    /* 2: NAPOT 4 KiB at DN, R, locked */
  csrw pmpaddr2, t0
  li t0, 0x991B1F
  csrw pmpcfg0, t0
  li t0, DN
  ld t1, 0(t0)
  NONE(f4)
  li t2, 0x3334
  bne t1, t2, f4
  sd t1, 0(t0)
  EXPECT(7, DN, f4)
  MPRV_M
  sd t1, 0(t0)
  EXPECT(7, DN, f4)
  MPRV_M
  ld t1, 0(t0)
  NONE(f4)
  li t2, 0x3334
  bne t1, t2, f4
  /* MPP = S again: the PMP write flushed DN's cached deny; S reads it now, and still may not write */
  MPRV_S
  li t0, 0x40001000
  ld t1, 0(t0)
  NONE(f5)
  li t2, 0x3334
  bne t1, t2, f5
  sd t1, 0(t0)
  EXPECT(7, 0x40001000, f5)
  MPRV_OFF
  j pass

  /* MPRV off first: tohost is written as M */
pass:
  TEST_PASS
f1: MPRV_OFF; TEST_FAIL(1)
f2: MPRV_OFF; TEST_FAIL(2)
f3: MPRV_OFF; TEST_FAIL(3)
f4: MPRV_OFF; TEST_FAIL(4)
f5: MPRV_OFF; TEST_FAIL(5)

  /* M handler: record the trap and skip the instruction (no compressed instructions here) */
  .align 2
trap:
  csrr a6, mcause
  csrr a7, mtval
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  mret

TOHOST_DATA
