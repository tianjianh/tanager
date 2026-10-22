/* mtgsmt (0x7C0, M7 step 6, core-pipeline.md §9): HART1_OFF keeps hart 1 asleep. With hart 1 running, hart 0
   checks the register (bit 0 only, reset 0), sets HART1_OFF once hart 1 parks in WFI, waits until hart 1 has gone
   to sleep for good, and sends hart 1 an IPI: hart 1 must stay asleep (HART1_OFF holds off its sleep timeout and
   +xwake's random wakes too; a wake without the IPI sleeps again). The IPI goes only after the wait: a parked hart 1
   may be awake in its loop when the bit is set (WFI may complete at any time, and +xwake=N completes it at random),
   and HART1_OFF does not stop a running hart 1, so an IPI then would complete a WFI that never slept. Clearing the
   bit must wake it at once on the pending IPI. Hart 1 then reads the
   register (0: one copy per core, which hart 0 cleared) and counts its wake. Lockstep compares every read of
   0x7C0 with Spike's model of the core's register. Without hart 1 only hart 0 runs, and passes without touching
   0x7C0 (illegal there). Failure codes: 2 the reset value, 3 a bit other than 0 kept, 4 hart 1 woke with
   HART1_OFF set, 5 hart 1 did not wake once it cleared, 6 hart 1 read the bit set. */
#include "tg_test.h"
#define MTGSMT 0x7c0
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  csrr t0, mhartid
  la s0, h1_state
  bnez t0, hart1

hart0:
  /* Is hart 1 running? It sets h1_state at once */
  li t1, 20000
1:
  lw t2, 0(s0)
  bnez t2, 2f
  addi t1, t1, -1
  bnez t1, 1b
  TEST_PASS
2:
  /* The register: reset 0, bit 0 only */
  csrr t2, MTGSMT
  bnez t2, fail_reset
  li t3, -1
  csrw MTGSMT, t3
  csrr t2, MTGSMT
  li t3, 1
  bne t2, t3, fail_warl
  csrw MTGSMT, zero
  /* Hart 1 parks (h1_state = 2). HART1_OFF, then a wait: a WFI sleeps 64 cycles after it reaches the head, and
     once hart 1 sleeps with the bit set it stays asleep; awake in its loop, it goes round at most once more */
3:
  lw t2, 0(s0)
  li t3, 2
  bne t2, t3, 3b
  csrsi MTGSMT, 1
  li t1, 2000
4:
  addi t1, t1, -1
  bnez t1, 4b
  /* An IPI to hart 1: it stays asleep */
  li t4, CLINT_MSIP
  li t5, 1
  sw t5, 4(t4)
  li t1, 4000
5:
  lw t2, 4(s0)
  bnez t2, fail_woke
  addi t1, t1, -1
  bnez t1, 5b
  /* Cleared: the pending IPI wakes it at once */
  csrci MTGSMT, 1
  li t1, 20000
6:
  lw t2, 4(s0)
  bnez t2, 7f
  addi t1, t1, -1
  bnez t1, 6b
  j fail_asleep
7:
  /* What hart 1 read of the register after it woke (stored before its count) */
  fence r, r
  ld t2, 8(s0)
  bnez t2, fail_read
  TEST_PASS

hart1:
  li t1, 1
  sw t1, 0(s0)
  /* An IPI completes WFI (MSIE); mstatus.MIE stays 0, so it takes no trap */
  csrsi mie, 8
  li t1, 2
  sw t1, 0(s0)
10:
  wfi
  csrr t2, mip
  andi t2, t2, 8
  beqz t2, 10b  /* a wake without an IPI (WFI may complete at any time; step 6's sleep timeout): sleep again */
  li t4, CLINT_MSIP
  sw zero, 4(t4)
  csrr t2, MTGSMT
  sd t2, 8(s0)
  fence w, w
  li t1, 1
  sw t1, 4(s0)
8:
  wfi
  j 8b

fail_reset:
  TEST_FAIL(2)
fail_warl:
  TEST_FAIL(3)
fail_woke:
  TEST_FAIL(4)
fail_asleep:
  TEST_FAIL(5)
fail_read:
  TEST_FAIL(6)

  .section .data
  .align 6
h1_state: .word 0     /* 1: hart 1 runs; 2: it parks in WFI */
h1_wakes: .word 0     /* 1: hart 1 woke */
h1_read:  .dword 0    /* mtgsmt as hart 1 read it after waking */

  TOHOST_DATA
