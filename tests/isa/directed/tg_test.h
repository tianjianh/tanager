/* Minimal environment for Tanager's directed ISA tests (verification.md §4.1): linked at
   0x8000_0000, M-mode, exit through tohost (TEST_PASS / TEST_FAIL), no libc. */
#define CLINT_MSIP      0x02000000
#define CLINT_MTIMECMP  0x02004000
#define CLINT_MTIME     0x0200bff8

/* M7 (DR-175): the first thing at _start. Hart 0 runs the test; another hart (a sibling thread that fetches from
   reset) parks in WFI. */
#define TG_PARK_HARTS          \
  csrr t0, mhartid;            \
  beqz t0, 9001f;              \
9000:                          \
  wfi;                         \
  j 9000b;                     \
9001:

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
