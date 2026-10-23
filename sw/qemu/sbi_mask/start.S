/* sbi_mask's entry from OpenSBI's fw_jump (S-mode, a0 = hartid, a1 = the device tree): the boot hart alone runs */
  .section .text.start, "ax"
  .globl _start
_start:
  la sp, __stack_top
  call main
1:
  wfi
  j 1b
