/* Tanager boot ROM at 0x1000 (docs/spec/uncore-periph.md, plan §5.4 / §7.2).
 * Every hart starts here in M-mode. Hand over to the next stage with the OpenSBI fw_jump
 * convention: a0 = mhartid, a1 = device tree; the entry and DTB addresses come from the
 * host-control block, which the host programs before releasing reset.
 * Built uncompressed (rv64i) so it does not depend on the C extension. */
#define HOSTCTL_BASE      0x10001000
#define HOSTCTL_ENTRY     0x08
#define HOSTCTL_DTB       0x10

	.section .text.boot, "ax"
	.globl _start
_start:
	csrr	a0, mhartid
	li	t0, HOSTCTL_BASE
	ld	a1, HOSTCTL_DTB(t0)
	ld	t1, HOSTCTL_ENTRY(t0)
	jr	t1
