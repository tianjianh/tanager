/* Sv39 (core-mmu.md): M builds page tables, then S and U run through them. Covers a 1 GiB
   identity superpage (S code), 2 MiB superpages (aligned and misaligned), 4 KiB user pages, the
   U/SUM/MXR rules, Svade (A, D), W without R, reserved bits, a non-leaf with A, an invalid PTE,
   a non-canonical address, a PTE outside memory (access fault), atomics under translation,
   SFENCE.VMA and satp changes (both flush), MPRV, and fetch faults (an S fetch of a U page, a U
   fetch of a non-X page and of an unmapped page). Every trap goes to M, which records mcause and
   mtval. Lockstep compares each step with Spike. Passes at once without S mode. Added by the
   core track. */
#include "tg_test.h"
  .option arch, +a
#define V 0x01
#define R 0x02
#define W 0x04
#define X 0x08
#define U 0x10
#define A 0x40
#define D 0x80
#define PT0 0x80100000
#define PT1 0x80101000
#define PT2 0x80102000
/* a6/a7: the last trap's cause/tval (a6 = -1: none); t5, t6: handler and check scratch;
   s11: where an ECALL continues in M; s10: the user code's result */
#define EXPECT(c, tv, lbl) li t5, c; bne a6, t5, lbl; li t5, tv; bne a7, t5, lbl; li a6, -1
#define NONE(lbl) li t5, -1; bne a6, t5, lbl

  .section .text.init, "ax"
  .globl _start
_start:
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
  li t0, 0x200000CF                    /* root[2]: VA 0x80000000, 1 GiB identity, RWXAD */
  sd t0, 16(s0)
  li t0, 0x20040401                    /* root[1]: VA 0x40000000 -> PT1 */
  sd t0, 8(s0)
  li t0, 0x00000001                    /* root[3]: VA 0xC0000000 -> a table at PA 0 (no memory) */
  sd t0, 24(s0)
  li t0, 0x20040801                    /* PT1[0]: -> PT2 */
  sd t0, 0(s1)
  li t0, 0x201000C7                    /* PT1[1]: VA 0x40200000, 2 MiB at PA 0x80400000 */
  sd t0, 8(s1)
  li t0, 0x201004C7                    /* PT1[2]: VA 0x40400000, misaligned 2 MiB superpage */
  sd t0, 16(s1)
  li t0, 0x20040841                    /* PT1[3]: VA 0x40600000, a non-leaf with A */
  sd t0, 24(s1)
  la t0, ucode                         /* PT2[0]: VA 0x40000000, the user code, RXUA */
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, V|R|X|U|A
  sd t0, 0(s2)
  li t0, 0x200800D7                    /* PT2[1]: 0x40001000 -> 0x80200000 RWUAD */
  sd t0, 8(s2)
  li t0, 0x20080453                    /* PT2[2]: 0x40002000 -> 0x80201000 RUA (read-only) */
  sd t0, 16(s2)
                                       /* PT2[3]: 0x40003000 invalid */
  li t0, 0x20080897                    /* PT2[4]: 0x40004000 -> 0x80202000 RWUD, A = 0 */
  sd t0, 32(s2)
  li t0, 0x20080C57                    /* PT2[5]: 0x40005000 -> 0x80203000 RWUA, D = 0 */
  sd t0, 40(s2)
  li t0, 0x20081059                    /* PT2[6]: 0x40006000 -> 0x80204000 XUA (execute-only) */
  sd t0, 48(s2)
  li t0, 0x200814C7                    /* PT2[7]: 0x40007000 -> 0x80205000 RWAD, S page */
  sd t0, 56(s2)
  li t0, 0x200818D5                    /* PT2[8]: 0x40008000 W without R */
  sd t0, 64(s2)
  li t0, 0x0040000020081CD7            /* PT2[9]: 0x40009000 reserved bit 54 */
  sd t0, 72(s2)

  /* Data behind the pages (physical) */
  li t0, 0x80200000
  li t1, 0x1111
  sd t1, 0(t0)
  li t0, 0x80201000
  li t1, 0x2222
  sd t1, 0(t0)
  li t0, 0x80203000
  li t1, 0x3333
  sd t1, 0(t0)
  li t0, 0x80204000
  li t1, 0x4444
  sd t1, 0(t0)
  li t0, 0x80205000
  li t1, 0x5555
  sd t1, 0(t0)
  li t0, 0x80208000
  li t1, 0x8888
  sd t1, 0(t0)
  li t0, 0x80400100
  li t1, 0x6666
  sd t1, 0(t0)

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
  /* U page from S without SUM: fault; with SUM: loads, stores and atomics work */
  li t0, 0x40001000
  ld t1, 0(t0)
  EXPECT(13, 0x40001000, f1)
  li t1, 1 << 18
  csrs sstatus, t1                     /* SUM */
  ld t1, 0(t0)
  li t2, 0x1111
  bne t1, t2, f1
  li t1, 0x1122334455667788
  sd t1, 0(t0)
  li t2, 1
  amoadd.d t3, t2, (t0)
  bne t3, t1, f1
  ld t3, 0(t0)
  addi t1, t1, 1
  bne t3, t1, f1
  NONE(f1)
  /* S never executes a U page */
  li t0, 0x40000000
  jalr ra, 0(t0)
  EXPECT(12, 0x40000000, f1)

  /* Superpages */
  li t0, 0x40200100
  ld t1, 0(t0)
  li t2, 0x6666
  bne t1, t2, f2
  NONE(f2)
  li t0, 0x40400100                    /* misaligned superpage */
  ld t1, 0(t0)
  EXPECT(13, 0x40400100, f2)
  li t0, 0x40600000                    /* non-leaf with A */
  sd t1, 0(t0)
  EXPECT(15, 0x40600000, f2)

  /* Permissions and Svade */
  li t0, 0x40003000                    /* invalid */
  ld t1, 0(t0)
  EXPECT(13, 0x40003000, f3)
  li t0, 0x40002000                    /* read-only: loads, not stores or AMOs */
  ld t1, 0(t0)
  li t2, 0x2222
  bne t1, t2, f3
  sd t1, 0(t0)
  EXPECT(15, 0x40002000, f3)
  amoswap.d t1, t2, (t0)
  EXPECT(15, 0x40002000, f3)
  li t0, 0x40004008                    /* A = 0 */
  ld t1, 0(t0)
  EXPECT(13, 0x40004008, f3)
  li t0, 0x40005000                    /* D = 0: loads only */
  ld t1, 0(t0)
  li t2, 0x3333
  bne t1, t2, f3
  sw t1, 4(t0)
  EXPECT(15, 0x40005004, f3)
  sc.d t1, t2, (t0)
  EXPECT(15, 0x40005000, f3)
  li t0, 0x40006000                    /* execute-only: loads with MXR */
  ld t1, 0(t0)
  EXPECT(13, 0x40006000, f3)
  lr.d t1, (t0)
  EXPECT(13, 0x40006000, f3)
  li t1, 1 << 19
  csrs sstatus, t1                     /* MXR */
  ld t1, 0(t0)
  li t2, 0x4444
  bne t1, t2, f3
  li t1, 1 << 19
  csrc sstatus, t1
  li t0, 0x40008000                    /* W without R */
  ld t1, 0(t0)
  EXPECT(13, 0x40008000, f3)
  li t0, 0x40009000                    /* reserved bit */
  ld t1, 0(t0)
  EXPECT(13, 0x40009000, f3)
  li t0, 0x0000800000000000            /* non-canonical */
  ld t1, 0(t0)
  EXPECT(13, 0x0000800000000000, f3)
  li t0, 0xC0000000                    /* the table is not in memory: access fault */
  lw t1, 0(t0)
  EXPECT(5, 0xC0000000, f3)
  NONE(f3)

  /* SFENCE.VMA and satp writes take a changed PTE */
  li t0, 0x40001000
  ld t1, 0(t0)                         /* the old mapping is in the DTLB now */
  li t2, PT2 + 8
  li t3, 0x200820D7                    /* -> 0x80208000 */
  sd t3, 0(t2)
  sfence.vma
  ld t1, 0(t0)
  li t4, 0x8888
  bne t1, t4, f4
  li t3, 0x200800D7                    /* back to 0x80200000 */
  sd t3, 0(t2)
  li t3, 0x8000100000080100            /* ASID 1: a satp change flushes the TLBs too (Spike) */
  csrw satp, t3
  ld t1, 0(t0)
  li t4, 0x1122334455667789
  bne t1, t4, f4
  NONE(f4)
  ecall                                /* back to M at m_after_s */

m_after_s:
  li t5, 9
  bne a6, t5, f4
  li a6, -1
  /* MPRV: M's loads and stores translate as S */
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x0800
  csrs mstatus, t0                     /* MPP = S */
  li t0, 1 << 17
  csrs mstatus, t0                     /* MPRV */
  li t0, 0x40200100
  ld t1, 0(t0)
  li t2, 0x6666
  bne t1, t2, f5
  li t0, 0x40001000                    /* a U page: SUM is still set */
  ld t1, 0(t0)
  li t2, 0x1122334455667789
  bne t1, t2, f5
  li t0, 1 << 17
  csrc mstatus, t0
  NONE(f5)

  /* Into U at the user code */
  li t0, 0x1800
  csrc mstatus, t0                     /* MPP = U */
  li t0, 0x40000000
  csrw mepc, t0
  la s11, m_after_u
  li s10, -1
  mret

m_after_u:
  li t5, 8
  bne a6, t5, f6
  bnez s10, f6

pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)
f5: TEST_FAIL(5)
f6: TEST_FAIL(6)

  /* M handler: record the trap. ECALL continues in M at s11; a fetch fault returns to ra;
     anything else skips the instruction (no compressed instructions here). */
  .align 2
trap:
  csrr a6, mcause
  csrr a7, mtval
  li t6, 8
  beq a6, t6, 2f
  li t6, 9
  beq a6, t6, 2f
  li t6, 12
  beq a6, t6, 3f
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

  /* User code, run at VA 0x40000000: s10 = 0 when every check passes */
  .align 12
ucode:
  li s10, 1
  li a6, -1
  li t0, 0x40001000                    /* its own data page */
  ld t1, 0(t0)
  li t2, 0x1122334455667789
  bne t1, t2, 9f
  li s10, 2
  li t0, 0x40007000                    /* an S page */
  ld t1, 0(t0)
  li t5, 13
  bne a6, t5, 9f
  bne a7, t0, 9f
  li a6, -1
  li s10, 3
  li t0, 0x40002000                    /* read-only */
  sd t1, 0(t0)
  li t5, 15
  bne a6, t5, 9f
  bne a7, t0, 9f
  li a6, -1
  li s10, 4
  li t0, 0x40001000                    /* no X */
  jalr ra, 0(t0)
  li t5, 12
  bne a6, t5, 9f
  bne a7, t0, 9f
  li a6, -1
  li s10, 5
  li t0, 0x40003000                    /* unmapped */
  jalr ra, 0(t0)
  li t5, 12
  bne a6, t5, 9f
  bne a7, t0, 9f
  li a6, -1
  li s10, 6
  li t0, 0x40001008                    /* atomics on a user page */
  sd x0, 0(t0)
  li t1, 5
  amoadd.d t2, t1, (t0)
  bnez t2, 9f
  lr.d t2, (t0)
  addi t2, t2, 1
  sc.d t3, t2, (t0)
  ld t4, 0(t0)
  beqz t3, 8f
  li t2, 5                             /* the SC failed: memory unchanged */
8:
  bne t4, t2, 9f
  li t5, -1
  bne a6, t5, 9f
  li s10, 0
9:
  ecall

TOHOST_DATA
