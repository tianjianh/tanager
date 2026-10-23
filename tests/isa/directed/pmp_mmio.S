/* MMIO loads that take the PMP check (DR-183): with a locked entry M-mode's loads are checked, and with the switch on
   an MMIO load whose check found the shared checker taken waits at the ROB's head for the head's own check. M-mode's
   fetches with a locked entry take word checks on the same checker, so a loop of loads keeps it busy.
   - Entry 0 NAPOT 2 MiB at 0x80000000 RWX, locked: the code, the data and tohost; M's accesses are checked.
   - Entry 1 NAPOT 4 KiB on CLINT's mtime page, R, locked: mtime reads pass, a store faults (7).
   - Entry 2 NAPOT 4 KiB on CLINT's msip page, no permission, locked: a load faults (5).
   The runs are unrolled: in a loop fetch's block keeps its word checks and leaves the checker to the loads. With the
   switch on (st and smt2, 10-22) 20 MMIO loads missed the checker in their own check and took the head's, two of them
   denied. Lockstep compares each step with Spike. Added by the SoC track for DR-183. */
#include "tg_test.h"
#define BUF 0x80100000                 /* in entry 0 */
#define EXPECT(c, tv, lbl) li t5, c; bne a6, t5, lbl; li t5, tv; bne a7, t5, lbl; li a6, -1
#define NONE(lbl) li t5, -1; bne a6, t5, lbl

  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  la t0, trap
  csrw mtvec, t0
  li a6, -1

  li s1, BUF
  li t1, 1
  sd t1, 0(s1)
  li t1, 2
  sd t1, 8(s1)
  li t1, 3
  sd t1, 16(s1)
  li t1, 4
  sd t1, 24(s1)

  /* PMP: 0 RWX over the test's 2 MiB, 1 R on mtime's page, 2 nothing on msip's page; all locked */
  li t0, 0x2003FFFF
  csrw pmpaddr0, t0
  li t0, 0x00802DFF
  csrw pmpaddr1, t0
  li t0, 0x008001FF
  csrw pmpaddr2, t0
  li t0, 0x98999F
  csrw pmpcfg0, t0
  csrr t1, pmpcfg0
  bne t1, t0, f1

  /* mtime read 64 times among stores and loads of RAM, unrolled so that every fetch block is new: fetch's word checks
     (M with a locked entry) and the store addresses at their decision take the shared checker ahead of a waiting
     load, so some of the MMIO loads miss it in their own check and wait for it at the head. The sum takes RAM's
     values only (mtime moves) */
  li s3, CLINT_MTIME
  li s4, 0
  .rept 32
  sd s4, 32(s1)
  ld t3, 0(s3)
  sd s4, 40(s1)
  ld t1, 0(s1)
  ld t2, 8(s1)
  add s4, s4, t1
  add s4, s4, t2
  sd s4, 48(s1)
  ld t4, 0(s3)
  sd s4, 56(s1)
  ld t1, 16(s1)
  ld t2, 24(s1)
  add s4, s4, t1
  add s4, s4, t2
  .endr
  NONE(f2)
  li t1, 320
  bne s4, t1, f2

  /* mtime's page is read-only to M: a store faults */
  sd zero, 0(s3)
  EXPECT(7, CLINT_MTIME, f3)

  /* msip's page denies M: a load faults, by the head's check or the load's own; 8 times in the body above with its
     second MMIO load on msip's page, so that the head's check finds some */
  li t0, CLINT_MSIP
  .rept 8
  sd s4, 32(s1)
  ld t3, 0(s3)
  sd s4, 40(s1)
  ld t1, 0(s1)
  ld t2, 8(s1)
  add s5, s4, t1
  add s5, s5, t2
  sd s4, 48(s1)
  lw t4, 0(t0)
  sd s4, 56(s1)
  ld t1, 16(s1)
  ld t2, 24(s1)
  add s5, s5, t1
  add s5, s5, t2
  EXPECT(5, CLINT_MSIP, f4)
  .endr
  j pass

pass:
  TEST_PASS
f1: TEST_FAIL(1)
f2: TEST_FAIL(2)
f3: TEST_FAIL(3)
f4: TEST_FAIL(4)

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
