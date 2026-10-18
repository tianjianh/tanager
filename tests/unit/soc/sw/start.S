/* Entry from the boot ROM: a0 = mhartid, a1 = DTB address. Each hart gets its own stack.
 * Traps go to trap_entry, which records mcause, mtval and a count in trap_save and returns past the
 * trapping instruction (4 bytes: the program has no compressed instructions). The PS window test
 * (soc_test.c) expects access faults. */
  .section .text.start, "ax"
  .globl _start
_start:
  la    t0, trap_entry
  csrw  mtvec, t0
  la    sp, __stack_top
  slli  t0, a0, 14              /* 16 KiB per hart */
  add   sp, sp, t0
  call  main
1:j     1b

  .align 2
trap_entry:
  csrw  mscratch, t0
  la    t0, trap_save
  sd    t1, 0(t0)
  csrr  t1, mcause
  sd    t1, 8(t0)
  csrr  t1, mtval
  sd    t1, 16(t0)
  ld    t1, 24(t0)
  addi  t1, t1, 1
  sd    t1, 24(t0)
  csrr  t1, mepc
  addi  t1, t1, 4
  csrw  mepc, t1
  ld    t1, 0(t0)
  csrr  t0, mscratch
  mret

  .section .data
  .align 3
  .globl trap_save
trap_save:                      /* t1 (saved), mcause, mtval, count */
  .dword 0, 0, 0, 0
