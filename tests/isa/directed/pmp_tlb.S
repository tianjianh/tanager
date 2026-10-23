/* The TLBs' cached PMP results (DR-182, DR-183; pmp-at-fill.md §6, tests 5, 7 and 8): S runs with Sv39 on 4 KiB pages
   whose PMP result the TLBs cache.
   - PMP writes: S reads a page and runs a code stub on another, so both TLBs cache them. M then takes R and W from the
     data page and X from the code page, without SFENCE.VMA, and S's next load and fetch fault; M gives them back and
     both work again. A second data page takes the same write with SFENCE.VMA.
   - No match: a page no entry covers caches S's default deny. Its load, store and fetch take access faults with their
     own causes, the second load from the cached result.
   - Page tables: a walk whose second-level table sits where PMP denies S reads takes the access fault of the access
     that walked (load 5, store 7, fetch 1).
   Lockstep compares each step with Spike. Passes at once without S mode. Added by the SoC track for DR-183. */
#include "tg_test.h"
  .option arch, +zifencei
#define PT0 0x80100000
#define PT1 0x80101000
#define PT2 0x80102000
#define D1  0x80200000                 /* PMP entry 1: RW, then none, then RW (no SFENCE.VMA) */
#define D2  0x80201000                 /* entry 2: RW, then none with SFENCE.VMA */
#define C1  0x80202000                 /* entry 3: RX, then R, then RX: a code stub */
#define DN  0x80300000                 /* no entry: S is denied */
#define PT3 0x80301000                 /* a second-level table where S may not read */
/* a6/a7: the last trap's cause/tval (a6 = -1: none); t5, t6: handler and check scratch; s11: where an ECALL
   continues in M; s9: the stub's count */
#define EXPECT(c, tv, lbl) li t5, c; bne a6, t5, lbl; li t5, tv; bne a7, t5, lbl; li a6, -1
#define NONE(lbl) li t5, -1; bne a6, t5, lbl
/* From M into S at sl, with the next ECALL continuing in M at ml */
#define TO_S(sl, ml) li t0, 0x1800; csrc mstatus, t0; li t0, 0x0800; csrs mstatus, t0; la t0, sl; csrw mepc, t0; \
                     la s11, ml; mret

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

  /* Page tables: zero PT0-PT2 and PT3, then the entries */
  li t0, PT0
  li t1, PT2 + 0x1000
1:
  sd x0, 0(t0)
  addi t0, t0, 8
  bltu t0, t1, 1b
  li t0, PT3
  li t1, PT3 + 0x1000
1:
  sd x0, 0(t0)
  addi t0, t0, 8
  bltu t0, t1, 1b
  li s0, PT0
  li s1, PT1
  li s2, PT2
  li t0, 0x200000CF                    /* root[2]: VA 0x80000000, 1 GiB identity, RWXAD (the S code) */
  sd t0, 16(s0)
  li t0, 0x20040401                    /* root[1]: VA 0x40000000 -> PT1 */
  sd t0, 8(s0)
  li t0, 0x200C0401                    /* root[0]: VA 0 -> PT3, which S may not read */
  sd t0, 0(s0)
  li t0, 0x20040801                    /* PT1[0]: VA 0x40000000 -> PT2 */
  sd t0, 0(s1)
  li t0, 0x200800C7                    /* PT2[0]: VA 0x40000000 -> D1, RWAD */
  sd t0, 0(s2)
  li t0, 0x200804C7                    /* PT2[1]: VA 0x40001000 -> D2, RWAD */
  sd t0, 8(s2)
  li t0, 0x200C00CF                    /* PT2[2]: VA 0x40002000 -> DN, RWXAD (PMP denies S) */
  sd t0, 16(s2)
  li t0, 0x2008084B                    /* PT2[3]: VA 0x40003000 -> C1, RXA */
  sd t0, 24(s2)

  /* Data, and the stub at C1: addi s9, s9, 1; ret */
  li t0, D1
  li t1, 0x1111
  sd t1, 0(t0)
  li t0, D2
  li t1, 0x2222
  sd t1, 0(t0)
  li t0, C1
  li t1, 0x001C8C93
  sw t1, 0(t0)
  li t1, 0x00008067
  sw t1, 4(t0)
  fence.i

  /* PMP: 0 NAPOT 2 MiB at 0x80000000 RWX (code, tohost, PT0-PT2), 1 NAPOT 4 KiB D1 RW, 2 NAPOT 4 KiB D2 RW,
     3 NAPOT 4 KiB C1 RX; 4-7 OFF. Nothing covers DN or PT3 */
  li t0, 0x2003FFFF
  csrw pmpaddr0, t0
  li t0, 0x200801FF
  csrw pmpaddr1, t0
  li t0, 0x200805FF
  csrw pmpaddr2, t0
  li t0, 0x200809FF
  csrw pmpaddr3, t0
  li t0, 0x1D1B1B1F
  csrw pmpcfg0, t0
  sfence.vma

  /* Into S with Sv39 */
  li t0, 0x8000000000080100
  csrw satp, t0
  sfence.vma
  TO_S(s_a1, m_a1)

  /* PMP writes without SFENCE.VMA: both TLBs cache D1 and C1, M takes their permissions away, then gives them back */
s_a1:
  li t0, 0x40000000
  ld t1, 0(t0)
  NONE(f1)
  li t2, 0x1111
  bne t1, t2, f1
  li t0, 0x40003000
  jalr ra, 0(t0)
  NONE(f1)
  li t1, 1
  bne s9, t1, f1
  ecall
m_a1:
  li t5, 9
  bne a6, t5, f1
  li a6, -1
  li t0, 0x191B181F                    /* entry 1: none, entry 3: R; no SFENCE.VMA */
  csrw pmpcfg0, t0
  TO_S(s_a2, m_a2)
s_a2:
  li t0, 0x40000000
  ld t1, 0(t0)
  EXPECT(5, 0x40000000, f2)
  sd t1, 0(t0)
  EXPECT(7, 0x40000000, f2)
  li t0, 0x40003000
  jalr ra, 0(t0)
  EXPECT(1, 0x40003000, f2)
  li t1, 1
  bne s9, t1, f2
  ecall
m_a2:
  li t5, 9
  bne a6, t5, f2
  li a6, -1
  li t0, 0x1D1B1B1F                    /* back to RW and RX; no SFENCE.VMA */
  csrw pmpcfg0, t0
  TO_S(s_a3, m_a3)
s_a3:
  li t0, 0x40000000
  ld t1, 0(t0)
  NONE(f3)
  li t2, 0x1111
  bne t1, t2, f3
  li t1, 0x1112
  sd t1, 0(t0)
  NONE(f3)
  li t0, 0x40003000
  jalr ra, 0(t0)
  NONE(f3)
  li t1, 2
  bne s9, t1, f3

  /* A PMP write with SFENCE.VMA: D2 cached, then denied */
  li t0, 0x40001000
  ld t1, 0(t0)
  NONE(f4)
  li t2, 0x2222
  bne t1, t2, f4
  ecall
m_a3:
  li t5, 9
  bne a6, t5, f4
  li a6, -1
  li t0, 0x1D181B1F                    /* entry 2: none */
  csrw pmpcfg0, t0
  sfence.vma
  TO_S(s_b, m_b)
s_b:
  li t0, 0x40001000
  ld t1, 0(t0)
  EXPECT(5, 0x40001000, f4)
  sd t1, 0(t0)
  EXPECT(7, 0x40001000, f4)

  /* No match: DN's page caches S's default deny */
  li t0, 0x40002000
  ld t1, 0(t0)
  EXPECT(5, 0x40002000, f5)
  sd t1, 0(t0)
  EXPECT(7, 0x40002000, f5)
  jalr ra, 0(t0)
  EXPECT(1, 0x40002000, f5)
  ld t1, 8(t0)
  EXPECT(5, 0x40002008, f5)

  /* A page table S may not read: the walk's fault takes the access's cause */
  li t0, 0x10
  ld t1, 0(t0)
  EXPECT(5, 0x10, f6)
  sd t1, 0(t0)
  EXPECT(7, 0x10, f6)
  jalr ra, 0(t0)
  EXPECT(1, 0x10, f6)
  ecall
m_b:
  li t5, 9
  bne a6, t5, f6
  li a6, -1
  j pass

pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)
f5: TEST_FAIL(5)
f6: TEST_FAIL(6)

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
