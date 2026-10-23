/* MMIO reads at the ROB head while the sibling thread's stores write a DRAM line with the same PA[19:6] (CoRR's
   partial line compare, M7 exit 4; rc2's lost SD interrupt, 10-23). Hart 0 reads the CLINT's mtime (an MMIO load,
   which issues only at the ROB head) back to back; hart 1 (with HART1=1) stores to 0x8010bfc0, whose PA[19:6] is
   mtime's (0x2ff), so each of its drains is a CoRR event on hart 0's loads of that partial line. A device load must
   never be marked: a replay after its request went out runs the read again (a PLIC claim read twice loses the
   interrupt, as DR-176's). tg_lsu asserts that no flush meets an MMIO read already sent. Without hart 1 the test
   only reads. */
#include "tg_test.h"
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, sib
  li s1, 0                  /* reads */
  li a0, CLINT_MTIME
1:
  ld t3, 0(a0)
  ld t4, 0(a0)
  bltu t4, t3, fail         /* mtime never goes back */
  addi s1, s1, 2
  li t0, 2000
  blt s1, t0, 1b
  TEST_PASS
fail:
  TEST_FAIL(1)

sib:                        /* hart 1: the aliasing line's stores, until hart 0 ends the test */
  li a1, 0x8010bfc0
2:
  sd a1, 0(a1)
  sd s1, 8(a1)
  addi s1, s1, 1
  j 2b

TOHOST_DATA
