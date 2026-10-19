/* A JAL at the micro-BTB's exit slot goes to its own target even when the entry it hits is another block's
   (core-pipeline.md §3.2). The micro-BTB keys on PC bits 20:4 with 64 entries, so a block 4 MiB away shares
   this test's yblock entry (4 MiB: also with 128 entries). The test writes a JALR there at the slot of
   yblock's JAL and runs it four times, so execute trains the shared entry with the JALR's target, train_back.
   Then it runs yblock. Before the fix (main 0a1a418), F2 kept F1's path to the entry's target and marked the
   JAL's exit "to its own target", so decode never checked it and the core went on at train_back. The test
   fails there, and lockstep fails at the JAL's successor. A few hundred cycles. Added by the core track. */
#include "tg_test.h"
#define ALIAS 0x400000
  .option arch, +zifencei
  .section .text.init, "ax"
  .globl _start
_start:
  li s2, 0                    /* phase: 0 training, 1 the JAL */
  la s3, yblock
  li t0, ALIAS
  add s3, s3, t0              /* xblock: yblock + 4 MiB, the same index, tag and slots */
  li t0, 0x00000013           /* nop */
  sw t0, 0(s3)
  li t0, 0x000f0067           /* jalr x0, 0(t5): its last parcel at slot 3, as yblock's JAL */
  sw t0, 4(s3)
  fence.i
  la t5, train_back
  li s1, 4
train_loop:
  jr s3                       /* xblock: nop; jalr x0, 0(t5) */
train_back:
  bnez s2, fail               /* reached from yblock's JAL: it followed xblock's entry */
  addi s1, s1, -1
  bnez s1, train_loop
  li s2, 1
  j yblock
y_ok:
  TEST_PASS
fail:
  TEST_FAIL(1)

  /* yblock at index 0x1a (PC bits 8:4), clear of the code above; zeros before it, so no path falls into it */
  .balign 512
  .skip 0x1a0
yblock:
  nop
  jal x0, y_ok                /* slot 3, the entry's: its own target is y_ok */

  TOHOST_DATA
