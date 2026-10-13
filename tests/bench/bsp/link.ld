/* Tanager bare-metal simulation platform (docs/spec/verification.md §2.6, interfaces.md §3):
   programs at 0x8000_0000; tohost/fromhost in their own lines; 256 MiB of RAM used. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 256M }

SECTIONS
{
  .text : {
    *(.text.init)
    *(.text .text.*)
  } > RAM
  .tohost : ALIGN(64) { *(.tohost) } > RAM
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > RAM
  .init_array : {
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(.init_array .init_array.*))
    PROVIDE_HIDDEN(__init_array_end = .);
  } > RAM
  .fini_array : {
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(.fini_array .fini_array.*))
    PROVIDE_HIDDEN(__fini_array_end = .);
  } > RAM
  .data : { *(.data .data.*) } > RAM
  .sdata : {
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } > RAM
  .bss (NOLOAD) : ALIGN(8) {
    __bss_start = .;
    *(.sbss .sbss.*) *(.scommon) *(.bss .bss.*) *(COMMON)
    . = ALIGN(8);
    __bss_end = .;
  } > RAM
  . = ALIGN(4096);
  _end = .;
  PROVIDE(end = .);
  __stack_top = ORIGIN(RAM) + LENGTH(RAM) - 64;
}
