/* Program counters at Sv39 width (pc40; DR-195, core-pipeline.md §8.6): redirects to pcs outside Sv39's range and
   runs at its edges, whose faults the pipeline's 40-bit pcs must report in full (a bad redirect's value stays in the
   ROB's bpc_q, one a thread). Every trap goes to M, which records mepc, mcause and mtval; a fetch fault returns to ra.
   - M, Bare: a JALR to eight targets above the physical address space and outside Sv39's range in each form (bit 63
     alone, bit 39 alone, bit 38 alone, bits 63:39 over a clear bit 38, mixed, 2^34, a canonical negative, the top of
     the lower half), and mret to three: access faults, mepc and mtval the target.
   - S, Sv39, non-canonical targets (page faults): mret into S, a JALR to six, sret, a trap to stvec (an illegal
     instruction delegated to S) and SSI through a vectored stvec whose base + 4 crosses into 0x40_0000_0000.
   - S at the edges of Sv39's range, through 4 KiB pages at 0x3F_FFFF_F000, 0xFFFF_FFC0_0000_0000,
     0xFFFF_FFFF_FFFF_F000 and 0: the instruction at 0x3F_FFFF_FFFC runs into 0x40_0000_0000; a straddler at
     0x3F_FFFF_FFFE faults on its second half (mepc 0x3F_FFFF_FFFE, mtval 0x40_0000_0000); a JAL and a branch cross
     up from 0x3F_FFFF_FFE8 and down from 0xFFFF_FFC0_0000_0020; auipc and a link are read back at both edges; at the
     top a JAL wraps to 0x10 and another back, and a straddler at 0xFFFF_FFFF_FFFF_FFFE takes its second half from 0.
   - S, Bare: a JALR, sret, a trap to stvec and SSI through a vectored stvec, each above the physical address space.
   - With hart 1 (HART1=1): from the start hart 1 jumps to its own bad targets between data-dependent branches (about
     half mispredict), and at the end hart 0 does the same with others, so each hart's flushes overwrite the ROB's one
     flush_pc between the other's bad redirect and its trap.
   A bad mtvec isn't tested: its fault re-enters it. A step into a bad pc and dret to one are in debug.S. Lockstep
   checks each record against Spike. Without S mode only the M parts and the two-hart part run; without C, no
   straddlers. A failed check's code is the case number (s9). Added by the core track. */
#include "tg_test.h"
  .option norelax
#define ROOT 0x80100000                 /* the page tables: the root, then a level-1 and a level-0 table per edge */
#define L1A  0x80101000                 /* VA 0x3F_FFFF_F000 */
#define L0A  0x80102000
#define L1B  0x80103000                 /* VA 0xFFFF_FFC0_0000_0000 */
#define L0B  0x80104000
#define L1C  0x80105000                 /* VA 0xFFFF_FFFF_FFFF_F000 */
#define L0C  0x80106000
#define L1D  0x80107000                 /* VA 0 */
#define L0D  0x80108000
#define NL(pa) ((((pa) >> 12) << 10) | 0x01)
#define LEAF 0x4B                       /* V, R, X, A: S code */
#define SATP_SV39 (0x8000000000000000 | (ROOT >> 12))

/* s9: the case; a5/a6/a7: the last trap's mepc/mcause/mtval (a6 = -1: none); t5, t6: the checks and the handler */
#define CASE(n) li s9, n
#define FAR_NE(a, b) beq a, b, 7f; j fail; 7:
#define EXPECT(c, v) li t5, c; FAR_NE(a6, t5); li t5, v; FAR_NE(a5, t5); FAR_NE(a7, t5); li a6, -1
#define EXPECT2(c, e, v) li t5, c; FAR_NE(a6, t5); li t5, e; FAR_NE(a5, t5); li t5, v; FAR_NE(a7, t5); li a6, -1
#define NONE li t5, -1; FAR_NE(a6, t5)
#define IS(r, v) li t5, v; FAR_NE(r, t5)
/* A JALR through t1 (not a link register: no return-stack pop); the fetch fault returns to the next line */
#define JUMP(v) la ra, 1f; li t1, v; jalr x0, 0(t1); 1:
#define MRET_TO(v) li t0, 0x1800; csrs mstatus, t0; la ra, 1f; li t1, v; csrw mepc, t1; mret; 1:
#define SRET_TO(v) li t0, 0x100; csrs sstatus, t0; la ra, 1f; li t1, v; csrw sepc, t1; sret; 1:
/* Map the edge page at VA 0x3F_FFFF_F000 (slot: its leaf) to the code page at pa */
#define PAGE(slot, pa) srli pa, pa, 12; slli pa, pa, 10; ori pa, pa, LEAF; sd pa, 0(slot); sfence.vma

  .section .text.init, "ax"
  .globl _start
_start:
  csrr t0, mhartid
  beqz t0, 2f
  li t1, 1
  beq t0, t1, hart1
1:
  wfi
  j 1b
2:
  la t0, trap
  csrw mtvec, t0
  li a6, -1

  /* 1. M, Bare: a JALR above the physical address space */
  CASE(1)
  JUMP(0x8000000000000000)
  EXPECT(1, 0x8000000000000000)
  CASE(2)
  JUMP(0x0000008000000000)
  EXPECT(1, 0x0000008000000000)
  CASE(3)
  JUMP(0x0000004000000000)
  EXPECT(1, 0x0000004000000000)
  CASE(4)
  JUMP(0xFFFFFFBFFFFFFFF0)
  EXPECT(1, 0xFFFFFFBFFFFFFFF0)
  CASE(5)
  JUMP(0x5555555555555554)
  EXPECT(1, 0x5555555555555554)
  CASE(6)
  JUMP(0x0000000400000000)
  EXPECT(1, 0x0000000400000000)
  CASE(7)
  JUMP(0xFFFFFFFFFFFFF000)
  EXPECT(1, 0xFFFFFFFFFFFFF000)
  CASE(8)
  JUMP(0x0000003FFFFFFFFC)
  EXPECT(1, 0x0000003FFFFFFFFC)
  /* 2. mret in M */
  CASE(10)
  MRET_TO(0x8000000000000000)
  EXPECT(1, 0x8000000000000000)
  CASE(11)
  MRET_TO(0x0000008000000000)
  EXPECT(1, 0x0000008000000000)
  CASE(12)
  MRET_TO(0x0000000400000000)
  EXPECT(1, 0x0000000400000000)

  csrr t0, misa
  li t1, 1 << 18                       /* S */
  and t0, t0, t1
  beqz t0, two_harts
  /* Page tables: zero nine pages, then the entries */
  li t0, ROOT
  li t1, ROOT + 9 * 0x1000
1:
  sd x0, 0(t0)
  addi t0, t0, 8
  bltu t0, t1, 1b
  li s0, ROOT
  li t0, 0x200000CF                    /* root[2]: VA 0x80000000, 1 GiB identity, RWXAD */
  sd t0, 16(s0)
  li t0, NL(L1D)                       /* root[0] */
  sd t0, 0(s0)
  li t0, NL(L1A)                       /* root[255] */
  sd t0, 255 * 8(s0)
  li t0, NL(L1B)                       /* root[256] */
  li t1, ROOT + 256 * 8
  sd t0, 0(t1)
  li t0, NL(L1C)                       /* root[511] */
  li t1, ROOT + 511 * 8
  sd t0, 0(t1)
  li t0, NL(L0A)
  li t1, L1A + 511 * 8
  sd t0, 0(t1)
  li t0, NL(L0B)
  li t1, L1B
  sd t0, 0(t1)
  li t0, NL(L0C)
  li t1, L1C + 511 * 8
  sd t0, 0(t1)
  li t0, NL(L0D)
  li t1, L1D
  sd t0, 0(t1)
  la t0, npage                         /* the leaves; S maps VA 0x3F_FFFF_F000 for each test */
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, LEAF
  li t1, L0B
  sd t0, 0(t1)
  la t0, tpage
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, LEAF
  li t1, L0C + 511 * 8
  sd t0, 0(t1)
  la t0, zpage
  srli t0, t0, 12
  slli t0, t0, 10
  ori t0, t0, LEAF
  li t1, L0D
  sd t0, 0(t1)
  li t0, 1 << 2
  csrw medeleg, t0                     /* illegal instructions to S */
  li t0, 1 << 1
  csrw mideleg, t0                     /* SSI to S */
  li t0, SATP_SV39
  csrw satp, t0
  sfence.vma
  la s11, m_after_s
  /* 3. mret into S under Sv39, non-canonical: the fault returns into S at s_main */
  CASE(20)
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x0800
  csrs mstatus, t0                     /* MPP = S */
  li t1, 0x0000008000000000
  csrw mepc, t1
  la ra, s_main
  mret

s_main:
  EXPECT(12, 0x0000008000000000)
  /* 4. S, Sv39: a JALR, sret, a trap to stvec, SSI through a vectored stvec */
  CASE(21)
  JUMP(0x8000000000000000)
  EXPECT(12, 0x8000000000000000)
  CASE(22)
  JUMP(0x0000008000000000)
  EXPECT(12, 0x0000008000000000)
  CASE(23)
  JUMP(0x0000004000000000)
  EXPECT(12, 0x0000004000000000)
  CASE(24)
  JUMP(0xFFFFFFBFFFFFFFF0)
  EXPECT(12, 0xFFFFFFBFFFFFFFF0)
  CASE(25)
  JUMP(0x5555555555555554)
  EXPECT(12, 0x5555555555555554)
  CASE(26)
  JUMP(0xFFFF7FFFFFFFFFFC)
  EXPECT(12, 0xFFFF7FFFFFFFFFFC)
  CASE(27)
  SRET_TO(0x8000000000000000)
  EXPECT(12, 0x8000000000000000)
  CASE(28)
  SRET_TO(0x0000004000000000)
  EXPECT(12, 0x0000004000000000)
  CASE(29)
  li t1, 0x0000004000000000
  csrw stvec, t1
  la ra, 1f
  .word 0                              /* illegal: to S at stvec, whose fetch faults */
1:
  EXPECT(12, 0x0000004000000000)
  CASE(30)
  li t1, 0x0000003FFFFFFFFD            /* base 0x3F_FFFF_FFFC, vectored: SSI goes to base + 4 */
  csrw stvec, t1
  csrsi sie, 2
  la ra, 1f
  csrsi sstatus, 2
  csrsi sip, 2                         /* taken at once */
  nop
1:
  csrci sip, 2
  csrci sie, 2
  EXPECT(12, 0x0000004000000000)

  /* 5. The edges of Sv39's range */
  li s0, L0A + 511 * 8                 /* the leaf for VA 0x3F_FFFF_F000 */
  la t0, epage1
  PAGE(s0, t0)
  CASE(40)                             /* auipc twice and a JAL's link at the top of the lower half */
  la s3, 1f
  li t1, 0x0000003FFFFFFFF4
  jalr x0, 0(t1)
1:
  NONE
  IS(a3, 0x0000003FFFFFFFF4)
  IS(a2, 0x000000407FFFEFF8)
  IS(a4, 0x0000004000000000)
  CASE(41)                             /* a JAL from 0x3F_FFFF_FFE8 to 0x40_0000_0008 */
  JUMP(0x0000003FFFFFFFE8)
  EXPECT(12, 0x0000004000000008)
  CASE(42)                             /* a branch from 0x3F_FFFF_FFEC to 0x40_0000_000C */
  JUMP(0x0000003FFFFFFFEC)
  EXPECT(12, 0x000000400000000C)
  la t0, epage2
  PAGE(s0, t0)
  CASE(43)                             /* the instruction at 0x3F_FFFF_FFFC runs into 0x40_0000_0000 */
  JUMP(0x0000003FFFFFFFF8)
  EXPECT(12, 0x0000004000000000)
  IS(a3, 0x0000004000000000)
  csrr t0, misa
  andi t0, t0, 4                       /* C */
  beqz t0, 2f
  la t0, epage3
  PAGE(s0, t0)
  CASE(44)                             /* the straddler at 0x3F_FFFF_FFFE */
  JUMP(0x0000003FFFFFFFF8)
  EXPECT2(12, 0x0000003FFFFFFFFE, 0x0000004000000000)
  IS(a3, 0x0000003FFFFFFFF9)
2:
  CASE(45)                             /* auipc twice and a JAL's link at the bottom of the upper half */
  la s3, 1f
  li t1, 0xFFFFFFC000000000
  jalr x0, 0(t1)
1:
  NONE
  IS(a3, 0xFFFFFFC000000000)
  IS(a2, 0xFFFFFFBFFFFFF004)
  IS(a4, 0xFFFFFFC00000000C)
  CASE(46)                             /* a JAL from 0xFFFF_FFC0_0000_0020 down to 0xFFFF_FFBF_FFFF_FFE0 */
  JUMP(0xFFFFFFC000000020)
  EXPECT(12, 0xFFFFFFBFFFFFFFE0)
  CASE(47)                             /* a branch from 0xFFFF_FFC0_0000_0024 down to 0xFFFF_FFBF_FFFF_FFE4 */
  JUMP(0xFFFFFFC000000024)
  EXPECT(12, 0xFFFFFFBFFFFFFFE4)
  CASE(48)                             /* a JAL from 0xFFFF_FFFF_FFFF_FFE0 wraps to 0x10, and one from 0x14 back */
  la s3, 1f
  li t1, 0xFFFFFFFFFFFFFFE0
  jalr x0, 0(t1)
1:
  NONE
  IS(a4, 0x10)
  IS(a2, 0xFFFFFFFFFFFFFFE4)
  csrr t0, misa
  andi t0, t0, 4
  beqz t0, 2f
  CASE(49)                             /* the straddler at 0xFFFF_FFFF_FFFF_FFFE, its second half at 0 */
  li a0, 5
  la s3, 1f
  li t1, 0xFFFFFFFFFFFFFFF8
  jalr x0, 0(t1)
1:
  NONE
  IS(a3, 0xFFFFFFFFFFFFFFF9)
  IS(a0, 6)
  IS(a4, 2)
2:

  /* 6. S, Bare: the sources above the physical address space */
  csrw satp, x0
  sfence.vma
  CASE(50)
  JUMP(0x0000000400000000)
  EXPECT(1, 0x0000000400000000)
  CASE(51)
  JUMP(0x8000000000000000)
  EXPECT(1, 0x8000000000000000)
  CASE(52)
  SRET_TO(0x0000008000000000)
  EXPECT(1, 0x0000008000000000)
  CASE(53)
  li t1, 0x0000000400000000
  csrw stvec, t1
  la ra, 1f
  .word 0
1:
  EXPECT(1, 0x0000000400000000)
  CASE(54)
  li t1, 0x8000000000000001            /* vectored: SSI goes to 0x8000_0000_0000_0004 */
  csrw stvec, t1
  csrsi sie, 2
  la ra, 1f
  csrsi sstatus, 2
  csrsi sip, 2
  nop
1:
  csrci sip, 2
  csrci sie, 2
  EXPECT(1, 0x8000000000000004)
  ecall                                /* to M at s11 */

m_after_s:
  CASE(55)
  li t5, 9
  FAR_NE(a6, t5)
  li a6, -1
  csrw medeleg, x0
  csrw mideleg, x0

  /* 7. Two harts: hart 0's bad jumps (hart 1's run from the start, if it is there) */
two_harts:
  CASE(60)
  la s4, tab0
  li s5, 200
  la s6, zero_w
  li s8, 0x2545F4914F6CDD1D
  jal s7, bad_loop
  FAR_NE(a0, zero)
  la t0, h1_here                       /* hart 1 sets it at its start: long done if it runs */
  li t1, 2000
1:
  lw t2, 0(t0)
  bnez t2, 2f
  addi t1, t1, -1
  bnez t1, 1b
  j pass
2:
  la t0, h1_stop
  li t1, 1
  sw t1, 0(t0)
  CASE(61)
  la t0, h1_done
  li t1, 1000000
3:
  lw t2, 0(t0)
  bnez t2, 4f
  addi t1, t1, -1
  bnez t1, 3b
  j fail
4:
  CASE(62)                             /* hart 1's rounds were all right */
  la t0, h1_res
  ld t1, 0(t0)
  FAR_NE(t1, zero)
  CASE(63)                             /* and it ran at least 16 */
  la t0, h1_cnt
  ld t1, 0(t0)
  li t2, 16
  bltu t1, t2, fail
pass:
  TEST_PASS
fail:
  slli a0, s9, 1
  ori a0, a0, 1
  la a1, tohost
  sd a0, 0(a1)
8:
  j 8b

/* Hart 1: bad jumps from the start until hart 0 stops it; the result (0, or the failing round + 1) and the round
   count go to memory, then it parks */
hart1:
  la t0, trap
  csrw mtvec, t0
  li a6, -1
  la t0, h1_here
  li t1, 1
  sw t1, 0(t0)
  la s4, tab1
  li s5, 0
  la s6, h1_stop
  li s8, 0x9E3779B97F4A7C15
  jal s7, bad_loop
  la t0, h1_res
  sd a0, 0(t0)
  la t0, h1_cnt
  sd s1, 0(t0)
  la t0, h1_done
  li t1, 1
  sw t1, 0(t0)
1:
  wfi
  j 1b

/* bad_loop (M, Bare; returns through s7): each round four branches on a xorshift state (s8), then a JALR to the
   round's target from the table at s4 (eight), whose access fault must report it in full. Stops after s5 rounds or
   when the word at s6 is set. a0 = 0, or the failing round + 1; s1 = the rounds run */
bad_loop:
  li s1, 0
1:
  .rept 4
  slli t2, s8, 13
  xor s8, s8, t2
  srli t2, s8, 7
  xor s8, s8, t2
  slli t2, s8, 17
  xor s8, s8, t2
  andi t2, s8, 1
  beqz t2, 2f
  addi t3, t3, 1
2:
  .endr
  andi t2, s1, 7
  slli t2, t2, 3
  add t2, t2, s4
  ld t1, 0(t2)
  la ra, 3f
  jalr x0, 0(t1)
3:
  li t2, 1
  bne a6, t2, 5f
  bne a5, t1, 5f
  bne a7, t1, 5f
  li a6, -1
  addi s1, s1, 1
  beq s1, s5, 4f
  lw t2, 0(s6)
  beqz t2, 1b
4:
  li a0, 0
  jr s7
5:
  addi a0, s1, 1
  jr s7

/* M handler: record the trap. A fetch fault (access or page) continues at ra in the mode it came from; an ECALL from
   S continues in M at s11; anything else (unexpected) skips the instruction. */
  .align 2
trap:
  csrr a5, mepc
  csrr a6, mcause
  csrr a7, mtval
  li t6, 1
  beq a6, t6, 3f
  li t6, 12
  beq a6, t6, 3f
  li t6, 9
  beq a6, t6, 2f
  addi t6, a5, 4
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

/* ---- The edge pages (S code at the VAs the tests map) ---- */
  .balign 4096
epage1:                                /* at VA 0x3F_FFFF_F000: jumps */
  mv a4, ra                            /* the link test's target */
  jalr x0, 0(s3)
  .org epage1 + 0xFE8
  jal x0, . + 0x20                     /* to 0x40_0000_0008 */
  beq x0, x0, . + 0x20                 /* (0xFEC) to 0x40_0000_000C */
  .org epage1 + 0xFF4
  auipc a3, 0
  auipc a2, 0x7ffff
  jal ra, epage1                       /* (0xFFC) the link: 0x40_0000_0000 */
epage2:                                /* at VA 0x3F_FFFF_F000: runs off the end */
  .org epage2 + 0xFF8
  auipc a3, 0
  addi a3, a3, 8                       /* (0xFFC) then 0x40_0000_0000 */
epage3:                                /* at VA 0x3F_FFFF_F000: the straddler (C) */
  .org epage3 + 0xFF8
  auipc a3, 0
  .half 0x0685                         /* (0xFFC) c.addi a3, 1 */
  .half 0x0513                         /* (0xFFE) addi a0, a0, 1's first half */
npage:                                 /* at VA 0xFFFF_FFC0_0000_0000 */
  auipc a3, 0
  auipc a2, 0xfffff
  jal a4, . + 8
  .word 0
  jalr x0, 0(s3)                       /* (0x010) */
  .org npage + 0x020
  jal x0, . - 0x40                     /* to 0xFFFF_FFBF_FFFF_FFE0 */
  beq x0, x0, . - 0x40                 /* (0x024) to 0xFFFF_FFBF_FFFF_FFE4 */
  .org npage + 0x1000
tpage:                                 /* at VA 0xFFFF_FFFF_FFFF_F000 */
  .org tpage + 0xFE0
  jal x0, . + 0x30                     /* to 0x10 */
  auipc a2, 0                          /* (0xFE4) back from 0x14 */
  jalr x0, 0(s3)
  .org tpage + 0xFF8
  auipc a3, 0
  .half 0x0685                         /* (0xFFC) c.addi a3, 1 */
  .half 0x0513                         /* (0xFFE) addi a0, a0, 1's first half... */
zpage:                                 /* at VA 0 */
  .half 0x0015                         /* ... and its second */
  auipc a4, 0                          /* (0x002) */
  jalr x0, 0(s3)                       /* (0x006) */
  .org zpage + 0x010
  auipc a4, 0                          /* the wrap's target */
  jal x0, . - 0x30                     /* (0x014) to 0xFFFF_FFFF_FFFF_FFE4 */
  .org zpage + 0x1000

  .data
  .align 3
tab0:                                  /* hart 0's targets */
  .dword 0x8000000000000000, 0x0000008000000000, 0x0000004000000000, 0xFFFFFFBFFFFFFFF0
  .dword 0x5555555555555554, 0x0000000400000000, 0xFFFFFFFFFFFFF000, 0x0000003FFFFFFFFC
tab1:                                  /* hart 1's */
  .dword 0x4000000000000000, 0x0000010000000000, 0x0000004000000ABC, 0xFFFFFFBFFFFFF000
  .dword 0xAAAAAAAAAAAAAAA8, 0x0000000400001000, 0xFFFFFFFF00000000, 0x0000007FFFFFFFFC
h1_res:
  .dword 0
h1_cnt:
  .dword 0
zero_w:
  .word 0
  .align 6
h1_here:
  .word 0
  .align 6
h1_stop:
  .word 0
  .align 6
h1_done:
  .word 0

TOHOST_DATA
