/* The pair runner's image (tests/bench/pair; pair.h): the dispatcher, the shared state, tohost, and the two
   slots' programs as binary blobs at their bases. The build passes SLOT0_BIN and SLOT1_BIN (either may be left
   out), each hart's slot (HART0_SLOT ... HART3_SLOT; -1 parks the hart in WFI) and ACTIVE, the harts that run. */
#define SLOT0_BASE 0x80100000
#define SLOT1_BASE 0x88100000
#ifndef HART0_SLOT
#define HART0_SLOT -1
#endif
#ifndef HART1_SLOT
#define HART1_SLOT -1
#endif
#ifndef HART2_SLOT
#define HART2_SLOT -1
#endif
#ifndef HART3_SLOT
#define HART3_SLOT -1
#endif
#ifndef ACTIVE
#error "ACTIVE: the build passes the number of harts that run a slot"
#endif

  .file "pair_top.S"           /* the ELF names this file, not the compiler's temporary object: builds repeat bit for bit */
  .option arch, +zicsr
  .section .text.init, "ax"
  .globl _start
_start:
  csrr t0, mhartid
  andi t0, t0, 3
  la t1, pair_shared
  slli t2, t0, 3
  add t1, t1, t2
  ld t2, 0(t1)
  bltz t2, park
  li t3, SLOT0_BASE
  beqz t2, 1f
  li t3, SLOT1_BASE
1:
  jr t3
park:
  wfi
  j park

  .section .pair_shared, "aw"
  .globl pair_shared
pair_shared:
  .dword HART0_SLOT, HART1_SLOT, HART2_SLOT, HART3_SLOT
  .dword ACTIVE
  .dword 0, 0, 0
  .space 2 * 64

  .section .tohost, "aw", @progbits
  .balign 64
  .globl tohost
tohost: .dword 0
  .balign 64
  .globl fromhost
fromhost: .dword 0

#ifdef SLOT0_BIN
  .section .slot0, "ax"
  .incbin SLOT0_BIN
#endif
#ifdef SLOT1_BIN
  .section .slot1, "ax"
  .incbin SLOT1_BIN
#endif
