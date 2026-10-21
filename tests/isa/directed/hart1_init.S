/* Every integer register starts at zero on every hart (M7 step 5c): with hart 1 (HART1=1) its x1-x16 live in bank 1
   and x17-x31 in the load bank, which the reset sequence zeroes beside hart 0's. Before writing any register each
   hart reads all of them into a running sum (x31), so lockstep compares every partial sum with Spike's zero: a home
   not zeroed shows at the first read of it. (The f registers are not checked: their reset value is the
   implementation's, and Spike's is not zero; the core zeroes them all the same, hart 1's F1 homes included.) Hart 0
   then passes; another hart parks. Without hart 1 only hart 0 runs it. Added by the core track (for verif-2's
   review). */
#include "tg_test.h"
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
  add x31, x31, x\r
  .endr
  bnez x31, fail
  TG_PARK_HARTS
pass:
  TEST_PASS
fail:
  TEST_FAIL(1)

  TOHOST_DATA
