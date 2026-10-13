/* Start-up for the Tanager simulation platform (verification.md §2.6). */
  .section .text.init, "ax"
  .globl _start
_start:
  .option push
  .option norelax
  la gp, __global_pointer$
  .option pop
  la sp, __stack_top
  .option push
  .option arch, +zicsr
  la t0, tg_trap
  csrw mtvec, t0
#ifdef __riscv_flen
  li t0, 0x2000          /* mstatus.FS = initial */
  csrs mstatus, t0
  csrwi fcsr, 0
#endif
  .option pop
  la t0, __bss_start
  la t1, __bss_end
1:
  bgeu t0, t1, 2f
  sd zero, 0(t0)
  addi t0, t0, 8
  j 1b
2:
  call __libc_init_array
  li a0, 0
  li a1, 0
  li a2, 0
  call main
  call exit
3:
  j 3b

/* Any trap is unexpected here: exit with code 0x1000 + mcause (low bits). */
  .align 2
tg_trap:
  .option push
  .option arch, +zicsr
  csrr a0, mcause
  .option pop
  andi a0, a0, 0xff
  li t0, 0x1000
  add a0, a0, t0
  call _exit
4:
  j 4b
