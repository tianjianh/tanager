/* D4 modes step 5's test image (rvtest.c): S-mode, at 0x8020_0000 after OpenSBI's fw_jump, a0 = hartid, a1 = tree.
 * A trap (an access fault through the PS window) is counted and skipped: rv64im, every instruction 4 bytes. */
	.section .text.start
	.globl _start
_start:
	la	sp, stack_top
	la	t0, trap
	csrw	stvec, t0
	call	main
1:	wfi
	j	1b

	.align 4
trap:
	addi	sp, sp, -16
	sd	t0, 0(sp)
	sd	t1, 8(sp)
	la	t0, trap_count
	ld	t1, 0(t0)
	addi	t1, t1, 1
	sd	t1, 0(t0)
	csrr	t1, scause
	sd	t1, 8(t0)
	csrr	t1, sepc
	addi	t1, t1, 4
	csrw	sepc, t1
	ld	t0, 0(sp)
	ld	t1, 8(sp)
	addi	sp, sp, 16
	sret

	.section .data
	.align 3
	.globl trap_count
trap_count:	.dword 0, 0        /* count, last scause */
	.section .bss
	.align 4
	.space 8192
stack_top:
