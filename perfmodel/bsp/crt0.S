/* tgsim bare-metal start-up. RAM is zero at reset (the simulator zero-fills .bss), so .bss is not
   cleared here; that keeps start-up instructions out of the measurements. */
  .section .text.init, "ax"
  .globl _start
_start:
  .option push
  .option norelax
  la gp, __global_pointer$
  .option pop
  la sp, __stack_top
#ifdef __riscv_flen
  .option push
  .option arch, +zicsr
  li t0, 0x2000          /* mstatus.FS = initial: enable the FPU */
  csrs mstatus, t0
  .option pop
#endif
  call __libc_init_array
  li a0, 0
  li a1, 0
  li a2, 0
  call main
  call exit
1:
  j 1b
