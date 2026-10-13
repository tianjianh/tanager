/* Minimal environment for Tanager's directed ISA tests (verification.md §4.1): linked at
   0x8000_0000, M-mode, exit through tohost (TEST_PASS / TEST_FAIL), no libc. */
#define CLINT_MSIP      0x02000000
#define CLINT_MTIMECMP  0x02004000
#define CLINT_MTIME     0x0200bff8

#define TEST_PASS              \
  li a0, 1;                    \
  la a1, tohost;               \
  sd a0, 0(a1);                \
9: j 9b

/* Exit code n (non-zero): fails with code n. */
#define TEST_FAIL(n)           \
  li a0, ((n) << 1) | 1;       \
  la a1, tohost;               \
  sd a0, 0(a1);                \
8: j 8b

#define TOHOST_DATA            \
  .section .tohost, "aw", @progbits; \
  .align 6; .global tohost; tohost: .dword 0; \
  .align 6; .global fromhost; fromhost: .dword 0
