/* TLB capacity and replacement under Sv39 (verification.md §4.1, §4.5). The other suites touch
   fewer pages than the TLBs hold, so a change to TLB size, replacement or refill timing showed in no
   program. M builds the page tables:
     - 128 data pages of 4 KiB at VA 0x10000000, in permuted physical order;
     - 64 code pages of 4 KiB at VA 0x20000000, each with a 4-instruction stub, also permuted;
     - a 2 MiB megapage at VA 0x30000000, and the 1 GiB identity superpage that S runs from.
   S then makes four passes, each in its own page order:
     - working sets of 4 to 64 code pages and 4 to 128 data pages, each swept twice in the same
       order: the second sweep hits only if the set fits, so any TLB size or replacement change
       between 4 and 128 entries moves cycles;
     - a full data sweep that checks one word per page and adds to another (with AMOs in pass 1);
     - a megapage sweep;
     - flushes: one page by SFENCE.VMA in pass 1, everything in pass 2, a satp change in pass 3.
   Self-checking (each stub adds its own page number; every data word is checked), and every step
   is in lockstep with Spike. Passes at once without S mode. */
#include "tg_test.h"
  .option arch, +a, +zifencei
#define ROOT  0x80100000
#define L1A   0x80101000                /* VA 0x00000000-0x3fffffff */
#define L0D   0x80102000                /* VA 0x10000000-0x101fffff: data pages */
#define L0C   0x80103000                /* VA 0x20000000-0x201fffff: code pages */
#define DPA   0x80400                   /* data pages' first PPN (128 pages) */
#define CPA   0x80500                   /* code pages' first PPN (64 pages) */
#define DVA   0x10000000
#define CVA   0x20000000
#define MVA   0x30000000
#define NDATA 128
#define NCODE 64
#define PASSES 4
/* S: s2/s3: the stubs' running sum and step; s4: the sum of the stubs' page numbers; s9: the sum of
   the pages called; s5: pass; s8: the number of the failed check (0: none); s10: s_call's return;
   s11: where an ECALL from S continues in M */

  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  csrr t0, misa
  li t1, 1 << 18                        /* S */
  and t0, t0, t1
  beqz t0, pass
  la t0, trap
  csrw mtvec, t0

  /* Zero the four tables */
  li t0, ROOT
  li t1, L0C + 0x1000
1:
  sd x0, 0(t0)
  addi t0, t0, 8
  bltu t0, t1, 1b
  li s0, ROOT
  li s1, L1A
  li t0, 0x200000CF                     /* root[2]: VA 0x80000000, 1 GiB identity, RWXAD */
  sd t0, 16(s0)
  li t0, 0x20040401                     /* root[0]: -> L1A */
  sd t0, 0(s0)
  li t0, 0x20040801                     /* L1A[0x80]: VA 0x10000000 -> L0D */
  sd t0, 0x400(s1)
  li t0, 0x20040C01                     /* L1A[0x100]: VA 0x20000000 -> L0C */
  li t1, L1A + 0x800
  sd t0, 0(t1)
  li t0, 0x201800C7                     /* L1A[0x180]: VA 0x30000000, 2 MiB at PA 0x80600000, RWAD */
  li t1, L1A + 0xC00
  sd t0, 0(t1)

  /* L0D[i] -> data page (i * 37) mod 128, RWAD */
  li s0, L0D
  li t0, 0
2:
  li t1, 37
  mul t1, t0, t1
  andi t1, t1, NDATA - 1
  li t2, DPA
  add t1, t1, t2
  slli t1, t1, 10
  ori t1, t1, 0xC7
  slli t2, t0, 3
  add t2, t2, s0
  sd t1, 0(t2)
  addi t0, t0, 1
  li t1, NDATA
  bltu t0, t1, 2b

  /* L0C[i] -> code page (i * 21) mod 64, RXA; stub i at offset i * 64 of that page:
     addi s4, s4, i; add s2, s2, s3; addi s3, s3, 1; ret */
  li s0, L0C
  la s1, stub
  lw s6, 0(s1)
  lw s7, 4(s1)
  lw s9, 8(s1)
  lw s10, 12(s1)
  li t0, 0
3:
  li t1, 21
  mul t1, t0, t1
  andi t1, t1, NCODE - 1
  li t2, CPA
  add t1, t1, t2                        /* PPN */
  slli t2, t1, 10
  ori t2, t2, 0x4B
  slli t3, t0, 3
  add t3, t3, s0
  sd t2, 0(t3)
  slli t1, t1, 12                       /* the stub's physical address */
  slli t2, t0, 6
  add t1, t1, t2
  slli t3, t0, 20                       /* addi's immediate */
  or t3, t3, s6
  sw t3, 0(t1)
  sw s7, 4(t1)
  sw s9, 8(t1)
  sw s10, 12(t1)
  addi t0, t0, 1
  li t1, NCODE
  bltu t0, t1, 3b
  fence.i

  /* Into S with Sv39 */
  li t0, 0x8000000000080100
  csrw satp, t0
  sfence.vma
  li t0, 0x1800
  csrc mstatus, t0
  li t0, 0x0800
  csrs mstatus, t0                      /* MPP = S */
  la t0, s_code
  csrw mepc, t0
  la s11, m_after_s
  mret

s_code:
  li s2, 0
  li s3, 1
  li s4, 0
  li s5, 0
  li s8, 0
  li s9, 0
s_pass:
  /* Flushes: one page in pass 1, all in pass 2, a satp change (ASID 1) in pass 3 */
  li t0, 1
  bne s5, t0, 1f
  li t1, DVA + 5 * 0x1000
  sfence.vma t1, x0
1:
  li t0, 2
  bne s5, t0, 1f
  sfence.vma
1:
  li t0, 3
  bne s5, t0, 1f
  li t1, 0x8000100000080100
  csrw satp, t1
  sfence.vma
1:
  /* Code working sets: stubs (i * 37 + pass) mod W for i < 2W */
  la s0, wsets_code
2:
  ld s1, 0(s0)
  beqz s1, 4f
  slli a1, s1, 1
  li s6, 0
3:
  li t0, 37
  mul a0, s6, t0
  add a0, a0, s5
  remu a0, a0, s1
  jal ra, s_call
  addi s6, s6, 1
  bltu s6, a1, 3b
  addi s0, s0, 8
  j 2b
4:
  /* The pass's stride: odd and prime to every working set */
  la t0, strides
  slli t1, s5, 3
  add t0, t0, t1
  ld s7, 0(t0)

  /* Full data sweep, pages (i * stride + pass) mod 128: word j of page j holds j ^ 0x5A5 (written
     in pass 0), word 256 + j counts j once per pass */
  li s6, 0
5:
  mul t0, s6, s7
  add t0, t0, s5
  andi t0, t0, NDATA - 1                /* page j */
  li t1, DVA
  slli t2, t0, 12
  add t1, t1, t2
  slli t2, t0, 3
  add t1, t1, t2                        /* word j of page j */
  xori t3, t0, 0x5A5
  bnez s5, 6f
  sd t3, 0(t1)
  j 7f
6:
  ld t4, 0(t1)
  beq t4, t3, 7f
  li s8, 1
7:
  addi t1, t1, 2047
  addi t1, t1, 1                        /* +2048: the running word */
  li t2, 1
  bne s5, t2, 8f
  amoadd.d x0, t0, (t1)                 /* pass 1 adds with an AMO */
  j 9f
8:
  ld t4, 0(t1)
  add t4, t4, t0
  sd t4, 0(t1)
9:
  addi s6, s6, 1
  li t0, NDATA
  bltu s6, t0, 5b

  /* Data working sets: pages (i * stride + pass) mod W for i < 2W, reading the check word */
  la s0, wsets_data
10:
  ld s1, 0(s0)
  beqz s1, 13f
  slli a1, s1, 1
  li s6, 0
11:
  mul t0, s6, s7
  add t0, t0, s5
  remu t0, t0, s1
  li t1, DVA
  slli t2, t0, 12
  add t1, t1, t2
  slli t2, t0, 3
  add t1, t1, t2
  ld t4, 0(t1)
  xori t3, t0, 0x5A5
  beq t4, t3, 12f
  li s8, 4
12:
  addi s6, s6, 1
  bltu s6, a1, 11b
  addi s0, s0, 8
  j 10b
13:
  /* The megapage: 32 words 64 KiB apart, one TLB entry */
  li s6, 0
14:
  li t1, MVA
  slli t2, s6, 16
  add t1, t1, t2
  slli t2, s5, 3
  add t1, t1, t2
  add t3, s6, s5
  sd t3, 0(t1)
  ld t4, 0(t1)
  beq t4, t3, 15f
  li s8, 2
15:
  addi s6, s6, 1
  li t0, 32
  bltu s6, t0, 14b

  addi s5, s5, 1
  li t0, PASSES
  bltu s5, t0, s_pass

  /* The running words: each page's must be 4 * j */
  li s6, 0
16:
  li t1, DVA
  slli t2, s6, 12
  add t1, t1, t2
  slli t2, s6, 3
  add t1, t1, t2
  addi t1, t1, 2047
  ld t4, 1(t1)
  slli t3, s6, 2
  beq t4, t3, 17f
  li s8, 3
17:
  addi s6, s6, 1
  li t0, NDATA
  bltu s6, t0, 16b
  ecall                                 /* to M */

  /* Calls stub a0 at VA CVA + a0 * 4096 + a0 * 64; returns through ra (saved in s10) */
s_call:
  mv s10, ra
  add s9, s9, a0
  li t1, CVA
  slli t2, a0, 12
  add t1, t1, t2
  slli t2, a0, 6
  add t1, t1, t2
  jalr ra, 0(t1)
  mv ra, s10
  ret

m_after_s:
  bnez s8, fail_data
  beqz s9, fail_sum
  bne s4, s9, fail_sum
pass:
  TEST_PASS
fail_data:
  TEST_FAIL(2)
fail_sum:
  TEST_FAIL(3)

  /* Any trap but the final ECALL from S fails the test with its cause */
trap:
  csrr t6, mcause
  li t5, 9
  beq t6, t5, 1f
  addi t6, t6, 16
  slli t6, t6, 1
  ori t6, t6, 1
  la t5, tohost
  sd t6, 0(t5)
2:
  j 2b
1:
  li t6, 0x1800
  csrs mstatus, t6                      /* MPP = M */
  csrw mepc, s11
  mret

  .section .data
  .align 3
strides:
  .dword 1, 37, 73, 101                 /* prime to 2, 3, 5 and 7: each visits every page once */
wsets_code:                             /* ITLB_ENTRIES: 16 in every configuration today */
  .dword 4, 8, 12, 16, 20, 24, 32, 48, 64, 0
wsets_data:                             /* DTLB_ENTRIES: 32 in every configuration today */
  .dword 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 64, 96, 128, 0
stub:
  addi s4, s4, 0
  add s2, s2, s3
  addi s3, s3, 1
  ret

TOHOST_DATA
