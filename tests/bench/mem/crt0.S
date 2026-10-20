/* memcal's start (tests/bench/mem): hart 0 runs main, every other hart parks in wfi. Loaded at 0x8000_0000 by
   tb_boot's +fw and by tanager-host's boot, as the coherence programs are. */
  .section .text.init, "ax"
  .globl _start
_start:
  csrr a0, mhartid
  bnez a0, park
  la sp, stack_top
  call main
park:
  wfi
  j park
  .section .bss
  .balign 16
  .space 16384
stack_top:
