/* Tanager debug ROM at DEBUG_BASE + 0x800 (docs/spec/soc.md §9.5; TG_DEBUG builds only).
 * A hart in debug mode runs it from the debug window: it enters at 0x800 on every entry to debug mode
 * (a halt request, a step, ebreak, the program buffer's closing ebreak) and at 0x808 on an exception
 * in debug mode. It keeps the hart's s0 and s1 in dscratch0 and dscratch1 while it runs, so the
 * program buffer and the debugger see the hart's own registers.
 * Window offsets from s1 = DEBUG_BASE + 4 * mhartid: the hart's FLAGS word at 0 ([0] GO, [1] RESUME),
 * and its HALTED, GOING, RESUMING and EXCEPTION words, which the DM decodes by address.
 * Built uncompressed (rv64i); tg_dm's abstract area jumps back to `halt`, whose offset the generator
 * puts in tg_debugrom_img_pkg. */
#define DEBUG_BASE_HI 0x11000           /* lui: DEBUG_BASE = 0x1100_0000 */
#define HALTED        0x100
#define GOING         0x140
#define RESUMING      0x180
#define EXCEPTION     0x1C0
#define ABSTRACT      0x300
#define CSR_DSCRATCH0 0x7b2
#define CSR_DSCRATCH1 0x7b3

	.section .text.debug, "ax"
	.option norvc
	.globl _start
_start:                         /* 0x800: entry */
	j	entry
	nop
	.globl exc_entry
exc_entry:                      /* 0x808: an exception in debug mode (the program buffer) */
	j	exception

entry:
	csrw	CSR_DSCRATCH0, s0
	csrw	CSR_DSCRATCH1, s1
	.globl halt
halt:                           /* also where the abstract area comes back */
	lui	s0, DEBUG_BASE_HI
	csrr	s1, mhartid
	slli	s1, s1, 2
	add	s1, s1, s0
	sw	zero, HALTED(s1)
loop:
	lw	s0, 0(s1)               /* FLAGS */
	beqz	s0, loop
	andi	s0, s0, 1
	bnez	s0, go
	sw	zero, RESUMING(s1)
	csrr	s0, CSR_DSCRATCH0
	csrr	s1, CSR_DSCRATCH1
	dret
go:
	sw	zero, GOING(s1)
	lui	s0, DEBUG_BASE_HI
	fence.i                         /* the DM has just written the abstract area and the program buffer */
	jr	ABSTRACT(s0)

exception:
	csrw	CSR_DSCRATCH0, s0
	csrw	CSR_DSCRATCH1, s1
	lui	s0, DEBUG_BASE_HI
	csrr	s1, mhartid
	slli	s1, s1, 2
	add	s1, s1, s0
	sw	zero, EXCEPTION(s1)
	j	loop
