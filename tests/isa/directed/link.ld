OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  .text : { *(.text) }
  .data : { *(.data) }
  .bss : { *(.bss) }
  /* A TG_DEBUG test's debug ROM (debug.S): the debug window's entry at 0x1100_0800 (core-priv.md "Debug mode") */
  .dbgrom 0x11000800 : { *(.dbgrom) }
}
