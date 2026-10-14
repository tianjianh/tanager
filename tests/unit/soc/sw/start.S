/* Entry from the boot ROM: a0 = mhartid, a1 = DTB address. Each hart gets its own stack. */
  .section .text.start, "ax"
  .globl _start
_start:
  la    sp, __stack_top
  slli  t0, a0, 14              /* 16 KiB per hart */
  add   sp, sp, t0
  call  main
1:j     1b
