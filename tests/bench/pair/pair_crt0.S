/* A pair program's start (tests/bench/pair): entered from the dispatcher, and again from the top whenever the
   program ends. It restores .data from its pristine copy, clears .bss, sets its own stack and gp, and calls main;
   _exit (pair_syscalls.c) comes back here. */
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
  la t0, pair_trap
  csrw mtvec, t0
#ifdef __riscv_flen
  li t0, 0x2000          /* mstatus.FS = initial */
  csrs mstatus, t0
  csrwi fcsr, 0
#endif
  .option pop
  la t0, __data_lma      /* .data from its pristine copy, so every run starts alike */
  la t1, __data_start
  la t2, __data_end
1:
  bgeu t1, t2, 2f
  ld t3, 0(t0)
  sd t3, 0(t1)
  addi t0, t0, 8
  addi t1, t1, 8
  j 1b
2:
  la t0, __bss_start
  la t1, __bss_end
3:
  bgeu t0, t1, 4f
  sd zero, 0(t0)
  addi t0, t0, 8
  j 3b
4:
  call __libc_init_array
  li a0, 0
  li a1, 0
  li a2, 0
  call main
  call exit
5:
  j 5b

/* Any trap is unexpected here: the run ends with code 0x1000 + mcause (pair_syscalls.c). */
  .align 2
pair_trap:
  .option push
  .option arch, +zicsr
  csrr a0, mcause
  .option pop
  andi a0, a0, 0xff
  li t0, 0x1000
  add a0, a0, t0
  call pair_fail
6:
  j 6b
