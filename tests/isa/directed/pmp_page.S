/* The walker's per-page PMP check (DR-182; core-mmu.md §PMP): PMP region boundaries inside 4 KiB pages, 2 MiB pages
   and one 1 GiB leaf, beside a page of each size with no boundary inside. S loads and stores on both sides of each
   boundary take the right permission (lockstep compares each step with Spike). The pages with a boundary inside do
   not cache their PMP result and the others do: the walker's TG-PMPH count (simulation only) shows it. Regions, each
   read-only, in priority order:
     0x80200000-0x802FFFFF  TOR: its top splits a 2 MiB page
     0x80600000-0x806007FF  NAPOT 2 KiB: splits a 4 KiB page
     0x80700800-0x80700FFF  TOR: its base splits a 4 KiB page
     0x80A00000-0x80A0FFFF  NAPOT 64 KiB: splits a 2 MiB page
   then everything RWX. The identity gigapage the S code runs from holds them all. The gigapage without a boundary
   (PA 0xC0000000) has no memory behind it: its load passes PMP and takes the PMA's access fault. Passes at once
   without S mode. Added by the core track, for verif-2's review. */
#include "tg_test.h"
  .option arch, +a
#define V 0x01
#define R 0x02
#define W 0x04
#define X 0x08
#define A 0x40
#define D 0x80
#define PT0 0x80100000
#define PT1 0x80101000
#define PT2 0x80102000
/* a6/a7: the last trap's cause/tval (a6 = -1: none); t5, t6: handler and check scratch; s11: where an ECALL
   continues in M */
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

  /* Page tables: zero three pages, then the entries */
  li t0, PT0
  li t1, PT2 + 0x1000
1:
  sd x0, 0(t0)
  addi t0, t0, 8
  bltu t0, t1, 1b
  li s0, PT0
  li s1, PT1
  li s2, PT2
  li t0, 0x200000CF                    /* root[2]: VA 0x80000000, 1 GiB identity, RWXAD: holds both boundaries */
  sd t0, 16(s0)
  li t0, 0x300000C7                    /* root[3]: VA 0xC0000000, 1 GiB at PA 0xC0000000, RWAD: no boundary */
  sd t0, 24(s0)
  li t0, 0x20040401                    /* root[1]: VA 0x40000000 -> PT1 */
  sd t0, 8(s0)
  li t0, 0x20040801                    /* PT1[0]: VA 0x40000000 -> PT2 */
  sd t0, 0(s1)
  li t0, 0x200800C7                    /* PT1[1]: VA 0x40200000, 2 MiB at PA 0x80200000: the TOR top inside */
  sd t0, 8(s1)
  li t0, 0x201000C7                    /* PT1[2]: VA 0x40400000, 2 MiB at PA 0x80400000: no boundary */
  sd t0, 16(s1)
  li t0, 0x201800C7                    /* PT2[0]: VA 0x40000000, 4 KiB at PA 0x80600000: the 2 KiB region inside */
  sd t0, 0(s2)
  li t0, 0x201804C7                    /* PT2[1]: VA 0x40001000, 4 KiB at PA 0x80601000: no boundary */
  sd t0, 8(s2)
  li t0, 0x201C00C7                    /* PT2[2]: VA 0x40002000, 4 KiB at PA 0x80700000: a TOR base inside */
  sd t0, 16(s2)
  li t0, 0x202800C7                    /* PT1[3]: VA 0x40600000, 2 MiB at PA 0x80A00000: the 64 KiB region inside */
  sd t0, 24(s1)

  /* Data on both sides of each boundary */
  li t0, 0x80200000
  li t1, 0x2222
  sd t1, 0(t0)
  li t0, 0x80300000
  li t1, 0x3333
  sd t1, 0(t0)
  li t0, 0x80400000
  li t1, 0x4444
  sd t1, 0(t0)
  li t0, 0x80600000
  li t1, 0x6666
  sd t1, 0(t0)
  li t0, 0x80600800
  li t1, 0x6868
  sd t1, 0(t0)
  li t0, 0x80601000
  li t1, 0x6161
  sd t1, 0(t0)
  li t0, 0x80700000
  li t1, 0x7070
  sd t1, 0(t0)
  li t0, 0x80700800
  li t1, 0x7878
  sd t1, 0(t0)
  li t0, 0x80A00000
  li t1, 0xA0A0
  sd t1, 0(t0)
  li t0, 0x80A10000
  li t1, 0xA1A0
  sd t1, 0(t0)

  /* PMP: 0 OFF (the TOR base 0x80200000), 1 TOR to 0x80300000 R, 2 NAPOT 2 KiB at 0x80600000 R, 3 OFF (the TOR
     base 0x80700800), 4 TOR to 0x80701000 R, 5 NAPOT 64 KiB at 0x80A00000 R, 6 NAPOT over everything RWX; 7 OFF */
  li t0, 0x20080000
  csrw pmpaddr0, t0
  li t0, 0x200C0000
  csrw pmpaddr1, t0
  li t0, 0x201800FF
  csrw pmpaddr2, t0
  li t0, 0x201C0200
  csrw pmpaddr3, t0
  li t0, 0x201C0400
  csrw pmpaddr4, t0
  li t0, 0x20281FFF
  csrw pmpaddr5, t0
  li t0, -1
  csrw pmpaddr6, t0
  li t0, 0x001F190900190900
  csrw pmpcfg0, t0
  sfence.vma

  /* Into S with Sv39 */
  li t0, 0x8000000000080100
  csrw satp, t0
  sfence.vma
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x0800
  csrs mstatus, t0                     /* MPP = S */
  la t0, s_code
  csrw mepc, t0
  la s11, m_after_s
  mret

s_code:
  /* 4 KiB: the page with the 2 KiB read-only region inside */
  li t0, 0x40000000
  ld t1, 0(t0)
  NONE(f1)
  li t2, 0x6666
  bne t1, t2, f1
  sd t1, 0(t0)                         /* the read-only region: a store access fault */
  EXPECT(7, 0x40000000, f1)
  li t0, 0x40000800                    /* past the region, in the same page: RWX */
  li t1, 0x6869
  sd t1, 0(t0)
  NONE(f1)
  ld t2, 0(t0)
  bne t1, t2, f1
  /* 4 KiB: its neighbour, no boundary */
  li t0, 0x40001000
  ld t1, 0(t0)
  li t2, 0x6161
  bne t1, t2, f2
  li t1, 0x6162
  sd t1, 0(t0)
  NONE(f2)

  /* 2 MiB: the page with the TOR top inside (read-only below 0x80300000) */
  li t0, 0x40200000
  ld t1, 0(t0)
  NONE(f3)
  li t2, 0x2222
  bne t1, t2, f3
  sd t1, 0(t0)
  EXPECT(7, 0x40200000, f3)
  li t0, 0x40300000                    /* PA 0x80300000: past the top, in the same page: RWX */
  li t1, 0x3334
  sd t1, 0(t0)
  NONE(f3)
  ld t2, 0(t0)
  bne t1, t2, f3
  /* 2 MiB: its neighbour, no boundary */
  li t0, 0x40400000
  ld t1, 0(t0)
  li t2, 0x4444
  bne t1, t2, f4
  li t1, 0x4445
  sd t1, 0(t0)
  NONE(f4)

  /* 4 KiB: the page with a TOR base inside (read-only from 0x80700800) */
  li t0, 0x40002000
  li t1, 0x7071
  sd t1, 0(t0)                         /* below the base, in the same page: RWX */
  NONE(f6)
  ld t2, 0(t0)
  bne t1, t2, f6
  li t0, 0x40002800
  ld t1, 0(t0)
  NONE(f6)
  li t2, 0x7878
  bne t1, t2, f6
  sd t1, 0(t0)                         /* the read-only region: a store access fault */
  EXPECT(7, 0x40002800, f6)

  /* 2 MiB: the page with the 64 KiB read-only region inside */
  li t0, 0x40600000
  ld t1, 0(t0)
  NONE(f7)
  li t2, 0xA0A0
  bne t1, t2, f7
  sd t1, 0(t0)
  EXPECT(7, 0x40600000, f7)
  li t0, 0x40610000                    /* PA 0x80A10000: past the region, in the same page: RWX */
  li t1, 0xA1A1
  sd t1, 0(t0)
  NONE(f7)
  ld t2, 0(t0)
  bne t1, t2, f7

  /* 1 GiB: the identity gigapage holds every region; the same answers through it */
  li t0, 0x80200000
  li t1, 0x2223
  sd t1, 0(t0)
  EXPECT(7, 0x80200000, f5)
  li t0, 0x80600000
  sd t1, 0(t0)
  EXPECT(7, 0x80600000, f5)
  li t0, 0x80600800
  ld t1, 0(t0)
  li t2, 0x6869
  bne t1, t2, f5
  li t0, 0x80300000
  ld t1, 0(t0)
  li t2, 0x3334
  bne t1, t2, f5
  li t0, 0x80700800
  sd t1, 0(t0)
  EXPECT(7, 0x80700800, f5)
  li t0, 0x80A00000
  sd t1, 0(t0)
  EXPECT(7, 0x80A00000, f5)
  li t0, 0x80A10000
  ld t1, 0(t0)
  li t2, 0xA1A1
  bne t1, t2, f5
  li t0, 0x80700000
  ld t1, 0(t0)
  li t2, 0x7071
  bne t1, t2, f5
  /* 1 GiB: its neighbour, no boundary. No memory may be there: lockstep checks whatever the load does */
  li t0, 0xC0000000
  ld t1, 0(t0)
  li a6, -1
  ecall

m_after_s:
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
f7: TEST_FAIL(7)

  /* M handler: record the trap. ECALL continues in M at s11; anything else skips the instruction (no compressed
     instructions here). */
  .align 2
trap:
  csrr a6, mcause
  csrr a7, mtval
  li t6, 9
  beq a6, t6, 2f
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  mret
2:
  li t6, 0x1800
  csrs mstatus, t6                     /* MPP = M */
  csrw mepc, s11
  mret

TOHOST_DATA
