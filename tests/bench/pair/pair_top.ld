/* The pair runner's image (tests/bench/pair): the dispatcher and tohost at 0x8000_0000, the shared state at
   PAIR_SHARED, the two slots at their bases (pair_top.S, pair.h). */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text .text.*) }
  .tohost 0x80001000 : { *(.tohost) }
  .pair_shared 0x80080000 : { *(.pair_shared) }
  .slot0 0x80100000 : { *(.slot0) }
  .slot1 0x88100000 : { *(.slot1) }
}
